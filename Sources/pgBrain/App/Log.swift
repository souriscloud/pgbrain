import Foundation
import Logging
import os

/// App-wide unified-logging categories. Read with
/// `log stream --predicate 'subsystem == "cloud.souris.pgbrain"'`.
enum Log {
    static let subsystem = "cloud.souris.pgbrain"
    static let persistence = os.Logger(subsystem: subsystem, category: "persistence")
    static let connection = os.Logger(subsystem: subsystem, category: "connection")
    static let io = os.Logger(subsystem: subsystem, category: "io")
    static let postgres = os.Logger(subsystem: subsystem, category: "postgres")

    /// PostgresNIO logger for a new client: silent unless the user turned on
    /// "Verbose Postgres logging", in which case it forwards to unified logging.
    @MainActor
    static func postgresClientLogger() -> Logging.Logger {
        guard AppSettings.shared.verbosePostgresLogging else { return pgbrainQuietLogger }
        var logger = Logging.Logger(label: subsystem, factory: { OSLogHandler(label: $0) })
        logger.logLevel = .debug
        return logger
    }
}

/// Bridges swift-log (what PostgresNIO speaks) to `os.Logger`.
struct OSLogHandler: LogHandler {
    let label: String
    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let suffix = merged.isEmpty ? "" : " " + merged.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let text = "\(event.message)\(suffix)"
        switch event.level {
        case .trace, .debug: Log.postgres.debug("\(text, privacy: .public)")
        case .info, .notice: Log.postgres.info("\(text, privacy: .public)")
        case .warning: Log.postgres.warning("\(text, privacy: .public)")
        case .error: Log.postgres.error("\(text, privacy: .public)")
        case .critical: Log.postgres.fault("\(text, privacy: .public)")
        }
    }
}
