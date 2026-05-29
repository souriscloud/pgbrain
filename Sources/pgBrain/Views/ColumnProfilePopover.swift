import SwiftUI

/// Popover that profiles a single column: total / non-null / null / distinct
/// counts with fractions, plus min·max·avg. Mirrors `DistinctValuesPopover`'s
/// shape and load lifecycle. Respects the tab's active WHERE clause.
struct ColumnProfilePopover: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let column: ColumnNode
    let extraWhere: String

    @State private var profile: ColumnProfiler.Profile?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundStyle(Tokens.Brand.primary)
                Text(column.name).font(.headline)
                Text(column.typeName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Profiling…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if let error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            } else if let p = profile {
                content(p)
            }
        }
        .padding(Tokens.Spacing.md)
        .frame(width: 320)
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ p: ColumnProfiler.Profile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Rows", "\(p.total)")
            statRow("Non-null", "\(p.nonNull)")
            statRow("Null", "\(p.nullCount) (\(percent(p.nullFraction)))")
            // Null fraction bar — quick visual for sparsity.
            if p.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(p.nullFraction > 0.5 ? Color.orange : Tokens.Brand.primary)
                            .frame(width: max(2, geo.size.width * (1 - p.nullFraction)))
                    }
                }
                .frame(height: 5)
                .help("\(percent(1 - p.nullFraction)) populated")
            }
            statRow("Distinct", "\(p.distinctCount)" + (p.nonNull > 0 ? " (\(percent(p.distinctFraction)))" : ""))
            if p.distinctCount == p.nonNull && p.nonNull > 0 {
                Text("Unique — every non-null value is distinct.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if p.minValue != nil || p.maxValue != nil || p.avgValue != nil {
                Divider().padding(.vertical, 2)
                if let mn = p.minValue { statRow("Min", mn, mono: true) }
                if let mx = p.maxValue { statRow("Max", mx, mono: true) }
                if let avg = p.avgValue { statRow("Avg", trimNumeric(avg), mono: true) }
            }

            if !extraWhere.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().padding(.vertical, 2)
                Text("Filtered by the active WHERE clause.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func statRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .caption.weight(.medium))
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func percent(_ f: Double) -> String {
        let pct = f * 100
        if pct > 0 && pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }

    /// avg comes back as numeric(38,6) text — strip trailing zeros so
    /// "3.000000" reads as "3" and "2.500000" as "2.5".
    private func trimNumeric(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    private func load() async {
        guard let client = service.client else {
            error = "Not connected."; loading = false; return
        }
        do {
            profile = try await ColumnProfiler.profile(
                schema: schema, table: table, column: column,
                extraWhere: extraWhere, client: client
            )
            loading = false
        } catch {
            self.error = PostgresErrorMessage.describe(error)
            loading = false
        }
    }
}
