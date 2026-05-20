import Foundation
import Observation
import PostgresNIO
import NIOCore
import NIOSSL

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

    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private var client: PostgresClient?

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

        do {
            var version = "PostgreSQL"
            let rows = try await client.query("SELECT version()")
            for try await (v) in rows.decode(String.self) {
                version = v
                break
            }
            self.state = .connected(version: version, since: Date())
        } catch {
            self.state = .error(error.localizedDescription)
            task.cancel()
            self.clientTask = nil
            self.client = nil
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
