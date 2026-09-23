import Foundation
import Observation
import PostgresNIO

/// Page loader + staged-change owner for one table tab. Cached per tab on
/// `ConnectionService`, so it outlives tab switches.
///
/// Every path that replaces the loaded page (paging, sorting, filtering,
/// refresh, FK jumps) goes through `request(_:change:)`, which consults
/// `DirtyGuard`: with staged changes the move is parked in
/// `pendingNavigation` until the user picks Apply / Discard / Cancel.
/// Loads carry a generation token and cancel their predecessor, so a fast
/// Next-Next can't land out of order.
@MainActor
@Observable
final class RowsLoader {
    enum State {
        case idle
        case loading
        case loaded(RowsFetcher.Page)
        case error(String)
    }

    /// A page replacement waiting on the user's Apply / Discard / Cancel.
    struct PendingNavigation: Identifiable {
        let id = UUID()
        let title: String
        let change: @MainActor (RowsLoader) -> Void
    }

    /// Ask the grid to put its cursor on a cell (e.g. a freshly added row).
    struct FocusRequest: Equatable {
        let id = UUID()
        let sourceRow: Int
        let dataColumn: Int
        let beginEditing: Bool
    }

    /// Effective table — re-assigned the first time `load()` runs so we pick
    /// up columns the background enrichment populated in the meantime.
    private(set) var table: TableNode
    @ObservationIgnored let service: ConnectionService
    /// The tab whose chip mirrors `hasPendingChanges`. Weak: the workspace
    /// owns tabs, the service owns loaders.
    @ObservationIgnored weak var tab: WorkspaceState.Tab? {
        didSet { syncPendingFlag() }
    }
    private(set) var state: State = .idle
    /// Bumps each time a freshly fetched page replaces the previous one —
    /// the grid resets selection / scroll and drops every cached cell.
    private(set) var pageGeneration = 0
    /// Bumps on in-place edits of the loaded rows (apply splice-back, draft
    /// rows added / removed) — the grid reloads but keeps its place.
    private(set) var contentRevision = 0

    let editBuffer = EditBuffer()
    private(set) var isApplying = false {
        didSet { if !isApplying { adoptDeferredTableIfClean() } }
    }
    private(set) var applyError: String?
    private(set) var applySuccess: String?
    /// Cells that were just applied — rendered with a fading green tint.
    private(set) var appliedHighlights: Set<EditBuffer.CellKey> = []

    /// Source-row indices (into the loaded page) that are draft INSERTs.
    private(set) var pendingInsertRows: Set<Int> = [] {
        didSet { stagingChanged() }
    }
    /// Source-row indices of existing rows staged for DELETE.
    private(set) var pendingDeleteRows: Set<Int> = [] {
        didSet { stagingChanged() }
    }
    /// Bumps on every staging mutation (cell edit, draft row, delete mark),
    /// so a load can tell whether the user staged something while it was
    /// in flight.
    @ObservationIgnored private(set) var stagingRevision = 0
    /// A schema reload changed this relation (e.g. its primary key) while
    /// edits were staged against the old shape; adopted once they're gone.
    @ObservationIgnored private var deferredTable: TableNode?

    var pendingNavigation: PendingNavigation?
    var focusRequest: FocusRequest?

    var hasPendingChanges: Bool {
        editBuffer.isDirty || !pendingInsertRows.isEmpty || !pendingDeleteRows.isEmpty
    }

    var rowIdentity: RowsFetcher.RowIdentity { RowsFetcher.RowIdentity.resolve(for: table) }
    var isEditable: Bool { rowIdentity.isEditable }

    private(set) var filter = RowsFetcher.Filter(whereClause: "", orderByClause: "")
    /// ⌘F find bar — client-side substring filter on the loaded page.
    var globalFilter: String = ""
    /// A refresh is in flight while the previous page stays on screen.
    private(set) var isRefreshing = false
    /// Error from the most recent refresh, shown above the kept page.
    var refreshError: String?
    private(set) var pageOffset = 0
    private(set) var pageSize = 200
    private(set) var estimatedTotal: Int64?
    private(set) var exactTotal: Int64?
    private(set) var isCountingExact = false
    private(set) var countError: String?
    private(set) var tableSizePretty: String?
    /// All foreign keys of this table, composite ones included; fetched on
    /// the first ⌘-click.
    private(set) var foreignKeys: [ForeignKeyResolver.Key]?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0

    var hasMoreAfterCurrentPage: Bool {
        if case .loaded(let page) = state { return page.truncated }
        return false
    }

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
        editBuffer.onChange = { [weak self] in self?.stagingChanged() }
    }

    private func stagingChanged() {
        stagingRevision &+= 1
        syncPendingFlag()
        adoptDeferredTableIfClean()
    }

    private func adoptDeferredTableIfClean() {
        guard let deferred = deferredTable, !hasPendingChanges, !isApplying else { return }
        deferredTable = nil
        adoptTable(deferred)
    }

    /// Point the loader at a freshly reloaded `TableNode` for the same tab
    /// (rename, primary-key or FK change). Staged edits were planned against
    /// the old key, so with anything pending the swap waits until they are
    /// applied or discarded, and the user is told.
    func adoptTable(_ fresh: TableNode) {
        guard fresh.id != table.id || WorkspaceState.relationChanged(table, fresh) else { return }
        guard !hasPendingChanges, !isApplying else {
            if deferredTable == nil {
                service.toasts.show(.info, "\(table.qualifiedName) changed on the server — apply or discard the staged edits, then refresh.")
            }
            deferredTable = fresh
            return
        }
        var merged = fresh
        if merged.columns.isEmpty { merged.columns = table.columns }
        table = merged
        foreignKeys = nil
    }

    /// What a finished load may do with the staged state: the guard only let
    /// the load start with nothing staged (or with the user's consent to
    /// drop it), so edits made while it was in flight are new work that the
    /// fresh page's row indices no longer line up with.
    nonisolated static func landingKeepsStagedEdits(revisionAtStart: Int, revisionNow: Int, hasPendingChanges: Bool) -> Bool {
        revisionAtStart != revisionNow && hasPendingChanges
    }

    /// Restore clauses persisted on the tab before the first load.
    func seedFilter(_ f: RowsFetcher.Filter) {
        guard case .idle = state else { return }
        filter = f
    }

    private func syncPendingFlag() {
        let dirty = hasPendingChanges
        if let tab, tab.hasPendingChanges != dirty { tab.hasPendingChanges = dirty }
    }

    // MARK: - Find filter

    /// Subset of the loaded page that satisfies the client-side find filter,
    /// plus each visible row's source index.
    func filteredPage() -> (RowsFetcher.Page, [Int])? {
        guard case .loaded(let base) = state else { return nil }
        let g = globalFilter.lowercased()
        if g.isEmpty {
            return (base, Array(0..<base.rows.count))
        }
        var rows: [[String?]] = []
        var sourceIndices: [Int] = []
        for (i, row) in base.rows.enumerated() where row.contains(where: { ($0?.lowercased() ?? "").contains(g) }) {
            rows.append(row)
            sourceIndices.append(i)
        }
        var filtered = base
        filtered.rows = rows
        filtered.rowLocators = base.rowLocators.map { locs in sourceIndices.map { $0 < locs.count ? locs[$0] : nil } }
        return (filtered, sourceIndices)
    }

    // MARK: - Guarded navigation

    /// Reload the current page (⌘R, Retry, after an import). Guarded.
    func load() async {
        await request("Reload \(table.qualifiedName)")
    }

    /// Replace the page after applying `change` to the loader's filter /
    /// paging state. With staged changes this parks the request for the
    /// user's decision and returns without loading.
    func request(_ title: String, change: (@MainActor (RowsLoader) -> Void)? = nil) async {
        switch DirtyGuard.decide(hasPendingChanges: hasPendingChanges, isApplying: isApplying) {
        case .proceed:
            change?(self)
            await performLoad()
        case .confirm:
            pendingNavigation = PendingNavigation(title: title, change: change ?? { _ in })
        case .block:
            service.toasts.show(.info, "Wait for Apply to finish.")
        }
    }

    /// The user's answer to the Apply / Discard / Cancel prompt. Clears the
    /// prompt synchronously (the alert's dismissal would otherwise read it
    /// as Cancel) and finishes the navigation in a task.
    @discardableResult
    func resolvePendingNavigation(_ choice: DirtyGuard.Choice) -> Task<Void, Never>? {
        guard let pending = pendingNavigation else { return nil }
        pendingNavigation = nil
        return Task { await self.finish(pending, choice) }
    }

    private func finish(_ pending: PendingNavigation, _ choice: DirtyGuard.Choice) async {
        switch DirtyGuard.resolve(choice) {
        case .stay:
            return
        case .discardThenProceed:
            revert()
        case .applyThenProceed:
            let ok = await apply()
            guard DirtyGuard.proceedAfterApply(succeeded: ok, stillPending: hasPendingChanges) else { return }
        }
        pending.change(self)
        await performLoad()
    }

    func loadNextPage() async {
        await request("Next page") { $0.pageOffset += $0.pageSize }
    }

    func loadPreviousPage() async {
        await request("Previous page") { $0.pageOffset = max(0, $0.pageOffset - $0.pageSize) }
    }

    func loadFirstPage() async {
        await request("First page") { $0.pageOffset = 0 }
    }

    func setPageSize(_ newSize: Int) async {
        await request("Change page size") {
            $0.pageSize = max(1, newSize)
            $0.pageOffset = 0
        }
    }

    /// New WHERE / ORDER BY → back to the first page of the new result.
    func setFilter(_ newFilter: RowsFetcher.Filter) async {
        await request("Apply filter") {
            $0.filter = newFilter
            $0.pageOffset = 0
        }
    }

    func appendToWhere(_ fragment: String) async {
        let current = filter.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = filter
        next.whereClause = current.isEmpty ? fragment : "(\n\(current)\n) AND (\(fragment))"
        await setFilter(next)
    }

    /// Header click — single-column sort (replacing any typed ORDER BY, as
    /// DataGrip does), first page.
    func applyHeaderSort(column: String, direction: HeaderSortDirection) async {
        var next = filter
        switch direction {
        case .none:       next.orderByClause = ""
        case .ascending:  next.orderByClause = "\(SQLIdent.quote(column)) ASC NULLS LAST"
        case .descending: next.orderByClause = "\(SQLIdent.quote(column)) DESC NULLS LAST"
        }
        await request("Sort by \(column)") {
            $0.filter = next
            $0.pageOffset = 0
        }
    }

    // MARK: - Loading

    private func performLoad() async {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoad(generation: generation)
        }
        loadTask = task
        await task.value
    }

    private func runLoad(generation: Int) async {
        guard let client = service.client else {
            state = .error("Not connected.")
            return
        }
        if table.columns.isEmpty {
            let enriched = await service.ensureColumns(for: table)
            guard generation == loadGeneration else { return }
            table = enriched
        }
        let hadLoadedPage: Bool
        if case .loaded = state {
            isRefreshing = true
            hadLoadedPage = true
        } else {
            state = .loading
            hadLoadedPage = false
        }
        let filter = self.filter
        let offset = pageOffset
        let size = pageSize
        let table = self.table
        let revisionAtStart = stagingRevision
        let spatial = service.hasPostGIS
        let estimateWanted = filter.whereClause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do {
            async let estimate: Int64? = estimateWanted
                ? (try? RowsFetcher.estimatedRowCount(table: table, client: client))
                : nil
            async let sizeText: String? = Self.fetchTableSize(table: table, client: client)
            let page = try await RowsFetcher.page(
                offset: offset, pageSize: size, from: table, client: client,
                filter: filter, spatial: spatial
            )
            let est = await estimate
            let pretty = await sizeText
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if Self.landingKeepsStagedEdits(revisionAtStart: revisionAtStart, revisionNow: stagingRevision,
                                            hasPendingChanges: hasPendingChanges) {
                refreshError = "You edited rows while the refresh was running, so the refreshed page was set aside to keep those edits. Apply or discard them, then refresh again."
                isRefreshing = false
                return
            }
            // Staged changes are dropped only once the replacement page is
            // here: the guard already had the user's consent, and a failed
            // load keeps both the old page and the edits.
            editBuffer.clear()
            pendingInsertRows.removeAll()
            pendingDeleteRows.removeAll()
            appliedHighlights = []
            applyError = nil
            exactTotal = nil
            countError = nil
            state = .loaded(page)
            pageGeneration += 1
            estimatedTotal = est
            tableSizePretty = pretty
            refreshError = nil
        } catch {
            guard generation == loadGeneration, !(error is CancellationError), !Task.isCancelled else { return }
            let message = PostgresErrorMessage.describe(error)
            if hadLoadedPage {
                refreshError = message
            } else {
                state = .error(message)
            }
        }
        if generation == loadGeneration { isRefreshing = false }
    }

    /// On-disk total size of a table/matview. Best-effort and decorative.
    nonisolated static func fetchTableSize(table: TableNode, client: PostgresClient) async -> String? {
        guard table.kind != .view else { return nil }
        let qualified = SQLIdent.qualified(schema: table.schema, name: table.name)
        // A partitioned parent stores nothing itself; its size is its partitions'.
        let sql: PostgresQuery = table.flavor == .partitioned
            ? "SELECT pg_size_pretty(sum(pg_total_relation_size(relid))) FROM pg_partition_tree(\(qualified)::regclass)"
            : "SELECT pg_size_pretty(pg_total_relation_size(\(qualified)::regclass))"
        do {
            let rows = try await client.query(sql)
            for try await s in rows.decode(String.self) { return s }
        } catch {
            Log.postgres.debug("table size lookup failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    /// `SELECT COUNT(*)` honouring the active filter, on demand.
    func countExact() async {
        guard let client = service.client, !isCountingExact else { return }
        isCountingExact = true
        countError = nil
        defer { isCountingExact = false }
        let generation = pageGeneration
        do {
            let count = try await RowsFetcher.exactRowCount(table: table, client: client, filter: filter)
            guard generation == pageGeneration else { return }
            exactTotal = count
        } catch {
            let message = PostgresErrorMessage.describe(error)
            countError = message
            service.toasts.show(.error, "Count failed: \(message)")
        }
    }

    func foreignKeyCatalog() async -> [ForeignKeyResolver.Key] {
        if let foreignKeys { return foreignKeys }
        guard let client = service.client else { return [] }
        do {
            let keys = try await ForeignKeyResolver.fetch(client: client, schema: table.schema, table: table.name)
            foreignKeys = keys
            return keys
        } catch {
            service.toasts.show(.error, "Couldn't read foreign keys: \(PostgresErrorMessage.describe(error))")
            return []
        }
    }

    // MARK: - Header sort

    enum HeaderSortDirection { case none, ascending, descending }

    func headerSortDirection(for columnName: String) -> HeaderSortDirection {
        Self.headerSortDirection(orderBy: filter.orderByClause, column: columnName)
    }

    /// Which arrow a header shows for a typed ORDER BY. Only a single term
    /// naming exactly this column (quoted or bare, optional ASC/DESC and
    /// NULLS FIRST/LAST) lights up; anything else leaves every arrow off.
    nonisolated static func headerSortDirection(orderBy: String, column: String) -> HeaderSortDirection {
        var tokens = OrderByTokens(orderBy)
        guard let first = tokens.next() else { return .none }
        let matches: Bool
        switch first {
        case .quoted(let name): matches = name == column
        case .word(let word): matches = word.lowercased() == column
        case .other: matches = false
        }
        guard matches else { return .none }
        var direction = HeaderSortDirection.ascending
        var expect: [String] = ["asc", "desc", "nulls"]
        while let token = tokens.next() {
            guard case .word(let raw) = token else { return .none }
            let w = raw.lowercased()
            guard expect.contains(w) else { return .none }
            switch w {
            case "asc": expect = ["nulls"]
            case "desc": direction = .descending; expect = ["nulls"]
            case "nulls": expect = ["first", "last"]
            default: expect = []
            }
        }
        if expect == ["first", "last"] { return .none }
        return direction
    }

    private struct OrderByTokens {
        enum Token { case quoted(String), word(String), other }
        private let chars: [Character]
        private var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func next() -> Token? {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "\"" {
                var name = ""
                i += 1
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { name.append("\""); i += 2; continue }
                        i += 1
                        return .quoted(name)
                    }
                    name.append(chars[i]); i += 1
                }
                return .other
            }
            if c.isLetter || c == "_" {
                var word = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" {
                    word.append(chars[i]); i += 1
                }
                return .word(word)
            }
            i += 1
            return .other
        }
    }

    // MARK: - Staging rows

    /// Stage / unstage existing rows for deletion. Drafts aren't in the
    /// database, so they're removed outright instead.
    func toggleDelete(sourceRows: [Int]) {
        guard case .loaded = state, !isApplying else { return }
        let drafts = sourceRows.filter { pendingInsertRows.contains($0) }
        if !drafts.isEmpty { removeDraftRows(Set(drafts)) }
        let targets = sourceRows.filter { !drafts.contains($0) }
        guard !targets.isEmpty else { return }
        if targets.allSatisfy({ pendingDeleteRows.contains($0) }) {
            pendingDeleteRows.subtract(targets)
        } else {
            pendingDeleteRows.formUnion(targets)
        }
    }

    /// Append a blank draft row; its cells stage through the normal editor.
    /// Unset cells are omitted from the INSERT, so they get the column
    /// DEFAULT.
    func addInsertRow() {
        guard case .loaded(var page) = state, isEditable, !isApplying else { return }
        let newIndex = page.rows.count
        page.appendDraftRow()
        pendingInsertRows.insert(newIndex)
        state = .loaded(page)
        contentRevision += 1
        focusRequest = FocusRequest(sourceRow: newIndex, dataColumn: 0, beginEditing: false)
    }

    /// Copy existing rows into new draft rows (values staged, so they can
    /// be tweaked before Apply). A single-column primary key is left to its
    /// DEFAULT — typically an identity / serial that must not collide.
    func duplicateRows(_ sources: [Int]) {
        guard case .loaded(var page) = state, isEditable, !isApplying, !sources.isEmpty else { return }
        let skip: Set<String> = table.primaryKey.count == 1 ? Set(table.primaryKey) : []
        var newRows: [Int] = []
        editBuffer.batch {
            for source in sources where source < page.rows.count {
                page.appendDraftRow()
                let index = page.rows.count - 1
                newRows.append(index)
                for (c, column) in page.columns.enumerated() where !skip.contains(column.name) {
                    let value: String?
                    if let entry = editBuffer.entry(row: source, column: c) {
                        guard case .literal(let v) = entry else { continue }
                        value = v
                    } else {
                        let row = page.rows[source]
                        value = c < row.count ? row[c] : nil
                    }
                    if let value { editBuffer.set(row: index, column: c, value: value) }
                }
            }
        }
        pendingInsertRows.formUnion(newRows)
        state = .loaded(page)
        contentRevision += 1
        if let first = newRows.first {
            focusRequest = FocusRequest(sourceRow: first, dataColumn: 0, beginEditing: false)
        }
    }

    private func removeDraftRows(_ drafts: Set<Int>) {
        guard !drafts.isEmpty, case .loaded(var page) = state else { return }
        let mapping = Self.indexMapping(removing: drafts, count: page.rows.count)
        page.removeRows(drafts)
        editBuffer.remapRows { mapping[$0] }
        pendingInsertRows = Set(pendingInsertRows.compactMap { mapping[$0] })
        pendingDeleteRows = Set(pendingDeleteRows.compactMap { mapping[$0] })
        appliedHighlights = Set(appliedHighlights.compactMap { key in
            mapping[key.row].map { EditBuffer.CellKey(row: $0, column: key.column) }
        })
        state = .loaded(page)
        contentRevision += 1
    }

    /// old index → new index after removing `removed` from `0..<count`.
    nonisolated static func indexMapping(removing removed: Set<Int>, count: Int) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var next = 0
        for i in 0..<count where !removed.contains(i) {
            map[i] = next
            next += 1
        }
        return map
    }

    func revert() {
        editBuffer.clear()
        pendingDeleteRows.removeAll()
        removeDraftRows(pendingInsertRows)
        applyError = nil
    }

    // MARK: - Apply

    private struct Batch {
        let edits: [UpdateApplier.Edit]
        let inserts: [UpdateApplier.Insert]
        let insertRows: [Int]
        let deletes: [UpdateApplier.Delete]
        var isEmpty: Bool { edits.isEmpty && inserts.isEmpty && deletes.isEmpty }
    }

    private func batch(for page: RowsFetcher.Page) -> Batch {
        let pending = editBuffer.editsByRow()
        func changes(_ cells: [(column: Int, entry: EditBuffer.Entry)]) -> [UpdateApplier.CellChange] {
            cells.compactMap { cell in
                guard cell.column >= 0, cell.column < page.columns.count else { return nil }
                return UpdateApplier.CellChange(column: page.columns[cell.column], entry: cell.entry)
            }
        }
        let edits = pending
            .filter { !pendingInsertRows.contains($0.row) && !pendingDeleteRows.contains($0.row) }
            .map { UpdateApplier.Edit(rowIndex: $0.row, cells: changes($0.cells)) }
            .filter { !$0.cells.isEmpty }
        let insertRows = pendingInsertRows.sorted()
        let inserts = insertRows.map { idx in
            UpdateApplier.Insert(cells: changes(pending.first { $0.row == idx }?.cells ?? []))
        }
        let deletes = pendingDeleteRows.sorted().map { UpdateApplier.Delete(rowIndex: $0) }
        return Batch(edits: edits, inserts: inserts, insertRows: insertRows, deletes: deletes)
    }

    /// The exact statements Apply would run, binds inlined.
    func previewSQL() -> Result<String, Error> {
        guard case .loaded(let page) = state else { return .success("") }
        let b = batch(for: page)
        do {
            let statements = try UpdateApplier.plan(
                edits: b.edits, inserts: b.inserts, deletes: b.deletes, table: table,
                originalRows: page.rows, rowLocators: page.rowLocators, spatial: service.hasPostGIS)
            return .success(UpdateApplier.previewScript(statements))
        } catch {
            return .failure(error)
        }
    }

    /// Count of staged changes, for the "N pending" badge.
    var pendingSummary: (cells: Int, inserts: Int, deletes: Int) {
        let cells = editBuffer.edits.keys.filter {
            !pendingInsertRows.contains($0.row) && !pendingDeleteRows.contains($0.row)
        }.count
        return (cells, pendingInsertRows.count, pendingDeleteRows.count)
    }

    /// Commit everything staged in one transaction and splice the server's
    /// stored values back into the page. Returns whether it succeeded.
    @discardableResult
    func apply() async -> Bool {
        guard !isApplying else { return false }
        guard let client = service.client else {
            applyError = "Not connected."
            return false
        }
        guard case .loaded(let page) = state else { return false }
        let b = batch(for: page)
        guard !b.isEmpty else {
            if hasPendingChanges { editBuffer.clear() }
            return true
        }
        let submitted = editBuffer.edits
        let generation = pageGeneration

        isApplying = true
        applyError = nil
        applySuccess = nil
        defer { isApplying = false }
        let summaryParts = [
            b.edits.isEmpty ? nil : "\(b.edits.count) update\(b.edits.count == 1 ? "" : "s")",
            b.inserts.isEmpty ? nil : "\(b.inserts.count) insert\(b.inserts.count == 1 ? "" : "s")",
            b.deletes.isEmpty ? nil : "\(b.deletes.count) delete\(b.deletes.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        let op = service.operations.begin(
            kind: .update,
            summary: "\(table.qualifiedName) · \(summaryParts.joined(separator: ", "))"
        )
        let started = Date()
        do {
            let outcome = try await UpdateApplier.apply(
                edits: b.edits, inserts: b.inserts, deletes: b.deletes,
                table: table, originalRows: page.rows, rowLocators: page.rowLocators,
                spatial: service.hasPostGIS, client: client,
                operationID: op.id, tracker: service.operations
            )
            service.operations.finish(op, status: .succeeded)
            let elapsed = Date().timeIntervalSince(started)
            guard generation == pageGeneration, case .loaded(var current) = state else { return true }
            splice(outcome, batch: b, into: &current, submitted: submitted)
            applySuccess = "Applied \(summaryParts.joined(separator: ", ")) · \(String(format: "%.0f ms", elapsed * 1000))"
            let snapshot = applySuccess
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if self?.applySuccess == snapshot {
                    self?.applySuccess = nil
                    self?.appliedHighlights = []
                }
            }
            return true
        } catch is CancellationError {
            applyError = "Cancelled"
            service.operations.finish(op, status: .cancelled)
        } catch {
            let message = PostgresErrorMessage.describe(error)
            applyError = message
            service.operations.finish(op, status: .failed(message))
        }
        return false
    }

    private func splice(_ outcome: UpdateApplier.Outcome, batch b: Batch, into page: inout RowsFetcher.Page, submitted: [EditBuffer.CellKey: EditBuffer.Entry]) {
        var highlights: Set<EditBuffer.CellKey> = []
        for (rowIndex, fresh) in outcome.updatedRows where rowIndex < page.rows.count {
            page.rows[rowIndex] = fresh
            if let loc = outcome.updatedLocators[rowIndex] { page.setLocator(loc, at: rowIndex) }
        }
        for edit in b.edits {
            for cell in edit.cells {
                if let col = page.columns.firstIndex(where: { $0.name == cell.column.name }) {
                    highlights.insert(EditBuffer.CellKey(row: edit.rowIndex, column: col))
                }
            }
        }
        // Per-draft results: a trigger-suppressed INSERT yields nil and must
        // not shift later results onto the wrong draft rows.
        for (k, rowIndex) in b.insertRows.enumerated()
            where k < outcome.insertedRowsByDraft.count && rowIndex < page.rows.count {
            guard let stored = outcome.insertedRowsByDraft[k] else { continue }
            page.rows[rowIndex] = stored
            if k < outcome.insertedLocatorsByDraft.count {
                page.setLocator(outcome.insertedLocatorsByDraft[k], at: rowIndex)
            }
            for col in page.columns.indices { highlights.insert(EditBuffer.CellKey(row: rowIndex, column: col)) }
        }
        editBuffer.settleApplied(submitted)
        pendingInsertRows.subtract(b.insertRows)

        let deleted = Set(outcome.deletedRows)
        if !deleted.isEmpty {
            let mapping = Self.indexMapping(removing: deleted, count: page.rows.count)
            page.removeRows(deleted)
            editBuffer.remapRows { mapping[$0] }
            pendingInsertRows = Set(pendingInsertRows.compactMap { mapping[$0] })
            pendingDeleteRows = Set(pendingDeleteRows.subtracting(deleted).compactMap { mapping[$0] })
            highlights = Set(highlights.compactMap { key in
                mapping[key.row].map { EditBuffer.CellKey(row: $0, column: key.column) }
            })
        }
        appliedHighlights = highlights
        state = .loaded(page)
        contentRevision += 1
    }
}

extension RowsFetcher.Page {
    /// Rows and their physical locators move together.
    mutating func appendDraftRow() {
        rows.append([String?](repeating: nil, count: columns.count))
        if var locs = rowLocators {
            locs.append(nil)
            rowLocators = locs
        }
    }

    mutating func removeRows(_ indices: Set<Int>) {
        for idx in indices.sorted(by: >) where idx < rows.count {
            rows.remove(at: idx)
            if var locs = rowLocators, idx < locs.count {
                locs.remove(at: idx)
                rowLocators = locs
            }
        }
    }

    mutating func setLocator(_ locator: String?, at index: Int) {
        guard var locs = rowLocators, index < locs.count else { return }
        locs[index] = locator
        rowLocators = locs
    }
}
