import AppKit
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController`. Sparkle reads
/// `SUFeedURL` + `SUPublicEDKey` from `Info.plist`, so configuration lives
/// there. The wrapper exists so the menu bar's "Check for Updates…" item
/// has a clean target/action surface.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private(set) var standardController: SPUStandardUpdaterController!

    override init() {
        super.init()
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Sparkle's scheduled-check timer only fires once per
        // SUScheduledCheckInterval (24h), so a user who relaunches within the
        // day would never see a new build. A silent launch check fixes that,
        // but only when the user hasn't turned automatic checks off.
        DispatchQueue.main.async { [weak self] in
            guard let updater = self?.standardController.updater,
                  updater.automaticallyChecksForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { standardController.updater.automaticallyChecksForUpdates }
        set { standardController.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates(_ sender: Any?) {
        standardController.checkForUpdates(sender)
    }
}
