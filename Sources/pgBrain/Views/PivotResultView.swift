import SwiftUI

/// Pivot view over a `RowsFetcher.Page`. The user picks one source
/// column for rows, one for columns, one for values, and an aggregation
/// (sum / count / avg / min / max) — we build the pivot matrix in Swift
/// and render it as a SwiftUI Table.
///
/// All aggregation uses Double when feasible, falling back to String
/// concatenation for non-numeric values (count still works).
struct PivotResultView: View {
    let page: RowsFetcher.Page
    var onClose: () -> Void = {}
    /// When true, renders without the sheet header/Close and fixed frame so it
    /// can live inline inside a scratchpad result block.
    var embedded: Bool = false

    enum Agg: String, CaseIterable, Identifiable {
        case sum, avg, min, max, count
        var id: String { rawValue }
    }

    @State private var rowCol: String = ""
    @State private var colCol: String = ""
    @State private var valCol: String = ""
    @State private var agg: Agg = .sum

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
        .onAppear {
            if let r = columnNames.first { rowCol = r }
            if columnNames.count > 1 { colCol = columnNames[1] }
            if columnNames.count > 2 { valCol = columnNames[2] }
            if valCol.isEmpty, let last = columnNames.last { valCol = last }
        }
    }

    private var header: some View {
        HStack {
            Text("Pivot").font(.title3.weight(.semibold))
            Text("(\(page.rows.count) source rows)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            picker("Rows", $rowCol)
            picker("Columns", $colCol)
            picker("Value", $valCol)
            Picker("", selection: $agg) {
                ForEach(Agg.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
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
            .frame(minWidth: 110)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var content: some View {
        let pivot = compute()
        if pivot.colKeys.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Pick row / column / value above")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        gridHeader(rowCol)
                            .gridColumnAlignment(.leading)
                        ForEach(pivot.colKeys, id: \.self) { ck in
                            gridHeader(ck)
                        }
                    }
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08))
                    ForEach(pivot.rowKeys, id: \.self) { rk in
                        GridRow {
                            Text(rk)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .gridColumnAlignment(.leading)
                            ForEach(pivot.colKeys, id: \.self) { ck in
                                let v = pivot.cells["\(rk)\u{1F}\(ck)"]
                                Text(format(v))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(v == nil ? .tertiary : .primary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(Tokens.Spacing.md)
            }
        }
    }

    private func gridHeader(_ s: String) -> some View {
        Text(s)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.3)
    }

    // MARK: - Compute

    private struct Pivot {
        let rowKeys: [String]
        let colKeys: [String]
        let cells: [String: Double]
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }

    private func compute() -> Pivot {
        guard !rowCol.isEmpty, !colCol.isEmpty, !valCol.isEmpty,
              let rIdx = columnNames.firstIndex(of: rowCol),
              let cIdx = columnNames.firstIndex(of: colCol),
              let vIdx = columnNames.firstIndex(of: valCol)
        else { return Pivot(rowKeys: [], colKeys: [], cells: [:]) }

        struct Bucket { var sum: Double = 0; var count: Double = 0; var min: Double = .infinity; var max: Double = -.infinity }
        var buckets: [String: Bucket] = [:]
        var rowKeys: [String] = []
        var colKeys: [String] = []
        var seenRow = Set<String>()
        var seenCol = Set<String>()
        for row in page.rows {
            let rk = row[rIdx] ?? "NULL"
            let ck = row[cIdx] ?? "NULL"
            let raw = row[vIdx]
            if !seenRow.contains(rk) { seenRow.insert(rk); rowKeys.append(rk) }
            if !seenCol.contains(ck) { seenCol.insert(ck); colKeys.append(ck) }
            let key = "\(rk)\u{1F}\(ck)"
            var b = buckets[key] ?? Bucket()
            b.count += 1
            if let v = raw.flatMap(Double.init) {
                b.sum += v
                if v < b.min { b.min = v }
                if v > b.max { b.max = v }
            }
            buckets[key] = b
        }
        var cells: [String: Double] = [:]
        for (key, b) in buckets {
            cells[key] = aggregate(b)
        }
        return Pivot(rowKeys: rowKeys.sorted(), colKeys: colKeys.sorted(), cells: cells)
    }

    private func aggregate(_ b: Any) -> Double {
        // Mirror the inner Bucket so we don't need to expose its
        // shape — switch on the enum and pull the value.
        let mirror = Mirror(reflecting: b)
        var sum: Double = 0, count: Double = 0, mn: Double = .infinity, mx: Double = -.infinity
        for child in mirror.children {
            switch child.label {
            case "sum":   sum = child.value as? Double ?? 0
            case "count": count = child.value as? Double ?? 0
            case "min":   mn = child.value as? Double ?? .infinity
            case "max":   mx = child.value as? Double ?? -.infinity
            default: break
            }
        }
        switch agg {
        case .sum:   return sum
        case .avg:   return count == 0 ? 0 : sum / count
        case .min:   return mn.isFinite ? mn : 0
        case .max:   return mx.isFinite ? mx : 0
        case .count: return count
        }
    }
}
