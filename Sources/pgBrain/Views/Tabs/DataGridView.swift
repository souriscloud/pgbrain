import AppKit
import SwiftUI

/// Read-only `NSTableView` driven by a `RowsFetcher.Page`. Type-aware cells:
/// alignment per column kind, monospaced for numeric columns, distinct NULL
/// rendering ("NULL" italic + dimmed), JSON pretty-print on single line.
struct DataGridView: NSViewRepresentable {
    let page: RowsFetcher.Page

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var page: RowsFetcher.Page
        init(page: RowsFetcher.Page) { self.page = page }

        // Map column identifier → index for O(1) row lookup.
        private var indexByID: [String: Int] = [:]

        func rebuildIndex() {
            indexByID.removeAll(keepingCapacity: true)
            for (i, c) in page.columns.enumerated() {
                indexByID["\(i)_\(c.name)"] = i
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { page.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let columnID = tableColumn?.identifier.rawValue,
                  let colIdx = indexByID[columnID] else { return nil }
            let column = page.columns[colIdx]
            let value = page.rows[row][colIdx]
            let cell = reuseCell(in: tableView)
            cell.configure(value: value, column: column)
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            20
        }

        private func reuseCell(in tableView: NSTableView) -> DataCellView {
            let id = NSUserInterfaceItemIdentifier("DataCell")
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? DataCellView {
                return reused
            }
            let v = DataCellView()
            v.identifier = id
            return v
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        table.style = .inset
        table.headerView = NSTableHeaderView()

        applyColumns(to: table, coordinator: context.coordinator)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.rebuildIndex()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let identityChanged = !columnsMatch(coordinator: context.coordinator, new: page.columns)
        context.coordinator.page = page
        context.coordinator.rebuildIndex()
        if identityChanged {
            // Remove all columns and re-add — happens on tab swap, not on reload.
            for col in table.tableColumns { table.removeTableColumn(col) }
            applyColumns(to: table, coordinator: context.coordinator)
        }
        table.reloadData()
    }

    private func columnsMatch(coordinator: Coordinator, new: [ColumnNode]) -> Bool {
        guard coordinator.page.columns.count == new.count else { return false }
        return zip(coordinator.page.columns, new).allSatisfy { $0.name == $1.name && $0.typeName == $1.typeName }
    }

    private func applyColumns(to table: NSTableView, coordinator: Coordinator) {
        for (i, col) in page.columns.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier("\(i)_\(col.name)")
            let column = NSTableColumn(identifier: identifier)
            column.title = col.name
            column.minWidth = 60
            column.width = estimatedWidth(for: col)
            column.maxWidth = 800
            column.isEditable = false
            let kind = ColumnTypeKind.from(typeName: col.typeName)
            column.headerCell.alignment = headerAlignment(for: kind)
            table.addTableColumn(column)
        }
    }

    private func estimatedWidth(for col: ColumnNode) -> CGFloat {
        let kind = ColumnTypeKind.from(typeName: col.typeName)
        switch kind {
        case .bool: return 70
        case .integer: return 100
        case .number: return 120
        case .uuid: return 270
        case .timestamp: return 200
        case .date: return 130
        case .json: return 260
        default: return 180
        }
    }

    private func headerAlignment(for kind: ColumnTypeKind) -> NSTextAlignment {
        switch kind {
        case .integer, .number: return .right
        case .bool: return .center
        default: return .left
        }
    }
}

/// One reusable cell view that styles itself based on the column kind.
private final class DataCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.drawsBackground = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(value: String?, column: ColumnNode) {
        let kind = ColumnTypeKind.from(typeName: column.typeName)
        if value == nil {
            label.stringValue = "NULL"
            label.font = NSFont.systemFont(ofSize: 12).italic()
            label.textColor = .tertiaryLabelColor
            label.alignment = .left
            return
        }
        let v = value ?? ""
        label.alignment = alignment(for: kind)
        label.font = font(for: kind)
        label.textColor = .labelColor
        switch kind {
        case .json:
            label.stringValue = v
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
        case .bool:
            label.stringValue = boolGlyph(for: v)
        default:
            label.stringValue = v
        }
    }

    private func alignment(for kind: ColumnTypeKind) -> NSTextAlignment {
        switch kind {
        case .integer, .number: return .right
        case .bool: return .center
        default: return .left
        }
    }

    private func font(for kind: ColumnTypeKind) -> NSFont {
        switch kind {
        case .integer, .number, .uuid, .json, .bytes, .timestamp:
            return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        default:
            return NSFont.systemFont(ofSize: 12)
        }
    }

    private func boolGlyph(for raw: String) -> String {
        switch raw.lowercased() {
        case "t", "true", "1": return "✓"
        case "f", "false", "0": return ""
        default: return raw
        }
    }
}

private extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
