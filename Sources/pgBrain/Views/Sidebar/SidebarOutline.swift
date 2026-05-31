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
        case functionsGroup(schema: String)  // group node holding a schema's routines
        case function(FunctionNode)
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
            var children = tableNodes
            // Functions live in a collapsed "functions" group below the
            // schema's tables so they're browsable without cluttering
            // the common table-hunting flow.
            if !schema.functions.isEmpty {
                let fnNodes = schema.functions.map { SidebarNode(kind: .function($0)) }
                children.append(SidebarNode(kind: .functionsGroup(schema: schema.name), children: fnNodes))
            }
            return SidebarNode(kind: .schema(name: schema.name), children: children)
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
        case .functionsGroup: return "functions"
        case .function(let f): return f.name
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
        case .function(let f):
            switch f.kind {
            case .function: return nil
            case .procedure: return "proc"
            case .aggregate: return "agg"
            case .window: return "window"
            }
        case .schema, .database, .columns, .functionsGroup: return nil
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
        case .functionsGroup: return "function"
        case .function: return "f.cursive"
        }
    }

    /// Tables are the only item that opens a tab on activation.
    var openableTable: TableNode? {
        if case .table(let t) = kind { return t } else { return nil }
    }

    /// Functions open the editor sheet on activation.
    var openableFunction: FunctionNode? {
        if case .function(let f) = kind { return f } else { return nil }
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
    /// New table in the given schema (nil → let the sheet pick the schema).
    var onNewTable: ((String?) -> Void)? = nil
    /// Find usages — pops the "where is this table referenced?" sheet.
    var onFindUsages: ((TableNode) -> Void)? = nil
    /// Open a function in the editor sheet.
    var onOpenFunction: ((FunctionNode) -> Void)? = nil
    var onNewFunction: ((String?) -> Void)? = nil
    var onRunFunction: ((FunctionNode) -> Void)? = nil
    /// TRUNCATE a table (pops the confirm sheet).
    var onTruncate: ((TableNode) -> Void)? = nil
    /// Generate test data into a table.
    var onGenerateData: ((TableNode) -> Void)? = nil
    var onNewIndex: ((TableNode) -> Void)? = nil
    /// Edit a view / matview body.
    var onEditView: ((TableNode) -> Void)? = nil
    /// Open the ERD for a schema.
    var onShowERD: ((String) -> Void)? = nil

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
        var onNewTable: ((String?) -> Void)?
        var onFindUsages: ((TableNode) -> Void)?
        var onOpenFunction: ((FunctionNode) -> Void)?
        var onNewFunction: ((String?) -> Void)?
        var onRunFunction: ((FunctionNode) -> Void)?
        var onTruncate: ((TableNode) -> Void)?
        var onGenerateData: ((TableNode) -> Void)?
        var onNewIndex: ((TableNode) -> Void)?
        var onEditView: ((TableNode) -> Void)?
        var onShowERD: ((String) -> Void)?

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
            case .function(let fn):
                return functionMenu(for: fn)
            case .functionsGroup(let schema):
                return functionsGroupMenu(schema: schema)
            case .columns, .column:
                return nil
            }
        }

        private func functionMenu(for fn: FunctionNode) -> NSMenu? {
            guard onOpenFunction != nil || onRunFunction != nil else { return nil }
            let menu = NSMenu()
            let verb = fn.kind == .procedure ? "Call" : "Run"
            if onRunFunction != nil {
                let run = NSMenuItem(title: "\(verb) \(fn.kind == .procedure ? "procedure" : "function")…",
                                     action: #selector(handleRunFunction(_:)), keyEquivalent: "")
                run.target = self
                run.representedObject = FunctionBox(fn)
                menu.addItem(run)
            }
            if onOpenFunction != nil {
                let edit = NSMenuItem(title: "Edit \(fn.kind == .procedure ? "procedure" : "function")…",
                                      action: #selector(handleOpenFunction(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = FunctionBox(fn)
                menu.addItem(edit)
            }
            if onNewFunction != nil {
                menu.addItem(.separator())
                let new = NSMenuItem(title: "New function…", action: #selector(handleNewFunction(_:)), keyEquivalent: "")
                new.target = self
                new.representedObject = fn.schema
                menu.addItem(new)
            }
            return menu
        }

        private func functionsGroupMenu(schema: String) -> NSMenu? {
            guard onNewFunction != nil else { return nil }
            let menu = NSMenu()
            let new = NSMenuItem(title: "New function in “\(schema)”…", action: #selector(handleNewFunction(_:)), keyEquivalent: "")
            new.target = self
            new.representedObject = schema
            menu.addItem(new)
            return menu
        }

        private func databaseMenu() -> NSMenu? {
            guard onCreateSchema != nil || onNewTable != nil else { return nil }
            let menu = NSMenu()
            if onNewTable != nil {
                let newTable = NSMenuItem(title: "New table…", action: #selector(handleNewTable(_:)), keyEquivalent: "")
                newTable.target = self
                menu.addItem(newTable)
            }
            if onCreateSchema != nil {
                let new = NSMenuItem(title: "New schema…", action: #selector(handleCreateSchema(_:)), keyEquivalent: "")
                new.target = self
                menu.addItem(new)
            }
            return menu
        }

        private func schemaMenu(name: String) -> NSMenu? {
            guard onRenameSchema != nil || onDropSchema != nil || onCreateSchema != nil || onShowERD != nil || onNewTable != nil else { return nil }
            let menu = NSMenu()
            if onNewTable != nil {
                let newTable = NSMenuItem(title: "New table in “\(name)”…", action: #selector(handleNewTable(_:)), keyEquivalent: "")
                newTable.target = self
                newTable.representedObject = name
                menu.addItem(newTable)
            }
            if onNewFunction != nil {
                let newFn = NSMenuItem(title: "New function in “\(name)”…", action: #selector(handleNewFunction(_:)), keyEquivalent: "")
                newFn.target = self
                newFn.representedObject = name
                menu.addItem(newFn)
            }
            if onNewTable != nil || onNewFunction != nil {
                menu.addItem(.separator())
            }
            if onShowERD != nil {
                let erd = NSMenuItem(title: "Show ERD…", action: #selector(handleShowERD(_:)), keyEquivalent: "")
                erd.target = self
                erd.representedObject = name
                menu.addItem(erd)
                menu.addItem(.separator())
            }
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
            if onFindUsages != nil {
                let find = NSMenuItem(title: "Find usages…", action: #selector(handleFindUsages(_:)), keyEquivalent: "")
                find.target = self
                find.representedObject = table
                menu.addItem(find)
            }
            // View body editor — only for views / matviews.
            if onEditView != nil, table.kind != .table {
                let editView = NSMenuItem(title: "Edit view definition…", action: #selector(handleEditView(_:)), keyEquivalent: "")
                editView.target = self
                editView.representedObject = table
                menu.addItem(editView)
            }
            // Data tools — real tables only.
            if table.kind == .table {
                if onNewIndex != nil {
                    let idx = NSMenuItem(title: "New index…", action: #selector(handleNewIndex(_:)), keyEquivalent: "")
                    idx.target = self
                    idx.representedObject = table
                    menu.addItem(idx)
                }
                if onGenerateData != nil {
                    let gen = NSMenuItem(title: "Generate data…", action: #selector(handleGenerateData(_:)), keyEquivalent: "")
                    gen.target = self
                    gen.representedObject = table
                    menu.addItem(gen)
                }
                if onTruncate != nil {
                    let trunc = NSMenuItem(title: "Truncate…", action: #selector(handleTruncate(_:)), keyEquivalent: "")
                    trunc.target = self
                    trunc.representedObject = table
                    menu.addItem(trunc)
                }
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
        @objc private func handleNewTable(_ sender: NSMenuItem) {
            onNewTable?(sender.representedObject as? String)
        }
        @objc private func handleFindUsages(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onFindUsages?(table)
        }
        @objc private func handleOpenFunction(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? FunctionBox else { return }
            onOpenFunction?(box.fn)
        }
        @objc private func handleRunFunction(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? FunctionBox else { return }
            onRunFunction?(box.fn)
        }
        @objc private func handleNewFunction(_ sender: NSMenuItem) {
            onNewFunction?(sender.representedObject as? String)
        }
        @objc private func handleTruncate(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onTruncate?(table)
        }
        @objc private func handleGenerateData(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onGenerateData?(table)
        }
        @objc private func handleNewIndex(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onNewIndex?(table)
        }
        @objc private func handleEditView(_ sender: NSMenuItem) {
            guard let table = sender.representedObject as? TableNode else { return }
            onEditView?(table)
        }
        @objc private func handleShowERD(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            onShowERD?(name)
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
            } else if let fn = node.openableFunction {
                onOpenFunction?(fn)
            } else if sender.isItemExpanded(node) {
                sender.collapseItem(node)
            } else {
                sender.expandItem(node)
            }
        }
    }

    /// AppKit's `representedObject` needs a class; `FunctionNode` is a
    /// struct, so box it for the menu round-trip.
    private final class FunctionBox {
        let fn: FunctionNode
        init(_ fn: FunctionNode) { self.fn = fn }
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
        coord.onNewTable = onNewTable
        coord.onFindUsages = onFindUsages
        coord.onOpenFunction = onOpenFunction
        coord.onNewFunction = onNewFunction
        coord.onRunFunction = onRunFunction
        coord.onTruncate = onTruncate
        coord.onGenerateData = onGenerateData
        coord.onNewIndex = onNewIndex
        coord.onEditView = onEditView
        coord.onShowERD = onShowERD
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
