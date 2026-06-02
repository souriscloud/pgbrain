import Foundation
import Observation

extension Notification.Name {
    /// Posted when the editor font size changes so already-open editors
    /// re-apply it live (the @Observable property alone doesn't reach the
    /// AppKit text views baked at make-time).
    static let pgbrainEditorFontChanged = Notification.Name("cloud.souris.pgbrain.editorFontChanged")
}

/// User-facing preferences. `@Observable` so SwiftUI can bind toggles in the
/// Settings window (iter-11) and the rest of the app can react live. Backed
/// by `UserDefaults` with a tiny key prefix.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private let keyPrefix = "pgbrain.settings."

    var restoreLastSession: Bool {
        didSet { defaults.set(restoreLastSession, forKey: keyPrefix + "restoreLastSession") }
    }

    var defaultRowLimit: Int {
        didSet { defaults.set(defaultRowLimit, forKey: keyPrefix + "defaultRowLimit") }
    }

    /// Override paths for external binaries (pg_dump, pg_restore, psql).
    /// Empty string = "use the discovered path".
    var pgDumpPath: String {
        didSet { defaults.set(pgDumpPath, forKey: "pgbrain.binaryOverride.pg_dump") }
    }
    var pgRestorePath: String {
        didSet { defaults.set(pgRestorePath, forKey: "pgbrain.binaryOverride.pg_restore") }
    }
    var psqlPath: String {
        didSet { defaults.set(psqlPath, forKey: "pgbrain.binaryOverride.psql") }
    }

    /// Verbose Postgres logging. When false (default) we use the no-op
    /// logger to keep latency down; when true ConnectionService passes a
    /// console-printing logger instead.
    var verbosePostgresLogging: Bool {
        didSet { defaults.set(verbosePostgresLogging, forKey: keyPrefix + "verbosePostgresLogging") }
    }

    /// Editor font point size. Clamped to a sane range; a change broadcasts
    /// `.pgbrainEditorFontChanged` so open editors re-apply it live.
    static let fontRange: ClosedRange<Double> = 9...28
    var editorFontSize: Double {
        didSet {
            let clamped = min(max(editorFontSize, Self.fontRange.lowerBound), Self.fontRange.upperBound)
            if clamped != editorFontSize { editorFontSize = clamped; return }
            defaults.set(editorFontSize, forKey: keyPrefix + "editorFontSize")
            NotificationCenter.default.post(name: .pgbrainEditorFontChanged, object: nil)
        }
    }

    /// Nudge the editor font by `delta`, clamped. Used by ⌘+ / ⌘-.
    func bumpFontSize(by delta: Double) {
        editorFontSize = min(max(editorFontSize + delta, Self.fontRange.lowerBound), Self.fontRange.upperBound)
    }

    /// Sparkle update channel (used by iter-12).
    var sparkleChannel: String {
        didSet { defaults.set(sparkleChannel, forKey: keyPrefix + "sparkleChannel") }
    }

    private convenience init() {
        self.init(defaults: .standard)
    }

    #if DEBUG
    convenience init(testDefaults: UserDefaults) {
        self.init(defaults: testDefaults)
    }
    #endif

    private init(defaults d: UserDefaults) {
        self.defaults = d
        // First-launch defaults so the UI binds to a real value.
        self.restoreLastSession = d.object(forKey: "pgbrain.settings.restoreLastSession") as? Bool ?? true
        self.defaultRowLimit = (d.object(forKey: "pgbrain.settings.defaultRowLimit") as? Int) ?? 1000
        self.pgDumpPath = d.string(forKey: "pgbrain.binaryOverride.pg_dump") ?? ""
        self.pgRestorePath = d.string(forKey: "pgbrain.binaryOverride.pg_restore") ?? ""
        self.psqlPath = d.string(forKey: "pgbrain.binaryOverride.psql") ?? ""
        self.verbosePostgresLogging = d.bool(forKey: "pgbrain.settings.verbosePostgresLogging")
        self.editorFontSize = (d.object(forKey: "pgbrain.settings.editorFontSize") as? Double) ?? 12
        self.sparkleChannel = d.string(forKey: "pgbrain.settings.sparkleChannel") ?? "stable"
    }
}
