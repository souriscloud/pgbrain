#if DEBUG
import AppKit
import SwiftUI

/// Drives the app through each marketing scene and writes PNGs, then exits.
/// Started from `AppDelegate` instead of the normal launch path, so there
/// is no Welcome window, menu bar item, Sparkle check or session restore.
@MainActor
enum ShowcaseRunner {
    static let windowSize = CGSize(width: 1600, height: 1000)

    static func start(delegate: AppDelegate) {
        Task { @MainActor in
            let status: Int32
            do {
                try await run(delegate: delegate)
                ShowcaseLog.write("done")
                status = 0
            } catch {
                ShowcaseLog.write("FAILED: \(error)")
                status = 1
            }
            ShowcaseEnvironment.discardDefaults()
            exit(status)
        }
    }

    static func run(delegate: AppDelegate) async throws {
        guard let outDir = ShowcaseEnvironment.outputDirectory else { return }
        guard ShowcaseEnvironment.supportDirectory != nil else {
            throw ShowcaseError("PGBRAIN_SUPPORT_DIR must be set so the run can't touch real app data")
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        ShowcaseLog.open(in: outDir)
        ShowcaseLog.write("showcase start, output \(outDir.path)")

        let scenes = ShowcaseScenes(delegate: delegate, outputDirectory: outDir)
        try await scenes.runAll()
    }

    /// Poll `condition` on the main actor until it holds or `timeout` passes.
    static func wait(_ what: String, timeout: Double = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw ShowcaseError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Progress log next to the PNGs, so `screenshots.sh` can show why a run
/// failed (the app has no terminal output of its own).
@MainActor
enum ShowcaseLog {
    private static var handle: FileHandle?

    static func open(in dir: URL) {
        let url = dir.appendingPathComponent("showcase.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    static func write(_ line: String) {
        Log.io.info("showcase: \(line, privacy: .public)")
        handle?.write(Data((line + "\n").utf8))
    }
}
#endif
