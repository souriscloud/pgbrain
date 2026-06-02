import Foundation
import XCTest
import PostgresNIO
import NIOSSL

/// E2E test fixture: a live `PostgresClient` against a throwaway database, plus
/// helpers to spin up and tear down isolated scratch schemas.
///
/// Target selection:
///   1. `PGBRAIN_TEST_DSN` — a `postgres://user:pass@host:port/db?sslmode=…` URL.
///   2. Otherwise localhost `pgbrain_demo` as the current `$USER` (matches the
///      local PG18 the project validates against by hand).
///
/// When nothing is reachable, `connectOrSkip` throws `XCTSkip` — so a machine
/// without Postgres (CI, a fresh clone) reports the data-layer tests as skipped,
/// not failed, and the release preflight's `swift test` gate still passes.
struct TestDB {
    /// How long the reachability probe waits before declaring the database
    /// absent and skipping. A live local server answers in well under a second.
    static let probeTimeoutSeconds: UInt64 = 5

    private struct Timeout: Error {}

    let client: PostgresClient
    private let runTask: Task<Void, Never>

    /// Build a client, start its run loop, and confirm the server answers a
    /// trivial query. Skips the calling test on any connection failure.
    static func connectOrSkip(file: StaticString = #filePath, line: UInt = #line) async throws -> TestDB {
        let config: PostgresClient.Configuration
        do {
            config = try makeConfiguration()
        } catch {
            throw XCTSkip("No test database configured: \(error)", file: file, line: line)
        }
        let client = PostgresClient(configuration: config)
        let runTask = Task { await client.run() }
        do {
            // Cheap reachability probe — distinguishes "no DB here" (skip) from
            // a real assertion failure later (fail). Bounded: PostgresClient's
            // pool retries connection creation for ~70s before its circuit
            // breaker trips, so race the probe against a short deadline and treat
            // a timeout as "no database" rather than letting the suite stall.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let rows = try await client.query("SELECT 1")
                    for try await _ in rows.decode(Int.self) { break }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.probeTimeoutSeconds * 1_000_000_000)
                    throw Timeout()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            runTask.cancel()
            throw XCTSkip("Test database unreachable (set PGBRAIN_TEST_DSN or run a local pgbrain_demo): \(error)",
                          file: file, line: line)
        }
        return TestDB(client: client, runTask: runTask)
    }

    /// Stop the client's background run loop. Call from the test's teardown path.
    func shutdown() {
        runTask.cancel()
    }

    // MARK: - Scratch-schema lifecycle

    /// A collision-resistant suffix so concurrent / repeated runs never clash and
    /// any orphan left by a crash is obvious in `\dn`.
    static func uniqueTag() -> String {
        "pgb_test_" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Execute one or more `;`-separated statements. PostgresNIO's extended
    /// query protocol is one-statement-per-round-trip, so we split and issue
    /// each separately (the test DDL has no semicolons inside literals).
    func exec(_ sql: String) async throws {
        let statements = sql
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for statement in statements {
            _ = try await client.query(PostgresQuery(unsafeSQL: statement))
        }
    }

    func scalarInt(_ sql: String) async throws -> Int {
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await v in rows.decode(Int.self) { return v }
        return 0
    }

    func scalarBool(_ sql: String) async throws -> Bool {
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await v in rows.decode(Bool.self) { return v }
        return false
    }

    func scalarString(_ sql: String) async throws -> String {
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await v in rows.decode(String.self) { return v }
        return ""
    }

    /// Drop the given schemas if present. Best-effort — used both to clean up
    /// leftovers before a run and to tear down after.
    func dropSchemas(_ names: String...) async {
        for name in names {
            _ = try? await client.query(PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \"\(name)\" CASCADE"))
        }
    }

    // MARK: - Configuration

    private struct NoTarget: Error, CustomStringConvertible {
        let description: String
    }

    private static func makeConfiguration() throws -> PostgresClient.Configuration {
        let env = ProcessInfo.processInfo.environment
        if let dsn = env["PGBRAIN_TEST_DSN"], !dsn.isEmpty {
            return try parse(dsn)
        }
        // Local fallback: plaintext loopback to pgbrain_demo as the login user.
        return PostgresClient.Configuration(
            host: "127.0.0.1",
            port: 5432,
            username: env["USER"] ?? "postgres",
            password: nil,
            database: "pgbrain_demo",
            tls: .disable
        )
    }

    /// Parse a `postgres://user:pass@host:port/db?sslmode=…` URL into a client
    /// configuration. `sslmode=disable` → no TLS; anything else → TLS without
    /// certificate verification (matches the app's `prefer`/`require` mapping —
    /// good enough for a test target hitting a known host).
    private static func parse(_ dsn: String) throws -> PostgresClient.Configuration {
        guard let url = URL(string: dsn),
              let scheme = url.scheme, scheme.hasPrefix("postgres") else {
            throw NoTarget(description: "PGBRAIN_TEST_DSN is not a postgres:// URL")
        }
        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? 5432
        let user = url.user?.removingPercentEncoding ?? (ProcessInfo.processInfo.environment["USER"] ?? "postgres")
        let password = url.password?.removingPercentEncoding
        let database = url.path.dropFirst().removingPercentEncoding ?? ""
        let sslmode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "sslmode" })?.value ?? "prefer"

        let tls: PostgresClient.Configuration.TLS
        if sslmode == "disable" {
            tls = .disable
        } else {
            var cfg = TLSConfiguration.makeClientConfiguration()
            cfg.certificateVerification = .none
            tls = .prefer(cfg)
        }
        return PostgresClient.Configuration(
            host: host, port: port,
            username: user, password: password,
            database: database.isEmpty ? nil : database,
            tls: tls
        )
    }
}
