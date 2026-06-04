import Foundation
import SwiftUI

/// Connection definition. Stored in `~/Library/Application Support/pgBrain/connections.json`
/// (sans password — passwords go to Keychain, added in iter-2).
struct Connection: Identifiable, Codable, Hashable {
    enum SSLMode: String, Codable, CaseIterable {
        case disable, allow, prefer, require, verifyCA = "verify-ca", verifyFull = "verify-full"
    }

    /// Visual tag color for quick scanning in lists. Stored as a named token, not a raw hex.
    enum ColorTag: String, Codable, CaseIterable, Identifiable {
        case none, gray, blue, green, yellow, orange, red, purple, pink, teal
        var id: String { rawValue }

        var swiftUIColor: Color {
            switch self {
            case .none: return .clear
            case .gray: return .gray
            case .blue: return .blue
            case .green: return .green
            case .yellow: return .yellow
            case .orange: return .orange
            case .red: return .red
            case .purple: return .purple
            case .pink: return .pink
            case .teal: return .teal
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var host: String = "localhost"
    var port: Int = 5432
    var database: String = ""
    var username: String = ""
    var sslMode: SSLMode = .prefer
    /// Default `search_path` adopted by new scratchpads on this
    /// connection. Empty = none (notebooks start unscoped, using the
    /// server's own `search_path`).
    var defaultSearchPath: String = ""
    var colorTag: ColorTag = .none
    // MARK: - SSH tunnel (optional)
    /// When true, ConnectionService starts an ssh local-forward
    /// process and points the PostgresNIO client at it before
    /// connecting.
    var sshEnabled: Bool = false
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUser: String = ""
    /// Path to a private key file (e.g. `~/.ssh/id_ed25519`). When
    /// empty, ssh falls back to its default search (~/.ssh/id_rsa,
    /// id_ed25519, etc.) or the agent.
    var sshKeyPath: String = ""
    /// When true, every reference to this connection gets red danger chrome.
    var isProduction: Bool = false

    static let placeholder = Connection(name: "")

    init(
        id: UUID = UUID(), name: String, host: String = "localhost", port: Int = 5432,
        database: String = "", username: String = "", sslMode: SSLMode = .prefer,
        defaultSearchPath: String = "", colorTag: ColorTag = .none,
        sshEnabled: Bool = false, sshHost: String = "",
        sshPort: Int = 22, sshUser: String = "", sshKeyPath: String = "", isProduction: Bool = false
    ) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.database = database; self.username = username; self.sslMode = sslMode
        self.defaultSearchPath = defaultSearchPath
        self.colorTag = colorTag; self.sshEnabled = sshEnabled; self.sshHost = sshHost
        self.sshPort = sshPort; self.sshUser = sshUser; self.sshKeyPath = sshKeyPath
        self.isProduction = isProduction
    }

    // Tolerant decoder: every field except `name`/`id` is optional in
    // the on-disk JSON. Without this, a connections.json written by an
    // older build (before the SSH fields existed) fails to decode — and
    // because `ConnectionStore.load` does `try? … ?? []`, the user's
    // entire connection list silently vanishes after an update. Decode
    // each key with `decodeIfPresent` and fall back to the property
    // default so old files keep working forever.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        host = (try c.decodeIfPresent(String.self, forKey: .host)) ?? "localhost"
        port = (try c.decodeIfPresent(Int.self, forKey: .port)) ?? 5432
        database = (try c.decodeIfPresent(String.self, forKey: .database)) ?? ""
        username = (try c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        sslMode = (try c.decodeIfPresent(SSLMode.self, forKey: .sslMode)) ?? .prefer
        defaultSearchPath = (try c.decodeIfPresent(String.self, forKey: .defaultSearchPath)) ?? ""
        colorTag = (try c.decodeIfPresent(ColorTag.self, forKey: .colorTag)) ?? .none
        sshEnabled = (try c.decodeIfPresent(Bool.self, forKey: .sshEnabled)) ?? false
        sshHost = (try c.decodeIfPresent(String.self, forKey: .sshHost)) ?? ""
        sshPort = (try c.decodeIfPresent(Int.self, forKey: .sshPort)) ?? 22
        sshUser = (try c.decodeIfPresent(String.self, forKey: .sshUser)) ?? ""
        sshKeyPath = (try c.decodeIfPresent(String.self, forKey: .sshKeyPath)) ?? ""
        isProduction = (try c.decodeIfPresent(Bool.self, forKey: .isProduction)) ?? false
    }
}
