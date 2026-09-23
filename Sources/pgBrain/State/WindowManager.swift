import AppKit

/// Tracks open connection windows so the AppDelegate can re-show Welcome on
/// last-close, focus existing windows on re-open, and (later) populate the
/// menu bar's "Open Windows" list.
///
/// A window is identified by (connection id, database): the database
/// switcher opens sibling windows for the same saved connection.
@MainActor
final class WindowManager {
    struct Entry {
        let connectionID: UUID
        let database: String
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
            entries.append(Entry(connectionID: service.connection.id,
                                 database: service.connection.database,
                                 window: window, service: service))
        }
    }

    func unregister(window: NSWindow) {
        entries.removeAll { $0.window === window }
    }

    /// First window for the connection, whatever its database.
    func window(for connectionID: UUID) -> NSWindow? {
        entries.first(where: { $0.connectionID == connectionID })?.window
    }

    func window(for connectionID: UUID, database: String) -> NSWindow? {
        entries.first(where: { $0.connectionID == connectionID && $0.database == database })?.window
    }

    /// Live `ConnectionService` for a connection if its window is currently
    /// open, otherwise nil. iter-9 cross-DB copy uses this to reuse an
    /// already-leased PostgresClient instead of opening a transient one.
    func service(for connectionID: UUID) -> ConnectionService? {
        entries.first(where: { $0.connectionID == connectionID })?.service
    }

    func service(for window: NSWindow?) -> ConnectionService? {
        guard let window else { return nil }
        return entries.first(where: { $0.window === window })?.service
    }

    /// The service behind the key (or main) window, used by menu commands.
    var keyService: ConnectionService? {
        service(for: NSApp.keyWindow) ?? service(for: NSApp.mainWindow)
    }

    /// Other open databases of the same connection, for the switcher.
    func openDatabases(for connectionID: UUID) -> [String] {
        entries.filter { $0.connectionID == connectionID }.map(\.database)
    }
}
