import Foundation

enum AppInfo {
    static var version: String {
        #if DEBUG
        // Screenshots are taken before release.sh bumps Info.plist.
        if let shown = ShowcaseEnvironment.versionOverride { return shown }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "cloud.souris.pgbrain"
    }
}
