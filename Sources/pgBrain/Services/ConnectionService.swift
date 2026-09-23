import AppKit
import Foundation
import Logging
import Network
import Observation
import PostgresNIO
import NIOCore
import NIOPosix
import NIOSSL

/// Shared no-op logger for per-query PostgresNIO calls, which are too chatty
/// to log even in verbose mode. Client-level logging goes through
/// `Log.postgresClientLogger()`.
let pgbrainQuietLogger = Logger(label: "cloud.souris.pgbrain", factory: { _ in SwiftLogNoOpLogHandler() })

/// One per ConnectionWindow. Owns a PostgresClient and exposes a UI-friendly
/// state machine to SwiftUI views.
///
/// Lifecycle: every `start()` bumps a generation counter; `shutdown()` bumps
/// it again and cancels the in-flight connect, so a connect that finishes
/// after the window closed (or after a `retry()`) discards its client and
/// releases its SSH tunnel instead of resurrecting a dead service.
///
/// Health: while connected, a monitor pings the server every 30s, on wake
/// from sleep, on network-path changes and when the SSH tunnel's process
/// exits. A failed ping starts a background reconnect with backoff; `health`
/// reports progress and, after a few failed attempts, `state` flips to
/// `.error` so the window shows it (the reconnect keeps going).
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

    /// Liveness of an established session, orthogonal to `state` so views
    /// that switch exhaustively on `State` keep compiling.
    enum Health: Sendable, Equatable {
        case healthy
        case reconnecting(attempt: Int)
        case lost(String)
    }

    let connection: Connection
    private(set) var state: State = .idle
    private(set) var health: Health = .healthy
    /// `server_version_num` of the connected server (e.g. 170002).
    private(set) var serverVersionNum: Int?
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
        var postgis: String?         // PostGIS extension version, nil if absent
    }
    private(set) var serverInfo: ServerInfo?

    /// True when the connected database has the PostGIS extension — gates
    /// spatial conveniences (WKT rendering, the map view).
    var hasPostGIS: Bool { serverInfo?.postgis != nil }

    /// Table/schema counts for the header, derived from the loaded snapshot.
    var schemaCount: Int { schema.schemas.count }
    var tableCount: Int { schema.schemas.reduce(0) { $0 + $1.tables.count } }

    enum SchemaState: Sendable, Equatable {
        case idle, loading, loaded, error(String)
    }

    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private(set) var client: PostgresClient?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var pathCheckTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private let observers = ObserverBag()
    @ObservationIgnored private let ownerID = UUID().uuidString
    @ObservationIgnored private var tunnelOwner: String?
    /// Pools replaced by a background reconnect, kept running for a grace
    /// period so queries already in flight on them can finish.
    @ObservationIgnored private var retiredPools: [Task<Void, Never>] = []
    @ObservationIgnored private var consecutivePingFailures = 0

    init(connection: Connection) {
        self.connection = connection
        // New scratchpads on this connection start scoped to its
        // configured default schema (empty = unscoped).
        workspace.defaultSearchPath = connection.defaultSearchPath
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
        connectTask?.cancel()
        recoveryTask?.cancel()
        healthTask?.cancel()
        pathCheckTask?.cancel()
        pathMonitor?.cancel()
        for pool in retiredPools { pool.cancel() }
        observers.removeAll()
        if let owner = tunnelOwner {
            let id = connection.id
            Task { @MainActor in SSHTunnelManager.shared.release(connectionID: id, owner: owner) }
        }
    }

    /// Fetch (or lazily create) the row loader for a `.table` tab.
    /// Same `tab.id` always returns the same instance so switching
    /// away from + back to a tab doesn't re-fetch.
    func loader(for tab: WorkspaceState.Tab, table: TableNode) -> RowsLoader {
        if let cached = loaderCache[tab.id] { return cached }
        let loader = RowsLoader(table: table, service: self)
        loader.tab = tab
        loaderCache[tab.id] = loader
        return loader
    }

    /// After a schema reload re-pointed tabs at fresh `TableNode`s (rename,
    /// primary-key change), hand them to the cached loaders so UPDATE /
    /// DELETE target the right relation and key.
    func syncLoadersWithTabs() {
        for tab in workspace.tabs {
            guard let table = tab.tableNode, let loader = loaderCache[tab.id] else { continue }
            loader.adoptTable(table)
        }
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

    // MARK: - Lifecycle

    func start() {
        switch state {
        case .connecting, .connected: return
        case .idle, .error, .closed: break
        }
        generation &+= 1
        let gen = generation
        state = .connecting
        health = .healthy
        connectTask = Task { [weak self] in await self?.connect(generation: gen) }
    }

    /// Retry / Reconnect rebuild only the pool. Scratchpad sessions are
    /// independent sockets: closing a healthy one would make the server
    /// silently roll back its open transaction, and a dead one reopens
    /// itself on the next run anyway.
    func retry() {
        tearDownPool()
        start()
    }

    /// Manual "Reconnect": drops the pooled session and connects afresh.
    /// Tabs, loaders, scratchpad sessions and the workspace survive.
    func reconnect() {
        retry()
    }

    /// Window close: the pool, every scratchpad session and the per-tab
    /// caches go. Loaders hold the service strongly, so the caches must be
    /// emptied here or the service never deallocates.
    func shutdown() {
        tearDownPool()
        for tab in workspace.tabs {
            if case .scratchpad(let pad) = tab.kind { pad.closeSession() }
        }
        Self.releaseEndpoint(for: connection, owner: scratchpadTunnelOwner)
        loaderCache.removeAll()
        inspectorCache.removeAll()
    }

    private func tearDownPool() {
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        stopHealthMonitor()
        clientTask?.cancel()
        clientTask = nil
        for pool in retiredPools { pool.cancel() }
        retiredPools.removeAll()
        client = nil
        state = .closed
        health = .healthy
        consecutivePingFailures = 0
        releaseTunnel()
    }

    /// Tunnel owner shared by every scratchpad session in this window, so
    /// their direct wire connections keep the SSH forward alive exactly as
    /// long as the window.
    var scratchpadTunnelOwner: String { "\(ownerID)#scratchpads" }

    private func releaseTunnel() {
        if let owner = tunnelOwner {
            SSHTunnelManager.shared.release(connectionID: connection.id, owner: owner)
        }
        tunnelOwner = nil
    }

    /// Hard timeout for the long-running `PostgresClient`-pooled path —
    /// reserved as a last-resort cap if the pre-flight probe somehow lets a
    /// bad config through.
    private static let connectTimeoutSeconds: UInt64 = 15

    private struct Session {
        let client: PostgresClient
        let runTask: Task<Void, Never>
        let version: String
        let versionNum: Int?
    }

    /// A newer `start()`/`shutdown()` superseded this attempt.
    private struct Superseded: Error {}

    struct ConnectFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func ensureCurrent(_ gen: Int) throws {
        guard gen == generation else { throw Superseded() }
    }

    private func connect(generation gen: Int) async {
        do {
            let session = try await establish(generation: gen)
            adopt(session)
            state = .connected(version: session.version, since: Date())
            Log.connection.info("connected \(self.connection.id.uuidString, privacy: .public)")
            startHealthMonitor()
            await loadSchema()
        } catch is Superseded {
            return
        } catch {
            guard gen == generation else { return }
            state = .error(error.localizedDescription)
        }
    }

    /// `drainOld`: a background reconnect replaced a pool that may still be
    /// serving queries (a slow link, not a dead one) — let it wind down
    /// instead of cancelling them mid-flight.
    private func adopt(_ session: Session, drainOld: Bool = false) {
        let old = clientTask
        client = session.client
        clientTask = session.runTask
        if drainOld, let old {
            retire(old)
        } else {
            old?.cancel()
        }
        serverVersionNum = session.versionNum
        if let num = session.versionNum {
            Self.serverVersionNums[connection.id] = num
        }
    }

    /// Tunnel (if any) → pre-flight probe → pooled client → version query.
    /// Every await is followed by a generation check; a superseded attempt
    /// tears down what it built and throws `Superseded`.
    private func establish(generation gen: Int) async throws -> Session {
        let password = await Keychain.passwordAsync(for: connection.id) ?? ""
        try ensureCurrent(gen)

        var endpoint = Endpoint(host: connection.host, port: connection.port)
        if connection.sshEnabled {
            let owner = "\(ownerID)#\(gen)"
            tunnelOwner = owner
            do {
                let port = try await SSHTunnelManager.shared.acquireTunnel(for: connection, owner: owner)
                endpoint = Endpoint(host: "127.0.0.1", port: port)
            } catch {
                try ensureCurrent(gen)
                throw ConnectFailure(message: "SSH tunnel failed: \(error.localizedDescription)")
            }
            try ensureCurrent(gen)
        }

        // PostgresClient's pool silently retries auth/protocol failures
        // forever and never surfaces the real error; a raw
        // `PostgresConnection.connect()` does, in milliseconds. Probe first
        // so "Connecting…" turns into "wrong password for user X".
        let outcome = await Self.probe(connection: connection, password: password,
                                       overrideHost: endpoint.host, overridePort: endpoint.port)
        try ensureCurrent(gen)
        if case .failure(let message) = outcome { throw ConnectFailure(message: message) }

        let config: PostgresClient.Configuration
        do {
            config = try Self.clientConfiguration(for: connection, password: password, endpoint: endpoint)
        } catch {
            throw ConnectFailure(message: "TLS setup failed: \(error.localizedDescription)")
        }
        let client = PostgresClient(configuration: config, backgroundLogger: Log.postgresClientLogger())
        let runTask = Task.detached(priority: .userInitiated) { await client.run() }

        let timeout = Self.connectTimeoutSeconds
        let host = connection.host
        let sslLabel = connection.sslMode.rawValue
        do {
            let (version, num) = try await Self.withDeadline(seconds: Double(timeout), onTimeout: {
                ConnectError.timedOut(host: host, sslMode: sslLabel, seconds: Int(timeout))
            }) {
                var v = "PostgreSQL"
                var n: Int?
                let rows = try await client.query("SELECT version(), current_setting('server_version_num')")
                for try await (text, numText) in rows.decode((String, String).self) {
                    v = text
                    n = Int(numText)
                    break
                }
                return (v, n)
            }
            guard gen == generation else { throw Superseded() }
            return Session(client: client, runTask: runTask, version: version, versionNum: num)
        } catch {
            runTask.cancel()
            throw error
        }
    }

    // MARK: - Health monitoring

    private static let healthInterval: Duration = .seconds(30)
    private static let pingTimeout: Double = 8
    private static let attemptsBeforeError = 3
    /// One slow ping on a congested link isn't an outage; recovery tears the
    /// pool down, so it needs a second, quick confirmation.
    nonisolated static let pingFailuresBeforeRecovery = 2
    private static let pingRecheckDelay: Duration = .seconds(3)
    private static let poolDrainWindow: Duration = .seconds(120)

    /// Pure: whether this many consecutive failed pings mean the session is lost.
    nonisolated static func shouldRecover(afterConsecutivePingFailures failures: Int) -> Bool {
        failures >= pingFailuresBeforeRecovery
    }

    private func retire(_ pool: Task<Void, Never>) {
        retiredPools.append(pool)
        Task { [weak self] in
            try? await Task.sleep(for: Self.poolDrainWindow)
            pool.cancel()
            self?.retiredPools.removeAll { $0 == pool }
        }
    }

    nonisolated static func reconnectDelay(afterAttempt attempt: Int) -> Duration {
        let steps: [Int] = [1, 2, 5, 10, 20, 30]
        return .seconds(steps[min(max(attempt, 1), steps.count) - 1])
    }

    private func startHealthMonitor() {
        stopHealthMonitor()
        let gen = generation
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.healthInterval)
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                await self.checkHealth()
            }
        }

        let myID = connection.id
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.add(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Wi-Fi/VPN need a moment after wake before a ping means anything.
                try? await Task.sleep(for: .seconds(3))
                await self?.checkHealth()
            }
        }, center: workspaceCenter)
        observers.add(NotificationCenter.default.addObserver(
            forName: .pgbrainSSHTunnelExited, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["connectionID"] as? UUID, id == myID else { return }
            let message = note.userInfo?["message"] as? String ?? "SSH tunnel closed."
            Task { @MainActor in self?.beginRecovery(reason: message) }
        })

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in self?.pathChanged(signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "cloud.souris.pgbrain.path-monitor"))
        pathMonitor = monitor
    }

    private func stopHealthMonitor() {
        healthTask?.cancel()
        healthTask = nil
        pathCheckTask?.cancel()
        pathCheckTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        observers.removeAll()
    }

    private func pathChanged(signature: String) {
        guard let previous = lastPathSignature else {
            lastPathSignature = signature
            return
        }
        guard previous != signature else { return }
        lastPathSignature = signature
        pathCheckTask?.cancel()
        pathCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.checkHealth()
        }
    }

    /// Ping the server; start a background reconnect if it doesn't answer.
    func checkHealth() async {
        guard case .connected = state, recoveryTask == nil, let client else { return }
        let gen = generation
        let ok = await Self.ping(client, timeoutSeconds: Self.pingTimeout)
        guard gen == generation, client === self.client else { return }
        if ok {
            consecutivePingFailures = 0
            return
        }
        consecutivePingFailures += 1
        if Self.shouldRecover(afterConsecutivePingFailures: consecutivePingFailures) {
            beginRecovery(reason: "The server stopped answering.")
            return
        }
        Log.connection.info("ping to \(self.connection.id.uuidString, privacy: .public) failed; re-checking before reconnecting")
        try? await Task.sleep(for: Self.pingRecheckDelay)
        guard gen == generation, client === self.client else { return }
        await checkHealth()
    }

    private func beginRecovery(reason: String) {
        guard recoveryTask == nil, case .connected = state else { return }
        consecutivePingFailures = 0
        Log.connection.info("connection \(self.connection.id.uuidString, privacy: .public) lost: \(reason, privacy: .public)")
        let gen = generation
        recoveryTask = Task { [weak self] in await self?.recover(generation: gen, reason: reason) }
    }

    private func recover(generation gen: Int, reason: String) async {
        var attempt = 0
        health = .lost(reason)
        while gen == generation, !Task.isCancelled {
            attempt += 1
            health = .reconnecting(attempt: attempt)
            do {
                let session = try await establish(generation: gen)
                adopt(session, drainOld: true)
                health = .healthy
                recoveryTask = nil
                if case .connected = state {
                    toasts.show(.info, "Reconnected to \(connection.name)")
                } else {
                    state = .connected(version: session.version, since: Date())
                    toasts.show(.success, "Reconnected to \(connection.name)")
                    await loadSchema()
                }
                return
            } catch is Superseded {
                return
            } catch {
                guard gen == generation else { return }
                let message = error.localizedDescription
                health = .lost(message)
                if attempt >= Self.attemptsBeforeError, case .connected = state {
                    state = .error("Connection lost: \(message)\n\npgBrain keeps trying to reconnect in the background.")
                }
                try? await Task.sleep(for: Self.reconnectDelay(afterAttempt: attempt))
            }
        }
    }

    nonisolated static func ping(_ client: PostgresClient, timeoutSeconds: Double) async -> Bool {
        do {
            return try await withDeadline(seconds: timeoutSeconds, onTimeout: { ConnectFailure(message: "ping timed out") }) {
                let rows = try await client.query("SELECT 1")
                for try await _ in rows.decode(Int.self) { break }
                return true
            }
        } catch {
            return false
        }
    }

    /// Race `operation` against a deadline without waiting for it to honour
    /// cancellation: a query stuck on a dead socket may ignore cancel for
    /// minutes, and a task group would wait for it.
    nonisolated static func withDeadline<T: Sendable>(
        seconds: Double,
        onTimeout: @escaping @Sendable () -> Error,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: onTimeout())
                }
            }
        }
    }

    // MARK: - Probe

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
        var config: PostgresConnection.Configuration
        do {
            config = try connectionConfiguration(
                for: connection, password: password,
                endpoint: Endpoint(host: overrideHost ?? connection.host, port: overridePort ?? connection.port)
            )
        } catch {
            return .failure("TLS setup failed: \(error.localizedDescription)")
        }
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

    /// Probe that honours the connection's SSH tunnel (opened just for the
    /// test and released afterwards). Backs the editor's Test Connection.
    static func testConnection(_ connection: Connection, password: String) async -> ProbeOutcome {
        let owner = "test-\(UUID().uuidString)"
        let endpoint: Endpoint
        do {
            endpoint = try await openEndpoint(for: connection, owner: owner)
        } catch {
            return .failure(error.localizedDescription)
        }
        defer { releaseEndpoint(for: connection, owner: owner) }
        return await probe(connection: connection, password: password,
                           overrideHost: endpoint.host, overridePort: endpoint.port)
    }

    /// Translate a `PSQLError` into a one-line user-readable message.
    /// Prefers the server's own `Message` field when present (covers
    /// auth-fail / wrong-db / etc.); falls back to the underlying NIO
    /// transport error description for DNS / connection-refused.
    nonisolated private static func friendlyMessage(from error: PSQLError, connection: Connection) -> String {
        if let server = error.serverInfo, let msg = server[.message] {
            if msg.localizedCaseInsensitiveContains("startup parameter")
                || msg.localizedCaseInsensitiveContains("unrecognized configuration parameter") {
                return msg + "\n\nA connection pooler may be rejecting a session setting — clear Statement timeout, Idle-in-transaction timeout and Read-only in the connection editor."
            }
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
            if s.contains("CERTIFICATE_VERIFY_FAILED") || s.contains("certificate verify failed") {
                return "The server's TLS certificate couldn't be verified (\(connection.sslMode.rawValue)). Set the Root CA file for a private CA, or use sslmode require to encrypt without verifying.\n\n\(underlying)"
            }
            if s.localizedCaseInsensitiveContains("hostname") && s.localizedCaseInsensitiveContains("match") {
                return "The server's TLS certificate isn't valid for \"\(connection.host)\" (verify-full). Use verify-ca to skip the hostname check.\n\n\(underlying)"
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

    // MARK: - Schema

    /// Fetch the server version + database size for the header. Best-effort:
    /// any failure leaves `serverInfo` as-is (decorative, never alarming).
    func loadServerInfo() async {
        guard let client else { return }
        do {
            let rows = try await client.query("""
                SELECT current_setting('server_version'),
                       pg_size_pretty(pg_database_size(current_database())),
                       (SELECT extversion FROM pg_extension WHERE extname = 'postgis')
                """)
            for try await (version, size, postgis) in rows.decode((String, String, String?).self) {
                // server_version can read "16.2" or "14.11 (Ubuntu …)" — keep
                // just the version number.
                let short = version.split(separator: " ").first.map(String.init) ?? version
                serverInfo = ServerInfo(versionShort: "PostgreSQL \(short)", databaseSize: size, postgis: postgis)
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

    // MARK: - Server version registry

    /// Last `server_version_num` seen per connection id, so tools that only
    /// hold a `Connection` (pg_dump binary selection) can match the server.
    private static var serverVersionNums: [UUID: Int] = [:]

    static func knownServerVersionNum(for connectionID: UUID) -> Int? {
        serverVersionNums[connectionID]
    }
}

// MARK: - Shared connection plumbing (TLS, startup parameters, SSH)
//
// Reusable by anything that opens its own Postgres session for a saved
// `Connection` (e.g. cross-database copy), so every path gets the same
// sslmode semantics, certificates, SNI and session settings:
//
//     let owner = "copy-\(UUID())"
//     let endpoint = try await ConnectionService.openEndpoint(for: conn, owner: owner)
//     defer { ConnectionService.releaseEndpoint(for: conn, owner: owner) }
//     let config = try ConnectionService.clientConfiguration(for: conn, password: pw, endpoint: endpoint)
//     let client = PostgresClient(configuration: config)
extension ConnectionService {
    /// Where to open the socket: the server itself or a local SSH forward.
    struct Endpoint: Sendable, Equatable {
        var host: String
        var port: Int
    }

    enum TLSSetupError: LocalizedError, Equatable {
        case fileNotFound(label: String, path: String)
        case clientKeyMissing
        case unreadable(label: String, path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let label, let path): return "\(label) not found at \(path)."
            case .clientKeyMissing: return "A client certificate needs its private key file too."
            case .unreadable(let label, let path, let reason):
                return "Couldn't load \(label) \(path): \(reason). Encrypted (passphrase-protected) keys aren't supported."
            }
        }
    }

    /// libpq-compatible sslmode → NIOSSL configuration; nil for `disable`.
    ///
    ///   - `allow`/`prefer` → TLS if offered, no verification
    ///   - `require` → TLS, no verification — unless a root CA is set, then
    ///     chain verification (libpq treats require + root cert as verify-ca)
    ///   - `verify-ca` → chain against root CA (or system roots), no hostname
    ///   - `verify-full` → chain + hostname
    ///
    /// Client certificate/key are presented in every TLS mode.
    nonisolated static func tlsConfiguration(for connection: Connection) throws -> TLSConfiguration? {
        let fm = FileManager.default
        func existing(_ raw: String, _ label: String) throws -> String? {
            guard let path = Connection.expandedPath(raw) else { return nil }
            guard fm.fileExists(atPath: path) else { throw TLSSetupError.fileNotFound(label: label, path: path) }
            return path
        }
        if connection.sslMode == .disable { return nil }
        var config = TLSConfiguration.makeClientConfiguration()
        let root = try existing(connection.sslRootCertPath, "Root CA file")
        switch connection.sslMode {
        case .disable, .allow, .prefer:
            config.certificateVerification = .none
        case .require:
            config.certificateVerification = root == nil ? .none : .noHostnameVerification
        case .verifyCA:
            config.certificateVerification = .noHostnameVerification
        case .verifyFull:
            config.certificateVerification = .fullVerification
        }
        if let root, [.require, .verifyCA, .verifyFull].contains(connection.sslMode) {
            config.trustRoots = .file(root)
        }
        if let certPath = try existing(connection.sslClientCertPath, "Client certificate") {
            guard let keyPath = try existing(connection.sslClientKeyPath, "Client key") else {
                throw TLSSetupError.clientKeyMissing
            }
            do {
                config.certificateChain = try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) }
            } catch {
                throw TLSSetupError.unreadable(label: "client certificate", path: certPath, reason: "\(error)")
            }
            do {
                config.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyPath, format: .pem))
            } catch {
                throw TLSSetupError.unreadable(label: "client key", path: keyPath, reason: "\(error)")
            }
        }
        return config
    }

    nonisolated static func clientTLS(for connection: Connection) throws -> PostgresClient.Configuration.TLS {
        guard let config = try tlsConfiguration(for: connection) else { return .disable }
        switch connection.sslMode {
        case .allow, .prefer: return .prefer(config)
        default: return .require(config)
        }
    }

    nonisolated static func connectionTLS(for connection: Connection) throws -> PostgresConnection.Configuration.TLS {
        guard let config = try tlsConfiguration(for: connection) else { return .disable }
        let context = try NIOSSLContext(configuration: config)
        switch connection.sslMode {
        case .allow, .prefer: return .prefer(context)
        default: return .require(context)
        }
    }

    /// Name used for SNI and certificate hostname checks. Always the real
    /// database host — never the 127.0.0.1 of an SSH forward, which is what
    /// broke verify-full over SSH. IP literals are not valid SNI names.
    nonisolated static func tlsServerName(for connection: Connection) -> String? {
        let host = connection.host
        guard connection.sslMode != .disable, !host.isEmpty, !isIPAddress(host) else { return nil }
        return host
    }

    nonisolated static func clientConfiguration(
        for connection: Connection, password: String, endpoint: Endpoint? = nil,
        applicationName: String = "pgBrain"
    ) throws -> PostgresClient.Configuration {
        let target = endpoint ?? Endpoint(host: connection.host, port: connection.port)
        var config = PostgresClient.Configuration(
            host: target.host,
            port: target.port,
            username: connection.username,
            password: password.isEmpty ? nil : password,
            database: connection.database.isEmpty ? nil : connection.database,
            tls: try clientTLS(for: connection)
        )
        config.options.tlsServerName = tlsServerName(for: connection)
        config.options.additionalStartupParameters = connection.startupParameters(applicationName: applicationName)
        return config
    }

    nonisolated static func connectionConfiguration(
        for connection: Connection, password: String, endpoint: Endpoint? = nil,
        applicationName: String = "pgBrain"
    ) throws -> PostgresConnection.Configuration {
        let target = endpoint ?? Endpoint(host: connection.host, port: connection.port)
        var config = PostgresConnection.Configuration(
            host: target.host,
            port: target.port,
            username: connection.username,
            password: password.isEmpty ? nil : password,
            database: connection.database.isEmpty ? nil : connection.database,
            tls: try connectionTLS(for: connection)
        )
        config.options.tlsServerName = tlsServerName(for: connection)
        config.options.additionalStartupParameters = connection.startupParameters(applicationName: applicationName)
        return config
    }

    /// Resolve the endpoint for `connection`, acquiring its SSH tunnel on
    /// behalf of `owner` when SSH is enabled. Always pair with
    /// `releaseEndpoint(for:owner:)`.
    static func openEndpoint(for connection: Connection, owner: String) async throws -> Endpoint {
        guard connection.sshEnabled else { return Endpoint(host: connection.host, port: connection.port) }
        do {
            let port = try await SSHTunnelManager.shared.acquireTunnel(for: connection, owner: owner)
            return Endpoint(host: "127.0.0.1", port: port)
        } catch {
            throw ConnectFailure(message: "SSH tunnel failed: \(error.localizedDescription)")
        }
    }

    static func releaseEndpoint(for connection: Connection, owner: String) {
        guard connection.sshEnabled else { return }
        SSHTunnelManager.shared.release(connectionID: connection.id, owner: owner)
    }

    nonisolated static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

/// One-shot latch for racing continuations.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Notification tokens that can be dropped from a nonisolated `deinit`.
final class ObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func add(_ token: NSObjectProtocol, center: NotificationCenter = .default) {
        lock.lock(); defer { lock.unlock() }
        tokens.append((center, token))
    }

    func removeAll() {
        lock.lock()
        let current = tokens
        tokens.removeAll()
        lock.unlock()
        for (center, token) in current { center.removeObserver(token) }
    }
}

#if DEBUG
extension ConnectionService {
    /// Test-only seam: bind an already-running `PostgresClient` (e.g. the one
    /// owned by the E2E `TestDB` fixture) so the admin/query wrappers can be
    /// driven against live Postgres without the connect/probe/Keychain path.
    /// Same-file access lets it write the otherwise-`private(set)` `client`.
    /// Excluded from release builds.
    func attachClientForTests(_ client: PostgresClient) {
        self.client = client
        self.state = .connected(version: "test", since: .distantPast)
    }

    /// Test-only seam: inject a schema snapshot (and optionally mark PostGIS
    /// present) without the live `loadSchema` catalog fetch, so the
    /// schema-driven UI builders (command palette, sidebar) can be exercised
    /// deterministically. Excluded from release builds.
    func injectSchemaForTests(_ snapshot: SchemaSnapshot, postgis: String? = nil) {
        self.schema = snapshot
        if let postgis {
            self.serverInfo = ServerInfo(versionShort: "PostgreSQL test", databaseSize: "0 MB", postgis: postgis)
        }
    }
}
#endif
