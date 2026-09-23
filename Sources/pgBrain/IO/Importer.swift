import Foundation
import NIOCore
import PostgresNIO

/// Streaming CSV / JSON importer. Rows are parsed client-side and streamed to
/// the backend via PostgresNIO's `copyFrom(table:columns:format:)` using the
/// Postgres TEXT COPY format (tab-separated, `\N` for NULL, control chars
/// escaped).
///
/// PostgresNIO's high-level `copyFrom` API doesn't expose `FORMAT csv`, so we
/// transcode client-side instead of pushing raw CSV bytes. The cost is one
/// alloc + light escape per cell — still cheap enough to saturate disk.
enum Importer {
    /// Source text encodings offered for import. Delimiters, quotes and line
    /// breaks are ASCII in all of the byte-oriented ones, so the CSV reader can
    /// split on raw bytes and decode each cell afterwards; UTF-16 is transcoded
    /// to UTF-8 up front.
    enum TextEncoding: String, CaseIterable, Identifiable, Sendable {
        case utf8, utf16, windows1250, windows1252, isoLatin1, isoLatin2

        var id: String { rawValue }
        var uiLabel: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf16: "UTF-16"
            case .windows1250: "Windows-1250 (Central European)"
            case .windows1252: "Windows-1252 (Western)"
            case .isoLatin1: "ISO-8859-1 (Latin-1)"
            case .isoLatin2: "ISO-8859-2 (Latin-2)"
            }
        }
        var foundation: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .utf16: .utf16
            case .windows1250: .windowsCP1250
            case .windows1252: .windowsCP1252
            case .isoLatin1: .isoLatin1
            case .isoLatin2: .isoLatin2
            }
        }
    }

    struct Options: Sendable {
        var hasHeader: Bool = true
        /// If true and the file has a header row, use its column order rather
        /// than the table's column order.
        var matchHeaderToColumns: Bool = true
        var delimiter: Character = ","
        /// Replace empty unquoted cells with NULL. Quoted empty strings (`""`)
        /// stay as the empty string.
        var emptyAsNull: Bool = true
        var encoding: TextEncoding = .utf8
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
        let columns = table.columns
        guard !columns.isEmpty else { throw ImportError.noColumns }
        guard let delimiter = options.delimiter.asciiValue, options.delimiter != "\"",
              options.delimiter != "\n", options.delimiter != "\r" else {
            throw ImportError.unsupportedDelimiter(String(options.delimiter))
        }

        let (stream, encoding) = try openCSVSource(source, encoding: options.encoding)
        stream.open()
        defer { stream.close() }

        let reader = CSVReader(stream: stream, delimiter: delimiter, encoding: encoding)
        let plan = try planColumns(reader: reader, columns: columns, options: options)

        let started = Date()
        var rowsImported = 0
        let bytesReadBox = ImportByteCounter()

        try await withCopy(into: table, columns: plan.copyColumns, client: client,
                           tracker: tracker, operationID: operationID) { writer in
            var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
            while true {
                try Task.checkCancellation()
                guard let row = try reader.readRecord() else { break }
                buffer.writeString(try encodeCSVRow(row, expectedCells: plan.copyColumns.count,
                                                    emptyAsNull: options.emptyAsNull, line: reader.recordLine))
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

        return Stats(
            rowsImported: rowsImported,
            bytesRead: bytesReadBox.value,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// The COPY column list, in the exact order cells appear in each CSV row.
    struct CSVColumnPlan: Equatable {
        var copyColumns: [String]
    }

    /// Consumes the header (if any) and decides the COPY column list. Values
    /// are always written in this list's order, so a header that is a subset
    /// of the table's columns, or in a different order, lines up correctly.
    static func planColumns(reader: CSVReader, columns: [ColumnNode], options: Options) throws -> CSVColumnPlan {
        var copyColumns = columns.map(\.name)
        if options.hasHeader, let header = try reader.readRecord(), options.matchHeaderToColumns {
            var seen = Set<String>()
            copyColumns = try header.map { cell in
                let name = try matchColumn(cell.text, in: columns)
                guard seen.insert(name).inserted else { throw ImportError.duplicateHeaderColumn(name) }
                return name
            }
            if copyColumns.isEmpty { throw ImportError.noColumns }
        }
        return CSVColumnPlan(copyColumns: copyColumns)
    }

    private static func matchColumn(_ raw: String, in columns: [ColumnNode]) throws -> String {
        if let c = columns.first(where: { $0.name == raw }) { return c.name }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let c = columns.first(where: { $0.name == trimmed }) { return c.name }
        throw ImportError.unknownHeaderColumn(raw)
    }

    /// One COPY-TEXT line for a parsed CSV record. Missing trailing cells
    /// become NULL; surplus cells are an error rather than silently dropped.
    static func encodeCSVRow(_ row: [CSVReader.Cell], expectedCells: Int,
                             emptyAsNull: Bool, line: Int) throws -> String {
        if row.count > expectedCells {
            throw ImportError.tooManyCells(line: line, expected: expectedCells, got: row.count)
        }
        var out = ""
        for k in 0..<expectedCells {
            if k > 0 { out += "\t" }
            let cell = k < row.count ? row[k] : nil
            if let cell, !(emptyAsNull && cell.text.isEmpty && !cell.quoted) {
                out += copyTextEscape(cell.text)
            } else {
                out += "\\N"
            }
        }
        out += "\n"
        return out
    }

    /// Opens `url` for the CSV reader. A BOM wins over the chosen encoding —
    /// it's unambiguous, and Excel writes one on "CSV UTF-8" / "Unicode text".
    static func openCSVSource(_ url: URL, encoding: TextEncoding) throws -> (InputStream, String.Encoding) {
        guard let probe = try? FileHandle(forReadingFrom: url) else { throw ImportError.openFailed(url.path) }
        let head = (try? probe.read(upToCount: 3)) ?? Data()
        try? probe.close()
        let bytes = [UInt8](head)

        if hasUTF16BOM(bytes) || encoding == .utf16 {
            guard let data = try? Data(contentsOf: url) else { throw ImportError.openFailed(url.path) }
            let text = try decodeUTF16(data)
            return (InputStream(data: Data(text.utf8)), .utf8)
        }
        guard let stream = InputStream(url: url) else { throw ImportError.openFailed(url.path) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (stream, .utf8)          // CSVReader skips the BOM itself
        }
        return (stream, encoding.foundation)
    }

    private static func hasUTF16BOM(_ b: [UInt8]) -> Bool {
        b.count >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))
    }

    /// UTF-16 with or without BOM. Without one we guess the byte order from
    /// where the zero bytes sit (ASCII-heavy data has a zero high byte).
    static func decodeUTF16(_ data: Data) throws -> String {
        var bytes = [UInt8](data)
        var enc: String.Encoding
        if bytes.starts(with: [0xFF, 0xFE]) { enc = .utf16LittleEndian; bytes.removeFirst(2) }
        else if bytes.starts(with: [0xFE, 0xFF]) { enc = .utf16BigEndian; bytes.removeFirst(2) }
        else { enc = (bytes.count >= 2 && bytes[1] == 0 && bytes[0] != 0) ? .utf16LittleEndian : .utf16BigEndian }
        guard bytes.count % 2 == 0, let s = String(bytes: bytes, encoding: enc) else {
            throw ImportError.invalidEncoding(line: nil, encoding: "UTF-16")
        }
        return s
    }

    /// BEGIN; SET LOCAL search_path; COPY …; COMMIT — with gated
    /// pg_cancel_backend wiring and ROLLBACK (or discard) on any failure.
    private static func withCopy(
        into table: TableNode, columns: [String], client: PostgresClient,
        tracker: OperationsCenter?, operationID: UUID?,
        _ body: (PostgresCopyFromWriter) async throws -> Void
    ) async throws {
        try await PooledTransaction.run(client: client, operationID: operationID, tracker: tracker) { connection in
            // PostgresNIO's `copyFrom(table:)` wraps the bare `table` in
            // double quotes — to address a schema-qualified target we set the
            // search_path, scoped to this transaction by SET LOCAL.
            _ = try await connection.query(
                PostgresQuery(unsafeSQL: copySearchPath(schema: table.schema)),
                logger: pgbrainQuietLogger
            )
            try await connection.copyFrom(
                table: table.name,
                columns: columns,
                format: .text(.init()),
                logger: pgbrainQuietLogger,
                writeData: body
            )
        }
    }

    /// pg_temp is implicitly searched *first* unless it's named, and
    /// pg_catalog first unless named — either would let a same-named temp
    /// or catalog table receive the import instead of the chosen one.
    static func copySearchPath(schema: String) -> String {
        "SET LOCAL search_path = \(SQLIdent.quote(schema)), pg_catalog, pg_temp"
    }

    /// Postgres COPY TEXT format escapes backslash, tab, newline, carriage
    /// return as `\\`, `\t`, `\n`, `\r`. NULL is `\N`, handled by callers.
    static func copyTextEscape(_ s: String) -> String {
        if !s.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            return s
        }
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        // Scalars, not Characters: "\r\n" is a single Character and would
        // otherwise slip past both the \r and \n cases unescaped.
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    enum ImportError: LocalizedError, Equatable {
        case openFailed(String)
        case noColumns
        case unknownHeaderColumn(String)
        case duplicateHeaderColumn(String)
        case unsupportedDelimiter(String)
        case invalidEncoding(line: Int?, encoding: String)
        case tooManyCells(line: Int, expected: Int, got: Int)
        case unterminatedQuote(line: Int)
        case invalidJSON(String)
        case jsonExpectsArray
        case unknownJSONKey(String)
        case jsonNoKeys

        var errorDescription: String? {
            switch self {
            case .openFailed(let path): return "Couldn't open \(path) for reading."
            case .noColumns: return "Target table has no columns."
            case .unknownHeaderColumn(let name):
                return "CSV header column \"\(name)\" doesn't match any column in the target table."
            case .duplicateHeaderColumn(let name):
                return "CSV header names column \"\(name)\" more than once."
            case .unsupportedDelimiter(let d):
                return "Delimiter \"\(d)\" isn't supported — use a single ASCII character other than a quote or line break."
            case .invalidEncoding(let line, let enc):
                let at = line.map { " on line \($0)" } ?? ""
                return "File isn't valid \(enc)\(at). Pick the file's real encoding in the import options."
            case .tooManyCells(let line, let expected, let got):
                return "Line \(line) has \(got) values but \(expected) column\(expected == 1 ? "" : "s") are expected."
            case .unterminatedQuote(let line):
                return "Quoted value starting on line \(line) is never closed."
            case .invalidJSON(let why): return "File isn't valid JSON: \(why)"
            case .jsonExpectsArray: return "Top-level JSON must be an array of objects."
            case .unknownJSONKey(let name):
                return "JSON key \"\(name)\" doesn't match any column in the target table."
            case .jsonNoKeys: return "JSON objects have no keys to import."
            }
        }
    }

    /// JSON importer — reads an array of objects, maps each object's keys to
    /// table columns (1:1, name-matched), and streams them through the same
    /// TEXT-format COPY path the CSV importer uses. Only keys present in the
    /// file are copied, so absent columns get their DEFAULT. Numbers keep
    /// their exact source text (bigint > 2^53, numeric/money precision), and
    /// nested objects/arrays land as compact JSON for json/jsonb columns.
    static func importJSON(
        into table: TableNode,
        from source: URL,
        client: PostgresClient,
        encoding: TextEncoding = .utf8,
        tracker: OperationsCenter? = nil,
        operationID: UUID? = nil
    ) async throws -> Stats {
        let started = Date()
        guard let data = try? Data(contentsOf: source) else {
            throw ImportError.openFailed(source.path)
        }
        let (copyColumns, lines) = try jsonCopyPlan(data: data, encoding: encoding, columns: table.columns)
        guard !lines.isEmpty else {
            return Stats(rowsImported: 0, bytesRead: data.count, elapsed: Date().timeIntervalSince(started))
        }

        try await withCopy(into: table, columns: copyColumns, client: client,
                           tracker: tracker, operationID: operationID) { writer in
            var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
            for line in lines {
                try Task.checkCancellation()
                buffer.writeString(line)
                if buffer.readableBytes >= 64 * 1024 {
                    try await writer.write(buffer)
                    buffer.clear()
                }
            }
            if buffer.readableBytes > 0 {
                try await writer.write(buffer)
            }
        }
        return Stats(
            rowsImported: lines.count,
            bytesRead: data.count,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// Pure half of the JSON import: parse, validate keys, and render each
    /// object as a COPY-TEXT line over the returned column list.
    static func jsonCopyPlan(data: Data, encoding: TextEncoding, columns: [ColumnNode]) throws -> ([String], [String]) {
        guard !columns.isEmpty else { throw ImportError.noColumns }
        let utf8 = try jsonUTF8Bytes(data, encoding: encoding)
        let parsed = try LosslessJSON.parse(utf8)
        guard case .array(let items) = parsed else { throw ImportError.jsonExpectsArray }
        var objects: [[String: LosslessJSON.Value]] = []
        objects.reserveCapacity(items.count)
        var keysSeen = Set<String>()
        for item in items {
            guard case .object(let pairs) = item else { throw ImportError.jsonExpectsArray }
            var obj: [String: LosslessJSON.Value] = [:]
            for pair in pairs {
                let k = pair.key
                if !keysSeen.contains(k) {
                    guard columns.contains(where: { $0.name == k }) else { throw ImportError.unknownJSONKey(k) }
                    keysSeen.insert(k)
                }
                obj[k] = pair.value
            }
            objects.append(obj)
        }
        guard !objects.isEmpty else { return ([], []) }
        let copyColumns = columns.map(\.name).filter { keysSeen.contains($0) }
        guard !copyColumns.isEmpty else { throw ImportError.jsonNoKeys }
        let lines = objects.map { obj -> String in
            var line = ""
            for (i, name) in copyColumns.enumerated() {
                if i > 0 { line += "\t" }
                if let v = obj[name], let text = jsonCellText(v) {
                    line += copyTextEscape(text)
                } else {
                    line += "\\N"
                }
            }
            return line + "\n"
        }
        return (copyColumns, lines)
    }

    private static func jsonUTF8Bytes(_ data: Data, encoding: TextEncoding) throws -> [UInt8] {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3); return bytes }
        if hasUTF16BOM(bytes) || encoding == .utf16 { return Array(try decodeUTF16(data).utf8) }
        if encoding == .utf8 {
            guard String(bytes: bytes, encoding: .utf8) != nil else {
                throw ImportError.invalidEncoding(line: nil, encoding: "UTF-8")
            }
            return bytes
        }
        guard let s = String(bytes: bytes, encoding: encoding.foundation) else {
            throw ImportError.invalidEncoding(line: nil, encoding: encoding.uiLabel)
        }
        return Array(s.utf8)
    }

    /// Text form of a JSON value for COPY-TEXT; `nil` means SQL NULL.
    static func jsonCellText(_ value: LosslessJSON.Value) -> String? {
        switch value {
        case .null: return nil
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let raw): return raw
        case .array, .object: return LosslessJSON.serialize(value)
        }
    }
}

/// Minimal RFC 8259 parser that keeps numbers as their exact source text and
/// object keys in source order. `JSONSerialization` bridges through NSNumber,
/// which turns 0/1 into booleans in some paths and rounds integers past 2^53.
enum LosslessJSON {
    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case number(String)
        case string(String)
        case array([Value])
        case object([Pair])
    }
    struct Pair: Equatable {
        let key: String
        let value: Value
        init(_ key: String, _ value: Value) { self.key = key; self.value = value }
    }

    static func parse(_ bytes: [UInt8]) throws -> Value {
        var p = Parser(b: bytes)
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        guard p.i == bytes.count else { throw p.fail("unexpected trailing content") }
        return v
    }

    static func serialize(_ v: Value) -> String {
        var out = ""
        write(v, into: &out)
        return out
    }

    private static func write(_ v: Value, into out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let raw): out += raw
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                writeString(pair.key, into: &out)
                out += ":"
                write(pair.value, into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
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
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        static let maxDepth = 512

        func fail(_ why: String) -> Importer.ImportError {
            .invalidJSON("\(why) at byte \(i)")
        }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth < Self.maxDepth else { throw fail("nesting too deep") }
            guard i < b.count else { throw fail("unexpected end of input") }
            switch b[i] {
            case 0x7B: return try object(depth: depth)
            case 0x5B: return try array(depth: depth)
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            case 0x2D, 0x30...0x39: return .number(try number())
            default: throw fail("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw fail("invalid literal") }
            i += w.count
        }

        mutating func object(depth: Int) throws -> Value {
            i += 1
            var pairs: [Pair] = []
            skipWS()
            if i < b.count, b[i] == 0x7D { i += 1; return .object(pairs) }
            while true {
                skipWS()
                guard i < b.count, b[i] == 0x22 else { throw fail("expected object key") }
                let key = try string()
                skipWS()
                guard i < b.count, b[i] == 0x3A else { throw fail("expected ':'") }
                i += 1
                skipWS()
                pairs.append(Pair(key, try value(depth: depth + 1)))
                skipWS()
                guard i < b.count else { throw fail("unterminated object") }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x7D { i += 1; return .object(pairs) }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> Value {
            i += 1
            var items: [Value] = []
            skipWS()
            if i < b.count, b[i] == 0x5D { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value(depth: depth + 1))
                skipWS()
                guard i < b.count else { throw fail("unterminated array") }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x5D { i += 1; return .array(items) }
                throw fail("expected ',' or ']'")
            }
        }

        mutating func number() throws -> String {
            let start = i
            func digits() -> Int {
                let s = i
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
                return i - s
            }
            if b[i] == 0x2D { i += 1 }
            guard i < b.count else { throw fail("invalid number") }
            if b[i] == 0x30 { i += 1 } else if digits() == 0 { throw fail("invalid number") }
            if i < b.count, b[i] == 0x2E {
                i += 1
                guard digits() > 0 else { throw fail("invalid number") }
            }
            if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
                i += 1
                if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
                guard digits() > 0 else { throw fail("invalid number") }
            }
            return String(decoding: b[start..<i], as: UTF8.self)
        }

        mutating func string() throws -> String {
            i += 1
            var bytes: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == 0x22 {
                    i += 1
                    guard let s = String(bytes: bytes, encoding: .utf8) else { throw fail("invalid UTF-8 in string") }
                    return s
                }
                if c < 0x20 { throw fail("control character in string") }
                if c != 0x5C { bytes.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { break }
                let e = b[i]
                i += 1
                switch e {
                case 0x22: bytes.append(0x22)
                case 0x5C: bytes.append(0x5C)
                case 0x2F: bytes.append(0x2F)
                case 0x62: bytes.append(0x08)
                case 0x66: bytes.append(0x0C)
                case 0x6E: bytes.append(0x0A)
                case 0x72: bytes.append(0x0D)
                case 0x74: bytes.append(0x09)
                case 0x75:
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail("invalid surrogate pair") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw fail("invalid \\u escape") }
                    bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw fail("invalid escape")
                }
            }
            throw fail("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw fail("invalid \\u escape")
            }
            i += 4
            return v
        }
    }
}

/// Mutable byte-count box used to communicate `bytesRead` out of the import
/// closure without making `Stats` mutable across an actor hop.
private final class ImportByteCounter: @unchecked Sendable {
    private(set) var value: Int = 0
    func set(_ v: Int) { value = v }
}

/// RFC 4180-style CSV reader over an `InputStream`, so memory stays flat
/// regardless of file size. Splits on raw bytes (delimiter, quote and line
/// breaks are ASCII in every supported encoding) and decodes each cell with
/// the source encoding, failing loudly on bytes that aren't valid in it.
final class CSVReader: @unchecked Sendable {
    struct Cell: Equatable {
        var text: String
        /// The cell was written as `"…"` — distinguishes `""` from an empty field.
        var quoted: Bool
    }

    private let stream: InputStream
    private let delimiter: UInt8
    private let encoding: String.Encoding
    private var buffer: [UInt8] = []
    private var bufIdx = 0
    private(set) var bytesRead = 0
    private let readChunk = 32 * 1024
    private var line = 1
    private var atStart = true
    /// 1-based line on which the most recently returned record started.
    private(set) var recordLine = 0

    init(stream: InputStream, delimiter: UInt8, encoding: String.Encoding = .utf8) {
        self.stream = stream
        self.delimiter = delimiter
        self.encoding = encoding
    }

    /// Next non-blank record, or `nil` at end of input.
    func readRecord() throws -> [Cell]? {
        if atStart {
            atStart = false
            if encoding == .utf8, peek() == 0xEF, peek(1) == 0xBB, peek(2) == 0xBF { bufIdx += 3 }
        }
        while true {
            guard peek() != nil else { return nil }
            let startLine = line
            let cells = try readRawRecord()
            if cells.count == 1, cells[0].isEmpty, !cells[0].quoted { continue }   // blank line
            recordLine = startLine
            return try cells.map { raw in
                guard let text = raw.isEmpty ? "" : String(bytes: raw.bytes, encoding: encoding) else {
                    throw Importer.ImportError.invalidEncoding(line: startLine, encoding: encodingName)
                }
                return Cell(text: text, quoted: raw.quoted)
            }
        }
    }

    private var encodingName: String {
        Importer.TextEncoding.allCases.first { $0.foundation == encoding }?.uiLabel ?? "\(encoding)"
    }

    private struct RawCell {
        var bytes: [UInt8] = []
        var quoted = false
        var isEmpty: Bool { bytes.isEmpty }
    }

    private func readRawRecord() throws -> [RawCell] {
        var cells: [RawCell] = []
        var current = RawCell()
        var inQuotes = false
        var fieldStart = true
        let quoteLine = line

        while let byte = peek() {
            bufIdx += 1
            if inQuotes {
                if byte == 0x22 {
                    if peek() == 0x22 {
                        current.bytes.append(0x22)
                        bufIdx += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if byte == 0x0A { line += 1 }
                    current.bytes.append(byte)
                }
                continue
            }
            if byte == 0x22, fieldStart {
                inQuotes = true
                current.quoted = true
                fieldStart = false
                continue
            }
            if byte == delimiter {
                cells.append(current)
                current = RawCell()
                fieldStart = true
                continue
            }
            if byte == 0x0A || byte == 0x0D {
                if byte == 0x0D, peek() == 0x0A { bufIdx += 1 }
                line += 1
                cells.append(current)
                return cells
            }
            fieldStart = false
            current.bytes.append(byte)
        }
        if inQuotes { throw Importer.ImportError.unterminatedQuote(line: quoteLine) }
        cells.append(current)
        return cells
    }

    private func peek(_ ahead: Int = 0) -> UInt8? {
        while bufIdx + ahead >= buffer.count {
            if !refill() { return nil }
        }
        return buffer[bufIdx + ahead]
    }

    /// Appends the next chunk (keeping unread bytes so multi-byte lookahead
    /// works across chunk boundaries). Returns false at end of stream.
    private func refill() -> Bool {
        if bufIdx > 0 {
            buffer.removeFirst(bufIdx)
            bufIdx = 0
        }
        var chunk = [UInt8](repeating: 0, count: readChunk)
        let n = chunk.withUnsafeMutableBufferPointer { ptr in
            stream.read(ptr.baseAddress!, maxLength: readChunk)
        }
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        bytesRead += n
        return true
    }
}
