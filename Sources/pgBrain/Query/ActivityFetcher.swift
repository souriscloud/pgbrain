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

/// One row from the index-usage stats — `pg_stat_user_indexes`
/// plus size from `pg_relation_size`. Powers the Indexes panel
/// (sidebar `…` menu → "Index usage…").
struct IndexUsageRow: Identifiable, Sendable {
    let id: String
    let schema: String
    let table: String
    let index: String
    let scans: Int64
    let tuplesRead: Int64
    let tuplesFetched: Int64
    let sizeBytes: Int64
    /// True when `scans == 0` and the index isn't backing a
    /// constraint — i.e. dead weight on writes for no payoff.
    let isUnused: Bool
}

@MainActor
enum IndexUsageFetcher {
    static func fetch(client: PostgresClient) async throws -> [IndexUsageRow] {
        let sql: PostgresQuery = """
        SELECT s.schemaname::text,
               s.relname::text,
               s.indexrelname::text,
               s.idx_scan::int8,
               s.idx_tup_read::int8,
               s.idx_tup_fetch::int8,
               pg_relation_size(s.indexrelid)::int8,
               (s.idx_scan = 0
                AND NOT EXISTS (
                    SELECT 1 FROM pg_constraint c
                    WHERE c.conindid = s.indexrelid
                ))
        FROM pg_stat_user_indexes s
        WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
        ORDER BY pg_relation_size(s.indexrelid) DESC
        """
        let rows = try await client.query(sql)
        var out: [IndexUsageRow] = []
        for try await (schema, table, index, scans, tupRead, tupFetch, size, unused)
            in rows.decode((String, String, String, Int64, Int64, Int64, Int64, Bool).self) {
            out.append(IndexUsageRow(
                id: "\(schema).\(table).\(index)",
                schema: schema, table: table, index: index,
                scans: scans, tuplesRead: tupRead,
                tuplesFetched: tupFetch, sizeBytes: size,
                isUnused: unused
            ))
        }
        return out
    }
}

/// One row from the lock viewer — `pg_locks` joined to
/// `pg_stat_activity` so we can show "session X holds this lock /
/// session Y is waiting for it". Powers the Locks tab.
struct LockRow: Identifiable, Sendable {
    let id: String
    let pid: Int32
    let lockType: String?
    let relation: String?
    let mode: String?
    let granted: Bool
    let user: String?
    let application: String?
    let waitElapsed: Double?
    let query: String?
}

@MainActor
enum LockFetcher {
    static func fetch(client: PostgresClient) async throws -> [LockRow] {
        let sql: PostgresQuery = """
        SELECT l.pid::int4,
               l.locktype::text,
               (CASE WHEN l.relation IS NOT NULL
                     THEN (SELECT n.nspname || '.' || c.relname
                           FROM pg_class c
                           JOIN pg_namespace n ON n.oid = c.relnamespace
                           WHERE c.oid = l.relation)
                     ELSE NULL END)::text,
               l.mode::text,
               l.granted,
               a.usename,
               a.application_name,
               EXTRACT(EPOCH FROM (now() - a.state_change))::float8,
               a.query
        FROM pg_locks l
        LEFT JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE l.pid <> pg_backend_pid()
        ORDER BY l.granted ASC, a.query_start DESC NULLS LAST
        """
        let rows = try await client.query(sql)
        var out: [LockRow] = []
        var counter = 0
        for try await (pid, lockType, relation, mode, granted, user, app, waitElapsed, query)
            in rows.decode((Int32, String?, String?, String?, Bool, String?, String?, Double?, String?).self) {
            counter += 1
            out.append(LockRow(
                id: "\(pid)-\(counter)", pid: pid,
                lockType: lockType, relation: relation,
                mode: mode, granted: granted,
                user: user, application: app,
                waitElapsed: waitElapsed, query: query
            ))
        }
        return out
    }
}
