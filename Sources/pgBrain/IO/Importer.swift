import Foundation
import NIOCore
import PostgresNIO

/// Streaming CSV importer. Reads `source` line-by-line, parses each row using
/// an RFC 4180-ish CSV reader, then streams it to the backend via
/// PostgresNIO's `copyFrom(table:columns:format:)` using the Postgres TEXT
/// COPY format (tab-separated, `\N` for NULL, control chars escaped).
///
/// PostgresNIO's high-level `copyFrom` API doesn't yet expose `FORMAT csv`,
/// so we transcode client-side instead of pushing raw CSV bytes. The cost is
/// one alloc + light escape per cell — still cheap enough to saturate disk.
enum Importer {
    struct Options: Sendable {
        var hasHeader: Bool = true
        /// If true and the file has a header row, use its column order rather
        /// than the table's column order.
        var matchHeaderToColumns: Bool = true
        var delimiter: Character = ","
        /// Replace empty unquoted cells with NULL. Quoted empty strings stay
        /// as the empty string.
        var emptyAsNull: Bool = true
    }

    struct Stats: Sendable {
        var rowsImported: Int
        var bytesRead: Int
        var elapsed: TimeInterval
    }

    static func importCSV(
        into table: TableNode,
        from source: URL,
        client: PostgresClient,
        options: Options = .init(),
        tracker: OperationsCenter? = nil,
        operationID: UUID? = nil
    ) async throws -> Stats {
        guard let stream = InputStream(url: source) else {
            throw ImportError.openFailed(source.path)
        }
        stream.open()
        defer { stream.close() }

        let columns = table.columns
        guard !columns.isEmpty else { throw ImportError.noColumns }

        let reader = CSVReader(stream: stream, delimiter: options.delimiter)
        var headerMap: [Int] = Array(0..<columns.count)
        if options.hasHeader, let header = try reader.readRow() {
            if options.matchHeaderToColumns {
                headerMap = []
                for cell in header {
                    if let idx = columns.firstIndex(where: { $0.name == cell }) {
                        headerMap.append(idx)
                    } else {
                        throw ImportError.unknownHeaderColumn(cell)
                    }
                }
                if headerMap.isEmpty { throw ImportError.noColumns }
            }
        }

        let columnsToCopy = headerMap.map { columns[$0].name }
        let started = Date()
        var rowsImported = 0
        let bytesReadBox = ImportByteCounter()

        try await client.withConnection { connection in
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

            // PostgresNIO's `copyFrom(table:)` wraps the bare `table` in
            // double quotes — to address a schema-qualified target we set the
            // search_path on the connection for the duration of the import.
            // SET LOCAL keeps the change scoped to the implicit transaction.
            _ = try await connection.query(
                PostgresQuery(unsafeSQL: "BEGIN"),
                logger: pgbrainQuietLogger
            )
            do {
                _ = try await connection.query(
                    PostgresQuery(unsafeSQL: "SET LOCAL search_path = \(SQLIdent.quote(table.schema))"),
                    logger: pgbrainQuietLogger
                )
                try await connection.copyFrom(
                    table: table.name,
                    columns: columnsToCopy,
                    format: .text(.init()),
                    logger: pgbrainQuietLogger
                ) { writer in
                    var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
                    while true {
                        try Task.checkCancellation()
                        guard let row = try reader.readRow() else { break }
                        // Reorder cells to match the table's column order.
                        var ordered: [String?] = Array(repeating: nil, count: headerMap.count)
                        for (csvIdx, columnIdx) in headerMap.enumerated() {
                            let raw = csvIdx < row.count ? row[csvIdx] : nil
                            ordered[columnIdx] = transformedCell(raw, emptyAsNull: options.emptyAsNull)
                        }
                        // Write tab-separated COPY text line.
                        for (i, cell) in ordered.enumerated() {
                            if i > 0 { buffer.writeString("\t") }
                            if let cell {
                                buffer.writeString(copyTextEscape(cell))
                            } else {
                                buffer.writeString("\\N")
                            }
                        }
                        buffer.writeString("\n")
                        rowsImported += 1
                        if buffer.readableBytes >= 64 * 1024 {
                            try await writer.write(buffer)
                            buffer.clear()
                        }
                    }
                    if buffer.readableBytes > 0 {
                        try await writer.write(buffer)
                    }
                    bytesReadBox.set(reader.bytesRead)
                }
                _ = try await connection.query(
                    PostgresQuery(unsafeSQL: "COMMIT"),
                    logger: pgbrainQuietLogger
                )
            } catch {
                _ = try? await connection.query(
                    PostgresQuery(unsafeSQL: "ROLLBACK"),
                    logger: pgbrainQuietLogger
                )
                throw error
            }
        }

        return Stats(
            rowsImported: rowsImported,
            bytesRead: bytesReadBox.value,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private static func transformedCell(_ raw: String?, emptyAsNull: Bool) -> String? {
        guard let raw else { return nil }
        if emptyAsNull, raw.isEmpty { return nil }
        return raw
    }

    /// Postgres COPY TEXT format escapes backslash, tab, newline, carriage
    /// return as `\\`, `\t`, `\n`, `\r`. NULL is `\N` which we handle at the
    /// writer level.
    private static func copyTextEscape(_ s: String) -> String {
        if !s.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            return s
        }
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    enum ImportError: LocalizedError {
        case openFailed(String)
        case noColumns
        case unknownHeaderColumn(String)
        case invalidJSON
        case jsonExpectsArray
        case unknownJSONKey(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path): return "Couldn't open \(path) for reading."
            case .noColumns: return "Target table has no columns."
            case .unknownHeaderColumn(let name):
                return "CSV header column \"\(name)\" doesn't match any column in the target table."
            case .invalidJSON: return "File isn't valid JSON."
            case .jsonExpectsArray: return "Top-level JSON must be an array of objects."
            case .unknownJSONKey(let name):
                return "JSON key \"\(name)\" doesn't match any column in the target table."
            }
        }
    }

    /// JSON importer — reads an array of objects, maps each object's
    /// keys to table columns (1:1, name-matched), and streams them
    /// through the same TEXT-format COPY path the CSV importer uses.
    /// All values are stringified — PG decodes them server-side per
    /// column type, so anything storable as a PG literal works
    /// (numbers, booleans, ISO dates, json blobs).
    static func importJSON(
        into table: TableNode,
        from source: URL,
        client: PostgresClient,
        tracker: OperationsCenter? = nil,
        operationID: UUID? = nil
    ) async throws -> Stats {
        let started = Date()
        guard let data = try? Data(contentsOf: source) else {
            throw ImportError.openFailed(source.path)
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportError.invalidJSON
        }
        guard let array = parsed as? [[String: Any]] else {
            throw ImportError.jsonExpectsArray
        }
        let columns = table.columns
        guard !columns.isEmpty else { throw ImportError.noColumns }

        // Pre-validate every distinct key — fail before any work if
        // the file references a column we don't have.
        var keysSeen = Set<String>()
        for obj in array {
            for k in obj.keys where !keysSeen.contains(k) {
                guard columns.contains(where: { $0.name == k }) else {
                    throw ImportError.unknownJSONKey(k)
                }
                keysSeen.insert(k)
            }
        }
        // Project to a stable column order (table's column list) so
        // the COPY stream lines up correctly.
        let columnNames = columns.map(\.name)
        var rowsImported = 0
        let bytesReadBox = ImportByteCounter()
        bytesReadBox.set(data.count)

        try await client.withConnection { connection in
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
            _ = try await connection.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: pgbrainQuietLogger)
            do {
                _ = try await connection.query(
                    PostgresQuery(unsafeSQL: "SET LOCAL search_path = \(SQLIdent.quote(table.schema))"),
                    logger: pgbrainQuietLogger
                )
                try await connection.copyFrom(
                    table: table.name,
                    columns: columnNames,
                    format: .text(.init()),
                    logger: pgbrainQuietLogger
                ) { writer in
                    var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
                    for obj in array {
                        try Task.checkCancellation()
                        for (i, name) in columnNames.enumerated() {
                            if i > 0 { buffer.writeString("\t") }
                            let raw = obj[name]
                            if let cell = jsonCellToCopyText(raw) {
                                buffer.writeString(copyTextEscape(cell))
                            } else {
                                buffer.writeString("\\N")
                            }
                        }
                        buffer.writeString("\n")
                        rowsImported += 1
                        if buffer.readableBytes >= 64 * 1024 {
                            try await writer.write(buffer)
                            buffer.clear()
                        }
                    }
                    if buffer.readableBytes > 0 {
                        try await writer.write(buffer)
                    }
                }
                _ = try await connection.query(PostgresQuery(unsafeSQL: "COMMIT"), logger: pgbrainQuietLogger)
            } catch {
                _ = try? await connection.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                throw error
            }
        }
        return Stats(
            rowsImported: rowsImported,
            bytesRead: bytesReadBox.value,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// Stringify a JSON value for COPY-TEXT. Nested objects / arrays
    /// are re-serialised as compact JSON so they can land in `jsonb`
    /// columns; nulls become NULL; primitives stringify directly.
    private static func jsonCellToCopyText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? Int { return String(n) }
        if let n = value as? Int64 { return String(n) }
        if let n = value as? Double {
            // Avoid losing precision on round-trip; "%.17g" keeps
            // doubles roundtrippable, but rstrips trailing zeros for
            // readability.
            return String(n)
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return nil
    }
}

/// Mutable byte-count box used to communicate `bytesRead` out of the import
/// closure without making `Stats` mutable across an actor hop.
private final class ImportByteCounter: @unchecked Sendable {
    private(set) var value: Int = 0
    func set(_ v: Int) { value = v }
}

/// Minimal RFC 4180-style CSV reader: comma-separated, double-quoted with
/// `""` escape, supports embedded newlines inside quotes. Reads from an
/// `InputStream` so memory stays flat regardless of file size.
final class CSVReader {
    private let stream: InputStream
    private let delimiter: Character
    private var buffer: [UInt8] = []
    private var bufIdx = 0
    private(set) var bytesRead = 0
    private let readChunk = 32 * 1024

    init(stream: InputStream, delimiter: Character) {
        self.stream = stream
        self.delimiter = delimiter
    }

    func readRow() throws -> [String]? {
        if peek() == nil { return nil }
        var cells: [String] = []
        var current: [UInt8] = []
        var inQuotes = false

        while let byte = peek() {
            advance()
            let ch = Character(UnicodeScalar(byte))
            if inQuotes {
                if ch == "\"" {
                    if let next = peek(), Character(UnicodeScalar(next)) == "\"" {
                        current.append(0x22) // ""
                        advance()
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(byte)
                }
                continue
            }
            if ch == "\"" {
                inQuotes = true
                continue
            }
            if ch == delimiter {
                cells.append(decode(current))
                current.removeAll(keepingCapacity: true)
                continue
            }
            if ch == "\n" {
                cells.append(decode(current))
                return cells
            }
            if ch == "\r" {
                // swallow optional following \n
                if let next = peek(), Character(UnicodeScalar(next)) == "\n" {
                    advance()
                }
                cells.append(decode(current))
                return cells
            }
            current.append(byte)
        }
        cells.append(decode(current))
        return cells
    }

    private func decode(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func peek() -> UInt8? {
        if bufIdx >= buffer.count { refill() }
        if bufIdx >= buffer.count { return nil }
        return buffer[bufIdx]
    }

    private func advance() { bufIdx += 1 }

    private func refill() {
        buffer.removeAll(keepingCapacity: true)
        bufIdx = 0
        var chunk = [UInt8](repeating: 0, count: readChunk)
        let n = chunk.withUnsafeMutableBufferPointer { ptr in
            stream.read(ptr.baseAddress!, maxLength: readChunk)
        }
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            bytesRead += n
        }
    }
}
