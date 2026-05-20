import AppKit

/// Tracks open connection windows so the AppDelegate can re-show Welcome on
/// last-close, focus existing windows on re-open, and (later) populate the
/// menu bar's "Open Windows" list.
@MainActor
final class WindowManager {
    private(set) var connectionWindows: [(connectionID: UUID, window: NSWindow)] = []

    func register(window: NSWindow, for connectionID: UUID) {
        if !connectionWindows.contains(where: { $0.window === window }) {
            connectionWindows.append((connectionID, window))
        }
    }

    func unregister(window: NSWindow) {
        connectionWindows.removeAll { $0.window === window }
    }

    func window(for connectionID: UUID) -> NSWindow? {
        connectionWindows.first(where: { $0.connectionID == connectionID })?.window
    }
}
