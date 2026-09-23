import AppKit
import SwiftUI

/// Class-backed tree node used as item identity for `NSOutlineView`.
/// SwiftUI value types can't satisfy NSOutlineView's identity-by-pointer
/// requirement, so we mirror the snapshot into these. Every node carries a
/// stable string `id` so expansion and selection survive rebuilds.
@MainActor
final class SidebarNode {
    enum Section: String {
        case pinned, recent

        var title: String {
            switch self {
            case .pinned: return "Pinned"
            case .recent: return "Recent"
            }
        }
    }

    enum Kind {
        case section(Section)
        case schema(name: String)
        case table(TableNode)
        case columns(ofTable: TableNode)   // group node so columns nest one extra level
        case column(ColumnNode)
        case partitions(ofTable: TableNode)
        case functionsGroup(schema: String)  // group node holding a schema's routines
        case function(FunctionNode)
        /// Filter hit on a column: shown as `table.column`, opens the table.
        case columnMatch(TableNode, ColumnNode)
    }

    let id: String
    let kind: Kind
    weak var parent: SidebarNode?
    /// Filter-mode schema rows show their hit count here.
    var countBadge: Int?
    private var storedChildren: [SidebarNode]?

    init(id: String, kind: Kind, children: [SidebarNode]? = nil) {
        self.id = id
        self.kind = kind
        self.storedChildren = children
        children?.forEach { $0.parent = self }
    }

    /// Column nodes are materialised on first expansion — a 10k-table
    /// schema would otherwise allocate ~200k column nodes per rebuild.
    var children: [SidebarNode] {
        if let storedChildren { return storedChildren }
        var built: [SidebarNode] = []
        if case .columns(let table) = kind {
            built = table.columns.map {
                SidebarNode(id: "\(id)/\($0.name)", kind: .column($0))
            }
            built.forEach { $0.parent = self }
        }
        storedChildren = built
        return built
    }

    var isExpandable: Bool {
        switch kind {
        case .columns(let t): return !t.columns.isEmpty
        case .column, .function, .columnMatch: return false
        default: return !children.isEmpty
        }
    }

    var displayName: String {
        switch kind {
        case .section(let s): return s.title
        case .schema(let n): return n
        case .table(let t): return t.name
        case .columns: return "columns"
        case .column(let c): return c.name
        case .partitions: return "partitions"
        case .functionsGroup: return "functions"
        case .function(let f): return f.name
        case .columnMatch(let t, let c): return "\(t.name).\(c.name)"
        }
    }

    var secondary: String? {
        switch kind {
        case .table(let t):
            if let p = parent, case .section = p.kind { return t.schema }
            switch (t.kind, t.flavor) {
            case (.table, .plain): return t.isExtensionOwned ? "ext" : nil
            default: return t.kindLabel
            }
        case .column(let c): return c.typeName + (c.nullable ? "" : " NOT NULL")
        case .columnMatch(_, let c): return c.typeName
        case .function(let f):
            switch f.kind {
            case .function: return nil
            case .procedure: return "proc"
            case .aggregate: return "agg"
            case .window: return "window"
            }
        case .schema:
            if let n = countBadge { return "\(n)" }
            return children.isEmpty ? "empty" : nil
        case .partitions: return "\(children.count)"
        case .section, .columns, .functionsGroup: return nil
        }
    }

    var symbol: String {
        switch kind {
        case .section(.pinned): return "pin"
        case .section(.recent): return "clock"
        case .schema: return "folder"
        case .table(let t): return t.symbolName
        case .columns: return "list.bullet.rectangle"
        case .column: return "circle.dotted"
        case .partitions: return "square.split.1x2"
        case .functionsGroup: return "function"
        case .function: return "f.cursive"
        case .columnMatch: return "circle.dotted"
        }
    }

    /// Relation this row opens on activation.
    var openableTable: TableNode? {
        switch kind {
        case .table(let t), .columnMatch(let t, _): return t
        default: return nil
        }
    }

    /// Functions open the editor sheet on activation.
    var openableFunction: FunctionNode? {
        if case .function(let f) = kind { return f } else { return nil }
    }

    /// Schema the row belongs to — drives "New query here" and ⌘T scoping.
    var schemaName: String? {
        switch kind {
        case .schema(let n), .functionsGroup(let n): return n
        case .table(let t), .columns(let t), .partitions(let t), .columnMatch(let t, _): return t.schema
        case .function(let f): return f.schema
        case .column: return parent?.schemaName
        case .section: return nil
        }
    }

    var isSection: Bool { if case .section = kind { return true } else { return false } }
}

// MARK: - Tree building (pure)

/// Everything that decides the tree's shape, apart from the filter. The
/// outline only rebuilds when this changes — comparing it is cheap because
/// an unchanged `SchemaSnapshot` shares array storage, and `Array ==`
/// short-circuits on identical buffers.
struct SidebarContent: Equatable {
    var snapshot: SchemaSnapshot
    var showExtensionObjects: Bool = false
    var pinned: [String] = []
    var recents: [String] = []
}

struct SidebarFilterKey: Equatable {
    var term: String
    var includeColumns: Bool

    var isActive: Bool { !term.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum SidebarUpdate: Equatable {
    case none, refilter, rebuild
}

@MainActor
enum SidebarTree {
    /// What `updateNSView` has to do: nothing (the common case — a parent
    /// re-render with identical inputs), re-run the filter, or rebuild.
    static func update(oldContent: SidebarContent?, oldFilter: SidebarFilterKey?,
                       newContent: SidebarContent, newFilter: SidebarFilterKey) -> SidebarUpdate {
        if oldContent != newContent { return .rebuild }
        if oldFilter != newFilter { return .refilter }
        return .none
    }

    struct Built {
        var roots: [SidebarNode]
        var nodesByID: [String: SidebarNode]
    }

    static func build(_ content: SidebarContent) -> Built {
        var byID: [String: SidebarNode] = [:]
        let showExt = content.showExtensionObjects
        var tablesByID: [String: TableNode] = [:]
        for s in content.snapshot.schemas { for t in s.tables { tablesByID[t.id] = t } }

        var roots = sections(content, tablesByID: tablesByID)

        // Partitions nest under their parent even across schemas, so the
        // parent→children map is global.
        func visible(_ t: TableNode) -> Bool { showExt || !t.isExtensionOwned }
        var partitionsByParent: [String: [TableNode]] = [:]
        for s in content.snapshot.schemas where showExt || !s.isExtensionOwned {
            for t in s.tables where visible(t) {
                if let p = t.partitionOf, let parent = tablesByID[p], visible(parent) {
                    partitionsByParent[p, default: []].append(t)
                }
            }
        }

        for schema in content.snapshot.schemas {
            if schema.isExtensionOwned && !showExt { continue }
            var children: [SidebarNode] = []
            for t in schema.tables where visible(t) {
                if let p = t.partitionOf, let parent = tablesByID[p], visible(parent) { continue }
                children.append(tableNode(t, partitionsByParent: partitionsByParent, byID: &byID))
            }
            let fns = schema.functions.filter { showExt || !$0.isExtensionOwned }
            if !fns.isEmpty {
                let fnNodes = fns.map { f -> SidebarNode in
                    let n = SidebarNode(id: "function:\(f.id)", kind: .function(f))
                    byID[n.id] = n
                    return n
                }
                let group = SidebarNode(id: "functions:\(schema.name)", kind: .functionsGroup(schema: schema.name), children: fnNodes)
                byID[group.id] = group
                children.append(group)
            }
            let node = SidebarNode(id: "schema:\(schema.name)", kind: .schema(name: schema.name), children: children)
            byID[node.id] = node
            roots.append(node)
        }
        for r in roots where r.isSection {
            byID[r.id] = r
            for c in r.children { byID[c.id] = c }
        }
        return Built(roots: roots, nodesByID: byID)
    }

    /// Only the Pinned / Recent lists differ — the schema tree (10k+ nodes
    /// on big databases) can stay; just the section roots are swapped.
    static func onlySectionsChanged(from old: SidebarContent?, to new: SidebarContent) -> Bool {
        guard let old, old != new else { return false }
        return old.snapshot == new.snapshot && old.showExtensionObjects == new.showExtensionObjects
    }

    /// The Pinned and Recent section roots (absent when empty).
    static func sections(_ content: SidebarContent, tablesByID: [String: TableNode]? = nil) -> [SidebarNode] {
        let lookup: [String: TableNode]
        if let tablesByID {
            lookup = tablesByID
        } else {
            let wanted = Set(content.pinned).union(content.recents)
            var found: [String: TableNode] = [:]
            for s in content.snapshot.schemas {
                for t in s.tables where wanted.contains(t.id) { found[t.id] = t }
            }
            lookup = found
        }
        func sectionNode(_ section: SidebarNode.Section, ids: [String]) -> SidebarNode? {
            let nodes = ids.compactMap { id -> SidebarNode? in
                guard let t = lookup[id] else { return nil }
                return SidebarNode(id: "\(section.rawValue)/table:\(t.id)", kind: .table(t), children: [])
            }
            guard !nodes.isEmpty else { return nil }
            return SidebarNode(id: "section:\(section.rawValue)", kind: .section(section), children: nodes)
        }
        var out: [SidebarNode] = []
        if let pinned = sectionNode(.pinned, ids: content.pinned) { out.append(pinned) }
        let pinnedSet = Set(content.pinned)
        if let recent = sectionNode(.recent, ids: content.recents.filter { !pinnedSet.contains($0) }) {
            out.append(recent)
        }
        return out
    }

    private static func tableNode(_ t: TableNode, partitionsByParent: [String: [TableNode]],
                                  byID: inout [String: SidebarNode]) -> SidebarNode {
        var kids: [SidebarNode] = [
            SidebarNode(id: "columns:\(t.id)", kind: .columns(ofTable: t))
        ]
        if let parts = partitionsByParent[t.id], !parts.isEmpty {
            let partNodes = parts.map { tableNode($0, partitionsByParent: partitionsByParent, byID: &byID) }
            let group = SidebarNode(id: "partitions:\(t.id)", kind: .partitions(ofTable: t), children: partNodes)
            byID[group.id] = group
            kids.append(group)
        }
        let node = SidebarNode(id: "table:\(t.id)", kind: .table(t), children: kids)
        byID[node.id] = node
        return node
    }

    static let filterResultLimit = 2000

    /// Filter results in their real schema grouping, best match first
    /// within each schema.
    static func buildFiltered(index: SchemaIndex, filter: SidebarFilterKey, showExtensionObjects: Bool) -> Built {
        let hits = index.fuzzy(filter.term, includeColumns: filter.includeColumns, limit: filterResultLimit)
        var bySchema: [String: [SidebarNode]] = [:]
        var order: [String] = []
        var byID: [String: SidebarNode] = [:]
        for hit in hits {
            let e = hit.entry
            if e.isExtensionOwned && !showExtensionObjects { continue }
            let node: SidebarNode
            switch e.kind {
            case .relation:
                guard let id = e.tableID, let t = index.tablesByID[id] else { continue }
                node = SidebarNode(id: "filter/table:\(t.id)", kind: .table(t),
                                   children: [SidebarNode(id: "filter/columns:\(t.id)", kind: .columns(ofTable: t))])
            case .function:
                guard let id = e.functionID, let f = index.functionsByID[id] else { continue }
                node = SidebarNode(id: "filter/function:\(f.id)", kind: .function(f))
            case .column:
                guard let id = e.tableID, let t = index.tablesByID[id],
                      let c = t.columns.first(where: { $0.name == e.name }) else { continue }
                node = SidebarNode(id: "filter/column:\(t.id).\(c.name)", kind: .columnMatch(t, c))
            }
            if bySchema[e.schema] == nil { order.append(e.schema) }
            bySchema[e.schema, default: []].append(node)
            byID[node.id] = node
        }
        let roots = order.sorted().map { name -> SidebarNode in
            let kids = bySchema[name] ?? []
            let n = SidebarNode(id: "filter/schema:\(name)", kind: .schema(name: name), children: kids)
            n.countBadge = kids.count
            byID[n.id] = n
            return n
        }
        return Built(roots: roots, nodesByID: byID)
    }

    /// First-connect expansion: with more than three non-empty schemas only
    /// the preferred one (search_path head, else `public`) starts open, so
    /// the tree doesn't open as a wall of tables.
    static func defaultExpansion(for snapshot: SchemaSnapshot, preferredSchema: String?) -> Set<String> {
        var out: Set<String> = ["section:pinned", "section:recent"]
        let nonEmpty = snapshot.schemas.filter { !$0.isEmpty }
        if nonEmpty.count <= 3 {
            for s in nonEmpty { out.insert("schema:\(s.name)") }
            return out
        }
        let names = Set(snapshot.schemas.map(\.name))
        if let p = preferredSchema, names.contains(p) {
            out.insert("schema:\(p)")
        } else if names.contains("public") {
            out.insert("schema:public")
        }
        return out
    }
}

// MARK: - Controller (SwiftUI → AppKit commands)

/// Imperative handle the SwiftUI side uses to drive the AppKit outline and
/// filter field: focus moves, reveal, open-top-match. Held in `@State` by
/// the window content; the coordinator registers itself on creation.
@MainActor
final class SidebarController {
    fileprivate weak var coordinator: SidebarOutlineView.Coordinator?
    weak var filterField: NSSearchField?

    func focusFilter() {
        guard let field = filterField, let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func focusOutline(selectFirst: Bool = false) {
        coordinator?.focus(selectFirst: selectFirst)
    }

    /// Select + scroll to the relation's row, expanding only its ancestors.
    func reveal(tableID: String) {
        coordinator?.reveal(tableID: tableID)
    }

    /// Return in the filter field: open the best match.
    func openFirstMatch() {
        coordinator?.openFirstMatch()
    }

    /// Schema of the selected row, if any.
    var selectedSchema: String? { coordinator?.selectedNode?.schemaName }

    func collapseAll() { coordinator?.collapseAll() }

    /// Apply `term` to the tree right now instead of on the next SwiftUI
    /// pass, so a Return/↓ typed straight after the last keystroke acts on
    /// the up-to-date results.
    func syncFilter(_ term: String) { coordinator?.syncFilter(term) }
}

// MARK: - NSViewRepresentable

struct SidebarOutlineView: NSViewRepresentable {
    let content: SidebarContent
    var filter: SidebarFilterKey = SidebarFilterKey(term: "", includeColumns: false)
    let controller: SidebarController
    /// Mutable expansion state owned by the window's workspace.
    let workspace: WorkspaceState
    var preferredSchema: String?
    let onOpenTable: (TableNode) -> Void
    var onPreviewTable: ((TableNode) -> Void)? = nil
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
    var onEditComments: ((TableNode) -> Void)? = nil
    var onRenameSchema: ((String) -> Void)? = nil
    var onDropSchema: ((String) -> Void)? = nil
    var onDuplicateSchema: ((String) -> Void)? = nil
    var onCreateSchema: (() -> Void)? = nil
    /// New table in the given schema (nil → let the sheet pick the schema).
    var onNewTable: ((String?) -> Void)? = nil
    var onFindUsages: ((TableNode) -> Void)? = nil
    var onOpenFunction: ((FunctionNode) -> Void)? = nil
    var onNewFunction: ((String?) -> Void)? = nil
    var onRunFunction: ((FunctionNode) -> Void)? = nil
    var onTruncate: ((TableNode) -> Void)? = nil
    var onGenerateData: ((TableNode) -> Void)? = nil
    var onNewIndex: ((TableNode) -> Void)? = nil
    var onEditView: ((TableNode) -> Void)? = nil
    var onShowERD: ((String) -> Void)? = nil
    /// Scratchpad with `search_path` preset to the schema.
    var onNewQuery: ((String) -> Void)? = nil
    var onTogglePin: ((TableNode) -> Void)? = nil
    var onHideSchema: ((String) -> Void)? = nil
    var onShowOnlySchema: ((String) -> Void)? = nil
    var onClearRecents: (() -> Void)? = nil
    var onClearFilter: (() -> Void)? = nil
    var onToggleExtensionObjects: (() -> Void)? = nil

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: SidebarOutlineView
        weak var outline: SidebarOutline?
        private(set) var roots: [SidebarNode] = []
        private var nodesByID: [String: SidebarNode] = [:]
        private var fullBuild: SidebarTree.Built?
        private(set) var index: SchemaIndex?
        private var content: SidebarContent?
        private var filter: SidebarFilterKey?
        private var isRestoring = false
        private var highlight: String = ""

        init(parent: SidebarOutlineView) {
            self.parent = parent
        }

        var isFiltering: Bool { filter?.isActive ?? false }

        var selectedNode: SidebarNode? {
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return outline.item(atRow: outline.selectedRow) as? SidebarNode
        }

        private var expanded: Set<String> {
            get { parent.workspace.expandedSidebarNodes ?? [] }
            set {
                parent.workspace.expandedSidebarNodes = newValue
                SessionStateStore.shared.scheduleSnapshot(delay: 1.5)
            }
        }

        // MARK: Apply

        func apply(content newContent: SidebarContent, filter newFilter: SidebarFilterKey) {
            guard let outline else { return }
            switch SidebarTree.update(oldContent: content, oldFilter: filter,
                                      newContent: newContent, newFilter: newFilter) {
            case .none:
                return
            case .rebuild where filter == newFilter && SidebarTree.onlySectionsChanged(from: content, to: newContent):
                content = newContent
                swapSections(SidebarTree.sections(newContent), in: outline)
            case .rebuild:
                let snapshotChanged = content?.snapshot != newContent.snapshot
                content = newContent
                filter = newFilter
                fullBuild = SidebarTree.build(newContent)
                if snapshotChanged || index == nil { index = SchemaIndex(snapshot: newContent.snapshot) }
                if parent.workspace.expandedSidebarNodes == nil, !newContent.snapshot.schemas.isEmpty {
                    parent.workspace.expandedSidebarNodes = SidebarTree.defaultExpansion(
                        for: newContent.snapshot, preferredSchema: parent.preferredSchema)
                }
                reload(outline)
            case .refilter:
                filter = newFilter
                reload(outline)
            }
        }

        /// Replace just the Pinned / Recent roots, leaving the schema tree's
        /// nodes, rows and expansion alone.
        private func swapSections(_ fresh: [SidebarNode], in outline: NSOutlineView) {
            guard var built = fullBuild else { return }
            let oldSections = built.roots.filter(\.isSection)
            for node in oldSections {
                built.nodesByID.removeValue(forKey: node.id)
                for child in node.children { built.nodesByID.removeValue(forKey: child.id) }
            }
            for node in fresh {
                built.nodesByID[node.id] = node
                for child in node.children { built.nodesByID[child.id] = child }
            }
            built.roots = fresh + built.roots.filter { !$0.isSection }
            fullBuild = built
            guard !isFiltering else { return }
            roots = built.roots
            nodesByID = built.nodesByID
            isRestoring = true
            outline.beginUpdates()
            if !oldSections.isEmpty {
                outline.removeItems(at: IndexSet(integersIn: 0..<oldSections.count), inParent: nil, withAnimation: [])
            }
            if !fresh.isEmpty {
                outline.insertItems(at: IndexSet(integersIn: 0..<fresh.count), inParent: nil, withAnimation: [])
            }
            outline.endUpdates()
            let exp = expanded
            for node in fresh where exp.contains(node.id) { outline.expandItem(node) }
            isRestoring = false
        }

        func syncFilter(_ term: String) {
            guard let content else { return }
            apply(content: content, filter: SidebarFilterKey(term: term, includeColumns: filter?.includeColumns ?? false))
        }

        private func reload(_ outline: NSOutlineView) {
            let selectedID = selectedNode?.id
            let scrollOrigin = outline.enclosingScrollView?.contentView.bounds.origin
            if let filter, filter.isActive, let index {
                let built = SidebarTree.buildFiltered(index: index, filter: filter,
                                                      showExtensionObjects: content?.showExtensionObjects ?? false)
                roots = built.roots
                nodesByID = built.nodesByID
                highlight = filter.term
            } else {
                roots = fullBuild?.roots ?? []
                nodesByID = fullBuild?.nodesByID ?? [:]
                highlight = ""
            }
            isRestoring = true
            outline.reloadData()
            if isFiltering {
                for r in roots { outline.expandItem(r) }
            } else {
                let exp = expanded
                func restore(_ node: SidebarNode) {
                    guard exp.contains(node.id) else { return }
                    outline.expandItem(node)
                    for child in node.children where child.isExpandable { restore(child) }
                }
                for r in roots { restore(r) }
            }
            isRestoring = false
            if let selectedID, let node = nodesByID[selectedID] {
                let row = outline.row(forItem: node)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            if !isFiltering, let scrollOrigin, let clip = outline.enclosingScrollView?.contentView {
                clip.scroll(to: scrollOrigin)
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
            } else if isFiltering {
                outline.scrollRowToVisible(0)
            }
        }

        // MARK: Commands

        func focus(selectFirst: Bool) {
            guard let outline, let window = outline.window else { return }
            window.makeFirstResponder(outline)
            if selectFirst || outline.selectedRow < 0 {
                if let row = firstOpenableRow() ?? (outline.numberOfRows > 0 ? 0 : nil) {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            }
        }

        private func firstOpenableRow() -> Int? {
            guard let outline else { return nil }
            for row in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: row) as? SidebarNode,
                   n.openableTable != nil || n.openableFunction != nil { return row }
            }
            return nil
        }

        func openFirstMatch() {
            guard let outline, let row = firstOpenableRow(),
                  let node = outline.item(atRow: row) as? SidebarNode else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            activate(node, in: outline)
        }

        func reveal(tableID: String) {
            guard let outline else { return }
            if let sel = selectedNode, sel.openableTable?.id == tableID { return }
            let candidates = isFiltering ? ["filter/table:\(tableID)"] : ["table:\(tableID)"]
            guard let node = candidates.compactMap({ nodesByID[$0] }).first else {
                outline.deselectAll(nil)
                return
            }
            var chain: [SidebarNode] = []
            var p = node.parent
            while let cur = p { chain.insert(cur, at: 0); p = cur.parent }
            for ancestor in chain where !outline.isItemExpanded(ancestor) { outline.expandItem(ancestor) }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        func collapseAll() {
            guard let outline else { return }
            for r in roots where !r.isSection { outline.collapseItem(r, collapseChildren: true) }
        }

        func activate(_ node: SidebarNode, in outline: NSOutlineView) {
            if let table = node.openableTable {
                parent.onOpenTable(table)
            } else if let fn = node.openableFunction {
                parent.onOpenFunction?(fn)
            } else if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        }

        func preview(_ node: SidebarNode) {
            if let table = node.openableTable { parent.onPreviewTable?(table) }
        }

        // MARK: Menus

        func menu(forRow row: Int, in outline: NSOutlineView) -> NSMenu? {
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return backgroundMenu() }
            switch node.kind {
            case .section(let s):
                return sectionMenu(s)
            case .schema(let name):
                return schemaMenu(name: name)
            case .table(let table), .columnMatch(let table, _):
                return tableMenu(for: table)
            case .function(let fn):
                return functionMenu(for: fn)
            case .functionsGroup(let schema):
                return functionsGroupMenu(schema: schema)
            case .partitions(let t):
                return tableMenu(for: t)
            case .columns, .column:
                return nil
            }
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            ClosureMenuItem(title: title, action: action)
        }

        private func sectionMenu(_ section: SidebarNode.Section) -> NSMenu? {
            let menu = NSMenu()
            if section == .recent, let clear = parent.onClearRecents {
                menu.addItem(item("Clear Recent Tables", clear))
            }
            return menu.items.isEmpty ? nil : menu
        }

        /// Right-click on empty space: database-level actions.
        func backgroundMenu() -> NSMenu? {
            let menu = NSMenu()
            if let newTable = parent.onNewTable { menu.addItem(item("New Table…") { newTable(nil) }) }
            if let create = parent.onCreateSchema { menu.addItem(item("New Schema…", create)) }
            if let toggle = parent.onToggleExtensionObjects {
                menu.addItem(.separator())
                let ext = item("Show Extension Objects", toggle)
                ext.state = (content?.showExtensionObjects ?? false) ? .on : .off
                menu.addItem(ext)
            }
            if outline != nil {
                menu.addItem(item("Collapse All") { [weak self] in self?.collapseAll() })
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func functionMenu(for fn: FunctionNode) -> NSMenu? {
            let menu = NSMenu()
            let isProc = fn.kind == .procedure
            if let run = parent.onRunFunction {
                menu.addItem(item("\(isProc ? "Call" : "Run") \(isProc ? "procedure" : "function")…") { run(fn) })
            }
            if let open = parent.onOpenFunction {
                menu.addItem(item("Edit \(isProc ? "procedure" : "function")…") { open(fn) })
            }
            if let newQuery = parent.onNewQuery {
                menu.addItem(item("New Query in “\(fn.schema)”") { newQuery(fn.schema) })
            }
            if let new = parent.onNewFunction {
                menu.addItem(.separator())
                menu.addItem(item("New function…") { new(fn.schema) })
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func functionsGroupMenu(schema: String) -> NSMenu? {
            guard let new = parent.onNewFunction else { return nil }
            let menu = NSMenu()
            menu.addItem(item("New function in “\(schema)”…") { new(schema) })
            return menu
        }

        private func schemaMenu(name: String) -> NSMenu? {
            let menu = NSMenu()
            if let newQuery = parent.onNewQuery {
                menu.addItem(item("New Query in “\(name)”") { newQuery(name) })
                menu.addItem(.separator())
            }
            if let newTable = parent.onNewTable {
                menu.addItem(item("New table in “\(name)”…") { newTable(name) })
            }
            if let newFn = parent.onNewFunction {
                menu.addItem(item("New function in “\(name)”…") { newFn(name) })
            }
            if parent.onNewTable != nil || parent.onNewFunction != nil { menu.addItem(.separator()) }
            if let erd = parent.onShowERD {
                menu.addItem(item("Show ERD…") { erd(name) })
                menu.addItem(.separator())
            }
            if let hide = parent.onHideSchema { menu.addItem(item("Hide Schema") { hide(name) }) }
            if let only = parent.onShowOnlySchema { menu.addItem(item("Show Only This Schema") { only(name) }) }
            if parent.onHideSchema != nil || parent.onShowOnlySchema != nil { menu.addItem(.separator()) }
            if let create = parent.onCreateSchema { menu.addItem(item("New schema…", create)) }
            if let dup = parent.onDuplicateSchema { menu.addItem(item("Duplicate schema…") { dup(name) }) }
            if let rename = parent.onRenameSchema { menu.addItem(item("Rename schema…") { rename(name) }) }
            if let drop = parent.onDropSchema {
                menu.addItem(.separator())
                menu.addItem(item("Drop schema…") { drop(name) })
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func tableMenu(for table: TableNode) -> NSMenu {
            let p = parent
            let menu = NSMenu()
            menu.addItem(item("Open in Tab") { p.onOpenTable(table) })
            if let structure = p.onShowStructure { menu.addItem(item("Show Structure") { structure(table) }) }
            if let ddl = p.onShowDDL { menu.addItem(item("Show CREATE SQL") { ddl(table) }) }
            if let pin = p.onTogglePin {
                let pinned = content?.pinned.contains(table.id) ?? false
                menu.addItem(item(pinned ? "Unpin from Sidebar" : "Pin to Sidebar") { pin(table) })
            }
            if let newQuery = p.onNewQuery {
                menu.addItem(item("New Query in “\(table.schema)”") { newQuery(table.schema) })
            }
            menu.addItem(item("Copy Qualified Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(table.qualifiedName, forType: .string)
            })
            menu.addItem(.separator())
            if let comments = p.onEditComments { menu.addItem(item("Edit comments…") { comments(table) }) }
            if let usages = p.onFindUsages { menu.addItem(item("Find usages…") { usages(table) }) }
            if let editView = p.onEditView, table.kind != .table {
                menu.addItem(item("Edit view definition…") { editView(table) })
            }
            if table.kind == .table {
                if let idx = p.onNewIndex { menu.addItem(item("New index…") { idx(table) }) }
                if let gen = p.onGenerateData { menu.addItem(item("Generate data…") { gen(table) }) }
                if let trunc = p.onTruncate { menu.addItem(item("Truncate…") { trunc(table) }) }
            }
            if let maintenance = p.onMaintenance, table.kind != .view {
                menu.addItem(.separator())
                let maint = NSMenuItem(title: "Maintenance", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for action in AdminActions.Maintenance.allCases {
                    let mi = item(action.label) { maintenance(table, action) }
                    mi.toolTip = action.help
                    sub.addItem(mi)
                }
                maint.submenu = sub
                menu.addItem(maint)
            }
            if let refresh = p.onRefreshMatView, table.kind == .materializedView {
                menu.addItem(item("Refresh") { refresh(table, false) })
                let refreshC = item("Refresh CONCURRENTLY") { refresh(table, true) }
                refreshC.toolTip = "Requires a unique index on the matview. Fails otherwise."
                menu.addItem(refreshC)
            }
            menu.addItem(.separator())
            if let copy = p.onCopyTable { menu.addItem(item("Copy table to…") { copy(table) }) }
            if let exp = p.onExportTable { menu.addItem(item("Export…") { exp(table) }) }
            if let imp = p.onImportInto { menu.addItem(item("Import CSV into this table…") { imp(table) }) }
            return menu
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child childIndex: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return roots[childIndex] }
            return node.children[childIndex]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarNode)?.isExpandable ?? false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: SidebarCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView {
                cell = reused
            } else {
                cell = SidebarCellView()
                cell.identifier = identifier
            }
            cell.configure(node: node, highlight: highlight)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? SidebarNode)?.isSection == true ? 24 : 22
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? SidebarNode)?.displayName
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isRestoring, !isFiltering,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            var set = expanded
            if set.insert(node.id).inserted { expanded = set }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isRestoring, !isFiltering,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            var set = expanded
            if set.remove(node.id) != nil { expanded = set }
        }

        @objc func handleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode,
                  let event = NSApp.currentEvent, event.clickCount == 1,
                  !event.modifierFlags.contains(.command) else { return }
            // Clicks on the disclosure triangle only toggle expansion.
            let point = sender.convert(event.locationInWindow, from: nil)
            if sender.frameOfOutlineCell(atRow: row).contains(point) { return }
            preview(node)
        }

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
            activate(node, in: sender)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
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
        outline.allowsTypeSelect = true
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.handleClick(_:))
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Main"))
        column.isEditable = false
        column.resizingMask = [.autoresizingMask]
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        context.coordinator.outline = outline
        controller.coordinator = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        context.coordinator.apply(content: content, filter: filter)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        context.coordinator.apply(content: content, filter: filter)
    }
}

/// NSMenuItem that runs a closure — keeps the context menus declarative
/// without a selector + representedObject pair per action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        handler()
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
    func configure(node: SidebarNode, highlight: String) {
        icon.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: node.displayName)
        let name = node.displayName
        if node.isSection {
            title.attributedStringValue = NSAttributedString(string: name.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        } else if !highlight.isEmpty, node.openableTable != nil || node.openableFunction != nil {
            let attr = NSMutableAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ])
            for r in CommandMatcher.matchedRanges(in: name, needle: highlight) {
                attr.addAttributes([
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor,
                ], range: NSRange(r, in: name))
            }
            title.attributedStringValue = attr
        } else {
            title.font = NSFont.systemFont(ofSize: 12)
            title.textColor = .labelColor
            title.stringValue = name
        }
        if let s = node.secondary {
            secondary.stringValue = s
            secondary.isHidden = false
        } else {
            secondary.stringValue = ""
            secondary.isHidden = true
        }
    }
}

/// NSOutlineView subclass: per-row context menus through the coordinator,
/// and keyboard activation (Return opens, Space previews, Esc clears the
/// filter) on top of the native arrows + type-select.
final class SidebarOutline: NSOutlineView {
    weak var coordinatorRef: SidebarOutlineView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return coordinatorRef?.backgroundMenu() }
        // Select the row that was right-clicked so the menu has visual
        // anchor; this matches Finder behaviour.
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return coordinatorRef?.menu(forRow: row, in: self)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, let coord = coordinatorRef {
            switch event.keyCode {
            case 36, 76:  // Return / Enter
                if selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode {
                    coord.activate(node, in: self)
                    return
                }
            case 49:  // Space
                if selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode,
                   node.openableTable != nil {
                    coord.preview(node)
                    return
                }
            case 53:  // Escape
                if coord.isFiltering {
                    coord.parent.onClearFilter?()
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
