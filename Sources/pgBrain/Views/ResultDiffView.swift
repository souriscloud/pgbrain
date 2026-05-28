import SwiftUI

/// Side-by-side diff of two query result pages. v1 strategy:
/// align rows by their first column (the "key"), then mark each row
/// pairing as added / removed / changed / unchanged. Both grids
/// stay scroll-locked together.
struct ResultDiffView: View {
    let leftStatement: String
    let rightStatement: String
    let leftPage: RowsFetcher.Page
    let rightPage: RowsFetcher.Page
    let onClose: () -> Void

    enum RowKind { case unchanged, added, removed, changed }

    struct DiffRow: Identifiable {
        let id = UUID()
        let kind: RowKind
        let left: [String?]?
        let right: [String?]?
    }

    private var rows: [DiffRow] {
        ResultDiffView.diff(left: leftPage, right: rightPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            Divider()
            content
        }
        .frame(width: 1100, height: 680)
    }

    private var header: some View {
        HStack {
            Text("Result diff").font(.title3.weight(.semibold))
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    private var summary: some View {
        let counts = rows.reduce(into: (added: 0, removed: 0, changed: 0, unchanged: 0)) { acc, r in
            switch r.kind {
            case .added:     acc.added += 1
            case .removed:   acc.removed += 1
            case .changed:   acc.changed += 1
            case .unchanged: acc.unchanged += 1
            }
        }
        return HStack(spacing: 14) {
            badge("+\(counts.added) added", color: .green)
            badge("-\(counts.removed) removed", color: .red)
            badge("~\(counts.changed) changed", color: .orange)
            badge("\(counts.unchanged) unchanged", color: .secondary)
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    private var content: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(spacing: 0) {
                // Column header
                HStack(spacing: 0) {
                    rowKindIndicator(kind: nil, isHeader: true)
                    columnHeader(columns: leftPage.columns, side: .left)
                    Divider().frame(width: 2)
                    columnHeader(columns: rightPage.columns, side: .right)
                }
                Divider()
                // Body
                ForEach(rows) { diffRow in
                    HStack(spacing: 0) {
                        rowKindIndicator(kind: diffRow.kind, isHeader: false)
                        rowView(values: diffRow.left, columns: leftPage.columns, side: .left, kind: diffRow.kind)
                        Divider().frame(width: 2)
                        rowView(values: diffRow.right, columns: rightPage.columns, side: .right, kind: diffRow.kind)
                    }
                    Divider().opacity(0.35)
                }
            }
            .padding(.bottom, Tokens.Spacing.md)
        }
    }

    private enum Side { case left, right }

    private func rowKindIndicator(kind: RowKind?, isHeader: Bool) -> some View {
        let color: Color = {
            switch kind {
            case .added:     return .green
            case .removed:   return .red
            case .changed:   return .orange
            case .unchanged: return .secondary.opacity(0.3)
            case .none:      return .clear
            }
        }()
        let label: String = {
            switch kind {
            case .added:     return "+"
            case .removed:   return "−"
            case .changed:   return "~"
            case .unchanged: return ""
            case .none:      return "·"
            }
        }()
        return Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .foregroundStyle(color)
            .frame(width: 24, height: isHeader ? 28 : 22)
            .background(color.opacity(isHeader ? 0 : 0.08))
    }

    private func columnHeader(columns: [ColumnNode], side: Side) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { col in
                Text(col.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(width: 140, alignment: .leading)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func rowView(values: [String?]?, columns: [ColumnNode], side: Side, kind: RowKind) -> some View {
        let bgColor: Color = {
            switch kind {
            case .added where side == .right:   return Color.green.opacity(0.10)
            case .removed where side == .left:  return Color.red.opacity(0.10)
            case .changed:                       return Color.orange.opacity(0.06)
            default:                             return .clear
            }
        }()
        return HStack(spacing: 0) {
            if let values {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    Text(v ?? "NULL")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(v == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(width: 140, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text("—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(width: CGFloat(columns.count) * 140, alignment: .leading)
            }
        }
        .background(bgColor)
    }

    // MARK: - Diff algorithm

    /// Key both pages by their first column (the conventional PK).
    /// Walk the union of keys: rows only on one side are added /
    /// removed, rows on both sides are changed when their projected
    /// values differ.
    static func diff(left: RowsFetcher.Page, right: RowsFetcher.Page) -> [DiffRow] {
        guard !left.columns.isEmpty, !right.columns.isEmpty else { return [] }
        let leftByKey = Dictionary(uniqueKeysWithValues:
            left.rows.compactMap { row -> (String, [String?])? in
                guard let key = row.first ?? nil else { return nil }
                return (key, row)
            }
        )
        let rightByKey = Dictionary(uniqueKeysWithValues:
            right.rows.compactMap { row -> (String, [String?])? in
                guard let key = row.first ?? nil else { return nil }
                return (key, row)
            }
        )
        let allKeys = Set(leftByKey.keys).union(rightByKey.keys).sorted()
        var out: [DiffRow] = []
        for key in allKeys {
            switch (leftByKey[key], rightByKey[key]) {
            case (let l?, let r?):
                if l == r { out.append(DiffRow(kind: .unchanged, left: l, right: r)) }
                else      { out.append(DiffRow(kind: .changed, left: l, right: r)) }
            case (let l?, nil):
                out.append(DiffRow(kind: .removed, left: l, right: nil))
            case (nil, let r?):
                out.append(DiffRow(kind: .added, left: nil, right: r))
            default:
                continue
            }
        }
        return out
    }
}
