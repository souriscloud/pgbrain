import AppKit
import SwiftUI

/// Single-row "form" view of a result page — DataGrip's form mode. Shows
/// one row as a vertical list of label + value fields. When an `EditBuffer`
/// is supplied the fields write through to the same buffer the grid uses,
/// so both views share one dirty set, undo history and Apply path.
///
/// ← / → step between rows only while no text field has focus (they move
/// the caret otherwise); ⌥⌘↑ / ⌥⌘↓ step from anywhere.
struct RowFormView: View {
    let page: RowsFetcher.Page
    /// Visible-row → source-row mapping (same contract as DataGridView).
    let sourceIndices: [Int]
    @Binding var rowIndex: Int
    let editBuffer: EditBuffer?
    var insertRowIndices: Set<Int> = []
    var deleteRowIndices: Set<Int> = []
    var enums: [String: [String]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            if page.rows.isEmpty {
                Text("No rows").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(page.columns.enumerated()), id: \.offset) { (col, column) in
                            fieldRow(col: col, column: column)
                            if col < page.columns.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                    .padding(Tokens.Spacing.md)
                }
            }
        }
        .background(FormArrowKeyMonitor(onStep: step))
        .onAppear { clampIndex() }
        .onChange(of: page.rows.count) { _, _ in clampIndex() }
    }

    private func step(_ delta: Int) {
        guard !page.rows.isEmpty else { return }
        rowIndex = max(0, min(page.rows.count - 1, rowIndex + delta))
    }

    private var currentSource: Int {
        let visible = min(rowIndex, max(0, page.rows.count - 1))
        return sourceIndices.indices.contains(visible) ? sourceIndices[visible] : visible
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(rowIndex <= 0)
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .help("Previous row (← or ⌥⌘↑)")
            Text("Row \(rowIndex + 1) of \(page.rows.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(rowIndex >= page.rows.count - 1)
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .help("Next row (→ or ⌥⌘↓)")
            if insertRowIndices.contains(currentSource) {
                Label("New row", systemImage: "sparkle").font(.caption).foregroundStyle(.green)
            } else if deleteRowIndices.contains(currentSource) {
                Label("Staged for deletion", systemImage: "trash").font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func fieldRow(col: Int, column: ColumnNode) -> some View {
        let visibleRow = min(rowIndex, max(0, page.rows.count - 1))
        let sourceRow = currentSource
        let row = page.rows.indices.contains(visibleRow) ? page.rows[visibleRow] : []
        let serverValue = col < row.count ? row[col] : nil
        let isDraft = insertRowIndices.contains(sourceRow)
        let isDeleted = deleteRowIndices.contains(sourceRow)
        let isDirty = editBuffer?.isDirty(row: sourceRow, column: col) ?? false

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(column.name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .multilineTextAlignment(.trailing)
                Text(column.typeName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 160, alignment: .trailing)

            if let editBuffer, !isDeleted {
                TypedValueEditor(
                    typeName: column.typeName,
                    nullable: column.nullable,
                    enums: enums,
                    allowsDefault: true,
                    allowsExpression: true,
                    compact: true,
                    value: Binding(
                        get: {
                            if let entry = editBuffer.entry(row: sourceRow, column: col) { return entry.typed }
                            return isDraft ? .defaultKeyword : TypedInputValue(serverValue: serverValue)
                        },
                        set: { typed in
                            let untouched = isDraft ? typed == .defaultKeyword : typed.isNoOp(against: serverValue)
                            if untouched {
                                editBuffer.clearCell(row: sourceRow, column: col, coalesce: true)
                            } else {
                                editBuffer.set(row: sourceRow, column: col, typed: typed, coalesce: true)
                            }
                        }
                    )
                )
                // Re-hydrate the editor's draft when the form steps to another
                // row, or when undo / redo changes the staged value.
                .id("\(sourceRow)-\(col)-\(editBuffer.externalRevision)")
                .overlay(alignment: .topTrailing) {
                    if isDirty {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).padding(.top, 2)
                    }
                }
            } else {
                let shown: String? = editBuffer?.entry(row: sourceRow, column: col)?.displayValue ?? serverValue
                Text(shown ?? "NULL")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(shown == nil ? .secondary : .primary)
                    .italic(shown == nil)
                    .strikethrough(isDeleted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
    }

    private func clampIndex() {
        if rowIndex >= page.rows.count { rowIndex = max(0, page.rows.count - 1) }
        if rowIndex < 0 { rowIndex = 0 }
    }
}

/// Plain ← / → step rows only when the keystroke isn't aimed at a text
/// field — a SwiftUI shortcut would steal them from the caret.
private struct FormArrowKeyMonitor: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.onStep = onStep
        return v
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onStep = onStep
    }

    final class MonitorView: NSView {
        var onStep: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      event.keyCode == 123 || event.keyCode == 124,
                      !(window.firstResponder is NSText)
                else { return event }
                self.onStep?(event.keyCode == 123 ? -1 : 1)
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
