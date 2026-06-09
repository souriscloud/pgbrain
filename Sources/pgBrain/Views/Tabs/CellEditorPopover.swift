import AppKit
import SwiftUI

/// Popover-based cell editor. Thin host around the app-wide
/// `TypedValueEditor`, so a grid cell edits through the exact same typed
/// control family as every dialog and form — date/time pickers, enum
/// dropdowns, a syntax-highlighted JSON editor, plus the mode menu for
/// `NULL` / `DEFAULT` / `now()` / raw SQL expressions.
///
/// `onCommit` receives a `TypedInputValue`; the caller maps it into the
/// edit buffer.
@MainActor
enum CellEditorPopover {
    /// True while a cell-edit popover is on screen. The data grid reads
    /// this so its key-equivalent handler (⌘C / ⌘Z / ⌃⌘N) stands down
    /// while a cell is being edited — otherwise ⌘C inside the popover is
    /// grabbed by the table and copies the whole row instead of the
    /// editor's selection. The popover is `.semitransient`, so the parent
    /// table window stays key and would otherwise win the key equivalent.
    static private(set) var isPresenting = false

    /// Strongly held so the popover's weak `delegate` survives; flips
    /// `isPresenting` back off on any close path (Save / Cancel / Esc /
    /// click-away).
    private final class CloseObserver: NSObject, NSPopoverDelegate {
        func popoverDidClose(_ notification: Notification) {
            CellEditorPopover.isPresenting = false
        }
    }
    private static let closeObserver = CloseObserver()

    #if DEBUG
    /// Test seam: drive the presenting flag without spinning up a real
    /// popover + window, so the grid's key-equivalent gating can be
    /// exercised headlessly under `swift test`.
    static func _setPresentingForTesting(_ value: Bool) { isPresenting = value }
    #endif

    static func show(
        for column: ColumnNode,
        initial: TypedInputValue,
        enums: [String: [String]],
        completions: ((String, String, Int) -> [CompletionItem])? = nil,
        relativeTo rect: NSRect,
        of view: NSView,
        onCommit: @escaping (TypedInputValue) -> Void
    ) {
        let popover = NSPopover()
        // Semi-transient so clicking the schema-completion panel (a separate
        // child window) doesn't dismiss the editor; it still closes when you
        // click elsewhere in the host window, or via Save / Cancel / Esc.
        popover.behavior = .semitransient
        popover.animates = true

        let host = NSHostingController(
            rootView: PopoverEditor(
                column: column,
                enums: enums,
                completions: completions,
                initial: initial,
                onSave: { v in onCommit(v); popover.close() },
                onCancel: { popover.close() }
            )
        )
        let kind = InputKind.resolve(typeName: column.typeName, enums: enums)
        switch kind {
        case .json:           host.preferredContentSize = NSSize(width: 500, height: 380)
        case .timestamp, .date, .time: host.preferredContentSize = NSSize(width: 340, height: 210)
        case .boolean:        host.preferredContentSize = NSSize(width: 300, height: 170)
        case .enumType:       host.preferredContentSize = NSSize(width: 320, height: 180)
        default:              host.preferredContentSize = NSSize(width: 380, height: 190)
        }
        popover.contentViewController = host
        popover.delegate = closeObserver
        isPresenting = true
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)

        // Hand the popover its own key focus. Popovers don't take key on
        // their own, so without this the parent grid window stays key:
        // Tab wouldn't cycle the editor's fields and ⌘C would route to the
        // grid (copying the row). Making the popover window key — and
        // selecting its first field — gives a proper edit context where
        // Tab / ⌘C / typing all act on the editor. Still semitransient, so
        // outside-click / Esc dismiss it as before.
        if let window = host.view.window {
            window.makeKey()
            window.recalculateKeyViewLoop()
            window.selectNextKeyView(nil)
        }
    }
}

private struct PopoverEditor: View {
    let column: ColumnNode
    let enums: [String: [String]]
    let completions: ((String, String, Int) -> [CompletionItem])?
    let initial: TypedInputValue
    let onSave: (TypedInputValue) -> Void
    let onCancel: () -> Void

    @State private var value: TypedInputValue

    init(column: ColumnNode, enums: [String: [String]],
         completions: ((String, String, Int) -> [CompletionItem])?, initial: TypedInputValue,
         onSave: @escaping (TypedInputValue) -> Void, onCancel: @escaping () -> Void) {
        self.column = column
        self.enums = enums
        self.completions = completions
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _value = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(column.name)
                .font(.system(.callout, weight: .semibold))

            Divider()

            TypedValueEditor(
                typeName: column.typeName,
                nullable: column.nullable,
                enums: enums,
                allowsDefault: true,
                allowsExpression: true,
                completions: completions,
                value: $value
            )

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(value) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
            }
        }
        .padding(Tokens.Spacing.md)
        .frame(minWidth: 280)
    }
}
