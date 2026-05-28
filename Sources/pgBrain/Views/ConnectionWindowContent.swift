import SwiftUI

/// Identifiable wrapper so SwiftUI can drive sheet/dialog presentation
/// from a single String like a schema name.
struct IdentifiedString: Identifiable, Equatable {
    let id: String
    var value: String { id }
}

extension Notification.Name {
    /// Posted by the command palette to ask the connection-window
    /// matching `object as? UUID` to show its Activity Panel sheet.
    static let pgbrainOpenActivityPanel = Notification.Name("cloud.souris.pgbrain.openActivityPanel")
    /// Asks the matching window to open the sequence inspector sheet.
    static let pgbrainOpenSequenceInspector = Notification.Name("cloud.souris.pgbrain.openSequenceInspector")
    /// Asks the matching window to open the LISTEN/NOTIFY sheet.
    static let pgbrainOpenNotifyPanel = Notification.Name("cloud.souris.pgbrain.openNotifyPanel")
    /// Asks the matching window to open the snippets library sheet.
    static let pgbrainOpenSnippets = Notification.Name("cloud.souris.pgbrain.openSnippets")
    /// Asks the matching window to open the create-schema sheet.
    static let pgbrainCreateSchema = Notification.Name("cloud.souris.pgbrain.createSchema")
    /// Asks the matching window to open the create-database sheet.
    static let pgbrainCreateDatabase = Notification.Name("cloud.souris.pgbrain.createDatabase")
    /// Asks the matching window to open a function in the editor.
    /// `userInfo["schema"]` + `userInfo["name"]` + `userInfo["args"]` identify it.
    static let pgbrainEditFunction = Notification.Name("cloud.souris.pgbrain.editFunction")
    /// Asks the matching window to open the ERD for `userInfo["schema"]`.
    static let pgbrainShowERD = Notification.Name("cloud.souris.pgbrain.showERD")
    /// Asks the matching window to prompt the user for a name and
    /// save the current tab set as a workspace.
    static let pgbrainSaveWorkspace = Notification.Name("cloud.souris.pgbrain.saveWorkspace")
    /// Asks the matching window to switch to a saved workspace.
    /// `userInfo["workspaceID"]` carries the `SavedWorkspace.id`.
    static let pgbrainSwitchWorkspace = Notification.Name("cloud.souris.pgbrain.switchWorkspace")
    /// Asks the matching window to show the query-history sheet.
    static let pgbrainOpenQueryHistory = Notification.Name("cloud.souris.pgbrain.openQueryHistory")
}

/// Drives the confirmation dialog for destructive maintenance actions
/// (VACUUM FULL, REINDEX). Identifiable so `.confirmationDialog(item:)`
/// can pop and dismiss it.
struct MaintenanceRequest: Identifiable {
    let id = UUID()
    let table: TableNode
    let action: AdminActions.Maintenance
}

struct CommentsTarget: Identifiable {
    let id: String
    let schema: String
    let table: String
    init(schema: String, table: String) {
        self.schema = schema
        self.table = table
        self.id = "\(schema).\(table)"
    }
}

struct ConnectionWindowContent: View {
    @Bindable var service: ConnectionService
    @State private var copySource: TableNode?
    @State private var showSchemaDiff = false
    @State private var sidebarFilter: String = ""
    @State private var sidebarVisible: Bool = true
    @State private var showActivityPanel = false
    @State private var showQueryHistory = false
    @State private var showSaveWorkspaceDialog = false
    @State private var workspaceNameDraft = ""
    @State private var showCreateSchema = false
    @State private var renameSchemaTarget: IdentifiedString?
    @State private var dropSchemaTarget: IdentifiedString?
    @State private var commentsTarget: CommentsTarget?
    @State private var pendingMaintenance: MaintenanceRequest?
    @State private var showSequenceInspector = false
    @State private var showNotifyPanel = false
    @State private var showSnippets = false
    @State private var showCreateDatabase = false
    @State private var dropDatabaseTarget: IdentifiedString?
    @State private var findUsagesTarget: CommentsTarget?
    @State private var editFunction: FunctionNode?
    @State private var truncateTarget: CommentsTarget?
    @State private var generateDataTarget: TableNode?
    @State private var editViewTarget: TableNode?
    @State private var erdSchema: IdentifiedString?

    /// Convenience pass-through to `service.visibleSchema` so views
    /// in this file can read the filtered snapshot without re-doing
    /// the SchemaVisibility lookup on every render.
    private var visibleSchema: SchemaSnapshot { service.visibleSchema }

    private var appearance: ConnectionAppearance {
        ConnectionAppearance(connection: service.connection)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thin coloured stripe at the very top — connection colour, or
            // red on production. Disappears entirely for an uncoloured,
            // non-prod connection.
            if appearance.connection.colorTag != .none || appearance.connection.isProduction {
                Rectangle()
                    .fill(appearance.emphasized)
                    .frame(height: 3)
            }
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusFooter(service: service)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $copySource) { source in
            CrossDBCopyView(source: source, sourceService: service)
        }
        .sheet(isPresented: $showSchemaDiff) {
            SchemaDiffView(source: service) { showSchemaDiff = false }
        }
        .sheet(isPresented: $showActivityPanel) {
            ActivityPanelView(service: service) { showActivityPanel = false }
        }
        .sheet(isPresented: $showCreateSchema) {
            CreateSchemaSheet(service: service) { showCreateSchema = false }
        }
        .sheet(item: $renameSchemaTarget) { target in
            RenameSchemaSheet(service: service, original: target.value) {
                renameSchemaTarget = nil
            }
        }
        .sheet(item: $dropSchemaTarget) { target in
            DropSchemaSheet(service: service, target: target.value) {
                dropSchemaTarget = nil
            }
        }
        .sheet(item: $commentsTarget) { target in
            CommentsEditorSheet(
                service: service,
                schema: target.schema,
                table: target.table,
                onClose: { commentsTarget = nil },
                onSaved: { reloadInspectorFor(schema: target.schema, table: target.table) }
            )
        }
        .sheet(isPresented: $showSequenceInspector) {
            SequenceInspectorView(service: service) { showSequenceInspector = false }
        }
        .sheet(isPresented: $showNotifyPanel) {
            NotifyPanelView(service: service) { showNotifyPanel = false }
        }
        .sheet(isPresented: $showSnippets) {
            SnippetsView(
                onInsert: { body in insertSnippet(body) },
                onClose: { showSnippets = false }
            )
        }
        .sheet(isPresented: $showCreateDatabase) {
            CreateDatabaseSheet(service: service) { showCreateDatabase = false }
        }
        .sheet(item: $dropDatabaseTarget) { target in
            DropDatabaseSheet(service: service, target: target.value) { dropDatabaseTarget = nil }
        }
        .sheet(item: $findUsagesTarget) { target in
            FindUsagesView(
                service: service,
                schema: target.schema, table: target.table,
                onClose: { findUsagesTarget = nil },
                onOpenFunction: { fn in
                    findUsagesTarget = nil
                    editFunction = fn
                },
                onOpenTable: { node in
                    findUsagesTarget = nil
                    service.workspace.openTable(node)
                }
            )
        }
        .sheet(item: $editFunction) { fn in
            FunctionEditorView(
                service: service,
                function: fn,
                onClose: { editFunction = nil }
            )
        }
        .sheet(item: $truncateTarget) { target in
            TruncateSheet(
                service: service, schema: target.schema, table: target.table,
                onClose: { truncateTarget = nil },
                onDone: { reloadActiveTab() }
            )
        }
        .sheet(item: $generateDataTarget) { node in
            GenerateDataSheet(
                service: service, table: node,
                onClose: { generateDataTarget = nil },
                onDone: { reloadActiveTab() }
            )
        }
        .sheet(item: $editViewTarget) { node in
            ViewEditorView(
                service: service, table: node,
                onClose: { editViewTarget = nil },
                onSaved: { Task { await service.loadSchema() } }
            )
        }
        .sheet(item: $erdSchema) { target in
            if let schemaNode = service.visibleSchema.schemas.first(where: { $0.name == target.value }) {
                ERDView(
                    schema: schemaNode,
                    onOpenTable: { node in
                        erdSchema = nil
                        service.workspace.openTable(node)
                    },
                    onClose: { erdSchema = nil }
                )
            }
        }
        .confirmationDialog(
            confirmTitle(for: pendingMaintenance),
            isPresented: Binding(
                get: { pendingMaintenance != nil && pendingMaintenance!.action.isDestructive },
                set: { if !$0 { pendingMaintenance = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMaintenance
        ) { req in
            Button(req.action.label, role: .destructive) {
                runMaintenance(req.action, on: req.table)
                pendingMaintenance = nil
            }
            Button("Cancel", role: .cancel) { pendingMaintenance = nil }
        } message: { req in
            Text(req.action.help)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainOpenSequenceInspector)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                showSequenceInspector = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainOpenNotifyPanel)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                showNotifyPanel = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainOpenSnippets)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                showSnippets = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainCreateSchema)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                showCreateSchema = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainCreateDatabase)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                showCreateDatabase = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainEditFunction)) { notif in
            guard let id = notif.object as? UUID, id == service.connection.id,
                  let schema = notif.userInfo?["schema"] as? String,
                  let name = notif.userInfo?["name"] as? String
            else { return }
            if let fn = service.schema.schemas.first(where: { $0.name == schema })?
                .functions.first(where: { $0.name == name }) {
                editFunction = fn
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainShowERD)) { notif in
            guard let id = notif.object as? UUID, id == service.connection.id,
                  let schema = notif.userInfo?["schema"] as? String else { return }
            erdSchema = IdentifiedString(id: schema)
        }
        .sheet(isPresented: $showQueryHistory) {
            QueryHistoryView(
                connectionID: service.connection.id,
                onInsert: { sql in
                    // Drop into a new scratchpad cell pre-populated
                    // with the picked statement.
                    let pad: Notebook
                    if let active = service.workspace.tabs.first(where: { $0.id == service.workspace.selectedID }),
                       case .scratchpad(let existing) = active.kind {
                        pad = existing
                    } else {
                        pad = service.workspace.openScratchpad()
                    }
                    if let firstSql = pad.cells.first(where: { $0.kind == .sql }) {
                        let separator = firstSql.text.isEmpty ? "" : "\n\n"
                        firstSql.text += separator + sql
                    }
                    showQueryHistory = false
                },
                onClose: { showQueryHistory = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainOpenQueryHistory)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                showQueryHistory = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainOpenActivityPanel)) { notif in
            // ⌘K → "Show Activity Panel" posts this with the target
            // connection ID. Only the window that owns that
            // connection should react.
            if let id = notif.object as? UUID, id == service.connection.id {
                showActivityPanel = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainSaveWorkspace)) { notif in
            if let id = notif.object as? UUID, id == service.connection.id {
                workspaceNameDraft = "Workspace \((WorkspaceStore.shared.workspaces(for: service.connection.id).count) + 1)"
                showSaveWorkspaceDialog = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pgbrainSwitchWorkspace)) { notif in
            guard let connID = notif.object as? UUID, connID == service.connection.id,
                  let wsID = notif.userInfo?["workspaceID"] as? UUID,
                  let ws = WorkspaceStore.shared.workspaces(for: connID).first(where: { $0.id == wsID })
            else { return }
            switchTo(workspace: ws)
        }
        .alert("Name this workspace", isPresented: $showSaveWorkspaceDialog) {
            TextField("Workspace name", text: $workspaceNameDraft)
            Button("Save") {
                let trimmed = workspaceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { saveCurrentAsWorkspace(named: trimmed) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Captures every open tab — schema, scratchpad text, colour, WHERE/ORDER BY. Switch back later from the Workspaces menu.")
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        switch service.state {
        case .idle, .connecting:
            connectingPlaceholder
        case .connected:
            connectedWorkspace
        case .error(let message):
            errorPlaceholder(message: message)
        case .closed:
            closedPlaceholder
        }
    }

    @ViewBuilder
    private var connectedWorkspace: some View {
        HSplitView {
            if sidebarVisible {
                sidebarPane
                    // HSplitView remembers per-session manual resizes,
                    // but its first-open width was being computed from
                    // `idealWidth = 260` plus column content padding,
                    // ending up much wider than ⌘B-toggled re-show
                    // (which honours the minWidth). Tightened the
                    // ideal so the default matches the toggled width.
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 420)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            workspacePane
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        .background(keyboardShortcuts)
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
    }

    /// Hidden buttons that own the per-window keyboard shortcuts.
    /// Living in this view means the bindings only fire when a
    /// connection window is key — they go silent on the Welcome /
    /// About windows automatically. Same hidden-button trick the
    /// table-tab uses for ⌘F.
    @ViewBuilder
    private var keyboardShortcuts: some View {
        Group {
            shortcut("w", modifiers: .command, action: closeCurrentTabOrWindow)
            // ⌘⇧W bypasses the tab-first rule and closes the window
            // outright — matches Safari / Chrome's "Close Window"
            // shortcut when tabs are open.
            shortcut("w", modifiers: [.command, .shift]) {
                NSApp.keyWindow?.performClose(nil)
            }
            shortcut("t", modifiers: .command) { _ = service.workspace.openScratchpad() }
            // Tab navigation — bind multiple aliases so Safari /
            // Chrome / VSCode / JetBrains muscle memory all work.
            shortcut(.rightArrow, modifiers: [.command, .option]) { service.workspace.nextTab() }
            shortcut(.leftArrow,  modifiers: [.command, .option]) { service.workspace.previousTab() }
            shortcut("]", modifiers: [.command, .shift]) { service.workspace.nextTab() }
            shortcut("[", modifiers: [.command, .shift]) { service.workspace.previousTab() }
            shortcut(.tab, modifiers: .control) { service.workspace.nextTab() }
            shortcut(.tab, modifiers: [.control, .shift]) { service.workspace.previousTab() }
            // ⌘1..⌘8 → jump to tab N (1-indexed). ⌘9 jumps to the
            // last tab, matching Safari/Chrome.
            ForEach(1...8, id: \.self) { i in
                shortcut(KeyEquivalent(Character(String(i))), modifiers: .command) {
                    service.workspace.selectTab(at: i - 1)
                }
            }
            shortcut("9", modifiers: .command) {
                service.workspace.selectTab(at: service.workspace.tabs.count - 1)
            }
            // ⌃1..⌃9 switch between *connection windows* — same
            // n-indexed convention as ⌘1..⌘9 for tabs, just one
            // ring up. ⌃9 jumps to the last open window.
            ForEach(1...8, id: \.self) { i in
                shortcut(KeyEquivalent(Character(String(i))), modifiers: .control) {
                    AppDelegate.shared?.focusConnectionWindow(at: i - 1)
                }
            }
            shortcut("9", modifiers: .control) {
                if let count = AppDelegate.shared?.windowManager.entries.count, count > 0 {
                    AppDelegate.shared?.focusConnectionWindow(at: count - 1)
                }
            }
            // ⌘R reloads the *current tab*'s data — table tab
            // re-fetches rows + inspector, scratchpad re-runs the
            // active cell. Schema reload remains in the ellipsis
            // menu since it's a heavier, rarer action. ⌘⇧R reloads
            // the schema for users who prefer the IDE convention.
            shortcut("r", modifiers: .command) { reloadActiveTab() }
            shortcut("r", modifiers: [.command, .shift]) {
                Task { await service.loadSchema() }
            }
            // ⌘B toggles the sidebar — VSCode / Code muscle memory.
            shortcut("b", modifiers: .command) {
                sidebarVisible.toggle()
            }
        }
        .hidden()
    }

    @ViewBuilder
    private func shortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
    }

    /// ⌘W routing: close the current tab first; only close the
    /// window when no tabs are open. Matches Safari / Chrome / Code.
    private func closeCurrentTabOrWindow() {
        if !service.workspace.tabs.isEmpty {
            service.workspace.closeCurrentTab()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    // MARK: - Saved workspaces

    /// Snapshot every open tab into a `SavedWorkspace` + persist it.
    /// Scratchpad text comes from the live `Notebook.plainText` so the
    /// saved snapshot includes any unsaved query edits.
    private func saveCurrentAsWorkspace(named name: String) {
        let tabs: [SavedWorkspaceTab] = service.workspace.tabs.map { tab in
            switch tab.kind {
            case .table(let t):
                return SavedWorkspaceTab(
                    kind: .table,
                    tableSchema: t.schema,
                    tableName: t.name,
                    tableWhereClause: tab.tableWhereClause.isEmpty ? nil : tab.tableWhereClause,
                    tableOrderByClause: tab.tableOrderByClause.isEmpty ? nil : tab.tableOrderByClause,
                    colorTag: tab.color?.rawValue,
                    tabTitle: tab.title == t.qualifiedName ? nil : tab.title
                )
            case .scratchpad(let pad):
                return SavedWorkspaceTab(
                    kind: .scratchpad,
                    scratchpadTitle: pad.title,
                    scratchpadText: pad.plainText,
                    scratchpadSearchPath: pad.searchPath,
                    colorTag: tab.color?.rawValue,
                    tabTitle: tab.title == pad.title ? nil : tab.title
                )
            }
        }
        let selectedIndex: Int? = service.workspace.selectedID.flatMap { id in
            service.workspace.tabs.firstIndex(where: { $0.id == id })
        }
        let ws = SavedWorkspace(
            id: UUID(), name: name,
            tabs: tabs, selectedTabIndex: selectedIndex,
            createdAt: Date()
        )
        WorkspaceStore.shared.save(ws, for: service.connection.id)
    }

    /// Replace the current tab set with the saved one. We close every
    /// open tab first (no confirmation — workspaces are how the user
    /// "saves" their state, so this is the explicit opt-in to
    /// discard) then replay the saved tabs in order.
    private func switchTo(workspace: SavedWorkspace) {
        for tab in service.workspace.tabs {
            service.workspace.closeTab(id: tab.id)
        }
        for saved in workspace.tabs {
            switch saved.kind {
            case .table:
                guard let schema = saved.tableSchema, let name = saved.tableName,
                      let live = service.schema.schemas
                        .first(where: { $0.name == schema })?
                        .tables.first(where: { $0.name == name })
                else { continue }
                service.workspace.openTable(live)
                if let opened = service.workspace.tabs.last {
                    opened.tableWhereClause = saved.tableWhereClause ?? ""
                    opened.tableOrderByClause = saved.tableOrderByClause ?? ""
                    opened.color = saved.colorTag.flatMap { Connection.ColorTag(rawValue: $0) }
                    if let custom = saved.tabTitle { opened.title = custom }
                }
            case .scratchpad:
                let pad = service.workspace.openScratchpad()
                if let title = saved.scratchpadTitle { pad.title = title }
                if let text = saved.scratchpadText, !text.isEmpty,
                   let firstSql = pad.cells.first(where: { $0.kind == .sql }) {
                    firstSql.text = text
                }
                pad.searchPath = saved.scratchpadSearchPath
                if let opened = service.workspace.tabs.last {
                    opened.color = saved.colorTag.flatMap { Connection.ColorTag(rawValue: $0) }
                    if let custom = saved.tabTitle {
                        opened.title = custom
                    } else if let scratchTitle = saved.scratchpadTitle {
                        opened.title = scratchTitle
                    }
                }
            }
        }
        if let idx = workspace.selectedTabIndex,
           service.workspace.tabs.indices.contains(idx) {
            service.workspace.selectedID = service.workspace.tabs[idx].id
        }
    }

    // MARK: - Admin action helpers

    private func runMaintenance(_ action: AdminActions.Maintenance, on table: TableNode) {
        Task {
            _ = await AdminActions.runMaintenance(action, on: table.schema, table: table.name, service: service)
        }
    }

    private func confirmTitle(for req: MaintenanceRequest?) -> String {
        guard let req else { return "" }
        return "\(req.action.label) \(req.table.schema).\(req.table.name)?"
    }

    private func reloadInspectorFor(schema: String, table: String) {
        if let tab = service.workspace.tabs.first(where: {
            if case .table(let t) = $0.kind { return t.schema == schema && t.name == table } else { return false }
        }),
           case .table(let t) = tab.kind {
            let inspector = service.inspector(for: tab, table: t)
            Task { await inspector.load() }
        }
    }

    private func insertSnippet(_ body: String) {
        let pad: Notebook
        if let active = service.workspace.tabs.first(where: { $0.id == service.workspace.selectedID }),
           case .scratchpad(let existing) = active.kind {
            pad = existing
        } else {
            pad = service.workspace.openScratchpad()
        }
        if let firstSql = pad.cells.first(where: { $0.kind == .sql }) {
            let separator = firstSql.text.isEmpty ? "" : "\n\n"
            firstSql.text += separator + SnippetStore.expand(body).text
        }
    }

    /// ⌘R hook: re-fetch whatever the active tab is showing. Table
    /// tabs reload rows (and the inspector if it had been visited);
    /// no-op for tabs that don't have a meaningful "reload" notion.
    private func reloadActiveTab() {
        guard let id = service.workspace.selectedID,
              let tab = service.workspace.tabs.first(where: { $0.id == id })
        else { return }
        switch tab.kind {
        case .table(let t):
            let loader = service.loader(for: tab, table: t)
            let inspector = service.inspector(for: tab, table: t)
            Task {
                await loader.load()
                if case .loaded = inspector.state {
                    await inspector.load()
                }
            }
        case .scratchpad:
            // No-op for scratchpads — Cmd+⏎ in a cell is the
            // canonical "run" path.
            break
        }
    }

    @ViewBuilder
    private var sidebarPane: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().opacity(0.6)
            switch service.schemaState {
            case .loaded:
                sidebarSearchField
                SidebarOutlineView(
                    snapshot: visibleSchema,
                    filterTerm: sidebarFilter,
                    onOpenTable: { service.workspace.openTable($0) },
                    onCopyTable: { copySource = $0 },
                    onShowStructure: { service.workspace.openTable($0, focusPane: .structure) },
                    onShowDDL: { service.workspace.openTable($0, focusPane: .ddl) },
                    onMaintenance: { table, action in
                        if action.isDestructive {
                            pendingMaintenance = MaintenanceRequest(table: table, action: action)
                        } else {
                            runMaintenance(action, on: table)
                        }
                    },
                    onRefreshMatView: { table, concurrently in
                        Task {
                            _ = await AdminActions.refreshMaterializedView(
                                schema: table.schema, name: table.name,
                                concurrently: concurrently, service: service
                            )
                        }
                    },
                    onEditComments: { table in
                        commentsTarget = CommentsTarget(schema: table.schema, table: table.name)
                    },
                    onRenameSchema: { name in
                        renameSchemaTarget = IdentifiedString(id: name)
                    },
                    onDropSchema: { name in
                        dropSchemaTarget = IdentifiedString(id: name)
                    },
                    onCreateSchema: { showCreateSchema = true },
                    onFindUsages: { table in
                        findUsagesTarget = CommentsTarget(schema: table.schema, table: table.name)
                    },
                    onOpenFunction: { fn in
                        editFunction = fn
                    },
                    onTruncate: { table in
                        truncateTarget = CommentsTarget(schema: table.schema, table: table.name)
                    },
                    onGenerateData: { table in
                        generateDataTarget = table
                    },
                    onEditView: { table in
                        editViewTarget = table
                    },
                    onShowERD: { name in
                        erdSchema = IdentifiedString(id: name)
                    }
                )
            case .loading, .idle:
                VStack(spacing: Tokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading schema…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: Tokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Schema load failed")
                        .font(.callout)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") { Task { await service.loadSchema() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Filter tables", text: $sidebarFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !sidebarFilter.isEmpty {
                Button {
                    sidebarFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appearance.connection.colorTag == .none
                      ? Color.secondary.opacity(0.25)
                      : appearance.connection.colorTag.swiftUIColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(appearance.connection.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(appearance.connection.database.isEmpty ? appearance.connection.host : appearance.connection.database)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if appearance.connection.isProduction {
                Text("PROD")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Tokens.Brand.danger)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Menu {
                Section("pg_dump") {
                    ForEach(PgDumpCLI.Format.allCases) { fmt in
                        Button("Dump as \(fmt.rawValue)") { runPgDump(format: fmt) }
                    }
                }
                Divider()
                Button("Reload schema") { Task { await service.loadSchema() } }
                Button("Diff schemas…") { showSchemaDiff = true }
                Button("Activity…") { showActivityPanel = true }
                Button("Query history…") { showQueryHistory = true }
                Button("Sequences…") { showSequenceInspector = true }
                Button("LISTEN / NOTIFY…") { showNotifyPanel = true }
                Button("Snippets…") { showSnippets = true }
                Divider()
                Button("New schema…") { showCreateSchema = true }
                Button("New database…") { showCreateDatabase = true }
                Divider()
                Menu("Workspaces") {
                    Button("Save current as workspace…") {
                        workspaceNameDraft = "Workspace \((WorkspaceStore.shared.workspaces(for: service.connection.id).count) + 1)"
                        showSaveWorkspaceDialog = true
                    }
                    let saved = WorkspaceStore.shared.workspaces(for: service.connection.id)
                    if !saved.isEmpty {
                        Divider()
                        Section("Switch to") {
                            ForEach(saved) { ws in
                                Button(ws.name) { switchTo(workspace: ws) }
                            }
                        }
                        Divider()
                        Menu("Delete") {
                            ForEach(saved) { ws in
                                Button(ws.name, role: .destructive) {
                                    WorkspaceStore.shared.delete(id: ws.id, for: service.connection.id)
                                }
                            }
                        }
                    }
                }
                Divider()
                // Schema-visibility toggles. Hidden schemas disappear
                // from the sidebar tree AND completion suggestions
                // until re-enabled here.
                Menu("Schemas") {
                    let connID = service.connection.id
                    let hidden = SchemaVisibility.shared.hidden(for: connID)
                    let names = service.schema.schemas.map(\.name).sorted()
                    if names.isEmpty {
                        Text("(no schemas yet)").foregroundStyle(.secondary)
                    } else {
                        ForEach(names, id: \.self) { name in
                            Button {
                                SchemaVisibility.shared.toggle(schema: name, connectionID: connID)
                            } label: {
                                Label(name, systemImage: hidden.contains(name) ? "" : "checkmark")
                            }
                        }
                        if !hidden.isEmpty {
                            Divider()
                            Button("Show all schemas") {
                                SchemaVisibility.shared.clear(connectionID: connID)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Connection actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(appearance.emphasized.opacity(0.08))
    }

    private func runPgDump(format: PgDumpCLI.Format) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let ext = format.fileExtension
        let stem = service.connection.database.isEmpty ? service.connection.name : service.connection.database
        panel.nameFieldStringValue = ext.isEmpty ? stem : "\(stem).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let conn = service.connection
        let password = Keychain.password(for: conn.id) ?? ""
        let op = service.operations.begin(
            kind: .export,
            summary: "pg_dump → \(url.lastPathComponent)"
        )
        let tracker = service.operations
        Task {
            do {
                _ = try await PgDumpCLI.dump(
                    connection: conn,
                    password: password,
                    format: format,
                    destination: url
                )
                tracker.finish(op, status: .succeeded)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "pg_dump failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @ViewBuilder
    private var workspacePane: some View {
        VStack(spacing: 0) {
            TabStripView(workspace: service.workspace, appearance: appearance)
            Divider()
            if let selected = service.workspace.selectedTab {
                switch selected.kind {
                case .table(let table):
                    TableTabView(table: table, tab: selected, service: service)
                        .id(table.id)
                case .scratchpad(let pad):
                    NotebookView(notebook: pad, service: service)
                        .id(pad.id)
                }
            } else {
                emptyWorkspace
            }
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "tablecells")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Pick a table from the sidebar")
                .font(.headline)
            Text("Double-click any table or view to load its first 1,000 rows, or press ⌘N to open a SQL scratchpad.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectingPlaceholder: some View {
        VStack(spacing: Tokens.Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(service.connection.name)…")
                .font(.headline)
            Text("\(service.connection.username)@\(service.connection.host):\(service.connection.port)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPlaceholder(message: String) -> some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't connect")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.xl)
                .textSelection(.enabled)
            Button { service.retry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .controlSize(.large)
            .padding(.top, Tokens.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closedPlaceholder: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Disconnected").font(.headline)
            Button("Reconnect") { service.start() }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusFooter: View {
    @Bindable var service: ConnectionService
    @State private var opsPopoverShown = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            statusDot
            Text(stateLabel)
                .font(.caption.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            if service.connection.colorTag != .none {
                Circle()
                    .fill(service.connection.colorTag.swiftUIColor)
                    .frame(width: 8, height: 8)
                    .help("Connection color tag")
            }
            if service.connection.isProduction {
                Text("PRODUCTION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Tokens.Brand.danger)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(targetDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            opsIndicator
            if case .connected(_, let since) = service.state {
                Text("connected at \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var opsIndicator: some View {
        let running = service.operations.runningCount
        let total = service.operations.operations.count
        let visible = running > 0 || total > 0
        return Button {
            opsPopoverShown.toggle()
        } label: {
            HStack(spacing: 4) {
                if running > 0 {
                    ProgressView().controlSize(.mini)
                    Text("\(running) running")
                        .font(.caption.weight(.medium))
                } else if total > 0 {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .help("Show running operations")
        .popover(isPresented: $opsPopoverShown, arrowEdge: .bottom) {
            OperationsPopover(operations: service.operations)
        }
    }

    private var targetDescription: String {
        let conn = service.connection
        let db = conn.database.isEmpty ? "—" : conn.database
        return "\(conn.username)@\(conn.host):\(conn.port) · \(db)"
    }

    private var stateLabel: String {
        switch service.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error: return "Error"
        case .closed: return "Closed"
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch service.state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .error: return .red
        case .closed: return .secondary
        }
    }
}
