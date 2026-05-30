import SwiftUI

/// Visual CREATE INDEX builder for a table: tick columns (selection order is
/// index order), choose UNIQUE + the access method, optionally a partial
/// WHERE, and watch the SQL assemble. Mirrors the create-table sheet's shape.
struct CreateIndexSheet: View {
    let service: ConnectionService
    let table: TableNode
    let onClose: () -> Void

    @State private var columns: [ColumnNode] = []
    @State private var selected: [String] = []          // ordered → index column order
    @State private var indexName: String = ""
    @State private var nameEdited = false
    @State private var unique = false
    @State private var method = "btree"
    @State private var whereClause = ""
    @State private var error: String?
    @State private var creating = false
    @State private var loadingColumns = true

    private let methods = ["btree", "hash", "gin", "gist", "brin", "spgist"]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("New index on \(table.schema).\(table.name)")
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                TextField("index_name", text: $indexName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(creating)
                    .onChange(of: indexName) { _, _ in nameEdited = true }
                Toggle("Unique", isOn: $unique).toggleStyle(.checkbox)
                Picker("Method", selection: $method) {
                    ForEach(methods, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 150)
            }

            Text("Columns (tick in index order)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if loadingColumns {
                    HStack { ProgressView().controlSize(.small); Text("Loading columns…").font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(columns, id: \.name) { col in
                            columnRow(col)
                        }
                    }
                }
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            HStack(spacing: 6) {
                Text("WHERE").font(.caption.monospaced()).foregroundStyle(.secondary)
                TextField("optional partial-index predicate", text: $whereClause)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(creating)
            }

            Text("Preview").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(fullSQL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 60)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Create index") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!isValid || creating)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 560)
        .task { await loadColumns() }
    }

    private func columnRow(_ col: ColumnNode) -> some View {
        let idx = selected.firstIndex(of: col.name)
        return HStack(spacing: 8) {
            Image(systemName: idx != nil ? "checkmark.square.fill" : "square")
                .foregroundStyle(idx != nil ? Color.accentColor : .secondary)
            Text(col.name).font(.system(.caption, design: .monospaced))
            Text(col.typeName).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let idx { Text("\(idx + 1)").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { toggle(col.name) }
    }

    private func toggle(_ name: String) {
        if let i = selected.firstIndex(of: name) {
            selected.remove(at: i)
        } else {
            selected.append(name)
        }
        if !nameEdited { indexName = suggestedName; nameEdited = false }
    }

    private var suggestedName: String {
        let cols = selected.isEmpty ? "" : "_" + selected.joined(separator: "_")
        return "\(table.name)\(cols)_idx"
    }

    private var fullSQL: String {
        let name = indexName.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName : indexName
        let cols = selected.map { SQLIdent.quote($0) }.joined(separator: ", ")
        var sql = "CREATE \(unique ? "UNIQUE " : "")INDEX \(SQLIdent.quote(name)) "
        sql += "ON \(SQLIdent.quote(table.schema)).\(SQLIdent.quote(table.name)) "
        sql += "USING \(method) (\(cols.isEmpty ? "…" : cols))"
        let w = whereClause.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty { sql += " WHERE \(w)" }
        return sql
    }

    private var isValid: Bool {
        !selected.isEmpty && !indexName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadColumns() async {
        let enriched = await service.ensureColumns(for: table)
        columns = enriched.columns
        loadingColumns = false
    }

    private func run() {
        guard isValid else { return }
        let name = indexName.trimmingCharacters(in: .whitespaces)
        creating = true
        error = nil
        Task {
            let result = await AdminActions.execute(fullSQL, summary: "CREATE INDEX \(name)", service: service)
            creating = false
            switch result {
            case .success:
                await service.loadSchema()
                onClose()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}
