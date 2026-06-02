import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class ActivityFetcherTests: XCTestCase {

    func testFetchActivityRunsAndExcludesSelf() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let rows = try await ActivityFetcher.fetch(client: db.client)
        // Our own fetching backend is filtered out; whatever remains is valid.
        let myPID = try await db.scalarInt("SELECT pg_backend_pid()")
        XCTAssertFalse(rows.contains { $0.pid == Int32(myPID) }, "the fetching backend excludes itself")
    }

    func testCancelAndTerminateUnknownPidReturnFalse() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let cancelled = try await ActivityFetcher.cancel(pid: 2_000_000_000, client: db.client)
        let terminated = try await ActivityFetcher.terminate(pid: 2_000_000_000, client: db.client)
        XCTAssertFalse(cancelled, "no such backend ⇒ false")
        XCTAssertFalse(terminated)
    }

    func testIndexUsageFlagsUnusedNonConstraintIndexes() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int PRIMARY KEY, v text);
            CREATE INDEX t_v_idx ON "\(s)".t (v);
            """)
            let rows = try await IndexUsageFetcher.fetch(client: db.client)
            let mine = rows.filter { $0.schema == s }

            let plain = try XCTUnwrap(mine.first { $0.index == "t_v_idx" })
            XCTAssertTrue(plain.isUnused, "0 scans + no constraint ⇒ unused")
            XCTAssertEqual(plain.scans, 0)

            let pk = try XCTUnwrap(mine.first { $0.index.contains("pkey") })
            XCTAssertFalse(pk.isUnused, "constraint-backed index is never flagged unused")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testLockFetcherRuns() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        // No assertion on contents (depends on concurrent sessions) — this
        // exercises the query + decode without throwing.
        _ = try await LockFetcher.fetch(client: db.client)
    }
}

@MainActor
final class StatementStatsTests: XCTestCase {

    func testSortKeyMetadata() {
        XCTAssertEqual(StatementStatsFetcher.SortKey.allCases.count, 4)
        for k in StatementStatsFetcher.SortKey.allCases {
            XCTAssertEqual(k.id, k.rawValue)
            XCTAssertFalse(k.rawValue.isEmpty)
        }
    }

    func testIsInstalledReturnsBoolAndDataPathWhenPresent() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let installed = await StatementStatsFetcher.isInstalled(client: db.client)
        // Only exercise the data path when the extension is actually present —
        // we don't install it from a test (it needs shared_preload_libraries).
        if installed {
            _ = try await StatementStatsFetcher.fetch(limit: 5, sort: .mean, client: db.client)
            try await StatementStatsFetcher.reset(client: db.client)
        }
    }
}
