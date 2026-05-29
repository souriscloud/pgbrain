import AppKit
import SwiftUI
import Observation
import PostgresNIO

/// Container view for a single table tab. Owns the row loader, the per-grid
/// edit buffer, and switches between loading / error / loaded grid states.
/// A segmented picker switches between Data (the row grid), Structure
/// (columns + constraints + indexes), and DDL (`CREATE TABLE …`).
/// Identifiable wrapper used to drive the distinct-values popover off
/// `.popover(item:)`. A plain String can't be Identifiable directly.
struct ColumnNameID: Identifiable, Hashable {
    let id: String
}

/// Drives the "Change type" sheet in the Structure pane.
struct AlterTypeRequest: Identifiable {
    let id = UUID()
    let column: String
    let currentType: String
}

struct TableTabView: View {
    let table: TableNode
    let tab: WorkspaceState.Tab
    let service: ConnectionService

    @State private var loader: RowsLoader
    @State private var inspector: InspectorLoader
    @State private var showApplyErrorPopover = false
    @State private var pane: WorkspaceState.TablePane = .data
    @State private var showFindBar = false
    @State private var distinctValuesColumn: ColumnNameID?
    @State private var profileColumn: ColumnNameID?
    @State private var pendingDelete: PendingRowDelete?
    @State private var rowViewMode: RowViewMode = .grid
    @State private var formRowIndex = 0

    enum RowViewMode { case grid, form }
    @FocusState private var findFocused: Bool

    init(table: TableNode, tab: WorkspaceState.Tab, service: ConnectionService) {
        self.table = table
        self.tab = tab
        self.service = service
        // Pull the cached loader/inspector for this tab so switching
        // away from a table and back doesn't re-fetch. The cache lives
        // on `ConnectionService` and is keyed by `tab.id`, pruned
        // automatically when the tab closes.
        _loader = State(initialValue: service.loader(for: tab, table: table))
        _inspector = State(initialValue: service.inspector(for: tab, table: table))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            paneStrip
            Divider()
            content
        }
        .background(
            // Invisible button that owns the ⌘F shortcut. Toggling
            // showFindBar focuses the text field via the .onChange below
            // so the cursor is ready for typing.
            Button {
                if pane == .data {
                    showFindBar.toggle()
                    if showFindBar { findFocused = true }
                }
            } label: { EmptyView() }
            .keyboardShortcut("f", modifiers: [.command])
            .hidden()
        )
        .task(id: table.id) {
            // Cached-loader semantics: only fetch on the FIRST time
            // we ever land on this tab (loader.state == .idle). Tab
            // switches re-create the view but the loader keeps its
            // page, so we skip the round-trip. Refresh button + ⌘R
            // are the explicit reload paths.
            guard case .idle = loader.state else { return }
            if loader.filter.whereClause.isEmpty, !tab.tableWhereClause.isEmpty {
                loader.filter.whereClause = tab.tableWhereClause
            }
            if loader.filter.orderByClause.isEmpty, !tab.tableOrderByClause.isEmpty {
                loader.filter.orderByClause = tab.tableOrderByClause
            }
            await loader.load()
        }
        .onAppear { consumeRequestedPane() }
        // Mirror loader changes back onto the Tab so the on-disk
        // snapshot picks up edits made via the strip or via a header
        // click. SessionStateStore debounces.
        .onChange(of: loader.filter.whereClause) { _, new in
            tab.tableWhereClause = new
            SessionStateStore.shared.scheduleSnapshot()
        }
        .onChange(of: loader.filter.orderByClause) { _, new in
            tab.tableOrderByClause = new
            SessionStateStore.shared.scheduleSnapshot()
        }
        .onChange(of: tab.requestedPane) { _, _ in consumeRequestedPane() }
        // FK navigation can land on a tab that's already mounted;
        // `.task(id:)` only fires on creation, so this pulse drives
        // the re-load when the new WHERE clause arrives.
        .onChange(of: tab.requestedFilterReload) { _, want in
            guard want else { return }
            loader.filter.whereClause = tab.tableWhereClause
            loader.filter.orderByClause = tab.tableOrderByClause
            loader.pageOffset = 0
            tab.requestedFilterReload = false
            Task { await loader.load() }
        }
        .onChange(of: pane) { _, new in
            // Same cache-first contract — inspector only fetches on
            // the first switch to Structure / DDL; cached afterwards.
            if (new == .structure || new == .ddl), inspector.state == .idle {
                Task { await inspector.load() }
            }
        }
        // Project the edit buffer's dirty state onto the Tab so the tab
        // strip can render a pending-edits dot without reaching into
        // per-tab content.
        .onChange(of: loader.editBuffer.isDirty) { _, isDirty in
            tab.hasPendingChanges = isDirty
        }
        .onDisappear {
            // Reading isDirty inside onDisappear isn't safe (loader may
            // already be torn down); clear unconditionally — the next
            // appearance will re-derive from the live buffer.
            tab.hasPendingChanges = false
        }
    }

    private func consumeRequestedPane() {
        guard let want = tab.requestedPane else { return }
        pane = want
        tab.requestedPane = nil
        if (want == .structure || want == .ddl) && inspector.state == .idle {
            Task { await inspector.load() }
        }
    }

    private var paneStrip: some View {
        HStack(spacing: 0) {
            Picker("", selection: $pane) {
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
            Text("\(table.columns.count) columns")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !table.isEditable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help(table.kind == .table
                        ? "No primary key; editing disabled."
                        : "Views aren't editable.")
            }
            Spacer()
            editControls
            Group {
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
            if table.isEditable, case .loaded = loader.state {
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
            .help("Reload")
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
                }
                if case .loaded(let page) = loader.state, !page.rows.isEmpty {
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
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func exportFullTable(as format: Exporter.Format) {
        guard let client = service.client else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(table.schema).\(table.name).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(
            kind: .export,
            summary: "Export \(table.qualifiedName) → \(url.lastPathComponent)"
        )
        let tracker = service.operations
        let opID = op.id
        Task {
            do {
                let stats = try await Exporter.exportTable(
                    table,
                    format: format,
                    destination: url,
                    client: client,
                    tracker: tracker,
                    operationID: opID
                )
                op.summary += " · \(rowsLabel(stats.rowsWritten))"
                tracker.finish(op, status: .succeeded)
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }

    private func exportPage(_ page: RowsFetcher.Page, as format: Exporter.Format) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(table.schema).\(table.name)_page.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(kind: .export, summary: "Export result → \(url.lastPathComponent)")
        do {
            let stats = try Exporter.exportPage(page, format: format, destination: url, tableNameHint: table.name)
            op.summary += " · \(rowsLabel(stats.rowsWritten))"
            service.operations.finish(op, status: .succeeded)
        } catch {
            service.operations.finish(op, status: .failed(error.localizedDescription))
        }
    }

    /// "1 row" / "1,234 rows" with grouping separators.
    private func rowsLabel(_ n: Int) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(formatted) row\(n == 1 ? "" : "s")"
    }

    private func importCSV() {
        guard let client = service.client else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(
            kind: .importJob,
            summary: "Import \(url.lastPathComponent) → \(table.qualifiedName)"
        )
        let tracker = service.operations
        let opID = op.id
        Task {
            do {
                let stats = try await Importer.importCSV(
                    into: table,
                    from: url,
                    client: client,
                    tracker: tracker,
                    operationID: opID
                )
                op.summary += " · \(rowsLabel(stats.rowsImported))"
                tracker.finish(op, status: .succeeded)
                await loader.load()
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }

    private func importJSON() {
        guard let client = service.client else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(
            kind: .importJob,
            summary: "Import \(url.lastPathComponent) → \(table.qualifiedName)"
        )
        let tracker = service.operations
        let opID = op.id
        Task {
            do {
                let stats = try await Importer.importJSON(
                    into: table,
                    from: url,
                    client: client,
                    tracker: tracker,
                    operationID: opID
                )
                op.summary += " · \(rowsLabel(stats.rowsImported))"
                tracker.finish(op, status: .succeeded)
                await loader.load()
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }

    /// "3 pending" / "2 new rows" / "3 pending · 2 new rows".
    private var pendingLabel: String {
        var parts: [String] = []
        let dirty = loader.editBuffer.dirtyCount - loader.pendingInsertRows.reduce(0) { acc, idx in
            acc + (loader.editBuffer.editsByRow().first { $0.row == idx }?.cells.count ?? 0)
        }
        if dirty > 0 { parts.append("\(dirty) pending") }
        let inserts = loader.pendingInsertRows.count
        if inserts > 0 { parts.append("\(inserts) new row\(inserts == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(loader.editBuffer.dirtyCount) pending" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var editControls: some View {
        if let applyError = loader.applyError {
            Button {
                showApplyErrorPopover = true
            } label: {
                Label {
                    Text("Apply failed")
                        .font(.caption.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
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
            Text(pendingLabel)
                .font(.caption)
                .foregroundStyle(.orange)
            Button {
                loader.revert()
            } label: {
                Text("Revert")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(loader.isApplying)

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
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .data:       dataPane
        case .structure:
            StructurePane(
                state: inspector.state,
                onRetry: { Task { await inspector.load() } },
                service: service,
                onReload: { Task { await inspector.load() } }
            )
        case .ddl:        DDLPane(state: inspector.state) { Task { await inspector.load() } }
        }
    }

    /// Bottom pager — page-size dropdown, "showing X-Y" range, ←/→
    /// arrows. Disabled state honours `loader.pageOffset` and
    /// `page.truncated` so arrows are only live when there's
    /// somewhere to go.
    @ViewBuilder
    private func pagerStrip(visible: RowsFetcher.Page) -> some View {
        let start = visible.offset + 1
        let end = visible.offset + visible.rows.count
        let canPrev = loader.pageOffset > 0
        let canNext = visible.truncated
        HStack(spacing: 12) {
            Menu {
                ForEach([50, 100, 200, 500, 1000, 5000], id: \.self) { size in
                    Button {
                        Task { await loader.setPageSize(size) }
                    } label: {
                        Label("\(size) per page",
                              systemImage: loader.pageSize == size ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(loader.pageSize)/page")
                        .font(.system(.caption, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text(rangeText(start: start, end: end, canNext: canNext, rowCount: visible.rows.count))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            // "Count exact" affordance — only meaningful when more
            // rows clearly exist (truncated, or an estimate beats the
            // current page). Spinner while in flight.
            if loader.isCountingExact {
                ProgressView().controlSize(.small)
            } else if loader.exactTotal == nil && (canNext || loader.estimatedTotal != nil) {
                Button {
                    Task { await loader.countExact() }
                } label: {
                    Text("count exact")
                        .font(.system(.caption2, design: .monospaced))
                }
                .buttonStyle(.borderless)
                .help("Run SELECT COUNT(*) — may be slow on big tables")
            }

            Spacer()

            // Grid / Form view toggle.
            Picker("", selection: $rowViewMode) {
                Image(systemName: "tablecells").tag(RowViewMode.grid)
                Image(systemName: "list.bullet.rectangle.portrait").tag(RowViewMode.form)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between grid and single-row form")

            Button {
                Task { await loader.loadFirstPage() }
            } label: { Image(systemName: "chevron.left.2") }
                .buttonStyle(.borderless)
                .disabled(!canPrev)
                .help("First page")
            Button {
                Task { await loader.loadPreviousPage() }
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!canPrev)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .help("Previous page (⌘⇧←)")
            Button {
                Task { await loader.loadNextPage() }
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(!canNext)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .help("Next page (⌘⇧→)")

            if loader.isRefreshing {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 5)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }

    /// Pager range text. Prefers exact when the user has clicked
    /// "count exact"; falls back to the planner estimate; falls back
    /// to the bare "X-Y[+]" when neither is available.
    private func rangeText(start: Int, end: Int, canNext: Bool, rowCount: Int) -> String {
        if rowCount == 0 { return "0 rows" }
        if let exact = loader.exactTotal {
            return "Rows \(start)–\(end) of \(Self.formatCount(exact))"
        }
        if let estimate = loader.estimatedTotal, estimate > Int64(end) {
            return "Rows \(start)–\(end) of ~\(Self.formatCount(estimate))"
        }
        return "Rows \(start)–\(end)\(canNext ? "+" : "")"
    }

    /// `1,234,567` → `1.23M`, `1_234` → `1.23k`, smaller → as-is.
    /// Compact-thousands keeps the pager strip narrow on huge tables.
    private static func formatCount(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000:        return "\(n)"
        case ..<1_000_000:    return String(format: "%.1fk", v / 1_000)
        case ..<1_000_000_000:return String(format: "%.2fM", v / 1_000_000)
        default:              return String(format: "%.2fB", v / 1_000_000_000)
        }
    }

    private var emptyMessage: String {
        if !loader.globalFilter.isEmpty {
            return "No rows match the find filter."
        }
        if !loader.filter.whereClause.isEmpty || !loader.filter.orderByClause.isEmpty {
            return "No rows match the WHERE clause."
        }
        return "No rows in \(table.qualifiedName)"
    }

    private enum RowSQLKind { case insert, delete, duplicate }
    private enum SelectionFormat { case markdown, slack }

    /// ⌘-click handler: if the clicked cell is on an FK column,
    /// open the parent table with `WHERE pk = value` pre-applied.
    /// Non-FK columns silently ignore the click — we don't want to
    /// repurpose ⌘-click into something noisy.
    private func navigateForeignKey(row sourceRow: Int, col dataCol: Int) {
        guard case .loaded(let page) = loader.state,
              sourceRow >= 0, sourceRow < page.rows.count,
              dataCol < page.columns.count
        else { return }
        let localColumn = page.columns[dataCol].name
        guard let fk = table.foreignKeys.first(where: { $0.localColumn == localColumn }) else {
            return
        }
        guard let refTable = service.schema.schemas
                .first(where: { $0.name == fk.refSchema })?
                .tables.first(where: { $0.name == fk.refTable })
        else { return }
        // Compose `"col" = value` honouring the parent column's type.
        let raw = page.rows[sourceRow][dataCol]
        let refColumn = refTable.columns.first(where: { $0.name == fk.refColumn })
        let typeName = refColumn?.typeName ?? "text"
        let clause: String = raw == nil
            ? "\(SQLIdent.quote(fk.refColumn)) IS NULL"
            : "\(SQLIdent.quote(fk.refColumn)) = \(sqlLiteral(raw, typeName: typeName))"

        let existing = service.workspace.tabs.first(where: {
            if case .table(let t) = $0.kind { return t.id == refTable.id }
            return false
        })
        service.workspace.openTable(refTable)
        // openTable focuses the existing tab when one exists. Set the
        // WHERE clause on that tab + pulse the reload signal so the
        // already-mounted TableTabView re-fetches with the new filter.
        let opened = existing ?? service.workspace.tabs.first(where: {
            if case .table(let t) = $0.kind { return t.id == refTable.id }
            return false
        })
        opened?.tableWhereClause = clause
        opened?.requestedFilterReload = true
    }

    /// "Filter to this cell's value": AND a `col = lit` (or
    /// `col IS NULL`) fragment onto the existing WHERE clause.
    /// Idempotent — running it twice on the same cell produces a
    /// duplicate AND but PG short-circuits it.
    private func filterToCell(row sourceRow: Int, col dataCol: Int) {
        guard case .loaded(let page) = loader.state,
              sourceRow >= 0, sourceRow < page.rows.count,
              dataCol < page.columns.count
        else { return }
        let column = page.columns[dataCol]
        let raw = page.rows[sourceRow][dataCol]
        let fragment: String = {
            if raw == nil { return "\(SQLIdent.quote(column.name)) IS NULL" }
            let lit = sqlLiteral(raw, typeName: column.typeName)
            return "\(SQLIdent.quote(column.name)) = \(lit)"
        }()
        appendToWhere(fragment)
    }

    private func filterColumn(col dataCol: Int, mode: ColumnFilterMode) {
        guard case .loaded(let page) = loader.state, dataCol < page.columns.count else { return }
        let name = SQLIdent.quote(page.columns[dataCol].name)
        let fragment = mode == .isNull ? "\(name) IS NULL" : "\(name) IS NOT NULL"
        appendToWhere(fragment)
    }

    private func appendToWhere(_ fragment: String) {
        let current = loader.filter.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        loader.filter.whereClause = current.isEmpty ? fragment : "(\(current)) AND (\(fragment))"
        loader.pageOffset = 0
        Task { await loader.load() }
    }

    /// Picking a row in the Distinct Values popover folds it into the
    /// active WHERE clause. We need the column's PG type to produce
    /// the right literal so we look it up on the loaded page.
    private func applyDistinctFilter(column: String, value: String?) {
        guard case .loaded(let page) = loader.state,
              let col = page.columns.first(where: { $0.name == column })
        else { return }
        let fragment: String = {
            if value == nil { return "\(SQLIdent.quote(column)) IS NULL" }
            let lit = sqlLiteral(value, typeName: col.typeName)
            return "\(SQLIdent.quote(column)) = \(lit)"
        }()
        appendToWhere(fragment)
    }

    /// Serialise the current row selection (or all visible rows if
    /// nothing's selected) as either GitHub-flavoured Markdown table
    /// or a Slack-style ``` block with tab-separated columns.
    private func copySelection(as format: SelectionFormat) {
        guard let (visible, _) = loader.filteredPage() else { return }
        // No selection state up here — use the whole visible page.
        // A future tweak could let the grid pass selected rows.
        let columns = visible.columns.map(\.name)
        let rows = visible.rows.map { row in
            row.map { $0?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|") ?? "" }
        }
        let payload: String
        switch format {
        case .markdown:
            var lines: [String] = []
            lines.append("| " + columns.joined(separator: " | ") + " |")
            lines.append("| " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
            for row in rows {
                lines.append("| " + row.joined(separator: " | ") + " |")
            }
            payload = lines.joined(separator: "\n")
        case .slack:
            // Right-pad each cell to the column's widest value so the
            // monospaced Slack code block aligns visually.
            var widths = columns.map { $0.count }
            for row in rows {
                for (i, cell) in row.enumerated() where i < widths.count {
                    widths[i] = max(widths[i], cell.count)
                }
            }
            func line(_ cells: [String]) -> String {
                cells.enumerated().map { i, c in
                    c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                }.joined(separator: "  ")
            }
            var lines: [String] = ["```"]
            lines.append(line(columns))
            lines.append(line(widths.map { String(repeating: "-", count: $0) }))
            for row in rows { lines.append(line(row)) }
            lines.append("```")
            payload = lines.joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    /// Build SQL for a single source row and put it on the clipboard.
    /// The source row index is into `loader.state`'s underlying page,
    /// independent of any active filter.
    /// A delete the user has asked for but not yet confirmed.
    private struct PendingRowDelete: Identifiable {
        let id = UUID()
        let count: Int
        let sql: String
    }

    /// Build the combined DELETE for the chosen source rows and stage a
    /// confirmation. Requires a primary key — without one we can't target
    /// the exact rows, so we refuse rather than risk a broad match.
    private func requestDelete(sourceRows: [Int]) {
        guard case .loaded(let page) = loader.state else { return }
        guard !table.primaryKey.isEmpty else {
            service.toasts.show(.error, "Can't delete — \(table.qualifiedName) has no primary key.")
            return
        }
        guard let sql = buildDeleteSQL(sourceRows: sourceRows, page: page) else {
            service.toasts.show(.error, "Couldn't build a delete for the selected rows.")
            return
        }
        pendingDelete = PendingRowDelete(count: sourceRows.count, sql: sql)
    }

    /// `DELETE FROM t WHERE (pk… ) OR (pk…) …` — one OR-group per row,
    /// keyed on the table's primary key. Returns nil if any selected row
    /// is missing a PK value (shouldn't happen for a real PK, but we bail
    /// safely rather than emit a partial predicate).
    private func buildDeleteSQL(sourceRows: [Int], page: RowsFetcher.Page) -> String? {
        let qualified = SQLIdent.qualified(schema: table.schema, name: table.name)
        let cols = page.columns
        var clauses: [String] = []
        for r in sourceRows {
            guard r >= 0, r < page.rows.count else { continue }
            let row = page.rows[r]
            let parts = table.primaryKey.compactMap { name -> String? in
                guard let idx = cols.firstIndex(where: { $0.name == name }) else { return nil }
                if row[idx] == nil { return "\(SQLIdent.quote(name)) IS NULL" }
                return "\(SQLIdent.quote(name)) = \(sqlLiteral(row[idx], typeName: cols[idx].typeName))"
            }
            guard parts.count == table.primaryKey.count else { return nil }
            clauses.append("(" + parts.joined(separator: " AND ") + ")")
        }
        guard !clauses.isEmpty else { return nil }
        return "DELETE FROM \(qualified) WHERE \(clauses.joined(separator: " OR "))"
    }

    private func runDelete(_ req: PendingRowDelete) {
        let summary = "DELETE \(table.qualifiedName) (\(req.count) row\(req.count == 1 ? "" : "s"))"
        Task {
            let result = await AdminActions.execute(req.sql, summary: summary, service: service)
            if case .success = result {
                await loader.load()
            }
        }
    }

    private func copySQL(_ kind: RowSQLKind, for sourceRow: Int) {
        guard case .loaded(let page) = loader.state,
              sourceRow >= 0, sourceRow < page.rows.count
        else { return }
        let row = page.rows[sourceRow]
        let qualified = SQLIdent.qualified(schema: table.schema, name: table.name)
        let columns = page.columns
        let sql: String
        switch kind {
        case .insert, .duplicate:
            // For duplicate, omit primary-key columns when there's a
            // single-column PK (typical identity/serial) so the row can
            // be re-inserted without conflict; multi-column PKs are kept
            // because the user will need to adjust them anyway.
            let pkSet: Set<String> = (kind == .duplicate && table.primaryKey.count == 1)
                ? Set(table.primaryKey)
                : []
            let usable = columns.enumerated().filter { !pkSet.contains($0.element.name) }
            let colList = usable.map { SQLIdent.quote($0.element.name) }.joined(separator: ", ")
            let valList = usable.map { sqlLiteral(row[$0.offset], typeName: $0.element.typeName) }.joined(separator: ", ")
            sql = "INSERT INTO \(qualified) (\(colList)) VALUES (\(valList));"
        case .delete:
            let pkCols = table.primaryKey.isEmpty ? columns.map(\.name) : table.primaryKey
            let wherePieces = pkCols.compactMap { name -> String? in
                guard let idx = columns.firstIndex(where: { $0.name == name }) else { return nil }
                let lit = sqlLiteral(row[idx], typeName: columns[idx].typeName)
                if row[idx] == nil {
                    return "\(SQLIdent.quote(name)) IS NULL"
                }
                return "\(SQLIdent.quote(name)) = \(lit)"
            }
            sql = "DELETE FROM \(qualified) WHERE \(wherePieces.joined(separator: " AND "));"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }

    /// Format a single cell value as a Postgres literal. Wires
    /// quoting + casts for the common types — text quoting, raw numerics
    /// and bools, ISO-format dates/timestamps, JSON.
    private func sqlLiteral(_ value: String?, typeName: String) -> String {
        guard let v = value else { return "NULL" }
        let kind = ColumnTypeKind.from(typeName: typeName)
        switch kind {
        case .integer, .number, .bool:
            return v
        case .uuid:
            return "'\(v.replacingOccurrences(of: "'", with: "''"))'::uuid"
        case .json:
            return "'\(v.replacingOccurrences(of: "'", with: "''"))'::\(typeName)"
        case .date, .timestamp:
            return "'\(v.replacingOccurrences(of: "'", with: "''"))'::\(typeName)"
        default:
            return "'\(v.replacingOccurrences(of: "'", with: "''"))'"
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in grid…", text: Binding(
                get: { loader.globalFilter },
                set: { loader.globalFilter = $0 }
            ))
            .textFieldStyle(.plain)
            .focused($findFocused)
            .onExitCommand {
                loader.globalFilter = ""
                showFindBar = false
            }
            Spacer(minLength: 0)
            if let count = filteredRowCount {
                Text("\(count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button {
                loader.globalFilter = ""
                showFindBar = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close find bar")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.08))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
    }

    private var filteredRowCount: Int? {
        guard let (page, _) = loader.filteredPage() else { return nil }
        return page.rows.count
    }

    @ViewBuilder
    private var dataPane: some View {
        switch loader.state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading rows…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let (visible, sourceIndices) = loader.filteredPage() {
                VStack(spacing: 0) {
                    QueryStripView(
                        filter: $loader.filter,
                        table: table,
                        schema: service.visibleSchema,
                        isRefreshing: loader.isRefreshing,
                        onSubmit: {
                            // New filter → reset pagination so the user
                            // starts reading from row 1 of the new
                            // result set, not offset-N of the old one.
                            loader.pageOffset = 0
                            Task { await loader.load() }
                        }
                    )
                    if let err = loader.refreshError {
                        errorBanner(message: err, isCold: false)
                    }
                    if showFindBar { findBar }
                    if visible.rows.isEmpty {
                        VStack(spacing: Tokens.Spacing.sm) {
                            Image(systemName: "tray")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(emptyMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if rowViewMode == .form {
                        RowFormView(
                            page: visible,
                            sourceIndices: sourceIndices,
                            rowIndex: $formRowIndex,
                            editBuffer: table.isEditable ? loader.editBuffer : nil
                        )
                        pagerStrip(visible: visible)
                    } else {
                        DataGridView(
                            page: visible,
                            editBuffer: table.isEditable ? loader.editBuffer : nil,
                            appliedHighlights: loader.appliedHighlights,
                            insertRowIndices: loader.pendingInsertRows,
                            sourceRowIndices: sourceIndices,
                            sortDirectionFor: { col in
                                switch loader.headerSortDirection(for: col) {
                                case .none:       return .none
                                case .ascending:  return .ascending
                                case .descending: return .descending
                                }
                            },
                            onHeaderClick: { col, next in
                                Task {
                                    let mapped: RowsLoader.HeaderSortDirection
                                    switch next {
                                    case .none:       mapped = .none
                                    case .ascending:  mapped = .ascending
                                    case .descending: mapped = .descending
                                    }
                                    await loader.applyHeaderSort(column: col, direction: mapped)
                                }
                            },
                            onCopyRowAsInsert: { row in copySQL(.insert, for: row) },
                            onCopyRowAsDelete: { row in copySQL(.delete, for: row) },
                            onDuplicateRow: { row in copySQL(.duplicate, for: row) },
                            onFilterEqualsCell: { row, col in
                                filterToCell(row: row, col: col)
                            },
                            onFilterColumn: { col, mode in
                                filterColumn(col: col, mode: mode)
                            },
                            onCopyAsMarkdown: { copySelection(as: .markdown) },
                            onCopyAsSlack:    { copySelection(as: .slack) },
                            onCommandClickCell: { row, col in
                                navigateForeignKey(row: row, col: col)
                            },
                            onShowColumnDistinct: { col in
                                distinctValuesColumn = ColumnNameID(id: col)
                            },
                            onProfileColumn: { col in
                                profileColumn = ColumnNameID(id: col)
                            },
                            onDeleteRows: { sourceRows in
                                requestDelete(sourceRows: sourceRows)
                            },
                            columnLayoutKey: (service.connection.id, table.schema, table.name)
                        )
                        .popover(item: $distinctValuesColumn, arrowEdge: .top) { colName in
                            DistinctValuesPopover(
                                service: service,
                                schema: table.schema,
                                table: table.name,
                                column: colName.id,
                                extraWhere: loader.filter.whereClause
                            ) { value in
                                applyDistinctFilter(column: colName.id, value: value)
                                distinctValuesColumn = nil
                            }
                        }
                        .popover(item: $profileColumn, arrowEdge: .top) { colName in
                            if let node = table.columns.first(where: { $0.name == colName.id }) {
                                ColumnProfilePopover(
                                    service: service,
                                    schema: table.schema,
                                    table: table.name,
                                    column: node,
                                    extraWhere: loader.filter.whereClause
                                )
                            }
                        }
                        .confirmationDialog(
                            pendingDelete.map { "Delete \($0.count) row\($0.count == 1 ? "" : "s")?" } ?? "",
                            isPresented: Binding(
                                get: { pendingDelete != nil },
                                set: { if !$0 { pendingDelete = nil } }
                            ),
                            titleVisibility: .visible,
                            presenting: pendingDelete
                        ) { req in
                            Button("Delete", role: .destructive) {
                                runDelete(req)
                                pendingDelete = nil
                            }
                            Button("Cancel", role: .cancel) { pendingDelete = nil }
                        } message: { req in
                            Text("Permanently deletes \(req.count) row\(req.count == 1 ? "" : "s") from \(table.qualifiedName) by primary key. This can't be undone.")
                        }
                        pagerStrip(visible: visible)
                    }
                }
            }
        case .error(let message):
            // Cold-error path (failed before we ever loaded a page) —
            // still show the WHERE / ORDER BY strip on top so the user
            // can edit and retry without re-opening the tab.
            VStack(spacing: 0) {
                QueryStripView(
                    filter: $loader.filter,
                    table: table,
                    schema: service.visibleSchema,
                    isRefreshing: loader.isRefreshing,
                    onSubmit: { Task { await loader.load() } }
                )
                errorBanner(message: message, isCold: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Inline red banner shown above the grid when a load fails. On
    /// refresh failures the previously-loaded page stays underneath; on
    /// cold failures (no prior page) it stands alone with the empty
    /// space below it.
    @ViewBuilder
    private func errorBanner(message: String, isCold: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(isCold ? "Couldn't load rows" : "Couldn't refresh — previous page kept below")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await loader.load() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !isCold {
                Button {
                    loader.refreshError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss this error (keeps your clause as-is)")
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(.separator),
            alignment: .bottom
        )
    }
}

@MainActor
@Observable
final class RowsLoader {
    enum State {
        case idle
        case loading
        case loaded(RowsFetcher.Page)
        case error(String)
    }

    /// Effective table — captured at init from the snapshot but
    /// re-assigned the first time `load()` runs so we pick up
    /// columns the background enrichment populated in the meantime.
    private(set) var table: TableNode
    @ObservationIgnored let service: ConnectionService
    private(set) var state: State = .idle

    /// Per-tab pending-edit buffer; lives as long as the loader does.
    let editBuffer = EditBuffer()
    private(set) var isApplying = false
    private(set) var applyError: String?
    /// Short-lived green message after a successful Apply.
    private(set) var applySuccess: String?
    /// Cells that were just applied — rendered with a fading green tint
    /// in the grid so the user can see exactly what landed. Cleared on a
    /// timer so the highlight doesn't loiter.
    private(set) var appliedHighlights: Set<EditBuffer.CellKey> = []

    /// Source-row indices (into the loaded page) that are draft INSERTs —
    /// blank rows appended to the bottom of the grid, awaiting Apply. Their
    /// cell values live in `editBuffer` like any other edit; this set just
    /// flags which rows become INSERTs instead of UPDATEs.
    private(set) var pendingInsertRows: Set<Int> = []

    /// Apply is meaningful when there are dirty cells OR pending new rows.
    var hasPendingChanges: Bool { editBuffer.isDirty || !pendingInsertRows.isEmpty }

    /// Append a blank draft row to the loaded page and flag it as a pending
    /// insert. Cells are filled through the normal cell editor afterwards.
    func addInsertRow() {
        guard case .loaded(var page) = state else { return }
        let newIndex = page.rows.count
        page.rows.append([String?](repeating: nil, count: page.columns.count))
        pendingInsertRows.insert(newIndex)
        state = .loaded(page)
    }

    /// JetBrains-style raw filter — user-typed `WHERE` and `ORDER BY`
    /// fragments spliced server-side. Setting either triggers a reload
    /// (the row-limit slice would otherwise lie).
    var filter: RowsFetcher.Filter = RowsFetcher.Filter(whereClause: "", orderByClause: "")
    /// ⌘F find bar — client-side substring filter across all columns on
    /// the already-loaded page. Independent from the server WHERE.
    var globalFilter: String = ""
    /// True while a *refresh* is in flight on an already-loaded grid —
    /// the previous `.loaded` page stays mounted so the user keeps
    /// seeing the old data with a small progress indicator, instead of
    /// the grid collapsing into a spinner on every Enter.
    var isRefreshing: Bool = false
    /// Server error from the *most recent* refresh. Surfaced as a red
    /// banner above the grid so the user can read it and edit the
    /// WHERE / ORDER BY clause without losing the previously-loaded
    /// page underneath. Cleared on the next successful load.
    var refreshError: String?
    /// Current page offset (0-based row index of the first row).
    var pageOffset: Int = 0
    /// Rows fetched per page. Defaults to 200 — 1000 was punishing
    /// on tables with wide JSONB / TEXT columns. User can bump it.
    var pageSize: Int = 200
    /// Planner row-count estimate when no WHERE clause is active.
    /// Surfaced as "~1.2M" in the pager so the user has a sense of
    /// scale without paying for a full COUNT(*).
    var estimatedTotal: Int64?
    /// Exact row count, populated when the user explicitly clicks
    /// "Count exact" in the pager. Takes precedence over
    /// `estimatedTotal` when both are present.
    var exactTotal: Int64?
    /// True while the exact-count query is in flight (drives the
    /// pager's button spinner).
    var isCountingExact: Bool = false
    /// On-disk size of the open table (`pg_total_relation_size`), shown in
    /// the toolbar. Refreshed on every load so it tracks inserts/deletes.
    private(set) var tableSizePretty: String?
    /// Whether the previously-loaded page reported "there's more
    /// after this" (so the Next arrow stays enabled).
    var hasMoreAfterCurrentPage: Bool {
        if case .loaded(let page) = state { return page.truncated }
        return false
    }

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
    }

    /// Subset of the loaded page that satisfies the (client-side) global
    /// find filter. Server-side WHERE happens at load time, not here.
    func filteredPage() -> (RowsFetcher.Page, [Int])? {
        guard case .loaded(let base) = state else { return nil }
        let g = globalFilter.lowercased()
        if g.isEmpty {
            return (base, Array(0..<base.rows.count))
        }
        var rows: [[String?]] = []
        var sourceIndices: [Int] = []
        rows.reserveCapacity(base.rows.count)
        sourceIndices.reserveCapacity(base.rows.count)
        for (i, row) in base.rows.enumerated() {
            var anyMatch = false
            for cell in row {
                if (cell?.lowercased() ?? "").contains(g) { anyMatch = true; break }
            }
            if !anyMatch { continue }
            rows.append(row)
            sourceIndices.append(i)
        }
        let filtered = RowsFetcher.Page(
            columns: base.columns,
            rows: rows,
            truncated: base.truncated,
            limit: base.limit,
            offset: base.offset,
            elapsed: base.elapsed
        )
        return (filtered, sourceIndices)
    }

    func load() async {
        guard let client = service.client else {
            state = .error("Not connected.")
            return
        }
        // Phase-2 schema enrichment may not have populated this
        // table's columns yet (or this connection might have
        // landed on a shallow snapshot). Ensure them before we
        // build the SELECT — RowsFetcher uses table.columns to
        // construct the projection.
        if table.columns.isEmpty {
            table = await service.ensureColumns(for: table)
        }
        let hadLoadedPage: Bool
        if case .loaded = state {
            isRefreshing = true
            hadLoadedPage = true
        } else {
            state = .loading
            hadLoadedPage = false
        }
        editBuffer.clear()
        pendingInsertRows.removeAll()
        applyError = nil
        // Clear the exact-count cache on any reload — it's tied to a
        // specific filter + page set.
        exactTotal = nil
        defer { isRefreshing = false }
        do {
            // Kick off the planner estimate in parallel with the page
            // fetch. Cheap (catalog read), only meaningful when no
            // WHERE clause is active.
            async let estimate: Int64? = filter.whereClause.trimmingCharacters(in: .whitespaces).isEmpty
                ? (try? RowsFetcher.estimatedRowCount(table: table, client: client))
                : nil
            async let size: String? = Self.fetchTableSize(table: table, client: client)
            let page = try await RowsFetcher.page(
                offset: pageOffset,
                pageSize: pageSize,
                from: table, client: client, filter: filter
            )
            state = .loaded(page)
            estimatedTotal = await estimate
            tableSizePretty = await size
            refreshError = nil
        } catch {
            let message = PostgresErrorMessage.describe(error)
            if hadLoadedPage {
                refreshError = message
            } else {
                state = .error(message)
            }
        }
    }

    /// On-disk total size of a table/matview (`pg_total_relation_size`).
    /// Plain views have no storage, so we skip them. Best-effort — any
    /// failure just leaves the toolbar size off.
    nonisolated static func fetchTableSize(table: TableNode, client: PostgresClient) async -> String? {
        guard table.kind != .view else { return nil }
        let qualified = (SQLIdent.quote(table.schema) + "." + SQLIdent.quote(table.name))
            .replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT pg_size_pretty(pg_total_relation_size('\(qualified)'::regclass))"
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await s in rows.decode(String.self) { return s }
        } catch {
            // Decorative — stay silent.
        }
        return nil
    }

    /// Run a `SELECT COUNT(*)` honouring the active filter. Wired to
    /// the pager's "count exact" button — bypasses the auto-load
    /// path because COUNT(*) can be slow on big tables.
    func countExact() async {
        guard let client = service.client, !isCountingExact else { return }
        isCountingExact = true
        defer { isCountingExact = false }
        if let count = try? await RowsFetcher.exactRowCount(
            table: table, client: client, filter: filter
        ) {
            exactTotal = count
        }
    }

    // MARK: - Pagination

    /// Advance one page. Caller should check
    /// `hasMoreAfterCurrentPage` first to avoid a wasted query.
    func loadNextPage() async {
        pageOffset += pageSize
        await load()
    }

    /// Step back one page. Clamped at offset 0.
    func loadPreviousPage() async {
        pageOffset = max(0, pageOffset - pageSize)
        await load()
    }

    /// First page — keeps the filter intact.
    func loadFirstPage() async {
        pageOffset = 0
        await load()
    }

    /// Change the page size + reset to the first page so the new
    /// rows-per-page setting kicks in immediately.
    func setPageSize(_ newSize: Int) async {
        pageSize = max(1, newSize)
        pageOffset = 0
        await load()
    }

    /// Header click — rewrite the ORDER BY clause to a single-column
    /// sort and reload. Wipes any user-typed multi-column ORDER BY,
    /// which matches JetBrains behaviour. Resets to the first page so
    /// the user doesn't end up reading offset-200 rows of the new
    /// sort that don't correspond to what they were looking at.
    func applyHeaderSort(column: String, direction: HeaderSortDirection) async {
        switch direction {
        case .none:
            filter.orderByClause = ""
        case .ascending:
            filter.orderByClause = "\(SQLIdent.quote(column)) ASC NULLS LAST"
        case .descending:
            filter.orderByClause = "\(SQLIdent.quote(column)) DESC NULLS LAST"
        }
        pageOffset = 0
        await load()
    }

    enum HeaderSortDirection { case none, ascending, descending }

    /// Parse the active `orderByClause` to figure out whether a header
    /// arrow should be shown. Only single-column `"col" ASC|DESC` is
    /// recognised — anything fancier leaves all arrows off.
    func headerSortDirection(for columnName: String) -> HeaderSortDirection {
        let raw = filter.orderByClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .none }
        // Bail on multi-column.
        if raw.contains(",") { return .none }
        let lower = raw.lowercased()
        let quoted = "\"\(columnName.lowercased())\""
        let bareStart = "\(columnName.lowercased()) "
        let bareOnly = columnName.lowercased()
        let hasMatch = lower.hasPrefix(quoted) || lower.hasPrefix(bareStart) || lower == bareOnly
        guard hasMatch else { return .none }
        if lower.contains("desc") { return .descending }
        return .ascending
    }

    func revert() {
        editBuffer.clear()
        // Drop the trailing draft rows (always appended at the end).
        if !pendingInsertRows.isEmpty, case .loaded(var page) = state {
            let n = pendingInsertRows.count
            if page.rows.count >= n { page.rows.removeLast(n) }
            pendingInsertRows.removeAll()
            state = .loaded(page)
        }
        applyError = nil
    }

    func apply() async {
        guard let client = service.client else {
            applyError = "Not connected."
            return
        }
        guard case .loaded(var page) = state else { return }
        let pending = editBuffer.editsByRow()

        // Split pending edits: rows flagged as drafts become INSERTs, the
        // rest are UPDATEs against existing rows.
        let edits: [UpdateApplier.Edit] = pending
            .filter { !pendingInsertRows.contains($0.row) }
            .map { rowEdits in
                let cells = rowEdits.cells.map {
                    UpdateApplier.CellChange(column: page.columns[$0.column], newValue: $0.value)
                }
                return UpdateApplier.Edit(rowIndex: rowEdits.row, cells: cells)
            }
        let inserts: [UpdateApplier.Insert] = pendingInsertRows.sorted().map { idx in
            let cells = (pending.first { $0.row == idx }?.cells ?? []).map {
                UpdateApplier.CellChange(column: page.columns[$0.column], newValue: $0.value)
            }
            return UpdateApplier.Insert(cells: cells)
        }
        guard !edits.isEmpty || !inserts.isEmpty else { return }

        isApplying = true
        applyError = nil
        applySuccess = nil
        defer { isApplying = false }
        let summaryParts = [
            edits.isEmpty ? nil : "\(edits.count) update\(edits.count == 1 ? "" : "s")",
            inserts.isEmpty ? nil : "\(inserts.count) insert\(inserts.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        let op = service.operations.begin(
            kind: .update,
            summary: "\(table.qualifiedName) · \(summaryParts.joined(separator: ", "))"
        )
        let started = Date()
        do {
            try await UpdateApplier.apply(
                edits: edits,
                inserts: inserts,
                table: table,
                originalRows: page.rows,
                client: client,
                operationID: op.id,
                tracker: service.operations
            )
            service.operations.finish(op, status: .succeeded)
            let elapsed = Date().timeIntervalSince(started)

            if !inserts.isEmpty {
                // New rows get server-assigned identity/defaults — refetch so
                // the grid shows their real values instead of the blank draft.
                applySuccess = "Applied \(summaryParts.joined(separator: ", ")) · \(String(format: "%.0f ms", elapsed * 1000))"
                editBuffer.clear()
                pendingInsertRows.removeAll()
                await load()
            } else {
                // Update-only: splice the applied values into the in-memory
                // page so the grid updates without a round-trip refetch.
                for edit in edits {
                    for cell in edit.cells {
                        page.rows[edit.rowIndex][page.columns.firstIndex(where: { $0.name == cell.column.name }) ?? 0] = cell.newValue
                    }
                }
                state = .loaded(page)
                applySuccess = "Applied \(edits.count) row\(edits.count == 1 ? "" : "s") · \(String(format: "%.0f ms", elapsed * 1000))"
                // Flash every applied (row, col) green in the grid before fading.
                var highlights: Set<EditBuffer.CellKey> = []
                for edit in edits {
                    for cell in edit.cells {
                        if let colIdx = page.columns.firstIndex(where: { $0.name == cell.column.name }) {
                            highlights.insert(EditBuffer.CellKey(row: edit.rowIndex, column: colIdx))
                        }
                    }
                }
                appliedHighlights = highlights
                editBuffer.clear()
            }
            let snapshot = applySuccess
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if self?.applySuccess == snapshot {
                    self?.applySuccess = nil
                    self?.appliedHighlights = []
                }
            }
        } catch is CancellationError {
            applyError = "Cancelled"
            service.operations.finish(op, status: .cancelled)
        } catch {
            // Unwrap PostgresTransactionError / PSQLError into a real
            // server message — by default they read "error 1" / opaque
            // code, which isn't actionable.
            let message = PostgresErrorMessage.describe(error)
            applyError = message
            service.operations.finish(op, status: .failed(message))
        }
    }
}

// MARK: - JetBrains-style WHERE / ORDER BY strip

/// Single-row strip pinned above the grid. Splits 50/50: left side
/// receives the body of a `WHERE` clause, right side the body of an
/// `ORDER BY` clause. The `WHERE` / `ORDER BY` keywords are
/// non-editable labels in front of each input — the user types only
/// the expression. Enter (or focus loss) triggers `onSubmit` which
/// the host re-fires as a server-side reload.
private struct QueryStripView: View {
    @Binding var filter: RowsFetcher.Filter
    let table: TableNode
    let schema: SchemaSnapshot
    let isRefreshing: Bool
    let onSubmit: () -> Void

    /// We need a separate draft so we don't refetch on every keystroke.
    /// Submitted state lives in `filter`; `whereDraft` / `orderDraft`
    /// are what's currently in the fields. Submit writes through.
    @State private var whereDraft: String = ""
    @State private var orderDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            clauseField(
                keyword: "WHERE",
                text: $whereDraft,
                placeholder: "e.g. id = 5  OR  email ILIKE '%@valuo.cz'",
                tint: .blue,
                clauseKind: .whereExpr
            ) {
                // SwiftUI's TextField onCommit fires both on Enter AND
                // on focus loss on macOS, so guard against no-op
                // commits — otherwise tabbing between the two fields
                // triggers a useless server reload.
                guard whereDraft != filter.whereClause else { return }
                filter.whereClause = whereDraft
                onSubmit()
            }
            Divider()
            clauseField(
                keyword: "ORDER BY",
                text: $orderDraft,
                placeholder: "e.g. created_at DESC, id",
                tint: .purple,
                clauseKind: .orderBy
            ) {
                guard orderDraft != filter.orderByClause else { return }
                filter.orderByClause = orderDraft
                onSubmit()
            }
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 30)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(.separator),
            alignment: .bottom
        )
        .onAppear {
            whereDraft = filter.whereClause
            orderDraft = filter.orderByClause
        }
        // If the loader rewrites the filter (e.g. header click → sort),
        // mirror the change into the drafts so the strip stays accurate.
        .onChange(of: filter.whereClause) { _, new in
            if new != whereDraft { whereDraft = new }
        }
        .onChange(of: filter.orderByClause) { _, new in
            if new != orderDraft { orderDraft = new }
        }
    }

    @ViewBuilder
    private func clauseField(
        keyword: String,
        text: Binding<String>,
        placeholder: String,
        tint: Color,
        clauseKind: SQLCompletionContext.ClauseKind,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Text(keyword)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(tint.opacity(0.12))
            CompletingTextField(
                text: text,
                placeholder: placeholder,
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                completions: { partial in
                    SQLCompletionProvider.completions(
                        for: partial,
                        in: schema,
                        context: .clause(table: table, kind: clauseKind)
                    )
                },
                onCommit: onCommit
            )
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Structure / DDL panes

/// Mirrors `RowsLoader.State` but for `TableInspector.Snapshot`. Backed
/// by `@Observable` so SwiftUI re-renders when the async fetch resolves.
@MainActor
@Observable
final class InspectorLoader {
    enum State: Equatable {
        case idle, loading
        case loaded(TableInspector.Snapshot, ddl: String)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): true
            case (.loaded, .loaded), (.error, .error):  true
            default: false
            }
        }
    }

    private let table: TableNode
    private let service: ConnectionService
    var state: State = .idle

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
    }

    func load() async {
        guard let client = service.client else {
            state = .error("Not connected")
            return
        }
        state = .loading
        do {
            let snap = try await TableInspector.fetch(client: client, schema: table.schema, table: table.name)
            let ddl = try await TableInspector.renderDDL(client: client, snapshot: snap)
            state = .loaded(snap, ddl: ddl)
        } catch {
            state = .error(PostgresErrorMessage.describe(error))
        }
    }
}

private struct StructurePane: View {
    let state: InspectorLoader.State
    let onRetry: () -> Void
    var service: ConnectionService? = nil
    var onReload: (() -> Void)? = nil

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading structure…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let snap, _):
            StructureBody(snapshot: snap, service: service, onReload: onReload)
        case .error(let msg):
            InspectorError(msg: msg, retry: onRetry)
        }
    }
}

private struct StructureBody: View {
    let snapshot: TableInspector.Snapshot
    var service: ConnectionService? = nil
    var onReload: (() -> Void)? = nil

    @State private var showAddColumn = false
    @State private var renameColumnTarget: IdentifiedString?
    @State private var alterTypeTarget: AlterTypeRequest?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                if let comment = snapshot.comment {
                    Text(comment)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Tokens.Spacing.sm)
                }

                section("Columns") {
                    StructureColumnsTable(
                        columns: snapshot.columns,
                        pkColumns: pkColumnNames(snapshot),
                        canEdit: service != nil,
                        onRename: { renameColumnTarget = IdentifiedString(id: $0) },
                        onAlterType: { col in
                            alterTypeTarget = AlterTypeRequest(column: col.name, currentType: col.typeName)
                        },
                        onDrop: { col in dropColumnPrompt(col) },
                        onAdd: { showAddColumn = true }
                    )
                }

                if !snapshot.constraints.isEmpty {
                    section("Constraints") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.constraints, id: \.name) { c in
                                constraintRow(c)
                            }
                        }
                    }
                }

                if !snapshot.indexes.isEmpty {
                    section("Indexes") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.indexes, id: \.name) { i in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(i.name)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    Text(i.definition)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                if !snapshot.triggers.isEmpty {
                    section("Triggers") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.triggers, id: \.name) { t in
                                triggerRow(t)
                            }
                        }
                    }
                }

                if let part = snapshot.partitioning {
                    section("Partitioning") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(part.strategy.uppercased())
                                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Tokens.Brand.primary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(Tokens.Brand.primary)
                                Text(part.key)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            ForEach(part.children, id: \.name) { child in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(child.schema).\(child.name)")
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                    Text(child.bound.isEmpty ? "DEFAULT" : child.bound)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                            if part.children.isEmpty {
                                Text("No partitions yet")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Spacer(minLength: Tokens.Spacing.md)
            }
            .padding(Tokens.Spacing.md)
            .frame(minWidth: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAddColumn) {
            if let service {
                AddColumnSheet(
                    service: service, schema: snapshot.schema, table: snapshot.table,
                    onClose: { showAddColumn = false },
                    onSaved: { onReload?() }
                )
            }
        }
        .sheet(item: $renameColumnTarget) { target in
            if let service {
                RenameColumnSheet(
                    service: service, schema: snapshot.schema, table: snapshot.table,
                    original: target.value,
                    onClose: { renameColumnTarget = nil },
                    onSaved: { onReload?() }
                )
            }
        }
        .sheet(item: $alterTypeTarget) { req in
            if let service {
                AlterColumnTypeSheet(
                    service: service, schema: snapshot.schema, table: snapshot.table,
                    column: req.column, currentType: req.currentType,
                    onClose: { alterTypeTarget = nil },
                    onSaved: { onReload?() }
                )
            }
        }
    }

    private func dropColumnPrompt(_ col: TableInspector.Column) {
        guard let service else { return }
        let alert = NSAlert()
        alert.messageText = "Drop column \(col.name)?"
        alert.informativeText = "Data in this column is gone permanently. Drop CASCADE also removes anything depending on it (views, FKs)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Drop CASCADE")
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let cascade = (answer == .alertSecondButtonReturn)
        Task {
            _ = await AdminActions.dropColumn(
                schema: snapshot.schema, table: snapshot.table,
                column: col.name, cascade: cascade, service: service
            )
            onReload?()
        }
    }

    @ViewBuilder
    private func triggerRow(_ t: TableInspector.Trigger) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(t.enabled ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(t.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                if !t.enabled {
                    Text("disabled")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let service {
                    Button(t.enabled ? "Disable" : "Enable") {
                        Task {
                            _ = await AdminActions.setTriggerEnabled(
                                schema: snapshot.schema, table: snapshot.table,
                                trigger: t.name, enabled: !t.enabled,
                                service: service
                            )
                            onReload?()
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Drop trigger \(t.name)?"
                        alert.informativeText = "This cannot be undone."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Drop")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            Task {
                                _ = await AdminActions.dropTrigger(
                                    schema: snapshot.schema, table: snapshot.table,
                                    trigger: t.name, service: service
                                )
                                onReload?()
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
            Text(t.definition)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func constraintRow(_ c: TableInspector.Constraint) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(badge(for: c.kind))
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(constraintColor(for: c.kind).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(constraintColor(for: c.kind))
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Text(c.definition)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func section<Body: View>(_ title: String, @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }

    private func pkColumnNames(_ s: TableInspector.Snapshot) -> Set<String> {
        // Pull the primary-key column names out of the constraint def so we
        // can flag them inline in the column table — there's always at most
        // one PK so this stays cheap.
        guard let pk = s.constraints.first(where: { $0.kind == "p" }) else { return [] }
        guard let open = pk.definition.firstIndex(of: "("),
              let close = pk.definition.firstIndex(of: ")"),
              open < close
        else { return [] }
        let body = pk.definition[pk.definition.index(after: open)..<close]
        return Set(body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
              .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        })
    }

    private func badge(for kind: Character) -> String {
        switch kind {
        case "p": "PK"
        case "u": "UK"
        case "f": "FK"
        case "c": "CK"
        case "x": "EX"
        default:  String(kind).uppercased()
        }
    }

    private func constraintColor(for kind: Character) -> Color {
        switch kind {
        case "p": Tokens.Brand.primary
        case "u": .indigo
        case "f": .blue
        case "c": .orange
        default:  .gray
        }
    }
}

/// Columns rendered as a real SwiftUI `Grid` so each column sizes to
/// content with sensible minimums, instead of fighting hardcoded
/// widths that overflowed when the window was narrow and clipped long
/// types like `character varying(255)`.
private struct StructureColumnsTable: View {
    let columns: [TableInspector.Column]
    let pkColumns: Set<String>
    var canEdit: Bool = false
    var onRename: ((String) -> Void)? = nil
    var onAlterType: ((TableInspector.Column) -> Void)? = nil
    var onDrop: ((TableInspector.Column) -> Void)? = nil
    var onAdd: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 14,
                 verticalSpacing: 4) {
                GridRow {
                    headerCell("#", alignment: .trailing)
                    headerCell("Name")
                    headerCell("Type")
                    headerCell("Nullable", alignment: .center)
                    headerCell("Default")
                    headerCell("Comment")
                }
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))

                ForEach(Array(columns.enumerated()), id: \.element.ordinal) { (idx, c) in
                    GridRow {
                        Text("\(c.ordinal)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)

                        HStack(spacing: 4) {
                            if pkColumns.contains(c.name) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Tokens.Brand.primary)
                            }
                            Text(c.name)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .textSelection(.enabled)
                        }

                        Text(c.typeName)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(c.nullable ? "yes" : "no")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(c.nullable ? .secondary : .primary)
                            .gridColumnAlignment(.center)

                        Text(c.defaultExpr ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(c.defaultExpr == nil ? .tertiary : .secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(c.comment ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        if canEdit {
                            Button("Rename column…") { onRename?(c.name) }
                            Button("Change type…") { onAlterType?(c) }
                            Divider()
                            Button("Drop column…", role: .destructive) { onDrop?(c) }
                        }
                    }
                    if idx < columns.count - 1 {
                        Divider().opacity(0.35).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            if canEdit, let onAdd {
                Button {
                    onAdd()
                } label: {
                    Label("Add column", systemImage: "plus.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func headerCell(_ s: String, alignment: HorizontalAlignment = .leading) -> some View {
        Text(s.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
            .gridColumnAlignment(alignment)
    }
}

private struct DDLPane: View {
    let state: InspectorLoader.State
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Generating DDL…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(_, let ddl):
            DDLBody(ddl: ddl)
        case .error(let msg):
            InspectorError(msg: msg, retry: onRetry)
        }
    }
}

private struct DDLBody: View {
    let ddl: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CREATE statement")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ddl, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy SQL", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, Tokens.Spacing.md)
            .padding(.vertical, 6)
            Divider().opacity(0.5)

            ScrollView([.vertical, .horizontal]) {
                // Run the SQL lexer over the DDL so keywords / strings /
                // comments / numbers come out coloured — same palette
                // the notebook cells use.
                Text(SQLHighlighter.attributedString(for: ddl))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.md)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct InspectorError: View {
    let msg: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Couldn't load metadata")
                .font(.headline)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Click-to-open popover showing the full multi-line apply error so the
/// user can actually read the server's reason (and copy it).
private struct ApplyErrorPopover: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("Apply failed").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Text("Transaction rolled back. Your pending edits are still here — fix and Apply again, or Revert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.md)
        .frame(width: 460)
    }
}
