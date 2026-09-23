import AppKit
import SwiftUI
import Observation
import PostgresNIO
import UniformTypeIdentifiers

/// Cell-based notebook scratchpad. Replaces the iter-15
/// NSTextAttachmentViewProvider design which never managed to render an
/// inline widget on our NSTextView setup. SwiftUI stack of alternating
/// SQL editors and result widgets — each cell is its own small NSTextView,
/// results are rendered through `DataGridView`.
///
/// `Cmd+⏎` inside an SQL cell runs that cell. With a non-empty selection
/// in the cell, only the selected SQL is run. The runner inserts result
/// widgets immediately after the cell and appends a fresh empty SQL cell
/// at the bottom so the user can keep typing without manually adding one.
struct NotebookView: View {
    @Bindable var notebook: Notebook
    let service: ConnectionService

    @State private var showLibrary = false
    @State private var focusedCellID: UUID?
    @State private var explainRequest: ExplainSheetState?
    @State private var diffRequest: DiffSheetState?
    @State private var parameterRequest: Notebook.ParameterRequest?

    struct ExplainSheetState: Identifiable {
        let id = UUID()
        let sql: String
    }
    struct DiffSheetState: Identifiable {
        let id = UUID()
        let leftStatement: String
        let rightStatement: String
        let leftPage: RowsFetcher.Page
        let rightPage: RowsFetcher.Page
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = notebook.sessionNotice {
                sessionNoticeBar(notice)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager VStack — not LazyVStack — so every cell's
                    // NSTextView exists at all times. With LazyVStack, an
                    // off-screen target cell isn't materialised and
                    // `makeFirstResponder` can't transfer focus to it
                    // (caret appears stuck in two cells, typing goes
                    // nowhere). For huge notebooks (100+ cells) this
                    // gets expensive; revisit with text-view pooling
                    // then.
                    VStack(spacing: 0) {
                        ForEach(notebook.cells) { cell in
                            CellRow(
                                cell: cell,
                                notebook: notebook,
                                service: service,
                                focusedCellID: $focusedCellID
                            )
                            .id(cell.id)
                            Divider().opacity(0.2)
                        }
                    }
                    .padding(.vertical, Tokens.Spacing.sm)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: focusedCellID) { _, newID in
                    guard let id = newID else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showLibrary) {
            SavedQueriesView(
                notebook: notebook,
                onOpenInNewTab: { sql in
                    let pad = service.workspace.openScratchpad()
                    if let first = pad.cells.first(where: { $0.kind == .sql }) { first.text = sql }
                }
            ) {
                showLibrary = false
            }
        }
        .sheet(item: $explainRequest) { state in
            ExplainPlanView(
                initialSQL: state.sql,
                runExplain: { analyze in
                    await NotebookRunner.explain(sql: state.sql, analyze: analyze, notebook: notebook, service: service)
                },
                onClose: { explainRequest = nil }
            )
        }
        .onChange(of: notebook.requestedExplainSQL) { _, sql in
            if let sql, !sql.isEmpty {
                explainRequest = ExplainSheetState(sql: sql)
                notebook.requestedExplainSQL = nil
            }
        }
        .onChange(of: notebook.requestedDiffLastTwo) { _, want in
            if want { presentDiffLastTwo(); notebook.requestedDiffLastTwo = false }
        }
        .sheet(item: $diffRequest) { state in
            ResultDiffView(
                leftStatement: state.leftStatement,
                rightStatement: state.rightStatement,
                leftPage: state.leftPage,
                rightPage: state.rightPage,
                onClose: { diffRequest = nil }
            )
        }
        .onChange(of: notebook.requestedParameters?.id) { _, _ in
            if let request = notebook.requestedParameters {
                parameterRequest = request
                notebook.requestedParameters = nil
            }
        }
        .sheet(item: $parameterRequest) { request in
            QueryParametersView(
                names: request.names,
                values: notebook.parameters,
                onRun: { filled in
                    notebook.parameters = filled
                    parameterRequest = nil
                    // Replay the deferred run now that the placeholders are
                    // filled — `run` re-derives the SQL and substitutes.
                    if let cell = notebook.sqlCell(id: request.cellID) {
                        NotebookRunner.run(cell: cell, selection: request.selection,
                                           notebook: notebook, service: service)
                    }
                },
                onCancel: { parameterRequest = nil }
            )
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(notebook.title).font(.body.weight(.medium))

            schemaPicker

            Toggle(isOn: $notebook.runAsTransaction) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                    Text("Atomic").font(.caption.weight(.semibold))
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Run multi-statement runs as one transaction (BEGIN/COMMIT) — any error rolls the whole batch back")

            commitModePicker

            TransactionIndicator(
                transaction: notebook.transaction,
                isRunning: notebook.isRunning,
                onCommit: { NotebookRunner.endTransaction(commit: true, notebook: notebook, service: service) },
                onRollback: { NotebookRunner.endTransaction(commit: false, notebook: notebook, service: service) }
            )

            Spacer()

            if notebook.isRunning {
                Button { notebook.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .help("Cancel the running statement and the rest of the batch (⌘.)")
            }

            Button { notebook.clearResults() } label: {
                Image(systemName: "clear")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!notebook.cells.contains { if case .result = $0.kind { return true } else { return false } })
            .help("Clear all results")
            Button { showLibrary = true } label: {
                Label("Saved", systemImage: "books.vertical").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save this scratchpad for later, or reopen a saved one")

            Menu {
                Button("Open .sql…") { openSQLFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save as .sql…") { saveSQLFile() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Reset Session") { resetSession() }
                    .disabled(notebook.session == nil)
            } label: {
                Image(systemName: "doc.badge.ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open / save SQL files")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Scopes the notebook's queries to a specific schema via
    /// `SET search_path` on the checked-out connection. "Default" means
    /// leave the connection's existing `search_path` alone (typically
    /// `"$user", public`). Picking a schema also lets you write
    /// unqualified table names against it (`SELECT * FROM users` instead
    /// of `SELECT * FROM analytics.users`).
    @ViewBuilder
    private var schemaPicker: some View {
        let schemas = service.visibleSchema.schemas.map(\.name)
        Menu {
            Button {
                notebook.searchPath = nil
            } label: {
                Label("Default search_path", systemImage: notebook.searchPath == nil ? "checkmark" : "")
            }
            if !schemas.isEmpty {
                Divider()
                ForEach(schemas, id: \.self) { name in
                    Button {
                        notebook.searchPath = name
                    } label: {
                        Label(name, systemImage: notebook.searchPath == name ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack").font(.caption)
                Text(notebook.searchPath ?? "default")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("search_path for this scratchpad")
    }

    /// DataGrip's Tx: Auto / Manual. Manual opens a transaction before the
    /// first data-changing statement and leaves it for Commit / Roll Back.
    private var commitModePicker: some View {
        Picker("", selection: $notebook.autoCommit) {
            Text("Auto").tag(true)
            Text("Manual").tag(false)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
        .help("Auto-commit each statement, or Manual: open a transaction before the first change and wait for Commit / Roll Back")
    }

    private func sessionNoticeBar(_ notice: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button { notebook.sessionNotice = nil } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain)
                .help("Dismiss")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 4)
        .background(Color.yellow.opacity(0.08))
    }

    /// Drop the pinned connection and start fresh on the next run. Asks first
    /// when that would throw away an open transaction.
    private func resetSession() {
        guard notebook.confirmCloseWithOpenTransaction() else { return }
        notebook.sessionNotice = nil
        service.toasts.show(.info, "Session reset — the next run opens a new connection")
    }

    /// Open a `.sql` file into a new SQL cell at the end of the
    /// notebook. We append rather than replace so the user doesn't lose
    /// what they were working on.
    private func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            service.toasts.show(.error, "Couldn't open \(url.lastPathComponent) — \(error.localizedDescription)")
            return
        }
        // Reuse the first empty SQL cell if there is one, else append.
        if let empty = notebook.cells.first(where: { $0.kind == .sql && $0.text.isEmpty }) {
            empty.text = text
        } else if let lastSQL = notebook.cells.last(where: { $0.kind == .sql }) {
            let sep = lastSQL.text.isEmpty ? "" : "\n\n"
            lastSQL.text += sep + text
        }
        notebook.title = url.deletingPathExtension().lastPathComponent
    }

    /// Save the notebook's combined SQL text to a `.sql` file.
    private func saveSQLFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(notebook.title).sql"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try notebook.plainText.write(to: url, atomically: true, encoding: .utf8)
            service.toasts.show(.success, "Saved \(url.lastPathComponent)")
        } catch {
            service.toasts.show(.error, "Couldn't save \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Find the two most-recent successful results in the notebook
    /// and pop the diff sheet on them. No-op (no sheet) when fewer
    /// than two successful results exist.
    private func presentDiffLastTwo() {
        let successes: [(stmt: String, page: RowsFetcher.Page)] = notebook.cells.compactMap { cell in
            guard case .result(let resultID) = cell.kind,
                  let result = notebook.results[resultID],
                  case .success(let qr) = result.status
            else { return nil }
            return (result.statement, qr.page)
        }
        guard successes.count >= 2 else { return }
        let right = successes[successes.count - 1]
        let left = successes[successes.count - 2]
        diffRequest = DiffSheetState(
            leftStatement: left.stmt, rightStatement: right.stmt,
            leftPage: left.page, rightPage: right.page
        )
    }

}

// MARK: - Cell row

private struct CellRow: View {
    @Bindable var cell: NotebookCell
    let notebook: Notebook
    let service: ConnectionService
    @Binding var focusedCellID: UUID?

    var body: some View {
        switch cell.kind {
        case .sql:
            SqlCellView(cell: cell, notebook: notebook, service: service,
                        isRunning: notebook.runningCellID == cell.id,
                        focusedCellID: $focusedCellID)
        case .result(let resultID):
            ResultCellView(resultID: resultID, notebook: notebook, service: service)
        }
    }
}

// MARK: - SQL cell

private struct SqlCellView: View {
    @Bindable var cell: NotebookCell
    let notebook: Notebook
    let service: ConnectionService
    let isRunning: Bool
    @Binding var focusedCellID: UUID?

    @State private var markers: [StatementMarker] = []
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Run gutter: a ▶ per statement (runs just that statement inline).
            SqlGutter(
                markers: markers,
                accent: Tokens.Brand.primary,
                onRun: { range in
                    NotebookRunner.run(cell: cell, selection: range,
                                       notebook: notebook, service: service)
                }
            )
            .frame(width: 26)

            SqlCellEditor(
                text: Binding(get: { cell.text }, set: { cell.text = $0 }),
                shouldFocus: focusedCellID == cell.id,
                onRun: { range in
                    // ⌘↩ runs the selection if there is one, else just the
                    // statement under the caret — never the whole cell (that's
                    // the floating ▶ / per-statement gutter).
                    if range.length > 0 {
                        NotebookRunner.run(cell: cell, selection: range,
                                           notebook: notebook, service: service)
                    } else if let stmt = statementRange(at: range.location, in: cell.text) {
                        NotebookRunner.run(cell: cell, selection: stmt,
                                           notebook: notebook, service: service)
                    }
                },
                onFocus: { focusedCellID = cell.id },
                onJumpToAdjacent: { direction in
                    jumpToAdjacentSqlCell(direction: direction)
                },
                completions: { partial, fullText, caretIndex in
                    SQLCompletionProvider.items(
                        for: partial,
                        in: service.visibleSchema,
                        context: .scratchpad(fullText: fullText, caretIndex: caretIndex)
                    )
                },
                schema: { service.visibleSchema },
                onExplain: { sql in
                    notebook.requestedExplainSQL = sql
                },
                onMarkers: { markers = $0 }
            )
            .frame(minHeight: 30)
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .overlay(alignment: .topTrailing) {
            // Floating action button: run this whole input cell.
            Button {
                NotebookRunner.run(cell: cell, selection: nil,
                                   notebook: notebook, service: service)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Tokens.Brand.primary)
                    .background(Circle().fill(Color(nsColor: .textBackgroundColor)).padding(2))
            }
            .buttonStyle(.plain)
            .help("Run this cell (⌘↩)")
            .padding(.top, 4)
            .padding(.trailing, Tokens.Spacing.md + 4)
            .opacity(hovering || isRunning ? 1 : 0.0)
        }
        .overlay(alignment: .leading) {
            // Left rail indicates focus/running state at a glance.
            Rectangle()
                .fill(isRunning
                      ? Color.green
                      : (focusedCellID == cell.id ? Tokens.Brand.primary.opacity(0.7) : Color.clear))
                .frame(width: 3)
        }
        .background(isRunning ? Color.green.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
    }

    /// NSRange of the (whitespace-trimmed) statement containing the UTF-16
    /// caret offset, or nil if none.
    private func statementRange(at utf16Caret: Int, in text: String) -> NSRange? {
        let clamped = max(0, min(utf16Caret, (text as NSString).length))
        guard let caretIdx = Range(NSRange(location: clamped, length: 0), in: text)?.lowerBound,
              let stmt = SQLStatementSplitter.statementAt(caret: caretIdx, in: text) else { return nil }
        var lo = stmt.range.lowerBound
        var hi = stmt.range.upperBound
        while lo < hi, text[lo].isWhitespace { lo = text.index(after: lo) }
        while hi > lo, text[text.index(before: hi)].isWhitespace { hi = text.index(before: hi) }
        guard lo < hi else { return nil }
        return NSRange(lo..<hi, in: text)
    }

    private func jumpToAdjacentSqlCell(direction: Int) {
        guard let myIdx = notebook.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let range: AnyIterator<Int>
        if direction > 0 {
            var i = myIdx + 1
            range = AnyIterator { defer { i += 1 }; return i < notebook.cells.count ? i : nil }
        } else {
            var i = myIdx - 1
            range = AnyIterator { defer { i -= 1 }; return i >= 0 ? i : nil }
        }
        for i in range where notebook.cells[i].kind == .sql {
            focusedCellID = notebook.cells[i].id
            return
        }
    }
}

/// NSTextView wrapped in NSViewRepresentable. Each SQL cell gets its own
/// instance. `onRun` fires on `Cmd+⏎` with the current selection (or nil
/// if empty); the runner decides between "statement at caret" and "this
/// exact selection".
private struct SqlCellEditor: NSViewRepresentable {
    @Binding var text: String
    var shouldFocus: Bool
    let onRun: (NSRange) -> Void
    let onFocus: () -> Void
    /// Called when the caret tries to move past the cell's first/last line:
    /// +1 for down (jump to next SQL cell), -1 for up.
    let onJumpToAdjacent: (Int) -> Void
    /// Returns ranked completion strings for the partial identifier
    /// preceding the caret. We pass through the full cell text + caret
    /// so the provider can derive context (FROM-vs-WHERE etc.) instead
    /// of always returning the union of everything.
    let completions: (_ partial: String, _ fullText: String, _ caretIndex: Int) -> [CompletionItem]
    /// Live schema snapshot — used by hover-to-identify tooltips.
    let schema: () -> SchemaSnapshot
    /// Host hook for `Explain Statement` — opens the EXPLAIN sheet
    /// on the notebook.
    let onExplain: (String) -> Void
    /// Reports statement markers for the run gutter.
    var onMarkers: ([StatementMarker]) -> Void = { _ in }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onRun: (NSRange) -> Void
        var onFocus: () -> Void
        var onJumpToAdjacent: (Int) -> Void
        var completions: (_ partial: String, _ fullText: String, _ caretIndex: Int) -> [CompletionItem]
        /// Provider for the live schema — used by hover-to-identify to
        /// build tooltip content without keeping a strong reference to
        /// the connection service inside the AppKit subclass.
        var currentSchema: (() -> SchemaSnapshot)?
        /// The custom completion controller for this cell's text view.
        var controller: CompletionController?

        init(text: Binding<String>, onRun: @escaping (NSRange) -> Void, onFocus: @escaping () -> Void, onJumpToAdjacent: @escaping (Int) -> Void, completions: @escaping (String, String, Int) -> [CompletionItem]) {
            self.text = text
            self.onRun = onRun
            self.onFocus = onFocus
            self.onJumpToAdjacent = onJumpToAdjacent
            self.completions = completions
        }

        func textDidChange(_ notif: Notification) {
            guard let tv = notif.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            // Per-keystroke autosave so scratchpad edits survive a crash,
            // not just a clean quit. The store debounces (0.5s) internally,
            // so a burst of typing collapses into one disk write.
            SessionStateStore.shared.scheduleSnapshot()
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(text: $text, onRun: onRun, onFocus: onFocus, onJumpToAdjacent: onJumpToAdjacent, completions: completions)
        c.currentSchema = schema
        return c
    }

    func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.currentSchema = schema
    }

    func makeNSView(context: Context) -> SqlCellNSTextView {
        let tv = SqlCellNSTextView()
        tv.isRichText = false
        // Enable the standard NSTextView find bar — ⌘F shows it,
        // ⌘G / ⌘⇧G step matches, ⌘⌥F toggles replace. Free win,
        // just had to opt in.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = NSFont.monospacedSystemFont(ofSize: CGFloat(AppSettings.shared.editorFontSize), weight: .regular)
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.allowsUndo = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.delegate = context.coordinator
        // Live SQL syntax highlighting — re-paints on every edit
        // through the text-storage delegate. The shared singleton
        // re-uses the keyword/function sets across cells.
        tv.textStorage?.delegate = SQLHighlighter.shared
        tv.onRun = { [weak tv] in
            guard let tv else { return }
            // Always report the full selected range (caret = zero length); the
            // host decides between "statement under caret" and "the selection".
            context.coordinator.onRun(tv.selectedRange())
        }
        tv.onJumpToAdjacent = { [weak tv] direction in
            _ = tv
            context.coordinator.onJumpToAdjacent(direction)
        }
        tv.onBecomeFirstResponder = { context.coordinator.onFocus() }
        tv.schemaProvider = { [weak coord = context.coordinator] in coord?.currentSchema?() }
        tv.onExplainRequested = onExplain
        tv.onLayoutChanged = onMarkers
        // IDE-grade completion: a custom panel driven by the schema-aware
        // provider, replacing macOS's string-only native popup.
        let controller = CompletionController(textView: tv) { [weak coord = context.coordinator] partial, full, caret in
            coord?.completions(partial, full, caret) ?? []
        }
        context.coordinator.controller = controller
        tv.completionController = controller
        tv.string = text
        // Highlight the initial contents — the delegate's edit hook only
        // fires for subsequent mutations.
        if let storage = tv.textStorage {
            SQLHighlighter.shared.highlight(storage)
        }
        tv.reportMarkers()
        return tv
    }

    func updateNSView(_ tv: SqlCellNSTextView, context: Context) {
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            let safe = NSRange(
                location: min(sel.location, tv.string.utf16.count),
                length: 0
            )
            tv.setSelectedRange(safe)
        }
        // If the host says this cell should be focused, grab first
        // responder synchronously. Async-dispatching was making cross-cell
        // arrow nav feel clunky — Down-then-typing dropped the focus
        // request between Cell A losing first responder and Cell B's
        // updateNSView firing on the next runloop turn.
        if shouldFocus, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        }
    }
}


// MARK: - Result cell

/// Wraps the grid with a tiny segmented toggle to flip between the
/// default grid, a pivot view, and a quick chart. Pivot + chart sheets
/// reuse the same `RowsFetcher.Page` — no extra fetch.
private struct ResultGridWithViews: View {
    let page: RowsFetcher.Page
    let service: ConnectionService
    let sourceSQL: String
    /// The scratchpad's search_path, so the inline map can resolve unqualified
    /// table names the same way the original query did.
    var searchPath: String? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case grid, pivot, chart, map
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .grid:  "tablecells"
            case .pivot: "square.grid.3x3"
            case .chart: "chart.bar"
            case .map:   "map"
            }
        }
    }
    @State private var mode: Mode = .grid

    /// A geometry column in this result (when PostGIS is present) → enables the
    /// inline Map view. Geometry renders as WKT, so we sniff for it.
    private var spatial: (geom: String, label: String?)? {
        guard service.hasPostGIS else { return nil }
        return SpatialDetect.detect(page)
    }

    private var modes: [Mode] {
        spatial != nil ? Mode.allCases : Mode.allCases.filter { $0 != .map }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thin toolbar above the content so the controls never cover the
            // top-right data cells.
            HStack(spacing: 8) {
                Text("\(page.rows.count) row\(page.rows.count == 1 ? "" : "s")\(page.truncated ? "+" : "") · \(page.columns.count) col\(page.columns.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(ClipboardCopy.Format.allCases) { fmt in
                        Button(fmt.menuLabel) {
                            let n = ClipboardCopy.copy(page, as: fmt)
                            service.toasts.show(.success, "Copied \(n) row\(n == 1 ? "" : "s") as \(fmt.menuLabel)")
                        }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .fixedSize()
                .help("Copy this result to the clipboard")

                // Inline view switcher — Grid / Pivot / Chart / Map, all
                // rendered right here in the result block (no sheets).
                ForEach(modes) { m in
                    Button { mode = m } label: {
                        Label(m.label, systemImage: m.icon)
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                    .tint(mode == m ? Tokens.Brand.primary : .secondary)
                    .help("Show as \(m.label)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            Divider().opacity(0.3)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .grid:
            DataGridView(page: page)
                .frame(minHeight: 140, idealHeight: 260, maxHeight: 360)
        case .pivot:
            PivotResultView(page: page, embedded: true)
        case .chart:
            ResultChartView(page: page, embedded: true)
        case .map:
            if let spatial {
                SpatialMapView(
                    service: service,
                    fromSQL: "(\(strippedSQL)\n) AS _pgbrain_map",
                    geometryColumn: spatial.geom,
                    labelColumn: spatial.label,
                    searchPath: searchPath
                )
                .frame(minHeight: 240, idealHeight: 320, maxHeight: 380)
            } else {
                DataGridView(page: page)
                    .frame(minHeight: 140, idealHeight: 260, maxHeight: 360)
            }
        }
    }

    /// The result's source SQL, minus any trailing semicolons, so it wraps
    /// cleanly inside `(…) AS _pgbrain_map` for the inline map.
    private var strippedSQL: String {
        var s = sourceSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }
}

private struct ResultCellView: View {
    let resultID: UUID
    @Bindable var notebook: Notebook
    let service: ConnectionService

    var body: some View {
        if let result = notebook.result(id: resultID) {
            ResultBody(result: result, notebook: notebook, service: service)
        } else {
            EmptyView()
        }
    }
}

private struct ResultBody: View {
    @Bindable var result: NotebookResult
    let notebook: Notebook
    let service: ConnectionService

    var body: some View {
        VStack(spacing: 0) {
            header
            if !result.isCollapsed {
                Divider().opacity(0.4)
                body(for: result.status)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Chevron now lives on the LEFT as a visual indicator; the
            // entire header is the tap target (sans the explicit X button).
            Image(systemName: result.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            statusGlyph
            Text(result.preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            outcomeSummary
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button {
                if let cellIdx = notebook.cells.firstIndex(where: {
                    if case .result(let r) = $0.kind { return r == result.id } else { return false }
                }) {
                    notebook.remove(cellID: notebook.cells[cellIdx].id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Remove this result")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            result.isCollapsed.toggle()
        }
    }

    @ViewBuilder
    private func body(for status: NotebookResult.Status) -> some View {
        switch status {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        case .success(let q):
            VStack(alignment: .leading, spacing: 0) {
                if q.page.columns.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(q.commandTag ?? "OK").font(.caption.monospaced())
                        Spacer()
                    }
                    .padding(10)
                } else {
                    ResultGridWithViews(page: q.page, service: service, sourceSQL: result.statement, searchPath: notebook.searchPath)
                }
                if !q.notices.isEmpty {
                    Divider().opacity(0.3)
                    Text(q.notices.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(10)
        case .cancelled:
            HStack {
                Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch result.status {
        case .running: ProgressView().controlSize(.mini)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var outcomeSummary: some View {
        switch result.status {
        case .running: EmptyView()
        case .success(let q):
            let rows = q.page.rows.count
            let prefix = q.page.truncated ? "\(rows)+" : "\(rows)"
            Text("\(prefix) row\(rows == 1 ? "" : "s") · \(String(format: "%.0f ms", q.page.elapsed * 1000))")
        case .failure: Text("Error")
        case .cancelled: Text("Cancelled")
        }
    }

    private var borderColor: Color {
        switch result.status {
        case .running: return .secondary.opacity(0.3)
        case .success: return .green.opacity(0.3)
        case .failure: return .red.opacity(0.4)
        case .cancelled: return .secondary.opacity(0.3)
        }
    }
}

// MARK: - Transaction indicator

/// Toolbar badge for the pinned session's transaction: nothing while idle,
/// "In transaction · N statements · 0:42" with Commit / Roll Back while one is
/// open, and a red "Failed — roll back" when the server has aborted it.
private struct TransactionIndicator: View {
    let transaction: Notebook.TransactionState
    let isRunning: Bool
    let onCommit: () -> Void
    let onRollback: () -> Void

    var body: some View {
        if transaction.isOpen {
            HStack(spacing: 6) {
                badge
                if transaction.status == .active {
                    Button("Commit", action: onCommit)
                        .controlSize(.small)
                        .disabled(isRunning)
                        .help("COMMIT the open transaction")
                }
                Button("Roll Back", action: onRollback)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help("ROLLBACK the open transaction")
            }
        }
    }

    private var badge: some View {
        let failed = transaction.status == .failed
        return HStack(spacing: 4) {
            Circle()
                .fill(failed ? Color.red : Color.orange)
                .frame(width: 7, height: 7)
            if failed {
                Text("Failed — must roll back")
                    .font(.caption.weight(.semibold))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("In transaction · \(transaction.statementCount) stmt\(transaction.statementCount == 1 ? "" : "s") · \(elapsed(at: context.date))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill((failed ? Color.red : Color.orange).opacity(0.14))
        )
        .help(failed
              ? "A statement failed inside the transaction; the server ignores everything until ROLLBACK"
              : "This scratchpad's session has an uncommitted transaction")
    }

    private func elapsed(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(transaction.startedAt ?? now))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
