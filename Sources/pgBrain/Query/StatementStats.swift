import Foundation
import PostgresNIO

/// One row from `pg_stat_statements`. Top-N slowest queries on the
/// database — the standard DBA "what's eating CPU" diagnostic.
struct StatementStatRow: Identifiable, Sendable {
    let id: Int64           // queryid; uniquely identifies a normalised statement
    let calls: Int64
    let totalMs: Double     // total_exec_time across all calls
    let meanMs: Double      // mean_exec_time
    let rows: Int64
    let query: String
}

@MainActor
enum StatementStatsFetcher {
    /// True when the `pg_stat_statements` extension is installed in the
    /// current database. The pane uses this to flip from data view to
    /// "enable the extension" hint without trying — and failing — to
    /// query the missing view.
    static func isInstalled(client: PostgresClient) async -> Bool {
        do {
            let rows = try await client.query("""
            SELECT EXISTS (
              SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
            )
            """)
            for try await ok in rows.decode(Bool.self) { return ok }
            return false
        } catch {
            return false
        }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case total = "Total time"
        case mean  = "Mean time"
        case calls = "Calls"
        case rows  = "Rows"
        var id: String { rawValue }
        fileprivate var column: String {
            switch self {
            case .total: return "total_exec_time"
            case .mean:  return "mean_exec_time"
            case .calls: return "calls"
            case .rows:  return "rows"
            }
        }
    }

    static func fetch(limit: Int = 100, sort: SortKey = .total, client: PostgresClient) async throws -> [StatementStatRow] {
        // pg_stat_statements 1.8+ uses `total_exec_time` / `mean_exec_time`.
        // We just trust 1.8+; the extension shipped with PG 13 (2020) and
        // pgBrain already requires recent PG via PostgresNIO.
        let raw = """
        SELECT s.queryid::int8,
               s.calls::int8,
               s.total_exec_time::float8,
               s.mean_exec_time::float8,
               s.rows::int8,
               s.query
        FROM pg_stat_statements s
        JOIN pg_database d ON d.oid = s.dbid
        WHERE d.datname = current_database()
        ORDER BY \(sort.column) DESC NULLS LAST
        LIMIT \(limit)
        """
        let rows = try await client.query(PostgresQuery(unsafeSQL: raw))
        var out: [StatementStatRow] = []
        for try await (id, calls, total, mean, rs, q) in rows.decode((Int64?, Int64, Double, Double, Int64, String).self) {
            out.append(StatementStatRow(
                id: id ?? Int64(out.count),
                calls: calls, totalMs: total, meanMs: mean,
                rows: rs, query: q
            ))
        }
        return out
    }

    /// `pg_stat_statements_reset()` — zero the counters so the user can
    /// start a fresh measurement window. Needs the right grants; surfaces
    /// the server error if it fails.
    static func reset(client: PostgresClient) async throws {
        _ = try await client.query("SELECT pg_stat_statements_reset()")
    }
}
