import XCTest
import PostgresNIO
@testable import pgBrain

/// Drives the real `ConnectionService` connect path (probe → pooled client →
/// startup parameters → health) against the test database. Skips when no
/// database is reachable, like the other E2E tests.
@MainActor
final class D_ConnectionServiceLiveTests: XCTestCase {
    private var createdKeychainID: UUID?

    override func tearDown() async throws {
        if let id = createdKeychainID { Keychain.deletePassword(for: id) }
    }

    /// Same target as `TestDB`, expressed as a saved `Connection`.
    private func liveConnection() async throws -> Connection {
        let db = try await TestDB.connectOrSkip()
        db.shutdown()
        var c = Connection(name: "live", host: "127.0.0.1", port: 5432, database: "pgbrain_demo",
                           username: ProcessInfo.processInfo.environment["USER"] ?? "postgres", sslMode: .disable)
        if let dsn = ProcessInfo.processInfo.environment["PGBRAIN_TEST_DSN"], !dsn.isEmpty {
            let parsed = try ConnInfoParser.parse(dsn)
            c.sslMode = .prefer
            if let pw = ConnInfoParser.apply(parsed, to: &c), !pw.isEmpty {
                try Keychain.setPassword(pw, for: c.id)
                createdKeychainID = c.id
            }
        }
        return c
    }

    private func waitForState(_ service: ConnectionService, timeout: TimeInterval = 15,
                              _ predicate: (ConnectionService.State) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(service.state) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate(service.state)
    }

    private func scalar(_ client: PostgresClient, _ sql: String) async throws -> String {
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await value in rows.decode(String.self) { return value }
        return ""
    }

    func testStartupParametersReachTheSession() async throws {
        var c = try await liveConnection()
        c.readOnly = true
        c.statementTimeoutSeconds = 7
        c.idleInTransactionTimeoutSeconds = 11
        let service = ConnectionService(connection: c)
        service.start()
        let connected = await waitForState(service) { if case .connected = $0 { return true } else { return false } }
        guard connected, let client = service.client else {
            service.shutdown()
            return XCTFail("did not connect: \(service.state)")
        }
        XCTAssertNotNil(service.serverVersionNum)
        XCTAssertEqual(ConnectionService.knownServerVersionNum(for: c.id), service.serverVersionNum)
        let appName = try await scalar(client, "SHOW application_name")
        let readOnly = try await scalar(client, "SHOW default_transaction_read_only")
        let statementTimeout = try await scalar(client, "SHOW statement_timeout")
        let idleTimeout = try await scalar(client, "SHOW idle_in_transaction_session_timeout")
        XCTAssertEqual(appName, "pgBrain")
        XCTAssertEqual(readOnly, "on")
        XCTAssertEqual(statementTimeout, "7s")
        XCTAssertEqual(idleTimeout, "11s")
        do {
            _ = try await client.query("CREATE TEMP TABLE pgbrain_ro_probe (x int)")
            XCTFail("read-only session accepted a write")
        } catch {}
        let alive = await ConnectionService.ping(client, timeoutSeconds: 5)
        XCTAssertTrue(alive)
        service.shutdown()
        XCTAssertEqual(service.state, .closed)
        XCTAssertNil(service.client)
    }

    func testShutdownDuringConnectWins() async throws {
        let c = try await liveConnection()
        let service = ConnectionService(connection: c)
        service.start()
        service.shutdown()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(service.state, .closed, "a late connect must not resurrect a closed service")
        XCTAssertNil(service.client)
    }

    func testRetryDuringConnectEndsConnectedOnce() async throws {
        let c = try await liveConnection()
        let service = ConnectionService(connection: c)
        service.start()
        service.retry()
        let connected = await waitForState(service) { if case .connected = $0 { return true } else { return false } }
        XCTAssertTrue(connected, "\(service.state)")
        let client = service.client
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(service.client === client, "superseded attempt must not swap the client afterwards")
        service.shutdown()
    }

    func testWrongDatabaseSurfacesServerMessage() async throws {
        var c = try await liveConnection()
        c.database = "pgbrain_no_such_db_\(UUID().uuidString.prefix(6).lowercased())"
        let service = ConnectionService(connection: c)
        service.start()
        let failed = await waitForState(service) { if case .error = $0 { return true } else { return false } }
        XCTAssertTrue(failed)
        if case .error(let message) = service.state {
            XCTAssertTrue(message.contains("does not exist"), message)
        }
        service.shutdown()
    }
}
