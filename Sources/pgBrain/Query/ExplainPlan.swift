import Foundation
import PostgresNIO

/// Parsed `EXPLAIN (FORMAT JSON [, ANALYZE])` output. Recursive — each
/// node carries the metrics PG returned + nested child plans. We only
/// surface the fields the viewer actually needs; future enhancements
/// (buffers, JIT, settings) can pull from the underlying JSON via
/// `rawAttributes`.
struct ExplainNode: Identifiable {
    let id = UUID()
    let nodeType: String
    let relationName: String?
    let alias: String?
    let startupCost: Double
    let totalCost: Double
    let planRows: Double
    let planWidth: Int
    let actualStartupTime: Double?
    let actualTotalTime: Double?
    let actualRows: Double?
    let actualLoops: Int?
    /// Captured for tooltip / "view full JSON" affordances later.
    let rawAttributes: [String: Any]
    let children: [ExplainNode]
}

/// One-shot helper: runs `EXPLAIN` against the active client and
/// parses the JSON-formatted output. `analyze: true` actually executes
/// the query — slow + side-effecting for non-SELECT statements, so the
/// viewer defaults to false and exposes a toggle.
@MainActor
enum Explain {
    enum ExplainError: Error, LocalizedError {
        case invalidJSON
        case empty
        var errorDescription: String? {
            switch self {
            case .invalidJSON: "Couldn't parse EXPLAIN output"
            case .empty:       "EXPLAIN returned no rows"
            }
        }
    }

    static func run(sql: String, analyze: Bool, on client: PostgresClient) async throws -> ExplainNode {
        // EXPLAIN inside parentheses lets PG accept multi-statement
        // bodies as a single expression. ANALYZE forces execution —
        // wrap in a savepoint-style transaction so destructive
        // statements don't actually mutate when the user is just
        // poking around. (BEGIN…ROLLBACK around the EXPLAIN.)
        let optionList = analyze ? "(FORMAT JSON, ANALYZE)" : "(FORMAT JSON)"
        // The whole user statement goes verbatim after the EXPLAIN.
        let stmt = "EXPLAIN \(optionList) \(sql)"
        let rows: [String]
        if analyze {
            // Wrap in a transaction we always ROLLBACK so an EXPLAIN
            // ANALYZE on an INSERT/UPDATE/DELETE doesn't actually
            // persist. The query path uses one connection from the
            // pool for the duration.
            rows = try await client.withConnection { conn in
                _ = try? await conn.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: pgbrainQuietLogger)
                var out: [String] = []
                do {
                    let stream = try await conn.query(PostgresQuery(unsafeSQL: stmt), logger: pgbrainQuietLogger)
                    for try await row in stream.decode(String.self) { out.append(row) }
                } catch {
                    _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                    throw error
                }
                _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                return out
            }
        } else {
            let stream = try await client.query(PostgresQuery(unsafeSQL: stmt))
            var out: [String] = []
            for try await row in stream.decode(String.self) { out.append(row) }
            rows = out
        }
        guard let json = rows.first,
              let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = top.first,
              let plan = first["Plan"] as? [String: Any]
        else {
            if rows.isEmpty { throw ExplainError.empty }
            throw ExplainError.invalidJSON
        }
        return parse(plan)
    }

    private static func parse(_ dict: [String: Any]) -> ExplainNode {
        let childPlans = (dict["Plans"] as? [[String: Any]]) ?? []
        let children = childPlans.map(parse)
        return ExplainNode(
            nodeType: (dict["Node Type"] as? String) ?? "Unknown",
            relationName: dict["Relation Name"] as? String,
            alias: dict["Alias"] as? String,
            startupCost: (dict["Startup Cost"] as? Double) ?? 0,
            totalCost: (dict["Total Cost"] as? Double) ?? 0,
            planRows: (dict["Plan Rows"] as? Double) ?? 0,
            planWidth: (dict["Plan Width"] as? Int) ?? 0,
            actualStartupTime: dict["Actual Startup Time"] as? Double,
            actualTotalTime: dict["Actual Total Time"] as? Double,
            actualRows: dict["Actual Rows"] as? Double,
            actualLoops: dict["Actual Loops"] as? Int,
            rawAttributes: dict,
            children: children
        )
    }
}
