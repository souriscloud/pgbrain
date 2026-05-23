import Foundation
import PostgresNIO

/// Fetches a single-database schema snapshot from `pg_catalog`. Two queries:
/// one for relations, one for columns, then merged in Swift. Cheaper than
/// `information_schema` and gives us `format_type()` for free.
enum SchemaFetcher {
    static func fetch(client: PostgresClient) async throws -> SchemaSnapshot {
        async let dbName = currentDatabase(client: client)
        async let relations = fetchRelations(client: client)
        async let columns = fetchColumns(client: client)
        async let pks = fetchPrimaryKeys(client: client)

        let (db, rels, cols, primaryKeys) = try await (dbName, relations, columns, pks)
        return assemble(databaseName: db, relations: rels, columns: cols, primaryKeys: primaryKeys)
    }

    private static func currentDatabase(client: PostgresClient) async throws -> String {
        let rows = try await client.query("SELECT current_database()")
        for try await name in rows.decode(String.self) {
            return name
        }
        return ""
    }

    private struct Relation: Sendable {
        let schema: String
        let name: String
        let kind: TableNode.Kind
    }

    private struct ColumnRow: Sendable {
        let schema: String
        let table: String
        let name: String
        let typeName: String
        let notNull: Bool
        let ordinal: Int
    }

    private struct PrimaryKeyRow: Sendable {
        let schema: String
        let table: String
        let columnName: String
        let position: Int  // 1-based ordinal within the PK
    }

    private static func fetchRelations(client: PostgresClient) async throws -> [Relation] {
        let sql: PostgresQuery = """
        SELECT n.nspname, c.relname, c.relkind::text
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','v','m','p')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast%'
        ORDER BY n.nspname, c.relname
        """
        let rows = try await client.query(sql)
        var out: [Relation] = []
        for try await (schema, name, relkind) in rows.decode((String, String, String).self) {
            let kind: TableNode.Kind
            switch relkind {
            case "v": kind = .view
            case "m": kind = .materializedView
            default:  kind = .table  // 'r' and 'p'
            }
            out.append(Relation(schema: schema, name: name, kind: kind))
        }
        return out
    }

    private static func fetchColumns(client: PostgresClient) async throws -> [ColumnRow] {
        let sql: PostgresQuery = """
        SELECT n.nspname,
               c.relname,
               a.attname,
               format_type(a.atttypid, a.atttypmod),
               a.attnotnull,
               a.attnum::int
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE a.attnum > 0
          AND NOT a.attisdropped
          AND c.relkind IN ('r','v','m','p')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast%'
        ORDER BY n.nspname, c.relname, a.attnum
        """
        let rows = try await client.query(sql)
        var out: [ColumnRow] = []
        for try await (schema, table, name, type, notNull, ordinal) in rows.decode((String, String, String, String, Bool, Int).self) {
            out.append(ColumnRow(schema: schema, table: table, name: name, typeName: type, notNull: notNull, ordinal: ordinal))
        }
        return out
    }

    private static func fetchPrimaryKeys(client: PostgresClient) async throws -> [PrimaryKeyRow] {
        // Walk pg_index for primary keys, then expand `indkey` (an int2vector
        // of attnums) into one row per PK column via `WITH ORDINALITY` so we
        // preserve column order across composite keys.
        let sql: PostgresQuery = """
        SELECT n.nspname,
               c.relname,
               a.attname,
               k.ord::int
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
        WHERE i.indisprimary
          AND c.relkind IN ('r','p')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast%'
        ORDER BY n.nspname, c.relname, k.ord
        """
        let rows = try await client.query(sql)
        var out: [PrimaryKeyRow] = []
        for try await (schema, table, columnName, position) in rows.decode((String, String, String, Int).self) {
            out.append(PrimaryKeyRow(schema: schema, table: table, columnName: columnName, position: position))
        }
        return out
    }

    private static func assemble(
        databaseName: String,
        relations: [Relation],
        columns: [ColumnRow],
        primaryKeys: [PrimaryKeyRow]
    ) -> SchemaSnapshot {
        // Bucket columns by (schema, table) once for O(1) lookup during merge.
        var colsByTable: [String: [ColumnNode]] = [:]
        for c in columns {
            let key = "\(c.schema)\u{1F}\(c.table)"
            colsByTable[key, default: []].append(
                ColumnNode(name: c.name, typeName: c.typeName, nullable: !c.notNull, ordinal: c.ordinal)
            )
        }

        // Bucket PK columns by (schema, table). Input is already ordered by
        // `position`, so appending preserves composite-key order.
        var pksByTable: [String: [String]] = [:]
        for pk in primaryKeys {
            let key = "\(pk.schema)\u{1F}\(pk.table)"
            pksByTable[key, default: []].append(pk.columnName)
        }

        // Group relations by schema in original (ordered) iteration.
        var schemas: [SchemaNode] = []
        var indexBySchema: [String: Int] = [:]
        for r in relations {
            let key = "\(r.schema)\u{1F}\(r.name)"
            let cols = colsByTable[key] ?? []
            let pk = pksByTable[key] ?? []
            let table = TableNode(schema: r.schema, name: r.name, kind: r.kind, columns: cols, primaryKey: pk)
            if let i = indexBySchema[r.schema] {
                schemas[i].tables.append(table)
            } else {
                indexBySchema[r.schema] = schemas.count
                schemas.append(SchemaNode(name: r.schema, tables: [table]))
            }
        }
        return SchemaSnapshot(databaseName: databaseName, schemas: schemas)
    }
}
