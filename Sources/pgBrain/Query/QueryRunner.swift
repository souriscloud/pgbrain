import Foundation
import Logging
import PostgresNIO

/// Output of a single query execution. Reuses the grid-friendly `RowsFetcher.Page`
/// shape so result blocks can render through the existing `DataGridView`.
/// `commandTag` carries libpq-style status strings ("SELECT 5", "UPDATE 12")
/// even when no rows came back, so non-SELECT statements still show useful
/// feedback in the result block header.
struct QueryResult: Sendable {
    var page: RowsFetcher.Page
    var commandTag: String?

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

    static func run(
        _ sql: String,
        on client: PostgresClient,
        limit: Int = defaultRowLimit,
        operationID: UUID? = nil,
        tracker: OperationsCenter? = nil,
        searchPath: String? = nil
    ) async throws -> QueryResult {
        try await client.withConnection { connection in
            if let opID = operationID, let tracker {
                let pid = try await OperationsHelpers.fetchBackendPID(connection, logger: pgbrainQuietLogger)
                let cancelHandler: @Sendable () async -> Void = { [weak client] in
                    guard let client else { return }
                    _ = try? await client.withConnection { sister in
                        _ = try await sister.query(
                            PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(pid))"),
                            logger: pgbrainQuietLogger
                        )
                    }
                }
                // Hop back to main to wire the op without crossing the @MainActor
                // boundary inside this nonisolated closure.
                Task { @MainActor in
                    tracker.attachCancellation(toOperationID: opID, pid: pid, handler: cancelHandler)
                }
            }
            if let schema = searchPath {
                // SET (without LOCAL) persists on the connection — we RESET
                // after the user query so the pool doesn't bleed this
                // setting into the next checkout.
                _ = try await connection.query(
                    PostgresQuery(unsafeSQL: "SET search_path TO \(SQLIdent.quote(schema))"),
                    logger: pgbrainQuietLogger
                )
            }
            do {
                let result = try await runOnConnection(sql, on: connection, limit: limit)
                if searchPath != nil {
                    _ = try? await connection.query(
                        PostgresQuery(unsafeSQL: "RESET search_path"),
                        logger: pgbrainQuietLogger
                    )
                }
                return result
            } catch {
                if searchPath != nil {
                    _ = try? await connection.query(
                        PostgresQuery(unsafeSQL: "RESET search_path"),
                        logger: pgbrainQuietLogger
                    )
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
            // Materialised path: gets command tag back via PostgresQueryResult.
            let result = try await connection
                .query(PostgresQuery(unsafeSQL: sql), logger: pgbrainQuietLogger)
                .get()
            let (columns, rows, truncated) = materialise(result.rows, limit: limit)
            let page = RowsFetcher.Page(
                columns: columns,
                rows: rows,
                truncated: truncated,
                limit: limit,
                elapsed: Date().timeIntervalSince(started)
            )
            let tag = formatCommandTag(result.metadata)
            return QueryResult(page: page, commandTag: tag)
        }

        let stream = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: pgbrainQuietLogger)
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
                let cell = random[i]
                if cell.bytes == nil {
                    values.append(nil)
                } else {
                    values.append(try? cell.decode(String.self, context: .default))
                }
            }
            rows.append(values)
            rowIndex += 1
        }

        let elapsed = Date().timeIntervalSince(started)
        let page = RowsFetcher.Page(
            columns: columns,
            rows: rows,
            truncated: truncated,
            limit: limit,
            elapsed: elapsed
        )
        return QueryResult(page: page, commandTag: "SELECT \(rows.count)")
    }

    /// Walk an already-materialised `[PostgresRow]`, decoding each cell to
    /// `String?` and rebuilding the column metadata from the first row.
    private static func materialise(_ rows: [PostgresRow], limit: Int) -> (columns: [ColumnNode], rows: [[String?]], truncated: Bool) {
        guard !rows.isEmpty else { return ([], [], false) }
        let first = rows[0]
        var columns: [ColumnNode] = []
        for cell in first {
            columns.append(ColumnNode(
                name: cell.columnName,
                typeName: pgTypeName(cell.dataType),
                nullable: true,
                ordinal: cell.columnIndex
            ))
        }
        var values: [[String?]] = []
        var truncated = false
        for (i, row) in rows.enumerated() {
            if i >= limit { truncated = true; break }
            let random = PostgresRandomAccessRow(row)
            var line: [String?] = []
            line.reserveCapacity(columns.count)
            for c in 0..<columns.count {
                let cell = random[c]
                line.append(cell.bytes == nil ? nil : try? cell.decode(String.self, context: .default))
            }
            values.append(line)
        }
        return (columns, values, truncated)
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

    private static func pgTypeName(_ type: PostgresDataType) -> String {
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
