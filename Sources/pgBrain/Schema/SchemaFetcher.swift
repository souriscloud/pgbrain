import Foundation
import PostgresNIO

/// Fetches a single-database schema snapshot from `pg_catalog`. Two queries:
/// one for relations, one for columns, then merged in Swift. Cheaper than
/// `information_schema` and gives us `format_type()` for free.
enum SchemaFetcher {
    /// Shallow schema fetch — schemas + table names + PKs + functions
    /// + FKs. **Columns are deliberately omitted** because the
    /// pg_attribute join is the single slowest piece of the catalog
    /// scan on big DBs (5k-table schemas produce ~100k attribute
    /// rows). `ConnectionService.loadSchema` runs `fetchColumnsAll`
    /// in the background after this returns to enrich every table
    /// with its column list; consumers that need columns *now* (the
    /// table opener) call `fetchColumns(for:)` for a single-table
    /// fast path.
    static func fetch(client: PostgresClient) async throws -> SchemaSnapshot {
        async let dbName = currentDatabase(client: client)
        async let relations = fetchRelations(client: client)
        async let pks = fetchPrimaryKeys(client: client)
        async let funcs = fetchFunctions(client: client)
        async let fks = fetchForeignKeys(client: client)

        let (db, rels, primaryKeys, functions, foreignKeys) =
            try await (dbName, relations, pks, funcs, fks)
        return assemble(
            databaseName: db, relations: rels, columns: [],
            primaryKeys: primaryKeys, functions: functions,
            foreignKeys: foreignKeys
        )
    }

    /// Background enrichment — runs the bulk pg_attribute query and
    /// returns column rows for every relation. Caller folds these
    /// into the existing snapshot via `merging(columns:)`.
    static func fetchColumnsAll(client: PostgresClient) async throws -> SchemaSnapshot.ColumnMap {
        let rows = try await fetchColumns(client: client)
        var map: SchemaSnapshot.ColumnMap = [:]
        for c in rows {
            let key = "\(c.schema)\u{1F}\(c.table)"
            map[key, default: []].append(
                ColumnNode(name: c.name, typeName: c.typeName, nullable: !c.notNull, ordinal: c.ordinal)
            )
        }
        return map
    }

    /// Single-table column fetch. Filtered server-side via
    /// `pg_class.oid = '<schema>.<table>'::regclass` so we don't have
    /// to filter 100k rows in Swift just to get a few dozen for the
    /// table the user is opening.
    static func fetchColumns(for schema: String, table: String, client: PostgresClient) async throws -> [ColumnNode] {
        let sql: PostgresQuery = """
        SELECT a.attname,
               format_type(a.atttypid, a.atttypmod),
               a.attnotnull,
               a.attnum::int
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(schema)
          AND c.relname = \(table)
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
        let rows = try await client.query(sql)
        var out: [ColumnNode] = []
        for try await (name, typeName, notNull, ordinal) in rows.decode((String, String, Bool, Int).self) {
            out.append(ColumnNode(name: name, typeName: typeName, nullable: !notNull, ordinal: ordinal))
        }
        return out
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

    private struct ForeignKeyRow: Sendable {
        let localSchema: String
        let localTable: String
        let localColumn: String
        let refSchema: String
        let refTable: String
        let refColumn: String
    }

    /// Single-column foreign keys via `pg_constraint`. We restrict to
    /// `array_length(conkey, 1) = 1` so multi-column FKs don't pollute
    /// the table — they'd need multi-cell navigation logic the grid
    /// doesn't have yet.
    private static func fetchForeignKeys(client: PostgresClient) async throws -> [ForeignKeyRow] {
        let sql: PostgresQuery = """
        SELECT n1.nspname,
               c1.relname,
               a1.attname,
               n2.nspname,
               c2.relname,
               a2.attname
        FROM pg_constraint con
        JOIN pg_class c1 ON c1.oid = con.conrelid
        JOIN pg_namespace n1 ON n1.oid = c1.relnamespace
        JOIN pg_attribute a1 ON a1.attrelid = con.conrelid AND a1.attnum = con.conkey[1]
        JOIN pg_class c2 ON c2.oid = con.confrelid
        JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        JOIN pg_attribute a2 ON a2.attrelid = con.confrelid AND a2.attnum = con.confkey[1]
        WHERE con.contype = 'f'
          AND array_length(con.conkey, 1) = 1
          AND n1.nspname NOT IN ('pg_catalog','information_schema')
          AND n1.nspname NOT LIKE 'pg_temp_%'
          AND n1.nspname NOT LIKE 'pg_toast%'
        ORDER BY n1.nspname, c1.relname, a1.attname
        """
        let rows = try await client.query(sql)
        var out: [ForeignKeyRow] = []
        for try await (lschema, ltable, lcol, rschema, rtable, rcol)
            in rows.decode((String, String, String, String, String, String).self) {
            out.append(ForeignKeyRow(
                localSchema: lschema, localTable: ltable, localColumn: lcol,
                refSchema: rschema, refTable: rtable, refColumn: rcol
            ))
        }
        return out
    }

    private static func assemble(
        databaseName: String,
        relations: [Relation],
        columns: [ColumnRow],
        primaryKeys: [PrimaryKeyRow],
        functions: [FunctionNode],
        foreignKeys: [ForeignKeyRow]
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

        // Bucket foreign keys by (schema, table).
        var fksByTable: [String: [ForeignKey]] = [:]
        for fk in foreignKeys {
            let key = "\(fk.localSchema)\u{1F}\(fk.localTable)"
            fksByTable[key, default: []].append(ForeignKey(
                localColumn: fk.localColumn,
                refSchema: fk.refSchema,
                refTable: fk.refTable,
                refColumn: fk.refColumn
            ))
        }

        // Group relations by schema in original (ordered) iteration.
        var schemas: [SchemaNode] = []
        var indexBySchema: [String: Int] = [:]
        for r in relations {
            let key = "\(r.schema)\u{1F}\(r.name)"
            let cols = colsByTable[key] ?? []
            let pk = pksByTable[key] ?? []
            let fks = fksByTable[key] ?? []
            let table = TableNode(schema: r.schema, name: r.name, kind: r.kind, columns: cols, primaryKey: pk, foreignKeys: fks)
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
