import SwiftUI
import AppKit

/// Reusable SQL source editor — an `NSTextView` with the same
/// `SQLHighlighter` the scratchpad cells use, but without any of their
/// cell-management state. Used by the function editor and the view
/// editor. Two-way bound to `text`.
struct SQLEditorTextView: NSViewRepresentable {
    @Binding var text: String
    var schemaProvider: (() -> SchemaSnapshot?)? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            binding.wrappedValue = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isRichText = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.delegate = context.coordinator
            tv.allowsUndo = true
            tv.string = text
            tv.usesFindBar = true
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.textContainerInset = NSSize(width: 6, height: 6)
            if let storage = tv.textStorage {
                let highlighter = SQLHighlighter()
                storage.delegate = highlighter
                tv.attachedHighlighter = highlighter
                highlighter.highlight(storage)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            if let storage = tv.textStorage,
               let highlighter = tv.attachedHighlighter as? SQLHighlighter {
                highlighter.highlight(storage)
            }
        }
    }
}

// Pointer-stable address for objc_getAssociatedObject's key. UTF-8 bytes
// of a string literal have a stable address for the program lifetime,
// and `StaticString.utf8Start` exposes one without involving Swift's
// concurrency-safety analyzer (the value is shared-immutable C data).
private nonisolated(unsafe) let attachedHighlighterKey: UnsafeRawPointer = {
    let s: StaticString = "pgbrain.attachedHighlighter"
    return UnsafeRawPointer(s.utf8Start)
}()

private extension NSTextView {
    /// Retain the SQLHighlighter delegate alongside the text view so it
    /// outlives the makeNSView scope.
    var attachedHighlighter: AnyObject? {
        get { objc_getAssociatedObject(self, attachedHighlighterKey) as AnyObject? }
        set { objc_setAssociatedObject(self, attachedHighlighterKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
