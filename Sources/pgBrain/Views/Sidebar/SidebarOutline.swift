import AppKit
import SwiftUI

/// Class-backed tree node used as item identity for `NSOutlineView`.
/// SwiftUI value types can't satisfy NSOutlineView's identity-by-pointer
/// requirement, so we mirror the snapshot once into these.
@MainActor
final class SidebarNode {
    enum Kind {
        case database(name: String)
        case schema(name: String)
        case table(TableNode)
        case columns(ofTable: TableNode)   // group node so columns nest one extra level
        case column(ColumnNode)
    }

    let kind: Kind
    var children: [SidebarNode]

    init(kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }

    static func build(from snapshot: SchemaSnapshot) -> SidebarNode {
        let schemaNodes = snapshot.schemas.map { schema -> SidebarNode in
            let tableNodes = schema.tables.map { table -> SidebarNode in
                let columnNodes = table.columns.map { col in
                    SidebarNode(kind: .column(col))
                }
                let columnsGroup = SidebarNode(kind: .columns(ofTable: table), children: columnNodes)
                return SidebarNode(kind: .table(table), children: [columnsGroup])
            }
            return SidebarNode(kind: .schema(name: schema.name), children: tableNodes)
        }
        return SidebarNode(
            kind: .database(name: snapshot.databaseName.isEmpty ? "database" : snapshot.databaseName),
            children: schemaNodes
        )
    }

    var displayName: String {
        switch kind {
        case .database(let n): return n
        case .schema(let n): return n
        case .table(let t): return t.name
        case .columns: return "columns"
        case .column(let c): return c.name
        }
    }

    var secondary: String? {
        switch kind {
        case .table(let t):
            switch t.kind {
            case .view: return "view"
            case .materializedView: return "matview"
            case .table: return nil
            }
        case .column(let c): return c.typeName + (c.nullable ? "" : " NOT NULL")
        case .schema, .database, .columns: return nil
        }
    }

    var symbol: String {
        switch kind {
        case .database: return "cylinder.split.1x2.fill"
        case .schema: return "folder"
        case .table(let t):
            switch t.kind {
            case .table: return "tablecells"
            case .view: return "rectangle.stack"
            case .materializedView: return "rectangle.stack.fill"
            }
        case .columns: return "list.bullet.rectangle"
        case .column: return "circle.dotted"
        }
    }

    /// Tables are the only item that opens a tab on activation.
    var openableTable: TableNode? {
        if case .table(let t) = kind { return t } else { return nil }
    }
}

struct SidebarOutlineView: NSViewRepresentable {
    let snapshot: SchemaSnapshot
    let onOpenTable: (TableNode) -> Void
    var onCopyTable: ((TableNode) -> Void)? = nil
    var onExportTable: ((TableNode) -> Void)? = nil
    var onImportInto: ((TableNode) -> Void)? = nil

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var root: SidebarNode
        let onOpenTable: (TableNode) -> Void
        let onCopyTable: ((TableNode) -> Void)?
        let onExportTable: ((TableNode) -> Void)?
        let onImportInto: ((TableNode) -> Void)?

        init(
            root: SidebarNode,
            onOpenTable: @escaping (TableNode) -> Void,
            onCopyTable: ((TableNode) -> Void)?,
            onExportTable: ((TableNode) -> Void)?,
            onImportInto: ((TableNode) -> Void)?
        ) {
            self.root = root
            self.onOpenTable = onOpenTable
            self.onCopyTable = onCopyTable
            self.onExportTable = onExportTable
            self.onImportInto = onImportInto
        }

        func menu(forRow row: Int, in outline: NSOutlineView) -> NSMenu? {
            guard let node = outline.item(atRow: row) as? SidebarNode,
                  let table = node.openableTable
            else { return nil }
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open in tab", action: #selector(handleOpen(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = table
            menu.addItem(open)
            menu.addItem(.separator())
            if onCopyTable != nil {
                let copy = NSMenuItem(title: "Copy table to…", action: #selector(handleCopy(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = table
                menu.addItem(copy)
            }
            if onExportTable != nil {
                let exp = NSMenuItem(title: "Export…", action: #selector(handleExport(_:)), keyEquivalent: "")
                exp.target = self
                exp.representedObject = table
                menu.addItem(exp)
            }
            if onImportInto != nil {
                let imp = NSMenuItem(title: "Import CSV into this table…", action: #selector(handleImport(_:)), keyEquivalent: "")
                imp.target = self
                imp.representedObject = table
                menu.addItem(imp)
            }
            return menu
        }

        @objc private func handleOpen(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onOpenTable(table)
        }

        @objc private func handleCopy(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onCopyTable?(table)
        }

        @objc private func handleExport(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onExportTable?(table)
        }

        @objc private func handleImport(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onImportInto?(table)
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return root.children.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return root.children[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarNode)?.children.isEmpty == false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = SidebarCellView()
                cell.identifier = identifier
            }
            (cell as? SidebarCellView)?.configure(node: node)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            22
        }

        @MainActor @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
            if let table = node.openableTable {
                onOpenTable(table)
            } else if sender.isItemExpanded(node) {
                sender.collapseItem(node)
            } else {
                sender.expandItem(node)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            root: SidebarNode.build(from: snapshot),
            onOpenTable: onOpenTable,
            onCopyTable: onCopyTable,
            onExportTable: onExportTable,
            onImportInto: onImportInto
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutline()
        outline.coordinatorRef = context.coordinator
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Main"))
        column.isEditable = false
        column.resizingMask = [.autoresizingMask]
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        // Expand the database + top-level schemas by default.
        DispatchQueue.main.async {
            outline.reloadData()
            outline.expandItem(context.coordinator.root)
            for schema in context.coordinator.root.children {
                outline.expandItem(schema)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        let newRoot = SidebarNode.build(from: snapshot)
        context.coordinator.root = newRoot
        outline.reloadData()
        outline.expandItem(newRoot)
        for schema in newRoot.children {
            outline.expandItem(schema)
        }
    }
}

private final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = NSFont.systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        secondary.font = NSFont.systemFont(ofSize: 11)
        secondary.textColor = .tertiaryLabelColor
        secondary.lineBreakMode = .byTruncatingTail
        secondary.alignment = .right

        let stack = NSStackView(views: [icon, title, secondary])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondary.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        self.textField = title
        self.imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(node: SidebarNode) {
        icon.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        title.stringValue = node.displayName
        if let s = node.secondary {
            secondary.stringValue = s
            secondary.isHidden = false
        } else {
            secondary.stringValue = ""
            secondary.isHidden = true
        }
    }
}

/// NSOutlineView subclass that delegates right-click menu construction to
/// the SidebarOutlineView coordinator so we can build per-row context
/// menus (Open / Copy to… / Export… / Import CSV).
final class SidebarOutline: NSOutlineView {
    weak var coordinatorRef: SidebarOutlineView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        // Select the row that was right-clicked so the menu has visual
        // anchor; this matches Finder behaviour.
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return coordinatorRef?.menu(forRow: row, in: self)
    }
}
