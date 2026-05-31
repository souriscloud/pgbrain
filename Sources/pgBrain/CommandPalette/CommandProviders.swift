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
        out.append(contentsOf: viewModes(service: service))
        out.append(contentsOf: tabs(service: service))
        out.append(contentsOf: tables(service: service))
        out.append(contentsOf: functions(service: service))
        out.append(contentsOf: schemas(service: service))
        out.append(contentsOf: erds(service: service))
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
            CommandItem(
                id: "action.activityPanel",
                icon: "waveform.path.ecg",
                title: "Show Activity Panel",
                subtitle: "Live pg_stat_activity / locks / index usage",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainOpenActivityPanel, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.queryHistory",
                icon: "clock.arrow.circlepath",
                title: "Query History…",
                subtitle: "Browse + reinsert past statements",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainOpenQueryHistory, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.sequenceInspector",
                icon: "number",
                title: "Sequences…",
                subtitle: "Inspect + setval / nextval / restart",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainOpenSequenceInspector, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.notifyPanel",
                icon: "antenna.radiowaves.left.and.right",
                title: "LISTEN / NOTIFY…",
                subtitle: "Subscribe to a NOTIFY channel",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainOpenNotifyPanel, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.snippets",
                icon: "doc.text",
                title: "Snippets…",
                subtitle: "Manage saved SQL fragments",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainOpenSnippets, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.createSchema",
                icon: "folder.badge.plus",
                title: "New Schema…",
                subtitle: "CREATE SCHEMA",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainCreateSchema, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.createFunction",
                icon: "plus.app",
                title: "New Function…",
                subtitle: "CREATE FUNCTION / PROCEDURE",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainNewFunction, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.createDatabase",
                icon: "cylinder.split.1x2",
                title: "New Database…",
                subtitle: "CREATE DATABASE",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(name: .pgbrainCreateDatabase, object: service.connection.id)
                }
            ),
            CommandItem(
                id: "action.saveWorkspace",
                icon: "square.stack.3d.up",
                title: "Save Workspace…",
                subtitle: "Snapshot the current tab set",
                category: .action,
                shortcut: nil,
                action: {
                    NotificationCenter.default.post(name: .pgbrainSaveWorkspace, object: service.connection.id)
                }
            ),
        ]
        // One palette item per saved workspace — quick switch via
        // ⌘K rather than mousing into the sidebar menu.
        for ws in WorkspaceStore.shared.workspaces(for: service.connection.id) {
            items.append(CommandItem(
                id: "action.switchWorkspace.\(ws.id.uuidString)",
                icon: "square.stack.3d.up.fill",
                title: "Switch to: \(ws.name)",
                subtitle: "\(ws.tabs.count) tab\(ws.tabs.count == 1 ? "" : "s")",
                category: .action,
                shortcut: nil,
                action: {
                    NotificationCenter.default.post(
                        name: .pgbrainSwitchWorkspace,
                        object: service.connection.id,
                        userInfo: ["workspaceID": ws.id]
                    )
                }
            ))
        }
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

        // Diff last two results — only meaningful when the active
        // tab is a scratchpad with ≥2 successful results.
        if let selID = service.workspace.selectedID,
           let active = service.workspace.tabs.first(where: { $0.id == selID }),
           case .scratchpad(let pad) = active.kind {
            let succ = pad.orderedResults.filter {
                if case .success = $0.status { return true }
                return false
            }.count
            if succ >= 2 {
                items.append(CommandItem(
                    id: "action.diffLastTwo",
                    icon: "rectangle.split.2x1",
                    title: "Diff Last Two Results",
                    subtitle: "Side-by-side delta of the two most recent results",
                    category: .action,
                    shortcut: nil,
                    action: { pad.requestedDiffLastTwo = true }
                ))
            }
        }

        // Active-tab actions: rename + colour pick. Both reduce to a
        // single palette entry — the rename hands off to an inline
        // TextField on the tab chip, the colour picker opens a
        // confirmationDialog with all options. Earlier versions
        // spammed 10 colour rows into every palette open which made
        // unrelated queries (`rename tab`) get drowned out.
        if let selID = service.workspace.selectedID,
           let active = service.workspace.tabs.first(where: { $0.id == selID }) {
            items.append(CommandItem(
                id: "action.renameTab",
                icon: "pencil",
                title: "Rename Tab…",
                subtitle: "Current tab: \(active.title)",
                category: .action,
                shortcut: nil,
                action: { active.requestedRename = true }
            ))
            items.append(CommandItem(
                id: "action.colorTab",
                icon: "paintpalette",
                title: "Color Tab…",
                subtitle: "Pick a tag colour for: \(active.title)",
                category: .action,
                shortcut: nil,
                action: { active.requestedColorPicker = true }
            ))
        }
        return items
    }

    // MARK: - Table view modes

    /// Grid / Form / Map switches for the front *table* tab. "Map" only
    /// appears when the table actually has a geometry/geography column (and
    /// the database has PostGIS). Fires `.pgbrainSetTableViewMode`, which the
    /// front table tab consumes.
    private static func viewModes(service: ConnectionService) -> [CommandItem] {
        guard let selID = service.workspace.selectedID,
              let active = service.workspace.tabs.first(where: { $0.id == selID }),
              case .table(let node) = active.kind
        else { return [] }
        let cid = service.connection.id

        func cmd(_ mode: String, _ title: String, _ icon: String) -> CommandItem {
            CommandItem(
                id: "viewmode.\(mode)",
                icon: icon,
                title: title,
                subtitle: "Show \(node.name) as \(mode)",
                category: .action,
                shortcut: nil,
                action: {
                    NotificationCenter.default.post(
                        name: .pgbrainSetTableViewMode,
                        object: cid,
                        userInfo: ["mode": mode]
                    )
                }
            )
        }

        var out = [
            cmd("grid", "View as Grid", "tablecells"),
            cmd("form", "View as Form", "list.bullet.rectangle.portrait"),
        ]
        // Edit-structure entry — only for real tables (not views).
        if node.kind == .table {
            out.append(CommandItem(
                id: "action.editStructure",
                icon: "slider.horizontal.3",
                title: "Edit structure…",
                subtitle: "Designer for \(node.name): add / rename / drop columns",
                category: .action,
                shortcut: nil,
                action: {
                    NotificationCenter.default.post(
                        name: .pgbrainEditTableStructure,
                        object: cid,
                        userInfo: ["schema": node.schema, "table": node.name]
                    )
                }
            ))
        }
        // Prefer the live (enriched) columns; fall back to the tab's snapshot.
        let enriched = service.visibleSchema.schemas
            .first(where: { $0.name == node.schema })?
            .tables.first(where: { $0.name == node.name })
        let cols = (enriched?.columns.isEmpty == false) ? enriched!.columns : node.columns
        if service.hasPostGIS && cols.contains(where: { RowsFetcher.isSpatialType($0.typeName) }) {
            out.append(cmd("map", "View as Map", "map"))
        }
        return out
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
        for schema in service.visibleSchema.schemas {
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

    // MARK: - ERD per schema

    private static func erds(service: ConnectionService) -> [CommandItem] {
        service.visibleSchema.schemas.map { schema in
            let name = schema.name
            return CommandItem(
                id: "erd.\(name)",
                icon: "point.3.connected.trianglepath.dotted",
                title: "Show ERD: \(name)",
                subtitle: "\(schema.tables.count) tables",
                category: .schema,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    NotificationCenter.default.post(
                        name: .pgbrainShowERD, object: service.connection.id,
                        userInfo: ["schema": name]
                    )
                }
            )
        }
    }

    // MARK: - Functions

    private static func functions(service: ConnectionService) -> [CommandItem] {
        var out: [CommandItem] = []
        for schema in service.visibleSchema.schemas {
            for fn in schema.functions {
                let schemaName = schema.name
                let fnName = fn.name
                let args = fn.arguments
                let verb = fn.kind == .procedure ? "Call" : "Run"
                out.append(CommandItem(
                    id: "function.\(schema.name).\(fn.name)\(fn.arguments)",
                    icon: "function",
                    title: fn.signature,
                    subtitle: "Edit · \(schema.name) · \(fn.kind.rawValue)",
                    category: .function,
                    shortcut: nil,
                    action: {
                        AppDelegate.shared?.openConnection(service.connection)
                        NotificationCenter.default.post(
                            name: .pgbrainEditFunction,
                            object: service.connection.id,
                            userInfo: ["schema": schemaName, "name": fnName, "args": args]
                        )
                    }
                ))
                out.append(CommandItem(
                    id: "function.run.\(schema.name).\(fn.name)\(fn.arguments)",
                    icon: fn.kind == .procedure ? "gearshape.2" : "play.circle",
                    title: "\(verb) \(fn.signature)",
                    subtitle: "\(schema.name) · \(fn.kind.rawValue)",
                    category: .function,
                    shortcut: nil,
                    action: {
                        AppDelegate.shared?.openConnection(service.connection)
                        NotificationCenter.default.post(
                            name: .pgbrainRunFunction,
                            object: service.connection.id,
                            userInfo: ["schema": schemaName, "name": fnName, "args": args]
                        )
                    }
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
        for schema in service.visibleSchema.schemas {
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
