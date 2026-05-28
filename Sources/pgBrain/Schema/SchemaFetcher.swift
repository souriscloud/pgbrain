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
        async let funcs = fetchFunctions(client: client)

        let (db, rels, cols, primaryKeys, functions) = try await (dbName, relations, columns, pks, funcs)
        return assemble(databaseName: db, relations: rels, columns: cols, primaryKeys: primaryKeys, functions: functions)
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

    /// User-defined functions/procedures via `pg_proc`. Skips anything
    /// living in `pg_catalog` / `information_schema` so we don't drown
    /// completions in built-ins. `pg_get_function_arguments` /
    /// `pg_get_function_result` give us already-pretty-printed
    /// argument and return-type strings, including DEFAULTs and
    /// `SETOF`, which matches what we'd want to surface in hover.
    private static func fetchFunctions(client: PostgresClient) async throws -> [FunctionNode] {
        let sql: PostgresQuery = """
        SELECT n.nspname,
               p.proname,
               p.prokind::text,
               pg_get_function_arguments(p.oid),
               pg_get_function_result(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND n.nspname NOT LIKE 'pg_toast%'
        ORDER BY n.nspname, p.proname
        """
        let rows = try await client.query(sql)
        var out: [FunctionNode] = []
        for try await (schema, name, kindChar, args, ret) in rows.decode((String, String, String, String, String).self) {
            let kind: FunctionNode.Kind
            switch kindChar {
            case "p": kind = .procedure
            case "a": kind = .aggregate
            case "w": kind = .window
            default:  kind = .function
            }
            out.append(FunctionNode(
                schema: schema,
                name: name,
                kind: kind,
                arguments: "(\(args))",
                returnType: ret
            ))
        }
        return out
    }

    private static func assemble(
        databaseName: String,
        relations: [Relation],
        columns: [ColumnRow],
        primaryKeys: [PrimaryKeyRow],
        functions: [FunctionNode]
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
        // Attach functions to their owning schema (or create the
        // schema entry if it had no relations).
        for f in functions {
            if let i = indexBySchema[f.schema] {
                schemas[i].functions.append(f)
            } else {
                indexBySchema[f.schema] = schemas.count
                schemas.append(SchemaNode(name: f.schema, tables: [], functions: [f]))
            }
        }
        return SchemaSnapshot(databaseName: databaseName, schemas: schemas)
    }
}
