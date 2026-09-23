import Foundation
import PostgresNIO

/// Read-only "first N rows" fetcher. Casts every column to text on the
/// server so the client doesn't need a type-aware decoder zoo — the grid
/// renders strings and the column metadata drives alignment/styling.
/// `NULL` survives the cast and is delivered as `String?`-nil.
enum RowsFetcher {
    struct Page: Sendable {
        let columns: [ColumnNode]   // copied from the schema snapshot
        var rows: [[String?]]
        let truncated: Bool         // true when more rows exist past this page
        let limit: Int              // requested LIMIT (== page size)
        /// 0-based index of the first row in this page, in the underlying
        /// result set.
        let offset: Int
        let elapsed: TimeInterval
        /// Physical row locators (`ctid@tableoid`), aligned with `rows`, for
        /// tables edited without a primary key. Nil when rows are addressed
        /// by primary key (or not editable at all). Draft insert rows carry
        /// nil until the server hands one back.
        var rowLocators: [String?]? = nil
    }

    /// User-typed clauses spliced into the SELECT verbatim. We don't
    /// parameter-bind or sanitize these — this is a SQL tool and the
    /// expressivity of "raw WHERE" / "raw ORDER BY" is the whole point.
    /// A bad clause just round-trips to PG and the error UI surfaces it.
    struct Filter: Sendable, Equatable {
        var whereClause: String     // body only — no leading "WHERE"
        var orderByClause: String   // body only — no leading "ORDER BY"
    }

    /// How a loaded row is found again for UPDATE / DELETE.
    enum RowIdentity: Equatable, Sendable {
        case primaryKey([ColumnNode])
        /// No primary key: `ctid` plus `tableoid` (ctid alone repeats across
        /// the partitions of a partitioned table).
        case physical
        case readOnly

        static func resolve(for table: TableNode) -> RowIdentity {
            guard table.kind == .table else { return .readOnly }
            let pk = table.primaryKeyColumns
            if !table.primaryKey.isEmpty, pk.count == table.primaryKey.count {
                return .primaryKey(pk)
            }
            return table.primaryKey.isEmpty ? .physical : .readOnly
        }

        var isEditable: Bool { self != .readOnly }
    }

    /// Alias of the hidden locator column appended to physical-identity
    /// projections.
    static let locatorAlias = "__pgbrain_rowloc"
    static let locatorExpression = "(ctid::text || '@' || tableoid::oid::text)"

    /// Wraps a user WHERE body so it can be spliced anywhere: parentheses
    /// keep `a OR b` from escaping an outer `AND`, the newlines stop a
    /// trailing `-- comment` from swallowing whatever follows.
    static func isolatedWhere(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "(\n\(trimmed)\n)"
    }

    /// `col = <literal>` (or `IS NULL`) matching a value as the grid shows
    /// it. Plain `json` has no equality operator, so it compares as text.
    static func equalityPredicate(column: ColumnNode, value: String?) -> String {
        let name = SQLIdent.quote(column.name)
        guard let value else { return "\(name) IS NULL" }
        if column.typeName.lowercased() == "json" {
            return "\(name)::text = \(UpdateApplier.quoteLiteral(value))"
        }
        return "\(name) = \(UpdateApplier.typedLiteral(value, typeName: column.typeName))"
    }

    /// Convenience for "give me the first N rows".
    static func first(
        _ limit: Int = 1000,
        from table: TableNode,
        client: PostgresClient,
        filter: Filter = Filter(whereClause: "", orderByClause: "")
    ) async throws -> Page {
        try await page(offset: 0, pageSize: limit, from: table, client: client, filter: filter)
    }

    /// Planner's row-count estimate for the whole table — cheap
    /// (`pg_class.reltuples`). `nil` when the table hasn't been analyzed.
    static func estimatedRowCount(
        table: TableNode,
        client: PostgresClient
    ) async throws -> Int64? {
        let sql: PostgresQuery = """
        SELECT GREATEST(c.reltuples, 0)::bigint
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(table.schema) AND c.relname = \(table.name)
        LIMIT 1
        """
        let rows = try await client.query(sql)
        for try await v in rows.decode(Int64.self) {
            return v <= 0 ? nil : v
        }
        return nil
    }

    static func exactCountSQL(table: TableNode, filter: Filter) -> String {
        var sql = "SELECT COUNT(*)::bigint\nFROM \(SQLIdent.qualified(schema: table.schema, name: table.name))"
        let whereBody = filter.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whereBody.isEmpty { sql += "\nWHERE \(whereBody)\n" }
        return sql
    }

    /// Exact `SELECT COUNT(*)` honouring the active filter.
    static func exactRowCount(
        table: TableNode,
        client: PostgresClient,
        filter: Filter
    ) async throws -> Int64 {
        let rows = try await client.query(PostgresQuery(unsafeSQL: exactCountSQL(table: table, filter: filter)))
        for try await v in rows.decode(Int64.self) {
            return v
        }
        return 0
    }

    /// True for PostGIS geometry/geography columns. `format_type` reports these
    /// as e.g. "geometry", "geometry(Point,4326)", "geography(Point,4326)".
    static func isSpatialType(_ typeName: String) -> Bool {
        let t = typeName.lowercased()
        return t.hasPrefix("geometry") || t.hasPrefix("geography")
    }

    /// The text projection of one column, as the grid (and RETURNING
    /// clauses that splice into it) sees it. With PostGIS, spatial columns
    /// render as EWKT instead of opaque WKB hex.
    static func columnExpression(_ col: ColumnNode, spatial: Bool) -> String {
        let q = SQLIdent.quote(col.name)
        if spatial, isSpatialType(col.typeName) { return "ST_AsEWKT(\(q))" }
        return "\(q)::text"
    }

    /// `"a"::text AS "_pgb_0", …` plus the locator column for physical
    /// identity. Rows decode by position; the aliases deliberately don't
    /// reuse column names, because ORDER BY resolves a bare name to an
    /// output column first — `ORDER BY "id"` would sort the *text* copy
    /// ("10" before "9").
    static func projection(columns: [ColumnNode], spatial: Bool, identity: RowIdentity) -> String {
        var parts = columns.enumerated().map { "\(columnExpression($1, spatial: spatial)) AS \"_pgb_\($0)\"" }
        if identity == .physical {
            parts.append("\(locatorExpression) AS \(SQLIdent.quote(locatorAlias))")
        }
        return parts.joined(separator: ", ")
    }

    /// Keys that make the page order total, so OFFSET pagination neither
    /// repeats nor skips rows: the primary key, else the physical location.
    /// Views have neither and stay in whatever order the plan produces.
    static func tiebreakerOrder(for table: TableNode) -> String? {
        switch RowIdentity.resolve(for: table) {
        case .primaryKey(let cols):
            return cols.map { SQLIdent.quote($0.name) }.joined(separator: ", ")
        case .physical:
            return "tableoid, ctid"
        case .readOnly:
            return table.kind == .materializedView ? "ctid" : nil
        }
    }

    /// The paged SELECT. Every user-supplied clause sits on its own line so a
    /// trailing `-- comment` can't swallow the ORDER BY / LIMIT / OFFSET
    /// after it.
    static func pageSQL(
        table: TableNode,
        filter: Filter,
        offset: Int,
        pageSize: Int,
        spatial: Bool
    ) -> String {
        let identity = RowIdentity.resolve(for: table)
        var sql = "SELECT \(projection(columns: table.columns, spatial: spatial, identity: identity))"
        sql += "\nFROM \(SQLIdent.qualified(schema: table.schema, name: table.name))"
        let whereBody = filter.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whereBody.isEmpty { sql += "\nWHERE \(whereBody)" }
        let orderBody = filter.orderByClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let tiebreak = tiebreakerOrder(for: table)
        switch (orderBody.isEmpty, tiebreak) {
        case (false, let t?): sql += "\nORDER BY \(orderBody)\n, \(t)"
        case (false, nil):    sql += "\nORDER BY \(orderBody)"
        case (true, let t?):  sql += "\nORDER BY \(t)"
        case (true, nil):     break
        }
        sql += "\nLIMIT \(max(1, pageSize) + 1)"
        if offset > 0 { sql += "\nOFFSET \(offset)" }
        return sql
    }

    /// Paged fetch — `offset` rows skipped, up to `pageSize` returned. We
    /// fetch `pageSize + 1` to learn whether a next page exists without a
    /// COUNT(*) round-trip.
    static func page(
        offset: Int,
        pageSize: Int,
        from table: TableNode,
        client: PostgresClient,
        filter: Filter = Filter(whereClause: "", orderByClause: ""),
        spatial: Bool = false
    ) async throws -> Page {
        let started = Date()
        guard !table.columns.isEmpty else {
            return Page(columns: [], rows: [], truncated: false, limit: pageSize, offset: offset, elapsed: 0)
        }
        let cappedOffset = max(0, offset)
        let cappedSize   = max(1, pageSize)
        let identity = RowIdentity.resolve(for: table)
        let sql = pageSQL(table: table, filter: filter, offset: cappedOffset, pageSize: cappedSize, spatial: spatial)

        let stream = try await client.query(PostgresQuery(unsafeSQL: sql))

        var rows: [[String?]] = []
        var locators: [String?] = []
        var truncated = false
        let columnCount = table.columns.count
        for try await row in stream {
            try Task.checkCancellation()
            if rows.count >= cappedSize {
                truncated = true
                break
            }
            let random = PostgresRandomAccessRow(row)
            rows.append(decodeText(random, count: columnCount))
            if identity == .physical {
                locators.append(decodeText(random, at: columnCount))
            }
        }

        return Page(
            columns: table.columns,
            rows: rows,
            truncated: truncated,
            limit: cappedSize,
            offset: cappedOffset,
            elapsed: Date().timeIntervalSince(started),
            rowLocators: identity == .physical ? locators : nil
        )
    }

    static func decodeText(_ row: PostgresRandomAccessRow, count: Int) -> [String?] {
        (0..<count).map { decodeText(row, at: $0) }
    }

    static func decodeText(_ row: PostgresRandomAccessRow, at index: Int) -> String? {
        let cell = row[index]
        guard cell.bytes != nil else { return nil }
        return try? cell.decode(String.self, context: .default)
    }
}
