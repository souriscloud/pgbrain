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
        tracker: OperationsCenter? = nil
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
            return try await runOnConnection(sql, on: connection, limit: limit)
        }
    }

    /// Inner runner without operation tracking — also used by the cross-DB
    /// copy path in iter-9 where the connection is checked out elsewhere.
    static func runOnConnection(
        _ sql: String,
        on connection: PostgresConnection,
        limit: Int = defaultRowLimit
    ) async throws -> QueryResult {
        let started = Date()
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
        return QueryResult(page: page, commandTag: nil)
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
