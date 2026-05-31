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
    let completions: (String) -> [CompletionItem]
    let onCommit: () -> Void

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var completions: (String) -> [CompletionItem]
        var onCommit: () -> Void
        /// String length on the previous tick — distinguishes
        /// insertions from deletions so we don't open the popup
        /// while the user is backspacing.
        var previousLength = 0
        var completionDebounce: Task<Void, Never>?
        /// The custom completion controller, bound to the field editor.
        /// Re-created if the shared field editor instance changes.
        private var controller: CompletionController?
        private weak var boundEditor: NSTextView?

        init(text: Binding<String>, completions: @escaping (String) -> [CompletionItem], onCommit: @escaping () -> Void) {
            self.text = text
            self.completions = completions
            self.onCommit = onCommit
        }

        private func ensureController(for editor: NSTextView) -> CompletionController {
            if let controller, boundEditor === editor { return controller }
            let c = CompletionController(textView: editor) { [weak self] partial, _, _ in
                self?.completions(partial) ?? []
            }
            controller = c
            boundEditor = editor
            return c
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            text.wrappedValue = field.stringValue
            let controller = ensureController(for: editor)
            controller.refreshIfVisible()
            // As-you-type: 180ms after the last forward keystroke on a
            // ≥2-char identifier.
            let currentLength = (editor.string as NSString).length
            let grew = currentLength > previousLength
            previousLength = currentLength
            completionDebounce?.cancel()
            guard grew else { return }
            let ns = editor.string as NSString
            let caret = editor.selectedRange().location
            guard caret > 0, caret <= ns.length, isWordChar(ns.character(at: caret - 1)) else { return }
            guard identifierPrefixLength(in: editor) >= 2 else { return }
            completionDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
                self?.controller?.requestCompletion()
            }
        }

        private func isWordChar(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
            (c >= 0x30 && c <= 0x39) || c == 0x5F
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            controller?.cancel()
            onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let controller = ensureController(for: textView)
            // Esc / ⌘Space toggle the popup; nav keys drive it while open.
            if commandSelector == #selector(NSStandardKeyBindingResponding.complete(_:)) {
                if controller.isVisible { controller.cancel() } else { controller.requestCompletion() }
                return true
            }
            return controller.handleCommand(commandSelector)
        }

        private func identifierPrefixLength(in editor: NSTextView) -> Int {
            let ns = editor.string as NSString
            let caret = editor.selectedRange().location
            guard caret > 0, caret <= ns.length else { return 0 }
            var i = caret
            while i > 0, isWordChar(ns.character(at: i - 1)) { i -= 1 }
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

/// NSTextField host for the completing strip. Esc (the default NSTextView
/// binding for `complete:`) is routed through the coordinator's
/// `doCommandBy` to toggle the custom completion panel — no native popup.
final class CompletingNSTextField: NSTextField {}
