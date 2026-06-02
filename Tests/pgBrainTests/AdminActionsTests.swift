import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class AdminActionsTests: XCTestCase {

    private func service(_ db: TestDB) -> ConnectionService {
        let svc = ConnectionService(connection: Connection(name: "admin-test"))
        svc.attachClientForTests(db.client)
        return svc
    }

    private func expectSuccess<T>(_ r: Result<T, Error>, _ msg: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let e) = r { XCTFail("expected success, got \(e). \(msg)", file: file, line: line) }
    }

    private func expectFailure<T>(_ r: Result<T, Error>, _ msg: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        if case .success = r { XCTFail("expected failure. \(msg)", file: file, line: line) }
    }

    // Async assertion helpers — XCTAssert's autoclosure can't host `await`, so
    // these bind the scalar first, then assert.
    private func dbTrue(_ db: TestDB, _ sql: String, _ msg: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await db.scalarBool(sql); XCTAssertTrue(v, msg, file: file, line: line)
    }
    private func dbFalse(_ db: TestDB, _ sql: String, _ msg: String = "",
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await db.scalarBool(sql); XCTAssertFalse(v, msg, file: file, line: line)
    }
    private func dbInt(_ db: TestDB, _ sql: String, _ expected: Int, _ msg: String = "",
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await db.scalarInt(sql); XCTAssertEqual(v, expected, msg, file: file, line: line)
    }

    // MARK: - Maintenance enum metadata (pure)

    func testMaintenanceMetadata() {
        XCTAssertEqual(AdminActions.Maintenance.allCases.count, 5)
        for m in AdminActions.Maintenance.allCases {
            XCTAssertEqual(m.id, m.rawValue)
            XCTAssertEqual(m.label, m.rawValue)
            XCTAssertFalse(m.help.isEmpty)
        }
        XCTAssertTrue(AdminActions.Maintenance.vacuumFull.isDestructive)
        XCTAssertTrue(AdminActions.Maintenance.reindex.isDestructive)
        XCTAssertFalse(AdminActions.Maintenance.analyze.isDestructive)
        XCTAssertFalse(AdminActions.Maintenance.vacuum.isDestructive)
    }

    // MARK: - AdminError

    func testAdminErrorDescriptions() {
        XCTAssertEqual(AdminError.notConnected.errorDescription, "Not connected.")
        XCTAssertEqual(AdminError.serverSaid("boom").errorDescription, "boom")
    }

    // MARK: - Not-connected guards

    func testNotConnectedReturnsFailure() async {
        let svc = ConnectionService(connection: Connection(name: "offline"))
        // No client attached.
        expectFailure(await AdminActions.createSchema(name: "x", service: svc))
        expectFailure(await AdminActions.runMaintenance(.analyze, on: "public", table: "t", service: svc))
        expectFailure(await AdminActions.setval(schema: "s", sequence: "q", value: 1, service: svc))
        expectFailure(await AdminActions.nextval(schema: "s", sequence: "q", service: svc))
        expectFailure(await AdminActions.executeBatch(["SELECT 1"], summary: "b", service: svc))
        // Empty batch short-circuits to success even with no client.
        expectSuccess(await AdminActions.executeBatch([], summary: "noop", service: svc))
        // Empty privilege set is a no-op success regardless of connection.
        expectSuccess(await AdminActions.setPrivileges(grant: true, privileges: [],
                                                       schema: "s", table: "t", role: "r", service: svc))
    }

    // MARK: - Maintenance E2E

    func testMaintenanceRuns() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int PRIMARY KEY, v text);
            INSERT INTO "\(s)".t SELECT g, 'x' FROM generate_series(1, 50) g;
            """)
            expectSuccess(await AdminActions.runMaintenance(.analyze, on: s, table: "t", service: svc))
            expectSuccess(await AdminActions.runMaintenance(.vacuum, on: s, table: "t", service: svc))
            expectSuccess(await AdminActions.runMaintenance(.vacuumAnalyze, on: s, table: "t", service: svc))
            expectSuccess(await AdminActions.runMaintenance(.reindex, on: s, table: "t", service: svc))
            // Each maintenance op was tracked and finished.
            XCTAssertTrue(svc.operations.operations.allSatisfy { $0.isFinished })
            XCTAssertGreaterThanOrEqual(svc.operations.operations.count, 4)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testMaintenanceFailureSurfacesServerError() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        // ANALYZE on a table that doesn't exist → server error → .failure.
        let r = await AdminActions.runMaintenance(.analyze, on: "public", table: "definitely_absent_xyz", service: svc)
        expectFailure(r)
        guard case .failure(AdminError.serverSaid) = r else { return XCTFail("expected serverSaid") }
        XCTAssertTrue(svc.operations.operations.contains { if case .failed = $0.status { return true }; return false })
    }

    // MARK: - Schema CRUD E2E

    func testSchemaCRUD() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); let s2 = TestDB.uniqueTag()
        await db.dropSchemas(s, s2)
        do {
            expectSuccess(await AdminActions.createSchema(name: s, service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='\(s)')")

            expectSuccess(await AdminActions.createTable(schema: s, name: "t", body: "id int PRIMARY KEY, name text", service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='\(s)' AND table_name='t')")

            expectSuccess(await AdminActions.renameSchema(from: s, to: s2, service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='\(s2)')")
            try await dbFalse(db, "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='\(s)')")

            // Without CASCADE, dropping a populated schema fails.
            expectFailure(await AdminActions.dropSchema(name: s2, cascade: false, service: svc))
            expectSuccess(await AdminActions.dropSchema(name: s2, cascade: true, service: svc))
            try await dbFalse(db, "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='\(s2)')")
        } catch { await db.dropSchemas(s, s2); throw error }
        await db.dropSchemas(s, s2)
    }

    // MARK: - Comments E2E

    func testComments() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            expectSuccess(await AdminActions.setTableComment(schema: s, table: "t", comment: "it's a table", service: svc))
            let tc = try await db.scalarString("SELECT obj_description('\"\(s)\".t'::regclass, 'pg_class')")
            XCTAssertEqual(tc, "it's a table", "apostrophe escaped correctly")

            expectSuccess(await AdminActions.setColumnComment(schema: s, table: "t", column: "id", comment: "the id", service: svc))
            let cc = try await db.scalarString("SELECT col_description('\"\(s)\".t'::regclass, 1)")
            XCTAssertEqual(cc, "the id")

            // nil comment clears it (COMMENT … IS NULL).
            expectSuccess(await AdminActions.setTableComment(schema: s, table: "t", comment: nil, service: svc))
            let cleared = try await db.scalarBool("SELECT obj_description('\"\(s)\".t'::regclass, 'pg_class') IS NULL")
            XCTAssertTrue(cleared)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - Sequences E2E

    func testSequenceActions() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE SEQUENCE \"\(s)\".q")

            let n1 = await AdminActions.nextval(schema: s, sequence: "q", service: svc)
            guard case .success(let v1) = n1 else { return XCTFail("nextval failed") }
            XCTAssertEqual(v1, 1)

            let setv = await AdminActions.setval(schema: s, sequence: "q", value: 100, service: svc)
            guard case .success(let v2) = setv else { return XCTFail("setval failed") }
            XCTAssertEqual(v2, 100)

            let n2 = await AdminActions.nextval(schema: s, sequence: "q", service: svc)
            guard case .success(let v3) = n2 else { return XCTFail("nextval failed") }
            XCTAssertEqual(v3, 101)

            expectSuccess(await AdminActions.restartSequence(schema: s, sequence: "q", to: 5, service: svc))
            let after = try await db.scalarInt("SELECT nextval('\"\(s)\".q')::int")
            XCTAssertEqual(after, 5)

            // Failure path: nonexistent sequence.
            expectFailure(await AdminActions.setval(schema: s, sequence: "absent", value: 1, service: svc))
            expectFailure(await AdminActions.nextval(schema: s, sequence: "absent", service: svc))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - Triggers E2E

    func testTriggers() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            // Run as single statements — the plpgsql body has an internal ';'
            // that TestDB.exec's naive splitter would mangle.
            _ = try await db.client.query(PostgresQuery(unsafeSQL:
                "CREATE FUNCTION \"\(s)\".noop() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$"))
            _ = try await db.client.query(PostgresQuery(unsafeSQL:
                "CREATE TRIGGER trg BEFORE INSERT ON \"\(s)\".t FOR EACH ROW EXECUTE FUNCTION \"\(s)\".noop()"))
            expectSuccess(await AdminActions.setTriggerEnabled(schema: s, table: "t", trigger: "trg", enabled: false, service: svc))
            let disabled = try await db.scalarString("SELECT tgenabled::text FROM pg_trigger WHERE tgname='trg'")
            XCTAssertEqual(disabled, "D", "DISABLE TRIGGER sets tgenabled='D'")

            expectSuccess(await AdminActions.setTriggerEnabled(schema: s, table: "t", trigger: "trg", enabled: true, service: svc))
            let enabled = try await db.scalarString("SELECT tgenabled::text FROM pg_trigger WHERE tgname='trg'")
            XCTAssertEqual(enabled, "O")

            expectSuccess(await AdminActions.dropTrigger(schema: s, table: "t", trigger: "trg", service: svc))
            try await dbFalse(db, "SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='trg')")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - Functions / views E2E

    func testFunctionsAndViews() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")

            expectSuccess(await AdminActions.saveFunctionBody(
                "CREATE OR REPLACE FUNCTION \"\(s)\".f(a int) RETURNS int LANGUAGE sql AS 'SELECT a + 1'",
                service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='\(s)' AND p.proname='f')")

            expectSuccess(await AdminActions.dropFunction(schema: s, signature: "f(integer)", service: svc))
            try await dbFalse(db, "SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='\(s)' AND p.proname='f')")

            expectSuccess(await AdminActions.saveViewBody(
                "CREATE OR REPLACE VIEW \"\(s)\".v AS SELECT id FROM \"\(s)\".t", service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM information_schema.views WHERE table_schema='\(s)' AND table_name='v')")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - Materialized view refresh E2E

    func testMaterializedViewRefresh() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int);
            INSERT INTO "\(s)".t VALUES (1),(2);
            CREATE MATERIALIZED VIEW "\(s)".mv AS SELECT id FROM "\(s)".t;
            CREATE UNIQUE INDEX mv_id ON "\(s)".mv (id);
            """)
            expectSuccess(await AdminActions.refreshMaterializedView(schema: s, name: "mv", concurrently: false, service: svc))
            // CONCURRENTLY needs the unique index we created above.
            expectSuccess(await AdminActions.refreshMaterializedView(schema: s, name: "mv", concurrently: true, service: svc))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - Column ALTERs + TRUNCATE E2E

    func testColumnAltersAndTruncate() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int GENERATED ALWAYS AS IDENTITY, raw text);
            INSERT INTO "\(s)".t (raw) VALUES ('1'),('2'),('3');
            """)
            // ADD COLUMN with default + NOT NULL.
            expectSuccess(await AdminActions.addColumn(schema: s, table: "t", name: "flag", type: "boolean",
                                                       nullable: false, defaultExpr: "true", service: svc))
            try await dbTrue(db, "SELECT bool_and(flag) FROM \"\(s)\".t")

            // ADD COLUMN nullable, no default (the other branch).
            expectSuccess(await AdminActions.addColumn(schema: s, table: "t", name: "note", type: "text",
                                                       nullable: true, defaultExpr: nil, service: svc))

            // ALTER COLUMN TYPE with USING.
            expectSuccess(await AdminActions.alterColumnType(schema: s, table: "t", column: "raw",
                                                            newType: "int", using: "raw::int", service: svc))
            let typ = try await db.scalarString("SELECT data_type FROM information_schema.columns WHERE table_schema='\(s)' AND table_name='t' AND column_name='raw'")
            XCTAssertEqual(typ, "integer")

            // ALTER COLUMN TYPE without USING (implicit cast int → bigint).
            expectSuccess(await AdminActions.alterColumnType(schema: s, table: "t", column: "raw",
                                                            newType: "bigint", using: nil, service: svc))

            // RENAME COLUMN.
            expectSuccess(await AdminActions.renameColumn(schema: s, table: "t", from: "note", to: "memo", service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='\(s)' AND table_name='t' AND column_name='memo')")

            // DROP COLUMN (non-cascade) and DROP COLUMN CASCADE.
            expectSuccess(await AdminActions.dropColumn(schema: s, table: "t", column: "memo", cascade: false, service: svc))
            expectSuccess(await AdminActions.dropColumn(schema: s, table: "t", column: "flag", cascade: true, service: svc))

            // TRUNCATE RESTART IDENTITY CASCADE.
            expectSuccess(await AdminActions.truncate(schema: s, table: "t", cascade: true, restartIdentity: true, service: svc))
            try await dbInt(db, "SELECT count(*)::int FROM \"\(s)\".t", 0)
            // After RESTART IDENTITY, the identity sequence is back to 1.
            try await db.exec("INSERT INTO \"\(s)\".t DEFAULT VALUES")
            try await dbInt(db, "SELECT min(id)::int FROM \"\(s)\".t", 1)

            // Plain TRUNCATE (no tails).
            expectSuccess(await AdminActions.truncate(schema: s, table: "t", cascade: false, restartIdentity: false, service: svc))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - GRANT / REVOKE E2E

    func testGrantRevoke() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        // A throwaway non-owner role — the table owner always has every
        // privilege implicitly, so GRANT/REVOKE can only be observed on a
        // distinct role. setPrivileges quotes the role, so PUBLIC can't be
        // exercised through it (it would resolve to a literal role "PUBLIC").
        let role = "pgb_role_" + UUID().uuidString.prefix(8).lowercased()
        _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP ROLE IF EXISTS \"\(role)\""))
        func dropRole() async { _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP ROLE IF EXISTS \"\(role)\"")) }
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            _ = try await db.client.query(PostgresQuery(unsafeSQL: "CREATE ROLE \"\(role)\" NOLOGIN"))

            expectSuccess(await AdminActions.setPrivileges(grant: true, privileges: ["SELECT", "INSERT"],
                                                           schema: s, table: "t", role: role, service: svc))
            try await dbTrue(db, "SELECT has_table_privilege('\(role)', '\"\(s)\".t', 'SELECT')")
            try await dbTrue(db, "SELECT has_table_privilege('\(role)', '\"\(s)\".t', 'INSERT')")

            expectSuccess(await AdminActions.setPrivileges(grant: false, privileges: ["INSERT"],
                                                           schema: s, table: "t", role: role, service: svc))
            try await dbFalse(db, "SELECT has_table_privilege('\(role)', '\"\(s)\".t', 'INSERT')")
            try await dbTrue(db, "SELECT has_table_privilege('\(role)', '\"\(s)\".t', 'SELECT')")
        } catch { await db.dropSchemas(s); await dropRole(); throw error }
        // Drop the schema (and its grants) before the role so DROP ROLE has no
        // dependent privileges left to block it.
        await db.dropSchemas(s)
        await dropRole()
    }

    // MARK: - NOTIFY, generated insert, execute, batch E2E

    func testNotifyGeneratedInsertExecuteAndBatch() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int, label text)")

            // NOTIFY with and without payload (no listener; just must succeed).
            expectSuccess(await AdminActions.notify(channel: "chan", payload: "it's here", service: svc))
            expectSuccess(await AdminActions.notify(channel: "chan", payload: "", service: svc))

            // Generated INSERT.
            expectSuccess(await AdminActions.runGeneratedInsert(
                "INSERT INTO \"\(s)\".t (id) SELECT generate_series(1,10)", summary: "gen", service: svc))
            try await dbInt(db, "SELECT count(*)::int FROM \"\(s)\".t", 10)

            // execute().
            expectSuccess(await AdminActions.execute("DELETE FROM \"\(s)\".t WHERE id > 5", summary: "del", service: svc))
            try await dbInt(db, "SELECT count(*)::int FROM \"\(s)\".t", 5)

            // executeBatch atomic success (blank/whitespace statements filtered).
            expectSuccess(await AdminActions.executeBatch([
                "UPDATE \"\(s)\".t SET label = 'a'",
                "   ",
                "UPDATE \"\(s)\".t SET label = 'b'"
            ], summary: "batch", service: svc))
            try await dbTrue(db, "SELECT bool_and(label = 'b') FROM \"\(s)\".t")

            // executeBatch rollback: second statement fails → first must not persist.
            let before = try await db.scalarInt("SELECT count(*)::int FROM \"\(s)\".t")
            expectFailure(await AdminActions.executeBatch([
                "INSERT INTO \"\(s)\".t (id) VALUES (99)",
                "INSERT INTO \"\(s)\".t (id) VALUES ('not a number')"
            ], summary: "bad batch", service: svc))
            try await dbInt(db, "SELECT count(*)::int FROM \"\(s)\".t", before, "failed batch rolled back")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    // MARK: - Database CRUD E2E

    func testDatabaseCRUD() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let svc = service(db)
        let me = try await db.scalarString("SELECT current_user")
        let enc = try await db.scalarString("SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = current_database()")
        let name1 = "pgb_db_" + UUID().uuidString.prefix(8).lowercased()
        let name2 = "pgb_db_" + UUID().uuidString.prefix(8).lowercased()
        // Best-effort pre-clean.
        _ = await AdminActions.dropDatabase(name: name1, force: true, service: svc)
        _ = await AdminActions.dropDatabase(name: name2, force: true, service: svc)
        do {
            // Plain create.
            expectSuccess(await AdminActions.createDatabase(name: name1, owner: nil, template: nil, encoding: nil, service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='\(name1)')")

            // Create with all option branches (owner/template/encoding).
            expectSuccess(await AdminActions.createDatabase(name: name2, owner: me, template: "template1", encoding: enc, service: svc))
            try await dbTrue(db, "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='\(name2)')")

            // Drop: plain + WITH (FORCE).
            expectSuccess(await AdminActions.dropDatabase(name: name1, force: false, service: svc))
            expectSuccess(await AdminActions.dropDatabase(name: name2, force: true, service: svc))
            try await dbFalse(db, "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='\(name1)')")
        } catch {
            _ = await AdminActions.dropDatabase(name: name1, force: true, service: svc)
            _ = await AdminActions.dropDatabase(name: name2, force: true, service: svc)
            throw error
        }
    }
}
