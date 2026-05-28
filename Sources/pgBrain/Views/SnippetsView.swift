import SwiftUI

/// Sheet-style snippet library. Two panes: a list of named snippets on
/// the left, an editor on the right. Save/Insert/Delete buttons live in
/// the editor pane footer.
///
/// `onInsert` fires when the user picks Insert — the host wires this
/// into the currently focused scratchpad cell so the expanded body
/// (with `$cursor$` resolved) lands at the caret.
struct SnippetsView: View {
    @Bindable var store = SnippetStore.shared
    let onInsert: ((String) -> Void)?
    let onClose: () -> Void

    @State private var selectedID: UUID?
    @State private var nameDraft: String = ""
    @State private var bodyDraft: String = ""
    @State private var creating = false

    private var selected: Snippet? {
        guard let id = selectedID else { return nil }
        return store.snippets.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listPane
                    .frame(minWidth: 220, idealWidth: 240)
                editorPane
                    .frame(minWidth: 400, maxWidth: .infinity)
            }
        }
        .frame(width: 800, height: 520)
    }

    private var header: some View {
        HStack {
            Text("Snippets").font(.title3.weight(.semibold))
            Text("(\(store.snippets.count))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private var listPane: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.snippets) { snip in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snip.name).font(.callout.weight(.medium))
                        Text(preview(snip.body))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(snip.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button {
                    creating = true
                    selectedID = nil
                    nameDraft = ""
                    bodyDraft = ""
                } label: {
                    Image(systemName: "plus")
                }
                .help("New snippet")
                Spacer()
                if let id = selectedID {
                    Button(role: .destructive) {
                        store.delete(id: id)
                        selectedID = nil
                        creating = false
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Delete snippet")
                }
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .onChange(of: selectedID) { _, newID in
            if let id = newID, let s = store.snippets.first(where: { $0.id == id }) {
                creating = false
                nameDraft = s.name
                bodyDraft = s.body
            }
        }
        .onAppear {
            if let first = store.snippets.first {
                selectedID = first.id
            }
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if creating || selected != nil {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    TextField("Snippet name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("SQL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("placeholders: $cursor$ · $1$")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        TextEditor(text: $bodyDraft)
                            .font(.system(.body, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                            )
                            .frame(minHeight: 220)
                    }
                }
                .padding(Tokens.Spacing.md)
                Divider()
                HStack {
                    if let onInsert, !creating, selected != nil {
                        Button {
                            let expanded = SnippetStore.expand(bodyDraft).text
                            onInsert(expanded)
                            onClose()
                        } label: {
                            Label("Insert into scratchpad", systemImage: "text.append")
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                    }
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty || bodyDraft.isEmpty)
                }
                .padding(Tokens.Spacing.md)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Pick a snippet or create a new one").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func save() {
        if creating {
            store.add(name: nameDraft, body: bodyDraft)
            creating = false
            if let added = store.snippets.first(where: { $0.name == nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                selectedID = added.id
            }
        } else if let id = selectedID {
            store.update(id: id, name: nameDraft, body: bodyDraft)
        }
    }

    private func preview(_ body: String) -> String {
        body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
