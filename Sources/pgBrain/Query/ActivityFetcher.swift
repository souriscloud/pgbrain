import Foundation
import PostgresNIO

/// One snapshot of `pg_stat_activity` for the current database.
/// Powers the activity panel — what's running, what's idle in
/// transaction, what's been waiting on a lock for ages.
struct ActivityRow: Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let user: String?
    let application: String?
    let clientAddr: String?
    let state: String?
    /// Seconds since the current query started (nil when idle).
    let queryElapsed: Double?
    /// Seconds since the state last changed.
    let stateElapsed: Double?
    let waitEventType: String?
    let waitEvent: String?
    let query: String?
}

@MainActor
enum ActivityFetcher {
    static func fetch(client: PostgresClient) async throws -> [ActivityRow] {
        // `pg_backend_pid()` filters out our own connection so the
        // user doesn't see the request that's currently fetching the
        // activity list as a runaway query.
        let sql: PostgresQuery = """
        SELECT pid,
               usename,
               application_name,
               client_addr::text,
               state,
               EXTRACT(EPOCH FROM (now() - query_start))::float8,
               EXTRACT(EPOCH FROM (now() - state_change))::float8,
               wait_event_type,
               wait_event,
               query
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND pid <> pg_backend_pid()
        ORDER BY query_start DESC NULLS LAST
        """
        let rows = try await client.query(sql)
        var out: [ActivityRow] = []
        for try await (pid, user, app, addr, state, qElapsed, sElapsed, waitType, wait, query)
            in rows.decode((Int32, String?, String?, String?, String?, Double?, Double?, String?, String?, String?).self) {
            out.append(ActivityRow(
                pid: pid, user: user, application: app, clientAddr: addr,
                state: state, queryElapsed: qElapsed, stateElapsed: sElapsed,
                waitEventType: waitType, waitEvent: wait, query: query
            ))
        }
        return out
    }

    /// `pg_cancel_backend` — asks the backend to cancel its current
    /// query. Returns true when PG reports the signal was accepted.
    @discardableResult
    static func cancel(pid: Int32, client: PostgresClient) async throws -> Bool {
        let sql: PostgresQuery = "SELECT pg_cancel_backend(\(pid))"
        let rows = try await client.query(sql)
        for try await ok in rows.decode(Bool.self) { return ok }
        return false
    }

    /// `pg_terminate_backend` — kills the session entirely. Heavier
    /// hammer than cancel; the activity panel only exposes it behind
    /// a confirmation.
    @discardableResult
    static func terminate(pid: Int32, client: PostgresClient) async throws -> Bool {
        let sql: PostgresQuery = "SELECT pg_terminate_backend(\(pid))"
        let rows = try await client.query(sql)
        for try await ok in rows.decode(Bool.self) { return ok }
        return false
    }
}
