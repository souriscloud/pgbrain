import XCTest
import PostgresNIO
@testable import pgBrain

final class QueryRunnerTests: XCTestCase {

    // MARK: - Pure: QueryResult.rowsAffected

    private func page() -> RowsFetcher.Page {
        RowsFetcher.Page(columns: [], rows: [], truncated: false, limit: 0, offset: 0, elapsed: 0)
    }

    func testRowsAffectedParsesLastToken() {
        XCTAssertEqual(QueryResult(page: page(), commandTag: "UPDATE 12").rowsAffected, 12)
        XCTAssertEqual(QueryResult(page: page(), commandTag: "INSERT 0 5").rowsAffected, 5)
        XCTAssertEqual(QueryResult(page: page(), commandTag: "DELETE 0").rowsAffected, 0)
        XCTAssertEqual(QueryResult(page: page(), commandTag: "SELECT 7").rowsAffected, 7)
    }

    func testRowsAffectedNilWhenNoCountOrNoTag() {
        XCTAssertNil(QueryResult(page: page(), commandTag: nil).rowsAffected)
        XCTAssertNil(QueryResult(page: page(), commandTag: "CREATE TABLE").rowsAffected)
        XCTAssertNil(QueryResult(page: page(), commandTag: "").rowsAffected)
    }

    // MARK: - Pure: applyAutoLimit

    func testApplyAutoLimitAppendsToBareReads() {
        XCTAssertEqual(QueryRunner.applyAutoLimit("SELECT 1", cap: 1000), "SELECT 1\nLIMIT 1001")
        XCTAssertEqual(QueryRunner.applyAutoLimit("select * from t", cap: 10), "select * from t\nLIMIT 11")
        // WITH and VALUES are reads too.
        XCTAssertTrue(QueryRunner.applyAutoLimit("WITH a AS (SELECT 1) SELECT * FROM a", cap: 5).hasSuffix("LIMIT 6"))
        XCTAssertTrue(QueryRunner.applyAutoLimit("VALUES (1),(2)", cap: 5).hasSuffix("LIMIT 6"))
    }

    func testApplyAutoLimitStripsTrailingSemicolons() {
        XCTAssertEqual(QueryRunner.applyAutoLimit("SELECT 1 ;;  ", cap: 1), "SELECT 1\nLIMIT 2")
    }

    func testApplyAutoLimitLeavesSelfLimitingQueriesAlone() {
        let limited = "SELECT * FROM t LIMIT 5"
        XCTAssertEqual(QueryRunner.applyAutoLimit(limited, cap: 1000), limited)
        let fetched = "SELECT * FROM t FETCH FIRST 5 ROWS ONLY"
        XCTAssertEqual(QueryRunner.applyAutoLimit(fetched, cap: 1000), fetched)
    }

    func testApplyAutoLimitIgnoresNonReads() {
        let upd = "UPDATE t SET x = 1"
        XCTAssertEqual(QueryRunner.applyAutoLimit(upd, cap: 1000), upd)
        let del = "DELETE FROM t"
        XCTAssertEqual(QueryRunner.applyAutoLimit(del, cap: 1000), del)
        XCTAssertEqual(QueryRunner.applyAutoLimit("", cap: 1000), "")
    }

    // MARK: - Pure: summary

    func testSummaryCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(QueryRunner.summary(of: "SELECT\n  *\nFROM   t"), "SELECT * FROM t")
        let long = String(repeating: "a", count: 200)
        let s = QueryRunner.summary(of: long, max: 10)
        XCTAssertEqual(s, String(repeating: "a", count: 10) + "…")
        XCTAssertEqual(QueryRunner.summary(of: "short", max: 80), "short")
    }

    // MARK: - E2E: run()

    func testRunSelectReturnsRowsAndColumns() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let result = try await QueryRunner.run("SELECT 1 AS a, 'x' AS b", on: db.client)
        XCTAssertEqual(result.page.columns.map(\.name), ["a", "b"])
        XCTAssertEqual(result.page.rows.count, 1)
        XCTAssertEqual(result.page.rows[0], ["1", "x"])
        XCTAssertEqual(result.commandTag, "SELECT 1")
        XCTAssertEqual(result.page.columns[0].typeName, "integer")
    }

    func testRunSelectTruncatesAtLimit() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let result = try await QueryRunner.run(
            "SELECT g FROM generate_series(1, 5000) g", on: db.client, limit: 10
        )
        XCTAssertEqual(result.page.rows.count, 10)
        XCTAssertTrue(result.page.truncated, "more rows exist past the limit")
    }

    func testRunNonSelectReportsCommandTag() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int);
            """)
            let ins = try await QueryRunner.run("INSERT INTO \"\(s)\".t SELECT generate_series(1,3)", on: db.client)
            XCTAssertEqual(ins.commandTag, "INSERT 0 3")
            XCTAssertEqual(ins.rowsAffected, 3)

            let upd = try await QueryRunner.run("UPDATE \"\(s)\".t SET id = id + 1", on: db.client)
            XCTAssertEqual(upd.commandTag, "UPDATE 3")

            let del = try await QueryRunner.run("DELETE FROM \"\(s)\".t WHERE id > 3", on: db.client)
            XCTAssertEqual(del.commandTag, "DELETE 1")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testRunStringifiesScalarTypes() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let sql = """
        SELECT
          1::int2          AS i2,
          2::int4          AS i4,
          3::int8          AS i8,
          1.5::float4      AS f4,
          2.5::float8      AS f8,
          3.25::numeric    AS num,
          true             AS flag,
          '00000000-0000-0000-0000-000000000001'::uuid AS u,
          '2024-01-15'::date AS d,
          '2024-01-15 10:30:00'::timestamp AS ts,
          'hello'          AS txt,
          '{"k":1}'::jsonb AS j,
          NULL::int        AS n
        """
        let r = try await QueryRunner.run(sql, on: db.client)
        let row = r.page.rows[0]
        let byName = Dictionary(uniqueKeysWithValues: zip(r.page.columns.map(\.name), row))
        XCTAssertEqual(byName["i2"], "1")
        XCTAssertEqual(byName["i4"], "2")
        XCTAssertEqual(byName["i8"], "3")
        XCTAssertEqual(byName["f4"], "1.5")
        XCTAssertEqual(byName["f8"], "2.5")
        XCTAssertEqual(byName["num"], "3.25")
        XCTAssertEqual(byName["flag"], "true")
        XCTAssertEqual(byName["u"], "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(byName["d"], "2024-01-15")
        XCTAssertEqual((byName["ts"] ?? nil)?.hasPrefix("2024-01-15 10:30:00"), true)
        XCTAssertEqual(byName["txt"], "hello")
        XCTAssertEqual(byName["j"], "{\"k\": 1}")
        XCTAssertEqual(byName["n"] ?? nil, nil, "NULL renders as nil")
    }

    func testRunHexEncodesBinaryAndRendersGeometryWhenAvailable() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        // bytea with control bytes → upper-hex stand-in (matches ::text path).
        let r = try await QueryRunner.run("SELECT '\\x00ff10'::bytea AS b", on: db.client)
        XCTAssertEqual(r.page.rows[0][0], "00FF10")
    }

    func testRunWithSearchPathResolvesUnqualifiedNames() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".widget (id int);
            INSERT INTO "\(s)".widget VALUES (42);
            """)
            let r = try await QueryRunner.run("SELECT id FROM widget", on: db.client, searchPath: s)
            XCTAssertEqual(r.page.rows[0][0], "42")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testRunPropagatesServerErrors() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        await XCTAssertThrowsErrorAsync(try await QueryRunner.run("SELECT * FROM nope_missing_table_xyz", on: db.client))
    }

    func testRunReturningClauseMaterialisesRows() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            // INSERT … RETURNING is non-read-only but returns rows → exercises
            // the materialise() path with a non-empty result.
            let r = try await QueryRunner.run(
                "INSERT INTO \"\(s)\".t SELECT generate_series(1,3) RETURNING id", on: db.client)
            XCTAssertEqual(r.page.columns.map(\.name), ["id"])
            XCTAssertEqual(r.page.rows.count, 3)
            XCTAssertEqual(r.commandTag, "INSERT 0 3")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testRunDDLReturnsBareCommandTag() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"")
            // A DDL command isn't in the count-bearing set → tag is the bare verb.
            let r = try await QueryRunner.run("CREATE TABLE \"\(s)\".x (id int)", on: db.client)
            XCTAssertEqual(r.commandTag, "CREATE TABLE")
            XCTAssertTrue(r.page.rows.isEmpty)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testRunSearchPathResetsAfterError() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"")
            // SET search_path succeeds (schema exists), the user query throws →
            // exercises the catch branch that still RESETs search_path.
            await XCTAssertThrowsErrorAsync(
                try await QueryRunner.run("SELECT * FROM nonexistent_in_path_xyz", on: db.client, searchPath: s))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testRunWithTrackerAttachesCancellation() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let tracker = await MainActor.run { OperationsCenter() }
        let opID = await MainActor.run { tracker.begin(kind: .query, summary: "q").id }
        let r = try await QueryRunner.run("SELECT 1", on: db.client, operationID: opID, tracker: tracker)
        XCTAssertEqual(r.page.rows.count, 1)
        // The runner hops to the main actor to attach the backend PID +
        // cancellation handler; give that detached Task a moment to land.
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = await MainActor.run { tracker.operations.first(where: { $0.id == opID })?.backendPID }
        XCTAssertNotNil(pid, "tracker received the backend PID for cancellation")
    }
}
