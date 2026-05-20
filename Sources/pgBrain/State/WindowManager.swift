import AppKit

/// Tracks open connection windows so the AppDelegate can know whether to
/// re-show Welcome on last-window-close and so the menu bar can list them.
@MainActor
final class WindowManager {
    private(set) var connectionWindows: [NSWindow] = []

    func register(_ window: NSWindow) {
        if !connectionWindows.contains(where: { $0 === window }) {
            connectionWindows.append(window)
        }
    }

    func unregister(_ window: NSWindow) {
        connectionWindows.removeAll { $0 === window }
    }
}
