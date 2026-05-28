import Foundation
import PostgresNIO

/// Database-wide size totals + biggest tables / indexes. Powers the
/// "Size dashboard" tab in the Activity panel. All sizes are bytes;
/// the UI does its own `formatSize` rendering.
struct SizeStats: Sendable {
    var databaseBytes: Int64
    var tables: [TableSize]
    var indexes: [IndexSize]

    struct TableSize: Identifiable, Sendable {
        let id: String        // schema.table
        let schema: String
        let table: String
        let totalBytes: Int64 // pg_total_relation_size — includes toast + indexes
        let tableBytes: Int64 // pg_table_size — heap + toast, no indexes
        let indexBytes: Int64 // pg_indexes_size
        let rowEstimate: Int64
    }

    struct IndexSize: Identifiable, Sendable {
        let id: String        // schema.table.index
        let schema: String
        let table: String
        let index: String
        let bytes: Int64
    }
}

@MainActor
enum SizeStatsFetcher {
    static func fetch(topN: Int = 50, client: PostgresClient) async throws -> SizeStats {
        async let total = fetchDatabaseSize(client: client)
        async let tables = fetchTopTables(limit: topN, client: client)
        async let indexes = fetchTopIndexes(limit: topN, client: client)
        return SizeStats(
            databaseBytes: try await total,
            tables: try await tables,
            indexes: try await indexes
        )
    }

    private static func fetchDatabaseSize(client: PostgresClient) async throws -> Int64 {
        let rows = try await client.query("SELECT pg_database_size(current_database())::int8")
        for try await v in rows.decode(Int64.self) { return v }
        return 0
    }

    private static func fetchTopTables(limit: Int, client: PostgresClient) async throws -> [SizeStats.TableSize] {
        let raw = """
        SELECT n.nspname,
               c.relname,
               pg_total_relation_size(c.oid)::int8,
               pg_table_size(c.oid)::int8,
               pg_indexes_size(c.oid)::int8,
               c.reltuples::int8
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','p','m')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast%'
        ORDER BY pg_total_relation_size(c.oid) DESC
        LIMIT \(limit)
        """
        let rows = try await client.query(PostgresQuery(unsafeSQL: raw))
        var out: [SizeStats.TableSize] = []
        for try await (schema, table, total, tableSize, idx, rowEst)
            in rows.decode((String, String, Int64, Int64, Int64, Int64).self) {
            out.append(SizeStats.TableSize(
                id: "\(schema).\(table)",
                schema: schema, table: table,
                totalBytes: total, tableBytes: tableSize,
                indexBytes: idx, rowEstimate: rowEst
            ))
        }
        return out
    }

    private static func fetchTopIndexes(limit: Int, client: PostgresClient) async throws -> [SizeStats.IndexSize] {
        let raw = """
        SELECT n.nspname,
               t.relname,
               i.relname,
               pg_relation_size(i.oid)::int8
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = i.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast%'
        ORDER BY pg_relation_size(i.oid) DESC
        LIMIT \(limit)
        """
        let rows = try await client.query(PostgresQuery(unsafeSQL: raw))
        var out: [SizeStats.IndexSize] = []
        for try await (schema, table, index, size)
            in rows.decode((String, String, String, Int64).self) {
            out.append(SizeStats.IndexSize(
                id: "\(schema).\(table).\(index)",
                schema: schema, table: table, index: index,
                bytes: size
            ))
        }
        return out
    }
}
