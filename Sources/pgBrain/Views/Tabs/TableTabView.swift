import AppKit
import SwiftUI
import Observation

/// Identifiable wrapper used to drive the distinct-values popover off
/// `.popover(item:)`. A plain String can't be Identifiable directly.
struct ColumnNameID: Identifiable, Hashable {
    let id: String
}

/// One table tab: header with staged-change controls, the Data / Structure /
/// DDL pane switch, and the pane itself. Rows, staged edits and paging live
/// on the tab's cached `RowsLoader`; pane / row-view mode / scroll position
/// live on `tab.tableViewState`, so switching tabs loses nothing.
struct TableTabView: View {
    let table: TableNode
    let tab: WorkspaceState.Tab
    let service: ConnectionService

    @State var loader: RowsLoader
    @State var inspector: InspectorLoader
    @State var showApplyErrorPopover = false
    @State var distinctValuesColumn: ColumnNameID?
    @State var showPreviewSQL = false
    @FocusState var findFocused: Bool

    var viewState: TableTabViewState { tab.tableViewState }

    init(table: TableNode, tab: WorkspaceState.Tab, service: ConnectionService) {
        self.table = table
        self.tab = tab
        self.service = service
        _loader = State(initialValue: service.loader(for: tab, table: table))
        _inspector = State(initialValue: service.inspector(for: tab, table: table))
    }

    /// Columns with real types — the view's `table` is captured at tab-open
    /// and may predate column enrichment; the loader's copy is what the grid
    /// renders from.
    var resolvedColumns: [ColumnNode] {
        loader.table.columns.isEmpty ? table.columns : loader.table.columns
    }

    var spatialColumns: [ColumnNode] {
        guard service.hasPostGIS else { return [] }
        return resolvedColumns.filter { RowsFetcher.isSpatialType($0.typeName) }
    }

    /// First text-ish column, used to label map markers.
    var mapLabelColumn: String? {
        resolvedColumns.first { col in
            let t = col.typeName.lowercased()
            return !RowsFetcher.isSpatialType(col.typeName)
                && ["text", "varchar", "char", "name", "bpchar", "character"].contains { t.hasPrefix($0) }
        }?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            paneStrip
            Divider()
            if viewState.pane == .data, loader.rowIdentity == .physical {
                noPrimaryKeyBanner
            }
            content
        }
        .background(shortcutButtons)
        .modifier(TableTabLifecycle(view: self))
        .alert(
            "Unapplied changes",
            isPresented: Binding(
                get: { loader.pendingNavigation != nil },
                set: { shown in if !shown { loader.resolvePendingNavigation(.cancel) } }
            ),
            presenting: loader.pendingNavigation
        ) { _ in
            Button("Apply") { loader.resolvePendingNavigation(.apply) }
            Button("Discard", role: .destructive) { loader.resolvePendingNavigation(.discard) }
            Button("Cancel", role: .cancel) { loader.resolvePendingNavigation(.cancel) }
        } message: { pending in
            Text("\(pending.title) would replace the rows on screen. Apply \(pendingCountText) first, or discard them?")
        }
        .sheet(isPresented: $showPreviewSQL) {
            PendingChangesPreviewSheet(
                script: loader.previewSQL(),
                summary: pendingBreakdown,
                onApply: { Task { await loader.apply() } },
                onClose: { showPreviewSQL = false }
            )
        }
    }

    /// Invisible buttons owning the tab's keyboard shortcuts.
    private var shortcutButtons: some View {
        ZStack {
            Button("") {
                guard viewState.pane == .data else { return }
                viewState.showFindBar.toggle()
                if viewState.showFindBar { findFocused = true }
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button("") { Task { await loader.apply() } }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!loader.hasPendingChanges || loader.isApplying)
            Button("") { confirmDiscard() }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(!loader.hasPendingChanges || loader.isApplying)
        }
        .hidden()
    }

    func consumeRequestedPane() {
        guard let want = tab.requestedPane else { return }
        viewState.pane = want
        tab.requestedPane = nil
        loadInspectorIfNeeded()
    }

    func loadInspectorIfNeeded() {
        if (viewState.pane == .structure || viewState.pane == .ddl), inspector.state == .idle {
            Task { await inspector.load() }
        }
    }

    /// FK navigation parks a WHERE clause on the tab and pulses this flag.
    /// A never-loaded tab picks the clause up in its first load instead.
    func consumeFilterReload() {
        guard tab.requestedFilterReload else { return }
        tab.requestedFilterReload = false
        guard !isIdle else { return }
        Task {
            await loader.setFilter(RowsFetcher.Filter(
                whereClause: tab.tableWhereClause,
                orderByClause: tab.tableOrderByClause
            ))
        }
    }

    var isIdle: Bool {
        if case .idle = loader.state { return true }
        return false
    }

    func firstLoad() async {
        guard isIdle else { return }
        tab.requestedFilterReload = false
        loader.seedFilter(RowsFetcher.Filter(
            whereClause: tab.tableWhereClause,
            orderByClause: tab.tableOrderByClause
        ))
        await loader.load()
        _ = await loader.foreignKeyCatalog()
    }

    // MARK: - Header

    private var paneStrip: some View {
        HStack(spacing: 0) {
            Picker("", selection: Binding(get: { viewState.pane }, set: { viewState.pane = $0 })) {
                Text("Data").tag(WorkspaceState.TablePane.data)
                Text("Structure").tag(WorkspaceState.TablePane.structure)
                Text("DDL").tag(WorkspaceState.TablePane.ddl)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .padding(.leading, Tokens.Spacing.md)
            .padding(.vertical, 4)
            Spacer()
            if table.kind == .table {
                Button {
                    NotificationCenter.default.post(
                        name: .pgbrainEditTableStructure,
                        object: service.connection.id,
                        userInfo: ["schema": table.schema, "table": table.name]
                    )
                } label: {
                    Label("Edit structure…", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.trailing, Tokens.Spacing.md)
                .help("Open the table designer — add, rename, retype, or drop columns")
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
            Text(table.qualifiedName)
                .font(.system(.body, design: .monospaced).weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(resolvedColumns.count) columns")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !loader.isEditable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help("Views and materialized views aren't editable.")
            }
            Spacer()
            editControls
            loadStatus
            if loader.isEditable, case .loaded = loader.state {
                Button {
                    loader.addInsertRow()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(loader.isApplying)
                .help("Add a new row (fill cells, then Apply)")
            }
            Button {
                Task { await loader.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload (⌘R)")
            ioMenu
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var loadStatus: some View {
        switch loader.state {
        case .loaded(let page):
            HStack(spacing: 6) {
                Text(page.truncated ? "\(page.rows.count)+ rows" : "\(page.rows.count) rows")
                if let size = loader.tableSizePretty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(size)
                        .contentTransition(.numericText())
                        .help("Total on-disk size (table + indexes + TOAST)")
                }
                Text(String(format: "%.0f ms", page.elapsed * 1000))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .animation(.easeInOut(duration: 0.25), value: loader.tableSizePretty)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("loading…").font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private var ioMenu: some View {
        Menu {
            Section("Export full table (streaming)") {
                ForEach(Exporter.Format.allCases) { fmt in
                    Button(fmt.uiLabel) { exportFullTable(as: fmt) }
                }
            }
            if case .loaded(let page) = loader.state, !page.rows.isEmpty {
                Divider()
                Section("Export visible page") {
                    ForEach(Exporter.Format.allCases) { fmt in
                        Button(fmt.uiLabel) { exportPage(page, as: fmt) }
                    }
                }
                Divider()
                Menu("Copy visible page to clipboard") {
                    ForEach(ClipboardCopy.Format.allCases) { fmt in
                        Button(fmt.menuLabel) {
                            let n = ClipboardCopy.copy(page, as: fmt)
                            service.toasts.show(.success, "Copied \(rowsLabel(n)) as \(fmt.menuLabel)")
                        }
                    }
                }
            }
            Divider()
            Button("Import CSV into this table…", action: importCSV)
            Button("Import JSON into this table…", action: importJSON)
        } label: {
            Image(systemName: "tray.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Import / Export")
    }

    // MARK: - Pending changes

    var pendingCount: Int {
        let s = loader.pendingSummary
        return s.cells + s.inserts + s.deletes
    }

    var pendingCountText: String {
        pendingCount == 1 ? "the pending change" : "the \(pendingCount) pending changes"
    }

    var pendingBreakdown: String {
        let s = loader.pendingSummary
        var parts: [String] = []
        if s.cells > 0 { parts.append("\(s.cells) edited cell\(s.cells == 1 ? "" : "s")") }
        if s.inserts > 0 { parts.append("\(s.inserts) new row\(s.inserts == 1 ? "" : "s")") }
        if s.deletes > 0 { parts.append("\(s.deletes) row\(s.deletes == 1 ? "" : "s") to delete") }
        return parts.joined(separator: " · ")
    }

    func confirmDiscard() {
        guard loader.hasPendingChanges, !loader.isApplying else { return }
        let alert = NSAlert()
        alert.messageText = "Discard \(pendingCount) pending change\(pendingCount == 1 ? "" : "s")?"
        alert.informativeText = pendingBreakdown
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            loader.revert()
        }
    }

    @ViewBuilder
    private var editControls: some View {
        if let applyError = loader.applyError {
            Button {
                showApplyErrorPopover = true
            } label: {
                Label {
                    Text("Apply failed").font(.caption.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Click to see the full error message")
            .popover(isPresented: $showApplyErrorPopover, arrowEdge: .bottom) {
                ApplyErrorPopover(message: applyError)
            }
        }
        if let applySuccess = loader.applySuccess {
            Label(applySuccess, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .transition(.opacity)
        }
        if loader.hasPendingChanges {
            Button {
                showPreviewSQL = true
            } label: {
                Text("\(pendingCount) pending")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("\(pendingBreakdown) — click to preview the SQL")
            Button("Preview SQL") { showPreviewSQL = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Discard") { confirmDiscard() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(loader.isApplying)
                .help("Throw away every staged change (⌘⎋)")
            Button {
                Task { await loader.apply() }
            } label: {
                if loader.isApplying {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Applying…")
                    }
                } else {
                    Text("Apply")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Tokens.Brand.primary)
            .disabled(loader.isApplying)
            .help("Commit all staged changes in one transaction (⌘S)")
        }
    }

    private var noPrimaryKeyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("No primary key — rows are identified by their physical location (ctid). A concurrent UPDATE or VACUUM FULL moves rows; an edit then fails instead of saving, and in rare cases may land on a different row. Add a primary key for safe editing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        switch viewState.pane {
        case .data:
            dataPane
        case .structure:
            StructurePane(
                state: inspector.state,
                onRetry: { Task { await inspector.load() } },
                service: service,
                onReload: { Task { await inspector.load() } }
            )
        case .ddl:
            DDLPane(state: inspector.state) { Task { await inspector.load() } }
        }
    }
}

/// Lifecycle + cross-view signal wiring, split out so the main body stays
/// type-checkable.
private struct TableTabLifecycle: ViewModifier {
    let view: TableTabView

    func body(content: Content) -> some View {
        let loader = view.loader
        let tab = view.tab
        let service = view.service
        content
            .task(id: view.table.id) { await view.firstLoad() }
            .onAppear {
                if loader.tab !== tab { loader.tab = tab }
                view.consumeRequestedPane()
                view.consumeFilterReload()
            }
            .onChange(of: loader.filter) { _, new in
                tab.tableWhereClause = new.whereClause
                tab.tableOrderByClause = new.orderByClause
                SessionStateStore.shared.scheduleSnapshot()
            }
            .onChange(of: tab.requestedPane) { _, _ in view.consumeRequestedPane() }
            .onChange(of: tab.requestedFilterReload) { _, _ in view.consumeFilterReload() }
            .onChange(of: view.viewState.pane) { _, _ in view.loadInspectorIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: .pgbrainSetTableViewMode)) { notif in
                guard service.owns(notif),
                      service.workspace.selectedID == tab.id,
                      let mode = notif.userInfo?["mode"] as? String else { return }
                switch mode {
                case "form":
                    view.viewState.pane = .data; view.viewState.rowViewMode = .form
                case "map":
                    guard !view.spatialColumns.isEmpty else { return }
                    view.viewState.pane = .data; view.viewState.rowViewMode = .map
                default:
                    view.viewState.pane = .data; view.viewState.rowViewMode = .grid
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pgbrainExportTable)) { notif in
                guard service.owns(notif),
                      service.workspace.selectedID == tab.id,
                      let raw = notif.userInfo?["format"] as? String,
                      let format = Exporter.Format(rawValue: raw) else { return }
                view.exportFullTable(as: format)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pgbrainImportTable)) { notif in
                guard service.owns(notif),
                      service.workspace.selectedID == tab.id,
                      let kind = notif.userInfo?["kind"] as? String else { return }
                if kind == "json" { view.importJSON() } else { view.importCSV() }
            }
    }
}
