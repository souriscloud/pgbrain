import Foundation

/// All on-disk state lives under `~/Library/Application Support/pgBrain/`.
enum AppSupport {
    static let folderName = "pgBrain"

    static var directory: URL {
        #if DEBUG
        // Showcase / screenshot runs keep every store in a throwaway folder.
        if let override = ShowcaseEnvironment.supportDirectory {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        #endif
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

    /// Atomically write `data` to `url` with owner-only (0600) permissions.
    /// The temp file is created 0600 from the start (`open(O_EXCL, 0600)`),
    /// so the secret is never readable by others, not even briefly.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try createPrivateFile(at: temp, contents: data)
        do {
            if rename(temp.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Create a new 0600 file at `url` (fails if it already exists).
    static func createPrivateFile(at url: URL, contents data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
