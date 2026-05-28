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
    /// When non-empty, only tables matching the term are shown (flat list).
    /// Computed lazily through `SchemaIndex` for O(prefix + matches).
    var filterTerm: String = ""
    let onOpenTable: (TableNode) -> Void
    var onCopyTable: ((TableNode) -> Void)? = nil
    var onExportTable: ((TableNode) -> Void)? = nil
    var onImportInto: ((TableNode) -> Void)? = nil
    var onShowStructure: ((TableNode) -> Void)? = nil
    var onShowDDL: ((TableNode) -> Void)? = nil
    /// VACUUM / ANALYZE / REINDEX — runs immediately for safe actions,
    /// confirms for destructive ones. Receiver is responsible for the
    /// confirmation flow.
    var onMaintenance: ((TableNode, AdminActions.Maintenance) -> Void)? = nil
    /// REFRESH MATERIALIZED VIEW [CONCURRENTLY]. Only offered on
    /// materialized views.
    var onRefreshMatView: ((TableNode, Bool) -> Void)? = nil
    /// Open the comments editor sheet for this table.
    var onEditComments: ((TableNode) -> Void)? = nil
    /// Schema-level: rename, drop. Receiver pops a confirmation sheet.
    var onRenameSchema: ((String) -> Void)? = nil
    var onDropSchema: ((String) -> Void)? = nil
    /// Database-level: create a new schema.
    var onCreateSchema: (() -> Void)? = nil

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var root: SidebarNode
        var filteredRoot: SidebarNode?  // non-nil = filter mode
        var index: SchemaIndex
        let onOpenTable: (TableNode) -> Void
        var onCopyTable: ((TableNode) -> Void)?
        var onExportTable: ((TableNode) -> Void)?
        var onImportInto: ((TableNode) -> Void)?
        var onShowStructure: ((TableNode) -> Void)?
        var onShowDDL: ((TableNode) -> Void)?
        var onMaintenance: ((TableNode, AdminActions.Maintenance) -> Void)?
        var onRefreshMatView: ((TableNode, Bool) -> Void)?
        var onEditComments: ((TableNode) -> Void)?
        var onRenameSchema: ((String) -> Void)?
        var onDropSchema: ((String) -> Void)?
        var onCreateSchema: (() -> Void)?

        var activeRoot: SidebarNode { filteredRoot ?? root }

        init(
            root: SidebarNode,
            index: SchemaIndex,
            onOpenTable: @escaping (TableNode) -> Void,
            onCopyTable: ((TableNode) -> Void)?,
            onExportTable: ((TableNode) -> Void)?,
            onImportInto: ((TableNode) -> Void)?,
            onShowStructure: ((TableNode) -> Void)?,
            onShowDDL: ((TableNode) -> Void)?
        ) {
            self.root = root
            self.index = index
            self.onOpenTable = onOpenTable
            self.onCopyTable = onCopyTable
            self.onExportTable = onExportTable
            self.onImportInto = onImportInto
            self.onShowStructure = onShowStructure
            self.onShowDDL = onShowDDL
        }

        /// Rebuild `filteredRoot` from `term` (empty = clear filter).
        /// Filtered root is a synthetic "search" database with one schema
        /// per matching table grouped by source schema.
        func applyFilter(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                filteredRoot = nil
                return
            }
            let matches = index.matches(trimmed)
            var bySchema: [String: [TableNode]] = [:]
            for table in matches {
                bySchema[table.schema, default: []].append(table)
            }
            let schemaNodes = bySchema.keys.sorted().map { name -> SidebarNode in
                let tables = bySchema[name]!.sorted { $0.name < $1.name }
                return SidebarNode(
                    kind: .schema(name: name),
                    children: tables.map { SidebarNode(kind: .table($0)) }
                )
            }
            filteredRoot = SidebarNode(
                kind: .database(name: "matches (\(matches.count))"),
                children: schemaNodes
            )
        }

        func menu(forRow row: Int, in outline: NSOutlineView) -> NSMenu? {
            guard let node = outline.item(atRow: row) as? SidebarNode else { return nil }
            switch node.kind {
            case .database:
                return databaseMenu()
            case .schema(let name):
                return schemaMenu(name: name)
            case .table(let table):
                return tableMenu(for: table)
            case .columns, .column:
                return nil
            }
        }

        private func databaseMenu() -> NSMenu? {
            guard onCreateSchema != nil else { return nil }
            let menu = NSMenu()
            let new = NSMenuItem(title: "New schema…", action: #selector(handleCreateSchema(_:)), keyEquivalent: "")
            new.target = self
            menu.addItem(new)
            return menu
        }

        private func schemaMenu(name: String) -> NSMenu? {
            guard onRenameSchema != nil || onDropSchema != nil || onCreateSchema != nil else { return nil }
            let menu = NSMenu()
            if onCreateSchema != nil {
                let new = NSMenuItem(title: "New schema…", action: #selector(handleCreateSchema(_:)), keyEquivalent: "")
                new.target = self
                menu.addItem(new)
            }
            if onRenameSchema != nil {
                let rename = NSMenuItem(title: "Rename schema…", action: #selector(handleRenameSchema(_:)), keyEquivalent: "")
                rename.target = self
                rename.representedObject = name
                menu.addItem(rename)
            }
            if onDropSchema != nil {
                menu.addItem(.separator())
                let drop = NSMenuItem(title: "Drop schema…", action: #selector(handleDropSchema(_:)), keyEquivalent: "")
                drop.target = self
                drop.representedObject = name
                menu.addItem(drop)
            }
            return menu
        }

        private func tableMenu(for table: TableNode) -> NSMenu {
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open in tab", action: #selector(handleOpen(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = table
            menu.addItem(open)
            if onShowStructure != nil {
                let struc = NSMenuItem(title: "Show Structure", action: #selector(handleShowStructure(_:)), keyEquivalent: "")
                struc.target = self
                struc.representedObject = table
                menu.addItem(struc)
            }
            if onShowDDL != nil {
                let ddl = NSMenuItem(title: "Show CREATE SQL", action: #selector(handleShowDDL(_:)), keyEquivalent: "")
                ddl.target = self
                ddl.representedObject = table
                menu.addItem(ddl)
            }
            if onEditComments != nil {
                let cm = NSMenuItem(title: "Edit comments…", action: #selector(handleEditComments(_:)), keyEquivalent: "")
                cm.target = self
                cm.representedObject = table
                menu.addItem(cm)
            }
            // Maintenance bloc — tables + matviews only.
            if onMaintenance != nil, table.kind != .view {
                menu.addItem(.separator())
                let maint = NSMenuItem(title: "Maintenance", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for action in AdminActions.Maintenance.allCases {
                    let item = NSMenuItem(
                        title: action.label,
                        action: #selector(handleMaintenance(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = MaintenancePayload(table: table, action: action)
                    item.toolTip = action.help
                    sub.addItem(item)
                }
                maint.submenu = sub
                menu.addItem(maint)
            }
            // Materialized view refresh.
            if onRefreshMatView != nil, table.kind == .materializedView {
                let refresh = NSMenuItem(title: "Refresh", action: #selector(handleRefreshMV(_:)), keyEquivalent: "")
                refresh.target = self
                refresh.representedObject = RefreshPayload(table: table, concurrently: false)
                menu.addItem(refresh)
                let refreshC = NSMenuItem(title: "Refresh CONCURRENTLY", action: #selector(handleRefreshMV(_:)), keyEquivalent: "")
                refreshC.target = self
                refreshC.representedObject = RefreshPayload(table: table, concurrently: true)
                refreshC.toolTip = "Requires a unique index on the matview. Fails otherwise."
                menu.addItem(refreshC)
            }
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

        private struct MaintenancePayload { let table: TableNode; let action: AdminActions.Maintenance }
        private struct RefreshPayload { let table: TableNode; let concurrently: Bool }

        @objc private func handleMaintenance(_ sender: NSMenuItem) {
            guard let p = sender.representedObject as? MaintenancePayload else { return }
            onMaintenance?(p.table, p.action)
        }
        @objc private func handleRefreshMV(_ sender: NSMenuItem) {
            guard let p = sender.representedObject as? RefreshPayload else { return }
            onRefreshMatView?(p.table, p.concurrently)
        }
        @objc private func handleEditComments(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onEditComments?(table)
        }
        @objc private func handleRenameSchema(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            onRenameSchema?(name)
        }
        @objc private func handleDropSchema(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            onDropSchema?(name)
        }
        @objc private func handleCreateSchema(_ sender: NSMenuItem) {
            onCreateSchema?()
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

        @objc private func handleShowStructure(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onShowStructure?(table)
        }

        @objc private func handleShowDDL(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onShowDDL?(table)
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return activeRoot.children.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child childIndex: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return activeRoot.children[childIndex] }
            return node.children[childIndex]
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
        let coord = Coordinator(
            root: SidebarNode.build(from: snapshot),
            index: SchemaIndex(snapshot: snapshot),
            onOpenTable: onOpenTable,
            onCopyTable: onCopyTable,
            onExportTable: onExportTable,
            onImportInto: onImportInto,
            onShowStructure: onShowStructure,
            onShowDDL: onShowDDL
        )
        propagateExtra(to: coord)
        return coord
    }

    private func propagateExtra(to coord: Coordinator) {
        coord.onCopyTable = onCopyTable
        coord.onExportTable = onExportTable
        coord.onImportInto = onImportInto
        coord.onShowStructure = onShowStructure
        coord.onShowDDL = onShowDDL
        coord.onMaintenance = onMaintenance
        coord.onRefreshMatView = onRefreshMatView
        coord.onEditComments = onEditComments
        coord.onRenameSchema = onRenameSchema
        coord.onDropSchema = onDropSchema
        coord.onCreateSchema = onCreateSchema
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
        propagateExtra(to: context.coordinator)
        // Snapshot changed?
        if !snapshotMatchesIndex(context.coordinator.index, snapshot: snapshot) {
            context.coordinator.root = SidebarNode.build(from: snapshot)
            context.coordinator.index = SchemaIndex(snapshot: snapshot)
        }
        context.coordinator.applyFilter(filterTerm)
        let active = context.coordinator.activeRoot
        outline.reloadData()
        outline.expandItem(active)
        for schema in active.children {
            outline.expandItem(schema)
        }
    }

    /// Cheap heuristic: rebuilds only when the database name or per-schema
    /// table counts change. Saves a full SidebarNode rebuild on every
    /// filter keystroke.
    private func snapshotMatchesIndex(_ index: SchemaIndex, snapshot: SchemaSnapshot) -> Bool {
        index.totalTables == snapshot.schemas.reduce(0) { $0 + $1.tables.count }
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
