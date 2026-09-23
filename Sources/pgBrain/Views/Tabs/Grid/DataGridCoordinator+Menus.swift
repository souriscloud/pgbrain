import AppKit

extension DataGridView.Coordinator {
    private struct CellLocator {
        let sourceRow: Int
        let visibleRow: Int
        let dataCol: Int
    }

    private func item(_ title: String, _ action: Selector, _ represented: Any? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = self
        item.representedObject = represented
        return item
    }

    // MARK: - Cell menu

    /// Right-click menu for a cell. A click outside the current selection
    /// first moves the selection there, like Finder / Numbers.
    func gridContextMenu(row: Int, tableColumn: Int) -> NSMenu? {
        if isGutter(tableColumn: tableColumn) {
            if !selection.rows.contains(row) {
                changeSelection(scroll: false) { $0.selectRows(from: row, to: row, cols: colCount) }
            }
            return rowMenu(clickedRow: row)
        }
        guard let d = displayCol(forTableColumn: tableColumn), let dataCol = dataCol(forDisplayCol: d),
              row >= 0, row < rowCount, dataCol < page.columns.count
        else { return nil }
        let cell = GridSelection.Cell(row: row, col: d)
        if !selection.contains(cell) {
            changeSelection(scroll: false) { $0.select(cell) }
        }
        let source = sourceIndex(forVisibleRow: row)
        let column = page.columns[dataCol]
        let displayed = effectiveValue(visibleRow: row, dataCol: dataCol)
        let loc = CellLocator(sourceRow: source, visibleRow: row, dataCol: dataCol)

        let menu = NSMenu()
        menu.addItem(item("Copy", #selector(handleCopySelection(_:)), key: "c"))
        menu.addItem(item("Copy value", #selector(handleCopyString(_:)), displayed ?? ""))
        menu.addItem(item("Copy column name", #selector(handleCopyString(_:)), column.name))
        menu.addItem(copyRowsSubmenu(clickedRow: row))
        if editBuffer != nil {
            menu.addItem(item("Paste", #selector(handlePaste(_:)), key: "v"))
        }

        if foreignKeyColumns.contains(column.name), onNavigateForeignKey != nil {
            menu.addItem(.separator())
            menu.addItem(item("Go to referenced row  (⌘-click)", #selector(handleNavigateFK(_:)), loc))
        }

        addColumnInsightItems(to: menu, column: column)

        if onFilterEqualsCell != nil || onFilterColumn != nil {
            menu.addItem(.separator())
            if onFilterEqualsCell != nil {
                let label: String
                if let displayed {
                    let preview = displayed.count > 24 ? String(displayed.prefix(22)) + "…" : displayed
                    label = "Filter to \"\(preview)\""
                } else {
                    label = "Filter to NULL on \(column.name)"
                }
                menu.addItem(item(label, #selector(handleFilterToCell(_:)), loc))
            }
            addNullFilterItems(to: menu, column: column, dataCol: dataCol)
        }

        if editBuffer != nil {
            menu.addItem(.separator())
            menu.addItem(item("Edit cell…", #selector(handleEditCell(_:)), loc, key: "\r", modifiers: []))
            if column.nullable {
                menu.addItem(item("Set NULL", #selector(handleSetNull(_:)), key: "n", modifiers: [.control, .command]))
            }
            menu.addItem(item("Set DEFAULT", #selector(handleSetDefault(_:)), loc))
        }
        rowActionItems(clickedRow: row).forEach(menu.addItem)
        return menu
    }

    private func copyRowsSubmenu(clickedRow: Int) -> NSMenuItem {
        let rows = targetRows(including: clickedRow)
        let parent = NSMenuItem(title: rows.count == 1 ? "Copy row as" : "Copy \(rows.count) rows as", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for format in RowCopy.Format.allCases where !format.needsTable || copyTarget != nil {
            if format == .insert { sub.addItem(.separator()) }
            sub.addItem(item(format.label, #selector(handleCopyRowsAs(_:)), CopyRequest(format: format, rows: rows)))
        }
        parent.submenu = sub
        return parent
    }

    private struct CopyRequest {
        let format: RowCopy.Format
        let rows: [Int]
    }

    /// Gutter menu: copy formats plus the row actions.
    private func rowMenu(clickedRow row: Int) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Copy", #selector(handleCopySelection(_:)), key: "c"))
        menu.addItem(copyRowsSubmenu(clickedRow: row))
        rowActionItems(clickedRow: row).forEach(menu.addItem)
        return menu
    }

    /// Add / duplicate / delete rows — editable grids only.
    private func rowActionItems(clickedRow row: Int) -> [NSMenuItem] {
        guard editBuffer != nil else { return [] }
        let sources = targetRows(including: row).map(sourceIndex(forVisibleRow:))
        var items: [NSMenuItem] = [.separator()]
        if onAddRow != nil {
            items.append(item("Add row", #selector(handleAddRow(_:))))
        }
        if onDuplicateRows != nil {
            let existing = sources.filter { !insertRowIndices.contains($0) }
            if !existing.isEmpty {
                items.append(item(existing.count == 1 ? "Duplicate row" : "Duplicate \(existing.count) rows",
                                  #selector(handleDuplicateRows(_:)), existing))
            }
        }
        if onDeleteRows != nil {
            let staged = !sources.isEmpty && sources.allSatisfy { deleteRowIndices.contains($0) }
            let n = sources.count
            let title = staged
                ? (n == 1 ? "Keep row (don't delete)" : "Keep \(n) rows (don't delete)")
                : (n == 1 ? "Delete row" : "Delete \(n) rows")
            items.append(item(title, #selector(handleDeleteRows(_:)), sources, key: "\u{8}"))
        }
        return items.count > 1 ? items : []
    }

    private func addColumnInsightItems(to menu: NSMenu, column: ColumnNode) {
        guard onShowColumnDistinct != nil || makeProfilerController != nil else { return }
        menu.addItem(.separator())
        if onShowColumnDistinct != nil {
            menu.addItem(item("Distinct values for \(column.name)…", #selector(handleDistinctValues(_:)), column.name))
        }
        if makeProfilerController != nil {
            menu.addItem(item("Profile column \(column.name)…", #selector(handleProfileColumn(_:)), column.name))
        }
    }

    private func addNullFilterItems(to menu: NSMenu, column: ColumnNode, dataCol: Int) {
        guard onFilterColumn != nil else { return }
        menu.addItem(item("Filter: \(column.name) IS NULL", #selector(handleFilterIsNull(_:)), dataCol))
        menu.addItem(item("Filter: \(column.name) IS NOT NULL", #selector(handleFilterIsNotNull(_:)), dataCol))
    }

    // MARK: - Header menu

    /// Column-level menu for a header right-click — the column-relevant
    /// subset of the cell menu.
    func columnHeaderMenu(forTableColumn tableColumn: Int) -> NSMenu? {
        guard let dataCol = dataCol(forTableColumn: tableColumn), dataCol < page.columns.count else { return nil }
        let column = page.columns[dataCol]
        let menu = NSMenu()
        menu.addItem(item("Copy column name", #selector(handleCopyString(_:)), column.name))
        if let d = dataToDisplayIndex(dataCol) {
            menu.addItem(item("Select column", #selector(handleSelectColumn(_:)), d))
        }
        addColumnInsightItems(to: menu, column: column)
        if onFilterColumn != nil {
            menu.addItem(.separator())
            addNullFilterItems(to: menu, column: column, dataCol: dataCol)
        }
        return menu
    }

    private func dataToDisplayIndex(_ dataCol: Int) -> Int? {
        displayToData.firstIndex(of: dataCol)
    }

    // MARK: - Actions

    @objc private func handleCopySelection(_ sender: NSMenuItem) { _ = gridCopy() }
    @objc private func handlePaste(_ sender: NSMenuItem) { _ = gridPaste() }

    @objc private func handleCopyString(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func handleCopyRowsAs(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? CopyRequest else { return }
        let rows = RowCopy.Rows(
            columns: page.columns,
            effective: req.rows.map { v in page.columns.indices.map { effectiveValue(visibleRow: v, dataCol: $0) } },
            original: req.rows.map { v in page.rows.indices.contains(v) ? page.rows[v] : [] },
            locators: page.rowLocators.map { locs in req.rows.map { $0 < locs.count ? locs[$0] : nil } }
        )
        let n = RowCopy.copy(req.format, rows: rows, target: copyTarget)
        if n > 0 { onMessage?("Copied \(n) row\(n == 1 ? "" : "s") as \(req.format.label)", false) }
    }

    @objc private func handleEditCell(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator else { return }
        presentEditor(visibleRow: loc.visibleRow, dataCol: loc.dataCol, seed: nil, fromKeyboard: false)
    }

    @objc private func handleSetNull(_ sender: NSMenuItem) { gridSetNull() }

    @objc private func handleSetDefault(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator else { return }
        commit(sourceRow: loc.sourceRow, dataCol: loc.dataCol, typed: .defaultKeyword)
    }

    @objc private func handleNavigateFK(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator else { return }
        onNavigateForeignKey?(loc.sourceRow, loc.dataCol)
    }

    @objc private func handleFilterToCell(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator else { return }
        onFilterEqualsCell?(loc.sourceRow, loc.dataCol)
    }

    @objc private func handleFilterIsNull(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? Int else { return }
        onFilterColumn?(col, .isNull)
    }

    @objc private func handleFilterIsNotNull(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? Int else { return }
        onFilterColumn?(col, .isNotNull)
    }

    @objc private func handleDistinctValues(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onShowColumnDistinct?(name)
    }

    @objc private func handleProfileColumn(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        showProfiler(columnName: name)
    }

    @objc private func handleSelectColumn(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Int, rowCount > 0 else { return }
        changeSelection(scroll: false) { sel in
            sel.select(GridSelection.Cell(row: 0, col: d))
            sel.extend(to: GridSelection.Cell(row: rowCount - 1, col: d))
        }
    }

    @objc private func handleAddRow(_ sender: NSMenuItem) { onAddRow?() }

    @objc private func handleDuplicateRows(_ sender: NSMenuItem) {
        guard let rows = sender.representedObject as? [Int] else { return }
        onDuplicateRows?(rows)
    }

    @objc private func handleDeleteRows(_ sender: NSMenuItem) {
        guard let rows = sender.representedObject as? [Int] else { return }
        onDeleteRows?(rows)
    }

    /// Presents the column profiler anchored to the column's header, so it
    /// points at the column wherever the right-click happened.
    func showProfiler(columnName: String) {
        guard let table = tableView,
              let header = table.headerView,
              let factory = makeProfilerController,
              let vc = factory(columnName),
              let dataCol = page.columns.firstIndex(where: { $0.name == columnName }),
              let tableColIndex = tableColumnIndex(forDataCol: dataCol)
        else { return }
        let rect = header.headerRect(ofColumn: tableColIndex)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = vc
        profilerPopover = pop
        pop.show(relativeTo: rect, of: header, preferredEdge: .maxY)
    }
}
