import AppKit
import SwiftUI
import Observation

/// Notebook scratchpad. Replaces the iter-4 result-block stack with a single
/// flowing document where SQL text and result widgets live inline.
///
/// Cmd+⏎ behaviour:
///   - Non-empty selection → run that exact range, insert result(s) right
///     after the selection end.
///   - Empty selection → run the statement under the caret, insert result
///     right after the statement.
///
/// Re-running with the same target (an existing result attachment is found
/// adjacent to the run end) replaces that result in place. Otherwise a new
/// attachment is inserted. The user can manually remove any result via its
/// header "x" button.
struct NotebookView: View {
    @Bindable var notebook: Notebook
    let service: ConnectionService

    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NotebookDocumentView(notebook: notebook, service: service)
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
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(notebook.title)
                .font(.body.weight(.medium))
            Spacer()
            Button {
                NotificationCenter.default.post(name: .pgBrainNotebookRunFromMenu, object: notebook.id)
            } label: {
                Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .controlSize(.small)
            .help("Run statement at cursor or selected range (⌘↩)")
            .disabled(service.client == nil)

            Button {
                showLibrary = true
            } label: {
                Image(systemName: "books.vertical")
            }
            .buttonStyle(.borderless)
            .help("Saved query library")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension Notification.Name {
    static let pgBrainNotebookRunFromMenu = Notification.Name("cloud.souris.pgbrain.notebook.runFromMenu")
}

/// `NSViewRepresentable` wrapper around the notebook's `NSTextView`. We
/// can't use SwiftUI's `TextEditor` here because we need direct access to
/// the `NSTextStorage` (for inline attachments) and to override key
/// handling for Cmd+⏎.
struct NotebookDocumentView: NSViewRepresentable {
    let notebook: Notebook
    let service: ConnectionService

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let notebook: Notebook
        let service: ConnectionService
        weak var textView: NotebookTextView?
        // Held via `nonisolated(unsafe)` so the nonisolated `deinit` can read
        // it back to remove the observer; only ever assigned during init on
        // the main actor.
        nonisolated(unsafe) var menuRunObserver: NSObjectProtocol?

        init(notebook: Notebook, service: ConnectionService) {
            self.notebook = notebook
            self.service = service
            super.init()
            menuRunObserver = NotificationCenter.default.addObserver(
                forName: .pgBrainNotebookRunFromMenu,
                object: notebook.id,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.runFromMenu()
                }
            }
        }

        deinit {
            if let token = menuRunObserver {
                NotificationCenter.default.removeObserver(token)
            }
        }

        @MainActor
        func runFromMenu() {
            guard let tv = textView else { return }
            tv.runCurrent()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(notebook: notebook, service: service)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        // Build a layout manager + container backed by the notebook's
        // text storage so the view edits the same buffer the model owns.
        let bigSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(size: bigSize)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 8
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        notebook.textStorage.addLayoutManager(layoutManager)

        let textView = NotebookTextView(frame: .zero, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(AppSettings.shared.editorFontSize), weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isRichText = true   // attachments require rich text
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.allowsImageEditing = false
        textView.delegate = context.coordinator
        textView.notebook = notebook
        textView.service = service

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // The notebook owns the storage; re-render the green outline when
        // `runningRange` changes.
        (nsView.documentView as? NotebookTextView)?.refreshRunningOutline()
    }
}

/// `NSTextView` subclass that owns Cmd+⏎ + paints the green run-context
/// outline. All run side-effects flow through `runCurrent()`.
final class NotebookTextView: NSTextView {
    weak var notebook: Notebook?
    weak var service: ConnectionService?

    override func keyDown(with event: NSEvent) {
        // Cmd+Return — same shortcut as iter-4 so muscle memory carries.
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            runCurrent()
            return
        }
        super.keyDown(with: event)
    }

    /// Determine run target(s) from current selection and dispatch them in
    /// document order. Selection wins over statement-under-caret.
    @MainActor
    func runCurrent() {
        guard let notebook, let service, let client = service.client else { return }
        let selection = selectedRange()
        let fullText = string

        let plans: [(range: NSRange, sql: String)]
        if selection.length > 0 {
            plans = statementsInSelection(selection: selection, fullText: fullText)
        } else if let single = statementAtCaret(offset: selection.location, fullText: fullText) {
            plans = [single]
        } else {
            plans = []
        }
        guard !plans.isEmpty else { return }

        // Destructive-on-prod guard — single confirmation for the whole batch.
        if service.connection.isProduction {
            let destructive = plans.contains {
                let v = SQLSafety.classify($0.sql)
                return v == .destructiveUnscoped || v == .ddl
            }
            if destructive, !confirmProductionRun(plans: plans) { return }
        }

        // JetBrains-style green outline = union of all run target ranges.
        let unionStart = plans.map(\.range.location).min() ?? 0
        let unionEnd = plans.map { $0.range.location + $0.range.length }.max() ?? 0
        notebook.runningRange = NSRange(location: unionStart, length: unionEnd - unionStart)
        refreshRunningOutline()

        // Walk forward from unionEnd looking for an existing chain of result
        // attachments. Reuse each in turn so re-running the same selection
        // replaces its previous results in place; insert fresh attachments
        // when the chain runs out.
        var cursor = unionEnd
        var pending: [(id: UUID, sql: String)] = []
        for plan in plans {
            let outcome = reuseOrInsertAttachment(at: cursor)
            cursor = outcome.cursorAfter
            pending.append((outcome.id, plan.sql))
        }

        // Spawn the async run; each result lands as we go.
        Task { @MainActor in
            defer {
                notebook.runningRange = nil
                self.refreshRunningOutline()
            }
            for entry in pending {
                let result = notebook.startResult(id: entry.id, statement: entry.sql)
                let op = service.operations.begin(
                    kind: .query,
                    summary: QueryRunner.summary(of: entry.sql)
                )
                do {
                    let qr = try await QueryRunner.run(
                        entry.sql,
                        on: client,
                        operationID: op.id,
                        tracker: service.operations
                    )
                    result.status = .success(qr)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .succeeded)
                } catch is CancellationError {
                    result.status = .cancelled
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .cancelled)
                } catch {
                    result.status = .failure(error.localizedDescription)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .failed(error.localizedDescription))
                }
            }
        }
    }

    /// If a `ResultAttachment` (ours) is the next non-whitespace character at
    /// or after `from`, return its `resultID` and a cursor positioned just
    /// past it. Otherwise insert a fresh attachment on its own line at
    /// `from` and return the new ID plus the post-insertion cursor.
    private func reuseOrInsertAttachment(at from: Int) -> (id: UUID, cursorAfter: Int) {
        guard let notebook, let storage = textStorage else {
            return (UUID(), from)
        }
        let nsString = storage.string as NSString
        var probe = from
        while probe < nsString.length {
            let ch = nsString.character(at: probe)
            if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D {
                probe += 1
            } else { break }
        }
        if probe < nsString.length {
            let attribs = storage.attributes(at: probe, effectiveRange: nil)
            if let existing = attribs[.attachment] as? ResultAttachment, existing.notebook === notebook {
                // Skip past the attachment + a following newline if present.
                var nextCursor = probe + 1
                if nextCursor < nsString.length, nsString.character(at: nextCursor) == 0x0A {
                    nextCursor += 1
                }
                return (existing.resultID, nextCursor)
            }
        }
        // Insert a new attachment line at `from`. Lead with a newline if
        // we're inline with text; trail with a newline so the user can keep
        // typing below.
        let newID = UUID()
        let attachment = ResultAttachment(resultID: newID, notebook: notebook)
        let insert = NSMutableAttributedString()
        let needLeadingNewline = from < nsString.length
            ? nsString.character(at: from) != 0x0A
            : true
        if needLeadingNewline { insert.append(NSAttributedString(string: "\n")) }
        insert.append(NSAttributedString(attachment: attachment))
        insert.append(NSAttributedString(string: "\n"))
        if let baseFont = self.font {
            insert.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: insert.length))
        }
        storage.beginEditing()
        storage.insert(insert, at: from)
        storage.endEditing()
        let cursorAfter = from + insert.length
        return (newID, cursorAfter)
    }

    /// JetBrains-style: green border around the SQL being executed.
    /// Implementation: query glyph bounds for the running range, stroke a
    /// rounded rectangle in `draw(_:)`. Storage changes trigger
    /// `refreshRunningOutline` which calls `needsDisplay = true`.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let notebook, let range = notebook.runningRange, range.length > 0,
              let layoutManager, let textContainer
        else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let inset = NSRect(
            x: rect.origin.x + textContainerOrigin.x - 2,
            y: rect.origin.y + textContainerOrigin.y - 2,
            width: rect.width + 4,
            height: rect.height + 4
        )
        let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
        NSColor.systemGreen.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        NSColor.systemGreen.withAlphaComponent(0.06).setFill()
        path.fill()
    }

    func refreshRunningOutline() {
        needsDisplay = true
    }

    /// Resolve the statement under `offset` (UTF-16 code-unit offset within
    /// `fullText`) into an absolute `NSRange` + its trimmed SQL.
    @MainActor
    private func statementAtCaret(offset: Int, fullText: String) -> (range: NSRange, sql: String)? {
        // NSRange offsets are UTF-16. Convert to a String.Index via the
        // utf16 view, then defer to SQLStatementSplitter.
        guard let strIdx = String.Index(utf16Offset: offset, in: fullText),
              let stmt = SQLStatementSplitter.statementAt(caret: strIdx, in: fullText)
        else { return nil }
        let nsRange = NSRange(stmt.range, in: fullText)
        return (nsRange, stmt.trimmed)
    }

    /// Split the SQL slice covered by `selection` into individual statements.
    /// Returned ranges are absolute (in `fullText`'s UTF-16 space).
    @MainActor
    private func statementsInSelection(selection: NSRange, fullText: String) -> [(range: NSRange, sql: String)] {
        let nsString = fullText as NSString
        guard selection.location + selection.length <= nsString.length else { return [] }
        let slice = nsString.substring(with: selection)
        let statements = SQLStatementSplitter.split(slice)
        var out: [(NSRange, String)] = []
        for s in statements {
            let local = NSRange(s.range, in: slice)
            let absolute = NSRange(location: selection.location + local.location, length: local.length)
            out.append((absolute, s.trimmed))
        }
        return out
    }

    @MainActor
    private func confirmProductionRun(plans: [(range: NSRange, sql: String)]) -> Bool {
        guard let service else { return false }
        let preview = plans.prefix(3).map { $0.sql }.joined(separator: "\n\n").prefix(360)
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

private extension String.Index {
    /// Bridges a UTF-16 offset (what `NSTextView.selectedRange` returns)
    /// into a Swift `String.Index`. Returns nil if the offset is out of
    /// bounds or lands inside a surrogate pair.
    init?(utf16Offset offset: Int, in string: String) {
        let utf16 = string.utf16
        guard let raw = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let idx = String.Index(raw, within: string)
        else { return nil }
        self = idx
    }
}
