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
        // the appcast URL based on the iter-11 channel preference.
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates(_ sender: Any?) {
        standardController.checkForUpdates(sender)
    }

    // MARK: - SPUUpdaterDelegate

    /// Pick the appcast variant matching the user's chosen Sparkle channel.
    /// Stable points at `appcast.xml`; beta at `appcast-beta.xml`.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let channel = MainActor.assumeIsolated { AppSettings.shared.sparkleChannel }
        switch channel {
        case "beta":
            return "https://apps.souris.cloud/pgbrain/appcast-beta.xml"
        default:
            return "https://apps.souris.cloud/pgbrain/appcast.xml"
        }
    }
}
