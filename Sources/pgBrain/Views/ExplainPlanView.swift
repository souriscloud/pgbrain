import SwiftUI

/// EXPLAIN result sheet — header with the SQL preview + an
/// EXPLAIN / EXPLAIN ANALYZE toggle, body is a recursive tree of
/// `ExplainNode`s. Cost tiers get a colored ring so expensive nodes
/// jump out at a glance.
struct ExplainPlanView: View {
    let initialSQL: String
    let runExplain: (_ analyze: Bool) async -> Result<ExplainNode, Error>
    let onClose: () -> Void

    @State private var analyze = false
    @State private var plan: ExplainNode?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 760, height: 560)
        .task { await fetch() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack {
                Text("Query Plan")
                    .font(.title3.weight(.semibold))
                Spacer()
                Toggle(isOn: $analyze) {
                    Text("ANALYZE (executes)")
                        .font(.system(.caption, design: .monospaced))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: analyze) { _, _ in Task { await fetch() } }
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Text(initialSQL.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08))
                )
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        if let plan {
            ScrollView {
                ExplainNodeRow(node: plan, depth: 0, analyze: analyze)
                    .padding(Tokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if loading {
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(analyze ? "Running EXPLAIN ANALYZE…" : "Running EXPLAIN…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24)).foregroundStyle(.orange)
                Text("EXPLAIN failed").font(.headline)
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { Task { await fetch() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            EmptyView()
        }
    }

    private func fetch() async {
        loading = true
        error = nil
        defer { loading = false }
        switch await runExplain(analyze) {
        case .success(let node): plan = node
        case .failure(let err):  plan = nil; error = err.localizedDescription
        }
    }
}

/// Recursive row — one node + its children, indented by depth. Cost
/// tier ring (green → yellow → orange → red) lets you triage the
/// expensive nodes without reading the numbers.
struct ExplainNodeRow: View {
    let node: ExplainNode
    let depth: Int
    let analyze: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                tierBadge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(node.nodeType)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                        if let rel = node.relationName {
                            Text("on \(rel)\(node.alias.map { " (\($0))" } ?? "")")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    metricsLine
                }
                Spacer()
            }
            ForEach(node.children) { child in
                ExplainNodeRow(node: child, depth: depth + 1, analyze: analyze)
                    .padding(.leading, 20)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 1)
                            .padding(.leading, 6)
                    }
            }
        }
    }

    private var metricsLine: some View {
        HStack(spacing: 12) {
            Text("cost \(format(node.startupCost))–\(format(node.totalCost))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("rows ~\(formatInt(node.planRows))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("width \(node.planWidth)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            if analyze, let actualTotal = node.actualTotalTime {
                Text("⏱ \(format(actualTotal))ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.blue)
                if let actualRows = node.actualRows {
                    Text("got \(formatInt(actualRows))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    @ViewBuilder
    private var tierBadge: some View {
        // Cost tier coloring: cheap → green, expensive → red. Pure
        // visual gradient on `totalCost` — a real cost-tier scheme
        // would need the root's max cost as a normaliser. Cheap and
        // useful.
        let color: Color = {
            switch node.totalCost {
            case ..<10:        return .green
            case ..<1_000:     return .yellow
            case ..<100_000:   return .orange
            default:           return .red
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .padding(.top, 4)
    }

    private func format(_ v: Double) -> String {
        v < 100 ? String(format: "%.2f", v) : String(format: "%.0f", v)
    }
    private func formatInt(_ v: Double) -> String {
        let i = Int64(v.rounded())
        if i >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if i >= 1_000     { return String(format: "%.1fk", v / 1_000) }
        return "\(i)"
    }
}
