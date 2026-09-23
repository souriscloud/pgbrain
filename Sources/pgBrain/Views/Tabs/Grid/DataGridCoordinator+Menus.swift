import AppKit

extension DataGridView.Coordinator {
    /// Builds the right-click context menu for the cell under the
    /// pointer. `visibleRow` is the index in the (possibly filtered)
    /// view; `dataCol` is the index in `page.columns`. We translate
    /// `visibleRow` to its source-row immediately so subsequent
    /// actions target the underlying data row.
    func contextMenu(forVisibleRow visibleRow: Int, dataCol: Int) -> NSMenu? {
        guard visibleRow >= 0, dataCol >= 0, dataCol < page.columns.count, visibleRow < page.rows.count else { return nil }
        let sourceRow = sourceIndex(forVisibleRow: visibleRow)
        let column = page.columns[dataCol]
        let original = page.rows[visibleRow][dataCol]
        let displayed: String? = editBuffer?.value(row: sourceRow, column: dataCol).flatMap { $0 } ?? original

        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy value", action: #selector(handleCopy(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = displayed ?? ""
        menu.addItem(copy)

        let copyName = NSMenuItem(title: "Copy column name", action: #selector(handleCopy(_:)), keyEquivalent: "")
        copyName.target = self
        copyName.representedObject = column.name
        menu.addItem(copyName)

        if onShowColumnDistinct != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Distinct values for \(column.name)…",
                action: #selector(handleDistinctValues(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.name
            menu.addItem(item)
        }

        if makeProfilerController != nil {
            if onShowColumnDistinct == nil { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: "Profile column \(column.name)…",
                action: #selector(handleProfileColumn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.name
            menu.addItem(item)
        }

        // Filter-to-value bloc. Available regardless of edit
        // buffer — these write to the WHERE strip, no PK needed.
        if onFilterEqualsCell != nil || onFilterColumn != nil {
            menu.addItem(.separator())
            if onFilterEqualsCell != nil {
                let label: String = {
                    guard let displayed else {
                        return "Filter to NULL on \(column.name)"
                    }
                    let preview = displayed.count > 24
                        ? String(displayed.prefix(22)) + "…"
                        : displayed
                    return "Filter to \"\(preview)\""
                }()
                let item = NSMenuItem(title: label, action: #selector(handleFilterToCell(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = CellLocator(row: sourceRow, col: dataCol)
                menu.addItem(item)
            }
            if onFilterColumn != nil {
                let nullItem = NSMenuItem(title: "Filter: \(column.name) IS NULL", action: #selector(handleFilterIsNull(_:)), keyEquivalent: "")
                nullItem.target = self
                nullItem.representedObject = dataCol
                menu.addItem(nullItem)
                let notNullItem = NSMenuItem(title: "Filter: \(column.name) IS NOT NULL", action: #selector(handleFilterIsNotNull(_:)), keyEquivalent: "")
                notNullItem.target = self
                notNullItem.representedObject = dataCol
                menu.addItem(notNullItem)
            }
        }

        // Selection-export bloc. Only meaningful when at least one
        // row is selected (or focused) — the receivers gate the
        // pasteboard write themselves but no point cluttering
        // the menu otherwise.
        if onCopyAsMarkdown != nil || onCopyAsSlack != nil {
            menu.addItem(.separator())
            if onCopyAsMarkdown != nil {
                let item = NSMenuItem(title: "Copy selection as Markdown table", action: #selector(handleCopyMarkdown(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            if onCopyAsSlack != nil {
                let item = NSMenuItem(title: "Copy selection as Slack code block", action: #selector(handleCopySlack(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        // Row-level actions live on the same menu when the grid has
        // a primary key + edit buffer (i.e. this is a real table).
        if editBuffer != nil {
            menu.addItem(.separator())
            let asInsert = NSMenuItem(title: "Copy row as INSERT", action: #selector(handleRowInsert(_:)), keyEquivalent: "")
            asInsert.target = self
            asInsert.representedObject = sourceRow
            menu.addItem(asInsert)
            let asDelete = NSMenuItem(title: "Copy row as DELETE", action: #selector(handleRowDelete(_:)), keyEquivalent: "")
            asDelete.target = self
            asDelete.representedObject = sourceRow
            menu.addItem(asDelete)
            let dup = NSMenuItem(title: "Duplicate row (INSERT to clipboard)", action: #selector(handleRowDuplicate(_:)), keyEquivalent: "")
            dup.target = self
            dup.representedObject = sourceRow
            menu.addItem(dup)
            menu.addItem(.separator())
            let edit = NSMenuItem(title: "Edit cell…", action: #selector(handleEditMenu(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = CellLocator(row: sourceRow, col: dataCol)
            menu.addItem(edit)
            if column.nullable {
                let setNull = NSMenuItem(title: "Set NULL", action: #selector(handleSetNull(_:)), keyEquivalent: "n")
                setNull.keyEquivalentModifierMask = [.control, .command]
                setNull.target = self
                setNull.representedObject = CellLocator(row: sourceRow, col: dataCol)
                menu.addItem(setNull)
            }
        }

        // Destructive: delete the right-clicked row, or the whole
        // selection if the clicked row is part of a multi-row selection.
        if onDeleteRows != nil {
            let selected = tableView?.selectedRowIndexes ?? []
            let targetsVisible: [Int] = selected.contains(visibleRow) ? Array(selected) : [visibleRow]
            let sourceRows = targetsVisible.map { sourceIndex(forVisibleRow: $0) }
            menu.addItem(.separator())
            // Staged rows can be un-staged from the same menu; the actual
            // DELETE happens on Apply, not here, so no "…" confirmation.
            let allStaged = !sourceRows.isEmpty && sourceRows.allSatisfy { deleteRowIndices.contains($0) }
            let n = sourceRows.count
            let title: String
            if allStaged {
                title = n == 1 ? "Keep row (don't delete)" : "Keep \(n) rows (don't delete)"
            } else {
                title = n == 1 ? "Delete row" : "Delete \(n) rows"
            }
            let del = NSMenuItem(title: title, action: #selector(handleDeleteRows(_:)), keyEquivalent: "")
            del.target = self
            del.representedObject = sourceRows
            menu.addItem(del)
        }
        return menu
    }

    private struct CellLocator {
        let row: Int
        let col: Int
    }

    @objc private func handleCopy(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func handleEditMenu(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator,
              let buffer = editBuffer, let table = tableView else { return }
        presentEditor(row: loc.row, col: loc.col, in: table, buffer: buffer)
    }

    @objc private func handleSetNull(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator,
              let _ = editBuffer else { return }
        // `loc.row` is already a source-row index — see contextMenu.
        // Walk the visible rows to find the original cell value.
        let visibleRow = sourceRowIndices.firstIndex(of: loc.row) ?? loc.row
        let original = page.rows[visibleRow][loc.col]
        commit(row: loc.row, col: loc.col, original: original, typed: .null)
        tableView?.reloadData()
    }

    @objc private func handleRowInsert(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Int else { return }
        onCopyRowAsInsert?(r)
    }

    @objc private func handleRowDelete(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Int else { return }
        onCopyRowAsDelete?(r)
    }

    @objc private func handleRowDuplicate(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Int else { return }
        onDuplicateRow?(r)
    }

    @objc private func handleFilterToCell(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? CellLocator else { return }
        onFilterEqualsCell?(loc.row, loc.col)
    }

    @objc private func handleFilterIsNull(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? Int else { return }
        onFilterColumn?(col, .isNull)
    }

    @objc private func handleFilterIsNotNull(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? Int else { return }
        onFilterColumn?(col, .isNotNull)
    }

    @objc private func handleCopyMarkdown(_ sender: NSMenuItem) { onCopyAsMarkdown?() }
    @objc private func handleCopySlack(_ sender: NSMenuItem) { onCopyAsSlack?() }

    @objc private func handleDistinctValues(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onShowColumnDistinct?(name)
    }

    @objc private func handleProfileColumn(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        showProfiler(columnName: name)
    }

    /// Presents the column profiler as an `NSPopover` anchored to the
    /// column's header cell, so it points at the column regardless of
    /// where the right-click happened (header or any cell in it).
    func showProfiler(columnName: String) {
        guard let table = tableView,
              let header = table.headerView,
              let factory = makeProfilerController,
              let vc = factory(columnName),
              let dataCol = page.columns.firstIndex(where: { $0.name == columnName })
        else { return }
        // Resolve the *visual* table-column index by identifier so the
        // anchor is correct even after the user reorders columns.
        let identifier = "\(dataCol)_\(columnName)"
        guard let tableColIndex = table.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == identifier
        }) else { return }
        let rect = header.headerRect(ofColumn: tableColIndex)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = vc
        profilerPopover = pop
        pop.show(relativeTo: rect, of: header, preferredEdge: .maxY)
    }

    /// Column-level menu for a header right-click — the column-relevant
    /// subset of the cell menu (no cell-value items). `dataCol` indexes
    /// `page.columns`.
    func columnHeaderMenu(forDataCol dataCol: Int) -> NSMenu? {
        guard dataCol >= 0, dataCol < page.columns.count else { return nil }
        let column = page.columns[dataCol]
        let menu = NSMenu()

        let copyName = NSMenuItem(title: "Copy column name", action: #selector(handleCopy(_:)), keyEquivalent: "")
        copyName.target = self
        copyName.representedObject = column.name
        menu.addItem(copyName)

        if onShowColumnDistinct != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Distinct values for \(column.name)…",
                action: #selector(handleDistinctValues(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.name
            menu.addItem(item)
        }

        if makeProfilerController != nil {
            if onShowColumnDistinct == nil { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: "Profile column \(column.name)…",
                action: #selector(handleProfileColumn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.name
            menu.addItem(item)
        }

        if onFilterColumn != nil {
            menu.addItem(.separator())
            let nullItem = NSMenuItem(title: "Filter: \(column.name) IS NULL", action: #selector(handleFilterIsNull(_:)), keyEquivalent: "")
            nullItem.target = self
            nullItem.representedObject = dataCol
            menu.addItem(nullItem)
            let notNullItem = NSMenuItem(title: "Filter: \(column.name) IS NOT NULL", action: #selector(handleFilterIsNotNull(_:)), keyEquivalent: "")
            notNullItem.target = self
            notNullItem.representedObject = dataCol
            menu.addItem(notNullItem)
        }

        return menu
    }

    @objc private func handleDeleteRows(_ sender: NSMenuItem) {
        guard let rows = sender.representedObject as? [Int] else { return }
        onDeleteRows?(rows)
    }
}
