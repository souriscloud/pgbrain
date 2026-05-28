import AppKit
import SwiftUI
import Observation

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
            SavedQueriesView(notebook: notebook) {
                showLibrary = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(notebook.title).font(.body.weight(.medium))

            schemaPicker

            Spacer()
            Button {
                runFocusedOrLastCell()
            } label: {
                Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .controlSize(.small)
            .help("Run focused SQL cell (⌘↩ also works inside a cell)")
            .disabled(service.client == nil)

            Button { showLibrary = true } label: {
                Image(systemName: "books.vertical")
            }
            .buttonStyle(.borderless)
            .help("Saved query library")
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

    private func runFocusedOrLastCell() {
        let target = focusedCellID ?? notebook.cells.last(where: { $0.kind == .sql })?.id
        guard let id = target, let cell = notebook.sqlCell(id: id) else { return }
        NotebookRunner.run(cell: cell, selection: nil, notebook: notebook, service: service)
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
            ResultCellView(resultID: resultID, notebook: notebook)
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

    var body: some View {
        SqlCellEditor(
            text: Binding(get: { cell.text }, set: { cell.text = $0 }),
            shouldFocus: focusedCellID == cell.id,
            onRun: { selection in
                NotebookRunner.run(
                    cell: cell, selection: selection,
                    notebook: notebook, service: service
                )
            },
            onFocus: { focusedCellID = cell.id },
            onJumpToAdjacent: { direction in
                jumpToAdjacentSqlCell(direction: direction)
            },
            completions: { partial, fullText, caretIndex in
                SQLCompletionProvider.completions(
                    for: partial,
                    in: service.visibleSchema,
                    context: .scratchpad(fullText: fullText, caretIndex: caretIndex)
                )
            },
            schema: { service.visibleSchema }
        )
        .frame(minHeight: 30)
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            // Left rail indicates focus/running state at a glance.
            Rectangle()
                .fill(isRunning
                      ? Color.green
                      : (focusedCellID == cell.id ? Tokens.Brand.primary.opacity(0.7) : Color.clear))
                .frame(width: 3)
        }
        .background(isRunning ? Color.green.opacity(0.04) : Color.clear)
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
    let onRun: (NSRange?) -> Void
    let onFocus: () -> Void
    /// Called when the caret tries to move past the cell's first/last line:
    /// +1 for down (jump to next SQL cell), -1 for up.
    let onJumpToAdjacent: (Int) -> Void
    /// Returns ranked completion strings for the partial identifier
    /// preceding the caret. We pass through the full cell text + caret
    /// so the provider can derive context (FROM-vs-WHERE etc.) instead
    /// of always returning the union of everything.
    let completions: (_ partial: String, _ fullText: String, _ caretIndex: Int) -> [String]
    /// Live schema snapshot — used by hover-to-identify tooltips.
    let schema: () -> SchemaSnapshot

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onRun: (NSRange?) -> Void
        var onFocus: () -> Void
        var onJumpToAdjacent: (Int) -> Void
        var completions: (_ partial: String, _ fullText: String, _ caretIndex: Int) -> [String]
        /// Provider for the live schema — used by hover-to-identify to
        /// build tooltip content without keeping a strong reference to
        /// the connection service inside the AppKit subclass.
        var currentSchema: (() -> SchemaSnapshot)?

        init(text: Binding<String>, onRun: @escaping (NSRange?) -> Void, onFocus: @escaping () -> Void, onJumpToAdjacent: @escaping (Int) -> Void, completions: @escaping (String, String, Int) -> [String]) {
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

        /// AppKit calls this when the text view's `complete(_:)` runs —
        /// either via Esc, our ⌃Space binding, or the system's
        /// completion driver. We supply schema-aware completions.
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let ns = textView.string as NSString
            guard charRange.location >= 0, charRange.location + charRange.length <= ns.length else { return words }
            let partial = ns.substring(with: charRange)
            // Pass the *full* cell text + the partial's start position so
            // the provider can derive context from what's to the left of
            // the caret (FROM / WHERE / ORDER BY / qualifier-dot etc.).
            let ours = completions(partial, ns as String, charRange.location)
            // Show the first match preselected so Enter / Tab inserts it.
            index?.pointee = ours.isEmpty ? -1 : 0
            return ours.isEmpty ? words : ours
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
            let sel = tv.selectedRange()
            context.coordinator.onRun(sel.length > 0 ? sel : nil)
        }
        tv.onJumpToAdjacent = { [weak tv] direction in
            _ = tv
            context.coordinator.onJumpToAdjacent(direction)
        }
        tv.onBecomeFirstResponder = { context.coordinator.onFocus() }
        tv.schemaProvider = { [weak coord = context.coordinator] in coord?.currentSchema?() }
        tv.string = text
        // Highlight the initial contents — the delegate's edit hook only
        // fires for subsequent mutations.
        if let storage = tv.textStorage {
            SQLHighlighter.shared.highlight(storage)
        }
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
    /// Used by hover-to-identify to look up tables / columns under the
    /// mouse. Returns nil when no schema is available.
    var schemaProvider: (() -> SchemaSnapshot?)?

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
    /// Character index resolved by the *previous* mouseMoved call.
    /// Used to skip the schema lookup when the cursor hasn't crossed
    /// into a new character — otherwise every pixel of mouse motion
    /// re-scans the entire schema and tanks scratchpad scroll fps.
    private var lastHoverCharIndex: Int = -1

    override func keyDown(with event: NSEvent) {
        // ⌘↩ → run.
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            onRun?()
            return
        }
        // Manual intellisense trigger. macOS already binds plain Esc
        // to `complete:` on NSTextView, so we don't need to handle it
        // here — but ⌥Esc is a common JetBrains/Xcode-on-Mac alias and
        // worth binding explicitly. ⌘Space conflicts with Spotlight
        // and ⌃Space conflicts with the system input-source switcher,
        // so neither is wired here.
        if event.modifierFlags.contains(.option), event.keyCode == 53 {
            self.complete(nil)
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

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 24)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(24, used.height + 8))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
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
                self.complete(nil)
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

private struct ResultCellView: View {
    let resultID: UUID
    @Bindable var notebook: Notebook

    var body: some View {
        if let result = notebook.result(id: resultID) {
            ResultBody(result: result, notebook: notebook)
        } else {
            EmptyView()
        }
    }
}

private struct ResultBody: View {
    @Bindable var result: NotebookResult
    let notebook: Notebook

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
                DataGridView(page: q.page)
                    .frame(minHeight: 140, idealHeight: 260, maxHeight: 360)
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

        // Resolve target statements within this cell.
        let buffer = cell.text
        let plans: [String]
        if let sel = selection {
            // User selected a range → just those statements.
            let ns = buffer as NSString
            guard sel.location + sel.length <= ns.length else { return }
            let slice = ns.substring(with: sel)
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

        // Generate fresh IDs OR reuse the IDs of the result cells already
        // adjacent to this SQL cell (replace-in-place semantics).
        let existing = notebook.adjacentResults(after: cell.id)
        var ids: [UUID] = []
        for i in 0..<plans.count {
            ids.append(i < existing.count ? existing[i].resultID : UUID())
        }
        notebook.replaceAdjacentResults(after: cell.id, with: ids)

        // Mark each result as running before kicking off the async pipeline
        // so the SwiftUI cells flip to the "Running…" state immediately.
        // Multi-statement runs default each widget to collapsed so the
        // user sees a scannable stack of headers instead of N expanded
        // grids — click any header to drill in.
        let collapseAll = plans.count > 1
        for (sql, id) in zip(plans, ids) {
            let r = notebook.startResult(id: id, statement: sql)
            r.isCollapsed = collapseAll
        }

        Task { @MainActor in
            defer { notebook.runningCellID = nil }
            for (sql, id) in zip(plans, ids) {
                let op = service.operations.begin(kind: .query, summary: QueryRunner.summary(of: sql))
                let result = notebook.startResult(id: id, statement: sql)
                // Re-apply collapse policy after startResult — the
                // synchronous pre-loop already did, but we want to be
                // explicit so future code changes don't reintroduce the
                // "always expanded" regression.
                result.isCollapsed = collapseAll
                do {
                    let qr = try await QueryRunner.run(
                        sql, on: client,
                        operationID: op.id, tracker: service.operations,
                        searchPath: notebook.searchPath
                    )
                    result.status = .success(qr)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .succeeded)
                } catch is CancellationError {
                    result.status = .cancelled
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .cancelled)
                } catch {
                    let message = PostgresErrorMessage.describe(error)
                    result.status = .failure(message)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .failed(message))
                }
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
