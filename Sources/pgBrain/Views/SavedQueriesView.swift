import SwiftUI

/// Sheet listing every saved SQL snippet with search-as-you-type.
/// Inserts the chosen SQL into the host scratchpad. The "Save current
/// scratchpad" button captures whatever's in the editor as a new entry.
struct SavedQueriesView: View {
    @Bindable var notebook: Notebook
    let onClose: () -> Void

    @State private var store = SavedQueryStore.shared
    @State private var search = ""
    @State private var draft: SavedQuery?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 480)
        .sheet(item: $draft) { existing in
            EditSavedQuerySheet(query: existing) { saved in
                store.upsert(saved)
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "books.vertical")
            TextField("Search saved queries", text: $search)
                .textFieldStyle(.roundedBorder)
            Button("Save current notebook") {
                let trimmed = notebook.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                draft = SavedQuery(name: "Query \(store.queries.count + 1)", sql: trimmed)
            }
            .disabled(notebook.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Tokens.Spacing.md)
    }

    private var content: some View {
        let items = store.matching(search)
        return List(items) { q in
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.name).font(.body.weight(.medium))
                    if !q.notes.isEmpty {
                        Text(q.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(preview(q.sql))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Edit") { draft = q }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Insert") {
                    // Replace the document text wholesale. The text storage
                    // is owned by the notebook so the live NSTextView picks
                    // up the change immediately.
                    let attributed = NSMutableAttributedString(string: q.sql)
                    if let font = NSFont(name: "Menlo", size: CGFloat(AppSettings.shared.editorFontSize)) {
                        attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length))
                    }
                    notebook.textStorage.beginEditing()
                    notebook.textStorage.setAttributedString(attributed)
                    notebook.textStorage.endEditing()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Tokens.Brand.primary)
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Delete", role: .destructive) {
                    store.remove(id: q.id)
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text("\(store.queries.count) saved")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close") { onClose() }
        }
        .padding(Tokens.Spacing.md)
    }

    private func preview(_ sql: String) -> String {
        let collapsed = sql
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
    }
}

private struct EditSavedQuerySheet: View {
    @State var query: SavedQuery
    let onSave: (SavedQuery) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Edit saved query")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $query.name)
                TextField("Notes", text: $query.notes, axis: .vertical)
                    .lineLimit(2...4)
                Text("SQL")
                    .font(.caption.weight(.semibold))
                TextEditor(text: $query.sql)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Corner.chip)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(query) }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
                    .disabled(query.name.isEmpty || query.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 520, height: 480)
    }
}
