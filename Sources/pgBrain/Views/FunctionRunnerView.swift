import SwiftUI

/// Drives a `.sheet(item:)` for executing an existing function/procedure.
struct FunctionRunnerRequest: Identifiable {
    let id = UUID()
    let function: FunctionNode
}

/// A focused "Run function" console: loads the routine's input parameters,
/// gives each a value field, builds the exact `SELECT … FROM fn(…)` (or
/// `CALL proc(…)`) call — shown live — and runs it, rendering the result
/// inline. Named parameters use `name => value` notation so blank fields fall
/// back to the function's own defaults.
struct FunctionRunnerView: View {
    let request: FunctionRunnerRequest
    let service: ConnectionService
    let onClose: () -> Void

    @State private var params: [FunctionInspector.Parameter] = []
    @State private var values: [UUID: TypedInputValue] = [:]
    @State private var loading = true
    @State private var loadError: String?

    @State private var running = false
    @State private var runError: String?
    @State private var result: QueryResult?

    private var fn: FunctionNode { request.function }
    private var isProcedure: Bool { fn.kind == .procedure }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                status { ProgressView().controlSize(.small); Text("Loading parameters…").font(.caption).foregroundStyle(.secondary) }
            } else if let loadError {
                status {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                paramsSection
                Divider()
                callPreview
                Divider()
                resultSection
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .task { await load() }
    }

    @ViewBuilder
    private func status<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: Tokens.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isProcedure ? "gearshape.2" : "function")
                .font(.title2).foregroundStyle(Tokens.Brand.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run \(isProcedure ? "procedure" : "function")")
                    .font(.title3.weight(.semibold))
                Text(fn.qualifiedSignature)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(Tokens.Spacing.md)
    }

    // MARK: Parameters

    private var paramsSection: some View {
        Group {
            if params.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("No input parameters.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(Tokens.Spacing.md)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(params) { p in
                            paramRow(p)
                        }
                    }
                    .padding(Tokens.Spacing.md)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func paramRow(_ p: FunctionInspector.Parameter) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(p.name.isEmpty ? "$\(paramIndex(p) + 1)" : p.name)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                Text(p.mode == "VARIADIC" ? "variadic" : "")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 150, alignment: .trailing)
            .padding(.top, 2)

            TypedValueEditor(
                typeName: p.type,
                nullable: true,
                enums: service.schema.enums,
                allowsDefault: p.hasDefault,
                allowsExpression: true,
                compact: true,
                completions: { partial, _, _ in
                    SQLCompletionProvider.items(
                        for: partial, in: service.schema,
                        context: .expression(columns: []))
                },
                value: Binding(
                    get: { values[p.id] ?? (p.hasDefault ? .defaultKeyword : .null) },
                    set: { values[p.id] = $0 }
                )
            )
        }
    }

    private func paramIndex(_ p: FunctionInspector.Parameter) -> Int {
        params.firstIndex(where: { $0.id == p.id }) ?? 0
    }

    // MARK: Call preview

    private var callPreview: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "curlybraces").font(.caption2).foregroundStyle(.secondary)
            Text(callSQL)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Tokens.Spacing.sm)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Result

    @ViewBuilder
    private var resultSection: some View {
        if let runError {
            ScrollView {
                Text(runError)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.sm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            resultTable(result)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "play.circle").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Fill in any arguments and Run.").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func resultTable(_ res: QueryResult) -> some View {
        let cols = res.page.columns
        let rows = res.page.rows
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                Text(res.commandTag ?? "OK").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if res.page.truncated {
                    Text("first \(rows.count) rows").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Tokens.Spacing.sm).padding(.vertical, 6)
            Divider()
            if cols.isEmpty {
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(cols) { c in
                                Text(c.name)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .frame(minWidth: 90, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                            }
                        }
                        .background(Color(nsColor: .underPageBackgroundColor))
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 0) {
                                ForEach(Array(cols.enumerated()), id: \.offset) { ci, _ in
                                    Text(ci < row.count ? (row[ci] ?? "NULL") : "")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(row[safe: ci].flatMap { $0 } == nil ? .secondary : .primary)
                                        .frame(minWidth: 90, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .textSelection(.enabled)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Copy SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(callSQL, forType: .string)
            }
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Button {
                run()
            } label: {
                if running {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running…") }
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(running || loading || loadError != nil)
        }
        .padding(Tokens.Spacing.md)
    }

    // MARK: Build call

    /// Whether we can safely use named `arg => value` notation — only when
    /// every parameter actually has a name.
    private var allNamed: Bool { !params.isEmpty && params.allSatisfy { !$0.name.isEmpty } }

    private var callSQL: String {
        let qualified = "\(SQLIdent.quote(fn.schema)).\(SQLIdent.quote(fn.name))"
        let argList = buildArgList()
        if isProcedure {
            return "CALL \(qualified)(\(argList))"
        }
        return "SELECT * FROM \(qualified)(\(argList))"
    }

    private func buildArgList() -> String {
        guard !params.isEmpty else { return "" }
        if allNamed {
            // Named notation: DEFAULT means "omit so the routine default
            // applies"; everything else passes `name => fragment`.
            var pieces: [String] = []
            for p in params {
                let v = values[p.id] ?? (p.hasDefault ? .defaultKeyword : .null)
                if case .defaultKeyword = v {
                    if p.hasDefault { continue }
                    pieces.append("\(p.name) => NULL")
                } else {
                    pieces.append("\(p.name) => \(v.sqlFragment(typeName: p.type, cast: false))")
                }
            }
            return pieces.joined(separator: ", ")
        }
        // Positional: every slot must be present, so DEFAULT collapses to NULL.
        return params.map { p in
            let v = values[p.id] ?? (p.hasDefault ? .defaultKeyword : .null)
            if case .defaultKeyword = v { return "NULL" }
            return v.sqlFragment(typeName: p.type, cast: false)
        }.joined(separator: ", ")
    }

    // MARK: Actions

    private func load() async {
        guard let client = service.client else { loadError = "Not connected"; loading = false; return }
        do {
            params = try await FunctionInspector.parameters(client: client, function: fn)
        } catch {
            loadError = PostgresErrorMessage.describe(error)
        }
        loading = false
    }

    private func run() {
        guard let client = service.client else { runError = "Not connected"; return }
        running = true
        runError = nil
        result = nil
        let sql = callSQL
        Task {
            do {
                let res = try await QueryRunner.run(sql, on: client, limit: 500)
                result = res
            } catch {
                runError = PostgresErrorMessage.describe(error)
            }
            running = false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
