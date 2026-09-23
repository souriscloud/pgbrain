import Foundation

extension Notification.Name {
    /// Posted (main thread) when a tunnel's ssh process exits while it still
    /// has owners. `userInfo`: `connectionID` (UUID), `message` (String).
    static let pgbrainSSHTunnelExited = Notification.Name("cloud.souris.pgbrain.sshTunnelExited")
}

/// Pure argument building + validation for the `ssh` local-forward command.
/// Nonisolated so it can be unit-tested and reused (e.g. by cross-DB copy).
enum SSHCommand {
    static let executable = "/usr/bin/ssh"

    enum ValidationError: LocalizedError, Equatable {
        case invalid(field: String, reason: String)
        var errorDescription: String? {
            switch self {
            case .invalid(let field, let reason): return "Invalid \(field): \(reason)"
            }
        }
    }

    /// Reject values ssh would parse as options or that could smuggle extra
    /// arguments/whitespace into the command line.
    static func validate(_ connection: Connection) throws {
        try validateToken(connection.sshHost, field: "SSH host", allowEmpty: false, allowAt: false)
        try validateToken(connection.sshUser, field: "SSH user", allowEmpty: true, allowAt: true)
        try validateToken(connection.host, field: "database host", allowEmpty: false, allowAt: false)
        guard (1...65_535).contains(connection.sshPort) else {
            throw ValidationError.invalid(field: "SSH port", reason: "must be 1–65535")
        }
        guard (1...65_535).contains(connection.port) else {
            throw ValidationError.invalid(field: "database port", reason: "must be 1–65535")
        }
    }

    private static func validateToken(_ value: String, field: String, allowEmpty: Bool, allowAt: Bool) throws {
        if value.isEmpty {
            if allowEmpty { return }
            throw ValidationError.invalid(field: field, reason: "is empty")
        }
        if value.hasPrefix("-") {
            throw ValidationError.invalid(field: field, reason: "must not start with \"-\"")
        }
        if value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            throw ValidationError.invalid(field: field, reason: "must not contain spaces or control characters")
        }
        if !allowAt, value.contains("@") {
            throw ValidationError.invalid(field: field, reason: "must not contain \"@\"")
        }
    }

    static func arguments(for connection: Connection, localPort: Int) throws -> [String] {
        try validate(connection)
        let dbHost = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        var args = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):\(dbHost):\(connection.port)",
            "-p", String(connection.sshPort),
        ]
        if let key = Connection.expandedPath(connection.sshKeyPath) {
            args += ["-i", key, "-o", "IdentitiesOnly=yes"]
        }
        args.append("--")
        args.append(connection.sshUser.isEmpty ? connection.sshHost : "\(connection.sshUser)@\(connection.sshHost)")
        return args
    }

    /// Turn ssh's stderr into something actionable.
    static func friendlyError(stderr raw: String, exitCode: Int32?, connection: Connection) -> String {
        let stderr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = connection.sshUser.isEmpty ? connection.sshHost : "\(connection.sshUser)@\(connection.sshHost)"
        if stderr.contains("Permission denied") || stderr.localizedCaseInsensitiveContains("passphrase") {
            return """
            SSH authentication to \(target) failed. pgBrain runs ssh non-interactively, so it can't \
            ask for a key passphrase — load the key into ssh-agent first \
            (ssh-add --apple-use-keychain \(connection.sshKeyPath.isEmpty ? "~/.ssh/id_ed25519" : connection.sshKeyPath)). \
            SSH password auth isn't supported.

            ssh said: \(stderr)
            """
        }
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || stderr.contains("Host key verification failed") {
            return """
            The SSH host key for \(connection.sshHost) doesn't match ~/.ssh/known_hosts. If the server \
            was legitimately rebuilt, remove the old key with: ssh-keygen -R \(connection.sshHost)
            """
        }
        if stderr.isEmpty {
            return "ssh exited" + (exitCode.map { " with status \($0)" } ?? "") + "."
        }
        return stderr
    }
}

/// Thin wrapper around the system `ssh` binary for local-forward
/// tunnels. We shell out instead of pulling in `swift-nio-ssh` —
/// macOS ships `/usr/bin/ssh`, agent-based auth Just Works for most
/// users, and Process management is small vs a full crypto dependency.
///
/// One tunnel per connection id, shared by every *owner* (a window's
/// `ConnectionService`, a pg_dump run, a Test Connection click). The ssh
/// process lives while at least one owner holds it. ssh runs with
/// `BatchMode=yes` (no prompts — key passphrases must come from the agent)
/// and `StrictHostKeyChecking=accept-new` (first-seen hosts are recorded,
/// changed keys still fail).
@MainActor
final class SSHTunnelManager {
    static let shared = SSHTunnelManager()

    struct Tunnel {
        let connectionID: UUID
        let localPort: Int
        let process: Process
    }

    private(set) var tunnels: [UUID: Tunnel] = [:]
    private var owners: [UUID: Set<String>] = [:]
    private var pending: [UUID: Task<Int, Error>] = [:]
    /// Every ssh we've spawned and not yet seen exit, including ones still
    /// starting up — so quitting can't orphan a half-started tunnel.
    private var live: [ObjectIdentifier: Process] = [:]

    enum TunnelError: LocalizedError {
        case sshMissing
        case allocFailed
        case startFailed(String)
        case timeout
        case released
        var errorDescription: String? {
            switch self {
            case .sshMissing:        return "\(SSHCommand.executable) not found."
            case .allocFailed:       return "Couldn't allocate a local forwarding port."
            case .startFailed(let s):return s
            case .timeout:           return "SSH tunnel didn't come up within 15 seconds."
            case .released:          return "SSH tunnel was closed while starting."
            }
        }
    }

    /// Open (or reuse) the tunnel for `connection` on behalf of `owner` and
    /// return the local port. Idempotent per owner; restarts a dead tunnel.
    func acquireTunnel(for connection: Connection, owner: String) async throws -> Int {
        let id = connection.id
        let wasOwner = owners[id]?.contains(owner) ?? false
        owners[id, default: []].insert(owner)
        do {
            return try await ensureRunning(connection)
        } catch {
            if !wasOwner { release(connectionID: id, owner: owner) }
            throw error
        }
    }

    /// Drop `owner`'s hold; the ssh process stops once nobody holds it.
    func release(connectionID: UUID, owner: String) {
        owners[connectionID]?.remove(owner)
        if owners[connectionID]?.isEmpty ?? true {
            owners[connectionID] = nil
            terminate(connectionID)
        }
    }

    /// Back-compat entry point: acquire under a shared anonymous owner.
    func startTunnel(for connection: Connection) async throws -> Int {
        try await acquireTunnel(for: connection, owner: "default")
    }

    /// Force-stop regardless of owners.
    func stopTunnel(for connectionID: UUID) {
        owners[connectionID] = nil
        terminate(connectionID)
    }

    /// Kill every ssh we started. Called on app termination.
    func stopAll() {
        owners.removeAll()
        tunnels.removeAll()
        for process in live.values where process.isRunning { process.terminate() }
        live.removeAll()
    }

    /// Local port of a running tunnel, if any.
    func localPort(for connectionID: UUID) -> Int? {
        guard let t = tunnels[connectionID], t.process.isRunning else { return nil }
        return t.localPort
    }

    private func terminate(_ connectionID: UUID) {
        guard let t = tunnels.removeValue(forKey: connectionID) else { return }
        if t.process.isRunning { t.process.terminate() }
    }

    private func ensureRunning(_ connection: Connection) async throws -> Int {
        let id = connection.id
        if let t = tunnels[id], t.process.isRunning { return t.localPort }
        tunnels[id] = nil
        if let inFlight = pending[id] { return try await inFlight.value }
        let task = Task { try await self.spawn(connection) }
        pending[id] = task
        defer { pending[id] = nil }
        let port = try await task.value
        if owners[id]?.isEmpty ?? true {
            terminate(id)
            throw TunnelError.released
        }
        return port
    }

    private func spawn(_ connection: Connection) async throws -> Int {
        guard FileManager.default.isExecutableFile(atPath: SSHCommand.executable) else {
            throw TunnelError.sshMissing
        }
        let port = try Self.findFreePort()
        let args: [String]
        do {
            args = try SSHCommand.arguments(for: connection, localPort: port)
        } catch let e as SSHCommand.ValidationError {
            throw TunnelError.startFailed(e.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        process.arguments = args
        let stderrPipe = Pipe()
        let stderr = OutputBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderr.append(chunk) }
        }
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let id = connection.id
        let key = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                self?.processExited(connection: connection, key: key, status: status, stderr: stderr.string)
            }
        }
        do {
            try process.run()
        } catch {
            throw TunnelError.startFailed("Couldn't launch ssh: \(error.localizedDescription)")
        }
        live[key] = process
        Log.connection.info("ssh tunnel starting for \(id.uuidString, privacy: .public) on 127.0.0.1:\(port, privacy: .public)")

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !process.isRunning {
                throw TunnelError.startFailed(SSHCommand.friendlyError(
                    stderr: stderr.string, exitCode: process.terminationStatus, connection: connection))
            }
            if await Self.canConnectOffMain(port: port) {
                tunnels[id] = Tunnel(connectionID: id, localPort: port, process: process)
                return port
            }
        }
        process.terminate()
        let detail = stderr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { throw TunnelError.timeout }
        throw TunnelError.startFailed(SSHCommand.friendlyError(stderr: detail, exitCode: nil, connection: connection))
    }

    private func processExited(connection: Connection, key: ObjectIdentifier, status: Int32, stderr: String) {
        live[key] = nil
        let id = connection.id
        guard let t = tunnels[id], ObjectIdentifier(t.process) == key else { return }
        tunnels[id] = nil
        guard !(owners[id]?.isEmpty ?? true) else { return }
        let message = SSHCommand.friendlyError(stderr: stderr, exitCode: status, connection: connection)
        Log.connection.error("ssh tunnel for \(id.uuidString, privacy: .public) exited (\(status, privacy: .public)): \(message, privacy: .public)")
        NotificationCenter.default.post(name: .pgbrainSSHTunnelExited, object: nil,
                                        userInfo: ["connectionID": id, "message": message])
    }

    // MARK: - Helpers

    /// Ask the kernel for a free TCP port by binding to port 0 and
    /// reading what got assigned. Releasing the listener is racy but
    /// the window is microseconds — fine for our use.
    nonisolated static func findFreePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw TunnelError.allocFailed }
        defer { close(sock) }
        var reuse: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw TunnelError.allocFailed }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard nameResult == 0 else { throw TunnelError.allocFailed }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    nonisolated static func canConnectOffMain(port: Int) async -> Bool {
        await Task.detached(priority: .userInitiated) { canConnect(port: port) }.value
    }

    /// Blocking TCP connect to `127.0.0.1:port` — never call on the main actor.
    nonisolated static func canConnect(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Thread-safe accumulator for a child process's output, filled from a
/// `readabilityHandler` on a background queue.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int = 256 * 1024) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
