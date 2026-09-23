import XCTest
import PostgresNIO
@testable import pgBrain

final class C_RowsFetcherSQLTests: XCTestCase {

    private func table(_ kind: TableNode.Kind = .table, pk: [String] = ["id"], schema: String = "s") -> TableNode {
        TableNode(schema: schema, name: "t", kind: kind, columns: [
            ColumnNode(name: "id",   typeName: "integer", nullable: false, ordinal: 0),
            ColumnNode(name: "name", typeName: "text",    nullable: true,  ordinal: 1),
        ], primaryKey: pk)
    }

    private let noFilter = RowsFetcher.Filter(whereClause: "", orderByClause: "")

    // MARK: - SQL shape

    func testEveryClauseStartsOnItsOwnLine() {
        let sql = RowsFetcher.pageSQL(
            table: table(),
            filter: .init(whereClause: "id > 3 -- only the tail", orderByClause: "name DESC -- newest"),
            offset: 400, pageSize: 200, spatial: false)
        let lines = sql.components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            #"SELECT "id"::text AS "_pgb_0", "name"::text AS "_pgb_1""#,
            #"FROM "s"."t""#,
            "WHERE id > 3 -- only the tail",
            "ORDER BY name DESC -- newest",
            #", "id""#,
            "LIMIT 201",
            "OFFSET 400",
        ])
    }

    func testDefaultOrderIsPrimaryKey() {
        let composite = TableNode(schema: "s", name: "t", kind: .table, columns: [
            ColumnNode(name: "a", typeName: "integer", nullable: false, ordinal: 0),
            ColumnNode(name: "b", typeName: "integer", nullable: false, ordinal: 1),
        ], primaryKey: ["a", "b"])
        let sql = RowsFetcher.pageSQL(table: composite, filter: noFilter, offset: 0, pageSize: 50, spatial: false)
        XCTAssertTrue(sql.contains("\nORDER BY \"a\", \"b\"\nLIMIT 51"), sql)
        XCTAssertFalse(sql.contains("OFFSET"))
    }

    func testNoPrimaryKeyOrdersAndLocatesPhysically() {
        let sql = RowsFetcher.pageSQL(table: table(pk: []), filter: noFilter, offset: 0, pageSize: 10, spatial: false)
        XCTAssertTrue(sql.contains(#"(ctid::text || '@' || tableoid::oid::text) AS "__pgbrain_rowloc""#), sql)
        XCTAssertTrue(sql.contains("\nORDER BY tableoid, ctid\n"), sql)
    }

    func testViewsGetNoInventedOrder() {
        let sql = RowsFetcher.pageSQL(table: table(.view, pk: []), filter: noFilter, offset: 0, pageSize: 10, spatial: false)
        XCTAssertFalse(sql.contains("ORDER BY"))
        XCTAssertFalse(sql.contains("__pgbrain_rowloc"))
        let mv = RowsFetcher.pageSQL(table: table(.materializedView, pk: []), filter: noFilter, offset: 0, pageSize: 10, spatial: false)
        XCTAssertTrue(mv.contains("\nORDER BY ctid\n"))
    }

    func testSpatialProjectionUsesEWKT() {
        let t = TableNode(schema: "s", name: "g", kind: .table, columns: [
            ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 0),
            ColumnNode(name: "geom", typeName: "geometry(Point,4326)", nullable: true, ordinal: 1),
        ], primaryKey: ["id"])
        let sql = RowsFetcher.pageSQL(table: t, filter: noFilter, offset: 0, pageSize: 1, spatial: true)
        XCTAssertTrue(sql.contains(#"ST_AsEWKT("geom") AS "_pgb_1""#))
    }

    func testCountAndIsolatedWhere() {
        let sql = RowsFetcher.exactCountSQL(table: table(), filter: .init(whereClause: "a = 1 -- x", orderByClause: ""))
        XCTAssertEqual(sql, "SELECT COUNT(*)::bigint\nFROM \"s\".\"t\"\nWHERE a = 1 -- x\n")
        XCTAssertEqual(RowsFetcher.isolatedWhere("  a OR b -- c "), "(\na OR b -- c\n)")
        XCTAssertEqual(RowsFetcher.isolatedWhere("   "), "")
    }

    func testRowIdentity() {
        XCTAssertEqual(RowsFetcher.RowIdentity.resolve(for: table()), .primaryKey([table().columns[0]]))
        XCTAssertEqual(RowsFetcher.RowIdentity.resolve(for: table(pk: [])), .physical)
        XCTAssertEqual(RowsFetcher.RowIdentity.resolve(for: table(.view, pk: [])), .readOnly)
        XCTAssertEqual(RowsFetcher.RowIdentity.resolve(for: table(pk: ["missing"])), .readOnly)
    }

    func testEqualityPredicateAlwaysQuotesAndCasts() {
        let num = ColumnNode(name: "x", typeName: "double precision", nullable: true, ordinal: 0)
        XCTAssertEqual(RowsFetcher.equalityPredicate(column: num, value: "NaN"), #""x" = 'NaN'::double precision"#)
        let b = ColumnNode(name: "ok", typeName: "boolean", nullable: true, ordinal: 0)
        XCTAssertEqual(RowsFetcher.equalityPredicate(column: b, value: "t"), #""ok" = 't'::boolean"#)
        let j = ColumnNode(name: "doc", typeName: "json", nullable: true, ordinal: 0)
        XCTAssertEqual(RowsFetcher.equalityPredicate(column: j, value: "{}"), #""doc"::text = '{}'"#)
        XCTAssertEqual(RowsFetcher.equalityPredicate(column: b, value: nil), #""ok" IS NULL"#)
        XCTAssertEqual(UpdateApplier.quoteLiteral(#"it's C:\dir"#), #"E'it''s C:\\dir'"#)
    }

    // MARK: - Header sort parsing

    func testHeaderSortDirectionParsing() {
        func dir(_ order: String, _ col: String) -> RowsLoader.HeaderSortDirection {
            RowsLoader.headerSortDirection(orderBy: order, column: col)
        }
        XCTAssertEqual(dir("\"description\" ASC NULLS LAST", "description"), .ascending)
        XCTAssertEqual(dir("description", "description"), .ascending)
        XCTAssertEqual(dir("Description desc", "description"), .descending)
        XCTAssertEqual(dir("\"id\" DESC NULLS FIRST", "id"), .descending)
        XCTAssertEqual(dir("\"Name\" desc", "Name"), .descending)
        XCTAssertEqual(dir("Name desc", "Name"), .none, "bare identifiers fold to lower case")
        XCTAssertEqual(dir("id, name", "id"), .none)
        XCTAssertEqual(dir("id + 1", "id"), .none)
        XCTAssertEqual(dir("id NULLS", "id"), .none)
        XCTAssertEqual(dir("", "id"), .none)
        XCTAssertEqual(dir("\"description\"", "desc"), .none)
    }

    // MARK: - Live

    /// A WHERE ending in a line comment used to comment out LIMIT / OFFSET
    /// and fetch the whole table.
    func testTrailingCommentKeepsPagingAgainstLivePostgres() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int PRIMARY KEY, name text);
            INSERT INTO "\(s)".t SELECT g, 'n' || g FROM generate_series(1, 30) g
            """)
            let page = try await RowsFetcher.page(
                offset: 5, pageSize: 10, from: table(schema: s), client: db.client,
                filter: .init(whereClause: "id > 0 -- everything", orderByClause: ""))
            XCTAssertEqual(page.rows.count, 10)
            XCTAssertTrue(page.truncated)
            XCTAssertEqual(page.rows.first?.first ?? nil, "6", "default ORDER BY pk made the page deterministic")
            XCTAssertNil(page.rowLocators)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testPhysicalLocatorsComeBackForTablesWithoutPrimaryKey() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int, name text);
            INSERT INTO "\(s)".t VALUES (1,'a'),(1,'a'),(2,'b')
            """)
            let page = try await RowsFetcher.page(offset: 0, pageSize: 10, from: table(pk: [], schema: s), client: db.client)
            XCTAssertEqual(page.rows.count, 3)
            XCTAssertEqual(page.rows[0], ["1", "a"], "the locator column isn't part of the row")
            let locs = try XCTUnwrap(page.rowLocators)
            XCTAssertEqual(locs.count, 3)
            XCTAssertEqual(Set(locs.compactMap { $0 }).count, 3, "duplicate rows still have distinct locators")
            XCTAssertTrue(locs.allSatisfy { $0?.hasPrefix("(0,") == true && $0?.contains("@") == true })
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
