import AppKit

/// Tracks open connection windows so the AppDelegate can re-show Welcome on
/// last-close, focus existing windows on re-open, and (later) populate the
/// menu bar's "Open Windows" list.
@MainActor
final class WindowManager {
    struct Entry {
        let connectionID: UUID
        let window: NSWindow
        weak var service: ConnectionService?
    }

    private(set) var entries: [Entry] = []

    /// Backwards-compatible adapter used by `MenuBarController`. Kept until
    /// the menu controller is refactored to read `entries` directly.
    var connectionWindows: [(connectionID: UUID, window: NSWindow)] {
        entries.map { ($0.connectionID, $0.window) }
    }

    func register(window: NSWindow, service: ConnectionService) {
        if !entries.contains(where: { $0.window === window }) {
            entries.append(Entry(connectionID: service.connection.id, window: window, service: service))
        }
    }

    func unregister(window: NSWindow) {
        entries.removeAll { $0.window === window }
    }

    func window(for connectionID: UUID) -> NSWindow? {
        entries.first(where: { $0.connectionID == connectionID })?.window
    }

    /// Live `ConnectionService` for a connection if its window is currently
    /// open, otherwise nil. iter-9 cross-DB copy uses this to reuse an
    /// already-leased PostgresClient instead of opening a transient one.
    func service(for connectionID: UUID) -> ConnectionService? {
        entries.first(where: { $0.connectionID == connectionID })?.service
    }
}
