import Foundation
import PostgresNIO

/// Streaming exporter. Two entry points:
/// - `exportTable` — full-table dump using a streaming SELECT. The row
///   sequence is consumed lazily so even multi-million-row tables don't
///   balloon memory. Pass an `OperationsCenter` to register the run.
/// - `exportPage` — write an already-materialised `RowsFetcher.Page` (i.e.
///   a scratchpad result block).
///
/// Output is written via a buffered `FileHandle`. CSV escaping follows
/// RFC 4180; JSON output is a streaming array; SQL is one INSERT per row.
enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case csv, json, sql
        var id: String { rawValue }
        var fileExtension: String { rawValue }
        var uiLabel: String {
            switch self {
            case .csv: return "CSV"
            case .json: return "JSON"
            case .sql: return "SQL inserts"
            }
        }
    }

    struct Stats: Sendable {
        var rowsWritten: Int
        var bytesWritten: Int
        var elapsed: TimeInterval
    }

    /// Stream every row of `table` (no LIMIT) into `destination` formatted as
    /// `format`. Cancellable via `tracker` + `operationID`.
    static func exportTable(
        _ table: TableNode,
        format: Format,
        destination: URL,
        client: PostgresClient,
        tracker: OperationsCenter? = nil,
        operationID: UUID? = nil
    ) async throws -> Stats {
        let columns = table.columns
        let projection = columns
            .map { "\(SQLIdent.quote($0.name))::text AS \(SQLIdent.quote($0.name))" }
            .joined(separator: ", ")
        let sql = "SELECT \(projection) FROM \(SQLIdent.qualified(schema: table.schema, name: table.name))"

        return try await client.withConnection { connection in
            let file = try AtomicExportFile(destination: destination)
            defer { file.discard() }
            let handle = file.handle

            // Cancellation handshake — same pattern as QueryRunner.
            if let opID = operationID, let tracker {
                let pid = try await OperationsHelpers.fetchBackendPID(connection, logger: pgbrainQuietLogger)
                let cancel: @Sendable () async -> Void = { [weak client] in
                    guard let client else { return }
                    _ = try? await client.withConnection { sister in
                        _ = try await sister.query(
                            PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(pid))"),
                            logger: pgbrainQuietLogger
                        )
                    }
                }
                Task { @MainActor in
                    tracker.attachCancellation(toOperationID: opID, pid: pid, handler: cancel)
                }
            }

            let writer = StreamingWriter(handle: handle, columns: columns, format: format, table: table)
            try writer.writeHeader()

            let started = Date()
            var rowCount = 0
            let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: pgbrainQuietLogger)
            for try await row in stream {
                try Task.checkCancellation()
                let random = PostgresRandomAccessRow(row)
                var values: [String?] = []
                values.reserveCapacity(columns.count)
                for i in 0..<columns.count {
                    let cell = random[i]
                    // Every column is projected `::text`, so a decode failure is
                    // a real error — never quietly export it as NULL.
                    values.append(cell.bytes == nil ? nil : try cell.decode(String.self, context: .default))
                }
                try writer.writeRow(values, isLast: false)
                rowCount += 1
            }
            try writer.writeFooter()
            try file.commit()
            return Stats(
                rowsWritten: rowCount,
                bytesWritten: writer.bytesWritten,
                elapsed: Date().timeIntervalSince(started)
            )
        }
    }

    /// Write a `RowsFetcher.Page` straight to disk in `format`. Used by the
    /// scratchpad result-block export action.
    static func exportPage(
        _ page: RowsFetcher.Page,
        format: Format,
        destination: URL,
        tableNameHint: String = "result"
    ) throws -> Stats {
        let file = try AtomicExportFile(destination: destination)
        defer { file.discard() }
        let handle = file.handle
        let table = TableNode(schema: "", name: tableNameHint, kind: .table, columns: page.columns)
        let writer = StreamingWriter(handle: handle, columns: page.columns, format: format, table: table)
        try writer.writeHeader()
        let started = Date()
        for row in page.rows {
            try writer.writeRow(row, isLast: false)
        }
        try writer.writeFooter()
        try file.commit()
        return Stats(
            rowsWritten: page.rows.count,
            bytesWritten: writer.bytesWritten,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// RFC 8259 number grammar: `-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`.
    static func isJSONNumber(_ s: String) -> Bool {
        let b = Array(s.utf8)
        var i = 0
        func digits() -> Int {
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            return i - start
        }
        if i < b.count, b[i] == 0x2D { i += 1 }
        guard i < b.count else { return false }
        if b[i] == 0x30 { i += 1 } else if digits() == 0 { return false }
        if i < b.count, b[i] == 0x2E {
            i += 1
            guard digits() > 0 else { return false }
        }
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            i += 1
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            guard digits() > 0 else { return false }
        }
        return i == b.count
    }

    enum ExportError: LocalizedError {
        case openFailed(String)
        var errorDescription: String? {
            switch self {
            case .openFailed(let path): return "Couldn't open \(path) for writing."
            }
        }
    }
}

/// Export target that only appears at `destination` once the export fully
/// succeeds: rows go to a hidden temp file in the same directory (same volume,
/// so the final rename is atomic); a failed or cancelled export deletes it and
/// leaves any previous file at `destination` untouched.
final class AtomicExportFile {
    let destination: URL
    let tempURL: URL
    let handle: FileHandle
    private var committed = false

    init(destination: URL) throws {
        self.destination = destination
        let dir = destination.deletingLastPathComponent()
        tempURL = dir.appendingPathComponent(".\(destination.lastPathComponent).pgbrain-\(UUID().uuidString.prefix(8)).tmp")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
              let h = try? FileHandle(forWritingTo: tempURL) else {
            throw Exporter.ExportError.openFailed(destination.path)
        }
        handle = h
    }

    func commit() throws {
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
        committed = true
    }

    /// No-op after a successful `commit`.
    func discard() {
        guard !committed else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: tempURL)
    }
}

/// Buffered file writer that translates `[String?]` rows into the chosen
/// format. Keeps a small in-memory buffer and flushes in 64KB chunks so the
/// kernel can pipeline disk writes with the next batch of rows.
private final class StreamingWriter {
    let handle: FileHandle
    let columns: [ColumnNode]
    let format: Exporter.Format
    let table: TableNode
    private var buffer: Data = Data(capacity: 64 * 1024)
    private(set) var bytesWritten = 0
    private var firstJSONRow = true

    init(handle: FileHandle, columns: [ColumnNode], format: Exporter.Format, table: TableNode) {
        self.handle = handle
        self.columns = columns
        self.format = format
        self.table = table
    }

    func writeHeader() throws {
        switch format {
        case .csv:
            appendLine(columns.map { csvEscape($0.name) }.joined(separator: ","))
        case .json:
            append("[\n")
            firstJSONRow = true
        case .sql:
            append("-- pgBrain export of \(SQLIdent.qualified(schema: table.schema, name: table.name))\n")
        }
    }

    func writeRow(_ values: [String?], isLast: Bool) throws {
        switch format {
        case .csv:
            appendLine(values.map { csvField($0) }.joined(separator: ","))
        case .json:
            if !firstJSONRow { append(",\n") }
            firstJSONRow = false
            var obj = "  {"
            for (i, col) in columns.enumerated() {
                if i > 0 { obj += ", " }
                obj += jsonString(col.name) + ": "
                if let v = values[i] {
                    obj += jsonValue(v, kind: ColumnTypeKind.from(typeName: col.typeName))
                } else {
                    obj += "null"
                }
            }
            obj += "}"
            append(obj)
        case .sql:
            let qualified = SQLIdent.qualified(schema: table.schema, name: table.name)
            let cols = columns.map { SQLIdent.quote($0.name) }.joined(separator: ", ")
            let vals = values.map { v -> String in
                guard let v else { return "NULL" }
                return "'\(v.replacingOccurrences(of: "'", with: "''"))'"
            }.joined(separator: ", ")
            appendLine("INSERT INTO \(qualified) (\(cols)) VALUES (\(vals));")
        }
        if buffer.count >= 64 * 1024 { try flush() }
    }

    func writeFooter() throws {
        switch format {
        case .csv:
            break
        case .json:
            append("\n]\n")
        case .sql:
            break
        }
        try flush()
    }

    private func flush() throws {
        if buffer.isEmpty { return }
        try handle.write(contentsOf: buffer)
        bytesWritten += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    private func append(_ s: String) { buffer.append(contentsOf: s.utf8) }
    private func appendLine(_ s: String) { append(s); append("\n") }

    /// PostgreSQL `COPY … CSV` convention: NULL is an empty unquoted field and
    /// the empty string is `""`, so the two survive a round trip.
    private func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        return value.isEmpty ? "\"\"" : csvEscape(value)
    }

    private func csvEscape(_ s: String) -> String {
        // Scalars, not Characters: "\r\n" is one Character and matches neither.
        if s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || s == "\\." {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    private func jsonValue(_ s: String, kind: ColumnTypeKind) -> String {
        switch kind {
        case .integer, .number:
            // NaN / Infinity (float, numeric) and money's "$1,234.00" aren't
            // JSON numbers — emit those as strings so the file stays valid.
            return Exporter.isJSONNumber(s) ? s : jsonString(s)
        case .bool:
            switch s.lowercased() {
            case "t", "true", "1": return "true"
            case "f", "false", "0": return "false"
            default: return jsonString(s)
            }
        case .json:
            // Server-side cast to text gives us already-valid JSON.
            return s
        default:
            return jsonString(s)
        }
    }
}
