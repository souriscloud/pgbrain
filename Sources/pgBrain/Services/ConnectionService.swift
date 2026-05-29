import Foundation
import Logging
import Observation
import PostgresNIO
import NIOCore
import NIOPosix
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
    /// Per-tab loader cache. Keeping these on the service (not in
    /// `@State` on the tab view) makes switching tabs free — the row
    /// page stays in memory and the user only re-fetches when they
    /// hit the refresh button or ⌘R explicitly.
    @ObservationIgnored private var loaderCache: [UUID: RowsLoader] = [:]
    @ObservationIgnored private var inspectorCache: [UUID: InspectorLoader] = [:]
    /// Raw schema as returned by the server — every namespace included.
    /// Most callers should prefer `visibleSchema`, which strips schemas
    /// the user has hidden via the sidebar's "Schemas" menu.
    private(set) var schema: SchemaSnapshot = .empty
    private(set) var schemaState: SchemaState = .idle

    /// `schema` with hidden namespaces removed. Drives the sidebar
    /// tree, the command palette tables/schemas categories, and the
    /// SQL completion provider so hiding is a single source of truth.
    var visibleSchema: SchemaSnapshot {
        let hidden = SchemaVisibility.shared.hidden(for: connection.id)
        if hidden.isEmpty { return schema }
        var snap = schema
        snap.schemas.removeAll { hidden.contains($0.name) }
        return snap
    }
    let workspace = WorkspaceState()
    let operations = OperationsCenter()
    let toasts = ToastCenter()

    /// Lightweight, decorative server vitals shown in the sidebar header.
    /// Refreshed whenever the schema (re)loads, so the database size tracks
    /// inserts/imports. Never surfaces errors — it's chrome, not a feature.
    struct ServerInfo: Sendable, Equatable {
        var versionShort: String     // "PostgreSQL 16.2"
        var databaseSize: String     // "24 MB"
    }
    private(set) var serverInfo: ServerInfo?

    /// Table/schema counts for the header, derived from the loaded snapshot.
    var schemaCount: Int { schema.schemas.count }
    var tableCount: Int { schema.schemas.reduce(0) { $0 + $1.tables.count } }

    enum SchemaState: Sendable, Equatable {
        case idle, loading, loaded, error(String)
    }

    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private(set) var client: PostgresClient?

    init(connection: Connection) {
        self.connection = connection
        // Prune cached loaders/inspectors when their tab disappears
        // — otherwise closed-tab loaders leak for the workspace's
        // lifetime and re-opening the same table would reuse a stale
        // edit buffer.
        workspace.onTabClosed = { [weak self] id in
            self?.loaderCache.removeValue(forKey: id)
            self?.inspectorCache.removeValue(forKey: id)
        }
        // Surface operation outcomes as toasts. Failures and cancellations
        // toast for every kind; successes only for the "notable" actions —
        // queries and schema fetches succeed constantly and would be noise.
        operations.onFinish = { [weak self] op in
            self?.emitToast(for: op)
        }
    }

    private func emitToast(for op: OperationsCenter.Operation) {
        switch op.status {
        case .running:
            break
        case .succeeded:
            switch op.kind {
            case .export, .importJob, .update:
                toasts.show(.success, op.summary)
            case .query, .schema:
                break
            }
        case .cancelled:
            toasts.show(.info, "Cancelled: \(op.summary)")
        case .failed(let message):
            // Server messages can be paragraphs; keep the toast tight and
            // let the operations popover hold the full text.
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
            toasts.show(.error, "\(op.kind.label) failed — \(clipped)")
        }
    }

    deinit {
        clientTask?.cancel()
    }

    /// Fetch (or lazily create) the row loader for a `.table` tab.
    /// Same `tab.id` always returns the same instance so switching
    /// away from + back to a tab doesn't re-fetch.
    func loader(for tab: WorkspaceState.Tab, table: TableNode) -> RowsLoader {
        if let cached = loaderCache[tab.id] { return cached }
        let loader = RowsLoader(table: table, service: self)
        loaderCache[tab.id] = loader
        return loader
    }

    /// Inspector cache — same caching contract as `loader(for:table:)`.
    /// The Structure / DDL panes draw from this so flipping panes
    /// doesn't re-issue the catalog queries.
    func inspector(for tab: WorkspaceState.Tab, table: TableNode) -> InspectorLoader {
        if let cached = inspectorCache[tab.id] { return cached }
        let inspector = InspectorLoader(table: table, service: self)
        inspectorCache[tab.id] = inspector
        return inspector
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
        // Tear down the SSH tunnel if one was started for this
        // connection. No-op when ssh isn't in use.
        SSHTunnelManager.shared.stopTunnel(for: connection.id)
    }

    /// Hard timeout for the long-running `PostgresClient`-pooled path —
    /// reserved as a last-resort cap if the pre-flight probe somehow lets a
    /// bad config through.
    private static let connectTimeoutSeconds: UInt64 = 15

    private func connect() async {
        let password = Keychain.password(for: connection.id) ?? ""

        // ---- SSH TUNNEL (optional) --------------------------------------
        // When enabled, swap the connection's effective host:port for a
        // local-forward port owned by SSHTunnelManager. The TLS probe +
        // pool below then talk to localhost which ssh forwards through.
        var effectiveHost = connection.host
        var effectivePort = connection.port
        if connection.sshEnabled {
            do {
                let localPort = try await SSHTunnelManager.shared.startTunnel(for: connection)
                effectiveHost = "127.0.0.1"
                effectivePort = localPort
            } catch {
                state = .error("SSH tunnel failed: \(error.localizedDescription)")
                return
            }
        }

        // ---- PRE-FLIGHT PROBE -------------------------------------------
        // PostgresClient's connection pool silently retries on auth /
        // protocol failures forever and never surfaces the real error.
        // A raw `PostgresConnection.connect()` does, in <10ms. Use that
        // first to validate credentials + reachability and turn a generic
        // "Connecting…" into a "wrong password for user X" or similar.
        let probeOutcome = await Self.probe(
            connection: connection, password: password,
            overrideHost: effectiveHost, overridePort: effectivePort
        )
        if case .failure(let message) = probeOutcome {
            state = .error(message)
            return
        }

        // ---- POOL FOR REAL SESSION --------------------------------------
        let tls: PostgresClient.Configuration.TLS
        do {
            tls = try Self.tls(for: connection.sslMode)
        } catch {
            state = .error("TLS setup failed: \(error.localizedDescription)")
            return
        }
        let config = PostgresClient.Configuration(
            host: effectiveHost,
            port: effectivePort,
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

        // Belt-and-braces timeout in case anything slips past the probe.
        let timeout = Self.connectTimeoutSeconds
        let host = connection.host
        let sslLabel = connection.sslMode.rawValue
        do {
            let version: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    var v = "PostgreSQL"
                    let rows = try await client.query("SELECT version()")
                    for try await row in rows.decode(String.self) { v = row; break }
                    return v
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
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

    /// Result of a one-shot `PostgresConnection.connect()` probe. We always
    /// close the probe connection so we don't leave an orphan socket — the
    /// real session uses a separate pooled connection.
    enum ProbeOutcome: Sendable {
        case ok
        case failure(String)
    }

    nonisolated static func probe(
        connection: Connection, password: String,
        overrideHost: String? = nil, overridePort: Int? = nil
    ) async -> ProbeOutcome {
        // Mirror the libpq mapping from `tls(for:)` — `prefer`/`require`
        // skip cert validation entirely; only `verify-ca`/`verify-full`
        // engage the chain check. Without this, every connection to
        // AWS RDS (or anything not in the system trust) fails with
        // CERTIFICATE_VERIFY_FAILED.
        let tls: PostgresConnection.Configuration.TLS
        do {
            var sslConfig = TLSConfiguration.makeClientConfiguration()
            switch connection.sslMode {
            case .disable:
                tls = .disable
            case .allow, .prefer:
                sslConfig.certificateVerification = .none
                tls = .prefer(try NIOSSLContext(configuration: sslConfig))
            case .require:
                sslConfig.certificateVerification = .none
                tls = .require(try NIOSSLContext(configuration: sslConfig))
            case .verifyCA:
                sslConfig.certificateVerification = .noHostnameVerification
                tls = .require(try NIOSSLContext(configuration: sslConfig))
            case .verifyFull:
                sslConfig.certificateVerification = .fullVerification
                tls = .require(try NIOSSLContext(configuration: sslConfig))
            }
        } catch {
            return .failure("TLS setup failed: \(error.localizedDescription)")
        }
        var config = PostgresConnection.Configuration(
            host: overrideHost ?? connection.host,
            port: overridePort ?? connection.port,
            username: connection.username,
            password: password.isEmpty ? nil : password,
            database: connection.database.isEmpty ? nil : connection.database,
            tls: tls
        )
        // 8s on the wire-level connect: covers DNS + TCP + TLS + auth.
        config.options.connectTimeout = .seconds(8)

        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let connectionID = Int.random(in: 0..<Int(Int32.max))
        do {
            let conn = try await PostgresConnection.connect(
                on: eventLoop,
                configuration: config,
                id: connectionID,
                logger: pgbrainQuietLogger
            ).get()
            try? await conn.close()
            return .ok
        } catch let psql as PSQLError {
            return .failure(friendlyMessage(from: psql, connection: connection))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Translate a `PSQLError` into a one-line user-readable message.
    /// Prefers the server's own `Message` field when present (covers
    /// auth-fail / wrong-db / etc.); falls back to the underlying NIO
    /// transport error description for DNS / connection-refused.
    nonisolated private static func friendlyMessage(from error: PSQLError, connection: Connection) -> String {
        if let server = error.serverInfo, let msg = server[.message] {
            return msg
        }
        if let underlying = error.underlying {
            let s = String(reflecting: underlying)
            if s.contains("UnknownHost") {
                if connection.host.contains(":") {
                    return "Host \"\(connection.host)\" looks like host:port — move the port number into the Port field and leave just the hostname here."
                }
                return "Host \"\(connection.host)\" not found (DNS lookup failed). Check the address and your network."
            }
            if s.contains("Connection refused") {
                return "Connection refused by \(connection.host):\(connection.port). Server isn't listening on that port, or a firewall is blocking it."
            }
            if s.contains("timeout") || s.contains("Connect timeout") {
                return "Connect to \(connection.host):\(connection.port) timed out. Host unreachable or behind a VPN that's down."
            }
            return "Connection error: \(underlying)"
        }
        return "Connection failed (\(error.code))"
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

    /// Fetch the server version + database size for the header. Best-effort:
    /// any failure leaves `serverInfo` as-is (decorative, never alarming).
    func loadServerInfo() async {
        guard let client else { return }
        do {
            let rows = try await client.query(
                "SELECT current_setting('server_version'), pg_size_pretty(pg_database_size(current_database()))"
            )
            for try await (version, size) in rows.decode((String, String).self) {
                // server_version can read "16.2" or "14.11 (Ubuntu …)" — keep
                // just the version number.
                let short = version.split(separator: " ").first.map(String.init) ?? version
                serverInfo = ServerInfo(versionShort: "PostgreSQL \(short)", databaseSize: size)
                break
            }
        } catch {
            // Intentionally silent.
        }
    }

    func loadSchema() async {
        guard let client else { return }
        schemaState = .loading
        let op = operations.begin(kind: .schema, summary: "Loading schema for \(connection.database.isEmpty ? "default db" : connection.database)")
        do {
            // Phase 1 — shallow fetch (no columns). Fast, makes the
            // sidebar usable in <1s even on big DBs.
            schema = try await SchemaFetcher.fetch(client: client)
            schemaState = .loaded
            operations.finish(op, status: .succeeded)
            // Refresh header vitals off the critical path.
            Task { [weak self] in await self?.loadServerInfo() }
            // Phase 2 — background column enrichment so completion +
            // hover light up for every table eventually, without
            // blocking the user from doing real work.
            Task { [weak self] in
                guard let self else { return }
                let enrichOp = operations.begin(kind: .schema, summary: "Loading column details")
                do {
                    let columns = try await SchemaFetcher.fetchColumnsAll(client: client)
                    self.schema = self.schema.merging(columns: columns)
                    self.operations.finish(enrichOp, status: .succeeded)
                } catch {
                    self.operations.finish(enrichOp, status: .failed(error.localizedDescription))
                }
            }
        } catch {
            schemaState = .error(error.localizedDescription)
            operations.finish(op, status: .failed(error.localizedDescription))
        }
    }

    /// On-demand single-table column load. Used by `RowsLoader` when
    /// it opens a table whose columns haven't reached the snapshot
    /// from the phase-2 enrichment yet. Returns a TableNode with
    /// `columns` populated; no-op (returns the input) if columns are
    /// already loaded or the fetch fails.
    func ensureColumns(for table: TableNode) async -> TableNode {
        if !table.columns.isEmpty { return table }
        guard let client else { return table }
        do {
            let cols = try await SchemaFetcher.fetchColumns(
                for: table.schema, table: table.name, client: client
            )
            schema = schema.mergingColumns(forSchema: table.schema, table: table.name, columns: cols)
            var enriched = table
            enriched.columns = cols
            return enriched
        } catch {
            return table
        }
    }

    /// Maps our `Connection.SSLMode` (libpq-style) to PostgresNIO's
    /// `(TLS mode, certificate verification)` pair. Matches libpq semantics:
    ///
    ///   - `disable` → no TLS
    ///   - `allow`/`prefer` → try TLS, **no cert verification**
    ///   - `require` → TLS required, **no cert verification** (libpq does
    ///     not validate at this level; that's `verify-ca`/`verify-full`'s job)
    ///   - `verify-ca` → TLS required, validate the chain but NOT the hostname
    ///   - `verify-full` → TLS required, full chain + hostname verification
    private static func tls(for mode: Connection.SSLMode) throws -> PostgresClient.Configuration.TLS {
        var config = TLSConfiguration.makeClientConfiguration()
        switch mode {
        case .disable:
            return .disable
        case .allow, .prefer:
            config.certificateVerification = .none
            return .prefer(config)
        case .require:
            config.certificateVerification = .none
            return .require(config)
        case .verifyCA:
            config.certificateVerification = .noHostnameVerification
            return .require(config)
        case .verifyFull:
            config.certificateVerification = .fullVerification
            return .require(config)
        }
    }
}
