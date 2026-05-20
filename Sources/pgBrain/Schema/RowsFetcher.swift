import Foundation
import PostgresNIO

/// Read-only "first N rows" fetcher. Casts every column to text on the
/// server so the client doesn't need a type-aware decoder zoo — the grid
/// renders strings and the column metadata drives alignment/styling.
/// `NULL` survives the cast and is delivered as `String?`-nil.
enum RowsFetcher {
    struct Page: Sendable {
        let columns: [ColumnNode]   // copied from the schema snapshot
        let rows: [[String?]]
        let truncated: Bool         // true when limit was reached
        let limit: Int
        let elapsed: TimeInterval
    }

    static func first(
        _ limit: Int = 1000,
        from table: TableNode,
        client: PostgresClient
    ) async throws -> Page {
        let started = Date()
        guard !table.columns.isEmpty else {
            return Page(columns: [], rows: [], truncated: false, limit: limit, elapsed: 0)
        }

        // Build "col1"::text AS "col1", ... so column ordering is deterministic
        // even on tables where attnum has gaps.
        let projection = table.columns
            .map { "\(SQLIdent.quote($0.name))::text AS \(SQLIdent.quote($0.name))" }
            .joined(separator: ", ")
        let sql = "SELECT \(projection) FROM \(SQLIdent.qualified(schema: table.schema, name: table.name)) LIMIT \(limit + 1)"

        let stream = try await client.query(PostgresQuery(unsafeSQL: sql))

        // Pull rows manually; cardinality of columns is dynamic so we can't
        // use the tuple `.decode` helpers — go through `PostgresRandomAccessRow`.
        var rows: [[String?]] = []
        var truncated = false
        let columnCount = table.columns.count
        for try await row in stream {
            if rows.count >= limit {
                truncated = true
                break
            }
            let random = PostgresRandomAccessRow(row)
            var values: [String?] = []
            values.reserveCapacity(columnCount)
            for i in 0..<columnCount {
                let cell = random[i]
                if cell.bytes == nil {
                    values.append(nil)
                } else {
                    values.append(try? cell.decode(String.self, context: .default))
                }
            }
            rows.append(values)
        }

        return Page(
            columns: table.columns,
            rows: rows,
            truncated: truncated,
            limit: limit,
            elapsed: Date().timeIntervalSince(started)
        )
    }
}

