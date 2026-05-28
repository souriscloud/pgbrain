import SwiftUI
import PostgresNIO

/// Editor for a view / materialized view body. Loads the current
/// `pg_get_viewdef` and wraps it in a `CREATE OR REPLACE VIEW … AS`
/// (plain views) or `DROP + CREATE MATERIALIZED VIEW` (matviews can't
/// be replaced in place). Save re-runs the whole statement.
struct ViewEditorView: View {
    let service: ConnectionService
    let table: TableNode    // kind is .view or .materializedView
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var body_: String = ""
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var savedToast = false

    private var isMatview: Bool { table.kind == .materializedView }
    private var qualified: String { SQLIdent.quote(table.schema) + "." + SQLIdent.quote(table.name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading view definition…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topTrailing) {
                    SQLEditorTextView(text: $body_, schemaProvider: { service.schema })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if savedToast {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Saved").font(.caption.weight(.medium))
                        }
                        .padding(6)
                        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.green)
                        .padding(8)
                        .transition(.opacity)
                    }
                }
            }
            if let error {
                Divider()
                ScrollView {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            Divider()
            HStack {
                if isMatview {
                    Label("Matview: saved via DROP + CREATE", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || loading || body_.isEmpty)
            }
            .padding(Tokens.Spacing.md)
        }
        .frame(width: 760, height: 540)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Image(systemName: isMatview ? "rectangle.stack.fill" : "rectangle.stack")
                .foregroundStyle(Tokens.Brand.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(table.name).font(.system(.title3, design: .monospaced).weight(.semibold))
                Text("\(table.schema) · \(isMatview ? "materialized view" : "view")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Tokens.Spacing.md)
    }

    private func load() async {
        guard let client = service.client else {
            error = "Not connected."; loading = false; return
        }
        let sql = "SELECT pg_get_viewdef('\(qualified.replacingOccurrences(of: "'", with: "''"))'::regclass, true)"
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await def in rows.decode(String.self) {
                let kindWord = isMatview ? "MATERIALIZED VIEW" : "VIEW"
                self.body_ = "CREATE OR REPLACE \(kindWord) \(qualified) AS\n\(def)"
                self.loading = false
                return
            }
            self.error = "View definition wasn't returned."
            self.loading = false
        } catch {
            self.error = PostgresErrorMessage.describe(error)
            self.loading = false
        }
    }

    private func save() {
        saving = true
        Task {
            // Matviews don't support CREATE OR REPLACE — rewrite the
            // editor's "CREATE OR REPLACE MATERIALIZED VIEW" into a
            // DROP + CREATE pair so the save actually lands.
            let ddl: String
            if isMatview {
                let createPart = body_.replacingOccurrences(
                    of: "CREATE OR REPLACE MATERIALIZED VIEW",
                    with: "CREATE MATERIALIZED VIEW",
                    options: [.caseInsensitive]
                )
                ddl = "DROP MATERIALIZED VIEW IF EXISTS \(qualified);\n\(createPart)"
            } else {
                ddl = body_
            }
            let result = await AdminActions.saveViewBody(ddl, service: service)
            saving = false
            switch result {
            case .success:
                error = nil
                onSaved()
                withAnimation { savedToast = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation { savedToast = false }
                }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}
