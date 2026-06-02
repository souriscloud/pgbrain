import XCTest
import PostgresNIO
@testable import pgBrain

final class ColumnProfilerTests: XCTestCase {

    private func col(_ name: String, _ type: String) -> ColumnNode {
        ColumnNode(name: name, typeName: type, nullable: true, ordinal: 0)
    }

    func testProfileDerivedFractions() {
        let p = ColumnProfiler.Profile(total: 10, nonNull: 8, distinctCount: 4,
                                       minValue: nil, maxValue: nil, avgValue: nil)
        XCTAssertEqual(p.nullCount, 2)
        XCTAssertEqual(p.nullFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(p.distinctFraction, 0.5, accuracy: 1e-9)

        // Divide-by-zero guards.
        let empty = ColumnProfiler.Profile(total: 0, nonNull: 0, distinctCount: 0,
                                           minValue: nil, maxValue: nil, avgValue: nil)
        XCTAssertEqual(empty.nullFraction, 0)
        XCTAssertEqual(empty.distinctFraction, 0)
    }

    func testProfileNumericTextJsonBool() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (n int, label text, j jsonb, flag boolean);
            INSERT INTO "\(s)".t VALUES
              (10,'a','{"k":1}', true),
              (20,'b','{"k":2}', false),
              (20,NULL,NULL,NULL),
              (30,'a','{"k":1}', true);
            """)

            // Numeric: min/max/avg all present.
            let n = try await ColumnProfiler.profile(schema: s, table: "t", column: col("n", "integer"),
                                                     extraWhere: "", client: db.client)
            XCTAssertEqual(n.total, 4)
            XCTAssertEqual(n.nonNull, 4)
            XCTAssertEqual(n.minValue, "10")
            XCTAssertEqual(n.maxValue, "30")
            XCTAssertEqual(n.avgValue, "20.000000")

            // Text: min/max present (orderable), avg NULL (non-numeric).
            let label = try await ColumnProfiler.profile(schema: s, table: "t", column: col("label", "text"),
                                                         extraWhere: "", client: db.client)
            XCTAssertEqual(label.nonNull, 3)
            XCTAssertEqual(label.distinctCount, 2)
            XCTAssertEqual(label.minValue, "a")
            XCTAssertNil(label.avgValue)

            // json: no ordering ⇒ min/max NULL.
            let j = try await ColumnProfiler.profile(schema: s, table: "t", column: col("j", "jsonb"),
                                                    extraWhere: "", client: db.client)
            XCTAssertNil(j.minValue)
            XCTAssertNil(j.maxValue)

            // boolean: no min/max aggregate ⇒ NULL.
            let flag = try await ColumnProfiler.profile(schema: s, table: "t", column: col("flag", "boolean"),
                                                       extraWhere: "", client: db.client)
            XCTAssertNil(flag.minValue)

            // extraWhere narrows the slice.
            let filtered = try await ColumnProfiler.profile(schema: s, table: "t", column: col("n", "integer"),
                                                           extraWhere: "n >= 20", client: db.client)
            XCTAssertEqual(filtered.total, 3)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
