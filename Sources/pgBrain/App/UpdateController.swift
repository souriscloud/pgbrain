import AppKit
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController`. Sparkle reads
/// `SUFeedURL` + `SUPublicEDKey` from `Info.plist`, so configuration lives
/// there. The wrapper exists so the menu bar's "Check for Updates…" item
/// has a clean target/action surface and so iter-11's `sparkleChannel`
/// setting can be threaded into the feed URL once the appcast supports
/// multiple channels.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    private(set) var standardController: SPUStandardUpdaterController!

    override init() {
        super.init()
        // Auto-launching = true so Sparkle starts background checks per
        // SUScheduledCheckInterval. The delegate is `self` so we can flip
        // the appcast URL based on the user's channel preference.
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // Sparkle's scheduled-check timer only fires once per
        // SUScheduledCheckInterval (24h here), so a user who quits + relaunches
        // within the day would never get a new build pushed. Kick off a silent
        // background check on launch so updates land on next open — the
        // standard background driver shows UI only when an update is found,
        // so this is invisible if you're already up to date.
        DispatchQueue.main.async { [weak self] in
            self?.standardController.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates(_ sender: Any?) {
        standardController.checkForUpdates(sender)
    }

    // MARK: - SPUUpdaterDelegate

    /// Pick the appcast variant matching the user's chosen channel.
    /// We host the appcast directly on the GitHub repo (the same place
    /// release.sh commits it to) — pointing at apps.souris.cloud was a
    /// regression: that host doesn't actually serve the appcast file
    /// and every check silently 404'd.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let channel = MainActor.assumeIsolated { AppSettings.shared.sparkleChannel }
        switch channel {
        case "beta":
            return "https://raw.githubusercontent.com/souriscloud/pgbrain/main/appcast-beta.xml"
        default:
            return "https://raw.githubusercontent.com/souriscloud/pgbrain/main/appcast.xml"
        }
    }
}
