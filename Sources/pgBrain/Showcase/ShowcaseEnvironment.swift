#if DEBUG
import Foundation

/// Marketing-screenshot mode (`scripts/screenshots.sh`). Everything the app
/// would normally persist or read from the user's real setup is redirected
/// or disabled while it is active, so a showcase run can never touch the
/// user's connections, Keychain, preferences or session.
enum ShowcaseEnvironment {
    /// Where the rendered PNGs go; set by `PGBRAIN_SHOWCASE`.
    static let outputDirectory: URL? = ProcessInfo.processInfo.environment["PGBRAIN_SHOWCASE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    static var isActive: Bool { outputDirectory != nil }

    /// Throwaway Application Support directory (`PGBRAIN_SUPPORT_DIR`).
    static let supportDirectory: URL? = ProcessInfo.processInfo.environment["PGBRAIN_SUPPORT_DIR"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    static let databaseName = ProcessInfo.processInfo.environment["PGBRAIN_SHOWCASE_DB"] ?? "pgbrain_showcase"

    /// Version shown in the UI (Welcome, About) — the release the
    /// screenshots are for, which Info.plist only gets at release time.
    static var versionOverride: String? {
        guard isActive else { return nil }
        return ProcessInfo.processInfo.environment["PGBRAIN_SHOWCASE_VERSION"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static let defaultsSuiteName = "cloud.souris.pgbrain.showcase"

    /// Preferences for the showcase run. A separate suite, wiped on exit,
    /// so no setting the harness reads or writes lands in the user's domain.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let suite = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("showcase defaults suite unavailable")
        }
        suite.removePersistentDomain(forName: defaultsSuiteName)
        return suite
    }()

    static func discardDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}
#endif
