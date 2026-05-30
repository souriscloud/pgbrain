import SwiftUI

/// Visual CREATE TABLE builder: pick a schema, name the table, add column
/// rows (name · type · NOT NULL · PK · default), and watch the SQL assemble
/// live. Only the columns the user fills in are emitted; a single table-level
/// PRIMARY KEY clause covers single or composite keys.
struct CreateTableSheet: View {
    let service: ConnectionService
    let initialSchema: String?
    let onClose: () -> Void

    @State private var schema: String = ""
    @State private var tableName: String = ""
    @State private var columns: [DraftColumn] = [DraftColumn(name: "id", type: "bigint GENERATED ALWAYS AS IDENTITY", isPrimaryKey: true)]
    @State private var error: String?
    @State private var creating = false

    struct DraftColumn: Identifiable {
        let id = UUID()
        var name: String = ""
        var type: String = "text"
        var notNull: Bool = false
        var isPrimaryKey: Bool = false
        var defaultValue: String = ""
    }

    private static let presetTypes = [
        "bigint", "integer", "smallint", "text", "varchar(255)", "boolean",
        "timestamptz", "timestamp", "date", "numeric", "double precision", "real",
        "uuid", "jsonb", "json", "bytea", "inet",
        "bigint GENERATED ALWAYS AS IDENTITY", "bigserial", "serial",
    ]

    private var schemaNames: [String] {
        let names = service.schema.schemas.map(\.name).sorted()
        return names.isEmpty ? ["public"] : names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("New table").font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                Picker("Schema", selection: $schema) {
                    ForEach(schemaNames, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 200)
                TextField("table_name", text: $tableName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(creating)
            }

            columnHeader
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($columns) { $col in
                        columnRow($col)
                    }
                }
            }
            .frame(height: 180)
            Button {
                columns.append(DraftColumn())
            } label: {
                Label("Add column", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(creating)

            Text("Preview").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(fullSQL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 92)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Create table") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!isValid || creating)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 640)
        .onAppear {
            schema = initialSchema ?? schemaNames.first ?? "public"
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text("Name").frame(width: 130, alignment: .leading)
            Text("Type").frame(width: 200, alignment: .leading)
            Text("NN").frame(width: 28)
            Text("PK").frame(width: 28)
            Text("Default").frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 22)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func columnRow(_ col: Binding<DraftColumn>) -> some View {
        HStack(spacing: 6) {
            TextField("name", text: col.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 130)
            HStack(spacing: 2) {
                TextField("type", text: col.type)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Menu {
                    ForEach(Self.presetTypes, id: \.self) { t in
                        Button(t) { col.type.wrappedValue = t }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(width: 200)
            Toggle("", isOn: col.notNull).labelsHidden().frame(width: 28)
            Toggle("", isOn: col.isPrimaryKey).labelsHidden().frame(width: 28)
            TextField("expr", text: col.defaultValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity)
            Button {
                columns.removeAll { $0.id == col.id }
            } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 22)
            .disabled(columns.count <= 1)
        }
    }

    // MARK: - SQL assembly

    private var namedColumns: [DraftColumn] {
        columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var body_: String {
        var lines: [String] = []
        for c in namedColumns {
            var line = "  \(SQLIdent.quote(c.name)) \(c.type.trimmingCharacters(in: .whitespaces).isEmpty ? "text" : c.type)"
            if c.notNull { line += " NOT NULL" }
            let def = c.defaultValue.trimmingCharacters(in: .whitespaces)
            if !def.isEmpty { line += " DEFAULT \(def)" }
            lines.append(line)
        }
        let pks = namedColumns.filter(\.isPrimaryKey).map { SQLIdent.quote($0.name) }
        if !pks.isEmpty {
            lines.append("  PRIMARY KEY (\(pks.joined(separator: ", ")))")
        }
        return lines.joined(separator: ",\n")
    }

    private var fullSQL: String {
        let name = tableName.trimmingCharacters(in: .whitespaces).isEmpty ? "table_name" : tableName
        return "CREATE TABLE \(SQLIdent.quote(schema)).\(SQLIdent.quote(name)) (\n\(body_)\n)"
    }

    private var isValid: Bool {
        !tableName.trimmingCharacters(in: .whitespaces).isEmpty && !namedColumns.isEmpty
    }

    private func run() {
        guard isValid else { return }
        let name = tableName.trimmingCharacters(in: .whitespaces)
        let targetSchema = schema
        creating = true
        error = nil
        Task {
            let result = await AdminActions.createTable(schema: targetSchema, name: name, body: body_, service: service)
            creating = false
            switch result {
            case .success:
                await service.loadSchema()
                // Open the freshly-created table if it's in the snapshot.
                if let node = service.schema.schemas.first(where: { $0.name == targetSchema })?
                    .tables.first(where: { $0.name == name }) {
                    service.workspace.openTable(node)
                }
                onClose()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}
