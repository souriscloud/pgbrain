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
/// `"my table"` or `"select"` doesn't blow up at runtime. Comment
/// values are SQL-literal-escaped via doubled apostrophes.
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
        let body = comment.map { "'\(escape($0))'" } ?? "NULL"
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
        let body = comment.map { "'\(escape($0))'" } ?? "NULL"
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
        let sql = "SELECT setval('\(escape(qualified))', \(value))"
        let op = service.operations.begin(kind: .update, summary: "setval \(schema).\(sequence) → \(value)")
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
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
        let sql = "SELECT nextval('\(escape(qualified))')"
        let op = service.operations.begin(kind: .update, summary: "nextval \(schema).\(sequence)")
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
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

    // MARK: - LISTEN / NOTIFY

    /// Fire a NOTIFY from a regular pooled connection. Payload is wrapped
    /// in single quotes with apostrophe-doubling.
    static func notify(channel: String, payload: String, service: ConnectionService) async -> Result<Void, Error> {
        let payloadSQL = payload.isEmpty
            ? "NOTIFY \(SQLIdent.quote(channel))"
            : "NOTIFY \(SQLIdent.quote(channel)), '\(escape(payload))'"
        return await runDDL(
            payloadSQL,
            summary: "NOTIFY \(channel)",
            service: service
        )
    }

    // MARK: - Internals

    private static func runDDL(_ sql: String, summary: String, service: ConnectionService) async -> Result<Void, Error> {
        guard let client = service.client else { return .failure(AdminError.notConnected) }
        let op = service.operations.begin(kind: .update, summary: summary)
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

    /// SQL string literal escape — only ' needs doubling for stdard
    /// strings (standard_conforming_strings is on by default since 9.1).
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}

enum AdminError: LocalizedError {
    case notConnected
    case serverSaid(String)
    var errorDescription: String? {
        switch self {
        case .notConnected:        return "Not connected."
        case .serverSaid(let m):   return m
        }
    }
}
