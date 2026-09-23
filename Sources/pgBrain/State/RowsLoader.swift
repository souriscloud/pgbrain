import Foundation
import Observation
import PostgresNIO

@MainActor
@Observable
final class RowsLoader {
    enum State {
        case idle
        case loading
        case loaded(RowsFetcher.Page)
        case error(String)
    }

    /// Effective table — captured at init from the snapshot but
    /// re-assigned the first time `load()` runs so we pick up
    /// columns the background enrichment populated in the meantime.
    private(set) var table: TableNode
    @ObservationIgnored let service: ConnectionService
    private(set) var state: State = .idle

    /// Per-tab pending-edit buffer; lives as long as the loader does.
    let editBuffer = EditBuffer()
    private(set) var isApplying = false
    private(set) var applyError: String?
    /// Short-lived green message after a successful Apply.
    private(set) var applySuccess: String?
    /// Cells that were just applied — rendered with a fading green tint
    /// in the grid so the user can see exactly what landed. Cleared on a
    /// timer so the highlight doesn't loiter.
    private(set) var appliedHighlights: Set<EditBuffer.CellKey> = []

    /// Source-row indices (into the loaded page) that are draft INSERTs —
    /// blank rows appended to the bottom of the grid, awaiting Apply. Their
    /// cell values live in `editBuffer` like any other edit; this set just
    /// flags which rows become INSERTs instead of UPDATEs.
    private(set) var pendingInsertRows: Set<Int> = []

    /// Source-row indices of existing rows the user has staged for DELETE.
    /// They render with a red wash and commit (inside the same transaction as
    /// edits/inserts) on the next Apply; Revert clears them.
    private(set) var pendingDeleteRows: Set<Int> = []

    /// Apply is meaningful when there are dirty cells, pending new rows, or
    /// rows staged for deletion.
    var hasPendingChanges: Bool {
        editBuffer.isDirty || !pendingInsertRows.isEmpty || !pendingDeleteRows.isEmpty
    }

    /// Stage / unstage existing rows for deletion. Draft (uncommitted insert)
    /// rows aren't in the database, so toggling delete on one is ignored here —
    /// drafts are discarded via Revert. Re-invoking on a staged row un-stages it.
    func toggleDelete(sourceRows: [Int]) {
        guard case .loaded = state else { return }
        let targets = sourceRows.filter { !pendingInsertRows.contains($0) }
        guard !targets.isEmpty else { return }
        // If the whole selection is already staged, unmark it; otherwise mark
        // it all. (Avoids a confusing per-row flip on a mixed selection.)
        if targets.allSatisfy({ pendingDeleteRows.contains($0) }) {
            for r in targets { pendingDeleteRows.remove(r) }
        } else {
            for r in targets { pendingDeleteRows.insert(r) }
        }
    }

    /// Append a blank draft row to the loaded page and flag it as a pending
    /// insert. Cells are filled through the normal cell editor afterwards.
    func addInsertRow() {
        guard case .loaded(var page) = state else { return }
        let newIndex = page.rows.count
        page.rows.append([String?](repeating: nil, count: page.columns.count))
        pendingInsertRows.insert(newIndex)
        state = .loaded(page)
    }

    /// JetBrains-style raw filter — user-typed `WHERE` and `ORDER BY`
    /// fragments spliced server-side. Setting either triggers a reload
    /// (the row-limit slice would otherwise lie).
    var filter: RowsFetcher.Filter = RowsFetcher.Filter(whereClause: "", orderByClause: "")
    /// ⌘F find bar — client-side substring filter across all columns on
    /// the already-loaded page. Independent from the server WHERE.
    var globalFilter: String = ""
    /// True while a *refresh* is in flight on an already-loaded grid —
    /// the previous `.loaded` page stays mounted so the user keeps
    /// seeing the old data with a small progress indicator, instead of
    /// the grid collapsing into a spinner on every Enter.
    var isRefreshing: Bool = false
    /// Server error from the *most recent* refresh. Surfaced as a red
    /// banner above the grid so the user can read it and edit the
    /// WHERE / ORDER BY clause without losing the previously-loaded
    /// page underneath. Cleared on the next successful load.
    var refreshError: String?
    /// Current page offset (0-based row index of the first row).
    var pageOffset: Int = 0
    /// Rows fetched per page. Defaults to 200 — 1000 was punishing
    /// on tables with wide JSONB / TEXT columns. User can bump it.
    var pageSize: Int = 200
    /// Planner row-count estimate when no WHERE clause is active.
    /// Surfaced as "~1.2M" in the pager so the user has a sense of
    /// scale without paying for a full COUNT(*).
    var estimatedTotal: Int64?
    /// Exact row count, populated when the user explicitly clicks
    /// "Count exact" in the pager. Takes precedence over
    /// `estimatedTotal` when both are present.
    var exactTotal: Int64?
    /// True while the exact-count query is in flight (drives the
    /// pager's button spinner).
    var isCountingExact: Bool = false
    /// On-disk size of the open table (`pg_total_relation_size`), shown in
    /// the toolbar. Refreshed on every load so it tracks inserts/deletes.
    private(set) var tableSizePretty: String?
    /// Whether the previously-loaded page reported "there's more
    /// after this" (so the Next arrow stays enabled).
    var hasMoreAfterCurrentPage: Bool {
        if case .loaded(let page) = state { return page.truncated }
        return false
    }

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
    }

    /// Subset of the loaded page that satisfies the (client-side) global
    /// find filter. Server-side WHERE happens at load time, not here.
    func filteredPage() -> (RowsFetcher.Page, [Int])? {
        guard case .loaded(let base) = state else { return nil }
        let g = globalFilter.lowercased()
        if g.isEmpty {
            return (base, Array(0..<base.rows.count))
        }
        var rows: [[String?]] = []
        var sourceIndices: [Int] = []
        rows.reserveCapacity(base.rows.count)
        sourceIndices.reserveCapacity(base.rows.count)
        for (i, row) in base.rows.enumerated() {
            var anyMatch = false
            for cell in row {
                if (cell?.lowercased() ?? "").contains(g) { anyMatch = true; break }
            }
            if !anyMatch { continue }
            rows.append(row)
            sourceIndices.append(i)
        }
        let filtered = RowsFetcher.Page(
            columns: base.columns,
            rows: rows,
            truncated: base.truncated,
            limit: base.limit,
            offset: base.offset,
            elapsed: base.elapsed
        )
        return (filtered, sourceIndices)
    }

    func load() async {
        guard let client = service.client else {
            state = .error("Not connected.")
            return
        }
        // Phase-2 schema enrichment may not have populated this
        // table's columns yet (or this connection might have
        // landed on a shallow snapshot). Ensure them before we
        // build the SELECT — RowsFetcher uses table.columns to
        // construct the projection.
        if table.columns.isEmpty {
            table = await service.ensureColumns(for: table)
        }
        let hadLoadedPage: Bool
        if case .loaded = state {
            isRefreshing = true
            hadLoadedPage = true
        } else {
            state = .loading
            hadLoadedPage = false
        }
        editBuffer.clear()
        pendingInsertRows.removeAll()
        pendingDeleteRows.removeAll()
        applyError = nil
        // Clear the exact-count cache on any reload — it's tied to a
        // specific filter + page set.
        exactTotal = nil
        defer { isRefreshing = false }
        do {
            // Kick off the planner estimate in parallel with the page
            // fetch. Cheap (catalog read), only meaningful when no
            // WHERE clause is active.
            async let estimate: Int64? = filter.whereClause.trimmingCharacters(in: .whitespaces).isEmpty
                ? (try? RowsFetcher.estimatedRowCount(table: table, client: client))
                : nil
            async let size: String? = Self.fetchTableSize(table: table, client: client)
            let page = try await RowsFetcher.page(
                offset: pageOffset,
                pageSize: pageSize,
                from: table, client: client, filter: filter,
                spatial: service.hasPostGIS
            )
            state = .loaded(page)
            estimatedTotal = await estimate
            tableSizePretty = await size
            refreshError = nil
        } catch {
            let message = PostgresErrorMessage.describe(error)
            if hadLoadedPage {
                refreshError = message
            } else {
                state = .error(message)
            }
        }
    }

    /// On-disk total size of a table/matview (`pg_total_relation_size`).
    /// Plain views have no storage, so we skip them. Best-effort — any
    /// failure just leaves the toolbar size off.
    nonisolated static func fetchTableSize(table: TableNode, client: PostgresClient) async -> String? {
        guard table.kind != .view else { return nil }
        let qualified = (SQLIdent.quote(table.schema) + "." + SQLIdent.quote(table.name))
            .replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT pg_size_pretty(pg_total_relation_size('\(qualified)'::regclass))"
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await s in rows.decode(String.self) { return s }
        } catch {
            // Decorative — stay silent.
        }
        return nil
    }

    /// Run a `SELECT COUNT(*)` honouring the active filter. Wired to
    /// the pager's "count exact" button — bypasses the auto-load
    /// path because COUNT(*) can be slow on big tables.
    func countExact() async {
        guard let client = service.client, !isCountingExact else { return }
        isCountingExact = true
        defer { isCountingExact = false }
        if let count = try? await RowsFetcher.exactRowCount(
            table: table, client: client, filter: filter
        ) {
            exactTotal = count
        }
    }

    // MARK: - Pagination

    /// Advance one page. Caller should check
    /// `hasMoreAfterCurrentPage` first to avoid a wasted query.
    func loadNextPage() async {
        pageOffset += pageSize
        await load()
    }

    /// Step back one page. Clamped at offset 0.
    func loadPreviousPage() async {
        pageOffset = max(0, pageOffset - pageSize)
        await load()
    }

    /// First page — keeps the filter intact.
    func loadFirstPage() async {
        pageOffset = 0
        await load()
    }

    /// Change the page size + reset to the first page so the new
    /// rows-per-page setting kicks in immediately.
    func setPageSize(_ newSize: Int) async {
        pageSize = max(1, newSize)
        pageOffset = 0
        await load()
    }

    /// Header click — rewrite the ORDER BY clause to a single-column
    /// sort and reload. Wipes any user-typed multi-column ORDER BY,
    /// which matches JetBrains behaviour. Resets to the first page so
    /// the user doesn't end up reading offset-200 rows of the new
    /// sort that don't correspond to what they were looking at.
    func applyHeaderSort(column: String, direction: HeaderSortDirection) async {
        switch direction {
        case .none:
            filter.orderByClause = ""
        case .ascending:
            filter.orderByClause = "\(SQLIdent.quote(column)) ASC NULLS LAST"
        case .descending:
            filter.orderByClause = "\(SQLIdent.quote(column)) DESC NULLS LAST"
        }
        pageOffset = 0
        await load()
    }

    enum HeaderSortDirection { case none, ascending, descending }

    /// Parse the active `orderByClause` to figure out whether a header
    /// arrow should be shown. Only single-column `"col" ASC|DESC` is
    /// recognised — anything fancier leaves all arrows off.
    func headerSortDirection(for columnName: String) -> HeaderSortDirection {
        let raw = filter.orderByClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .none }
        // Bail on multi-column.
        if raw.contains(",") { return .none }
        let lower = raw.lowercased()
        let quoted = "\"\(columnName.lowercased())\""
        let bareStart = "\(columnName.lowercased()) "
        let bareOnly = columnName.lowercased()
        let hasMatch = lower.hasPrefix(quoted) || lower.hasPrefix(bareStart) || lower == bareOnly
        guard hasMatch else { return .none }
        if lower.contains("desc") { return .descending }
        return .ascending
    }

    func revert() {
        editBuffer.clear()
        pendingDeleteRows.removeAll()
        // Drop the trailing draft rows (always appended at the end).
        if !pendingInsertRows.isEmpty, case .loaded(var page) = state {
            let n = pendingInsertRows.count
            if page.rows.count >= n { page.rows.removeLast(n) }
            pendingInsertRows.removeAll()
            state = .loaded(page)
        }
        applyError = nil
    }

    func apply() async {
        guard let client = service.client else {
            applyError = "Not connected."
            return
        }
        guard case .loaded(var page) = state else { return }
        let pending = editBuffer.editsByRow()

        // Split pending edits: rows flagged as drafts become INSERTs, the
        // rest are UPDATEs against existing rows. Rows staged for deletion are
        // excluded from UPDATEs (no point updating a row we're about to drop).
        let edits: [UpdateApplier.Edit] = pending
            .filter { !pendingInsertRows.contains($0.row) && !pendingDeleteRows.contains($0.row) }
            .map { rowEdits in
                let cells = rowEdits.cells.map {
                    UpdateApplier.CellChange(column: page.columns[$0.column], entry: $0.entry)
                }
                return UpdateApplier.Edit(rowIndex: rowEdits.row, cells: cells)
            }
        let inserts: [UpdateApplier.Insert] = pendingInsertRows.sorted().map { idx in
            let cells = (pending.first { $0.row == idx }?.cells ?? []).map {
                UpdateApplier.CellChange(column: page.columns[$0.column], entry: $0.entry)
            }
            return UpdateApplier.Insert(cells: cells)
        }
        let deletes: [UpdateApplier.Delete] = pendingDeleteRows.sorted()
            .map { UpdateApplier.Delete(rowIndex: $0) }
        guard !edits.isEmpty || !inserts.isEmpty || !deletes.isEmpty else { return }

        isApplying = true
        applyError = nil
        applySuccess = nil
        defer { isApplying = false }
        let summaryParts = [
            edits.isEmpty ? nil : "\(edits.count) update\(edits.count == 1 ? "" : "s")",
            inserts.isEmpty ? nil : "\(inserts.count) insert\(inserts.count == 1 ? "" : "s")",
            deletes.isEmpty ? nil : "\(deletes.count) delete\(deletes.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        let op = service.operations.begin(
            kind: .update,
            summary: "\(table.qualifiedName) · \(summaryParts.joined(separator: ", "))"
        )
        let started = Date()
        do {
            try await UpdateApplier.apply(
                edits: edits,
                inserts: inserts,
                deletes: deletes,
                table: table,
                originalRows: page.rows,
                client: client,
                operationID: op.id,
                tracker: service.operations
            )
            service.operations.finish(op, status: .succeeded)
            let elapsed = Date().timeIntervalSince(started)

            // Expression / DEFAULT updates produce server-computed values we
            // can't predict client-side, so they force a refetch too.
            let hasComputedUpdates = edits.contains { edit in
                edit.cells.contains { if case .literal = $0.value { return false } else { return true } }
            }
            if !inserts.isEmpty || !deletes.isEmpty || hasComputedUpdates {
                // Inserts get server-assigned identity/defaults and deletes
                // remove rows — either way the row set changed, so refetch
                // rather than try to splice in place.
                applySuccess = "Applied \(summaryParts.joined(separator: ", ")) · \(String(format: "%.0f ms", elapsed * 1000))"
                editBuffer.clear()
                pendingInsertRows.removeAll()
                pendingDeleteRows.removeAll()
                await load()
            } else {
                // Update-only: splice the applied values into the in-memory
                // page so the grid updates without a round-trip refetch.
                for edit in edits {
                    for cell in edit.cells {
                        guard case .literal(let v) = cell.value else { continue }
                        page.rows[edit.rowIndex][page.columns.firstIndex(where: { $0.name == cell.column.name }) ?? 0] = v
                    }
                }
                state = .loaded(page)
                applySuccess = "Applied \(edits.count) row\(edits.count == 1 ? "" : "s") · \(String(format: "%.0f ms", elapsed * 1000))"
                // Flash every applied (row, col) green in the grid before fading.
                var highlights: Set<EditBuffer.CellKey> = []
                for edit in edits {
                    for cell in edit.cells {
                        if let colIdx = page.columns.firstIndex(where: { $0.name == cell.column.name }) {
                            highlights.insert(EditBuffer.CellKey(row: edit.rowIndex, column: colIdx))
                        }
                    }
                }
                appliedHighlights = highlights
                editBuffer.clear()
            }
            let snapshot = applySuccess
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if self?.applySuccess == snapshot {
                    self?.applySuccess = nil
                    self?.appliedHighlights = []
                }
            }
        } catch is CancellationError {
            applyError = "Cancelled"
            service.operations.finish(op, status: .cancelled)
        } catch {
            // Unwrap PostgresTransactionError / PSQLError into a real
            // server message — by default they read "error 1" / opaque
            // code, which isn't actionable.
            let message = PostgresErrorMessage.describe(error)
            applyError = message
            service.operations.finish(op, status: .failed(message))
        }
    }
}
