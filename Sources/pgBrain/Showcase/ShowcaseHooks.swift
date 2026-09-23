#if DEBUG
import AppKit
import ObjectiveC

/// The few places the harness has to reach into view-private state.
@MainActor
enum ShowcaseHooks {
    /// Scratchpad statements (matched by substring) whose inline result
    /// should open in a view other than the grid — "chart", "pivot", "map".
    static var resultModes: [String: String] = [:]

    static func resultMode(for statement: String) -> String? {
        guard ShowcaseEnvironment.isActive else { return nil }
        return resultModes.first { statement.contains($0.key) }?.value
    }

    /// Windows that are never ordered in are never key, so AppKit would draw
    /// grey traffic lights and inactive (grey) selections. Screenshots should
    /// look like the app in use, so every window reports itself key/main and
    /// the app active. Only ever installed in a showcase run.
    static func forceActiveAppearance() {
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        var targets: [(AnyClass, Selector)] = [
            (NSWindow.self, #selector(getter: NSWindow.isKeyWindow)),
            (NSWindow.self, #selector(getter: NSWindow.isMainWindow)),
            (NSApplication.self, #selector(getter: NSApplication.isActive)),
        ]
        // The title bar's traffic lights ask these instead of isKeyWindow.
        for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus",
                     "_hasKeyAppearance", "_hasMainAppearance"] {
            targets.append((NSWindow.self, NSSelectorFromString(name)))
        }
        for target in targets {
            guard let method = class_getInstanceMethod(target.0, target.1) else { continue }
            method_setImplementation(method, imp_implementationWithBlock(yes))
        }
    }
}
#endif
