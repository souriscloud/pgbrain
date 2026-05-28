import SwiftUI

struct ConnectionWindowContent: View {
    @Bindable var service: ConnectionService
    @State private var copySource: TableNode?
    @State private var showSchemaDiff = false
    @State private var sidebarFilter: String = ""
    @State private var sidebarVisible: Bool = true

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
                    onShowDDL: { service.workspace.openTable($0, focusPane: .ddl) }
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
