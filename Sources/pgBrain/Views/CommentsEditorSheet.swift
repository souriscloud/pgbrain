import SwiftUI

/// Sheet for editing one table's COMMENT and all column COMMENTs at
/// once. Loads the current values from the already-fetched `Snapshot`
/// (we hand it in rather than re-querying), diffs against the user's
/// edits on save, and only fires `COMMENT ON …` statements for what
/// actually changed.
struct CommentsEditorSheet: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var snapshot: TableInspector.Snapshot?
    @State private var tableComment: String = ""
    @State private var columnComments: [String: String] = [:]
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                        section("Table comment") {
                            TextEditor(text: $tableComment)
                                .font(.system(.body))
                                .frame(minHeight: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                        section("Columns") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(snapshot.columns, id: \.name) { col in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(col.name)
                                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                            Text(col.typeName)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                        TextField("comment", text: Binding(
                                            get: { columnComments[col.name] ?? "" },
                                            set: { columnComments[col.name] = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption))
                                    }
                                }
                            }
                        }
                    }
                    .padding(Tokens.Spacing.md)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Couldn't load table metadata")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .padding(.vertical, 6)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || snapshot == nil)
            }
            .padding(Tokens.Spacing.md)
        }
        .frame(width: 560, height: 540)
        .task { await load() }
    }

    private func load() async {
        guard let client = service.client else {
            error = "Not connected."; loading = false; return
        }
        loading = true
        do {
            let snap = try await TableInspector.fetch(client: client, schema: schema, table: table)
            self.snapshot = snap
            tableComment = snap.comment ?? ""
            columnComments = Dictionary(uniqueKeysWithValues: snap.columns.map { ($0.name, $0.comment ?? "") })
            loading = false
        } catch {
            self.error = PostgresErrorMessage.describe(error)
            loading = false
        }
    }

    private var header: some View {
        HStack {
            Text("Comments — \(schema).\(table)")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private func section<Body: View>(_ title: String, @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }

    private func save() {
        guard let snapshot else { return }
        saving = true
        Task {
            // Diff against the snapshot: only emit a COMMENT ON for
            // each field the user actually changed.
            var failures: [String] = []
            let originalTableComment = snapshot.comment ?? ""
            let newTable = tableComment
            if newTable != originalTableComment {
                let value: String? = newTable.isEmpty ? nil : newTable
                if case .failure(let err) = await AdminActions.setTableComment(
                    schema: schema, table: table, comment: value, service: service
                ) {
                    failures.append("table: \(err.localizedDescription)")
                }
            }
            for col in snapshot.columns {
                let old = col.comment ?? ""
                let new = columnComments[col.name] ?? ""
                if new != old {
                    let value: String? = new.isEmpty ? nil : new
                    if case .failure(let err) = await AdminActions.setColumnComment(
                        schema: schema, table: table, column: col.name,
                        comment: value, service: service
                    ) {
                        failures.append("\(col.name): \(err.localizedDescription)")
                    }
                }
            }
            saving = false
            if failures.isEmpty {
                onSaved()
                onClose()
            } else {
                error = failures.joined(separator: "\n")
            }
        }
    }
}
