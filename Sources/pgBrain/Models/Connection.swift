import Foundation
import SwiftUI

/// Connection definition. Stored in `~/Library/Application Support/pgBrain/connections.json`
/// (sans password — passwords live in the Keychain).
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
    /// PEM file of the CA(s) to trust instead of the system roots. Used by
    /// `verify-ca`/`verify-full`; with `require` it upgrades to `verify-ca`
    /// semantics, like libpq does when a root cert is present.
    var sslRootCertPath: String = ""
    /// PEM client certificate + key for mutual TLS. Unencrypted keys only.
    var sslClientCertPath: String = ""
    var sslClientKeyPath: String = ""
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
    // MARK: - Session defaults (sent as startup parameters)
    /// `statement_timeout` in seconds; 0 = server default.
    var statementTimeoutSeconds: Int = 0
    /// `idle_in_transaction_session_timeout` in seconds; 0 = server default.
    var idleInTransactionTimeoutSeconds: Int = 0
    /// `default_transaction_read_only = on` for every session. A guard rail,
    /// not a permission boundary — `SET` can still flip it back.
    var readOnly: Bool = false

    static let placeholder = Connection(name: "")

    init(
        id: UUID = UUID(), name: String, host: String = "localhost", port: Int = 5432,
        database: String = "", username: String = "", sslMode: SSLMode = .prefer,
        defaultSearchPath: String = "", colorTag: ColorTag = .none,
        sshEnabled: Bool = false, sshHost: String = "",
        sshPort: Int = 22, sshUser: String = "", sshKeyPath: String = "", isProduction: Bool = false,
        sslRootCertPath: String = "", sslClientCertPath: String = "", sslClientKeyPath: String = "",
        statementTimeoutSeconds: Int = 0, idleInTransactionTimeoutSeconds: Int = 0, readOnly: Bool = false
    ) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.database = database; self.username = username; self.sslMode = sslMode
        self.defaultSearchPath = defaultSearchPath
        self.colorTag = colorTag; self.sshEnabled = sshEnabled; self.sshHost = sshHost
        self.sshPort = sshPort; self.sshUser = sshUser; self.sshKeyPath = sshKeyPath
        self.isProduction = isProduction
        self.sslRootCertPath = sslRootCertPath
        self.sslClientCertPath = sslClientCertPath
        self.sslClientKeyPath = sslClientKeyPath
        self.statementTimeoutSeconds = statementTimeoutSeconds
        self.idleInTransactionTimeoutSeconds = idleInTransactionTimeoutSeconds
        self.readOnly = readOnly
    }

    // Tolerant decoder: every key is optional, a mistyped value falls back to
    // the default, and enums fall back on an unknown raw value. The file may
    // have been written by an older build (missing keys) or a newer one (new
    // enum cases, seen after a downgrade) — neither may cost the user their
    // connection list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "")
        host = value(.host, "localhost")
        port = value(.port, 5432)
        database = value(.database, "")
        username = value(.username, "")
        sslMode = SSLMode(rawValue: value(.sslMode, "")) ?? .prefer
        sslRootCertPath = value(.sslRootCertPath, "")
        sslClientCertPath = value(.sslClientCertPath, "")
        sslClientKeyPath = value(.sslClientKeyPath, "")
        defaultSearchPath = value(.defaultSearchPath, "")
        colorTag = ColorTag(rawValue: value(.colorTag, "")) ?? .none
        sshEnabled = value(.sshEnabled, false)
        sshHost = value(.sshHost, "")
        sshPort = value(.sshPort, 22)
        sshUser = value(.sshUser, "")
        sshKeyPath = value(.sshKeyPath, "")
        isProduction = value(.isProduction, false)
        statementTimeoutSeconds = max(0, value(.statementTimeoutSeconds, 0))
        idleInTransactionTimeoutSeconds = max(0, value(.idleInTransactionTimeoutSeconds, 0))
        readOnly = value(.readOnly, false)
    }
}

extension Connection {
    /// Startup parameters sent in the Postgres startup packet of every new
    /// session. Beyond `application_name`, only non-default values are sent:
    /// poolers like PgBouncer reject startup parameters they don't know.
    func startupParameters(applicationName: String = "pgBrain") -> [(String, String)] {
        var params: [(String, String)] = [("application_name", applicationName)]
        if statementTimeoutSeconds > 0 {
            params.append(("statement_timeout", "\(statementTimeoutSeconds)s"))
        }
        if idleInTransactionTimeoutSeconds > 0 {
            params.append(("idle_in_transaction_session_timeout", "\(idleInTransactionTimeoutSeconds)s"))
        }
        if readOnly {
            params.append(("default_transaction_read_only", "on"))
        }
        return params
    }

    /// `~`-expanded path, or nil when the field is blank.
    static func expandedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }
}
