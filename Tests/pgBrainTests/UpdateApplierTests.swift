import XCTest
import PostgresNIO
@testable import pgBrain

/// E2E coverage of the cell-edit write path. The bind-indexing logic (only
/// literal cells consume a `$N`; expression/DEFAULT cells inline raw SQL) is the
/// high-risk part — a miscount produces a wrong `$N` and a server error, so
/// driving real UPDATE/INSERT/DELETE batches against a live table both exercises
/// the code and proves the SQL is well-formed.
final class UpdateApplierTests: XCTestCase {

    private func col(_ t: TableNode, _ name: String) -> ColumnNode {
        t.columns.first { $0.name == name }!
    }

    /// `t (id pk, n int, s text, j jsonb, note text DEFAULT 'def-note')`, one row.
    private func makeT(_ db: TestDB, _ schema: String) async throws -> TableNode {
        try await db.exec("""
        CREATE TABLE "\(schema)".t (
            id   integer PRIMARY KEY,
            n    integer,
            s    text,
            j    jsonb,
            note text DEFAULT 'def-note'
        );
        INSERT INTO "\(schema)".t (id, n, s, j, note) VALUES (1, 10, 'a', '{"k": 1}', 'orig');
        """)
        return TableNode(schema: schema, name: "t", kind: .table, columns: [
            ColumnNode(name: "id",   typeName: "integer", nullable: false, ordinal: 0),
            ColumnNode(name: "n",    typeName: "integer", nullable: true,  ordinal: 1),
            ColumnNode(name: "s",    typeName: "text",    nullable: true,  ordinal: 2),
            ColumnNode(name: "j",    typeName: "jsonb",   nullable: true,  ordinal: 3),
            ColumnNode(name: "note", typeName: "text",    nullable: true,  ordinal: 4),
        ], primaryKey: ["id"])
    }

    // MARK: UPDATE + bind indexing

    func testUpdateMixesLiteralExpressionDefaultWithCorrectBinds() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("CREATE SCHEMA \"\(schema)\"")
            let t = try await makeT(db, schema)
            let rows: [[String?]] = [["1", "10", "a", "{\"k\": 1}", "orig"]]

            let edit = UpdateApplier.Edit(rowIndex: 0, cells: [
                .init(column: col(t, "n"), value: .literal("99")),          // $1::integer
                .init(column: col(t, "j"), value: .literal("{\"k\": 2}")),  // $2::jsonb
                .init(column: col(t, "s"), value: .expression("upper('zz')")), // no bind
                .init(column: col(t, "note"), value: .defaultKeyword),       // no bind
            ])
            // A no-op edit with empty cells and one out of range — both skipped.
            let emptyEdit = UpdateApplier.Edit(rowIndex: 0, cells: [])
            let oobEdit = UpdateApplier.Edit(rowIndex: 99, cells: [
                .init(column: col(t, "n"), value: .literal("0"))])

            try await UpdateApplier.apply(edits: [edit, emptyEdit, oobEdit],
                                          table: t, originalRows: rows, client: db.client)

            // WHERE id = $3 must have bound "1" — if expression/DEFAULT had been
            // miscounted as binds, this row wouldn't have matched.
            let n = try await db.scalarInt("SELECT n FROM \"\(schema)\".t WHERE id=1")
            let s = try await db.scalarString("SELECT s FROM \"\(schema)\".t WHERE id=1")
            let note = try await db.scalarString("SELECT note FROM \"\(schema)\".t WHERE id=1")
            let jMatch = try await db.scalarBool("SELECT j = '{\"k\": 2}'::jsonb FROM \"\(schema)\".t WHERE id=1")
            XCTAssertEqual(n, 99)
            XCTAssertEqual(s, "ZZ")
            XCTAssertEqual(note, "def-note")
            XCTAssertTrue(jMatch)
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }

    // MARK: INSERT

    func testInsertLiteralExpressionAndOmittedDefault() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("CREATE SCHEMA \"\(schema)\"")
            let t = try await makeT(db, schema)
            let insert = UpdateApplier.Insert(cells: [
                .init(column: col(t, "id"), value: .literal("2")),          // $1::integer
                .init(column: col(t, "n"), value: .literal("20")),          // $2::integer
                .init(column: col(t, "s"), value: .expression("lower('XY')")), // inlined
                .init(column: col(t, "note"), value: .defaultKeyword),       // omitted → DEFAULT
            ])
            try await UpdateApplier.apply(edits: [], inserts: [insert],
                                          table: t, originalRows: [], client: db.client)

            let n = try await db.scalarInt("SELECT n FROM \"\(schema)\".t WHERE id=2")
            let s = try await db.scalarString("SELECT s FROM \"\(schema)\".t WHERE id=2")
            let note = try await db.scalarString("SELECT note FROM \"\(schema)\".t WHERE id=2")
            let jNull = try await db.scalarBool("SELECT j IS NULL FROM \"\(schema)\".t WHERE id=2")
            XCTAssertEqual(n, 20)
            XCTAssertEqual(s, "xy")
            XCTAssertEqual(note, "def-note")
            XCTAssertTrue(jNull)
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }

    func testInsertEmptyAndAllDefaultCellsUseDefaultValues() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(schema)";
            CREATE TABLE "\(schema)".d (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, x integer DEFAULT 7);
            """)
            let d = TableNode(schema: schema, name: "d", kind: .table, columns: [
                ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 0),
                ColumnNode(name: "x",  typeName: "integer", nullable: true,  ordinal: 1),
            ], primaryKey: ["id"])

            let emptyInsert = UpdateApplier.Insert(cells: [])                       // → DEFAULT VALUES
            let allDefault = UpdateApplier.Insert(cells: [.init(column: col(d, "x"), value: .defaultKeyword)]) // → DEFAULT VALUES
            try await UpdateApplier.apply(edits: [], inserts: [emptyInsert, allDefault],
                                          table: d, originalRows: [], client: db.client)

            let total = try await db.scalarInt("SELECT count(*) FROM \"\(schema)\".d")
            let sevens = try await db.scalarInt("SELECT count(*) FROM \"\(schema)\".d WHERE x=7")
            XCTAssertEqual(total, 2)
            XCTAssertEqual(sevens, 2)
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }

    // MARK: DELETE

    func testDeleteByPrimaryKeyAndNullPkComponent() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("CREATE SCHEMA \"\(schema)\"")
            let t = try await makeT(db, schema)
            try await db.exec("INSERT INTO \"\(schema)\".t (id,n) VALUES (2,20),(3,30)")

            // Delete id=2 (rowIndex 0), skip an out-of-range delete, and a NULL-PK
            // delete that matches nothing via the `IS NULL` branch.
            let rows: [[String?]] = [["2", nil, nil, nil, nil], [nil, nil, nil, nil, nil]]
            try await UpdateApplier.apply(edits: [],
                                          deletes: [.init(rowIndex: 0), .init(rowIndex: 1), .init(rowIndex: 99)],
                                          table: t, originalRows: rows, client: db.client)

            let has2 = try await db.scalarBool("SELECT EXISTS(SELECT 1 FROM \"\(schema)\".t WHERE id=2)")
            let has1 = try await db.scalarBool("SELECT EXISTS(SELECT 1 FROM \"\(schema)\".t WHERE id=1)")
            let has3 = try await db.scalarBool("SELECT EXISTS(SELECT 1 FROM \"\(schema)\".t WHERE id=3)")
            XCTAssertFalse(has2)
            XCTAssertTrue(has1)
            XCTAssertTrue(has3)
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }

    // MARK: failure modes

    func testApplyThrowsWithoutPrimaryKey() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let noPK = TableNode(schema: "public", name: "v", kind: .table, columns: [
            ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 0)
        ], primaryKey: [])
        await XCTAssertThrowsErrorAsync(
            try await UpdateApplier.apply(edits: [], table: noPK, originalRows: [], client: db.client)
        ) {
            guard case UpdateApplier.Failure.noPrimaryKey = $0 else {
                return XCTFail("expected .noPrimaryKey, got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("no primary key"))
        }
    }

    func testApplyThrowsWhenPkColumnMissingFromResultSet() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let badPK = TableNode(schema: "public", name: "t", kind: .table, columns: [
            ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 0)
        ], primaryKey: ["missing"])
        await XCTAssertThrowsErrorAsync(
            try await UpdateApplier.apply(edits: [], table: badPK, originalRows: [], client: db.client)
        ) {
            guard case UpdateApplier.Failure.unknownPrimaryKeyColumn("missing") = $0 else {
                return XCTFail("expected .unknownPrimaryKeyColumn(missing), got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("missing"))
        }
    }

    func testUpdateOnVanishedRowThrowsStaleRowAndRollsBackBatch() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("CREATE SCHEMA \"\(schema)\"")
            let t = try await makeT(db, schema)                       // id=1
            try await db.exec("INSERT INTO \"\(schema)\".t (id,n) VALUES (2,20)")
            // The grid loaded both rows…
            let rows: [[String?]] = [
                ["2", "20", nil, nil, nil],   // rowIndex 0 → id=2 (still present)
                ["1", "10", nil, nil, nil],   // rowIndex 1 → id=1 (about to vanish)
            ]
            // …then id=1 was deleted out from under us.
            try await db.exec("DELETE FROM \"\(schema)\".t WHERE id=1")

            let edits = [
                UpdateApplier.Edit(rowIndex: 0, cells: [.init(column: col(t, "n"), value: .literal("222"))]),
                UpdateApplier.Edit(rowIndex: 1, cells: [.init(column: col(t, "n"), value: .literal("111"))]),
            ]
            await XCTAssertThrowsErrorAsync(
                try await UpdateApplier.apply(edits: edits, table: t, originalRows: rows, client: db.client)
            ) {
                guard case UpdateApplier.Failure.staleRow(let pk) = $0 else {
                    return XCTFail("expected .staleRow, got \($0)")
                }
                XCTAssertTrue(pk.contains("id=1"))
                XCTAssertTrue($0.localizedDescription.contains("no longer exists"))
            }
            // The id=2 update (applied first) must be rolled back by the batch abort.
            let n2 = try await db.scalarInt("SELECT n FROM \"\(schema)\".t WHERE id=2")
            XCTAssertEqual(n2, 20, "the whole transaction rolled back — id=2 unchanged")
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }

    // MARK: operation tracking (cancellation attach)

    func testUpdateRegistersCancellableOperation() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let schema = TestDB.uniqueTag(); await db.dropSchemas(schema)
        do {
            try await db.exec("CREATE SCHEMA \"\(schema)\"")
            let t = try await makeT(db, schema)
            // OperationsCenter is @MainActor; build it (and read its id) there.
            let (center, opID): (OperationsCenter, UUID) = await MainActor.run {
                let c = OperationsCenter()
                return (c, c.begin(kind: .update, summary: "test update").id)
            }
            let edit = UpdateApplier.Edit(rowIndex: 0, cells: [
                .init(column: col(t, "n"), value: .literal("42"))])
            try await UpdateApplier.apply(edits: [edit], table: t,
                                          originalRows: [["1", "10", "a", "{\"k\": 1}", "orig"]],
                                          client: db.client, operationID: opID, tracker: center)
            let n = try await db.scalarInt("SELECT n FROM \"\(schema)\".t WHERE id=1")
            XCTAssertEqual(n, 42)
        } catch { await db.dropSchemas(schema); throw error }
        await db.dropSchemas(schema)
    }
}
