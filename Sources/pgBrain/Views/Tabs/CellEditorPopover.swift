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
        popover.behavior = .transient
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
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
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
