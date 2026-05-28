import Foundation
import PostgresNIO

/// Read-only "first N rows" fetcher. Casts every column to text on the
/// server so the client doesn't need a type-aware decoder zoo — the grid
/// renders strings and the column metadata drives alignment/styling.
/// `NULL` survives the cast and is delivered as `String?`-nil.
enum RowsFetcher {
    struct Page: Sendable {
        let columns: [ColumnNode]   // copied from the schema snapshot
        // Mutable so iter-5 can splice in newly-applied cell edits without
        // refetching from the server.
        var rows: [[String?]]
        let truncated: Bool         // true when more rows exist past this page
        let limit: Int              // requested LIMIT (== page size)
        /// 0-based index of the first row in this page, in the
        /// underlying result set. Combined with `rows.count` it gives
        /// the inclusive range shown ("rows 200-299"), which the
        /// pager uses to render "Showing 200-299" + arrow state.
        let offset: Int
        let elapsed: TimeInterval
    }

    /// User-typed clauses spliced into the SELECT verbatim. We don't
    /// parameter-bind or sanitize these — this is a SQL tool and the
    /// expressivity of "raw WHERE" / "raw ORDER BY" is the whole point.
    /// A bad clause just round-trips to PG and the error UI surfaces it.
    struct Filter: Sendable, Equatable {
        var whereClause: String     // body only — no leading "WHERE"
        var orderByClause: String   // body only — no leading "ORDER BY"
    }

    /// Convenience for "give me the first N rows" — the cross-DB
    /// copy + early-iteration callers don't care about pagination.
    /// Routes through `page(...)` with offset 0.
    static func first(
        _ limit: Int = 1000,
        from table: TableNode,
        client: PostgresClient,
        filter: Filter = Filter(whereClause: "", orderByClause: "")
    ) async throws -> Page {
        try await page(offset: 0, pageSize: limit, from: table, client: client, filter: filter)
    }

    /// Paged fetch — `offset` rows skipped, up to `pageSize` returned.
    /// We fetch `pageSize + 1` to detect whether more pages exist
    /// (so the pager can disable/enable the Next button without an
    /// extra COUNT(*) round-trip).
    static func page(
        offset: Int,
        pageSize: Int,
        from table: TableNode,
        client: PostgresClient,
        filter: Filter = Filter(whereClause: "", orderByClause: "")
    ) async throws -> Page {
        let started = Date()
        guard !table.columns.isEmpty else {
            return Page(columns: [], rows: [], truncated: false, limit: pageSize, offset: offset, elapsed: 0)
        }
        let cappedOffset = max(0, offset)
        let cappedSize   = max(1, pageSize)

        // Build "col1"::text AS "col1", ... so column ordering is deterministic
        // even on tables where attnum has gaps.
        let projection = table.columns
            .map { "\(SQLIdent.quote($0.name))::text AS \(SQLIdent.quote($0.name))" }
            .joined(separator: ", ")
        let whereBody = filter.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderBody = filter.orderByClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereSQL = whereBody.isEmpty ? "" : " WHERE \(whereBody)"
        let orderSQL = orderBody.isEmpty ? "" : " ORDER BY \(orderBody)"
        let offsetSQL = cappedOffset > 0 ? " OFFSET \(cappedOffset)" : ""
        let sql = "SELECT \(projection) FROM \(SQLIdent.qualified(schema: table.schema, name: table.name))\(whereSQL)\(orderSQL) LIMIT \(cappedSize + 1)\(offsetSQL)"

        let stream = try await client.query(PostgresQuery(unsafeSQL: sql))

        var rows: [[String?]] = []
        var truncated = false
        let columnCount = table.columns.count
        for try await row in stream {
            if rows.count >= cappedSize {
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
            limit: cappedSize,
            offset: cappedOffset,
            elapsed: Date().timeIntervalSince(started)
        )
    }
}

