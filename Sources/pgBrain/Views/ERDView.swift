import SwiftUI

/// Entity-relationship diagram for one schema. Table boxes laid out on
/// a grid, foreign keys drawn as connecting lines. Boxes are draggable;
/// double-clicking one opens the table. Deliberately simple — a
/// force-directed layout would be nicer but a tidy grid is legible and
/// deterministic, which matters more for a reference diagram.
struct ERDView: View {
    let schema: SchemaNode
    let onOpenTable: (TableNode) -> Void
    let onClose: () -> Void

    @State private var positions: [String: CGPoint] = [:]
    @State private var dragging: String?
    @State private var scale: CGFloat = 1.0

    private let boxWidth: CGFloat = 200
    private let rowHeight: CGFloat = 16
    private let headerHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { _ in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        edges
                        ForEach(schema.tables) { table in
                            box(for: table)
                                .position(positions[table.id] ?? .zero)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: canvasSize.width * scale,
                        height: canvasSize.height * scale
                    )
                    .padding(40)
                }
            }
        }
        .frame(width: 900, height: 640)
        .onAppear { layoutIfNeeded() }
    }

    private var header: some View {
        HStack {
            Text("ERD · \(schema.name)").font(.title3.weight(.semibold))
            Text("(\(schema.tables.count) tables)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button { scale = max(0.4, scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Zoom out")
            Text("\(Int(scale * 100))%").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 44)
            Button { scale = min(2.0, scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Zoom in")
            Button("Reset layout") { positions = [:]; layoutIfNeeded(force: true) }
                .buttonStyle(.borderless)
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    // MARK: - Edges (FK lines)

    private var edges: some View {
        Canvas { ctx, _ in
            for table in schema.tables {
                guard let from = positions[table.id] else { continue }
                for fk in table.foreignKeys where fk.refSchema == schema.name {
                    let targetID = "\(fk.refSchema).\(fk.refTable)"
                    guard let to = positions[targetID] else { continue }
                    var path = Path()
                    path.move(to: from)
                    // Gentle cubic curve so overlapping straight lines
                    // don't read as one.
                    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                    path.addQuadCurve(to: to, control: CGPoint(x: mid.x, y: mid.y - 30))
                    ctx.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                    // Arrowhead dot at the referenced (parent) end.
                    let dot = Path(ellipseIn: CGRect(x: to.x - 3, y: to.y - 3, width: 6, height: 6))
                    ctx.fill(dot, with: .color(Color.accentColor))
                }
            }
        }
    }

    // MARK: - Table box

    private func box(for table: TableNode) -> some View {
        let shownCols = table.columns.prefix(12)
        return VStack(alignment: .leading, spacing: 0) {
            Text(table.name)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: headerHeight)
                .background(Tokens.Brand.primary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shownCols), id: \.name) { col in
                    HStack(spacing: 4) {
                        if table.primaryKey.contains(col.name) {
                            Image(systemName: "key.fill").font(.system(size: 7)).foregroundStyle(Tokens.Brand.primary)
                        }
                        if table.foreignKeys.contains(where: { $0.localColumn == col.name }) {
                            Image(systemName: "arrow.up.right").font(.system(size: 7)).foregroundStyle(.blue)
                        }
                        Text(col.name)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(shortType(col.typeName))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: rowHeight)
                }
                if table.columns.count > 12 {
                    Text("+\(table.columns.count - 12) more")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).frame(height: rowHeight)
                }
            }
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: boxWidth)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .gesture(
            DragGesture()
                .onChanged { v in
                    positions[table.id] = CGPoint(
                        x: v.location.x / scale,
                        y: v.location.y / scale
                    )
                }
        )
        .onTapGesture(count: 2) { onOpenTable(table) }
    }

    private func shortType(_ t: String) -> String {
        if t.hasPrefix("character varying") { return "varchar" }
        if t.hasPrefix("timestamp") { return "ts" }
        if t == "double precision" { return "float8" }
        return t.count > 10 ? String(t.prefix(9)) + "…" : t
    }

    // MARK: - Layout

    private var canvasSize: CGSize {
        let cols = max(1, Int(Double(schema.tables.count).squareRoot().rounded(.up)))
        let rows = Int((Double(schema.tables.count) / Double(cols)).rounded(.up))
        return CGSize(
            width: CGFloat(cols) * (boxWidth + 80) + 80,
            height: CGFloat(rows) * 320 + 80
        )
    }

    private func layoutIfNeeded(force: Bool = false) {
        guard force || positions.isEmpty else { return }
        let cols = max(1, Int(Double(schema.tables.count).squareRoot().rounded(.up)))
        for (i, table) in schema.tables.enumerated() {
            let row = i / cols
            let col = i % cols
            positions[table.id] = CGPoint(
                x: CGFloat(col) * (boxWidth + 80) + boxWidth / 2 + 60,
                y: CGFloat(row) * 320 + 160
            )
        }
    }
}
