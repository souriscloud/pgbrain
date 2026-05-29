import SwiftUI

/// Single-row "form" view of a result page — DataGrip's form mode. Shows
/// one row as a vertical list of label + value fields, with ← / → to
/// step between rows. When an `EditBuffer` is supplied the value fields
/// are editable and write through to the same buffer the grid uses, so
/// edits made in either view share one dirty set + Apply path.
struct RowFormView: View {
    let page: RowsFetcher.Page
    /// Visible-row → source-row mapping (same contract as DataGridView).
    let sourceIndices: [Int]
    @Binding var rowIndex: Int
    let editBuffer: EditBuffer?

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
        .onAppear { clampIndex() }
        .onChange(of: page.rows.count) { _, _ in clampIndex() }
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button { rowIndex = max(0, rowIndex - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(rowIndex <= 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous row (←)")
            Text("Row \(rowIndex + 1) of \(page.rows.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button { rowIndex = min(page.rows.count - 1, rowIndex + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(rowIndex >= page.rows.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next row (→)")
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func fieldRow(col: Int, column: ColumnNode) -> some View {
        let visibleRow = min(rowIndex, max(0, page.rows.count - 1))
        let sourceRow = sourceIndices.indices.contains(visibleRow) ? sourceIndices[visibleRow] : visibleRow
        let serverValue = page.rows.indices.contains(visibleRow) ? page.rows[visibleRow][col] : nil
        let pending = editBuffer?.value(row: sourceRow, column: col)
        let displayed: String? = pending.flatMap { $0 } ?? serverValue
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

            if let editBuffer {
                TextField("", text: Binding(
                    get: { displayed ?? "" },
                    set: { newVal in
                        if newVal == (serverValue ?? "") {
                            editBuffer.clearCell(row: sourceRow, column: col)
                        } else {
                            editBuffer.set(row: sourceRow, column: col, value: newVal)
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .overlay(alignment: .trailing) {
                    if isDirty {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).padding(.trailing, 6)
                    }
                }
            } else {
                Text(displayed ?? "NULL")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(displayed == nil ? .secondary : .primary)
                    .italic(displayed == nil)
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
