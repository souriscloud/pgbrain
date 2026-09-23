import AppKit
import SwiftUI

/// The Data pane: WHERE / ORDER BY strip, find bar, grid / form / map, pager.
extension TableTabView {
    @ViewBuilder
    var dataPane: some View {
        switch loader.state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading rows…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let (visible, sourceIndices) = loader.filteredPage() {
                VStack(spacing: 0) {
                    queryStrip
                    if let err = loader.refreshError {
                        errorBanner(message: err, isCold: false)
                    }
                    if viewState.showFindBar { findBar }
                    rowsView(visible: visible, sourceIndices: sourceIndices)
                    pagerStrip(visible: visible)
                }
            }
        case .error(let message):
            // Cold error (nothing ever loaded): keep the strip so the clause
            // can be fixed and retried without reopening the tab.
            VStack(spacing: 0) {
                queryStrip
                errorBanner(message: message, isCold: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var queryStrip: some View {
        QueryStripView(
            filter: loader.filter,
            table: table,
            schema: service.visibleSchema,
            isRefreshing: loader.isRefreshing,
            hasPendingChanges: loader.hasPendingChanges,
            onSubmit: { newFilter in Task { await loader.setFilter(newFilter) } }
        )
    }

    @ViewBuilder
    private func rowsView(visible: RowsFetcher.Page, sourceIndices: [Int]) -> some View {
        if visible.rows.isEmpty {
            VStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if loader.isEditable, loader.globalFilter.isEmpty {
                    Button("Add row") { loader.addInsertRow() }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewState.rowViewMode == .map, let geom = spatialColumns.first {
            SpatialMapView(
                service: service,
                fromSQL: SQLIdent.qualified(schema: table.schema, name: table.name),
                geometryColumn: geom.name,
                labelColumn: mapLabelColumn,
                whereClause: loader.filter.whereClause
            )
        } else if viewState.rowViewMode == .form {
            RowFormView(
                page: visible,
                sourceIndices: sourceIndices,
                rowIndex: Binding(get: { viewState.formRowIndex }, set: { viewState.formRowIndex = $0 }),
                editBuffer: loader.isEditable ? loader.editBuffer : nil,
                insertRowIndices: loader.pendingInsertRows,
                deleteRowIndices: loader.pendingDeleteRows,
                enums: service.schema.enums
            )
        } else {
            grid(visible: visible, sourceIndices: sourceIndices)
        }
    }

    private func grid(visible: RowsFetcher.Page, sourceIndices: [Int]) -> some View {
        let editable = loader.isEditable
        return DataGridView(
            page: visible,
            editBuffer: editable ? loader.editBuffer : nil,
            editVersion: loader.editBuffer.version,
            enums: service.schema.enums,
            schema: service.schema,
            appliedHighlights: loader.appliedHighlights,
            insertRowIndices: loader.pendingInsertRows,
            deleteRowIndices: loader.pendingDeleteRows,
            sourceRowIndices: sourceIndices,
            pageGeneration: loader.pageGeneration,
            contentRevision: loader.contentRevision,
            focusRequest: loader.focusRequest,
            viewState: viewState,
            foreignKeyColumns: foreignKeyColumns,
            copyTarget: table.kind == .table
                ? RowCopy.Target(schema: table.schema, table: table.name, primaryKey: loader.table.primaryKey)
                : nil,
            sortDirectionFor: { col in
                switch loader.headerSortDirection(for: col) {
                case .none:       return .none
                case .ascending:  return .ascending
                case .descending: return .descending
                }
            },
            onHeaderClick: { col, next in
                let mapped: RowsLoader.HeaderSortDirection
                switch next {
                case .none:       mapped = .none
                case .ascending:  mapped = .ascending
                case .descending: mapped = .descending
                }
                Task { await loader.applyHeaderSort(column: col, direction: mapped) }
            },
            onFilterEqualsCell: { row, col in filterToCell(sourceRow: row, dataCol: col) },
            onFilterColumn: { col, mode in filterColumn(dataCol: col, mode: mode) },
            onShowColumnDistinct: { col in distinctValuesColumn = ColumnNameID(id: col) },
            makeProfilerController: { name in
                guard let node = resolvedColumns.first(where: { $0.name == name }) else { return nil }
                return NSHostingController(rootView: ColumnProfilePopover(
                    service: service,
                    schema: table.schema,
                    table: table.name,
                    column: node,
                    extraWhere: RowsFetcher.isolatedWhere(loader.filter.whereClause)
                ))
            },
            onDeleteRows: editable ? { rows in loader.toggleDelete(sourceRows: rows) } : nil,
            onDuplicateRows: editable ? { rows in loader.duplicateRows(rows) } : nil,
            onAddRow: editable ? { loader.addInsertRow() } : nil,
            onNavigateForeignKey: { row, col in navigateToForeignKey(sourceRow: row, dataCol: col) },
            onMessage: { text, isError in service.toasts.show(isError ? .error : .info, text) },
            columnLayoutKey: (service.connection.id, table.schema, table.name)
        )
        .popover(item: $distinctValuesColumn, arrowEdge: .top) { colName in
            DistinctValuesPopover(
                service: service,
                schema: table.schema,
                table: table.name,
                column: colName.id,
                extraWhere: RowsFetcher.isolatedWhere(loader.filter.whereClause)
            ) { value in
                applyDistinctFilter(column: colName.id, value: value)
                distinctValuesColumn = nil
            }
        }
    }

    /// Columns taking part in any foreign key (composite ones included once
    /// the catalog has loaded).
    var foreignKeyColumns: Set<String> {
        var names = Set(table.foreignKeys.map(\.localColumn))
        for key in loader.foreignKeys ?? [] { names.formUnion(key.localColumns) }
        return names
    }

    // MARK: - Pager

    @ViewBuilder
    func pagerStrip(visible: RowsFetcher.Page) -> some View {
        let start = visible.offset + 1
        let end = visible.offset + visible.rows.count
        let canPrev = loader.pageOffset > 0 && !loader.isApplying
        let canNext = visible.truncated && !loader.isApplying
        HStack(spacing: 12) {
            Menu {
                ForEach([50, 100, 200, 500, 1000, 5000], id: \.self) { size in
                    Button {
                        Task { await loader.setPageSize(size) }
                    } label: {
                        Label("\(size) per page", systemImage: loader.pageSize == size ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(loader.pageSize)/page")
                        .font(.system(.caption, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text(rangeText(start: start, end: end, canNext: visible.truncated, rowCount: visible.rows.count))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if loader.isCountingExact {
                ProgressView().controlSize(.small)
            } else if loader.exactTotal == nil && (visible.truncated || loader.estimatedTotal != nil) {
                Button {
                    Task { await loader.countExact() }
                } label: {
                    Text("count exact")
                        .font(.system(.caption2, design: .monospaced))
                }
                .buttonStyle(.borderless)
                .help("Run SELECT COUNT(*) — may be slow on big tables")
                if let countError = loader.countError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("Last count failed: \(countError)")
                }
            }

            Spacer()

            Picker("", selection: Binding(get: { viewState.rowViewMode }, set: { viewState.rowViewMode = $0 })) {
                Image(systemName: "tablecells").tag(TableRowViewMode.grid)
                Image(systemName: "list.bullet.rectangle.portrait").tag(TableRowViewMode.form)
                if !spatialColumns.isEmpty {
                    Image(systemName: "map").tag(TableRowViewMode.map)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(spatialColumns.isEmpty ? "Switch between grid and single-row form" : "Grid · form · map (this table has geometry)")

            Button {
                Task { await loader.loadFirstPage() }
            } label: { Image(systemName: "chevron.left.2") }
                .buttonStyle(.borderless)
                .disabled(!canPrev)
                .help("First page")
            Button {
                Task { await loader.loadPreviousPage() }
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!canPrev)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .help("Previous page (⌘⇧←)")
            Button {
                Task { await loader.loadNextPage() }
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(!canNext)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .help("Next page (⌘⇧→)")

            if loader.isRefreshing {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 5)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }

    /// Exact count when asked for, else the planner estimate, else "X–Y+".
    private func rangeText(start: Int, end: Int, canNext: Bool, rowCount: Int) -> String {
        if rowCount == 0 { return "0 rows" }
        if let exact = loader.exactTotal {
            return "Rows \(start)–\(end) of \(Self.formatCount(exact))"
        }
        if let estimate = loader.estimatedTotal, estimate > Int64(end) {
            return "Rows \(start)–\(end) of ~\(Self.formatCount(estimate))"
        }
        return "Rows \(start)–\(end)\(canNext ? "+" : "")"
    }

    /// `1,234,567` → `1.23M`: keeps the pager narrow on huge tables.
    static func formatCount(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000:         return "\(n)"
        case ..<1_000_000:     return String(format: "%.1fk", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.2fM", v / 1_000_000)
        default:               return String(format: "%.2fB", v / 1_000_000_000)
        }
    }

    private var emptyMessage: String {
        if !loader.globalFilter.isEmpty { return "No rows match the find filter." }
        if !loader.filter.whereClause.isEmpty { return "No rows match the WHERE clause." }
        return "No rows in \(table.qualifiedName)"
    }

    // MARK: - Find bar

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in grid…", text: Binding(
                get: { loader.globalFilter },
                set: { loader.globalFilter = $0 }
            ))
            .textFieldStyle(.plain)
            .focused($findFocused)
            .onExitCommand { closeFindBar() }
            Spacer(minLength: 0)
            if let (page, _) = loader.filteredPage() {
                Text("\(page.rows.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button {
                closeFindBar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close find bar")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.08))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
    }

    private func closeFindBar() {
        loader.globalFilter = ""
        viewState.showFindBar = false
    }

    // MARK: - Error banner

    /// On refresh failures the previous page stays underneath; on cold
    /// failures the banner stands alone.
    @ViewBuilder
    private func errorBanner(message: String, isCold: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(isCold ? "Couldn't load rows" : "Couldn't refresh — previous page kept below")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await loader.load() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !isCold {
                Button {
                    loader.refreshError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss this error (keeps your clause as-is)")
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
    }
}
