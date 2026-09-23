import SwiftUI
import AppKit

/// Reusable SQL source editor — an `NSTextView` with the same
/// `SQLHighlighter`, schema-aware completion and editor-font zoom the
/// scratchpad cells use, but without any of their cell-management state.
/// Used by the function editor and the view editor. Two-way bound to `text`.
struct SQLEditorTextView: NSViewRepresentable {
    @Binding var text: String
    var schemaProvider: (() -> SchemaSnapshot?)? = nil

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        var schemaProvider: (() -> SchemaSnapshot?)?
        var controller: CompletionController?

        init(binding: Binding<String>) { self.binding = binding }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            binding.wrappedValue = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if controller?.handleCommand(selector) == true { return true }
            // Esc opens completion, like in the scratchpad.
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                controller?.requestCompletion()
                return true
            }
            return false
        }

        func completions(partial: String, fullText: String, caret: Int) -> [CompletionItem] {
            guard let schema = schemaProvider?() else { return [] }
            return SQLCompletionProvider.items(
                for: partial, in: schema,
                context: .scratchpad(fullText: fullText, caretIndex: caret)
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(binding: $text)
        c.schemaProvider = schemaProvider
        return c
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let tv = SQLEditorNSTextView()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.isRichText = false
        tv.font = SQLEditorNSTextView.editorFont
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.delegate = context.coordinator
        tv.allowsUndo = true
        tv.string = text
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        if let storage = tv.textStorage {
            let highlighter = SQLHighlighter()
            storage.delegate = highlighter
            tv.highlighter = highlighter
            highlighter.highlight(storage)
        }
        let controller = CompletionController(textView: tv) { [weak coord = context.coordinator] partial, full, caret in
            coord?.completions(partial: partial, fullText: full, caret: caret) ?? []
        }
        context.coordinator.controller = controller
        tv.completionController = controller
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.schemaProvider = schemaProvider
        guard let tv = scroll.documentView as? SQLEditorNSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            if let storage = tv.textStorage {
                tv.highlighter?.highlight(storage)
            }
        }
    }
}

/// Text view behind `SQLEditorTextView`: follows ⌘+ / ⌘− editor zoom and
/// pops schema completion as you type, matching the scratchpad cells.
final class SQLEditorNSTextView: NSTextView {
    static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(AppSettings.shared.editorFontSize), weight: .regular)
    }

    /// Retained here because `NSTextStorage.delegate` is weak.
    var highlighter: SQLHighlighter?
    var completionController: CompletionController?

    private var fontObserver: NSObjectProtocol?
    private var completionDebounce: Task<Void, Never>?
    private var previousLength = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let o = fontObserver { NotificationCenter.default.removeObserver(o); fontObserver = nil }
            completionController?.cancel()
        } else if fontObserver == nil {
            fontObserver = NotificationCenter.default.addObserver(
                forName: .pgbrainEditorFontChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyEditorFont() }
            }
            applyEditorFont()
        }
    }

    private func applyEditorFont() {
        let font = Self.editorFont
        guard self.font != font else { return }
        self.font = font
        if let storage = textStorage { highlighter?.highlight(storage) }
    }

    override func keyDown(with event: NSEvent) {
        if let cc = completionController, cc.isVisible {
            switch event.keyCode {
            case 126: cc.moveSelection(-1); return
            case 125: cc.moveSelection(+1); return
            case 36, 76, 48: if cc.acceptSelected() { return }
            case 53: cc.cancel(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        completionController?.refreshIfVisible()
        let ns = string as NSString
        let grew = ns.length > previousLength
        previousLength = ns.length
        completionDebounce?.cancel()
        guard grew, identifierPrefixLength() >= 2 else { return }
        // Same 180 ms debounce as the scratchpad: only the last keystroke of
        // a burst opens the panel.
        completionDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self, self.identifierPrefixLength() >= 2 else { return }
            self.completionController?.requestCompletion()
        }
    }

    private func identifierPrefixLength() -> Int {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret > 0, caret <= ns.length else { return 0 }
        var i = caret
        while i > 0 {
            let c = ns.character(at: i - 1)
            let word = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
            guard word else { break }
            i -= 1
        }
        return caret - i
    }
}
