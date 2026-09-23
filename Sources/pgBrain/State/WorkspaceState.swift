import Foundation
import Observation

/// Per-connection-window tab state. Tabs are either a read-only table view
/// (iter-3) or a SQL scratchpad with inline result blocks (iter-4).
///
/// Also owns the window's navigation model: preview/pinned tabs, the
/// back/forward history of tab activations, and the sidebar UI state that
/// session restore persists per window.
@MainActor
@Observable
final class WorkspaceState {
    enum TabKind: Equatable {
        case table(TableNode)
        case scratchpad(Notebook)

        static func == (lhs: TabKind, rhs: TabKind) -> Bool {
            switch (lhs, rhs) {
            case (.table(let l), .table(let r)): return l.id == r.id
            case (.scratchpad(let l), .scratchpad(let r)): return l === r
            default: return false
            }
        }
    }

    /// Which pane of a `.table` tab is currently shown. Free-floating
    /// rather than nested under `TabKind` because the picker is purely a
    /// UI concept — session restore doesn't care which pane was last
    /// active.
    enum TablePane: String, Sendable {
        case data, structure, ddl
    }

    @Observable
    final class Tab: Identifiable, Equatable {
        let id = UUID()
        var kind: TabKind
        var title: String
        /// Cross-view signal: set by sidebar context-menu items
        /// ("Show Structure", "Show CREATE SQL") to nudge an already-open
        /// table tab onto a specific pane. `TableTabView` consumes it on
        /// change and resets to nil so the same value can be sent again.
        var requestedPane: TablePane?
        /// Drives the small dot on the tab chip — only meaningful for
        /// `.table` tabs with a dirty edit buffer right now. Kept on
        /// `Tab` so the strip can render it without reaching into the
        /// per-tab content view.
        var hasPendingChanges: Bool = false {
            didSet { if hasPendingChanges { isPreview = false } }
        }
        /// Optional color accent for the tab chip. `nil` = no tint;
        /// otherwise paints the active-tab underline + a soft background
        /// in the picked color. Persisted across session restore.
        var color: Connection.ColorTag?
        /// Pulse signal: set to `true` to ask the tab strip to start an
        /// inline rename on this tab. The chip flips the flag back to
        /// `false` after consuming it so the same nudge can fire again.
        var requestedRename: Bool = false
        /// Pulse signal: set to `true` to ask the host window to pop
        /// a colour-picker dialog for this tab. Same consume-on-use
        /// contract as `requestedRename`.
        var requestedColorPicker: Bool = false
        /// Pulse signal for FK navigation: set after pushing a new
        /// WHERE clause onto `tableWhereClause` so an already-mounted
        /// `TableTabView` re-syncs its loader and re-fetches. The
        /// `.task(id:)` modifier only fires on tab creation, so we
        /// need a separate kick for the "tab already exists" case.
        var requestedFilterReload: Bool = false
        /// Persisted raw WHERE / ORDER BY clauses for `.table` tabs —
        /// just the bodies, no leading keyword. Empty = no clause.
        /// Survives session restore via `SessionState.Tab`.
        /// Filtering is an explicit action, so it promotes a preview tab.
        var tableWhereClause: String = "" {
            didSet { if tableWhereClause != oldValue, !tableWhereClause.isEmpty { isPreview = false } }
        }
        var tableOrderByClause: String = "" {
            didSet { if tableOrderByClause != oldValue, !tableOrderByClause.isEmpty { isPreview = false } }
        }
        /// Single-click "preview" tab (italic title). At most one per
        /// window; the next preview replaces it until something pins it.
        var isPreview: Bool = false {
            didSet { if oldValue, !isPreview { onPromoted?() } }
        }
        /// Fired once a preview tab becomes a kept tab (double-click, edit,
        /// filter, pin, Keep Tab Open) — the moment it counts as "opened".
        @ObservationIgnored var onPromoted: (() -> Void)?
        /// User-pinned tab: kept at the front of the strip and skipped by
        /// Close Others / Close to the Right / Close All.
        var isPinned: Bool = false
        /// The table behind this tab vanished on the last schema reload.
        var isStale: Bool = false
        /// Pane, grid/form/map mode, form row and grid scroll/cursor for
        /// `.table` tabs, kept here so switching tabs doesn't reset them.
        let tableViewState = TableTabViewState()

        init(kind: TabKind, title: String) {
            self.kind = kind
            self.title = title
        }

        static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.id == rhs.id }

        var tableNode: TableNode? {
            if case .table(let t) = kind { return t } else { return nil }
        }
    }

    /// One back/forward stop. `whereClause` is only captured for explicit
    /// navigations (FK jumps, back/forward themselves) so plain tab
    /// switching never rewrites a filter the user typed in the meantime.
    struct NavigationEntry: Equatable {
        let tabID: UUID
        var whereClause: String?
    }

    static let historyLimit = 100

    /// Distinguishes sibling windows of the same connection (one per
    /// database) when routing window-scoped notifications.
    let windowID = UUID()

    private(set) var tabs: [Tab] = []
    var selectedID: UUID? {
        didSet { recordAutomaticHistory(from: oldValue) }
    }
    private(set) var backStack: [NavigationEntry] = []
    private(set) var forwardStack: [NavigationEntry] = []
    @ObservationIgnored private var suppressHistory = false
    @ObservationIgnored private var scratchpadCounter = 0
    /// Default `search_path` new scratchpads adopt. Set by the owning
    /// `ConnectionService` from `Connection.defaultSearchPath`. Empty =
    /// leave the notebook unscoped (server default `search_path`).
    @ObservationIgnored var defaultSearchPath: String = ""
    /// Fires immediately after a tab is removed. The owning
    /// `ConnectionService` uses this to prune its loader cache, so
    /// closed-tab loaders + edit buffers don't leak.
    @ObservationIgnored var onTabClosed: ((UUID) -> Void)?
    /// Fires when a table is really opened — a kept tab, or a preview tab
    /// once it's promoted; the window wires it to the recents store.
    /// Previews don't count: recording them reshuffled the sidebar's Recent
    /// section on every single click, moving rows under a double-click.
    @ObservationIgnored var onTableOpened: ((TableNode) -> Void)?

    // MARK: Sidebar UI state (per window, persisted by SessionState)

    var sidebarVisible: Bool = true
    /// Index into `OnboardingTour.steps` while the tour is showing.
    var onboardingStep: Int?
    var sidebarFilter: String = ""
    var sidebarIncludeColumns: Bool = false
    /// Stable sidebar node ids the user has expanded. nil = never set,
    /// so the sidebar applies its first-connect default.
    @ObservationIgnored var expandedSidebarNodes: Set<String>?

    var selectedTab: Tab? {
        guard let id = selectedID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    var previewTab: Tab? { tabs.first(where: \.isPreview) }
    var canGoBack: Bool { backStack.contains { id in tabs.contains { $0.id == id.tabID } } }
    var canGoForward: Bool { forwardStack.contains { id in tabs.contains { $0.id == id.tabID } } }

    func tab(showing tableID: String) -> Tab? {
        tabs.first { $0.tableNode?.id == tableID }
    }

    /// Open `table` in a new tab, or focus the existing tab if one already
    /// shows the same `(schema, name)`. `focusPane` lets sidebar context
    /// menus route to a non-default pane: an existing tab gets its
    /// `requestedPane` poked (TableTabView watches and switches), a new
    /// tab carries the request along so its first render lands on the
    /// asked-for pane.
    ///
    /// `preview: true` (sidebar single-click) reuses the window's preview
    /// tab instead of adding one; any non-preview open of an existing
    /// preview tab pins it.
    func openTable(_ table: TableNode, focusPane: TablePane = .data, preview: Bool = false) {
        defer { if !preview { onTableOpened?(table) } }
        if let existing = tab(showing: table.id) {
            existing.requestedPane = focusPane
            if !preview { existing.isPreview = false }
            selectedID = existing.id
            return
        }
        let tab = Tab(kind: .table(table), title: table.qualifiedName)
        tab.requestedPane = focusPane
        tab.isPreview = preview
        if preview {
            tab.onPromoted = { [weak self, weak tab] in
                if let node = tab?.tableNode { self?.onTableOpened?(node) }
            }
        }
        if preview, let idx = tabs.firstIndex(where: { $0.isPreview && !$0.hasPendingChanges }) {
            let old = tabs[idx]
            tabs[idx] = tab
            pruneHistory(removing: old.id)
            selectedID = tab.id
            onTabClosed?(old.id)
        } else {
            tabs.append(tab)
            selectedID = tab.id
        }
        SessionStateStore.shared.scheduleSnapshot()
    }

    /// Always opens a fresh scratchpad — unlike table tabs we don't dedupe,
    /// since users may want multiple independent notebooks side by side.
    /// `searchPath` scopes it to a schema ("New query here"); nil falls
    /// back to the connection default.
    @discardableResult
    func openScratchpad(searchPath: String? = nil) -> Notebook {
        scratchpadCounter += 1
        let pad = Notebook(title: "Query \(scratchpadCounter)")
        let trimmed = (searchPath ?? defaultSearchPath).trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { pad.searchPath = trimmed }
        let tab = Tab(kind: .scratchpad(pad), title: pad.title)
        tabs.append(tab)
        selectedID = tab.id
        SessionStateStore.shared.scheduleSnapshot()
        return pad
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        pruneHistory(removing: id)
        if selectedID == id {
            selectedID = tabs.indices.contains(idx) ? tabs[idx].id : tabs.last?.id
        }
        onTabClosed?(id)
        SessionStateStore.shared.scheduleSnapshot()
    }

    func closeTabs(_ ids: [UUID]) {
        for id in ids { closeTab(id: id) }
    }

    // MARK: - Bulk-close targets (pinned tabs are never included)

    func idsToCloseOthers(keeping id: UUID) -> [UUID] {
        tabs.filter { $0.id != id && !$0.isPinned }.map(\.id)
    }

    func idsToCloseRight(of id: UUID) -> [UUID] {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        return tabs[(idx + 1)...].filter { !$0.isPinned }.map(\.id)
    }

    func idsToCloseAll() -> [UUID] {
        tabs.filter { !$0.isPinned }.map(\.id)
    }

    func dirtyTabs(among ids: [UUID]) -> [Tab] {
        let set = Set(ids)
        return tabs.filter { set.contains($0.id) && $0.hasPendingChanges }
    }

    // MARK: - Pin / preview

    /// Pinned tabs form a block at the front of the strip, in pin order.
    func togglePinned(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: idx)
        tab.isPinned.toggle()
        if tab.isPinned { tab.isPreview = false }
        let pinnedCount = tabs.filter(\.isPinned).count
        tabs.insert(tab, at: pinnedCount)
        SessionStateStore.shared.scheduleSnapshot()
    }

    /// Promote a preview tab to a regular one (double-click on its chip,
    /// or any explicit action on it).
    func keepTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.isPreview else { return }
        tab.isPreview = false
        SessionStateStore.shared.scheduleSnapshot()
    }

    /// Short chip label: the bare table name unless another open tab shows
    /// a same-named table from a different schema. Custom titles win.
    func displayTitle(for tab: Tab) -> String {
        guard case .table(let t) = tab.kind, tab.title == t.qualifiedName else { return tab.title }
        let collides = tabs.contains { other in
            guard other.id != tab.id, case .table(let o) = other.kind else { return false }
            return o.name == t.name && o.schema != t.schema
        }
        return collides ? t.qualifiedName : t.name
    }

    // MARK: - Keyboard-driven tab navigation

    /// Close whichever tab is currently selected. No-op when the
    /// workspace is empty so callers can fall through to a window
    /// close on ⌘W.
    func closeCurrentTab() {
        guard let id = selectedID else { return }
        closeTab(id: id)
    }

    /// Cycle to the next tab, wrapping at the end. Matches Safari /
    /// Chrome / Cmd+⌥→ behaviour.
    func nextTab() {
        guard !tabs.isEmpty else { return }
        let curr = tabs.firstIndex(where: { $0.id == selectedID }) ?? -1
        let next = (curr + 1) % tabs.count
        selectedID = tabs[next].id
    }

    /// Cycle to the previous tab, wrapping at the start.
    func previousTab() {
        guard !tabs.isEmpty else { return }
        let curr = tabs.firstIndex(where: { $0.id == selectedID }) ?? tabs.count
        let prev = (curr - 1 + tabs.count) % tabs.count
        selectedID = tabs[prev].id
    }

    /// Jump to the nth tab (0-indexed). Out-of-range is a no-op.
    /// `⌘9` traditionally jumps to the LAST tab — callers map that
    /// to `tabs.count - 1` themselves so this stays generic.
    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectedID = tabs[index].id
    }

    /// Move the tab identified by `id` to sit immediately before the tab
    /// identified by `target`. No-op if either is missing or they're the same.
    func move(id: UUID, before target: UUID) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target })
        else { return }
        let tab = tabs.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        tabs.insert(tab, at: insertAt)
        tab.isPreview = false
        SessionStateStore.shared.scheduleSnapshot()
    }

    // MARK: - Back / forward navigation

    /// Open (or focus) `table` as an explicit navigation step: the current
    /// location — including its WHERE clause — is pushed onto the back
    /// stack, so ⌘[ returns to exactly where the user was. When `where` is
    /// non-nil it replaces the target tab's WHERE clause and, for an
    /// already-mounted tab, pulses `requestedFilterReload`.
    ///
    /// This is the entry point for FK ⌘-click jumps.
    @discardableResult
    func navigate(toTable table: TableNode, where clause: String? = nil,
                  focusPane: TablePane = .data) -> Tab {
        if let current = selectedTab {
            push(historyEntry(for: current), onto: &backStack)
            forwardStack.removeAll()
        }
        let existed = tab(showing: table.id) != nil
        suppressHistory = true
        openTable(table, focusPane: focusPane, preview: false)
        suppressHistory = false
        let target = selectedTab ?? tabs[tabs.count - 1]
        if let clause {
            target.tableWhereClause = clause
            if existed { target.requestedFilterReload = true }
        }
        return target
    }

    func goBack() { step(from: &backStack, to: &forwardStack) }
    func clearHistory() {
        backStack.removeAll()
        forwardStack.removeAll()
    }
    func goForward() { step(from: &forwardStack, to: &backStack) }

    private func step(from source: inout [NavigationEntry], to dest: inout [NavigationEntry]) {
        while let entry = source.popLast() {
            guard let tab = tabs.first(where: { $0.id == entry.tabID }) else { continue }
            let current = selectedTab
            if current?.id == entry.tabID,
               entry.whereClause == nil || entry.whereClause == current?.tableWhereClause { continue }
            if let current { push(historyEntry(for: current), onto: &dest) }
            suppressHistory = true
            selectedID = tab.id
            suppressHistory = false
            if let clause = entry.whereClause, tab.tableNode != nil, tab.tableWhereClause != clause {
                tab.tableWhereClause = clause
                tab.requestedFilterReload = true
            }
            return
        }
    }

    private func historyEntry(for tab: Tab) -> NavigationEntry {
        NavigationEntry(tabID: tab.id, whereClause: tab.tableNode == nil ? nil : tab.tableWhereClause)
    }

    private func push(_ entry: NavigationEntry, onto stack: inout [NavigationEntry]) {
        if stack.last == entry { return }
        stack.append(entry)
        if stack.count > Self.historyLimit { stack.removeFirst(stack.count - Self.historyLimit) }
    }

    private func recordAutomaticHistory(from old: UUID?) {
        guard !suppressHistory, let old, old != selectedID,
              tabs.contains(where: { $0.id == old }) else { return }
        if backStack.last?.tabID == old { return }
        push(NavigationEntry(tabID: old, whereClause: nil), onto: &backStack)
        forwardStack.removeAll()
    }

    private func pruneHistory(removing id: UUID) {
        backStack.removeAll { $0.tabID == id }
        forwardStack.removeAll { $0.tabID == id }
    }

    // MARK: - Schema reload reconciliation

    struct ReconcileResult: Equatable {
        var renamed: [(from: String, to: String)] = []
        var dropped: [String] = []

        static func == (l: ReconcileResult, r: ReconcileResult) -> Bool {
            l.dropped == r.dropped && l.renamed.map(\.from) == r.renamed.map(\.from)
                && l.renamed.map(\.to) == r.renamed.map(\.to)
        }
    }

    /// Re-point open table tabs at the freshly loaded snapshot. Tabs whose
    /// relation was renamed (same oid) keep their identity — and with it
    /// their cached loader and staged edits — and get the new node; the
    /// owner then pushes it into the loader (`syncLoadersWithTabs`). Tabs
    /// whose relation vanished are closed when they were only previews and
    /// marked stale otherwise (they may hold unapplied edits).
    @discardableResult
    func reconcile(with snapshot: SchemaSnapshot) -> ReconcileResult {
        var result = ReconcileResult()
        guard !snapshot.schemas.isEmpty, tabs.contains(where: { $0.tableNode != nil }) else { return result }
        var byID: [String: TableNode] = [:]
        var byOID: [Int: TableNode] = [:]
        for s in snapshot.schemas {
            for t in s.tables {
                byID[t.id] = t
                if t.oid != 0 { byOID[t.oid] = t }
            }
        }
        var toClose: [UUID] = []
        for tab in tabs {
            guard case .table(let old) = tab.kind else { continue }
            if let fresh = byID[old.id] {
                tab.isStale = false
                if Self.relationChanged(old, fresh) {
                    var merged = fresh
                    if merged.columns.isEmpty { merged.columns = old.columns }
                    tab.kind = .table(merged)
                }
            } else if old.oid != 0, let renamed = byOID[old.oid] {
                // Same Tab, new node: its loader (and any staged edits) stay
                // keyed by tab id; the owner re-points the loader afterwards.
                var merged = renamed
                if merged.columns.isEmpty { merged.columns = old.columns }
                if tab.title == old.qualifiedName { tab.title = renamed.qualifiedName }
                tab.isStale = false
                tab.kind = .table(merged)
                result.renamed.append((old.qualifiedName, renamed.qualifiedName))
            } else {
                if !tab.isStale { result.dropped.append(old.qualifiedName) }
                if tab.isPreview && !tab.hasPendingChanges {
                    toClose.append(tab.id)
                } else {
                    tab.isStale = true
                }
            }
        }
        closeTabs(toClose)
        if !result.renamed.isEmpty { SessionStateStore.shared.scheduleSnapshot() }
        return result
    }

    /// Column lists are ignored: phase-2 enrichment fills them in on every
    /// load and swapping the node for that alone would re-render every tab.
    static func relationChanged(_ a: TableNode, _ b: TableNode) -> Bool {
        a.kind != b.kind || a.flavor != b.flavor || a.primaryKey != b.primaryKey
            || a.foreignKeys != b.foreignKeys || a.oid != b.oid
    }
}
