import Foundation
import Logging
import Observation
import PostgresNIO
import NIOCore
import NIOSSL

/// Shared no-op logger for the (currently very chatty) PostgresNIO query
/// surface. Centralised so iter-11's Settings can swap it for a real logger
/// behind a verbose flag.
let pgbrainQuietLogger = Logger(label: "cloud.souris.pgbrain", factory: { _ in SwiftLogNoOpLogHandler() })

/// One per ConnectionWindow. Owns a PostgresClient and exposes a UI-friendly
/// state machine to SwiftUI views.
@MainActor
@Observable
final class ConnectionService {
    enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected(version: String, since: Date)
        case error(String)
        case closed
    }

    let connection: Connection
    private(set) var state: State = .idle
    private(set) var schema: SchemaSnapshot = .empty
    private(set) var schemaState: SchemaState = .idle
    let workspace = WorkspaceState()
    let operations = OperationsCenter()

    enum SchemaState: Sendable, Equatable {
        case idle, loading, loaded, error(String)
    }

    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private(set) var client: PostgresClient?

    init(connection: Connection) {
        self.connection = connection
    }

    deinit {
        clientTask?.cancel()
    }

    func start() {
        if case .connecting = state { return }
        if case .connected = state { return }
        state = .connecting
        Task { await self.connect() }
    }

    func retry() {
        shutdown()
        start()
    }

    func shutdown() {
        clientTask?.cancel()
        clientTask = nil
        client = nil
        state = .closed
    }

    /// Max time we wait for `SELECT version()` to come back before declaring
    /// the connect attempt dead. PostgresNIO's `.require` TLS against a
    /// server that doesn't speak TLS hangs silently with no error — without
    /// this timeout the UI would stay on "Connecting…" forever.
    private static let connectTimeoutSeconds: UInt64 = 15

    private func connect() async {
        let password = Keychain.password(for: connection.id) ?? ""
        let tls: PostgresClient.Configuration.TLS
        do {
            tls = try Self.tls(for: connection.sslMode)
        } catch {
            state = .error("TLS setup failed: \(error.localizedDescription)")
            return
        }

        let config = PostgresClient.Configuration(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password.isEmpty ? nil : password,
            database: connection.database.isEmpty ? nil : connection.database,
            tls: tls
        )

        let client = PostgresClient(configuration: config)
        self.client = client

        let task = Task.detached(priority: .userInitiated) {
            await client.run()
        }
        self.clientTask = task

        let timeout = Self.connectTimeoutSeconds
        let host = connection.host
        let sslLabel = connection.sslMode.rawValue
        do {
            let version: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    var v = "PostgreSQL"
                    let rows = try await client.query("SELECT version()")
                    for try await row in rows.decode(String.self) {
                        v = row
                        break
                    }
                    return v
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    // This text is what shows up in the connection error
                    // bubble — make it actionable.
                    throw ConnectError.timedOut(host: host, sslMode: sslLabel, seconds: Int(timeout))
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            self.state = .connected(version: version, since: Date())
            await self.loadSchema()
        } catch {
            self.state = .error(error.localizedDescription)
            task.cancel()
            self.clientTask = nil
            self.client = nil
        }
    }

    enum ConnectError: LocalizedError {
        case timedOut(host: String, sslMode: String, seconds: Int)

        var errorDescription: String? {
            switch self {
            case .timedOut(let host, let sslMode, let seconds):
                return """
                Couldn't connect to \(host) within \(seconds)s (SSL mode: \(sslMode)).

                Common causes:
                  • Host is unreachable (wrong address, firewall, VPN down)
                  • Server isn't listening on the port
                  • SSL mode set to require/verify-* but server doesn't speak TLS — try "prefer"
                """
            }
        }
    }

    func loadSchema() async {
        guard let client else { return }
        schemaState = .loading
        let op = operations.begin(kind: .schema, summary: "Loading schema for \(connection.database.isEmpty ? "default db" : connection.database)")
        do {
            schema = try await SchemaFetcher.fetch(client: client)
            schemaState = .loaded
            operations.finish(op, status: .succeeded)
        } catch {
            schemaState = .error(error.localizedDescription)
            operations.finish(op, status: .failed(error.localizedDescription))
        }
    }

    private static func tls(for mode: Connection.SSLMode) throws -> PostgresClient.Configuration.TLS {
        switch mode {
        case .disable:
            return .disable
        case .allow, .prefer:
            return .prefer(TLSConfiguration.makeClientConfiguration())
        case .require, .verifyCA, .verifyFull:
            return .require(TLSConfiguration.makeClientConfiguration())
        }
    }
}
