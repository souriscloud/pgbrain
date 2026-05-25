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
            await self.loadSchema()
        } catch {
            self.state = .error(error.localizedDescription)
            task.cancel()
            self.clientTask = nil
            self.client = nil
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
