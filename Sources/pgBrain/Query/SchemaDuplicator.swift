import Foundation
import PostgresNIO

/// Clones a whole schema into a new one, with per-content-type toggles.
///
/// The structural clone runs inside ONE transaction on ONE pooled connection,
/// which lets us lean on `search_path` so view/matview/trigger/policy bodies
/// re-resolve to the target schema without fragile text rewriting:
///   - **Tables**: `CREATE TABLE tgt.t (LIKE src.t INCLUDING ALL)`; partitioned
///     parents get `PARTITION BY …` and their partitions are re-attached.
///   - **Sequences**: recreated with parameters + `setval`; serial defaults repointed.
///   - **Foreign keys / triggers**: re-added from `pg_get_constraintdef` /
///     `pg_get_triggerdef` (composite-safe).
///   - **RLS**: row-security re-enabled and policies recreated from `pg_policies`.
///   - **Views / matviews**: `pg_get_viewdef` captured under `search_path = src`,
///     created under `search_path = tgt`.
///   - **Functions / procedures**: `pg_get_functiondef`, schema-retargeted.
///
/// **Ownership + grants** run in a SEPARATE best-effort pass AFTER the clone
/// commits, so a privilege the current role can't set never rolls back the
/// clone. Not copied: extensions, and multi-level (sub-)partitioning beyond one
/// level. The sheet states this.
enum SchemaDuplicator {
    struct Options: Sendable {
        var tableStructure = true
        var tableData = true
        var sequences = true
        var foreignKeys = true
        var views = true
        var matviews = true
        var functions = true
        var triggers = true
        var policies = true            // row-level security
        var privileges = false         // ownership + grants (best-effort, post-commit)
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
                if options.views { try await copyViews(c, source, target, materialized: false, withData: false) }
                if options.matviews { try await copyViews(c, source, target, materialized: true, withData: options.tableData) }
                if options.tableStructure && options.foreignKeys { try await copyForeignKeys(c, source, target) }
                if options.tableStructure && options.triggers { try await copyTriggers(c, source, target) }
                if options.tableStructure && options.policies { try await copyPolicies(c, source, target) }
                try await run(c, "SET search_path TO DEFAULT")
            }
            // Privileges are intentionally outside the transaction: best-effort,
            // each statement independent, failures swallowed.
            if options.privileges { await copyPrivileges(client, source, target) }
            service.operations.finish(op, status: .succeeded)
            return .success(())
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    // MARK: - Sequences

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

    // MARK: - Tables (incl. single-level partitioning)

    private static func copyTables(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        // 1. Partitioned parents — copy columns via LIKE + carry the partition key.
        for name in try await relations(c, src, relkind: "p", excludePartitions: false) {
            let partkey = try await scalarString(c, "SELECT pg_get_partkeydef(\(lit("\(src).\(name)"))::regclass)")
            try await run(c, "CREATE TABLE \(ident(tgt)).\(ident(name)) (LIKE \(ident(src)).\(ident(name)) INCLUDING ALL) PARTITION BY \(partkey)")
        }
        // 2. Partition leaves — re-attach with their original bound.
        for (name, parent, bound) in try await partitionLeaves(c, src) {
            try await run(c, "CREATE TABLE \(ident(tgt)).\(ident(name)) PARTITION OF \(ident(tgt)).\(ident(parent)) \(bound)")
        }
        // 3. Plain tables.
        for name in try await relations(c, src, relkind: "r", excludePartitions: true) {
            try await run(c, "CREATE TABLE \(ident(tgt)).\(ident(name)) (LIKE \(ident(src)).\(ident(name)) INCLUDING ALL)")
        }
    }

    private static func repointSerialDefaults(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        var tables = try await relations(c, tgt, relkind: "r", excludePartitions: true)
        tables += try await relations(c, tgt, relkind: "p", excludePartitions: false)
        for name in tables {
            let sql = """
            SELECT a.attname, pg_get_expr(ad.adbin, ad.adrelid)
            FROM pg_attrdef ad
            JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
            WHERE ad.adrelid = \(lit("\(tgt).\(name)"))::regclass
            """
            let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            var fixes: [(String, String)] = []
            for try await (col, expr) in rows.decode((String, String).self) where expr.contains("\(src).") {
                fixes.append((col, retarget(expr, from: src, to: tgt)))
            }
            for (col, expr) in fixes {
                try await run(c, "ALTER TABLE \(ident(tgt)).\(ident(name)) ALTER COLUMN \(ident(col)) SET DEFAULT \(expr)")
            }
        }
    }

    private static func copyData(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        // Plain tables + partition leaves (NOT partitioned parents — leaves hold the rows).
        for name in try await relations(c, src, relkind: "r", excludePartitions: false) {
            let alwaysIdentity = try await scalarBool(c, """
            SELECT EXISTS (SELECT 1 FROM pg_attribute
                           WHERE attrelid = \(lit("\(src).\(name)"))::regclass AND attidentity = 'a')
            """)
            let overriding = alwaysIdentity ? " OVERRIDING SYSTEM VALUE" : ""
            try await run(c, "INSERT INTO \(ident(tgt)).\(ident(name))\(overriding) SELECT * FROM \(ident(src)).\(ident(name))")
        }
    }

    // MARK: - Functions / views / FKs / triggers / policies

    private static func copyFunctions(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        let sql = """
        SELECT pg_get_functiondef(p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = \(lit(src)) AND p.prokind IN ('f','p')
        """
        let defs = try await strings(c, sql)
        try await run(c, "SET search_path TO \(ident(tgt))")
        for def in defs { try await run(c, retarget(def, from: src, to: tgt)) }
    }

    private static func copyViews(_ c: PostgresConnection, _ src: String, _ tgt: String,
                                  materialized: Bool, withData: Bool) async throws {
        let names = try await relations(c, src, relkind: materialized ? "m" : "v", excludePartitions: false)
        guard !names.isEmpty else { return }
        try await run(c, "SET search_path TO \(ident(src))")
        var bodies: [(String, String)] = []
        for name in names {
            bodies.append((name, try await scalarString(c, "SELECT pg_get_viewdef(\(lit("\(src).\(name)"))::regclass, true)")))
        }
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

    private static func copyTriggers(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        let sql = """
        SELECT pg_get_triggerdef(tr.oid)
        FROM pg_trigger tr
        JOIN pg_class t ON t.oid = tr.tgrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = \(lit(src)) AND NOT tr.tgisinternal
        """
        let defs = try await strings(c, sql)
        try await run(c, "SET search_path TO \(ident(tgt))")
        for def in defs { try await run(c, retarget(def, from: src, to: tgt)) }
    }

    private static func copyPolicies(_ c: PostgresConnection, _ src: String, _ tgt: String) async throws {
        // Re-enable row security on the tables that had it.
        let secSQL = """
        SELECT relname, relforcerowsecurity FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(lit(src)) AND c.relrowsecurity
        """
        let secRows = try await c.query(PostgresQuery(unsafeSQL: secSQL), logger: logger)
        for try await (name, force) in secRows.decode((String, Bool).self) {
            try await run(c, "ALTER TABLE \(ident(tgt)).\(ident(name)) ENABLE ROW LEVEL SECURITY")
            if force { try await run(c, "ALTER TABLE \(ident(tgt)).\(ident(name)) FORCE ROW LEVEL SECURITY") }
        }
        // Recreate the policies themselves.
        let polSQL = """
        SELECT tablename, policyname, permissive, roles, cmd, qual, with_check
        FROM pg_policies WHERE schemaname = \(lit(src))
        """
        let rows = try await c.query(PostgresQuery(unsafeSQL: polSQL), logger: logger)
        var stmts: [String] = []
        for try await (table, policy, permissive, roles, cmd, qual, withCheck)
            in rows.decode((String, String, String, [String], String, String?, String?).self) {
            let to = roles.map { $0.lowercased() == "public" ? "PUBLIC" : ident($0) }.joined(separator: ", ")
            var stmt = "CREATE POLICY \(ident(policy)) ON \(ident(tgt)).\(ident(table)) AS \(permissive) FOR \(cmd) TO \(to)"
            if let qual { stmt += " USING (\(retarget(qual, from: src, to: tgt)))" }
            if let withCheck { stmt += " WITH CHECK (\(retarget(withCheck, from: src, to: tgt)))" }
            stmts.append(stmt)
        }
        for s in stmts { try await run(c, s) }
    }

    // MARK: - Privileges (best-effort, post-commit)

    private static func copyPrivileges(_ client: PostgresClient, _ src: String, _ tgt: String) async {
        _ = try? await client.withConnection { c in
            // Ownership of relations.
            let ownRel = """
            SELECT c.relkind::text, c.relname, pg_get_userbyid(c.relowner)
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(lit(src)) AND c.relkind IN ('r','p','v','m','S')
            """
            if let rows = try? await c.query(PostgresQuery(unsafeSQL: ownRel), logger: logger) {
                for try await (kind, name, owner) in rows.decode((String, String, String).self) {
                    let word = relationWord(kind)
                    _ = try? await c.query(PostgresQuery(unsafeSQL: "ALTER \(word) \(ident(tgt)).\(ident(name)) OWNER TO \(ident(owner))"), logger: logger)
                }
            }
            // Ownership of routines.
            let ownFn = """
            SELECT p.prokind::text, p.proname, pg_get_function_identity_arguments(p.oid), pg_get_userbyid(p.proowner)
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = \(lit(src)) AND p.prokind IN ('f','p')
            """
            if let rows = try? await c.query(PostgresQuery(unsafeSQL: ownFn), logger: logger) {
                for try await (kind, name, args, owner) in rows.decode((String, String, String, String).self) {
                    let word = kind == "p" ? "PROCEDURE" : "FUNCTION"
                    _ = try? await c.query(PostgresQuery(unsafeSQL: "ALTER \(word) \(ident(tgt)).\(ident(name))(\(args)) OWNER TO \(ident(owner))"), logger: logger)
                }
            }
            // Grants on relations.
            let grantSQL = """
            SELECT c.relkind::text, c.relname,
                   CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(g.grantee) END,
                   g.privilege_type, g.is_grantable
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
                 LATERAL aclexplode(c.relacl) g
            WHERE n.nspname = \(lit(src)) AND c.relkind IN ('r','p','v','m','S') AND c.relacl IS NOT NULL
            """
            if let rows = try? await c.query(PostgresQuery(unsafeSQL: grantSQL), logger: logger) {
                for try await (kind, name, grantee, priv, grantable) in rows.decode((String, String, String, String, Bool).self) {
                    let onWord = kind == "S" ? "SEQUENCE" : "TABLE"
                    let to = grantee == "PUBLIC" ? "PUBLIC" : ident(grantee)
                    var stmt = "GRANT \(priv) ON \(onWord) \(ident(tgt)).\(ident(name)) TO \(to)"
                    if grantable { stmt += " WITH GRANT OPTION" }
                    _ = try? await c.query(PostgresQuery(unsafeSQL: stmt), logger: logger)
                }
            }
        }
    }

    private static func relationWord(_ relkind: String) -> String {
        switch relkind {
        case "S": return "SEQUENCE"
        case "v": return "VIEW"
        case "m": return "MATERIALIZED VIEW"
        default:  return "TABLE"     // r, p
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
        return try await strings(c, sql)
    }

    private static func partitionLeaves(_ c: PostgresConnection, _ schema: String) async throws -> [(String, String, String)] {
        let sql = """
        SELECT c.relname, parent.relname, pg_get_expr(c.relpartbound, c.oid)
        FROM pg_class c
        JOIN pg_inherits i ON i.inhrelid = c.oid
        JOIN pg_class parent ON parent.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(lit(schema)) AND c.relispartition AND c.relkind = 'r'
        ORDER BY c.relname
        """
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var out: [(String, String, String)] = []
        for try await (name, parent, bound) in rows.decode((String, String, String).self) {
            out.append((name, parent, bound))
        }
        return out
    }

    private static func strings(_ c: PostgresConnection, _ sql: String) async throws -> [String] {
        let rows = try await c.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var out: [String] = []
        for try await v in rows.decode(String.self) { out.append(v) }
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

    private static func ident(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func lit(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Repoint schema-qualified references from `src.` to `tgt.` (bare and
    /// double-quoted). Used on DDL fragments only, never on table data.
    private static func retarget(_ sql: String, from src: String, to tgt: String) -> String {
        sql
            .replacingOccurrences(of: "\(src).", with: "\(tgt).")
            .replacingOccurrences(of: "\"\(src)\".", with: ident(tgt) + ".")
    }
}
