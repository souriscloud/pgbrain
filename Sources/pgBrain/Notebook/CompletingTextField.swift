import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSTextField` that pops a completion menu
/// driven by a caller-supplied provider. Used by the JetBrains-style
/// `WHERE` / `ORDER BY` strip so the same schema-aware intellisense
/// the notebook cells get also shows up in those inputs.
///
/// Trigger behaviour matches `SqlCellNSTextView`:
///   - ⌘Space or ⌃Space → manually open the popup
///   - As-you-type → opens automatically once the identifier-shaped
///     prefix under the caret is ≥2 characters
///   - Esc → close popup
struct CompletingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let completions: (String) -> [String]
    let onCommit: () -> Void

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var completions: (String) -> [String]
        var onCommit: () -> Void
        /// Re-entry guard for synthetic edits (accepting a completion
        /// mutates the field, which re-fires controlTextDidChange).
        var isCompleting = false
        /// String length on the previous tick — distinguishes
        /// insertions from deletions so we don't open the popup
        /// while the user is backspacing.
        var previousLength = 0
        /// Debounce so a flurry of keystrokes only fires one
        /// `complete:` call (the last one wins).
        var completionDebounce: Task<Void, Never>?

        init(text: Binding<String>, completions: @escaping (String) -> [String], onCommit: @escaping () -> Void) {
            self.text = text
            self.completions = completions
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            guard !isCompleting else { return }
            // Trigger as-you-type only on forward typing of word chars,
            // 180ms after the last keystroke. Anything else cancels.
            let editor = field.currentEditor() as? NSTextView
            guard let editor else { return }
            let currentLength = (editor.string as NSString).length
            let grew = currentLength > previousLength
            previousLength = currentLength
            completionDebounce?.cancel()
            guard grew else { return }
            let caret = editor.selectedRange().location
            let ns = editor.string as NSString
            guard caret > 0, caret <= ns.length else { return }
            let lastChar = ns.character(at: caret - 1)
            guard isWordChar(lastChar) else { return }
            guard identifierPrefixLength(in: editor) >= 2 else { return }
            completionDebounce = Task { @MainActor [weak self, weak editor] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
                guard let self, let editor else { return }
                self.isCompleting = true
                editor.complete(nil)
                self.isCompleting = false
            }
        }

        private func isWordChar(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
            (c >= 0x30 && c <= 0x39) || c == 0x5F
        }

        func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            let ns = textView.string as NSString
            guard charRange.location >= 0, charRange.location + charRange.length <= ns.length else { return words }
            let partial = ns.substring(with: charRange)
            let ours = completions(partial)
            index.pointee = ours.isEmpty ? -1 : 0
            return ours.isEmpty ? words : ours
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Treat Enter / focus-loss as commit; the parent guards
            // against no-op reloads so this is cheap to fire.
            onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // ⌘Space / ⌃Space — manually trigger the completion popup.
            if commandSelector == #selector(NSStandardKeyBindingResponding.complete(_:)) {
                textView.complete(nil)
                return true
            }
            return false
        }

        private func identifierPrefixLength(in editor: NSTextView) -> Int {
            let ns = editor.string as NSString
            let caret = editor.selectedRange().location
            guard caret > 0, caret <= ns.length else { return 0 }
            var i = caret
            while i > 0 {
                let c = ns.character(at: i - 1)
                let isWord =
                    (c >= 0x41 && c <= 0x5A) ||
                    (c >= 0x61 && c <= 0x7A) ||
                    (c >= 0x30 && c <= 0x39) ||
                    c == 0x5F
                if isWord { i -= 1 } else { break }
            }
            return caret - i
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, completions: completions, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> CompletingNSTextField {
        let field = CompletingNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: CompletingNSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.text = $text
        context.coordinator.completions = completions
        context.coordinator.onCommit = onCommit
    }
}

/// NSTextField subclass that wires ⌥Esc to `complete:` as a manual
/// intellisense trigger. Plain Esc is handled by macOS's default key
/// bindings already; ⌘Space (Spotlight) and ⌃Space (input-source
/// switcher) are intentionally NOT bound.
final class CompletingNSTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌥Esc (keyCode 53 = Esc, .option modifier).
        if event.modifierFlags.contains(.option), event.keyCode == 53,
           window?.firstResponder === currentEditor() {
            currentEditor()?.complete(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
