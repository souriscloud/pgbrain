import AppKit
import SwiftUI

/// Single-pass JSON syntax highlighter attached as an `NSTextStorage`
/// delegate, mirroring `SQLHighlighter`'s lightweight approach: walk the
/// string once and colour keys, string values, numbers, literals and
/// punctuation. No parser — colour is advisory, the validity chip in the
/// editor toolbar is the source of truth for well-formedness.
final class JSONHighlighter: NSObject, NSTextStorageDelegate, @unchecked Sendable {
    static let shared = JSONHighlighter()

    private static let key = NSColor(srgbRed: 0.42, green: 0.32, blue: 0.86, alpha: 1)      // brand violet
    private static let string = NSColor.systemGreen
    private static let number = NSColor.systemOrange
    private static let literal = NSColor.systemPurple
    private static let punct = NSColor.tertiaryLabelColor

    nonisolated func highlight(_ storage: NSTextStorage, font: NSFont) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Attribute-only changes (no character edits) are safe to apply
        // directly, including from inside `didProcessEditing`.
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        storage.addAttribute(.font, value: font, range: full)

        let chars = storage.string
        var idx = chars.startIndex
        while idx < chars.endIndex {
            let c = chars[idx]
            if c == "\"" {
                // Scan a full string token (respecting escapes).
                let start = idx
                var j = chars.index(after: idx)
                while j < chars.endIndex {
                    if chars[j] == "\\", let n = chars.index(j, offsetBy: 1, limitedBy: chars.endIndex), n < chars.endIndex {
                        j = chars.index(after: n); continue
                    }
                    if chars[j] == "\"" { j = chars.index(after: j); break }
                    j = chars.index(after: j)
                }
                let nsRange = NSRange(start..<j, in: chars)
                // A string immediately followed (after optional spaces) by ':'
                // is an object key — colour it differently.
                var k = j
                while k < chars.endIndex, chars[k] == " " || chars[k] == "\n" || chars[k] == "\t" { k = chars.index(after: k) }
                let isKey = k < chars.endIndex && chars[k] == ":"
                storage.addAttribute(.foregroundColor, value: isKey ? Self.key : Self.string, range: nsRange)
                idx = j
            } else if c.isNumber || (c == "-" && chars.index(after: idx) < chars.endIndex) {
                let start = idx
                var j = idx
                while j < chars.endIndex, "0123456789+-.eE".contains(chars[j]) { j = chars.index(after: j) }
                storage.addAttribute(.foregroundColor, value: Self.number, range: NSRange(start..<j, in: chars))
                idx = j
            } else if c.isLetter {
                let start = idx
                var j = idx
                while j < chars.endIndex, chars[j].isLetter { j = chars.index(after: j) }
                let word = String(chars[start..<j])
                if word == "true" || word == "false" || word == "null" {
                    storage.addAttribute(.foregroundColor, value: Self.literal, range: NSRange(start..<j, in: chars))
                }
                idx = j
            } else {
                if "{}[]:,".contains(c) {
                    storage.addAttribute(.foregroundColor, value: Self.punct, range: NSRange(idx..<chars.index(after: idx), in: chars))
                }
                idx = chars.index(after: idx)
            }
        }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let font = (textStorage.length > 0
            ? textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            : nil) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlight(textStorage, font: font)
    }
}

/// A syntax-highlighted, monospaced JSON text editor. Plain `NSTextView`
/// wrapped for SwiftUI, with the `JSONHighlighter` driving colours live.
struct JSONSyntaxEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        textView.textStorage?.delegate = JSONHighlighter.shared
        JSONHighlighter.shared.highlight(textView.textStorage!, font: textView.font!)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            JSONHighlighter.shared.highlight(textView.textStorage!, font: textView.font!)
            textView.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: JSONSyntaxEditor
        weak var textView: NSTextView?
        init(_ parent: JSONSyntaxEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
