import Foundation
import XCTest
@testable import pgBrain

/// E2E: the scratchpad's pinned wire session — text-format rendering,
/// session affinity, transaction status, cancel. Uses the same target as
/// `TestDB` and skips when no database is reachable.
final class E_ScratchpadSessionTests: XCTestCase {

    static func endpointOrSkip(file: StaticString = #filePath, line: UInt = #line) async throws -> PGWireEndpoint {
        let env = ProcessInfo.processInfo.environment
        var endpoint = PGWireEndpoint(
            host: "127.0.0.1", port: 5432, tlsServerName: nil,
            username: env["USER"] ?? "postgres", password: nil,
            database: "pgbrain_demo", sslMode: .disable
        )
        if let dsn = env["PGBRAIN_TEST_DSN"], !dsn.isEmpty, let url = URL(string: dsn) {
            endpoint.host = url.host ?? "127.0.0.1"
            endpoint.port = url.port ?? 5432
            endpoint.username = url.user?.removingPercentEncoding ?? endpoint.username
            endpoint.password = url.password?.removingPercentEncoding
            endpoint.database = url.path.dropFirst().removingPercentEncoding
            let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "sslmode" })?.value ?? "prefer"
            endpoint.sslMode = mode == "disable" ? .disable : .prefer
        }
        endpoint.connectTimeoutSeconds = 5
        let probe = ScratchpadSession(endpoint: endpoint)
        defer { probe.close() }
        do {
            _ = try await probe.run("SELECT 1", rowLimit: 1)
        } catch {
            throw XCTSkip("Test database unreachable: \(error)", file: file, line: line)
        }
        return endpoint
    }

    private func value(_ session: ScratchpadSession, _ sql: String) async throws -> String? {
        let r = try await session.run(sql, rowLimit: 10)
        return r.result.page.rows.first?.first ?? nil
    }

    func testTypeRenderingMatchesServerText() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("SET TimeZone = 'Europe/Prague'", rowLimit: 1)
        _ = try await session.run("SET DateStyle = 'ISO, MDY'", rowLimit: 1)
        _ = try await session.run("SET IntervalStyle = 'postgres'", rowLimit: 1)
        _ = try await session.run("SET lc_monetary = 'C'", rowLimit: 1)

        let cases: [(String, String)] = [
            ("SELECT '13:45:07.123456'::time", "13:45:07.123456"),
            ("SELECT '13:45:07+02'::timetz", "13:45:07+02"),
            ("SELECT '1 day 02:03:04'::interval", "1 day 02:03:04"),
            ("SELECT ARRAY[1,2,3]::int[]", "{1,2,3}"),
            ("SELECT ARRAY['a b','c']::text[]", "{\"a b\",c}"),
            ("SELECT '192.168.0.1/24'::inet", "192.168.0.1/24"),
            ("SELECT 12.5::money", "$12.50"),
            ("SELECT point(1.5, 2)", "(1.5,2)"),
            ("SELECT 'NaN'::numeric", "NaN"),
            ("SELECT 'infinity'::timestamp", "infinity"),
            ("SELECT '-infinity'::date", "-infinity"),
            ("SELECT 12345678901234567890.123456789012345678901234567890::numeric",
             "12345678901234567890.123456789012345678901234567890"),
            ("SELECT '2024-03-05 10:11:12.345678'::timestamp", "2024-03-05 10:11:12.345678"),
            ("SELECT '2024-07-01 12:00:00+00'::timestamptz", "2024-07-01 14:00:00+02"),
            ("SELECT '0044-03-15 BC'::date", "0044-03-15 BC"),
            ("SELECT true", "true"),
            ("SELECT '\\xdeadbeef'::bytea", "\\xdeadbeef"),
            ("SELECT 'a'::\"char\"", "a"),
            ("SELECT '{\"a\": 1}'::jsonb", "{\"a\": 1}"),
            ("SELECT 'a1b2c3d4-0000-4000-8000-000000000001'::uuid", "a1b2c3d4-0000-4000-8000-000000000001"),
        ]
        for (sql, expected) in cases {
            let got = try await value(session, sql)
            XCTAssertEqual(got, expected, sql)
        }
        let null = try await session.run("SELECT NULL::int", rowLimit: 1)
        XCTAssertEqual(null.result.page.rows.first?.first ?? "x", nil)
    }

    func testColumnTypeNames() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        let r = try await session.run(
            "SELECT 1::int AS a, 'x'::varchar(12) AS b, 1.5::numeric(10,2) AS c, now() AS d, ARRAY[1]::int[] AS e, 'pg_class'::regclass AS f",
            rowLimit: 1)
        XCTAssertEqual(r.result.page.columns.map(\.name), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(r.result.page.columns.map(\.typeName), [
            "integer", "character varying(12)", "numeric(10,2)",
            "timestamp with time zone", "integer[]", "regclass",
        ])
    }

    func testAclitemAndPgClassDoNotFail() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        let r = try await session.run("SELECT * FROM pg_class", rowLimit: 5)
        XCTAssertFalse(r.result.page.columns.isEmpty)
        XCTAssertTrue(r.result.page.columns.contains { $0.typeName == "aclitem[]" })
        let acl = try await value(session, "SELECT makeaclitem(0, 0, 'SELECT', false)")
        XCTAssertEqual(acl, "=r/0")
    }

    func testSessionAffinityAcrossRuns() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("SET application_name = 'pgbrain_affinity'", rowLimit: 1)
        _ = try await session.run("CREATE TEMP TABLE e_affinity(x int)", rowLimit: 1)
        _ = try await session.run("INSERT INTO e_affinity VALUES (1), (2)", rowLimit: 1)
        let name = try await value(session, "SHOW application_name")
        XCTAssertEqual(name, "pgbrain_affinity")
        let count = try await value(session, "SELECT count(*) FROM e_affinity")
        XCTAssertEqual(count, "2")
    }

    func testTransactionStatusTracking() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("CREATE TEMP TABLE e_tx(x int)", rowLimit: 1)
        let begin = try await session.run("BEGIN", rowLimit: 1)
        XCTAssertEqual(begin.transaction, .active)
        let insert = try await session.run("INSERT INTO e_tx VALUES (1)", rowLimit: 1)
        XCTAssertEqual(insert.transaction, .active)
        XCTAssertEqual(insert.result.rowsAffected, 1)
        do {
            _ = try await session.run("SELECT 1/0", rowLimit: 1)
            XCTFail("expected division by zero")
        } catch let err as PGServerError {
            XCTAssertEqual(err.sqlState, "22012")
        }
        let status = try await session.run("ROLLBACK", rowLimit: 1)
        XCTAssertEqual(status.transaction, .idle)
        XCTAssertEqual(status.result.commandTag, "ROLLBACK")
        let count = try await value(session, "SELECT count(*) FROM e_tx")
        XCTAssertEqual(count, "0")
    }

    func testFailedTransactionReportsFailedStatus() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("BEGIN", rowLimit: 1)
        _ = try? await session.run("SELECT 1/0", rowLimit: 1)
        let probe = try? await session.run("SELECT 1", rowLimit: 1)
        XCTAssertNil(probe)
        let rb = try await session.run("ROLLBACK", rowLimit: 1)
        XCTAssertEqual(rb.transaction, .idle)
    }

    func testRowCapAppliesToWrites() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("CREATE TEMP TABLE e_cap(x int)", rowLimit: 1)
        let r = try await session.run("INSERT INTO e_cap SELECT g FROM generate_series(1, 5000) g RETURNING x", rowLimit: 100)
        XCTAssertEqual(r.result.page.rows.count, 100)
        XCTAssertTrue(r.result.page.truncated)
        XCTAssertEqual(r.result.commandTag, "INSERT 0 5000")
    }

    func testNoticesAreCollected() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        let r = try await session.run("DO $$ BEGIN RAISE NOTICE 'hello %', 42; END $$", rowLimit: 1)
        XCTAssertEqual(r.result.notices, ["NOTICE: hello 42"])
    }

    func testCancelTargetsOwnBackend() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        let bystander = ScratchpadSession(endpoint: endpoint)
        defer { session.close(); bystander.close() }
        _ = try await session.run("SELECT 1", rowLimit: 1)
        _ = try await bystander.run("SELECT 1", rowLimit: 1)
        XCTAssertNotEqual(session.backendPID, bystander.backendPID)

        let ticket = session.makeTicket()
        async let victim: ScratchpadSession.Response = session.run("SELECT pg_sleep(20)", rowLimit: 1, ticket: ticket)
        async let other: ScratchpadSession.Response = bystander.run("SELECT pg_sleep(1.5), 'ok'", rowLimit: 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        let started = Date()
        await session.cancel(ticket)
        do {
            _ = try await victim
            XCTFail("expected cancellation")
        } catch let err as PGServerError {
            XCTAssertTrue(err.isQueryCanceled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let survivor = try await other
        XCTAssertEqual(survivor.result.page.rows.first?[1], "ok")
        let after = try await value(session, "SELECT 'alive'")
        XCTAssertEqual(after, "alive")
    }

    func testCancelOfFinishedTicketIsNoOp() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        let ticket = session.makeTicket()
        _ = try await session.run("SELECT 1", rowLimit: 1, ticket: ticket)
        await session.cancel(ticket)
        let r = try await session.run("SELECT pg_sleep(0.3), 'fine'", rowLimit: 1)
        XCTAssertEqual(r.result.page.rows.first?[1], "fine")
    }

    func testCancelledQueuedTicketNeverRuns() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("CREATE TEMP TABLE e_q(x int)", rowLimit: 1)
        let queued = session.makeTicket()
        await session.cancel(queued)
        do {
            _ = try await session.run("INSERT INTO e_q VALUES (1)", rowLimit: 1, ticket: queued)
            XCTFail("expected cancelled")
        } catch let err as PGWireError {
            XCTAssertEqual(err, .cancelled)
        }
        let count = try await value(session, "SELECT count(*) FROM e_q")
        XCTAssertEqual(count, "0")
    }

    func testTaskCancellationCancelsServerSide() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        _ = try await session.run("SELECT 1", rowLimit: 1)
        let task = Task { try await session.run("SELECT pg_sleep(20)", rowLimit: 1) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        let outcome = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        if case .success = outcome { XCTFail("expected an error") }
    }

    func testReconnectsAfterBackendTerminated() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        let killer = ScratchpadSession(endpoint: endpoint)
        defer { session.close(); killer.close() }
        _ = try await session.run("SELECT 1", rowLimit: 1)
        let pid = try XCTUnwrap(session.backendPID)
        _ = try await killer.run("SELECT pg_terminate_backend(\(pid))", rowLimit: 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let r = try await session.run("SELECT 'back'", rowLimit: 1)
        XCTAssertEqual(r.result.page.rows.first?.first, "back")
        XCTAssertTrue(r.reconnected)
        XCTAssertNotEqual(session.backendPID, pid)
    }

    func testCopyToStdoutRendersLines() async throws {
        let endpoint = try await Self.endpointOrSkip()
        let session = ScratchpadSession(endpoint: endpoint)
        defer { session.close() }
        let r = try await session.run("COPY (SELECT g, 'x' FROM generate_series(1,3) g) TO STDOUT", rowLimit: 10)
        XCTAssertEqual(r.result.page.rows.map { $0.first ?? nil }, ["1\tx", "2\tx", "3\tx"])
        do {
            _ = try await session.run("COPY pg_class FROM STDIN", rowLimit: 1)
            XCTFail("COPY FROM STDIN must fail cleanly")
        } catch is PGServerError {}
        let alive = try await value(session, "SELECT 'still'")
        XCTAssertEqual(alive, "still")
    }

    func testScramProofMatchesRFC7677Vector() throws {
        var scram = PGScramSHA256(password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO", username: "user")
        XCTAssertEqual(scram.clientFirstMessage, "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = try scram.clientFinalMessage(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        XCTAssertEqual(final, "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        XCTAssertTrue(scram.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
    }

    func testMD5Response() {
        let r = PGMD5Auth.response(user: "alice", password: "secret", salt: [1, 2, 3, 4])
        XCTAssertEqual(r, "md598a0412b9c31436fc53776e863350083")
    }
}
