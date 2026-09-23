import XCTest
import PostgresNIO
@testable import pgBrain

final class A_SchemaDuplicatorTests: XCTestCase {
    private func rt(_ sql: String, _ src: String = "app", _ tgt: String = "new") -> String {
        SchemaDuplicator.retarget(sql, from: src, to: tgt)
    }

    // MARK: pure retarget

    func testOnlyQualifierTokensChange() {
        XCTAssertEqual(rt("SELECT app.t, myapp.t, x.app.z FROM app.u"),
                       "SELECT \"new\".t, myapp.t, x.app.z FROM \"new\".u")
    }

    func testStringsAndCommentsUntouched() {
        XCTAssertEqual(rt("SELECT 'app.x', E'app\\'.y', /* app.c */ 1 -- app.d\n FROM app.t"),
                       "SELECT 'app.x', E'app\\'.y', /* app.c */ 1 -- app.d\n FROM \"new\".t")
    }

    func testQuotedAndCaseFolding() {
        XCTAssertEqual(rt("\"app\".t JOIN App.u"), "\"new\".t JOIN \"new\".u")
        // A mixed-case schema only matches its quoted spelling.
        XCTAssertEqual(rt("\"MyApp\".t JOIN MyApp.u", "MyApp", "Clone"), "\"Clone\".t JOIN MyApp.u")
    }

    func testRegclassLiteralIsRetargeted() {
        XCTAssertEqual(rt("nextval('app.t_id_seq'::regclass)"), "nextval('\"new\".t_id_seq'::regclass)")
        XCTAssertEqual(rt("'app'::regnamespace"), "'\"new\"'::regnamespace")
        XCTAssertEqual(rt("'app.t'::text"), "'app.t'::text", "only reg* casts name objects")
    }

    func testDollarQuotedBodyIsCode() {
        let def = "CREATE FUNCTION app.f() RETURNS int AS $function$ SELECT count(*) FROM app.t WHERE s <> 'app.t' $function$"
        XCTAssertEqual(rt(def),
                       "CREATE FUNCTION \"new\".f() RETURNS int AS $function$ SELECT count(*) FROM \"new\".t WHERE s <> 'app.t' $function$")
    }

    func testTargetNeedingQuotes() {
        XCTAssertEqual(rt("app.t", "app", "Weird \"x\""), "\"Weird \"\"x\"\"\".t")
    }

    // MARK: E2E

    func testFunctionsAndPrivilegesClone() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let tag = TestDB.uniqueTag()
        let src = "\(tag)_src", dst = "\(tag)_dst"
        await db.dropSchemas(src, dst)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(src)";
            CREATE TABLE "\(src)".t (id serial PRIMARY KEY, note text);
            INSERT INTO "\(src)".t (note) VALUES ('\(src).literal'), ('b');
            CREATE TABLE "\(src)".u (id int);
            GRANT SELECT ON "\(src)".t TO PUBLIC;
            GRANT SELECT ON "\(src)".u TO PUBLIC
            """)
            _ = try await db.client.query(PostgresQuery(unsafeSQL: """
            CREATE FUNCTION "\(src)".n() RETURNS bigint LANGUAGE sql AS $body$
              SELECT count(*) FROM "\(src)".t WHERE note <> '\(src).literal'
            $body$
            """))
            var opts = SchemaDuplicator.Options()
            opts.privileges = true
            try await SchemaDuplicator.duplicate(client: db.client, from: src, to: dst, options: opts)

            try await db.exec("INSERT INTO \"\(src)\".t (note) VALUES ('only-in-src')")
            let n = try await db.scalarInt("SELECT \"\(dst)\".n()::int")
            XCTAssertEqual(n, 1, "cloned function reads the cloned table and keeps its string literal")
            let publicGrants = try await db.scalarInt("""
            SELECT count(*)::int FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace,
                   LATERAL aclexplode(c.relacl) g
            WHERE ns.nspname = '\(dst)' AND g.grantee = 0 AND g.privilege_type = 'SELECT'
            """)
            XCTAssertEqual(publicGrants, 2, "both grants copied (privileges pass no longer aborts mid-stream)")
            let literalKept = try await db.scalarInt("SELECT count(*)::int FROM \"\(dst)\".t WHERE note = '\(src).literal'")
            XCTAssertEqual(literalKept, 1)
        } catch { await db.dropSchemas(src, dst); throw error }
        await db.dropSchemas(src, dst)
    }

    func testMixedCaseSchemaClones() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let tag = TestDB.uniqueTag()
        let src = "\(tag)_Src", dst = "\(tag)_Dst"
        await db.dropSchemas(src, dst)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(src)";
            CREATE TABLE "\(src)"."Items" (id serial PRIMARY KEY, v text);
            INSERT INTO "\(src)"."Items" (v) VALUES ('a'), ('b')
            """)
            try await SchemaDuplicator.duplicate(client: db.client, from: src, to: dst, options: .init())
            try await db.exec("INSERT INTO \"\(dst)\".\"Items\" (v) VALUES ('c')")
            let maxID = try await db.scalarInt("SELECT max(id) FROM \"\(dst)\".\"Items\"")
            XCTAssertEqual(maxID, 3, "serial default repointed to the clone's sequence, which continues at 3")
            let srcRows = try await db.scalarInt("SELECT count(*)::int FROM \"\(src)\".\"Items\"")
            XCTAssertEqual(srcRows, 2)
        } catch { await db.dropSchemas(src, dst); throw error }
        await db.dropSchemas(src, dst)
    }
}
