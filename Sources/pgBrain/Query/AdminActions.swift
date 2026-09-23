import Foundation
import PostgresNIO

/// Catch-all for "the user clicked a button and we want to run an admin
/// statement against the database" — VACUUM / ANALYZE / REINDEX, schema
/// CRUD, materialized view refresh, COMMENT updates, sequence actions.
///
/// Every entry point follows the same pattern: build the SQL, register
/// with `OperationsCenter` so it shows up in the running-ops popover
/// (and gets a Cancel button), then `client.query(...)`.
///
/// Identifiers are wrapped through `SQLIdent.quote` so a table named
/// `"my table"` or `"select"` doesn't blow up at runtime. Values go through
/// bind parameters where the statement allows them, and through `literal(_:)`
/// (safe regardless of `standard_conforming_strings`) where it doesn't
/// (COMMENT, CREATE DATABASE).
@MainActor
enum AdminActions {
    // MARK: - VACUUM / ANALYZE / REINDEX

    enum Maintenance: String, CaseIterable, Identifiable {
        case analyze         = "ANALYZE"
        case vacuum          = "VACUUM"
        case vacuumAnalyze   = "VACUUM ANALYZE"
        case vacuumFull      = "VACUUM FULL"
        case reindex         = "REINDEX"
        var id: String { rawValue }
        var label: String { rawValue }
        var help: String {
            switch self {
            case .analyze:       "Refresh planner statistics. Cheap, non-blocking."
            case .vacuum:        "Reclaim dead tuples. Non-blocking — runs concurrently with reads/writes."
            case .vacuumAnalyze: "VACUUM + statistics refresh in one pass."
            case .vacuumFull:    "Rewrite the entire table to reclaim space. Takes an ACCESS EXCLUSIVE lock — blocks everything else."
            case .reindex:       "Rebuild every index on the table. Blocks writes."
            }
        }
        var isDestructive: Bool { self == .vacuumFull || self == .reindex }
    }

    /// Run a maintenance action against one relation. The OperationsCenter
    /// entry doubles as the user-facing progress + cancel handle.
    static func runMaintenance(
        _ action: Maintenance,
        on schema: String, table: String,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        guard let client = service.client else {
            return .failure(AdminError.notConnected)
        }
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let sql: String = {
            switch action {
            case .reindex: return "REINDEX TABLE \(qualified)"
            default:       return "\(action.rawValue) \(qualified)"
            }
        }()
        let op = service.operations.begin(kind: .update, summary: "\(action.rawValue) \(schema).\(table)")
        do {
            _ = try await client.query(PostgresQuery(unsafeSQL: sql))
            service.operations.finish(op, status: .succeeded)
            return .success(())
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    // MARK: - Schema CRUD

    static func createSchema(name: String, service: ConnectionService) async -> Result<Void, Error> {
        await runDDL("CREATE SCHEMA \(SQLIdent.quote(name))", summary: "CREATE SCHEMA \(name)", service: service)
    }

    /// `CREATE TABLE schema.name ( <body> )`. The caller assembles `body`
    /// (column definitions + optional PRIMARY KEY) so the sheet can show a
    /// live preview of the exact SQL that runs.
    static func createTable(schema: String, name: String, body: String, service: ConnectionService) async -> Result<Void, Error> {
        let sql = "CREATE TABLE \(SQLIdent.quote(schema)).\(SQLIdent.quote(name)) (\n\(body)\n)"
        return await runDDL(sql, summary: "CREATE TABLE \(schema).\(name)", service: service)
    }

    static func renameSchema(from old: String, to new: String, service: ConnectionService) async -> Result<Void, Error> {
        await runDDL(
            "ALTER SCHEMA \(SQLIdent.quote(old)) RENAME TO \(SQLIdent.quote(new))",
            summary: "RENAME SCHEMA \(old) → \(new)",
            service: service
        )
    }

    /// Drop a schema. `cascade` follows Postgres' own semantics: without
    /// CASCADE the server refuses if dependent objects exist, so we wrap
    /// the boolean directly into the statement and let the user pick.
    static func dropSchema(name: String, cascade: Bool, service: ConnectionService) async -> Result<Void, Error> {
        let tail = cascade ? " CASCADE" : ""
        return await runDDL(
            "DROP SCHEMA \(SQLIdent.quote(name))\(tail)",
            summary: "DROP SCHEMA \(name)\(cascade ? " CASCADE" : "")",
            service: service
        )
    }

    // MARK: - Materialized view refresh

    /// REFRESH MATERIALIZED VIEW. `concurrently=true` requires a unique
    /// index on the view; the caller is responsible for only offering
    /// the toggle when one exists.
    static func refreshMaterializedView(
        schema: String, name: String, concurrently: Bool,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(name)
        let sql = "REFRESH MATERIALIZED VIEW\(concurrently ? " CONCURRENTLY" : "") \(qualified)"
        return await runDDL(
            sql,
            summary: "REFRESH MATVIEW\(concurrently ? " CONCURRENTLY" : "") \(schema).\(name)",
            service: service
        )
    }

    // MARK: - COMMENT ON …

    static func setTableComment(
        schema: String, table: String, comment: String?,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let body = comment.map { literal($0) } ?? "NULL"
        return await runDDL(
            "COMMENT ON TABLE \(qualified) IS \(body)",
            summary: "COMMENT ON TABLE \(schema).\(table)",
            service: service
        )
    }

    static func setColumnComment(
        schema: String, table: String, column: String, comment: String?,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table) + "." + SQLIdent.quote(column)
        let body = comment.map { literal($0) } ?? "NULL"
        return await runDDL(
            "COMMENT ON COLUMN \(qualified) IS \(body)",
            summary: "COMMENT ON COLUMN \(schema).\(table).\(column)",
            service: service
        )
    }

    // MARK: - Sequence actions

    static func setval(schema: String, sequence: String, value: Int64, service: ConnectionService) async -> Result<Int64, Error> {
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(sequence)
        let sql: PostgresQuery = "SELECT setval(\(qualified)::regclass, \(value))"
        let op = service.operations.begin(kind: .update, summary: "setval \(schema).\(sequence) → \(value)")
        do {
            let rows = try await client.query(sql)
            for try await v in rows.decode(Int64.self) {
                service.operations.finish(op, status: .succeeded)
                return .success(v)
            }
            service.operations.finish(op, status: .succeeded)
            return .success(value)
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    static func nextval(schema: String, sequence: String, service: ConnectionService) async -> Result<Int64, Error> {
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(sequence)
        let sql: PostgresQuery = "SELECT nextval(\(qualified)::regclass)"
        let op = service.operations.begin(kind: .update, summary: "nextval \(schema).\(sequence)")
        do {
            let rows = try await client.query(sql)
            for try await v in rows.decode(Int64.self) {
                service.operations.finish(op, status: .succeeded)
                return .success(v)
            }
            service.operations.finish(op, status: .succeeded)
            return .success(0)
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    static func restartSequence(schema: String, sequence: String, to value: Int64, service: ConnectionService) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(sequence)
        return await runDDL(
            "ALTER SEQUENCE \(qualified) RESTART WITH \(value)",
            summary: "RESTART \(schema).\(sequence) → \(value)",
            service: service
        )
    }

    // MARK: - Triggers

    /// ALTER TABLE … {ENABLE|DISABLE} TRIGGER name. We use the
    /// per-trigger flavour rather than the table-wide one — keeps
    /// behaviour predictable when a table has many triggers.
    static func setTriggerEnabled(
        schema: String, table: String, trigger: String, enabled: Bool,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let verb = enabled ? "ENABLE" : "DISABLE"
        return await runDDL(
            "ALTER TABLE \(qualified) \(verb) TRIGGER \(SQLIdent.quote(trigger))",
            summary: "\(verb) TRIGGER \(trigger) ON \(schema).\(table)",
            service: service
        )
    }

    static func dropTrigger(
        schema: String, table: String, trigger: String,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        return await runDDL(
            "DROP TRIGGER \(SQLIdent.quote(trigger)) ON \(qualified)",
            summary: "DROP TRIGGER \(trigger)",
            service: service
        )
    }

    // MARK: - Functions / procedures

    /// Re-run a CREATE OR REPLACE FUNCTION (or any DDL) the user typed
    /// in the function editor. We don't validate the body — the server
    /// will, and its error message is more accurate than anything we
    /// could string-parse.
    static func saveFunctionBody(_ ddl: String, service: ConnectionService) async -> Result<Void, Error> {
        await runDDL(ddl, summary: "CREATE OR REPLACE FUNCTION", service: service)
    }

    static func dropFunction(
        schema: String, signature: String,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        // `signature` is `name(arg types)`. It is never spliced into the DROP:
        // the server resolves it via to_regprocedure (a bind parameter, parsed
        // as a name — nothing in it can execute) and hands back its own
        // canonical, properly quoted regprocedure text plus the routine kind.
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        guard let spec = functionSpec(schema: schema, signature: signature) else {
            return .failure(AdminError.invalidInput("\"\(signature)\" isn't a function signature like name(type, …)."))
        }
        let lookup: PostgresQuery = """
        SELECT p.oid::regprocedure::text, p.prokind::text
        FROM pg_proc p WHERE p.oid = to_regprocedure(\(spec))
        """
        var resolved: (String, String)?
        do {
            for try await row in try await client.query(lookup).decode((String, String).self) { resolved = row }
        } catch {
            return .failure(AdminError.serverSaid(PostgresErrorMessage.describe(error)))
        }
        guard let (canonical, kind) = resolved else {
            return .failure(AdminError.serverSaid("Function \(schema).\(signature) doesn't exist."))
        }
        let word = switch kind {
        case "p": "PROCEDURE"
        case "a": "AGGREGATE"
        default: "FUNCTION"
        }
        return await runDDL(
            "DROP \(word) \(canonical)",
            summary: "DROP \(word) \(schema).\(signature)",
            service: service
        )
    }

    /// `schema.name(args)` text for `to_regprocedure`, with the name part
    /// quoted unless it already is. `nil` when `signature` isn't
    /// `name(…)`-shaped with balanced parens and no statement separators.
    nonisolated static func functionSpec(schema: String, signature: String) -> String? {
        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = sig.firstIndex(of: "("), sig.hasSuffix(")") else { return nil }
        let name = sig[..<open].trimmingCharacters(in: .whitespaces)
        let args = String(sig[open...])
        guard !name.isEmpty else { return nil }
        var depth = 0
        for t in SQLLexer.lex(args) {
            switch t.kind {
            case .lineComment, .blockComment, .string, .dollarString, .parameter: return nil
            case .punct:
                let c = (args as NSString).character(at: t.range.location)
                if c == 0x28 { depth += 1 } else if c == 0x29 { depth -= 1 } else if c == 0x3B { return nil }
                if depth < 0 { return nil }
            default: break
            }
        }
        guard depth == 0 else { return nil }
        let quotedName = name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 ? name : SQLIdent.quote(name)
        return SQLIdent.quote(schema) + "." + quotedName + args
    }

    // MARK: - Database CRUD

    /// `CREATE DATABASE` can't run inside a transaction. The client
    /// path uses autocommit so we just fire it. Some options
    /// (TEMPLATE, OWNER, ENCODING) get conditionally appended.
    static func createDatabase(
        name: String, owner: String?, template: String?, encoding: String?,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        var sql = "CREATE DATABASE \(SQLIdent.quote(name))"
        if let owner, !owner.isEmpty { sql += " OWNER \(SQLIdent.quote(owner))" }
        if let template, !template.isEmpty { sql += " TEMPLATE \(SQLIdent.quote(template))" }
        if let encoding, !encoding.isEmpty { sql += " ENCODING \(literal(encoding))" }
        return await runDDL(sql, summary: "CREATE DATABASE \(name)", service: service)
    }

    static func dropDatabase(
        name: String, force: Bool,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let tail = force ? " WITH (FORCE)" : ""
        return await runDDL(
            "DROP DATABASE \(SQLIdent.quote(name))\(tail)",
            summary: "DROP DATABASE \(name)\(force ? " FORCE" : "")",
            service: service
        )
    }

    // MARK: - Column ALTER

    static func renameColumn(
        schema: String, table: String, from: String, to: String,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        return await runDDL(
            "ALTER TABLE \(qualified) RENAME COLUMN \(SQLIdent.quote(from)) TO \(SQLIdent.quote(to))",
            summary: "RENAME COLUMN \(from) → \(to)",
            service: service
        )
    }

    static func dropColumn(
        schema: String, table: String, column: String, cascade: Bool,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let tail = cascade ? " CASCADE" : ""
        return await runDDL(
            "ALTER TABLE \(qualified) DROP COLUMN \(SQLIdent.quote(column))\(tail)",
            summary: "DROP COLUMN \(column)\(cascade ? " CASCADE" : "")",
            service: service
        )
    }

    /// Add a column. `nullable` defaults to true (PG default). When
    /// `defaultExpr` is supplied PG runs the rewrite to backfill —
    /// caller's responsibility to consider lock impact.
    static func addColumn(
        schema: String, table: String, name: String, type: String,
        nullable: Bool, defaultExpr: String?,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        var line = "ALTER TABLE \(qualified) ADD COLUMN \(SQLIdent.quote(name)) \(type)"
        if let defaultExpr, !defaultExpr.isEmpty { line += " DEFAULT \(defaultExpr)" }
        if !nullable { line += " NOT NULL" }
        return await runDDL(line, summary: "ADD COLUMN \(name) \(type)", service: service)
    }

    /// ALTER COLUMN TYPE with an optional USING expression for casts
    /// that aren't implicit (e.g. text → uuid).
    static func alterColumnType(
        schema: String, table: String, column: String, newType: String, using: String?,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        var sql = "ALTER TABLE \(qualified) ALTER COLUMN \(SQLIdent.quote(column)) TYPE \(newType)"
        if let using, !using.isEmpty { sql += " USING \(using)" }
        return await runDDL(sql, summary: "ALTER COLUMN \(column) TYPE \(newType)", service: service)
    }

    // MARK: - TRUNCATE

    static func truncate(
        schema: String, table: String, cascade: Bool, restartIdentity: Bool,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        var sql = "TRUNCATE TABLE \(qualified)"
        if restartIdentity { sql += " RESTART IDENTITY" }
        if cascade { sql += " CASCADE" }
        return await runDDL(sql, summary: "TRUNCATE \(schema).\(table)", service: service)
    }

    // MARK: - Views

    /// Save a view body. Views use CREATE OR REPLACE; matviews can't be
    /// replaced in place so we DROP + CREATE (caller is warned). `body`
    /// is the full statement the editor produced.
    static func saveViewBody(_ ddl: String, service: ConnectionService) async -> Result<Void, Error> {
        await runDDL(ddl, summary: "CREATE OR REPLACE VIEW", service: service)
    }

    // MARK: - GRANT / REVOKE

    /// Table privilege keywords accepted by `setPrivileges` — the list is
    /// spliced into SQL, so anything else is rejected rather than escaped.
    nonisolated static let tablePrivileges: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN",
        "ALL", "ALL PRIVILEGES",
    ]

    /// Build + run a GRANT or REVOKE for a set of privileges on one
    /// table. `privileges` must be keywords from `tablePrivileges`.
    static func setPrivileges(
        grant: Bool, privileges: [String],
        schema: String, table: String, role: String,
        service: ConnectionService
    ) async -> Result<Void, Error> {
        guard !privileges.isEmpty else { return .success(()) }
        let normalized = privileges.map {
            $0.trimmingCharacters(in: .whitespaces).uppercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if let bad = normalized.first(where: { !tablePrivileges.contains($0) }) {
            return .failure(AdminError.invalidInput("\"\(bad)\" isn't a table privilege."))
        }
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let privList = normalized.joined(separator: ", ")
        // PUBLIC is a keyword, not a role name — quoting it would target a
        // (nonexistent) role literally called "PUBLIC".
        let grantee = role.uppercased() == "PUBLIC" ? "PUBLIC" : SQLIdent.quote(role)
        let sql: String
        if grant {
            sql = "GRANT \(privList) ON TABLE \(qualified) TO \(grantee)"
        } else {
            sql = "REVOKE \(privList) ON TABLE \(qualified) FROM \(grantee)"
        }
        return await runDDL(
            sql,
            summary: "\(grant ? "GRANT" : "REVOKE") \(privList) · \(role)",
            service: service
        )
    }

    // MARK: - Bulk INSERT (data generator)

    /// Run a generated INSERT … SELECT FROM generate_series statement.
    /// The caller builds the SQL; we just execute + track it.
    static func runGeneratedInsert(_ sql: String, summary: String, service: ConnectionService) async -> Result<Void, Error> {
        await runDDL(sql, summary: summary, service: service)
    }

    // MARK: - LISTEN / NOTIFY

    /// Fire a NOTIFY from a regular pooled connection. `pg_notify` takes the
    /// channel and payload as bind parameters (same semantics as
    /// `NOTIFY "channel", 'payload'`), so no quoting is involved at all.
    static func notify(channel: String, payload: String, service: ConnectionService) async -> Result<Void, Error> {
        await runQuery("SELECT pg_notify(\(channel), \(payload))", summary: "NOTIFY \(channel)", service: service)
    }

    /// Run an arbitrary statement as a tracked `.update` operation. Used by
    /// the data grid's row-delete action; success/failure surface through the
    /// usual operation → toast path.
    static func execute(_ sql: String, summary: String, service: ConnectionService) async -> Result<Void, Error> {
        await runDDL(sql, summary: summary, service: service)
    }

    /// Run several statements atomically in one transaction — used by the
    /// table designer so a batch of ALTERs either all land or none do. Empty
    /// input is a no-op success.
    static func executeBatch(_ statements: [String], summary: String, service: ConnectionService) async -> Result<Void, Error> {
        let stmts = statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !stmts.isEmpty else { return .success(()) }
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        let op = service.operations.begin(kind: .update, summary: summary)
        do {
            try await client.withTransaction(logger: pgbrainQuietLogger) { connection in
                for sql in stmts {
                    _ = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: pgbrainQuietLogger)
                }
            }
            service.operations.finish(op, status: .succeeded)
            return .success(())
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    // MARK: - Internals

    private static func runDDL(_ sql: String, summary: String, service: ConnectionService) async -> Result<Void, Error> {
        await runQuery(PostgresQuery(unsafeSQL: sql), summary: summary, service: service)
    }

    private static func runQuery(_ query: PostgresQuery, summary: String, service: ConnectionService) async -> Result<Void, Error> {
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        let op = service.operations.begin(kind: .update, summary: summary)
        do {
            _ = try await client.query(query)
            service.operations.finish(op, status: .succeeded)
            return .success(())
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            return .failure(AdminError.serverSaid(msg))
        }
    }

    /// SQL string literal for statements that can't take bind parameters.
    /// Uses `E'…'` (backslashes and quotes escaped) whenever a backslash is
    /// present, so the result means the same thing whether or not the server
    /// runs with `standard_conforming_strings`. NULs are dropped: the wire
    /// protocol would truncate the statement at one.
    nonisolated static func literal(_ s: String) -> String {
        let clean = s.contains("\0") ? s.replacingOccurrences(of: "\0", with: "") : s
        let quoted = clean.replacingOccurrences(of: "'", with: "''")
        if clean.contains("\\") {
            return "E'" + quoted.replacingOccurrences(of: "\\", with: "\\\\") + "'"
        }
        return "'" + quoted + "'"
    }
}

enum AdminError: LocalizedError {
    case notConnected
    case serverSaid(String)
    case invalidInput(String)
    var errorDescription: String? {
        switch self {
        case .notConnected:        return "Not connected."
        case .serverSaid(let m):   return m
        case .invalidInput(let m): return m
        }
    }
}
