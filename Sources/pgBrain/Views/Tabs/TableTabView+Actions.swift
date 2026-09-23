import AppKit
import SwiftUI

/// Filters, foreign-key navigation, import / export.
extension TableTabView {
    // MARK: - Filters

    /// "Filter to this value": AND `col = value` (or `IS NULL`) onto the
    /// WHERE clause, using the server's value for the row.
    func filterToCell(sourceRow: Int, dataCol: Int) {
        guard case .loaded(let page) = loader.state,
              sourceRow >= 0, sourceRow < page.rows.count, dataCol < page.columns.count
        else { return }
        let value = dataCol < page.rows[sourceRow].count ? page.rows[sourceRow][dataCol] : nil
        let fragment = RowsFetcher.equalityPredicate(column: page.columns[dataCol], value: value)
        Task { await loader.appendToWhere(fragment) }
    }

    func filterColumn(dataCol: Int, mode: ColumnFilterMode) {
        guard case .loaded(let page) = loader.state, dataCol < page.columns.count else { return }
        let name = SQLIdent.quote(page.columns[dataCol].name)
        let fragment = mode == .isNull ? "\(name) IS NULL" : "\(name) IS NOT NULL"
        Task { await loader.appendToWhere(fragment) }
    }

    /// A pick in the Distinct Values popover folds into the WHERE clause.
    func applyDistinctFilter(column: String, value: String?) {
        guard case .loaded(let page) = loader.state,
              let col = page.columns.first(where: { $0.name == column })
        else { return }
        Task { await loader.appendToWhere(RowsFetcher.equalityPredicate(column: col, value: value)) }
    }

    // MARK: - Foreign keys

    /// ⌘-click / "Go to referenced row": open the parent table filtered to
    /// the row this cell's foreign key points at. Handles composite keys by
    /// gathering every key column's value from the clicked row.
    ///
    /// Single entry point on purpose: when workspace back/forward history
    /// lands, the "open" step below is the one line to re-point.
    func navigateToForeignKey(sourceRow: Int, dataCol: Int) {
        guard case .loaded(let page) = loader.state,
              sourceRow >= 0, sourceRow < page.rows.count, dataCol < page.columns.count
        else { return }
        let columnName = page.columns[dataCol].name
        let row = page.rows[sourceRow]
        Task {
            let keys = await loader.foreignKeyCatalog()
            guard let key = ForeignKeyResolver.key(for: columnName, in: keys) else {
                service.toasts.show(.info, "\(columnName) isn't part of a foreign key.")
                return
            }
            let values: [String?] = key.localColumns.map { local in
                guard let i = page.columns.firstIndex(where: { $0.name == local }), i < row.count else { return nil }
                return row[i]
            }
            guard var refTable = service.schema.schemas
                .first(where: { $0.name == key.refSchema })?
                .tables.first(where: { $0.name == key.refTable })
            else {
                service.toasts.show(.error, "\(key.refSchema).\(key.refTable) isn't in the loaded schema.")
                return
            }
            if refTable.columns.isEmpty { refTable = await service.ensureColumns(for: refTable) }
            let refTypes = Dictionary(refTable.columns.map { ($0.name, $0.typeName) }, uniquingKeysWith: { a, _ in a })
            let clause = ForeignKeyResolver.whereClause(for: key, values: values, refTypes: refTypes)

            // Through the navigation history so ⌘[ comes back here, with
            // this tab's filter restored.
            let target = service.workspace.navigate(toTable: refTable, where: clause)
            target.tableOrderByClause = ""
        }
    }

    // MARK: - Import / export

    func rowsLabel(_ n: Int) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(formatted) row\(n == 1 ? "" : "s")"
    }

    func exportFullTable(as format: Exporter.Format) {
        guard let client = service.client else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(table.schema).\(table.name).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(
            kind: .export,
            summary: "Export \(table.qualifiedName) → \(url.lastPathComponent)"
        )
        let tracker = service.operations
        let opID = op.id
        let table = self.table
        Task {
            do {
                let stats = try await Exporter.exportTable(
                    table, format: format, destination: url,
                    client: client, tracker: tracker, operationID: opID
                )
                op.summary += " · \(rowsLabel(stats.rowsWritten))"
                tracker.finish(op, status: .succeeded)
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }

    func exportPage(_ page: RowsFetcher.Page, as format: Exporter.Format) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(table.schema).\(table.name)_page.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(kind: .export, summary: "Export result → \(url.lastPathComponent)")
        do {
            let stats = try Exporter.exportPage(page, format: format, destination: url, tableNameHint: table.name)
            op.summary += " · \(rowsLabel(stats.rowsWritten))"
            service.operations.finish(op, status: .succeeded)
        } catch {
            service.operations.finish(op, status: .failed(error.localizedDescription))
        }
    }

    func importCSV() { runImport(json: false) }
    func importJSON() { runImport(json: true) }

    private func runImport(json: Bool) {
        guard let client = service.client else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let accessory = ImportOptionsAccessory(json: json)
        panel.accessoryView = accessory.view
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csvOptions = accessory.csvOptions
        let encoding = accessory.encoding
        let op = service.operations.begin(
            kind: .importJob,
            summary: "Import \(url.lastPathComponent) → \(table.qualifiedName)"
        )
        let tracker = service.operations
        let opID = op.id
        let table = self.table
        Task {
            do {
                let stats = json
                    ? try await Importer.importJSON(into: table, from: url, client: client, encoding: encoding,
                                                    tracker: tracker, operationID: opID)
                    : try await Importer.importCSV(into: table, from: url, client: client, options: csvOptions,
                                                   tracker: tracker, operationID: opID)
                op.summary += " · \(rowsLabel(stats.rowsImported))"
                tracker.finish(op, status: .succeeded)
                await loader.load()
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }
}
