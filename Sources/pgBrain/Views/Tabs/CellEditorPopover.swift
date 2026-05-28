import AppKit
import SwiftUI

/// Popover-based cell editor with type-aware input. Replaces inline
/// NSTextField editing for PK-bearing tables.
///
///   - bool          → segmented `true | false` picker
///   - date          → `DatePicker(.date)`
///   - timestamp     → `DatePicker([.date, .hourAndMinute])`
///   - json/jsonb    → multiline monospaced editor (~300pt tall)
///   - integer/number → numeric field, right-aligned
///   - text/uuid/…    → plain text field
///
/// Plus a "Set NULL" button (only when `column.nullable`) and Cancel /
/// Save. Save calls `onCommit` with the new value; "Set NULL" calls
/// `onCommit(nil)`; Cancel calls `onCancel`.
@MainActor
enum CellEditorPopover {
    static func show(
        for column: ColumnNode,
        currentValue: String?,
        relativeTo rect: NSRect,
        of view: NSView,
        onCommit: @escaping (String?) -> Void
    ) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let kind = ColumnTypeKind.from(typeName: column.typeName)
        let host = NSHostingController(
            rootView: TypedEditor(
                column: column,
                kind: kind,
                initialValue: currentValue,
                onSave: { newValue in
                    onCommit(newValue)
                    popover.close()
                },
                onSetNull: column.nullable ? {
                    onCommit(nil)
                    popover.close()
                } : nil,
                onCancel: { popover.close() }
            )
        )
        // Width grows with column type (JSON needs more room).
        switch kind {
        case .json:        host.preferredContentSize = NSSize(width: 480, height: 360)
        case .timestamp:   host.preferredContentSize = NSSize(width: 320, height: 200)
        case .date:        host.preferredContentSize = NSSize(width: 280, height: 170)
        case .bool:        host.preferredContentSize = NSSize(width: 240, height: 150)
        default:           host.preferredContentSize = NSSize(width: 360, height: 170)
        }
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}

private struct TypedEditor: View {
    let column: ColumnNode
    let kind: ColumnTypeKind
    let initialValue: String?
    let onSave: (String) -> Void
    let onSetNull: (() -> Void)?
    let onCancel: () -> Void

    @State private var text: String
    @State private var date: Date
    @State private var bool: Bool

    init(column: ColumnNode, kind: ColumnTypeKind, initialValue: String?,
         onSave: @escaping (String) -> Void,
         onSetNull: (() -> Void)?,
         onCancel: @escaping () -> Void) {
        self.column = column
        self.kind = kind
        self.initialValue = initialValue
        self.onSave = onSave
        self.onSetNull = onSetNull
        self.onCancel = onCancel
        let raw = initialValue ?? ""
        _text = State(initialValue: raw)
        _date = State(initialValue: Self.parseDate(raw) ?? Date())
        _bool = State(initialValue: Self.parseBool(raw) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            // Header — column name + PG type tag.
            HStack(spacing: 6) {
                Text(column.name)
                    .font(.system(.callout, weight: .semibold))
                Text(column.typeName.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if initialValue == nil {
                    Text("NULL")
                        .font(.caption2.italic())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            Divider()

            // Type-specific editor.
            editor

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if let onSetNull {
                    Button("Set NULL", action: onSetNull)
                        .keyboardShortcut("0", modifiers: [.command, .shift])
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
            }
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private var editor: some View {
        switch kind {
        case .bool:
            Picker("", selection: $bool) {
                Text("true").tag(true)
                Text("false").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .date:
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
        case .timestamp:
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
        case .json:
            VStack(alignment: .leading, spacing: 4) {
                Text("JSON")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                    .frame(minHeight: 220)
            }
        case .integer, .number:
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
        default:
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func commit() {
        switch kind {
        case .bool:
            onSave(bool ? "true" : "false")
        case .date:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            onSave(f.string(from: date))
        case .timestamp:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            onSave(f.string(from: date))
        default:
            onSave(text)
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formats = ["yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
        for fmt in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "t", "true", "1", "yes", "y", "on": return true
        case "f", "false", "0", "no", "n", "off": return false
        default: return nil
        }
    }
}
