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
                    guard let client = service.client else {
                        return .failure(Explain.ExplainError.empty)
                    }
                    do {
                        let node = try await Explain.run(sql: state.sql, analyze: analyze, on: client)
                        return .success(node)
                    } catch {
                        return .failure(error)
                    }
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

            Spacer()
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

/// NSTextView subclass that grows with its content, intercepts ⌘↩, and
/// hands ↑/↓ at the cell boundary to the host for cross-cell navigation.
final class SqlCellNSTextView: NSTextView {
    var onRun: (() -> Void)?
    var onJumpToAdjacent: ((Int) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    /// Reports the cell's statement markers (range + vertical geometry) so the
    /// SwiftUI run-gutter can place a ▶ next to each statement. Fired after
    /// every edit and re-layout.
    var onLayoutChanged: (([StatementMarker]) -> Void)?
    /// Used by hover-to-identify to look up tables / columns under the
    /// mouse. Returns nil when no schema is available.
    var schemaProvider: (() -> SchemaSnapshot?)?
    /// Custom completion panel for this cell. When visible it captures
    /// ↑/↓/⏎/⇥/Esc; otherwise Esc/⌥Esc open it.
    var completionController: CompletionController?

    /// Tracks the storage length on the previous tick so `didChangeText`
    /// can tell insertions from deletions. Auto-complete only fires on
    /// forward typing — never on backspace.
    private var previousStringLength: Int = 0
    /// Debounce token for the as-you-type completion popup. Subsequent
    /// keystrokes cancel the pending fire so we don't open 5 popups in
    /// a row, and only the last word-character keystroke triggers.
    private var completionDebounce: Task<Void, Never>?

    /// Tracking area for hover-to-identify. Recreated whenever bounds
    /// change so the area stays the size of the visible cell.
    private var hoverTracking: NSTrackingArea?
    /// Live editor-font observer; registered while in a window, torn down
    /// when removed (keeps it main-actor and leak-free).
    private var fontObserver: NSObjectProtocol?
    /// Character index resolved by the *previous* mouseMoved call.
    /// Used to skip the schema lookup when the cursor hasn't crossed
    /// into a new character — otherwise every pixel of mouse motion
    /// re-scans the entire schema and tanks scratchpad scroll fps.
    private var lastHoverCharIndex: Int = -1

    override func keyDown(with event: NSEvent) {
        // Completion panel owns navigation keys while it's open — must come
        // before cross-cell ↑/↓ nav and ⌘↩ run handling below.
        if let cc = completionController, cc.isVisible {
            switch event.keyCode {
            case 126: cc.moveSelection(-1); return      // ↑
            case 125: cc.moveSelection(+1); return      // ↓
            case 36, 76: if cc.acceptSelected() { return }  // ⏎ / enter
            case 48: if cc.acceptSelected() { return }      // ⇥ tab
            case 53: cc.cancel(); return                    // esc
            default: break
            }
        }
        // ⌘↩ → run.
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            onRun?()
            return
        }
        // Esc / ⌥Esc → open completion (when the panel isn't already up).
        if event.keyCode == 53 {
            completionController?.requestCompletion()
            return
        }
        // ⌘⌥L (JetBrains convention) → Format SQL.
        if event.modifierFlags.contains([.command, .option]),
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            formatSQL(nil)
            return
        }
        // ⌘E → Explain Statement (Postico / DataGrip convention).
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            explainStatement(nil)
            return
        }
        // ⌥↓ / ⌥↑ → unconditional jump to next/previous SQL cell,
        // regardless of caret position. Overrides AppKit's default
        // "move to end/start of paragraph" which is rarely useful here.
        if event.modifierFlags.contains(.option), event.keyCode == 125 {
            onJumpToAdjacent?(+1)
            return
        }
        if event.modifierFlags.contains(.option), event.keyCode == 126 {
            onJumpToAdjacent?(-1)
            return
        }
        // Plain ↓ on the visually-last line → jump to next SQL cell.
        if event.keyCode == 125, isCaretOnLastLine() {
            onJumpToAdjacent?(+1)
            return
        }
        // Plain ↑ on the visually-first line → jump to previous SQL cell.
        if event.keyCode == 126, isCaretOnFirstLine() {
            onJumpToAdjacent?(-1)
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Wrapping changes statement geometry when the cell width changes.
        reportMarkers()
    }

    /// Recompute statement ranges + their vertical geometry and hand them to
    /// the run gutter. Dispatched to the next runloop turn so we never mutate
    /// SwiftUI state mid-layout.
    func reportMarkers() {
        guard let onLayoutChanged, let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let text = string
        let inset = textContainerInset.height
        var out: [StatementMarker] = []
        for (i, stmt) in SQLStatementSplitter.split(text).enumerated() {
            // The splitter's range starts right after the previous `;`, so it
            // includes leading whitespace/newlines — measuring that gives the
            // WRONG line (the previous statement's). Trim to the actual content
            // so each ▶ sits on its own first line.
            var lo = stmt.range.lowerBound
            var hi = stmt.range.upperBound
            while lo < hi, text[lo].isWhitespace { lo = text.index(after: lo) }
            while hi > lo, text[text.index(before: hi)].isWhitespace { hi = text.index(before: hi) }
            guard lo < hi else { continue }
            let r = NSRange(lo..<hi, in: text)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            out.append(StatementMarker(id: i, range: r, yTop: rect.minY + inset, height: rect.height))
        }
        let result = out
        DispatchQueue.main.async { onLayoutChanged(result) }
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 24)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(24, used.height + 8))
    }

    // MARK: - Bracket / quote pairing + auto-indent

    private static let openerToCloser: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "'": "'", "\"": "\""
    ]
    private static let closersSet: Set<Character> = [")", "]", "}", "'", "\""]

    /// Auto-pair `(` `[` `{` `'` `"`. Wraps an existing selection
    /// when present; skips over an existing closer when the user
    /// types one that's already next to the caret. Apostrophes after
    /// word characters (`it's`) fall through to the default insert.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, s.count == 1, let ch = s.first {
            let sel = selectedRange()
            let ns = self.string as NSString
            if Self.closersSet.contains(ch), sel.length == 0, sel.location < ns.length,
               UnicodeScalar(ns.character(at: sel.location)) == ch.unicodeScalars.first {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
            if let closer = Self.openerToCloser[ch] {
                let isQuote = ch == "'" || ch == "\""
                let prevIsWord: Bool = {
                    guard sel.location > 0 else { return false }
                    let prev = ns.character(at: sel.location - 1)
                    return (prev >= 0x41 && prev <= 0x5A)
                        || (prev >= 0x61 && prev <= 0x7A)
                        || (prev >= 0x30 && prev <= 0x39)
                        || prev == 0x5F
                }()
                if !(isQuote && prevIsWord) {
                    if sel.length > 0 {
                        let selected = ns.substring(with: sel)
                        let replacement = "\(ch)\(selected)\(closer)"
                        if shouldChangeText(in: sel, replacementString: replacement) {
                            textStorage?.replaceCharacters(in: sel, with: replacement)
                            didChangeText()
                            setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
                        }
                    } else {
                        let pair = "\(ch)\(closer)"
                        if shouldChangeText(in: sel, replacementString: pair) {
                            textStorage?.replaceCharacters(in: sel, with: pair)
                            didChangeText()
                            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                        }
                    }
                    return
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Match the previous line's leading whitespace on Enter so users
    /// don't re-indent every line. Tabs and spaces are both honoured.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.location <= ns.length else { super.insertNewline(sender); return }
        let beforeCaret = NSRange(location: 0, length: sel.location)
        let nlRange = ns.range(of: "\n", options: [.backwards], range: beforeCaret)
        let lineStart = nlRange.location == NSNotFound ? 0 : nlRange.location + 1
        var indentEnd = lineStart
        while indentEnd < ns.length {
            let c = ns.character(at: indentEnd)
            if c == 0x20 || c == 0x09 { indentEnd += 1 } else { break }
        }
        let indent = ns.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        let insertion = "\n" + indent
        if shouldChangeText(in: sel, replacementString: insertion) {
            textStorage?.replaceCharacters(in: sel, with: insertion)
            didChangeText()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        reportMarkers()
        // Keep an open panel in sync with what's being typed.
        completionController?.refreshIfVisible()
        // Smart as-you-type: only fire when the text grew (insertion,
        // not delete), the last char is an identifier char, the
        // identifier prefix is ≥2 chars, and we've waited 180ms since
        // the previous keystroke (debounce). Anything else cancels.
        let currentLength = (string as NSString).length
        let grew = currentLength > previousStringLength
        previousStringLength = currentLength
        completionDebounce?.cancel()
        guard grew else { return }
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret > 0, caret <= ns.length else { return }
        let lastChar = ns.character(at: caret - 1)
        guard isWordChar(lastChar) else { return }
        guard currentIdentifierPrefixLength() >= 2 else { return }
        completionDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            // Re-check the prefix on fire — the user may have deleted
            // chars in the debounce window.
            if self.currentIdentifierPrefixLength() >= 2 {
                self.completionController?.requestCompletion()
            }
        }
    }

    private func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x30 && c <= 0x39) || c == 0x5F
    }

    /// Length of the identifier-like character run ending at the caret
    /// (letters, digits, underscores). Zero if the caret isn't on a
    /// word boundary so we suppress the popup after whitespace or
    /// punctuation.
    private func currentIdentifierPrefixLength() -> Int {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret > 0, caret <= ns.length else { return 0 }
        var i = caret
        while i > 0, isWordChar(ns.character(at: i - 1)) { i -= 1 }
        return caret - i
    }

    // MARK: - Hover-to-identify

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let o = fontObserver { NotificationCenter.default.removeObserver(o); fontObserver = nil }
        } else if fontObserver == nil {
            fontObserver = NotificationCenter.default.addObserver(
                forName: .pgbrainEditorFontChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyEditorFont() }
            }
        }
    }

    /// Re-apply the current editor font size to this cell, re-highlight so
    /// existing runs pick up the new size, and re-flow the gutter geometry.
    private func applyEditorFont() {
        font = NSFont.monospacedSystemFont(ofSize: CGFloat(AppSettings.shared.editorFontSize), weight: .regular)
        if let storage = textStorage { SQLHighlighter.shared.highlight(storage) }
        invalidateIntrinsicContentSize()
        reportMarkers()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Cheap gate: skip the schema resolution unless the cursor
        // crossed a character boundary. Without this, every pixel of
        // mouse motion runs `hoverInfo` (full schema scan), which
        // becomes the dominant cost on a large schema and tanks
        // scratchpad scroll fps.
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index == lastHoverCharIndex { return }
        lastHoverCharIndex = index
        let info = hoverInfo(charIndex: index)
        if self.toolTip != info { self.toolTip = info }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastHoverCharIndex = -1
        if self.toolTip != nil { self.toolTip = nil }
    }

    // MARK: - Custom context menu

    /// Replace NSTextView's default menu (writing tools, dictation,
    /// substitutions, …) with a focused SQL-editor menu. Standard
    /// editing actions on top, schema-lookup of the identifier under
    /// the cursor at the bottom.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        let identifier = identifierAround(charIndex: charIndex)

        let menu = NSMenu()
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "")
        menu.addItem(cut)
        menu.addItem(copy)
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(selectAll)
        menu.addItem(.separator())
        let format = NSMenuItem(title: "Format SQL", action: #selector(formatSQL(_:)), keyEquivalent: "")
        format.target = self
        menu.addItem(format)
        let explain = NSMenuItem(title: "Explain Statement", action: #selector(explainStatement(_:)), keyEquivalent: "")
        explain.target = self
        menu.addItem(explain)

        // Snippets bloc.
        menu.addItem(.separator())
        let saveSnippet = NSMenuItem(title: "Save selection as snippet…", action: #selector(saveSelectionAsSnippet(_:)), keyEquivalent: "")
        saveSnippet.target = self
        saveSnippet.isEnabled = selectedRange().length > 0 || !string.isEmpty
        menu.addItem(saveSnippet)
        let allSnippets = SnippetStore.shared.snippets
        if !allSnippets.isEmpty {
            let insertMenu = NSMenuItem(title: "Insert snippet", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for snip in allSnippets {
                let item = NSMenuItem(title: snip.name, action: #selector(insertSnippetMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = snip.id
                sub.addItem(item)
            }
            insertMenu.submenu = sub
            menu.addItem(insertMenu)
        }

        // SQL-specific block, only when we can resolve something.
        let snapshot = schemaProvider.flatMap { $0() }
        if let ident = identifier,
           let snap = snapshot,
           let info = SQLHoverResolver.describe(identifier: ident, in: snap) {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Look up “\(ident)”", action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(
                string: "Look up “\(ident)”",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
            )
            header.isEnabled = false
            menu.addItem(header)
            for line in info.split(separator: "\n", omittingEmptySubsequences: false) {
                let item = NSMenuItem(title: String(line), action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(
                    string: "  " + String(line),
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                )
                item.isEnabled = false
                menu.addItem(item)
            }
            let copyInfo = NSMenuItem(
                title: "Copy lookup info",
                action: #selector(copyHoverInfo(_:)),
                keyEquivalent: ""
            )
            copyInfo.target = self
            copyInfo.representedObject = info
            menu.addItem(copyInfo)
        }
        return menu
    }

    @objc private func copyHoverInfo(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    @objc private func saveSelectionAsSnippet(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        let body: String
        if sel.length > 0 {
            body = ns.substring(with: sel)
        } else {
            body = self.string
        }
        guard !body.isEmpty else { return }
        // Pop a tiny modal alert for the name — sidesteps having to
        // route through ConnectionWindowContent for a one-shot dialog.
        let alert = NSAlert()
        alert.messageText = "Save snippet"
        alert.informativeText = "Name this snippet so you can find it later."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "snippet name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                SnippetStore.shared.add(name: name, body: body)
            }
        }
    }

    @objc private func insertSnippetMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let snip = SnippetStore.shared.snippets.first(where: { $0.id == id })
        else { return }
        let expanded = SnippetStore.expand(snip.body)
        let sel = selectedRange()
        if shouldChangeText(in: sel, replacementString: expanded.text) {
            textStorage?.replaceCharacters(in: sel, with: expanded.text)
            didChangeText()
            // Place the caret at the resolved $cursor$ offset (relative
            // to the insertion start).
            let insertStart = sel.location
            setSelectedRange(NSRange(location: insertStart + expanded.caret, length: 0))
        }
    }

    /// Resolve the statement under the caret (or selection) and ask
    /// the host notebook to open the EXPLAIN sheet for it.
    @objc func explainStatement(_ sender: Any?) {
        let sql = currentStatementSQL()
        guard !sql.isEmpty else { return }
        onExplainRequested?(sql)
    }

    /// Statement-under-caret resolver shared by Explain + the SQL
    /// runner. Prefers the user's selection when one exists, else
    /// the `;`-bounded statement around the caret.
    private func currentStatementSQL() -> String {
        let ns = string as NSString
        let sel = selectedRange()
        if sel.length > 0 {
            return ns.substring(with: sel).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let buffer = string
        let caret = sel.location  // NSString (UTF-16) units
        let statements = SQLStatementSplitter.split(buffer)
        for s in statements {
            let lo = buffer.utf16.distance(from: buffer.startIndex, to: s.range.lowerBound)
            let hi = buffer.utf16.distance(from: buffer.startIndex, to: s.range.upperBound)
            if caret >= lo, caret <= hi {
                return s.trimmed
            }
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Host-provided closure that opens the EXPLAIN sheet.
    var onExplainRequested: ((String) -> Void)?

    /// Run the SQL formatter on the cell's contents. Replaces the
    /// whole text storage in one shot so the undo manager records a
    /// single undoable edit rather than per-token replacements.
    @objc func formatSQL(_ sender: Any?) {
        let original = self.string
        let formatted = SQLFormatter.format(original)
        guard formatted != original else { return }
        let full = NSRange(location: 0, length: (original as NSString).length)
        if shouldChangeText(in: full, replacementString: formatted) {
            self.textStorage?.replaceCharacters(in: full, with: formatted)
            didChangeText()
        }
    }

    /// Identifier the cursor / right-click is sitting on. Shares the
    /// same word-walk logic as `hoverInfo` — duplicate kept inline so
    /// the menu builder doesn't have to do the schema lookup again.
    private func identifierAround(charIndex: Int) -> String? {
        let ns = string as NSString
        var idx = max(0, min(charIndex, ns.length - 1))
        if idx < 0 || idx >= ns.length { return nil }
        if !isWordChar(ns.character(at: idx)) {
            if idx > 0, isWordChar(ns.character(at: idx - 1)) { idx -= 1 }
            else { return nil }
        }
        var left = idx
        while left > 0, isWordChar(ns.character(at: left - 1)) { left -= 1 }
        var right = idx
        while right + 1 < ns.length, isWordChar(ns.character(at: right + 1)) { right += 1 }
        let word = ns.substring(with: NSRange(location: left, length: right - left + 1))
        return word.isEmpty ? nil : word
    }

    /// Resolve the identifier under `charIndex` (or just before it) and
    /// build a short description from the live schema. Returns nil when
    /// the cursor is on whitespace / punctuation / an unknown word so
    /// AppKit doesn't show a useless tooltip.
    private func hoverInfo(charIndex: Int) -> String? {
        // `schemaProvider?()` is `SchemaSnapshot??` — optional chaining
        // on a function call that itself returns Optional. A single
        // `guard let` only peels one layer, leaving `schema:
        // SchemaSnapshot?`, which silently never matched any identifier
        // (and the file still compiled because Swift inferred the
        // wrong type at the call site). Flatten via `.flatMap` so the
        // bound `schema` is the non-optional we actually need.
        guard let schema: SchemaSnapshot = schemaProvider.flatMap({ $0() })
        else { return nil }
        let ns = string as NSString
        var idx = max(0, min(charIndex, ns.length - 1))
        if idx < 0 || idx >= ns.length { return nil }
        // If we're past a word, characterIndexForInsertion lands one
        // past — back up one so the resolver finds the identifier.
        if !isWordChar(ns.character(at: idx)) {
            if idx > 0, isWordChar(ns.character(at: idx - 1)) { idx -= 1 }
            else { return nil }
        }
        // Walk both directions to find identifier bounds.
        var left = idx
        while left > 0, isWordChar(ns.character(at: left - 1)) { left -= 1 }
        var right = idx
        while right + 1 < ns.length, isWordChar(ns.character(at: right + 1)) { right += 1 }
        let word = ns.substring(with: NSRange(location: left, length: right - left + 1))
        guard !word.isEmpty else { return nil }
        return SQLHoverResolver.describe(identifier: word, in: schema)
    }

    /// True if the caret is on the visually first (top) line of the cell.
    /// Clamps the caret to a valid character index before resolving its
    /// glyph — `glyphIndexForCharacter(at:)` with `caret == string.length`
    /// returns garbage that incorrectly matches the first-line rect.
    private func isCaretOnFirstLine() -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return true }
        lm.ensureLayout(for: tc)
        let nsLen = (string as NSString).length
        let caret = max(0, min(selectedRange().location, nsLen))
        let clampedChar = max(0, min(caret, nsLen - 1))  // -1 not allowed; ok when nsLen=0
        let caretGlyph = nsLen == 0 ? 0 : lm.glyphIndexForCharacter(at: clampedChar)
        let firstLine = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let caretLine = lm.lineFragmentRect(forGlyphAt: caretGlyph, effectiveRange: nil)
        return abs(caretLine.minY - firstLine.minY) < 0.5
    }

    /// True if the caret is on the visually last (bottom) line of the cell.
    private func isCaretOnLastLine() -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return true }
        lm.ensureLayout(for: tc)
        let nsLen = (string as NSString).length
        let caret = max(0, min(selectedRange().location, nsLen))
        let lastGlyphIndex = lm.numberOfGlyphs > 0 ? lm.numberOfGlyphs - 1 : 0
        let clampedChar = max(0, min(caret, nsLen - 1))
        let caretGlyph = nsLen == 0 ? 0
            : (caret >= nsLen ? lastGlyphIndex : lm.glyphIndexForCharacter(at: clampedChar))
        let lastLineRect = lm.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
        let caretLine = lm.lineFragmentRect(forGlyphAt: caretGlyph, effectiveRange: nil)
        return abs(caretLine.minY - lastLineRect.minY) < 0.5
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
        case .failure: Text("error")
        case .cancelled: Text("cancelled")
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

// MARK: - Runner

/// Resolves what to run from a given SQL cell, executes via QueryRunner,
/// and feeds results back into the notebook's cell list. Replaces the
/// previous TextKit-attachment-based dispatcher.
@MainActor
enum NotebookRunner {
    static func run(cell: NotebookCell, selection: NSRange?, notebook: Notebook, service: ConnectionService) {
        guard cell.kind == .sql, let client = service.client else { return }

        // Resolve target statements within this cell. Slash-command
        // lines (`\dt`, `\df`, …) get expanded into real SQL before
        // statement splitting so the user can mix `\dt` with normal
        // queries in the same cell.
        let buffer = SlashCommands.translateCell(cell.text)
        let plans: [String]
        if let sel = selection {
            // User selected a range → translate-and-split just that.
            let ns = cell.text as NSString
            guard sel.location + sel.length <= ns.length else { return }
            let slice = SlashCommands.translateCell(ns.substring(with: sel))
            plans = SQLStatementSplitter.split(slice).map { $0.trimmed }
        } else {
            // No selection → run *every* statement in the cell, Jupyter-
            // style. Multi-statement cells get one result widget each.
            let split = SQLStatementSplitter.split(buffer).map { $0.trimmed }
            if !split.isEmpty {
                plans = split
            } else {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                plans = trimmed.isEmpty ? [] : [trimmed]
            }
        }
        guard !plans.isEmpty else { return }

        // Production-destructive guardrail.
        if service.connection.isProduction {
            let destructive = plans.contains {
                let v = SQLSafety.classify($0)
                return v == .destructiveUnscoped || v == .ddl
            }
            if destructive, !confirmProductionRun(plans: plans, service: service) { return }
        }

        notebook.runningCellID = cell.id

        // Each run STACKS: fresh result widgets are appended after any results
        // already under this cell, and the prior ones collapse. Re-running the
        // cell accumulates a history instead of replacing it.
        let ids = plans.map { _ in UUID() }
        notebook.stackResults(after: cell.id, newResultIDs: ids)

        // Mark each result as running before kicking off the async pipeline so
        // the SwiftUI cells flip to "Running…" immediately. The current run's
        // widgets start expanded (it's what you just asked for); a big batch
        // (>3) starts collapsed to stay scannable.
        let collapseAll = plans.count > 3
        for (sql, id) in zip(plans, ids) {
            let r = notebook.startResult(id: id, statement: sql)
            r.isCollapsed = collapseAll
        }

        // Transactional path: all statements on one connection inside
        // BEGIN/COMMIT. The first failure short-circuits and rolls back
        // the whole batch; remaining widgets get marked `.cancelled`.
        if notebook.runAsTransaction && plans.count > 1 {
            Task { @MainActor in
                defer { notebook.runningCellID = nil }
                await runTransactional(plans: plans, ids: ids, notebook: notebook, service: service, client: client)
            }
            return
        }

        Task { @MainActor in
            defer { notebook.runningCellID = nil }
            var schemaTouched = false
            for (sql, id) in zip(plans, ids) {
                let op = service.operations.begin(kind: .query, summary: QueryRunner.summary(of: sql))
                let result = notebook.startResult(id: id, statement: sql)
                result.isCollapsed = collapseAll
                let started = Date()
                do {
                    let qr = try await QueryRunner.run(
                        sql, on: client,
                        operationID: op.id, tracker: service.operations,
                        searchPath: notebook.searchPath
                    )
                    result.status = .success(qr)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .succeeded)
                    if Self.isSchemaChangingSQL(sql) { schemaTouched = true }
                    QueryHistoryStore.shared.record(
                        connectionID: service.connection.id,
                        sql: sql, startedAt: started,
                        elapsedSec: Date().timeIntervalSince(started),
                        success: true, errorMessage: nil,
                        rowsAffected: qr.rowsAffected
                    )
                } catch is CancellationError {
                    result.status = .cancelled
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .cancelled)
                    QueryHistoryStore.shared.record(
                        connectionID: service.connection.id,
                        sql: sql, startedAt: started,
                        elapsedSec: Date().timeIntervalSince(started),
                        success: false, errorMessage: "Cancelled",
                        rowsAffected: nil
                    )
                } catch {
                    let message = PostgresErrorMessage.describe(error)
                    result.status = .failure(message)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .failed(message))
                    QueryHistoryStore.shared.record(
                        connectionID: service.connection.id,
                        sql: sql, startedAt: started,
                        elapsedSec: Date().timeIntervalSince(started),
                        success: false, errorMessage: message,
                        rowsAffected: nil
                    )
                }
            }
            // A successful CREATE / DROP / ALTER / COMMENT can add or remove
            // sidebar objects (tables, functions, schemas) — refresh so the
            // tree reflects it without a reconnect.
            if schemaTouched { await service.loadSchema() }
        }
    }

    /// Returns true when `sql`'s leading keyword is DDL that can change what
    /// the sidebar shows. Comment-only / whitespace prefixes are skipped.
    static func isSchemaChangingSQL(_ sql: String) -> Bool {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading line/block comments so "-- note\nCREATE …" still counts.
        while true {
            if s.hasPrefix("--") {
                if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines); continue }
                return false
            }
            if s.hasPrefix("/*"), let close = s.range(of: "*/") {
                s = String(s[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines); continue
            }
            break
        }
        let head = s.prefix(while: { $0.isLetter }).lowercased()
        return ["create", "drop", "alter", "comment"].contains(head)
    }

    /// Single-connection BEGIN/COMMIT batch. Walks `plans` sequentially
    /// on one checked-out connection. First failure short-circuits the
    /// loop and issues ROLLBACK; statements that never ran get marked
    /// `.cancelled` so the user can see exactly where the failure was.
    @MainActor
    private static func runTransactional(
        plans: [String], ids: [UUID],
        notebook: Notebook, service: ConnectionService,
        client: PostgresClient
    ) async {
        let op = service.operations.begin(kind: .update, summary: "Transaction (\(plans.count) statements)")
        let started = Date()
        var failureMessage: String?
        var failedAt: Int = plans.count
        do {
            try await client.withConnection { conn in
                _ = try await conn.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: pgbrainQuietLogger)
                if let sp = notebook.searchPath {
                    _ = try await conn.query(
                        PostgresQuery(unsafeSQL: "SET LOCAL search_path TO \(SQLIdent.quote(sp))"),
                        logger: pgbrainQuietLogger
                    )
                }
                for (i, (sql, id)) in zip(plans, ids).enumerated() {
                    let stmtStarted = Date()
                    let result = await MainActor.run { notebook.startResult(id: id, statement: sql) }
                    do {
                        let qr = try await QueryRunner.runOnConnection(sql, on: conn)
                        await MainActor.run {
                            result.status = .success(qr)
                            result.finishedAt = Date()
                        }
                        QueryHistoryStore.shared.record(
                            connectionID: service.connection.id,
                            sql: sql, startedAt: stmtStarted,
                            elapsedSec: Date().timeIntervalSince(stmtStarted),
                            success: true, errorMessage: nil,
                            rowsAffected: qr.rowsAffected
                        )
                    } catch {
                        let msg = PostgresErrorMessage.describe(error)
                        failureMessage = msg
                        failedAt = i
                        await MainActor.run {
                            result.status = .failure(msg)
                            result.finishedAt = Date()
                        }
                        QueryHistoryStore.shared.record(
                            connectionID: service.connection.id,
                            sql: sql, startedAt: stmtStarted,
                            elapsedSec: Date().timeIntervalSince(stmtStarted),
                            success: false, errorMessage: msg,
                            rowsAffected: nil
                        )
                        break
                    }
                }
                // Commit on full success, rollback on any failure.
                if failureMessage == nil {
                    _ = try await conn.query(PostgresQuery(unsafeSQL: "COMMIT"), logger: pgbrainQuietLogger)
                } else {
                    _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                }
            }
            // Mark the never-ran widgets so the user sees the cutoff.
            for i in (failedAt + 1)..<plans.count {
                let r = await MainActor.run { notebook.startResult(id: ids[i], statement: plans[i]) }
                r.status = .cancelled
                r.finishedAt = Date()
            }
            if let msg = failureMessage {
                service.operations.finish(op, status: .failed("rolled back — \(msg)"))
            } else {
                service.operations.finish(op, status: .succeeded)
                if plans.contains(where: { isSchemaChangingSQL($0) }) {
                    await service.loadSchema()
                }
            }
            _ = started
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            // Mark every widget that never resolved.
            for id in ids {
                guard let r = notebook.result(id: id), case .running = r.status else { continue }
                r.status = .failure(msg)
                r.finishedAt = Date()
            }
        }
    }

    @MainActor
    private static func confirmProductionRun(plans: [String], service: ConnectionService) -> Bool {
        let preview = plans.prefix(3).joined(separator: "\n\n").prefix(360)
        let alert = NSAlert()
        alert.messageText = "Run on production?"
        alert.informativeText = """
            The connection "\(service.connection.name)" is marked PRODUCTION and \
            at least one statement in this batch is destructive or DDL.

            \(preview)
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Run on PROD")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
