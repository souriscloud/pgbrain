import Foundation
import Logging
import PostgresNIO
import Synchronization

/// Output of a single query execution. Reuses the grid-friendly `RowsFetcher.Page`
/// shape so result blocks can render through the existing `DataGridView`.
/// `commandTag` carries libpq-style status strings ("SELECT 5", "UPDATE 12")
/// even when no rows came back, so non-SELECT statements still show useful
/// feedback in the result block header.
struct QueryResult: Sendable {
    var page: RowsFetcher.Page
    var commandTag: String?
    /// NOTICE / WARNING lines the server sent while running the statement
    /// (`RAISE NOTICE`, "relation already exists, skipping", …).
    var notices: [String] = []

    var rowsAffected: Int? {
        // commandTag is "<TAG> [oid] <count>"; the count is always the last token.
        guard let tag = commandTag, let last = tag.split(separator: " ").last,
              let n = Int(last) else { return nil }
        return n
    }
}

/// Runs ad-hoc SQL against an active `PostgresClient`. Iter-7 adds operation
/// tracking + pg_cancel_backend-driven cancellation: when a `bind` Operation
/// is passed, the runner checks out a connection from the pool, captures the
/// backend PID, and registers a cancellation handler that fires
/// `pg_cancel_backend($pid)` from a sister connection so user-clicked Cancel
/// actually stops the server-side work.
enum QueryRunner {
    static let defaultRowLimit = 1000

    /// Stringify a cell for the grid. Text-like types decode straight to
    /// `String`; numeric/bool/uuid/date types come back in binary wire format
    /// (so a bare `String` decode fails — this is why `SELECT count(*)` showed
    /// an empty cell), so we decode them to their Swift type and render. Exotic
    /// types we don't special-case fall through to nil rather than crashing.
    static func stringify(_ cell: PostgresCell) -> String? {
        guard cell.bytes != nil else { return nil }
        // Switch on type FIRST. PostgresNIO's `String` decoder has an
        // "eagerly convert anything" fallback that reads a binary int8/numeric/
        // etc. as raw bytes (→ NUL/garbage that renders blank), so we must NOT
        // try String decode before handling the binary scalar types.
        switch cell.dataType {
        case .int2:
            return (try? cell.decode(Int16.self, context: .default)).map { String($0) }
        case .int4, .oid:
            return (try? cell.decode(Int32.self, context: .default)).map { String($0) }
        case .int8:
            return (try? cell.decode(Int64.self, context: .default)).map { String($0) }
        case .float4:
            return (try? cell.decode(Float.self, context: .default)).map { String($0) }
        case .float8:
            return (try? cell.decode(Double.self, context: .default)).map { String($0) }
        case .numeric:
            return (try? cell.decode(Decimal.self, context: .default)).map { "\($0)" }
        case .bool:
            return (try? cell.decode(Bool.self, context: .default)).map { $0 ? "true" : "false" }
        case .uuid:
            return (try? cell.decode(UUID.self, context: .default))?.uuidString.lowercased()
        case .date:
            return (try? cell.decode(Date.self, context: .default)).map { dateOnlyFormatter.string(from: $0) }
        case .timestamp, .timestamptz:
            return (try? cell.decode(Date.self, context: .default)).map { timestampFormatter.string(from: $0) }
        default:
            // Text-format / textual types (text, varchar, json, jsonb, enums,
            // inet, …) — PostgresNIO's String decoder reads these correctly.
            // But its eager fallback also reads *binary* types (PostGIS
            // geometry WKB, bytea, …) as raw bytes → control-char garbage.
            // Detect that and show hex (matching `::text`) instead.
            if let s = try? cell.decode(String.self, context: .default) {
                if s.utf8.contains(where: { $0 == 0x00 || $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }) {
                    // Binary value — PostGIS geometry decodes to WKT, everything
                    // else (bytea, …) falls back to hex like `::text`.
                    return EWKB.toEWKT(cell.bytes) ?? hexEncode(cell.bytes)
                }
                return s
            }
            return EWKB.toEWKT(cell.bytes) ?? hexEncode(cell.bytes)
        }
    }

    /// Uppercase hex of a cell's raw bytes — the readable stand-in for binary
    /// values (PostGIS EWKB, bytea) that have no sensible text decode.
    private static func hexEncode(_ buffer: ByteBuffer?) -> String? {
        guard let buffer else { return nil }
        return buffer.readableBytesView.map { String(format: "%02X", $0) }.joined()
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Append a `LIMIT` to a bare top-level SELECT/WITH/VALUES that doesn't
    /// already have one, so the *server* stops producing rows instead of
    /// scanning the whole table while we only keep the first page. Fetches
    /// `cap + 1` so the caller can still detect "there's more". No-op for
    /// anything that isn't a plain read, or that already limits itself.
    static func applyAutoLimit(_ sql: String, cap: Int) -> String {
        var core = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while core.hasSuffix(";") {
            core = String(core.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let toks = SQLSafety.tokens(in: core).map { $0.lowercased() }
        guard let first = toks.first, ["select", "with", "values"].contains(first) else { return sql }
        // Already self-limiting (top-level or in a subquery) — leave it alone.
        if toks.contains("limit") || toks.contains("fetch") { return sql }
        return core + "\nLIMIT \(cap + 1)"
    }

    static func run(
        _ sql: String,
        on client: PostgresClient,
        limit: Int = defaultRowLimit,
        operationID: UUID? = nil,
        tracker: OperationsCenter? = nil,
        searchPath: String? = nil
    ) async throws -> QueryResult {
        try await client.withConnection { connection in
            // The connection must not go back to the pool while a cancel for
            // its PID is still in flight, or the cancel could hit whichever
            // caller checks it out next.
            let gate = CancelGate()
            if let opID = operationID, let tracker {
                let pid = try await OperationsHelpers.fetchBackendPID(connection, logger: pgbrainQuietLogger)
                let cancelHandler: @Sendable () async -> Void = { [weak client] in
                    guard let client else { return }
                    await gate.fire {
                        _ = try? await client.withConnection { sister in
                            _ = try await sister.query(
                                PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(pid))"),
                                logger: pgbrainQuietLogger
                            )
                        }
                    }
                }
                Task { @MainActor in
                    tracker.attachCancellation(toOperationID: opID, pid: pid, handler: cancelHandler)
                }
            }
            do {
                if let schema = searchPath {
                    // SET (without LOCAL) persists on the connection — RESET
                    // afterwards so the pool doesn't bleed it into the next checkout.
                    _ = try await connection.query(
                        PostgresQuery(unsafeSQL: "SET search_path TO \(SQLIdent.quote(schema))"),
                        logger: pgbrainQuietLogger
                    )
                }
                let result = try await runOnConnection(sql, on: connection, limit: limit)
                await gate.close()
                if searchPath != nil {
                    _ = try? await connection.query(PostgresQuery(unsafeSQL: "RESET search_path"), logger: pgbrainQuietLogger)
                }
                return result
            } catch {
                await gate.close()
                if searchPath != nil {
                    _ = try? await connection.query(PostgresQuery(unsafeSQL: "RESET search_path"), logger: pgbrainQuietLogger)
                }
                throw error
            }
        }
    }

    /// Inner runner without operation tracking — also used by the cross-DB
    /// copy path in iter-9 where the connection is checked out elsewhere.
    ///
    /// For statements classified as non-read-only by `SQLSafety` we use the
    /// materialised `EventLoopFuture`-based `query` API, which surfaces the
    /// libpq command tag ("UPDATE 12", "INSERT 0 5"). Non-SELECT statements
    /// rarely return rows so the materialisation cost is trivial.
    /// SELECTs stay on the streaming path so result sets bigger than `limit`
    /// don't get buffered.
    static func runOnConnection(
        _ sql: String,
        on connection: PostgresConnection,
        limit: Int = defaultRowLimit
    ) async throws -> QueryResult {
        let started = Date()
        let verdict = SQLSafety.classify(sql)
        if verdict != .readOnly {
            // Callback API: streams rows *and* surfaces the command tag
            // ("UPDATE 12", "INSERT 0 5"). Rows past `limit` are dropped as
            // they arrive, so a huge `INSERT … RETURNING` can't balloon memory.
            let sink = RowSink(limit: limit)
            let metadata = try await connection.query(
                PostgresQuery(unsafeSQL: sql), logger: pgbrainQuietLogger
            ) { row in sink.accept(row) }.get()
            let (columns, rows, truncated) = sink.snapshot()
            let page = RowsFetcher.Page(
                columns: columns,
                rows: rows,
                truncated: truncated,
                limit: limit, offset: 0,
                elapsed: Date().timeIntervalSince(started)
            )
            return QueryResult(page: page, commandTag: formatCommandTag(metadata))
        }

        // Bound the server's work: append LIMIT to a bare SELECT so it doesn't
        // scan an entire huge table while we only page the first `limit` rows.
        let boundedSQL = applyAutoLimit(sql, cap: limit)
        let stream = try await connection.query(PostgresQuery(unsafeSQL: boundedSQL), logger: pgbrainQuietLogger)
        var columns: [ColumnNode] = []
        var rows: [[String?]] = []
        var truncated = false
        var rowIndex = 0

        for try await row in stream {
            if columns.isEmpty {
                for cell in row {
                    columns.append(ColumnNode(
                        name: cell.columnName,
                        typeName: pgTypeName(cell.dataType),
                        nullable: true,
                        ordinal: cell.columnIndex
                    ))
                }
            }
            if rowIndex >= limit {
                truncated = true
                break
            }
            let random = PostgresRandomAccessRow(row)
            var values: [String?] = []
            values.reserveCapacity(columns.count)
            for i in 0..<columns.count {
                values.append(stringify(random[i]))
            }
            rows.append(values)
            rowIndex += 1
        }

        let elapsed = Date().timeIntervalSince(started)
        let page = RowsFetcher.Page(
            columns: columns,
            rows: rows,
            truncated: truncated,
            limit: limit, offset: 0,
            elapsed: elapsed
        )
        return QueryResult(page: page, commandTag: "SELECT \(rows.count)")
    }

    /// libpq-style tag from the parsed metadata: "UPDATE 12", "INSERT 0 5".
    private static func formatCommandTag(_ md: PostgresQueryMetadata) -> String {
        switch md.command {
        case "INSERT":
            return "INSERT \(md.oid ?? 0) \(md.rows ?? 0)"
        case "SELECT", "DELETE", "UPDATE", "MOVE", "FETCH", "COPY":
            return "\(md.command) \(md.rows ?? 0)"
        default:
            return md.command
        }
    }

    /// Truncate `sql` to a one-line preview suitable for an OperationsCenter
    /// summary or a popover row label.
    static func summary(of sql: String, max: Int = 80) -> String {
        let collapsed = sql
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > max ? String(collapsed.prefix(max)) + "…" : collapsed
    }

    fileprivate static func pgTypeName(_ type: PostgresDataType) -> String {
        switch type {
        case .bool: return "boolean"
        case .int2: return "smallint"
        case .int4: return "integer"
        case .int8: return "bigint"
        case .float4: return "real"
        case .float8: return "double precision"
        case .numeric: return "numeric"
        case .text: return "text"
        case .varchar: return "character varying"
        case .bpchar: return "character"
        case .name: return "name"
        case .uuid: return "uuid"
        case .json: return "json"
        case .jsonb: return "jsonb"
        case .date: return "date"
        case .time: return "time"
        case .timestamp: return "timestamp without time zone"
        case .timestamptz: return "timestamp with time zone"
        case .interval: return "interval"
        case .bytea: return "bytea"
        case .oid: return "oid"
        case .inet: return "inet"
        default: return "oid \(type.rawValue)"
        }
    }
}

/// Collects streamed rows from PostgresNIO's `@Sendable` row callback,
/// keeping only the first `limit`.
private final class RowSink: Sendable {
    private struct State {
        var columns: [ColumnNode] = []
        var rows: [[String?]] = []
        var truncated = false
    }
    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) { self.limit = limit }

    func accept(_ row: PostgresRow) {
        state.withLock { s in
            if s.columns.isEmpty {
                for cell in row {
                    s.columns.append(ColumnNode(
                        name: cell.columnName,
                        typeName: QueryRunner.pgTypeName(cell.dataType),
                        nullable: true,
                        ordinal: cell.columnIndex
                    ))
                }
            }
            guard s.rows.count < limit else { s.truncated = true; return }
            let random = PostgresRandomAccessRow(row)
            s.rows.append((0..<s.columns.count).map { QueryRunner.stringify(random[$0]) })
        }
    }

    func snapshot() -> ([ColumnNode], [[String?]], Bool) {
        state.withLock { ($0.columns, $0.rows, $0.truncated) }
    }
}

/// Serialises a pool-path cancel against the connection's return to the
/// pool: `fire` only runs while the statement is live, and `close` waits for
/// an in-flight cancel before the connection is released.
final class CancelGate: Sendable {
    private struct State {
        var open = true
        var inFlight: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func fire(_ action: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never>? = state.withLock { s in
            guard s.open else { return nil }
            if let existing = s.inFlight { return existing }
            let t = Task { await action() }
            s.inFlight = t
            return t
        }
        await task?.value
    }

    func close() async {
        let pending = state.withLock { s -> Task<Void, Never>? in
            s.open = false
            return s.inFlight
        }
        await pending?.value
    }
}
