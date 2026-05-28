import SwiftUI

/// Results sheet for "Find usages of {table}" — substring matches in
/// every function / view / matview / trigger. Clicking a function row
/// opens the function editor; clicking a view / matview opens its tab.
struct FindUsagesView: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let onClose: () -> Void
    let onOpenFunction: (FunctionNode) -> Void
    let onOpenTable: (TableNode) -> Void

    @State private var hits: [UsageHit] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 720, height: 480)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text("Usages of \(schema).\(table)")
                .font(.title3.weight(.semibold))
            Text("(\(hits.count))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24)).foregroundStyle(.orange)
                Text("Couldn't search")
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hits.isEmpty && !loading {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("No references found")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Substring-match against function bodies, view defs, and triggers. Composite identifiers (`schema.table`) and quoted forms are covered.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(hits) { hit in
                        Button {
                            open(hit)
                        } label: {
                            hitRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Tokens.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private func hitRow(_ hit: UsageHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconFor(hit.kind))
                .foregroundStyle(Tokens.Brand.primary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(hit.schema).\(hit.name)")
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                    Text(hit.kind.rawValue)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }
                Text(hit.excerpt)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func iconFor(_ kind: UsageHit.Kind) -> String {
        switch kind {
        case .function: "function"
        case .view: "rectangle.stack"
        case .materializedView: "rectangle.stack.fill"
        case .trigger: "bolt"
        }
    }

    private func open(_ hit: UsageHit) {
        switch hit.kind {
        case .function:
            // Resolve the function via the live schema; if we can't
            // (overloads, signature drift) just close — palette opens
            // the function-editor flow.
            guard let f = service.schema.schemas
                .first(where: { $0.name == hit.schema })?
                .functions.first(where: { $0.name == hit.name })
            else { onClose(); return }
            onOpenFunction(f)
        case .view, .materializedView:
            guard let t = service.schema.schemas
                .first(where: { $0.name == hit.schema })?
                .tables.first(where: { $0.name == hit.name })
            else { onClose(); return }
            onOpenTable(t)
        case .trigger:
            // Triggers don't open a tab — surface the parent table.
            guard let t = service.schema.schemas
                .first(where: { $0.name == hit.schema })?
                .tables.first(where: { _ in true })
            else { onClose(); return }
            _ = t  // can't reliably resolve trigger→table without another fetch; user can navigate via Structure pane.
        }
    }

    private func load() async {
        guard let client = service.client else {
            error = "Not connected."; loading = false; return
        }
        loading = true
        do {
            hits = try await UsageFinder.find(schema: schema, table: table, client: client)
            error = nil
        } catch {
            self.error = PostgresErrorMessage.describe(error)
        }
        loading = false
    }
}
