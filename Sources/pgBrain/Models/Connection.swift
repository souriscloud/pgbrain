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
    var colorTag: ColorTag = .none
    /// When true, every reference to this connection gets red danger chrome.
    var isProduction: Bool = false

    static let placeholder = Connection(name: "")
}
