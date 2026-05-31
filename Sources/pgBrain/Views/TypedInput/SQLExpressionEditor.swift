import AppKit
import SwiftUI

/// Compact, SQL syntax-highlighted text field used by `TypedValueEditor`'s
/// expression mode. Reuses the app's `SQLHighlighter` (the same lexer that
/// colours the scratchpad) for colour and the custom `CompletionController`
/// for IDE-grade, schema-aware completion.
struct SQLExpressionEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    /// Schema-aware completion source: (partial, fullText, caretIndex) →
    /// rich items. Nil disables completion.
    var completions: ((_ partial: String, _ fullText: String, _ caretIndex: Int) -> [CompletionItem])? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.textStorage?.delegate = SQLHighlighter.shared
        if let storage = textView.textStorage {
            SQLHighlighter.shared.highlight(storage)
        }
        context.coordinator.textView = textView
        if let provider = completions {
            context.coordinator.controller = CompletionController(textView: textView) { p, f, c in
                provider(p, f, c)
            }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            if let storage = textView.textStorage { SQLHighlighter.shared.highlight(storage) }
            let len = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, len), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SQLExpressionEditor
        weak var textView: NSTextView?
        var controller: CompletionController?
        private var debounce: Task<Void, Never>?
        private var previousLength = 0
        init(_ parent: SQLExpressionEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            controller?.refreshIfVisible()
            scheduleCompletion(in: tv)
        }

        /// Route nav keys to the popup while it's open; ⌘Space / Esc as the
        /// manual trigger / dismiss.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSStandardKeyBindingResponding.complete(_:)) {
                controller?.requestCompletion()
                return true
            }
            return controller?.handleCommand(commandSelector) ?? false
        }

        private func scheduleCompletion(in tv: NSTextView) {
            guard controller != nil else { return }
            let ns = tv.string as NSString
            let len = ns.length
            let grew = len > previousLength
            previousLength = len
            debounce?.cancel()
            guard grew else { return }
            let caret = tv.selectedRange().location
            guard caret > 0, caret <= len, isWordChar(ns.character(at: caret - 1)) else { return }
            guard identifierPrefixLength(ns, caret) >= 2 else { return }
            debounce = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
                self?.controller?.requestCompletion()
            }
        }

        private func isWordChar(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
            (c >= 0x30 && c <= 0x39) || c == 0x5F
        }

        private func identifierPrefixLength(_ ns: NSString, _ caret: Int) -> Int {
            var i = caret, count = 0
            while i > 0, isWordChar(ns.character(at: i - 1)) { i -= 1; count += 1 }
            return count
        }
    }
}
