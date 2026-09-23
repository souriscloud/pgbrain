import AppKit

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
        // ⌘↩ → run; 76 is the numeric keypad's Enter.
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
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
        // ⌘⇧E → Explain Statement. Plain ⌘E stays the system's
        // "Use Selection for Find".
        if event.modifierFlags.contains([.command, .shift]),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            explainStatement(nil)
            return
        }
        if let direction = Self.cellJump(
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            onFirstLine: self.isCaretOnFirstLine(), onLastLine: self.isCaretOnLastLine()
        ) {
            onJumpToAdjacent?(direction)
            return
        }
        super.keyDown(with: event)
    }

    /// Which adjacent SQL cell an arrow key jumps to, if any. Only exact
    /// modifier sets count — ⌥⇧↑ (select to paragraph start), ⇧↓ (extend
    /// the selection) and ⌘↓ (end of document) must keep their text-editing
    /// meaning:
    /// - ⌥↓ / ⌥↑ jump regardless of caret position (AppKit's "move to end
    ///   of paragraph" is rarely useful here);
    /// - plain ↓ on the visually-last line / ↑ on the first line jump.
    static func cellJump(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        onFirstLine: @autoclosure () -> Bool, onLastLine: @autoclosure () -> Bool
    ) -> Int? {
        let direction: Int
        switch keyCode {
        case 125: direction = +1
        case 126: direction = -1
        default: return nil
        }
        // Arrow keys also carry .numericPad / .function; only the user-held
        // modifiers matter.
        let held = modifiers.intersection([.command, .option, .control, .shift])
        if held == .option { return direction }
        guard held.isEmpty else { return nil }
        let atEdge = direction > 0 ? onLastLine() : onFirstLine()
        return atEdge ? direction : nil
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
        let explain = NSMenuItem(title: "Explain Statement", action: #selector(explainStatement(_:)), keyEquivalent: "E")
        explain.keyEquivalentModifierMask = [.command, .shift]
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
