import Foundation
import PostgresNIO

/// One-shot column profiler: runs a single aggregate query over a table column
/// and returns row/null/distinct counts plus min/max (and avg for numerics).
/// Honours the tab's current WHERE clause so you profile exactly the slice
/// you're looking at.
///
/// The query always projects the same six columns — NULL-casting the ones that
/// don't apply to the column's type (min/max for json, avg for non-numerics) —
/// so the decode shape is stable regardless of type.
enum ColumnProfiler {
    struct Profile: Sendable {
        var total: Int64
        var nonNull: Int64
        var distinctCount: Int64
        var minValue: String?
        var maxValue: String?
        var avgValue: String?

        var nullCount: Int64 { max(0, total - nonNull) }
        var nullFraction: Double { total == 0 ? 0 : Double(nullCount) / Double(total) }
        var distinctFraction: Double { nonNull == 0 ? 0 : Double(distinctCount) / Double(nonNull) }
    }

    static func profile(
        schema: String,
        table: String,
        column: ColumnNode,
        extraWhere: String,
        client: PostgresClient
    ) async throws -> Profile {
        let qualifiedTable = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let col = SQLIdent.quote(column.name)
        let whereClause = extraWhere.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : " WHERE \(extraWhere)"

        let kind = ColumnTypeKind.from(typeName: column.typeName)
        // json/jsonb have no ordering operator, and Postgres has no
        // min(boolean)/max(boolean) aggregate → skip min/max for both.
        let orderable = kind != .json && kind != .bool
        let numeric = kind == .integer || kind == .number

        let minMax = orderable
            ? "min(\(col))::text AS min_val, max(\(col))::text AS max_val"
            : "NULL::text AS min_val, NULL::text AS max_val"
        let avg = numeric
            ? "avg(\(col))::numeric(38,6)::text AS avg_val"
            : "NULL::text AS avg_val"

        let sql = """
        SELECT count(*)::int8 AS total,
               count(\(col))::int8 AS non_null,
               count(DISTINCT \(col))::int8 AS distinct_count,
               \(minMax),
               \(avg)
        FROM \(qualifiedTable)\(whereClause)
        """

        let stream = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in stream.decode((Int64, Int64, Int64, String?, String?, String?).self) {
            return Profile(
                total: row.0, nonNull: row.1, distinctCount: row.2,
                minValue: row.3, maxValue: row.4, avgValue: row.5
            )
        }
        return Profile(total: 0, nonNull: 0, distinctCount: 0, minValue: nil, maxValue: nil, avgValue: nil)
    }
}
