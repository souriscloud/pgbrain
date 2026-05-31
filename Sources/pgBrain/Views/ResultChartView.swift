import SwiftUI
import Charts

/// Quick bar / line chart over a `RowsFetcher.Page`. The user picks an
/// X column (categorical) and one or more Y columns (numeric); we plot
/// the first 200 rows. Anything bigger and we add a "showing first 200"
/// banner — beyond that the chart pixels merge anyway.
struct ResultChartView: View {
    let page: RowsFetcher.Page
    var onClose: () -> Void = {}
    /// Inline (scratchpad result block) mode — no sheet header / fixed frame.
    var embedded: Bool = false

    enum Kind: String, CaseIterable, Identifiable {
        case bar, line, point
        var id: String { rawValue }
    }

    @State private var xCol: String = ""
    @State private var yCol: String = ""
    @State private var kind: Kind = .bar

    private var columnNames: [String] { page.columns.map(\.name) }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                header
                Divider()
            }
            controls
            Divider()
            content
        }
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 540)
        .frame(maxWidth: embedded ? .infinity : nil, minHeight: embedded ? 200 : nil, maxHeight: embedded ? 360 : nil)
        .onAppear { autoPick() }
    }

    private var header: some View {
        HStack {
            Text("Chart").font(.title3.weight(.semibold))
            Text("(\(page.rows.count) rows)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            picker("X", $xCol)
            picker("Y", $yCol)
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
    }

    private func picker(_ label: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("", selection: binding) {
                ForEach(columnNames, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 120)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var content: some View {
        let series = compute()
        if series.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Pick X (label) and Y (numeric) columns").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if page.rows.count > 200 {
                    Text("Showing first 200 of \(page.rows.count) rows")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .padding(.horizontal, Tokens.Spacing.md)
                }
                Chart(series, id: \.label) { point in
                    switch kind {
                    case .bar:
                        BarMark(
                            x: .value(xCol, point.label),
                            y: .value(yCol, point.value)
                        )
                        .foregroundStyle(Tokens.Brand.primary)
                    case .line:
                        LineMark(
                            x: .value(xCol, point.label),
                            y: .value(yCol, point.value)
                        )
                        .foregroundStyle(Tokens.Brand.primary)
                    case .point:
                        PointMark(
                            x: .value(xCol, point.label),
                            y: .value(yCol, point.value)
                        )
                        .foregroundStyle(Tokens.Brand.primary)
                    }
                }
                .padding(Tokens.Spacing.md)
            }
        }
    }

    private struct ChartPoint {
        let label: String
        let value: Double
    }

    private func autoPick() {
        if xCol.isEmpty, let first = columnNames.first { xCol = first }
        // Pick the first numeric-looking column for Y.
        if yCol.isEmpty {
            for (i, c) in page.columns.enumerated() {
                let kind = ColumnTypeKind.from(typeName: c.typeName)
                if (kind == .integer || kind == .number), c.name != xCol {
                    yCol = c.name
                    break
                }
                _ = i
            }
            if yCol.isEmpty, columnNames.count > 1 { yCol = columnNames[1] }
        }
    }

    private func compute() -> [ChartPoint] {
        guard !xCol.isEmpty, !yCol.isEmpty,
              let xi = columnNames.firstIndex(of: xCol),
              let yi = columnNames.firstIndex(of: yCol)
        else { return [] }
        var out: [ChartPoint] = []
        out.reserveCapacity(min(200, page.rows.count))
        for row in page.rows.prefix(200) {
            let xv = row[xi] ?? "NULL"
            guard let yv = row[yi].flatMap(Double.init) else { continue }
            out.append(ChartPoint(label: xv, value: yv))
        }
        return out
    }
}
