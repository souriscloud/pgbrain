import Foundation

/// All on-disk state lives under `~/Library/Application Support/pgBrain/`.
enum AppSupport {
    static let folderName = "pgBrain"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var connectionsFile: URL {
        directory.appendingPathComponent("connections.json")
    }

    static var stateFile: URL {
        directory.appendingPathComponent("state.json")
    }

    /// Alias used by `SessionStateStore` — matches the naming convention of
    /// `connectionsFile`/`stateFile` and lets `SessionStateStore.init` use a
    /// stable name even if we later add `*.URL` variants.
    static var stateFileURL: URL { stateFile }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
