import Foundation
import PostgresNIO

/// Clones a whole schema into a new one, with per-content-type toggles.
///
/// Everything runs inside ONE transaction on ONE pooled connection, which
/// lets us lean on `search_path` so view/matview bodies re-resolve to the
/// target schema without fragile text rewriting:
///   - **Tables**: `CREATE TABLE tgt.t (LIKE src.t INCLUDING ALL)` (columns,
///     defaults, PK/unique/indexes, checks, identity, generated, comments).
///   - **Sequences**: recreated with their parameters + `setval`; serial
///     column defaults are repointed from the source sequence to the new one.
///   - **Foreign keys**: re-added from `pg_get_constraintdef` (composite-safe).
///   - **Views / matviews**: `pg_get_viewdef` captured under
///     `search_path = src` (bare same-schema refs) then created under
///     `search_path = tgt`.
///   - **Functions / procedures**: `pg_get_functiondef`, schema-retargeted.
///
/// Not copied (v1): triggers, RLS policies, grants/ownership, and partitioning
/// (partitioned tables are skipped). The sheet states this.
enum SchemaDuplicator {
    struct Options: Sendable {
        var tableStructure = true
        var tableData = true
        var sequences = true
        var foreignKeys = true
        var views = true
        var matviews = true
        var functions = true
    }

    private static let logger = pgbrainQuietLogger

    @MainActor
    static func duplicate(from source: String, to target: String,
                          options: Options, service: ConnectionService) async -> Result<Void, Error> {
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        let op = service.operations.begin(kind: .update, summary: "Duplicate schema \(source) → \(target)")
        do {
            try await client.withTransaction(logger: logger) { c in
                try await run(c, "CREATE SCHEMA \(ident(target))")

                if options.sequences { try await copySequences(c, source, target) }
                if options.tableStructure { try await copyTables(c, source, target) }
                if options.tableStructure && options.sequences { try await repointSerialDefaults(c, source, target) }
                if options.tableStructure && options.tableData { try await copyData(c, source, target) }
                if options.functions { try await copyFunctions(c, source, target) }
                if options.views { try await copyRelations(c, source, target, relkind: "v", materialized: false, withData: false) }
                if options.matviews { try await copyRelations(c, source, target, relkind: "m", materialized: true, withData: options.tableData) }
                if options.tableStructure && options.foreignKeys { try await copyForeignKeys(c, source, target) }

                try await run(c, "SET search_path TO DEFAULT")
            }
            service.operations.finish(op, status: .succeeded)
            return .success(())
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    // MARK: - Steps

    private static func copySequences(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        let sql = """
        SELECT sequencename, data_type::text, start_value, min_value, max_value,
               increment_by, cycle, cache_size, last_value
        FROM pg_sequences WHERE schemaname = \(lit(src))
        """
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        for try await (name, type, start, minv, maxv, inc, cycle, cache, last)
            in rows.decode((String, String, Int64, Int64, Int64, Int64, Bool, Int64, Int64?).self) {
            var stmt = "CREATE SEQUENCE \(ident(tgt)).\(ident(name)) AS \(type)"
            stmt += " INCREMENT BY \(inc) MINVALUE \(minv) MAXVALUE \(maxv) START WITH \(start) CACHE \(cache)"
            if cycle { stmt += " CYCLE" }
            try await run(c, stmt)
            if let last {
                try await run(c, "SELECT setval(\(lit("\(tgt).\(name)")), \(last), true)")
            }
        }
    }

    private static func copyTables(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        for name in try await relations(c, src, relkind: "r", excludePartitions: true) {
            try await run(c, "CREATE TABLE \(ident(tgt)).\(ident(name)) (LIKE \(ident(src)).\(ident(name)) INCLUDING ALL)")
        }
    }

    /// Rewrite copied serial/identity-by-sequence defaults that still point at
    /// the SOURCE schema's sequence so they use the freshly-created one.
    private static func repointSerialDefaults(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        for name in try await relations(c, tgt, relkind: "r", excludePartitions: true) {
            let sql = """
            SELECT a.attname, pg_get_expr(ad.adbin, ad.adrelid)
            FROM pg_attrdef ad
            JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
            WHERE ad.adrelid = \(lit("\(tgt).\(name)"))::regclass
            """
            let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            var fixes: [(String, String)] = []
            for try await (col, expr) in rows.decode((String, String).self) {
                if expr.contains("\(src).") {
                    fixes.append((col, retarget(expr, from: src, to: tgt)))
                }
            }
            for (col, expr) in fixes {
                try await run(c, "ALTER TABLE \(ident(tgt)).\(ident(name)) ALTER COLUMN \(ident(col)) SET DEFAULT \(expr)")
            }
        }
    }

    private static func copyData(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        for name in try await relations(c, src, relkind: "r", excludePartitions: true) {
            let alwaysIdentity = try await scalarBool(c, """
            SELECT EXISTS (SELECT 1 FROM pg_attribute
                           WHERE attrelid = \(lit("\(src).\(name)"))::regclass AND attidentity = 'a')
            """)
            let overriding = alwaysIdentity ? " OVERRIDING SYSTEM VALUE" : ""
            try await run(c, "INSERT INTO \(ident(tgt)).\(ident(name))\(overriding) SELECT * FROM \(ident(src)).\(ident(name))")
        }
    }

    private static func copyFunctions(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        let sql = """
        SELECT pg_get_functiondef(p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = \(lit(src)) AND p.prokind IN ('f','p')
        """
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var defs: [String] = []
        for try await def in rows.decode(String.self) { defs.append(def) }
        // Bare body refs resolve to the new schema; explicit src.refs are retargeted.
        try await run(c, "SET search_path TO \(ident(tgt))")
        for def in defs { try await run(c, retarget(def, from: src, to: tgt)) }
    }

    private static func copyRelations(_ c: PostgresConnection, _ src: String, _ tgt: String,
                                      relkind: String, materialized: Bool, withData: Bool) async throws {
        let names = try await relations(c, src, relkind: relkind, excludePartitions: false)
        guard !names.isEmpty else { return }
        // Capture bodies with same-schema refs left bare…
        try await run(c, "SET search_path TO \(ident(src))")
        var bodies: [(String, String)] = []
        for name in names {
            let body = try await scalarString(c, "SELECT pg_get_viewdef(\(lit("\(src).\(name)"))::regclass, true)")
            bodies.append((name, body))
        }
        // …then create them resolving against the target schema.
        try await run(c, "SET search_path TO \(ident(tgt))")
        for (name, body) in bodies {
            if materialized {
                try await run(c, "CREATE MATERIALIZED VIEW \(ident(tgt)).\(ident(name)) AS \(body) WITH \(withData ? "DATA" : "NO DATA")")
            } else {
                try await run(c, "CREATE VIEW \(ident(tgt)).\(ident(name)) AS \(body)")
            }
        }
    }

    private static func copyForeignKeys(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        let sql = """
        SELECT t.relname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class t ON t.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = \(lit(src)) AND con.contype = 'f'
        """
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var fks: [(String, String)] = []
        for try await (tbl, def) in rows.decode((String, String).self) { fks.append((tbl, def)) }
        try await run(c, "SET search_path TO \(ident(tgt))")
        for (tbl, def) in fks {
            try await run(c, "ALTER TABLE \(ident(tgt)).\(ident(tbl)) ADD \(retarget(def, from: src, to: tgt))")
        }
    }

    // MARK: - Helpers

    private static func relations(_ c: PostgresConnection, _ schema: String,
                                  relkind: String, excludePartitions: Bool) async throws -> [String] {
        var sql = """
        SELECT cl.relname FROM pg_class cl
        JOIN pg_namespace n ON n.oid = cl.relnamespace
        WHERE n.nspname = \(lit(schema)) AND cl.relkind = \(lit(relkind))
        """
        if excludePartitions { sql += " AND cl.relispartition = false" }
        sql += " ORDER BY cl.relname"
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var out: [String] = []
        for try await name in rows.decode(String.self) { out.append(name) }
        return out
    }

    private static func scalarBool(_ c: PostgresConnection, _ sql: String) async throws -> Bool {
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        for try await v in rows.decode(Bool.self) { return v }
        return false
    }

    private static func scalarString(_ c: PostgresConnection, _ sql: String) async throws -> String {
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        for try await v in rows.decode(String.self) { return v }
        return ""
    }

    private static func run(_ c: PostgresConnection, _ sql: String) async throws {
        _ = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
    }

    /// Quote an identifier (always double-quoted for safety).
    private static func ident(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// SQL string literal.
    private static func lit(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Repoint schema-qualified references from `src.` to `tgt.` (both bare
    /// and double-quoted forms). Used on DDL fragments — constraint defs,
    /// function bodies, repointed defaults — never on table data.
    private static func retarget(_ sql: String, from src: String, to tgt: String) -> String {
        sql
            .replacingOccurrences(of: "\(src).", with: "\(tgt).")
            .replacingOccurrences(of: "\"\(src)\".", with: ident(tgt) + ".")
    }
}
