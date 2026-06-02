import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class RolesFetcherTests: XCTestCase {

    func testFetchRolesIncludesCurrentRole() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let me = try await db.scalarString("SELECT current_user")
        let roles = try await RolesFetcher.fetchRoles(client: db.client)
        XCTAssertFalse(roles.isEmpty)
        let mine = try XCTUnwrap(roles.first { $0.name == me }, "current role should be listed")
        XCTAssertTrue(mine.canLogin, "the role we connected as can log in")
        XCTAssertEqual(mine.id, me)
    }

    func testFetchGrantsAggregatesPrivileges() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int);
            GRANT SELECT, INSERT ON "\(s)".t TO PUBLIC;
            """)
            let grants = try await RolesFetcher.fetchGrants(client: db.client)
            let mine = try XCTUnwrap(grants.first { $0.schema == s && $0.table == "t" && $0.grantee == "PUBLIC" })
            XCTAssertEqual(mine.privileges, "INSERT, SELECT", "privileges aggregated + ordered")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}

@MainActor
final class SizeStatsFetcherTests: XCTestCase {

    func testFetchReportsDatabaseTableAndIndexSizes() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".big (id int PRIMARY KEY, payload text);
            INSERT INTO "\(s)".big SELECT g, repeat('x', 100) FROM generate_series(1, 500) g;
            CREATE INDEX big_payload_idx ON "\(s)".big (payload);
            ANALYZE "\(s)".big;
            """)
            // Large topN so the small fixture table is guaranteed in range.
            let stats = try await SizeStatsFetcher.fetch(topN: 10_000, client: db.client)
            XCTAssertGreaterThan(stats.databaseBytes, 0)

            let table = try XCTUnwrap(stats.tables.first { $0.id == "\(s).big" })
            XCTAssertGreaterThan(table.totalBytes, 0)
            XCTAssertGreaterThanOrEqual(table.totalBytes, table.tableBytes)
            XCTAssertGreaterThan(table.rowEstimate, 0, "ANALYZE populated reltuples")

            let index = try XCTUnwrap(stats.indexes.first { $0.index == "big_payload_idx" })
            XCTAssertEqual(index.schema, s)
            XCTAssertGreaterThan(index.bytes, 0)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}

@MainActor
final class UsageFinderTests: XCTestCase {

    func testFindLocatesViewAndFunctionReferences() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".widget (id int);
            CREATE VIEW "\(s)".v_widget AS SELECT id FROM "\(s)".widget;
            CREATE FUNCTION "\(s)".count_widgets() RETURNS bigint LANGUAGE sql
                AS 'SELECT count(*) FROM \(s).widget';
            """)
            let hits = try await UsageFinder.find(schema: s, table: "widget", client: db.client)
            let names = Set(hits.map(\.name))
            XCTAssertTrue(names.contains("v_widget"), "the view referencing widget is found")
            XCTAssertTrue(names.contains("count_widgets"), "the function referencing widget is found")
            let view = try XCTUnwrap(hits.first { $0.name == "v_widget" })
            XCTAssertEqual(view.kind, .view)
            XCTAssertFalse(view.excerpt.isEmpty)
            XCTAssertTrue(view.id.contains("v_widget"))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
