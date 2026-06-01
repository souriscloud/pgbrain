import SwiftUI

/// What the designer is doing — building a new table, or restructuring an
/// existing one. Identifiable so it drives a `.sheet(item:)`.
struct TableDesignerRequest: Identifiable {
    let id = UUID()
    enum Mode {
        case create(schema: String?)
        case edit(TableNode)
    }
    let mode: Mode
}

/// A unified, roomy "Table Designer": a column editor on the left, a live SQL
/// preview on the right. In **create** mode it assembles a `CREATE TABLE`; in
/// **edit** mode it loads the existing structure, diffs your changes, and emits
/// the exact `ALTER TABLE` batch — applied atomically in one transaction.
struct TableDesignerView: View {
    let request: TableDesignerRequest
    let service: ConnectionService
    let onClose: () -> Void

    @State private var schema: String = ""
    @State private var tableName: String = ""
    @State private var originalTableName: String = ""
    @State private var columns: [DesignColumn] = []
    @State private var pkConstraintName: String?     // edit mode: name of the existing PK constraint
    @State private var loadedColumnNames: [String] = []   // edit mode: columns present at load (for DROP detection)
    @State private var loading = false
    @State private var loadError: String?
    @State private var applyError: String?
    @State private var applying = false

    private var isEdit: Bool {
        if case .edit = request.mode { return true }
        return false
    }

    // MARK: Column model

    struct DesignColumn: Identifiable {
        let id = UUID()
        var name: String = ""
        var type: String = "text"
        var notNull: Bool = false
        var isPrimaryKey: Bool = false
        var defaultValue: String = ""
        var comment: String = ""
        /// Snapshot of the column as it exists server-side (edit mode). `nil`
        /// means a brand-new column the user just added.
        var original: Original?

        struct Original {
            var name: String
            var type: String
            var notNull: Bool
            var isPrimaryKey: Bool
            var defaultValue: String
            var comment: String
            var isIdentity: Bool
        }
    }

    private static let presetTypes = [
        "bigint", "integer", "smallint", "text", "varchar(255)", "boolean",
        "timestamptz", "timestamp", "date", "time", "interval", "numeric",
        "double precision", "real", "uuid", "jsonb", "json", "bytea", "inet",
        "bigint GENERATED ALWAYS AS IDENTITY", "bigserial", "serial",
    ]

    private var schemaNames: [String] {
        let names = service.schema.schemas.map(\.name).sorted()
        return names.isEmpty ? ["public"] : names
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                VStack(spacing: Tokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading structure…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: Tokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    editorColumn
                    Divider()
                    previewColumn
                        .frame(width: 320)
                }
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 580)
        .task { await initialLoad() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isEdit ? "tablecells.badge.ellipsis" : "plus.rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(Tokens.Brand.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEdit ? "Edit structure" : "New table")
                    .font(.title3.weight(.semibold))
                if isEdit {
                    Text("\(schema).\(originalTableName)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isEdit {
                Picker("", selection: $schema) {
                    ForEach(schemaNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            TextField("table_name", text: $tableName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 220)
                .disabled(applying)
        }
        .padding(Tokens.Spacing.md)
    }

    // MARK: Editor column

    private var editorColumn: some View {
        VStack(spacing: 0) {
            columnHeaderRow
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($columns) { $col in
                        columnRow($col)
                    }
                }
                .padding(Tokens.Spacing.sm)
            }
            Divider()
            HStack {
                Button {
                    columns.append(DesignColumn())
                } label: {
                    Label("Add column", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(applying)
                Spacer()
                if isEdit {
                    Text("\(columns.count) column\(columns.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var columnHeaderRow: some View {
        HStack(spacing: 6) {
            Text("Name").frame(width: 140, alignment: .leading)
            Text("Type").frame(width: 180, alignment: .leading)
            Text("NN").frame(width: 26)
            Text("PK").frame(width: 26)
            Text("Default").frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 24)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func columnRow(_ col: Binding<DesignColumn>) -> some View {
        let status = columnStatus(col.wrappedValue)
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                // Status accent strip (new / modified) for edit mode.
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.color)
                    .frame(width: 3, height: 22)

                TextField("name", text: col.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 137)

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
                .frame(width: 180)

                Toggle("", isOn: col.notNull).labelsHidden().frame(width: 26)
                    .toggleStyle(.checkbox)
                Toggle("", isOn: col.isPrimaryKey).labelsHidden().frame(width: 26)
                    .toggleStyle(.checkbox)
                DefaultEditorCell(defaultValue: col.defaultValue,
                                  typeName: col.type.wrappedValue,
                                  enums: service.schema.enums)
                    .frame(maxWidth: .infinity)

                Button {
                    columns.removeAll { $0.id == col.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 24)
                .disabled(columns.count <= 1)
                .help("Remove this column" + (col.wrappedValue.original != nil ? " (DROP COLUMN)" : ""))
            }
            // Comment field — small, secondary.
            HStack(spacing: 6) {
                Spacer().frame(width: 9)
                Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.tertiary)
                TextField("comment (optional)", text: col.comment)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let badge = status.badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.color)
                }
            }
        }
        .padding(6)
        .background(status.bg, in: RoundedRectangle(cornerRadius: 6))
    }

    private struct ColStatus {
        let color: Color
        let bg: Color
        let badge: String?
    }

    private func columnStatus(_ col: DesignColumn) -> ColStatus {
        guard isEdit else { return ColStatus(color: .clear, bg: .clear, badge: nil) }
        guard let o = col.original else {
            return ColStatus(color: .green, bg: Color.green.opacity(0.07), badge: "new")
        }
        let changed = o.name != col.name
            || o.type != col.type
            || o.notNull != col.notNull
            || o.isPrimaryKey != col.isPrimaryKey
            || o.defaultValue != col.defaultValue
            || o.comment != col.comment
        return changed
            ? ColStatus(color: .orange, bg: Color.orange.opacity(0.06), badge: "modified")
            : ColStatus(color: .clear, bg: .clear, badge: nil)
    }

    // MARK: Preview column

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").font(.caption)
                Text(isEdit ? "Changes (SQL)" : "Preview").font(.caption.weight(.semibold))
                Spacer()
                if isEdit && generatedStatements.isEmpty {
                    Text("no changes").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(Tokens.Spacing.sm)
            Divider()
            ScrollView {
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.sm)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let applyError {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text(applyError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button {
                apply()
            } label: {
                if applying {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Applying…") }
                } else {
                    Text(isEdit ? "Apply changes" : "Create table")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
            .disabled(!canApply || applying)
        }
        .padding(Tokens.Spacing.md)
    }

    private var canApply: Bool {
        guard !tableName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !namedColumns.isEmpty else { return false }
        if isEdit { return !generatedStatements.isEmpty }
        return true
    }

    // MARK: Loading

    private func initialLoad() async {
        switch request.mode {
        case .create(let s):
            schema = s ?? schemaNames.first ?? "public"
            if columns.isEmpty {
                columns = [DesignColumn(name: "id", type: "bigint GENERATED ALWAYS AS IDENTITY", isPrimaryKey: true)]
            }
        case .edit(let node):
            schema = node.schema
            tableName = node.name
            originalTableName = node.name
            await loadExisting(node)
        }
    }

    private func loadExisting(_ node: TableNode) async {
        guard let client = service.client else { loadError = "Not connected"; return }
        loading = true
        defer { loading = false }
        do {
            let snap = try await TableInspector.fetch(client: client, schema: node.schema, table: node.name)
            let pkCols = Set(node.primaryKey)
            pkConstraintName = snap.constraints.first { $0.kind == "p" }?.name
            loadedColumnNames = snap.columns.sorted { $0.ordinal < $1.ordinal }.map(\.name)
            columns = snap.columns
                .sorted { $0.ordinal < $1.ordinal }
                .map { c in
                    let isPK = pkCols.contains(c.name)
                    let isIdentity = c.identity != nil
                    let original = DesignColumn.Original(
                        name: c.name, type: c.typeName, notNull: !c.nullable,
                        isPrimaryKey: isPK, defaultValue: c.defaultExpr ?? "",
                        comment: c.comment ?? "", isIdentity: isIdentity
                    )
                    return DesignColumn(
                        name: c.name, type: c.typeName, notNull: !c.nullable,
                        isPrimaryKey: isPK, defaultValue: c.defaultExpr ?? "",
                        comment: c.comment ?? "", original: original
                    )
                }
        } catch {
            loadError = PostgresErrorMessage.describe(error)
        }
    }

    // MARK: SQL assembly

    private var namedColumns: [DesignColumn] {
        columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var previewText: String {
        if isEdit {
            let stmts = generatedStatements
            return stmts.isEmpty ? "-- No changes yet." : stmts.map { $0 + ";" }.joined(separator: "\n\n")
        }
        return createSQL + ";"
    }

    /// CREATE TABLE body + statement (create mode).
    private var createSQL: String {
        var lines: [String] = []
        for c in namedColumns {
            var line = "  \(SQLIdent.quote(c.name)) \(typeOrDefault(c.type))"
            if c.notNull { line += " NOT NULL" }
            let def = c.defaultValue.trimmingCharacters(in: .whitespaces)
            if !def.isEmpty { line += " DEFAULT \(def)" }
            lines.append(line)
        }
        let pks = namedColumns.filter(\.isPrimaryKey).map { SQLIdent.quote($0.name) }
        if !pks.isEmpty { lines.append("  PRIMARY KEY (\(pks.joined(separator: ", ")))") }
        let name = tableName.trimmingCharacters(in: .whitespaces).isEmpty ? "table_name" : tableName
        return "CREATE TABLE \(SQLIdent.quote(schema)).\(SQLIdent.quote(name)) (\n\(lines.joined(separator: ",\n"))\n)"
    }

    private func typeOrDefault(_ t: String) -> String {
        t.trimmingCharacters(in: .whitespaces).isEmpty ? "text" : t
    }

    /// The ordered ALTER batch (edit mode). Each entry is a full statement
    /// without a trailing semicolon.
    private var generatedStatements: [String] {
        guard isEdit else { return [] }
        let qualified = SQLIdent.quote(schema) + "." + SQLIdent.quote(originalTableName)
        var out: [String] = []

        // 1. Column renames first, so later actions use the new names.
        for c in namedColumns {
            guard let o = c.original, o.name != c.name else { continue }
            out.append("ALTER TABLE \(qualified) RENAME COLUMN \(SQLIdent.quote(o.name)) TO \(SQLIdent.quote(c.name))")
        }

        // 2. Drops — columns that existed at load but the user removed.
        let survivingOriginals = Set(columns.compactMap { $0.original?.name })
        for orig in loadedColumnNames where !survivingOriginals.contains(orig) {
            out.append("ALTER TABLE \(qualified) DROP COLUMN \(SQLIdent.quote(orig))")
        }

        // 3. Adds — new columns.
        for c in namedColumns where c.original == nil {
            var line = "ALTER TABLE \(qualified) ADD COLUMN \(SQLIdent.quote(c.name)) \(typeOrDefault(c.type))"
            let def = c.defaultValue.trimmingCharacters(in: .whitespaces)
            if !def.isEmpty { line += " DEFAULT \(def)" }
            if c.notNull { line += " NOT NULL" }
            out.append(line)
        }

        // 4. Type / nullability / default changes on existing columns (new name).
        for c in namedColumns {
            guard let o = c.original else { continue }
            if o.type != c.type {
                out.append("ALTER TABLE \(qualified) ALTER COLUMN \(SQLIdent.quote(c.name)) TYPE \(typeOrDefault(c.type)) USING \(SQLIdent.quote(c.name))::\(typeOrDefault(c.type))")
            }
            if o.notNull != c.notNull {
                out.append("ALTER TABLE \(qualified) ALTER COLUMN \(SQLIdent.quote(c.name)) \(c.notNull ? "SET" : "DROP") NOT NULL")
            }
            let def = c.defaultValue.trimmingCharacters(in: .whitespaces)
            if o.defaultValue.trimmingCharacters(in: .whitespaces) != def {
                out.append(def.isEmpty
                    ? "ALTER TABLE \(qualified) ALTER COLUMN \(SQLIdent.quote(c.name)) DROP DEFAULT"
                    : "ALTER TABLE \(qualified) ALTER COLUMN \(SQLIdent.quote(c.name)) SET DEFAULT \(def)")
            }
        }

        // 5. Primary-key change.
        let newPK = namedColumns.filter(\.isPrimaryKey).map(\.name)
        let oldPK = columns.compactMap { $0.original }.filter(\.isPrimaryKey).map(\.name)
        if newPK != oldPK {
            if let pkName = pkConstraintName, !oldPK.isEmpty {
                out.append("ALTER TABLE \(qualified) DROP CONSTRAINT \(SQLIdent.quote(pkName))")
            }
            if !newPK.isEmpty {
                out.append("ALTER TABLE \(qualified) ADD PRIMARY KEY (\(newPK.map { SQLIdent.quote($0) }.joined(separator: ", ")))")
            }
        }

        // 6. Comment changes.
        for c in namedColumns {
            guard let o = c.original else {
                let cm = c.comment.trimmingCharacters(in: .whitespaces)
                if !cm.isEmpty {
                    out.append("COMMENT ON COLUMN \(qualified).\(SQLIdent.quote(c.name)) IS '\(sqlEscape(cm))'")
                }
                continue
            }
            if o.comment != c.comment {
                let cm = c.comment.trimmingCharacters(in: .whitespaces)
                out.append(cm.isEmpty
                    ? "COMMENT ON COLUMN \(qualified).\(SQLIdent.quote(c.name)) IS NULL"
                    : "COMMENT ON COLUMN \(qualified).\(SQLIdent.quote(c.name)) IS '\(sqlEscape(cm))'")
            }
        }

        // 7. Table rename last.
        let trimmedName = tableName.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty, trimmedName != originalTableName {
            out.append("ALTER TABLE \(qualified) RENAME TO \(SQLIdent.quote(trimmedName))")
        }
        return out
    }

    private func sqlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: Apply

    private func apply() {
        applying = true
        applyError = nil
        Task {
            let result: Result<Void, Error>
            let targetSchema = schema
            let finalName = tableName.trimmingCharacters(in: .whitespaces)
            switch request.mode {
            case .create:
                let body = createTableBody()
                result = await AdminActions.createTable(schema: targetSchema, name: finalName, body: body, service: service)
            case .edit:
                result = await AdminActions.executeBatch(
                    generatedStatements,
                    summary: "Alter \(targetSchema).\(originalTableName) (\(generatedStatements.count) change\(generatedStatements.count == 1 ? "" : "s"))",
                    service: service
                )
            }
            applying = false
            switch result {
            case .success:
                service.toasts.show(.success, isEdit ? "Updated \(targetSchema).\(finalName)" : "Created \(targetSchema).\(finalName)")
                await service.loadSchema()
                if let node = service.schema.schemas.first(where: { $0.name == targetSchema })?
                    .tables.first(where: { $0.name == finalName }) {
                    service.workspace.openTable(node)
                }
                onClose()
            case .failure(let err):
                applyError = err.localizedDescription
            }
        }
    }

    /// CREATE TABLE inner body (without the wrapping statement) for AdminActions.
    private func createTableBody() -> String {
        var lines: [String] = []
        for c in namedColumns {
            var line = "  \(SQLIdent.quote(c.name)) \(typeOrDefault(c.type))"
            if c.notNull { line += " NOT NULL" }
            let def = c.defaultValue.trimmingCharacters(in: .whitespaces)
            if !def.isEmpty { line += " DEFAULT \(def)" }
            lines.append(line)
        }
        let pks = namedColumns.filter(\.isPrimaryKey).map { SQLIdent.quote($0.name) }
        if !pks.isEmpty { lines.append("  PRIMARY KEY (\(pks.joined(separator: ", ")))") }
        return lines.joined(separator: ",\n")
    }
}

/// Default-value cell for the designer grid: a raw expression field plus a
/// typed-editor popover that writes a SQL fragment back into it. Keeps the
/// dense row compact while still offering date/enum/now()/expression pickers.
private struct DefaultEditorCell: View {
    @Binding var defaultValue: String
    let typeName: String
    let enums: [String: [String]]
    @State private var show = false
    @State private var typed: TypedInputValue = .literal("")

    var body: some View {
        HStack(spacing: 2) {
            TextField("expr", text: $defaultValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity)
            Button {
                typed = defaultValue.isEmpty ? .literal("") : .expression(defaultValue)
                show = true
            } label: {
                Image(systemName: "slider.horizontal.3").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Build a typed default")
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    Text("Default for \(typeName.isEmpty ? "column" : typeName)")
                        .font(.caption.weight(.semibold))
                    TypedValueEditor(typeName: typeName, nullable: true, enums: enums,
                                     allowsDefault: false, allowsExpression: true, value: $typed)
                    HStack {
                        Button("Clear") { defaultValue = ""; show = false }
                        Spacer()
                        Button("Use") {
                            defaultValue = typed.sqlFragment(typeName: typeName, cast: false)
                            show = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(Tokens.Spacing.md)
                .frame(width: 320)
            }
        }
    }
}
