import SwiftUI
import PostgresNIO

/// Drives a `.sheet(item:)` for the function designer — create a new routine or
/// restructure an existing one.
struct FunctionDesignerRequest: Identifiable {
    let id = UUID()
    enum Mode {
        case create(schema: String?)
        case edit(FunctionNode)
    }
    let mode: Mode
}

/// A unified "Function Designer": structured essentials on the left (schema,
/// name, signature, language, options) over a body editor, with a live
/// `CREATE OR REPLACE FUNCTION` preview on the right. In **edit** mode it loads
/// the existing definition; if the signature changes it prepends a `DROP` so
/// the rewrite lands cleanly — the whole thing applies in one transaction.
///
/// SQL-standard `BEGIN ATOMIC` bodies have no `prosrc`; for those we fall back
/// to a raw full-statement editor (loaded from `pg_get_functiondef`) so the
/// designer never corrupts a function it can't structurally round-trip.
struct FunctionDesignerView: View {
    let request: FunctionDesignerRequest
    let service: ConnectionService
    let onClose: () -> Void

    @State private var schema: String = "public"
    @State private var name: String = ""
    @State private var kind: FunctionNode.Kind = .function
    @State private var argumentsText: String = ""
    @State private var returnsText: String = "integer"
    @State private var language: String = "plpgsql"
    @State private var volatility: FunctionInspector.Volatility = .volatile
    @State private var securityDefiner = false
    @State private var isStrict = false
    @State private var bodyText: String = ""

    // Raw fallback: the body editor holds the entire statement verbatim.
    @State private var rawDDL = false

    // Edit-mode originals (signature diff → decide whether a DROP is needed).
    @State private var original: Original?

    @State private var loading = false
    @State private var loadError: String?
    @State private var applyError: String?
    @State private var applying = false

    private struct Original {
        var schema: String
        var name: String
        var identityArguments: String
        var returnType: String
        var kind: FunctionNode.Kind
    }

    private var isEdit: Bool {
        if case .edit = request.mode { return true }
        return false
    }
    private var isProcedure: Bool { kind == .procedure }

    private static let languages = ["plpgsql", "sql"]
    private static let bodyTemplate = """
    BEGIN
      -- your logic here
      RETURN NULL;
    END;
    """

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
                centeredStatus { ProgressView().controlSize(.small); Text("Loading function…").font(.caption).foregroundStyle(.secondary) }
            } else if let loadError {
                centeredStatus {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                HStack(spacing: 0) {
                    editorColumn
                    Divider()
                    previewColumn.frame(width: 340)
                }
            }
            Divider()
            footer
        }
        .frame(width: 940, height: 620)
        .task { await initialLoad() }
    }

    @ViewBuilder
    private func centeredStatus<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: Tokens.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isEdit ? "function" : "plus.app")
                .font(.title2)
                .foregroundStyle(Tokens.Brand.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEdit ? "Edit function" : "New function")
                    .font(.title3.weight(.semibold))
                if isEdit {
                    Text("\(schema).\(name)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isEdit {
                Picker("", selection: $kind) {
                    Text("Function").tag(FunctionNode.Kind.function)
                    Text("Procedure").tag(FunctionNode.Kind.procedure)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(Tokens.Spacing.md)
    }

    // MARK: Editor column

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if rawDDL {
                rawNotice
            } else {
                essentialsForm
                Divider()
            }
            HStack(spacing: 6) {
                Image(systemName: "curlybraces.square").font(.caption2)
                Text(rawDDL ? "Full statement" : "Body")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !rawDDL {
                    Text("AS $\(dollarTag)$ … $\(dollarTag)$")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, 6)
            SQLEditorTextView(text: $bodyText, schemaProvider: { service.schema })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var rawNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("This function uses a SQL-standard body. Edit the full statement below.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Tokens.Spacing.sm)
        .background(Color.orange.opacity(0.07))
    }

    private var essentialsForm: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field("Schema") {
                    Picker("", selection: $schema) {
                        ForEach(schemaNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(isEdit)
                }
                .frame(width: 150)
                field("Name") {
                    TextField("function_name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
            }
            field("Arguments") {
                TextField("a integer, b text DEFAULT ''", text: $argumentsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(spacing: 8) {
                if !isProcedure {
                    field("Returns") {
                        TextField("integer", text: $returnsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                }
                field("Language") {
                    Picker("", selection: $language) {
                        ForEach(languageOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                .frame(width: 130)
            }
            HStack(spacing: 14) {
                if !isProcedure {
                    Picker("", selection: $volatility) {
                        ForEach(FunctionInspector.Volatility.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Toggle("Strict", isOn: $isStrict).toggleStyle(.checkbox)
                        .help("RETURNS NULL ON NULL INPUT")
                }
                Toggle("Security definer", isOn: $securityDefiner).toggleStyle(.checkbox)
                    .help("Run with the privileges of the function's owner")
                Spacer()
            }
            .font(.caption)
        }
        .padding(Tokens.Spacing.sm)
        .disabled(applying)
    }

    private var languageOptions: [String] {
        // Keep the function's existing language available even if exotic.
        var opts = Self.languages
        if !opts.contains(language) { opts.insert(language, at: 0) }
        return opts
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Preview column

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").font(.caption)
                Text("SQL").font(.caption.weight(.semibold))
                Spacer()
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
                    Text(isEdit ? "Save changes" : "Create \(isProcedure ? "procedure" : "function")")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canApply || applying)
        }
        .padding(Tokens.Spacing.md)
    }

    private var canApply: Bool {
        if rawDDL { return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !isProcedure && returnsText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    // MARK: Loading

    private func initialLoad() async {
        switch request.mode {
        case .create(let s):
            schema = s ?? schemaNames.first ?? "public"
            if bodyText.isEmpty { bodyText = Self.bodyTemplate }
        case .edit(let node):
            schema = node.schema
            name = node.name
            kind = node.kind
            await loadExisting(node)
        }
    }

    private func loadExisting(_ node: FunctionNode) async {
        guard let client = service.client else { loadError = "Not connected"; return }
        loading = true
        defer { loading = false }
        do {
            let def = try await FunctionInspector.fetch(client: client, function: node)
            language = def.language
            returnsText = def.returnType
            argumentsText = def.arguments
            volatility = def.volatility
            isStrict = def.isStrict
            securityDefiner = def.securityDefiner
            kind = def.kind
            original = Original(
                schema: node.schema, name: node.name,
                identityArguments: def.identityArguments,
                returnType: def.returnType, kind: def.kind
            )
            if def.isStructurallySimple {
                bodyText = def.body
            } else {
                // SQL-standard body, or attributes the structured form doesn't
                // model (SET / LEAKPROOF / COST / PARALLEL …) — edit the full
                // statement verbatim so we never drop them on save.
                rawDDL = true
                bodyText = (try? await fetchFullDDL(client: client, node: node)) ?? def.body
            }
        } catch {
            loadError = PostgresErrorMessage.describe(error)
        }
    }

    private func fetchFullDDL(client: PostgresClient, node: FunctionNode) async throws -> String {
        let qualified = "\(SQLIdent.quote(node.schema)).\(SQLIdent.quote(node.name))\(node.arguments)"
        let sql = "SELECT pg_get_functiondef('\(qualified.replacingOccurrences(of: "'", with: "''"))'::regprocedure)"
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await def in rows.decode(String.self) { return def }
        return ""
    }

    // MARK: SQL assembly

    /// A dollar-quote tag that can't collide with the body content.
    private var dollarTag: String {
        let base = isProcedure ? "procedure" : "function"
        if !bodyText.contains("$\(base)$") { return base }
        var i = 1
        while bodyText.contains("$pgbody\(i)$") { i += 1 }
        return "pgbody\(i)"
    }

    private var createSQL: String {
        if rawDDL { return bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }
        let routine = isProcedure ? "PROCEDURE" : "FUNCTION"
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "function_name" : name
        let args = argumentsText.trimmingCharacters(in: .whitespaces)
        var lines = ["CREATE OR REPLACE \(routine) \(SQLIdent.quote(schema)).\(SQLIdent.quote(finalName))(\(args))"]
        if !isProcedure {
            let ret = returnsText.trimmingCharacters(in: .whitespaces)
            lines.append(" RETURNS \(ret.isEmpty ? "void" : ret)")
        }
        lines.append(" LANGUAGE \(language)")
        if !isProcedure && volatility != .volatile { lines.append(" \(volatility.rawValue)") }
        if !isProcedure && isStrict { lines.append(" STRICT") }
        if securityDefiner { lines.append(" SECURITY DEFINER") }
        let tag = dollarTag
        lines.append("AS $\(tag)$\n\(bodyText)\n$\(tag)$")
        return lines.joined(separator: "\n")
    }

    private var previewText: String {
        let stmts = generatedStatements
        return stmts.isEmpty ? "-- Nothing to apply yet." : stmts.map { $0 + ";" }.joined(separator: "\n\n")
    }

    /// The statement batch to run. In edit mode, if the signature changed we
    /// DROP the old routine first (a bare CREATE OR REPLACE can't change a
    /// function's name, argument types, or return type).
    private var generatedStatements: [String] {
        var out: [String] = []
        if let o = original, signatureChanged(o) {
            let routine = o.kind == .procedure ? "PROCEDURE" : "FUNCTION"
            out.append("DROP \(routine) IF EXISTS \(SQLIdent.quote(o.schema)).\(SQLIdent.quote(o.name))(\(o.identityArguments))")
        }
        out.append(createSQL)
        return out
    }

    private func signatureChanged(_ o: Original) -> Bool {
        if rawDDL { return false } // raw mode replaces in place; user owns the DDL
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let ret = returnsText.trimmingCharacters(in: .whitespaces)
        return finalName != o.name
            || schema != o.schema
            || kind != o.kind
            || (!isProcedure && ret != o.returnType.trimmingCharacters(in: .whitespaces))
            || argumentsChanged(o)
    }

    /// Compare the editable argument string against the loaded identity args.
    /// We normalise whitespace and strip DEFAULT clauses since identity args
    /// never carry them.
    private func argumentsChanged(_ o: Original) -> Bool {
        identityForm(argumentsText) != normalize(o.identityArguments)
    }

    private func identityForm(_ args: String) -> String {
        // Drop "DEFAULT …" tails from each top-level argument before comparing.
        let parts = splitTopLevel(args)
        let stripped = parts.map { part -> String in
            if let r = part.range(of: " DEFAULT ", options: .caseInsensitive) {
                return String(part[part.startIndex..<r.lowerBound])
            }
            return part
        }
        return normalize(stripped.joined(separator: ", "))
    }

    private func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .lowercased()
    }

    /// Split on top-level commas (ignoring commas inside parentheses, e.g.
    /// `numeric(10,2)`).
    private func splitTopLevel(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for c in s {
            switch c {
            case "(": depth += 1; current.append(c)
            case ")": depth = max(0, depth - 1); current.append(c)
            case "," where depth == 0:
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }

    // MARK: Apply

    private func apply() {
        applying = true
        applyError = nil
        Task {
            let finalSchema = schema
            let finalName = rawDDL ? name : name.trimmingCharacters(in: .whitespaces)
            let result = await AdminActions.executeBatch(
                generatedStatements,
                summary: isEdit ? "Save \(finalSchema).\(finalName)" : "Create \(finalSchema).\(finalName)",
                service: service
            )
            applying = false
            switch result {
            case .success:
                service.toasts.show(.success, isEdit ? "Saved \(finalSchema).\(finalName)" : "Created \(finalSchema).\(finalName)")
                await service.loadSchema()
                onClose()
            case .failure(let err):
                applyError = err.localizedDescription
            }
        }
    }
}
