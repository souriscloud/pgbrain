import AppKit

/// Tracks open connection windows so the AppDelegate can re-show Welcome on
/// last-close, focus existing windows on re-open, and (later) populate the
/// menu bar's "Open Windows" list.
///
/// A window is identified by (connection id, database): the database
/// switcher opens sibling windows for the same saved connection. Database
/// names are compared resolved — a connection saved without a database lands
/// on the server's default (the user name, or whatever the server reported),
/// so "" and that name must be the same key or picking the current database
/// in the switcher would open a duplicate window.
@MainActor
final class WindowManager {
    struct Entry {
        let connectionID: UUID
        let database: String
        let username: String
        let window: NSWindow
        weak var service: ConnectionService?

        /// The database this window is really on: the explicit one, else
        /// what the server reported once the schema loaded, else the
        /// server-side default (the user name).
        @MainActor var resolvedDatabase: String {
            let reported = service?.schema.databaseName ?? ""
            return WindowManager.resolve(database: database, reported: reported, username: username)
        }
    }

    private(set) var entries: [Entry] = []

    /// Backwards-compatible adapter used by `MenuBarController`. Kept until
    /// the menu controller is refactored to read `entries` directly.
    var connectionWindows: [(connectionID: UUID, window: NSWindow)] {
        entries.map { ($0.connectionID, $0.window) }
    }

    nonisolated static func resolve(database: String, reported: String, username: String) -> String {
        if !database.isEmpty { return database }
        if !reported.isEmpty { return reported }
        return username
    }

    func register(window: NSWindow, service: ConnectionService) {
        if !entries.contains(where: { $0.window === window }) {
            entries.append(Entry(connectionID: service.connection.id,
                                 database: service.connection.database,
                                 username: service.connection.username,
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

    func window(for connectionID: UUID, database: String, username: String) -> NSWindow? {
        entry(for: connectionID, database: database, username: username)?.window
    }

    /// Live service for exactly this (connection, database), so tools that
    /// act on "the target database" never borrow a sibling window's pool.
    func service(for connectionID: UUID, database: String, username: String) -> ConnectionService? {
        entry(for: connectionID, database: database, username: username)?.service
    }

    private func entry(for connectionID: UUID, database: String, username: String) -> Entry? {
        let wanted = Self.resolve(database: database, reported: "", username: username)
        return entries.first { entry in
            guard entry.connectionID == connectionID else { return false }
            return entry.database == database || entry.resolvedDatabase == wanted
        }
    }

    /// Whether any window of the connection is open, whatever its database.
    func hasWindow(for connectionID: UUID) -> Bool {
        entries.contains { $0.connectionID == connectionID }
    }

    func service(for window: NSWindow?) -> ConnectionService? {
        guard let window else { return nil }
        return entries.first(where: { $0.window === window })?.service
    }

    /// The service behind the key (or main) window, used by menu commands.
    var keyService: ConnectionService? {
        service(for: NSApp.keyWindow) ?? service(for: NSApp.mainWindow)
    }

    /// Resolved database names open for the connection, for the switcher.
    func openDatabases(for connectionID: UUID) -> [String] {
        entries.filter { $0.connectionID == connectionID }.map(\.resolvedDatabase)
    }
}
