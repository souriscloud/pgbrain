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
}
