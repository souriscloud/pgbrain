import XCTest
import PostgresNIO
@testable import pgBrain

final class RowsFetcherTests: XCTestCase {

    private func makeTable(_ schema: String) -> TableNode {
        TableNode(schema: schema, name: "t", kind: .table, columns: [
            ColumnNode(name: "id",   typeName: "integer", nullable: false, ordinal: 0),
            ColumnNode(name: "name", typeName: "text",    nullable: true,  ordinal: 1),
        ], primaryKey: ["id"])
    }

    func testIsSpatialType() {
        XCTAssertTrue(RowsFetcher.isSpatialType("geometry"))
        XCTAssertTrue(RowsFetcher.isSpatialType("geometry(Point,4326)"))
        XCTAssertTrue(RowsFetcher.isSpatialType("geography(Point,4326)"))
        XCTAssertFalse(RowsFetcher.isSpatialType("text"))
    }

    func testPageWithEmptyColumnsShortCircuits() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let noCols = TableNode(schema: "public", name: "t", kind: .table, columns: [])
        let page = try await RowsFetcher.page(offset: 0, pageSize: 10, from: noCols, client: db.client)
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertFalse(page.truncated)
    }

    func testFirstPagingTruncationOffsetAndNulls() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int, name text);
            INSERT INTO "\(s)".t VALUES (1,'a'),(2,'b'),(3,'c'),(4,NULL),(5,'e');
            """)
            let t = makeTable(s)

            // first(2): two rows returned, more exist ⇒ truncated.
            let firstPage = try await RowsFetcher.first(2, from: t, client: db.client)
            XCTAssertEqual(firstPage.rows.count, 2)
            XCTAssertTrue(firstPage.truncated)
            XCTAssertEqual(firstPage.offset, 0)
            XCTAssertEqual(firstPage.columns.map(\.name), ["id", "name"])

            // offset 2, ordered: rows 3,4,5 → page of 3 (not truncated), NULL preserved.
            let p = try await RowsFetcher.page(offset: 2, pageSize: 10, from: t, client: db.client,
                                               filter: .init(whereClause: "", orderByClause: "id"))
            XCTAssertEqual(p.rows.count, 3)
            XCTAssertFalse(p.truncated)
            XCTAssertEqual(p.rows.first?.first as? String, "3")
            XCTAssertNil(p.rows[1][1], "row (4, NULL) keeps its NULL cell")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testExactAndEstimatedRowCounts() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int, name text);
            INSERT INTO "\(s)".t VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');
            """)
            let t = makeTable(s)

            let exact = try await RowsFetcher.exactRowCount(table: t, client: db.client,
                                                            filter: .init(whereClause: "", orderByClause: ""))
            XCTAssertEqual(exact, 5)
            let filtered = try await RowsFetcher.exactRowCount(table: t, client: db.client,
                                                               filter: .init(whereClause: "id > 3", orderByClause: ""))
            XCTAssertEqual(filtered, 2)

            // Un-analyzed table ⇒ reltuples ≤ 0 ⇒ nil estimate.
            let estBefore = try await RowsFetcher.estimatedRowCount(table: t, client: db.client)
            XCTAssertNil(estBefore)
            try await db.exec("ANALYZE \"\(s)\".t")
            let estAfter = try await RowsFetcher.estimatedRowCount(table: t, client: db.client)
            XCTAssertEqual(estAfter, 5)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
