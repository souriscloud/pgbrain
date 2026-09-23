import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class A_AdminActionsTests: XCTestCase {
    private func service(_ db: TestDB) -> ConnectionService {
        let svc = ConnectionService(connection: Connection(name: "admin-test-a"))
        svc.attachClientForTests(db.client)
        return svc
    }
    private func ok<T>(_ r: Result<T, Error>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let e) = r { XCTFail("expected success, got \(e)", file: file, line: line) }
    }
    private func fails<T>(_ r: Result<T, Error>, file: StaticString = #filePath, line: UInt = #line) {
        if case .success = r { XCTFail("expected failure", file: file, line: line) }
    }

    // MARK: pure

    func testLiteral() {
        XCTAssertEqual(AdminActions.literal("it's"), "'it''s'")
        XCTAssertEqual(AdminActions.literal("a\\b'c"), "E'a\\\\b''c'")
        XCTAssertEqual(AdminActions.literal("x\0y"), "'xy'")
    }

    func testFunctionSpec() {
        XCTAssertEqual(AdminActions.functionSpec(schema: "s", signature: "f(integer)"), "\"s\".\"f\"(integer)")
        XCTAssertEqual(AdminActions.functionSpec(schema: "s", signature: "\"My F\"(text, int)"), "\"s\".\"My F\"(text, int)")
        XCTAssertEqual(AdminActions.functionSpec(schema: "s", signature: "f()"), "\"s\".\"f\"()")
        XCTAssertEqual(AdminActions.functionSpec(schema: "s", signature: "f(numeric(10,2))"), "\"s\".\"f\"(numeric(10,2))")
        for bad in ["f", "(int)", "f(int); DROP TABLE t()", "f(int) -- x)", "f(int))", "f('x')", "f(int /* c */)"] {
            XCTAssertNil(AdminActions.functionSpec(schema: "s", signature: bad), bad)
        }
    }

    func testPrivilegeWhitelist() async {
        let svc = ConnectionService(connection: Connection(name: "offline"))
        // Rejected before any connection is needed.
        let r = await AdminActions.setPrivileges(grant: true, privileges: ["SELECT", "SELECT ON t TO x; DROP TABLE y; --"],
                                                 schema: "s", table: "t", role: "r", service: svc)
        guard case .failure(AdminError.invalidInput) = r else { return XCTFail("expected invalidInput, got \(r)") }
    }

    // MARK: E2E

    func testCommentWithBackslashRoundTrips() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            let text = #"C:\temp\new 'quoted'"#
            ok(await AdminActions.setTableComment(schema: s, table: "t", comment: text, service: svc))
            let stored = try await db.scalarString("SELECT obj_description('\"\(s)\".t'::regclass, 'pg_class')")
            XCTAssertEqual(stored, text)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testSequenceActionsWithMixedCaseNames() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag() + "_Mixed"; await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE SEQUENCE \"\(s)\".\"Seq'Q\"")
            guard case .success(let v) = await AdminActions.setval(schema: s, sequence: "Seq'Q", value: 41, service: svc) else {
                return XCTFail("setval failed")
            }
            XCTAssertEqual(v, 41)
            guard case .success(let n) = await AdminActions.nextval(schema: s, sequence: "Seq'Q", service: svc) else {
                return XCTFail("nextval failed")
            }
            XCTAssertEqual(n, 42)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testDropFunctionResolvesViaServer() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".keep (id int)")
            _ = try await db.client.query(PostgresQuery(unsafeSQL:
                "CREATE PROCEDURE \"\(s)\".\"My Proc\"(a int) LANGUAGE sql AS $$ SELECT 1 $$"))
            // Injection attempt is refused and the table survives.
            fails(await AdminActions.dropFunction(schema: s, signature: "x(); DROP TABLE \"\(s)\".keep; --()", service: svc))
            let kept = try await db.scalarBool("SELECT to_regclass('\"\(s)\".keep') IS NOT NULL")
            XCTAssertTrue(kept)
            // A procedure is dropped with DROP PROCEDURE, quoted name included.
            ok(await AdminActions.dropFunction(schema: s, signature: "\"My Proc\"(integer)", service: svc))
            let gone = try await db.scalarBool("SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'My Proc')")
            XCTAssertTrue(gone)
            fails(await AdminActions.dropFunction(schema: s, signature: "absent(int)", service: svc))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testNotifyPayloadWithBackslashAndQuote() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        ok(await AdminActions.notify(channel: "Mixed Chan", payload: #"a\b 'c'"#, service: service(db)))
    }

    func testGrantToPublic() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            ok(await AdminActions.setPrivileges(grant: true, privileges: ["select"], schema: s, table: "t",
                                                role: "PUBLIC", service: svc))
            let n = try await db.scalarInt("""
            SELECT count(*)::int FROM pg_class c, LATERAL aclexplode(c.relacl) g
            WHERE c.oid = '"\(s)".t'::regclass AND g.grantee = 0 AND g.privilege_type = 'SELECT'
            """)
            XCTAssertEqual(n, 1)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
