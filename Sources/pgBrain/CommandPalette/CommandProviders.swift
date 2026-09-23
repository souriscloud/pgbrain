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
        out.append(contentsOf: databaseTools(service: service))
        out.append(contentsOf: schemaAdmin(service: service))
        out.append(contentsOf: viewModes(service: service))
        out.append(contentsOf: frontTableActions(service: service))
        out.append(contentsOf: tabs(service: service))
        out.append(contentsOf: tables(service: service))
        out.append(contentsOf: functions(service: service))
        out.append(contentsOf: scratchpads(service: service))
        out.append(contentsOf: schemas(service: service))
        out.append(contentsOf: erds(service: service))
        return out
    }

    // MARK: - Go to Table (⌘O)

    /// Relations + functions only. Recently opened relations rank first;
    /// objects in hidden schemas stay reachable but sink below the rest.
    static func goToItems(service: ConnectionService?) -> [CommandItem] {
        guard let service else { return [] }
        return relationItems(service: service) + functionJumpItems(service: service)
    }

    private static func relationItems(service: ConnectionService) -> [CommandItem] {
        let hidden = SchemaVisibility.shared.hidden(for: service.connection.id)
        let recents = NavigationHistoryStore.shared.recents(for: service.navigationScope)
        var recentRank: [String: Int] = [:]
        for (i, id) in recents.enumerated() { recentRank[id] = recents.count - i }
        var out: [CommandItem] = []
        for schema in service.schema.schemas {
            let isHidden = hidden.contains(schema.name)
            // Partitions are reached through their parent, as in the sidebar.
            for table in schema.tables where table.partitionOf == nil {
                let captured = table
                var bias = 0
                if let r = recentRank[table.id] { bias += 40 + r * 4 }
                if isHidden { bias -= 60 }
                if table.isExtensionOwned { bias -= 30 }
                var subtitle = "\(schema.name) · \(table.kindLabel)"
                if isHidden { subtitle += " · hidden schema" }
                if recentRank[table.id] != nil { subtitle += " · recent" }
                out.append(CommandItem(
                    id: "table.\(schema.name).\(table.name)",
                    icon: table.symbolName,
                    title: table.name,
                    subtitle: subtitle,
                    category: .table,
                    shortcut: nil,
                    action: { service.workspace.openTable(captured) },
                    qualifier: schema.name,
                    rankBias: bias
                ))
            }
        }
        return out
    }

    private static func functionJumpItems(service: ConnectionService) -> [CommandItem] {
        let hidden = SchemaVisibility.shared.hidden(for: service.connection.id)
        var out: [CommandItem] = []
        for schema in service.schema.schemas {
            let isHidden = hidden.contains(schema.name)
            for fn in schema.functions {
                let schemaName = schema.name, fnName = fn.name, args = fn.arguments
                out.append(CommandItem(
                    id: "goto.function.\(fn.id)",
                    icon: "function",
                    title: fn.name,
                    subtitle: "\(schema.name) · \(fn.kind.rawValue)\(fn.arguments)" + (isHidden ? " · hidden schema" : ""),
                    category: .function,
                    shortcut: nil,
                    action: {
                        CommandProviders.post(.pgbrainEditFunction, service: service,
                             userInfo: ["schema": schemaName, "name": fnName, "args": args])
                    },
                    qualifier: schema.name,
                    rankBias: (isHidden ? -60 : 0) + (fn.isExtensionOwned ? -30 : 0)
                ))
            }
        }
        return out
    }

    /// Window-scoped post: sibling windows share the connection id, so the
    /// window id rides along and `ConnectionService.owns` filters on it.
    static func post(_ name: Notification.Name, service: ConnectionService, userInfo: [String: Any] = [:]) {
        var info = userInfo
        info[pgbrainWindowIDKey] = service.workspace.windowID
        NotificationCenter.default.post(name: name, object: service.connection.id, userInfo: info)
    }

    // MARK: - Front table-tab actions

    /// Contextual actions for the table currently open in the front tab —
    /// mirrors the sidebar's table context menu so you can drive it from ⌘K.
    private static func frontTableActions(service: ConnectionService) -> [CommandItem] {
        guard let selID = service.workspace.selectedID,
              let active = service.workspace.tabs.first(where: { $0.id == selID }),
              case .table(let node) = active.kind else { return [] }
        let schema = node.schema, name = node.name
        let qn = "\(schema).\(name)"

        func postItem(_ id: String, _ title: String, _ icon: String, _ note: Notification.Name) -> CommandItem {
            CommandItem(id: id, icon: icon, title: title, subtitle: qn, category: .table, shortcut: nil, action: {
                CommandProviders.post(note, service: service, userInfo: ["schema": schema, "table": name])
            })
        }

        var out: [CommandItem] = [
            CommandItem(id: "fronttable.structure", icon: "list.bullet.rectangle", title: "Show Structure",
                        subtitle: qn, category: .table, shortcut: nil,
                        action: { service.workspace.openTable(node, focusPane: .structure) }),
            CommandItem(id: "fronttable.ddl", icon: "doc.plaintext", title: "Show CREATE SQL",
                        subtitle: qn, category: .table, shortcut: nil,
                        action: { service.workspace.openTable(node, focusPane: .ddl) }),
            postItem("fronttable.findUsages", "Find Usages…", "magnifyingglass", .pgbrainFindUsages),
            postItem("fronttable.comments", "Edit Comments…", "text.bubble", .pgbrainEditComments),
        ]
        // Export works for any relation; geometry/views included.
        for fmt in Exporter.Format.allCases {
            out.append(CommandItem(id: "fronttable.export.\(fmt.rawValue)", icon: "square.and.arrow.up",
                                   title: "Export Table as \(fmt.rawValue.uppercased())…", subtitle: qn,
                                   category: .table, shortcut: nil, action: {
                CommandProviders.post(.pgbrainExportTable, service: service, userInfo: ["format": fmt.rawValue])
            }))
        }
        if node.kind == .table {
            out.append(postItem("fronttable.newIndex", "New Index…", "key", .pgbrainNewIndex))
            out.append(postItem("fronttable.generateData", "Generate Data…", "wand.and.stars", .pgbrainGenerateData))
            out.append(postItem("fronttable.truncate", "Truncate…", "trash", .pgbrainTruncateTable))
            for kind in ["csv", "json"] {
                out.append(CommandItem(id: "fronttable.import.\(kind)", icon: "square.and.arrow.down",
                                       title: "Import \(kind.uppercased()) into Table…", subtitle: qn,
                                       category: .table, shortcut: nil, action: {
                    CommandProviders.post(.pgbrainImportTable, service: service, userInfo: ["kind": kind])
                }))
            }
            for m in AdminActions.Maintenance.allCases {
                out.append(CommandItem(id: "fronttable.maint.\(m.rawValue)", icon: "wrench.and.screwdriver",
                                       title: "\(m.label) Table", subtitle: qn,
                                       category: .table, shortcut: nil, action: {
                    CommandProviders.post(.pgbrainMaintenance, service: service, userInfo: ["schema": schema, "table": name, "action": m.rawValue])
                }))
            }
        }
        return out
    }

    // MARK: - Database tools (pg_dump)

    private static func databaseTools(service: ConnectionService) -> [CommandItem] {
        var out = PgDumpCLI.Format.allCases.map { fmt in
            CommandItem(
                id: "pgdump.\(fmt.rawValue)",
                icon: "arrow.down.doc",
                title: "pg_dump Database (\(fmt.rawValue))…",
                subtitle: service.connection.database.isEmpty ? "Streaming dump" : "Dump \(service.connection.database)",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    CommandProviders.post(.pgbrainPgDump, service: service, userInfo: ["format": fmt.rawValue])
                }
            )
        }
        out.append(CommandItem(
            id: "pgrestore",
            icon: "arrow.up.doc",
            title: "Restore Database…",
            subtitle: service.connection.database.isEmpty ? "pg_restore an archive" : "Restore into \(service.connection.database)",
            category: .action,
            shortcut: nil,
            action: {
                AppDelegate.shared?.openConnection(service.connection)
                CommandProviders.post(.pgbrainRestoreDatabase, service: service)
            }
        ))
        return out
    }

    // MARK: - Schema admin (rename / drop / visibility)

    private static func schemaAdmin(service: ConnectionService) -> [CommandItem] {
        let connID = service.connection.id
        let hidden = SchemaVisibility.shared.hidden(for: connID)
        var out: [CommandItem] = []
        for schema in service.schema.schemas {
            let name = schema.name
            out.append(CommandItem(id: "schemaadmin.rename.\(name)", icon: "pencil",
                                   title: "Rename Schema: \(name)…", subtitle: nil, category: .schema, shortcut: nil, action: {
                AppDelegate.shared?.openConnection(service.connection)
                CommandProviders.post(.pgbrainRenameSchema, service: service, userInfo: ["schema": name])
            }))
            out.append(CommandItem(id: "schemaadmin.duplicate.\(name)", icon: "doc.on.doc",
                                   title: "Duplicate Schema: \(name)…", subtitle: nil, category: .schema, shortcut: nil, action: {
                AppDelegate.shared?.openConnection(service.connection)
                CommandProviders.post(.pgbrainDuplicateSchema, service: service, userInfo: ["schema": name])
            }))
            out.append(CommandItem(id: "schemaadmin.drop.\(name)", icon: "trash",
                                   title: "Drop Schema: \(name)…", subtitle: nil, category: .schema, shortcut: nil, action: {
                AppDelegate.shared?.openConnection(service.connection)
                CommandProviders.post(.pgbrainDropSchema, service: service, userInfo: ["schema": name])
            }))
            let isHidden = hidden.contains(name)
            out.append(CommandItem(id: "schemaadmin.vis.\(name)", icon: isHidden ? "eye" : "eye.slash",
                                   title: "\(isHidden ? "Show" : "Hide") Schema: \(name)", subtitle: nil, category: .schema, shortcut: nil, action: {
                SchemaVisibility.shared.toggle(schema: name, connectionID: connID)
            }))
        }
        if !hidden.isEmpty {
            out.append(CommandItem(id: "schemaadmin.showall", icon: "eye",
                                   title: "Show All Schemas", subtitle: "\(hidden.count) hidden", category: .schema, shortcut: nil, action: {
                SchemaVisibility.shared.clear(connectionID: connID)
            }))
        }
        return out
    }

    // MARK: - Scratchpads (save current / reopen saved)

    private static func scratchpads(service: ConnectionService) -> [CommandItem] {
        var out: [CommandItem] = []

        // Save the front scratchpad to the library (when it has text).
        if let selID = service.workspace.selectedID,
           let active = service.workspace.tabs.first(where: { $0.id == selID }),
           case .scratchpad(let pad) = active.kind {
            let text = pad.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let count = SavedQueryStore.shared.queries.count
                out.append(CommandItem(
                    id: "scratchpad.saveCurrent",
                    icon: "square.and.arrow.down",
                    title: "Save Scratchpad…",
                    subtitle: "Add “\(pad.title)” to the saved library",
                    category: .query,
                    shortcut: nil,
                    action: {
                        SavedQueryStore.shared.upsert(SavedQuery(name: pad.title.isEmpty ? "Query \(count + 1)" : pad.title, sql: text))
                        service.toasts.show(.success, "Saved scratchpad — rename it in the Saved library")
                    }
                ))
            }
        }

        // Reopen any saved scratchpad as a new tab.
        for q in SavedQueryStore.shared.queries {
            let sql = q.sql
            out.append(CommandItem(
                id: "scratchpad.open.\(q.id.uuidString)",
                icon: "doc.text.magnifyingglass",
                title: "Open Scratchpad: \(q.name)",
                subtitle: q.notes.isEmpty ? "Reopen as a new tab" : q.notes,
                category: .query,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    let pad = service.workspace.openScratchpad()
                    if let first = pad.cells.first(where: { $0.kind == .sql }) { first.text = sql }
                }
            ))
        }
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
            CommandItem(
                id: "action.help",
                icon: "questionmark.circle",
                title: "pgBrain Help",
                subtitle: "Guide, shortcuts, support",
                category: .action,
                shortcut: "⌘?",
                action: { AppDelegate.shared?.showHelp() }
            ),
            CommandItem(
                id: "action.feedback",
                icon: "exclamationmark.bubble",
                title: "Send Feedback…",
                subtitle: "Report a bug or request a feature",
                category: .action,
                shortcut: nil,
                action: { AppDelegate.shared?.showFeedback() }
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
                id: "action.goToTable",
                icon: "arrow.right.doc.on.clipboard",
                title: "Go to Table…",
                subtitle: "Jump to a table, view, or function",
                category: .action,
                shortcut: "⌘O",
                action: { CommandPaletteWindow.shared.present(mode: .goToTable) }
            ),
            CommandItem(
                id: "action.navigateBack",
                icon: "chevron.left",
                title: "Navigate Back",
                subtitle: "Previous tab in this window's history",
                category: .action,
                shortcut: "⌘[",
                action: { service.workspace.goBack() }
            ),
            CommandItem(
                id: "action.navigateForward",
                icon: "chevron.right",
                title: "Navigate Forward",
                subtitle: "Next tab in this window's history",
                category: .action,
                shortcut: "⌘]",
                action: { service.workspace.goForward() }
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
                    CommandProviders.post(.pgbrainOpenActivityPanel, service: service)
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
                    CommandProviders.post(.pgbrainOpenQueryHistory, service: service)
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
                    CommandProviders.post(.pgbrainOpenSequenceInspector, service: service)
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
                    CommandProviders.post(.pgbrainOpenNotifyPanel, service: service)
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
                    CommandProviders.post(.pgbrainOpenSnippets, service: service)
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
                    CommandProviders.post(.pgbrainCreateSchema, service: service)
                }
            ),
            CommandItem(
                id: "action.createTable",
                icon: "tablecells.badge.ellipsis",
                title: "New Table…",
                subtitle: "Visual CREATE TABLE designer",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    CommandProviders.post(.pgbrainNewTable, service: service)
                }
            ),
            CommandItem(
                id: "action.schemaDiff",
                icon: "rectangle.split.2x1",
                title: "Diff Schemas…",
                subtitle: "Compare this database against another",
                category: .action,
                shortcut: nil,
                action: {
                    AppDelegate.shared?.openConnection(service.connection)
                    CommandProviders.post(.pgbrainShowSchemaDiff, service: service)
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
                    CommandProviders.post(.pgbrainNewFunction, service: service)
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
                    CommandProviders.post(.pgbrainCreateDatabase, service: service)
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
                    CommandProviders.post(.pgbrainSaveWorkspace, service: service)
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
                    CommandProviders.post(.pgbrainSwitchWorkspace, service: service, userInfo: ["workspaceID": ws.id])
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
            let succ = pad.cells.filter {
                if case .result(let id) = $0.kind,
                   let r = pad.results[id],
                   case .success = r.status { return true }
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

        func cmd(_ mode: String, _ title: String, _ icon: String) -> CommandItem {
            CommandItem(
                id: "viewmode.\(mode)",
                icon: icon,
                title: title,
                subtitle: "Show \(node.name) as \(mode)",
                category: .action,
                shortcut: nil,
                action: {
                    CommandProviders.post(.pgbrainSetTableViewMode, service: service, userInfo: ["mode": mode])
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
                    CommandProviders.post(.pgbrainEditTableStructure, service: service, userInfo: ["schema": node.schema, "table": node.name])
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
                icon: tab.iconName,
                title: service.workspace.displayTitle(for: tab),
                subtitle: "Switch to open tab",
                category: .tab,
                shortcut: nil,
                action: { service.workspace.selectedID = id }
            )
        }
    }

    // MARK: - Tables

    /// Same relation list as Go to Table, so hidden schemas stay reachable
    /// from ⌘K too — just ranked lower.
    private static func tables(service: ConnectionService) -> [CommandItem] {
        relationItems(service: service)
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
                    CommandProviders.post(.pgbrainShowERD, service: service, userInfo: ["schema": name])
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
                        CommandProviders.post(.pgbrainEditFunction, service: service, userInfo: ["schema": schemaName, "name": fnName, "args": args])
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
                        CommandProviders.post(.pgbrainRunFunction, service: service, userInfo: ["schema": schemaName, "name": fnName, "args": args])
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

