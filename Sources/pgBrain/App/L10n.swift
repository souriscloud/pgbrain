import Foundation

/// Localised-string accessor. Centralises every user-facing string that's
/// been migrated into `Localizable.xcstrings`. Keys are namespaced
/// (`menu.about`, `welcome.title`, etc.) so future additions don't collide.
///
/// Iter-14 ships English + Czech for the first eight strings as a
/// scaffold; growing the catalog from here is mechanical (drop a new key,
/// add an `L10n.x` accessor, use it).
enum L10n {
    static func key(_ key: String, fallback: String) -> String {
        // `comment:` requires StaticString, so we drop the fallback note
        // (it lives as the @fallback parameter for developers reading code).
        String(localized: String.LocalizationValue(key), bundle: .module)
    }

    enum Menu {
        static var about: String { key("menu.about", fallback: "About pgBrain") }
        static var checkUpdates: String { key("menu.checkUpdates", fallback: "Check for Updates…") }
        static var quit: String { key("menu.quit", fallback: "Quit pgBrain") }
    }

    enum Welcome {
        static var title: String { key("welcome.title", fallback: "Pro PostgreSQL for macOS") }
        static var connections: String { key("welcome.connections", fallback: "Connections") }
    }

    enum Common {
        static var cancel: String { key("common.cancel", fallback: "Cancel") }
        static var save: String { key("common.save", fallback: "Save") }
        static var close: String { key("common.close", fallback: "Close") }
    }
}
