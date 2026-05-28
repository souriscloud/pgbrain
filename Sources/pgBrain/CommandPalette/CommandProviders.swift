import AppKit

/// Builds the live `CommandItem` set the palette shows. Re-runs every
/// time the palette opens so the menu reflects the current schema,
/// open tabs, and whatever scratchpad is in front.
@MainActor
enum CommandProviders {
    /// Top-level: combine all sources for the frontmost connection.
    /// When `service` is nil (no connection window open) we still
    /// surface app-global actions like "New connection…" / Settings so
    /// ⌘K never feels useless.
    static func items(service: ConnectionService?) -> [CommandItem] {
        var out: [CommandItem] = []
        out.append(contentsOf: globalActions())
        out.append(contentsOf: savedConnections(currentID: service?.connection.id))
        guard let service else { return out }
        out.append(contentsOf: connectionActions(service: service))
        out.append(contentsOf: tabs(service: service))
        out.append(contentsOf: tables(service: service))
        out.append(contentsOf: schemas(service: service))
        return out
    }

    // MARK: - Saved connections

    /// Every saved connection. The frontmost one is suppressed to avoid
    /// the dead-end "Open X" when you're already in X. Tapping a row
    /// routes through `AppDelegate.openConnection`, which focuses an
    /// existing window or opens a new one if none is up.
    private static func savedConnections(currentID: UUID?) -> [CommandItem] {
        ConnectionStore.shared.connections
            .filter { $0.id != currentID }
            .map { conn in
                let summary: String = {
                    let host = conn.host.isEmpty ? "localhost" : conn.host
                    let db = conn.database.isEmpty ? "" : " · \(conn.database)"
                    return host + db
                }()
                return CommandItem(
                    id: "connection.\(conn.id.uuidString)",
                    icon: conn.isProduction ? "exclamationmark.shield.fill" : "server.rack",
                    title: conn.name,
                    subtitle: summary,
                    category: .connection,
                    shortcut: nil,
                    action: { AppDelegate.shared?.openConnection(conn) }
                )
            }
    }

    // MARK: - Actions

    private static func globalActions() -> [CommandItem] {
        [
            CommandItem(
                id: "action.newConnection",
                icon: "plus.rectangle.on.rectangle",
                title: "New Connection…",
                subtitle: "Open the Welcome window",
                category: .action,
                shortcut: "⌘N",
                action: { AppDelegate.shared?.showWelcome(focus: true) }
            ),
            CommandItem(
                id: "action.settings",
                icon: "gearshape",
                title: "Settings…",
                subtitle: "Preferences",
                category: .action,
                shortcut: "⌘,",
                action: {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            ),
            CommandItem(
                id: "action.about",
                icon: "info.circle",
                title: "About pgBrain",
                subtitle: nil,
                category: .action,
                shortcut: nil,
                action: { AppDelegate.shared?.showAbout() }
            ),
            CommandItem(
                id: "action.checkForUpdates",
                icon: "arrow.down.circle",
                title: "Check for Updates…",
                subtitle: "Sparkle",
                category: .action,
                shortcut: nil,
                action: { UpdateController.shared.checkForUpdates(nil) }
            ),
        ]
    }

    private static func connectionActions(service: ConnectionService) -> [CommandItem] {
        var items: [CommandItem] = [
            CommandItem(
                id: "action.newScratchpad",
                icon: "doc.text",
                title: "New Scratchpad",
                subtitle: "Open a SQL notebook tab",
                category: .action,
                shortcut: "⌘T",
                action: { _ = service.workspace.openScratchpad() }
            ),
            CommandItem(
                id: "action.reloadSchema",
                icon: "arrow.clockwise",
                title: "Reload Schema",
                subtitle: "Refetch tables, views, and columns",
                category: .action,
                shortcut: nil,
                action: { Task { await service.loadSchema() } }
            ),
        ]
        // Cancel-running shows up only when something's actually in flight,
        // so the palette doesn't pretend you can cancel idleness.
        let running = service.operations.operations.filter { !$0.isFinished }
        for op in running {
            items.append(CommandItem(
                id: "action.cancel.\(op.id.uuidString)",
                icon: "xmark.octagon",
                title: "Cancel: \(op.summary)",
                subtitle: "Running operation",
                category: .action,
                shortcut: nil,
                action: { service.operations.cancel(op) }
            ))
        }
        return items
    }

    // MARK: - Tabs

    private static func tabs(service: ConnectionService) -> [CommandItem] {
        service.workspace.tabs.map { tab in
            let id = tab.id
            return CommandItem(
                id: "tab.\(id.uuidString)",
                icon: tab.kind.iconName,
                title: tab.title,
                subtitle: "Switch to open tab",
                category: .tab,
                shortcut: nil,
                action: { service.workspace.selectedID = id }
            )
        }
    }

    // MARK: - Tables

    private static func tables(service: ConnectionService) -> [CommandItem] {
        var out: [CommandItem] = []
        for schema in service.schema.schemas {
            for table in schema.tables {
                let captured = table
                out.append(CommandItem(
                    id: "table.\(schema.name).\(table.name)",
                    icon: "tablecells",
                    title: table.name,
                    subtitle: "\(schema.name) · table",
                    category: .table,
                    shortcut: nil,
                    action: { service.workspace.openTable(captured) }
                ))
            }
        }
        return out
    }

    // MARK: - Schemas (set search_path on frontmost scratchpad)

    private static func schemas(service: ConnectionService) -> [CommandItem] {
        // Only meaningful when the selected tab is a scratchpad.
        guard
            let selectedID = service.workspace.selectedID,
            let selected = service.workspace.tabs.first(where: { $0.id == selectedID }),
            case .scratchpad(let pad) = selected.kind
        else { return [] }
        var out: [CommandItem] = []
        out.append(CommandItem(
            id: "schema.reset",
            icon: "rectangle.stack",
            title: "Use default search_path",
            subtitle: "Scratchpad: \(pad.title)",
            category: .schema,
            shortcut: nil,
            action: { pad.searchPath = nil }
        ))
        for schema in service.schema.schemas {
            let name = schema.name
            out.append(CommandItem(
                id: "schema.set.\(name)",
                icon: "rectangle.stack.fill",
                title: "Set search_path → \(name)",
                subtitle: "Scratchpad: \(pad.title)",
                category: .schema,
                shortcut: nil,
                action: { pad.searchPath = name }
            ))
        }
        return out
    }
}

private extension WorkspaceState.TabKind {
    var iconName: String {
        switch self {
        case .table:      "tablecells"
        case .scratchpad: "doc.text"
        }
    }
}
