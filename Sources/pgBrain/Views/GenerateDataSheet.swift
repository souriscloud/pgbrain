import SwiftUI

/// Generate-test-data sheet. The user picks a row count and a per-column
/// strategy, and we build one `INSERT INTO … SELECT … FROM generate_series(1, N)`
/// that the server runs in a single pass — far faster than N round-trips.
///
/// Columns default to "skip" (let the column's own DEFAULT / sequence
/// fill it) so identity / serial PKs don't get clobbered.
struct GenerateDataSheet: View {
    let service: ConnectionService
    let table: TableNode
    let onClose: () -> Void
    let onDone: () -> Void

    enum Strategy: String, CaseIterable, Identifiable {
        case skip = "Skip (use default)"
        case sequence = "Row number (g.i)"
        case randomInt = "Random int"
        case randomNumeric = "Random numeric"
        case randomText = "Random text"
        case randomBool = "Random bool"
        case now = "now()"
        case randomTimestamp = "Random timestamp (±1y)"
        case uuid = "gen_random_uuid()"
        case nullValue = "NULL"
        case fixed = "Fixed value…"
        var id: String { rawValue }
    }

    @State private var rowCount: Int = 100
    @State private var strategies: [String: Strategy] = [:]
    @State private var fixedValues: [String: TypedInputValue] = [:]
    @State private var error: String?
    @State private var running = false
    @State private var previewSQL = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            columnList
            Divider()
            previewBar
            if let error {
                Divider()
                Text(error).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                    .textSelection(.enabled).padding(.horizontal, Tokens.Spacing.md).padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear {
            for c in table.columns where strategies[c.name] == nil {
                strategies[c.name] = .skip
            }
            recomputePreview()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.stars").foregroundStyle(Tokens.Brand.primary)
            Text("Generate data — \(table.schema).\(table.name)").font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(Tokens.Spacing.md)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text("Rows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("100", value: $rowCount, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onChange(of: rowCount) { _, _ in recomputePreview() }
            Stepper("", value: $rowCount, in: 1...1_000_000, step: 100)
                .labelsHidden()
                .onChange(of: rowCount) { _, _ in recomputePreview() }
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
    }

    private var columnList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(table.columns) { col in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(col.name).font(.system(.caption, design: .monospaced).weight(.medium))
                            Text(col.typeName).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        .frame(width: 160, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { strategies[col.name] ?? .skip },
                            set: { strategies[col.name] = $0; recomputePreview() }
                        )) {
                            ForEach(Strategy.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        if strategies[col.name] == .fixed {
                            TypedValueEditor(
                                typeName: col.typeName,
                                nullable: col.nullable,
                                enums: service.schema.enums,
                                allowsDefault: false,
                                allowsExpression: true,
                                compact: true,
                                value: Binding(
                                    get: { fixedValues[col.name] ?? .literal("") },
                                    set: { fixedValues[col.name] = $0; recomputePreview() }
                                )
                            )
                            .frame(width: 240)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Tokens.Spacing.md)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var previewBar: some View {
        ScrollView(.horizontal) {
            Text(previewSQL.isEmpty ? "— nothing to insert —" : previewSQL)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, Tokens.Spacing.md)
                .padding(.vertical, 6)
        }
        .frame(height: 56)
    }

    private var footer: some View {
        HStack {
            if service.connection.isProduction {
                Label("PRODUCTION", systemImage: "exclamationmark.shield.fill")
                    .font(.caption2.weight(.bold)).foregroundStyle(.red)
            }
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Insert \(rowCount) rows") { run() }
                .buttonStyle(.borderedProminent)
                .disabled(running || previewSQL.isEmpty)
        }
        .padding(Tokens.Spacing.md)
    }

    // MARK: - SQL building

    /// Per-column SELECT expression. `g.i` is the generate_series alias.
    private func expression(for col: ColumnNode) -> String? {
        switch strategies[col.name] ?? .skip {
        case .skip: return nil
        case .sequence: return "g.i"
        case .randomInt: return "(random() * 1000000)::int"
        case .randomNumeric: return "(random() * 1000)::numeric(12,2)"
        case .randomText: return "md5(random()::text)"
        case .randomBool: return "(random() < 0.5)"
        case .now: return "now()"
        case .randomTimestamp: return "now() - (random() * interval '365 days')"
        case .uuid: return "gen_random_uuid()"
        case .nullValue: return "NULL"
        case .fixed:
            return (fixedValues[col.name] ?? .literal("")).sqlFragment(typeName: col.typeName)
        }
    }

    private func recomputePreview() {
        let active = table.columns.compactMap { col -> (String, String)? in
            guard let expr = expression(for: col) else { return nil }
            return (col.name, expr)
        }
        guard !active.isEmpty else { previewSQL = ""; return }
        let qualified = SQLIdent.quote(table.schema) + "." + SQLIdent.quote(table.name)
        let cols = active.map { SQLIdent.quote($0.0) }.joined(separator: ", ")
        let exprs = active.map { $0.1 }.joined(separator: ", ")
        previewSQL = "INSERT INTO \(qualified) (\(cols))\nSELECT \(exprs)\nFROM generate_series(1, \(rowCount)) AS g(i)"
    }

    private func run() {
        recomputePreview()
        guard !previewSQL.isEmpty else { return }
        running = true
        Task {
            let result = await AdminActions.runGeneratedInsert(
                previewSQL,
                summary: "Generate \(rowCount) rows → \(table.schema).\(table.name)",
                service: service
            )
            running = false
            switch result {
            case .success: onDone(); onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}
