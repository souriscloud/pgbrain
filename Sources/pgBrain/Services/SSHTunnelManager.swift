import Foundation

/// Thin wrapper around the system `ssh` binary for local-forward
/// tunnels. We shell out instead of pulling in `swift-nio-ssh` —
/// macOS ships `/usr/bin/ssh`, agent-based auth Just Works for most
/// users, and Process management is ~50 lines vs a full crypto
/// dependency.
///
/// Each `Connection` with `sshEnabled = true` gets its own
/// `Tunnel` — `connectionID → Tunnel` — so opening the same
/// connection twice (e.g. from two windows) reuses the running
/// forward rather than racing on the same local port.
///
/// Caveats baked into the implementation:
/// - SSH password auth is **not** supported (would need an
///   interactive prompt or sshpass). Use public-key auth via the
///   agent or `~/.ssh/<key>` and document this.
/// - StrictHostKeyChecking is left at its default (`ask`). First
///   connect will fail until the user accepts the host in their
///   `known_hosts` via Terminal — explicitly safer than auto-accept.
@MainActor
final class SSHTunnelManager {
    static let shared = SSHTunnelManager()

    struct Tunnel {
        let connectionID: UUID
        let localPort: Int
        let process: Process
    }

    private(set) var tunnels: [UUID: Tunnel] = [:]

    enum TunnelError: LocalizedError {
        case sshMissing
        case allocFailed
        case startFailed(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .sshMissing:        return "/usr/bin/ssh not found."
            case .allocFailed:       return "Couldn't allocate a local forwarding port."
            case .startFailed(let s):return "ssh failed: \(s)"
            case .timeout:           return "Tunnel didn't come up within 8 seconds."
            }
        }
    }

    /// Open (or reuse) a tunnel for `connection`. Returns the local
    /// port the caller should connect to. Idempotent — repeat calls
    /// while a tunnel is running return the same port.
    func startTunnel(for connection: Connection) async throws -> Int {
        if let existing = tunnels[connection.id], existing.process.isRunning {
            return existing.localPort
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            throw TunnelError.sshMissing
        }
        let port = try findFreePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N",                  // no remote command, just forward
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", "\(port):\(connection.host):\(connection.port)",
            "-p", String(connection.sshPort)
        ]
        if !connection.sshKeyPath.isEmpty {
            args += ["-i", (connection.sshKeyPath as NSString).expandingTildeInPath]
        }
        args.append("\(connection.sshUser)@\(connection.sshHost)")
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TunnelError.startFailed(error.localizedDescription)
        }
        // Wait for the forward to come up — poll the local port for
        // up to 8 seconds. If ssh dies first (auth failure, host key
        // refused, etc.) capture its stderr and surface it.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !process.isRunning {
                let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let msg = String(data: data, encoding: .utf8) ?? "ssh exited (\(process.terminationStatus))"
                throw TunnelError.startFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if canConnect(port: port) { break }
        }
        if !canConnect(port: port) {
            process.terminate()
            throw TunnelError.timeout
        }
        tunnels[connection.id] = Tunnel(connectionID: connection.id, localPort: port, process: process)
        return port
    }

    /// Tear down a tunnel — kills the ssh process. Safe to call
    /// when no tunnel exists.
    func stopTunnel(for connectionID: UUID) {
        guard let t = tunnels.removeValue(forKey: connectionID) else { return }
        if t.process.isRunning { t.process.terminate() }
    }

    // MARK: - Helpers

    /// Ask the kernel for a free TCP port by binding to port 0 and
    /// reading what got assigned. Releasing the listener is racy but
    /// the window is microseconds — fine for our use.
    private func findFreePort() throws -> Int {
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

    /// Probe a TCP connection to `127.0.0.1:port`. Used to wait for
    /// ssh's local-forward socket to come up.
    private func canConnect(port: Int) -> Bool {
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
