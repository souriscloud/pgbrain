import XCTest
import PostgresNIO
@testable import pgBrain

/// E2E coverage of the EXPLAIN runner + recursive JSON parser. Uses
/// `generate_series` so no table fixture is needed.
@MainActor
final class ExplainPlanTests: XCTestCase {

    func testExplainSimplePlan() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let node = try await Explain.run(sql: "SELECT 1", analyze: false, on: db.client)
        XCTAssertFalse(node.nodeType.isEmpty)
        XCTAssertGreaterThanOrEqual(node.totalCost, 0)
        XCTAssertNil(node.actualTotalTime, "no ANALYZE ⇒ no actual timings")
        XCTAssertFalse(node.rawAttributes.isEmpty)
    }

    func testExplainWithNestedChildren() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let node = try await Explain.run(
            sql: "SELECT * FROM generate_series(1,10) a, generate_series(1,5) b",
            analyze: false, on: db.client)
        XCTAssertFalse(node.children.isEmpty, "a join plan has child nodes")
        XCTAssertFalse(node.children[0].nodeType.isEmpty)
    }

    func testExplainAnalyzePopulatesActuals() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let node = try await Explain.run(sql: "SELECT 1", analyze: true, on: db.client)
        XCTAssertNotNil(node.actualTotalTime, "ANALYZE records real execution time")
    }

    func testExplainAnalyzeRollsBackMutations() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(schema)";
            CREATE TABLE "\(schema)".t (id int);
            """)
            // EXPLAIN ANALYZE on an INSERT executes it, but the runner wraps it
            // in BEGIN…ROLLBACK so nothing persists.
            _ = try await Explain.run(sql: "INSERT INTO \"\(schema)\".t VALUES (1)",
                                      analyze: true, on: db.client)
            let count = try await db.scalarInt("SELECT count(*) FROM \"\(schema)\".t")
            XCTAssertEqual(count, 0, "the analyzed INSERT must have been rolled back")
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }

    func testErrorDescriptions() {
        XCTAssertEqual(Explain.ExplainError.invalidJSON.errorDescription, "Couldn't parse EXPLAIN output")
        XCTAssertEqual(Explain.ExplainError.empty.errorDescription, "EXPLAIN returned no rows")
    }
}
