#if DEBUG
import AppKit
import PostgresNIO
import SwiftUI

/// The smoke suite (`scripts/smoke.sh`): scenes named `smoke-…` that drive a
/// real window like a user would — through the same model entry points the
/// UI calls — assert what should have happened, and capture a PNG of it.
/// They run only when asked for, against the fixtures in
/// `scripts/showcase/smoke-seed.sql`. Nothing here may present a modal
/// alert (it would block the run): decision logic is asserted instead.
extension ShowcaseScenes {
    var smokeScenes: [(String, () async throws -> Void)] {
        [
            ("smoke-tour", smokeTour),
            ("smoke-navigation", smokeNavigation),
            ("smoke-grid", smokeGrid),
            ("smoke-scratchpad", smokeScratchpad),
            ("smoke-panes", smokePanes),
            ("smoke-switcher", smokeSwitcher),
            ("smoke-reconnect", smokeReconnect),
        ]
    }

    // MARK: - Assertions

    func expect(_ condition: Bool, _ what: @autoclosure () -> String) throws {
        let message = what()
        guard condition else {
            ShowcaseLog.write("  ✗ \(message)")
            throw ShowcaseError(message)
        }
        ShowcaseLog.write("  ✓ \(message)")
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) throws {
        try expect(actual == expected, "\(what): expected \(expected), got \(actual)")
    }

    // MARK: - Database helpers

    /// First column of the first row, as text, through the window's pool.
    func dbValue(_ sql: String) async throws -> String? {
        guard let client = service.client else { throw ShowcaseError("no pool client") }
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let cell = PostgresRandomAccessRow(row)[0]
            return cell.bytes == nil ? nil : try cell.decode(String.self, context: .default)
        }
        return nil
    }

    /// Run SQL from outside the app (another client), rows as unit-separated
    /// text exactly as psql prints them.
    @discardableResult
    func psql(_ sql: String, database: String = ShowcaseEnvironment.databaseName) throws -> [[String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                             "-F", "\u{1f}", "-d", database, "-c", sql]
        var env = ProcessInfo.processInfo.environment
        env["PGAPPNAME"] = "smoke-external"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShowcaseError("psql failed: \(String(decoding: errData, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init) }
    }

    func page(of loader: RowsLoader) throws -> RowsFetcher.Page {
        guard case .loaded(let page) = loader.state else { throw ShowcaseError("\(loader.table.id) has no page") }
        return page
    }

    func col(_ name: String, _ loader: RowsLoader) throws -> Int {
        guard let i = try page(of: loader).columns.firstIndex(where: { $0.name == name }) else {
            throw ShowcaseError("no column \(name) in \(loader.table.id)")
        }
        return i
    }

    func row(id: String, _ loader: RowsLoader, idColumn: String = "id") throws -> Int {
        let c = try col(idColumn, loader)
        guard let r = try page(of: loader).rows.firstIndex(where: { $0[c] == id }) else {
            throw ShowcaseError("no row \(idColumn)=\(id) on the page of \(loader.table.id)")
        }
        return r
    }

    func settleAfterLoad(_ loader: RowsLoader, _ what: String) async throws {
        try await ShowcaseRunner.wait(what) {
            if case .loaded = loader.state { return !loader.isRefreshing }
            if case .error = loader.state { return true }
            return false
        }
        if case .error(let message) = loader.state { throw ShowcaseError("\(what): \(message)") }
    }

    // MARK: - Scratchpad helpers

    /// Add a cell with `sql` to `pad`, run it like ⌘↩ does and return its
    /// results once the run finished.
    @discardableResult
    func run(_ sql: String, in pad: Notebook, timeout: Double = 30) async throws -> [NotebookResult] {
        let cell = NotebookCell(kind: .sql, text: sql)
        if let blank = pad.cells.first(where: { $0.kind == .sql && $0.text.isEmpty }) {
            blank.text = sql
            return try await run(cell: blank, in: pad, timeout: timeout)
        }
        pad.insert(cell, after: pad.cells.last!.id)
        return try await run(cell: cell, in: pad, timeout: timeout)
    }

    private func run(cell: NotebookCell, in pad: Notebook, timeout: Double) async throws -> [NotebookResult] {
        try await ShowcaseRunner.wait("previous run to finish") { !pad.isRunning }
        NotebookRunner.run(cell: cell, selection: nil, notebook: pad, service: service)
        try await ShowcaseRunner.wait("run of \(cell.text.prefix(40))", timeout: timeout) { !pad.isRunning }
        return pad.adjacentResults(after: cell.id).compactMap { pad.result(id: $0.resultID) }
    }

    @discardableResult
    func success(_ results: [NotebookResult], _ what: String) throws -> QueryResult {
        guard let last = results.last else { throw ShowcaseError("\(what): no result") }
        for r in results {
            if case .failure(let message) = r.status { throw ShowcaseError("\(what): \(message)") }
        }
        guard case .success(let q) = last.status else { throw ShowcaseError("\(what): status \(last.status)") }
        return q
    }

    // MARK: - a. Tour

    private func smokeTour() async throws {
        closeAllTabs()
        let ws = service.workspace
        try expect(ws.tabs.isEmpty, "tour starts from an empty workspace")
        ws.sidebarVisible = false
        OnboardingTour.start(in: service)
        try expect(ws.sidebarVisible, "starting the tour shows the sidebar")
        for step in OnboardingTour.steps {
            if step.id > 0 { OnboardingTour.prepare(step, in: service) }
            ws.onboardingStep = step.id
            await ShowcaseRenderer.settle(window, turns: 6)
            if step.anchor == .tabs || step.anchor == .grid || step.anchor == .tableHeader {
                guard let tab = ws.selectedTab, let node = tab.tableNode else {
                    throw ShowcaseError("tour step \(step.id): ensureTableTab opened no table tab")
                }
                if step.anchor == .tabs {
                    try expect(tab.isPreview, "tour step \(step.id) opened \(node.id) as a preview tab")
                }
                try await settleAfterLoad(service.loader(for: tab, table: node), "tour grid rows")
                await ShowcaseRenderer.settle(window, turns: 4)
            }
            if let anchor = step.anchor {
                let seen = OnboardingTour.anchorsSeen[ws.windowID] ?? []
                try expect(seen.contains(anchor),
                           "tour step \(step.id) (\(step.title)) finds its \(anchor) anchor on screen (seen: \(seen.map { "\($0)" }.sorted()))")
            }
            try await capture(String(format: "smoke-tour-%02d", step.id))
        }
        ws.onboardingStep = nil
    }

    // MARK: - b. Navigation

    private func smokeNavigation() async throws {
        closeAllTabs()
        let ws = service.workspace
        let customers = try table("public", "customers")
        let products = try table("public", "products")
        let invoices = try table("billing", "invoices")
        let orders = try table("public", "orders")

        ws.openTable(customers, preview: true)
        ws.openTable(products, preview: true)
        try expectEqual(ws.tabs.count, 1, "two preview opens leave one tab")
        try expect(ws.tabs.first?.isPreview == true && ws.tabs.first?.tableNode?.id == products.id,
                   "the preview tab was replaced by public.products")
        ws.keepTab(id: ws.tabs[0].id)
        ws.openTable(invoices, preview: true)
        try expectEqual(ws.tabs.count, 2, "a kept tab survives the next preview")
        try expectEqual(ws.tabs.filter(\.isPreview).count, 1, "exactly one preview tab")
        let invoicesTab = ws.tabs.first { $0.tableNode?.id == invoices.id }!
        ws.togglePinned(id: invoicesTab.id)
        try expect(invoicesTab.isPinned && !invoicesTab.isPreview && ws.tabs.first === invoicesTab,
                   "pinning moves the tab to the front and keeps it")
        let (customersTab, _) = try await openLoaded(customers, where: "country = 'DE'")
        ws.closeTabs(ws.idsToCloseOthers(keeping: customersTab.id))
        try expectEqual(ws.tabs.map { $0.tableNode?.id ?? "?" }, [invoices.id, customers.id],
                        "Close Others keeps the pinned tab and the current one")

        let target = ws.navigate(toTable: orders, where: "customer_id = 5")
        try expect(ws.selectedTab === target && target.tableWhereClause == "customer_id = 5",
                   "navigate(toTable:where:) opens orders filtered")
        let ordersLoader = service.loader(for: target, table: orders)
        try await settleAfterLoad(ordersLoader, "filtered orders")
        try expectEqual(ordersLoader.filter.whereClause, "customer_id = 5", "orders loaded with the jump's WHERE")
        await ShowcaseRenderer.settle(window)
        try await capture("smoke-nav-fk-jump")
        try expect(ws.canGoBack, "back is available after a jump")
        customersTab.tableWhereClause = "country = 'DE'"
        ws.goBack()
        try expect(ws.selectedTab === customersTab, "goBack() returns to customers")
        try expectEqual(customersTab.tableWhereClause, "country = 'DE'", "goBack() restores the WHERE")
        try expect(ws.canGoForward, "forward is available after going back")
        await ShowcaseRenderer.settle(window)
        try await capture("smoke-nav-back")

        // Go to Table: partitions live under their parent; extension objects
        // follow the sidebar's toggle (off by default).
        let items = CommandProviders.goToItems(service: service).filter { $0.category == .table }
        let all = service.schema.schemas.flatMap(\.tables)
        let partitions = Set(all.filter { $0.partitionOf != nil }.map { "table.\($0.schema).\($0.name)" })
        let extensionObjects = Set(all.filter(\.isExtensionOwned).map { "table.\($0.schema).\($0.name)" })
        try expect(!partitions.isEmpty, "the seed has partitions (\(partitions.count))")
        try expect(items.allSatisfy { !partitions.contains($0.id) }, "Go to Table lists no partitions")
        try expect(items.allSatisfy { !extensionObjects.contains($0.id) },
                   "Go to Table lists no extension-owned relations (\(extensionObjects.count) in the catalog)")
        try expect(items.contains { $0.id == "table.public.orders" }, "Go to Table lists public.orders")

        // Schema visibility.
        let visibility = SchemaVisibility.shared
        visibility.setHidden(true, schema: "inventory", connectionID: connection.id)
        try expect(!service.visibleSchema.schemas.contains { $0.name == "inventory" }, "hiding inventory removes it from visibleSchema")
        await ShowcaseRenderer.settle(window)
        try await capture("smoke-nav-hidden-schema")
        visibility.setHidden(false, schema: "inventory", connectionID: connection.id)
        try expect(service.visibleSchema.schemas.contains { $0.name == "inventory" }, "showing inventory brings it back")

        // Schema reload keeps tabs and the tree.
        let tabIDs = ws.tabs.map(\.id)
        let reload = Task { await self.service.loadSchema() }
        try await ShowcaseRunner.wait("schema reload to start", timeout: 5) { self.service.schemaState == .loading }
        await ShowcaseRenderer.settle(window, turns: 2)
        try await capture("smoke-nav-reload-during", settleTurns: 1)
        await reload.value
        try await ShowcaseRunner.wait("column enrichment after reload") {
            (try? self.table("public", "orders").columns.isEmpty == false) ?? false
        }
        await ShowcaseRenderer.settle(window, turns: 6)
        try expectEqual(ws.tabs.map(\.id), tabIDs, "schema reload keeps every open tab")
        try expect(ws.selectedTab === customersTab, "schema reload keeps the selected tab")
        try await capture("smoke-nav-reload-after")
    }

    // MARK: - c. Grid editing

    private func smokeGrid() async throws {
        closeAllTabs()
        let items = try table("smoke", "items")
        let (_, loader) = try await openLoaded(items, orderBy: "id")
        try expect(loader.isEditable, "smoke.items is editable")
        let priceCol = try col("price", loader), nameCol = try col("name", loader), idCol = try col("id", loader)
        try expectEqual(try page(of: loader).rows.first?[idCol] ?? nil, "1", "the page is ordered by id")

        // Edit → Apply → server-normalised value.
        let r1 = try row(id: "1", loader)
        loader.editBuffer.set(row: r1, column: priceCol, value: "12.5")
        try expect(loader.hasPendingChanges, "the edit is staged")
        if case .success(let script) = loader.previewSQL() {
            try expect(script.contains("UPDATE"), "Preview SQL shows an UPDATE")
        } else {
            throw ShowcaseError("previewSQL failed")
        }
        try expect(await loader.apply(), "apply succeeds (\(loader.applyError ?? ""))")
        try expectEqual(try await dbValue("SELECT price::text FROM smoke.items WHERE id = 1"), "12.50", "DB holds the edit")
        try expectEqual(try page(of: loader).rows[r1][priceCol], "12.50", "grid shows the server-normalised value")
        try expect(!loader.hasPendingChanges, "nothing staged after apply")
        await ShowcaseRenderer.settle(window)
        try await capture("smoke-grid-applied")

        // Insert a draft row.
        loader.addInsertRow()
        let draft = try page(of: loader).rows.count - 1
        loader.editBuffer.set(row: draft, column: idCol, value: "100")
        loader.editBuffer.set(row: draft, column: nameCol, value: "draft row")
        loader.editBuffer.set(row: draft, column: priceCol, value: "3")
        try expectEqual(loader.pendingSummary.inserts, 1, "one draft insert staged")
        try expect(await loader.apply(), "insert applies (\(loader.applyError ?? ""))")
        try expectEqual(try await dbValue("SELECT name FROM smoke.items WHERE id = 100"), "draft row", "DB has the inserted row")
        try expectEqual(try page(of: loader).rows[draft][priceCol], "3.00", "grid shows the stored numeric for the insert")

        // Delete.
        loader.toggleDelete(sourceRows: [try row(id: "2", loader)])
        try expectEqual(loader.pendingSummary.deletes, 1, "one delete staged")
        try expect(await loader.apply(), "delete applies (\(loader.applyError ?? ""))")
        try expectEqual(try await dbValue("SELECT count(*)::text FROM smoke.items WHERE id = 2"), "0", "row 2 is gone from the DB")
        try expect((try? row(id: "2", loader)) == nil, "row 2 is gone from the grid")

        // Stale-row guard: a batch whose second row changed underneath.
        loader.editBuffer.set(row: try row(id: "3", loader), column: nameCol, value: "mine 3")
        loader.editBuffer.set(row: try row(id: "5", loader), column: nameCol, value: "mine 5")
        try psql("UPDATE smoke.items SET name = 'theirs' WHERE id = 5")
        let staleOK = await loader.apply()
        try expect(!staleOK, "apply refuses when a row changed underneath")
        try expect(loader.applyError?.contains("changed or deleted by someone else") == true,
                   "the error says the row was changed by someone else (\(loader.applyError ?? "nil"))")
        try expectEqual(try await dbValue("SELECT name FROM smoke.items WHERE id = 5"), "theirs", "the other client's value survives")
        try expectEqual(try await dbValue("SELECT name FROM smoke.items WHERE id = 3"), "item 3", "the rest of the batch rolled back")
        try expect(loader.hasPendingChanges, "the staged edits are kept for the user")
        await ShowcaseRenderer.settle(window)
        try await capture("smoke-grid-stale")
        loader.revert()
        try expect(!loader.hasPendingChanges, "revert clears the staged edits")

        // Dirty guard: paging with staged edits asks instead of discarding.
        loader.editBuffer.set(row: 0, column: nameCol, value: "dirty")
        let offset = loader.pageOffset
        await loader.loadNextPage()
        try expect(loader.pendingNavigation != nil, "paging with staged edits asks first")
        try expectEqual(loader.pageOffset, offset, "the page did not move")
        await loader.resolvePendingNavigation(.cancel)?.value
        try expect(loader.hasPendingChanges && loader.pendingNavigation == nil, "Cancel keeps the edits")
        await loader.loadNextPage()
        await loader.resolvePendingNavigation(.discard)?.value
        try await settleAfterLoad(loader, "next page after discard")
        try expect(!loader.hasPendingChanges && loader.pageOffset == offset + loader.pageSize,
                   "Discard drops the edits and pages on")
        await loader.loadFirstPage()
        try await settleAfterLoad(loader, "first page")

        // No primary key → edited through ctid.
        let nopk = try table("smoke", "nopk")
        let (_, pk) = try await openLoaded(nopk, orderBy: "label")
        try expect(pk.rowIdentity == .physical, "smoke.nopk is edited by physical row")
        let beta = try row(id: "beta", pk, idColumn: "label")
        pk.editBuffer.set(row: beta, column: try col("qty", pk), value: "42")
        try expect(await pk.apply(), "ctid edit applies (\(pk.applyError ?? ""))")
        try expectEqual(try await dbValue("SELECT qty::text FROM smoke.nopk WHERE label = 'beta'"), "42", "DB holds the ctid edit")
        try expectEqual(try await dbValue("SELECT count(*)::text FROM smoke.nopk WHERE qty = 42"), "1", "exactly one row changed")
        await ShowcaseRenderer.settle(window)
        try await capture("smoke-grid-nopk")
    }

    // MARK: - d. Scratchpad

    private func smokeScratchpad() async throws {
        closeAllTabs()
        let pad = service.workspace.openScratchpad()
        await ShowcaseRenderer.settle(window)

        try success(try await run("SET search_path TO analytics", in: pad), "SET search_path")
        let q1 = try success(try await run("SELECT count(*) AS n FROM events", in: pad), "query relying on search_path")
        try expect(Int(q1.page.rows.first?.first.flatMap { $0 } ?? "") ?? 0 > 0, "unqualified events resolves via the session's search_path")

        try success(try await run("CREATE TEMP TABLE smoke_tmp AS SELECT 7 AS v", in: pad), "CREATE TEMP TABLE")
        let q2 = try success(try await run("SELECT v FROM smoke_tmp", in: pad), "temp table in a later run")
        try expectEqual(q2.page.rows.first?.first ?? nil, "7", "the temp table survives between runs")

        let before = try await dbValue("SELECT name FROM smoke.items WHERE id = 7")
        try success(try await run("BEGIN; UPDATE smoke.items SET name = 'in txn' WHERE id = 7", in: pad), "BEGIN; UPDATE")
        try expect(pad.transaction.isOpen, "the transaction indicator shows an open transaction")
        await ShowcaseRenderer.settle(window, turns: 6)
        try await capture("smoke-scratchpad-txn")
        NotebookRunner.endTransaction(commit: false, notebook: pad, service: service)
        try await ShowcaseRunner.wait("rollback") { !pad.transaction.isOpen && pad.runTask == nil }
        try expectEqual(try await dbValue("SELECT name FROM smoke.items WHERE id = 7"), before, "Roll Back left the row unchanged")

        // Every value rendered exactly as psql prints it.
        let typesSQL = """
            SELECT interval '1 year 2 mons 3 days 04:05:06.789' AS iv,
                   12345678901234567890123456789012345678901234567890.123::numeric AS big,
                   time '13:14:15.123456' AS t,
                   ARRAY[1, NULL, 3]::int[] AS ints,
                   ARRAY['a b', 'c"d', NULL]::text[] AS texts,
                   'NaN'::numeric AS nan, 'NaN'::float8 AS fnan,
                   'infinity'::timestamptz AS inf, '-infinity'::date AS ninf,
                   '{"b": 1, "a": [1, 2.50]}'::jsonb AS doc,
                   '192.168.0.1/24'::inet AS addr, 1234.5::money AS cash,
                   date '0044-03-15 BC' AS bc, true AS yes, '\\x00ff'::bytea AS raw
            """
        let q3 = try success(try await run(typesSQL, in: pad), "type rendering row")
        let psqlRowRaw = try psql("SET search_path TO analytics; " + typesSQL).last ?? []
        // Booleans are the one documented deviation: the grid shows true /
        // false where psql prints t / f (TextValue.normaliser).
        let psqlRow = psqlRowRaw.map { $0 == "t" ? "true" : ($0 == "f" ? "false" : $0) }
        let appRow = (q3.page.rows.first ?? []).map { $0 ?? "" }
        for (i, column) in q3.page.columns.enumerated() {
            let expected = i < psqlRow.count ? psqlRow[i] : "<missing>"
            try expectEqual(i < appRow.count ? appRow[i] : "<missing>", expected, "\(column.name) renders as psql")
        }

        let q4 = try success(try await run("SELECT relname, relacl FROM pg_class ORDER BY relacl IS NULL, oid LIMIT 20", in: pad),
                             "SELECT from pg_class (aclitem[])")
        try expect(!q4.page.rows.isEmpty, "pg_class rows came back")

        // Stop cancels just this statement; the session stays.
        let pid = pad.session?.backendPID
        let sleepCell = NotebookCell(kind: .sql, text: "SELECT pg_sleep(30)")
        pad.insert(sleepCell, after: pad.cells.last!.id)
        NotebookRunner.run(cell: sleepCell, selection: nil, notebook: pad, service: service)
        try await ShowcaseRunner.wait("pg_sleep on the wire", timeout: 5) { pad.currentTicket != nil }
        try await Task.sleep(for: .milliseconds(600))
        let stopped = Date()
        pad.stop()
        try await ShowcaseRunner.wait("cancelled run to finish", timeout: 5) { !pad.isRunning }
        let took = Date().timeIntervalSince(stopped)
        try expect(took < 3, "Stop ended pg_sleep(30) in \(String(format: "%.2f", took)) s")
        let sleepResult = pad.adjacentResults(after: sleepCell.id).compactMap { pad.result(id: $0.resultID) }.last
        if case .cancelled = sleepResult?.status {} else {
            throw ShowcaseError("the stopped statement's status is \(String(describing: sleepResult?.status))")
        }
        let q5 = try success(try await run("SELECT v FROM smoke_tmp", in: pad), "query after Stop")
        try expectEqual(q5.page.rows.first?.first ?? nil, "7", "the session (temp table) survived Stop")
        try expectEqual(pad.session?.backendPID, pid, "same server session after Stop")

        await ShowcaseRenderer.settle(window, turns: 6)
        scrollToBottom(in: window)
        await ShowcaseRenderer.settle(window, turns: 6)
        try await capture("smoke-scratchpad")
    }

    // MARK: - f. Other panes

    private func smokePanes() async throws {
        closeAllTabs()
        let products = try table("public", "products")
        let (tab, _) = try await openLoaded(products)
        tab.tableViewState.pane = .structure
        let inspector = service.inspector(for: tab, table: products)
        await ShowcaseRenderer.settle(window)
        try await ShowcaseRunner.wait("structure") {
            if case .loaded = inspector.state { return true }
            if case .error = inspector.state { return true }
            return false
        }
        guard case .loaded(let snapshot, let ddl) = inspector.state else {
            throw ShowcaseError("inspector failed: \(inspector.state)")
        }
        try expect(!snapshot.columns.isEmpty, "Structure lists \(snapshot.columns.count) columns")
        try await capture("smoke-structure")
        tab.tableViewState.pane = .ddl
        try expect(ddl.contains("CREATE TABLE"), "DDL starts with CREATE TABLE")
        try await capture("smoke-ddl")
        tab.tableViewState.pane = .data

        // Not a tab: the explain sheet sits over the table, as in the app.
        let pad = Notebook(title: "explain")
        defer { pad.closeSession() }
        let sql = "SELECT c.country, count(*) FROM orders o JOIN customers c ON c.id = o.customer_id GROUP BY 1"
        let plan = await NotebookRunner.explain(sql: sql, analyze: true, notebook: pad, service: service)
        if case .failure(let error) = plan { throw ShowcaseError("EXPLAIN failed: \(error)") }
        let service = self.service!
        let explainView = ExplainPlanView(
            initialSQL: sql,
            runExplain: { analyze in await NotebookRunner.explain(sql: sql, analyze: analyze, notebook: pad, service: service) },
            onClose: {})
        try await capture("smoke-explain", overlay: { self.hostWindow(explainView) }, placement: .sheet, settleTurns: 20)

        guard var schema = service.visibleSchema.schemas.first(where: { $0.name == "public" }) else {
            throw ShowcaseError("no public schema")
        }
        schema.tables.removeAll { $0.partitionOf != nil || $0.isExtensionOwned }
        try expect(schema.tables.contains { $0.name == "orders" }, "ERD includes public.orders")
        let erd = ERDView(schema: schema, onOpenTable: { _ in }, onClose: {})
        try await capture("smoke-erd", overlay: { self.hostWindow(erd) }, placement: .sheet)

        try await smokeImportExport()
    }

    private func smokeImportExport() async throws {
        guard let client = service.client else { throw ShowcaseError("no client") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Header in a different order than the table, a UTF-8 BOM, a quoted
        // comma, an empty unquoted cell (NULL) and a quoted empty string ('').
        let csv = "\u{FEFF}note,amount,id,name\r\nhello,1.5,1,Ann\r\n,2,2,\"Bob, Jr\"\r\n\"\",,3,Zoë\r\n"
        let csvURL = dir.appendingPathComponent("people.csv")
        try Data(csv.utf8).write(to: csvURL)
        let target = await service.ensureColumns(for: try table("smoke", "import_target"))
        let options = ImportOptionsAccessory(json: false).csvOptions
        let stats = try await Importer.importCSV(into: target, from: csvURL, client: client, options: options)
        try expectEqual(stats.rowsImported, 3, "CSV import row count")
        let imported = try psql("SELECT id, name, coalesce(note, '<null>'), coalesce(amount::text, '<null>') FROM smoke.import_target ORDER BY id")
        try expectEqual(imported, [["1", "Ann", "hello", "1.50"], ["2", "Bob, Jr", "<null>", "2.00"], ["3", "Zoë", "", "<null>"]],
                        "CSV import mapped columns by header, NULL vs ''")

        let probe = await service.ensureColumns(for: try table("smoke", "export_probe"))
        let csvOut = dir.appendingPathComponent("probe.csv")
        _ = try await Exporter.exportTable(probe, format: .csv, destination: csvOut, client: client)
        let csvLines = try String(contentsOf: csvOut, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        try expectEqual(csvLines.first ?? "", "id,label,n", "CSV export header")
        try expectEqual(Set(csvLines.dropFirst()), ["1,,1.5", "2,\"\",NaN", "3,\"a,\"\"b\"\"\","],
                        "CSV export distinguishes NULL from '' and quotes")

        let jsonOut = dir.appendingPathComponent("probe.json")
        _ = try await Exporter.exportTable(probe, format: .json, destination: jsonOut, client: client)
        let data = try Data(contentsOf: jsonOut)
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ShowcaseError("JSON export is not an array of objects")
        }
        let byID = Dictionary(uniqueKeysWithValues: objects.compactMap { o -> (String, [String: Any])? in
            guard let id = o["id"] else { return nil }
            return ("\(id)", o)
        })
        try expect(byID["1"]?["label"] is NSNull, "JSON export writes NULL as null")
        try expectEqual(byID["2"]?["label"] as? String, "", "JSON export writes '' as \"\"")
        try expect(byID["2"]?["n"] != nil, "JSON export of NaN is valid JSON (\(String(describing: byID["2"]?["n"])))")
    }

    // MARK: - e. Database switcher

    private func smokeSwitcher() async throws {
        let manager = delegate.windowManager
        let otherDB = ShowcaseEnvironment.databaseName + "_b"
        let before = manager.entries.count
        delegate.openConnection(connection, database: connection.database)
        try expectEqual(manager.entries.count, before, "switching to the current database opens no window")

        delegate.openConnection(connection, database: otherDB)
        guard let entry = manager.entries.first(where: { $0.connectionID == connection.id && $0.database == otherDB }),
              let sibling = entry.service else {
            throw ShowcaseError("no window registered for \(otherDB)")
        }
        let siblingWindow = entry.window
        try expect(siblingWindow !== window, "the sibling is its own window")
        ShowcaseRenderer.guardOffscreen(siblingWindow)
        siblingWindow.setContentSize(ShowcaseRunner.windowSize)
        siblingWindow.appearance = appearance.ns
        ShowcaseRenderer.orderInOffscreen(siblingWindow)
        try await ShowcaseRunner.wait("sibling connection", timeout: 20) { sibling.schemaState == .loaded }
        try expect(sibling.schema.schemas.flatMap(\.tables).contains { $0.name == "sibling_only" },
                   "the sibling window shows \(otherDB)'s tables")
        try expectEqual(Set(manager.openDatabases(for: connection.id)), [connection.database, otherDB],
                        "two windows keyed (connection, database)")
        delegate.openConnection(connection, database: otherDB)
        try expectEqual(manager.entries.count, before + 1, "reopening the sibling database focuses it instead of duplicating")

        if let node = sibling.schema.schemas.flatMap(\.tables).first(where: { $0.name == "sibling_only" }) {
            sibling.workspace.openTable(node)
            if let tab = sibling.workspace.selectedTab {
                try await settleAfterLoad(sibling.loader(for: tab, table: node), "sibling rows")
            }
        }
        await ShowcaseRenderer.settle(siblingWindow, turns: 8)
        try await capture("smoke-switcher-sibling", base: siblingWindow)

        siblingWindow.close()
        try expectEqual(manager.entries.count, before, "closing the sibling unregisters it")
        try expect(sibling.client == nil, "closing the sibling shut its pool down")

        closeAllTabs()
        let (_, loader) = try await openLoaded(try table("smoke", "items"), orderBy: "id")
        await loader.load()
        try await settleAfterLoad(loader, "main window after closing the sibling")
        try expect(loader.refreshError == nil, "the first window still works")
    }

    // MARK: - g. Reconnect

    private func smokeReconnect() async throws {
        closeAllTabs()
        let (_, loader) = try await openLoaded(try table("smoke", "items"), orderBy: "id")
        let idle = service.workspace.openScratchpad()
        try success(try await run("SELECT 1", in: idle), "idle scratchpad warm-up")
        let busy = service.workspace.openScratchpad()
        try success(try await run("BEGIN; UPDATE smoke.items SET note = 'lost txn' WHERE id = 10", in: busy), "open transaction")
        try expect(busy.transaction.isOpen, "second scratchpad is in a transaction")

        let db = ShowcaseEnvironment.databaseName
        let killed = try psql("""
            SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
            WHERE application_name LIKE 'pgBrain%' AND datname = '\(db)'
            """).first?.first ?? "0"
        try expect((Int(killed) ?? 0) >= 3, "terminated \(killed) pgBrain backends (pool + 2 sessions)")
        try await Task.sleep(for: .milliseconds(500))

        // The pool: the next grid load must succeed within a bounded time.
        let started = Date()
        var lastError: String?
        var recovered = false
        while Date().timeIntervalSince(started) < 30 {
            await loader.load()
            try await settleAfterLoad(loader, "reload after backend loss")
            if loader.refreshError == nil { recovered = true; break }
            lastError = loader.refreshError
            ShowcaseLog.write("  … reload failed: \(lastError ?? "")")
            await service.checkHealth()
            try await Task.sleep(for: .seconds(1))
        }
        try expect(recovered, "the grid reloads after the pool's backends were killed (last error: \(lastError ?? "none"), \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        try expect(lastError == nil, "the very first reload after the loss succeeded (\(lastError ?? ""))")
        await service.checkHealth()
        try await ShowcaseRunner.wait("health", timeout: 30) { self.service.health == .healthy }
        try expectEqual(service.health, .healthy, "health is back to healthy")

        // Idle scratchpad: transparent reconnect with a notice.
        let q = try success(try await run("SELECT 2", in: idle), "idle scratchpad after loss")
        try expectEqual(q.page.rows.first?.first ?? nil, "2", "the idle scratchpad reconnected transparently")
        try expect(idle.sessionNotice?.contains("Reconnected") == true, "…and says so (\(idle.sessionNotice ?? "nil"))")

        // Scratchpad in a transaction: refused, clearly.
        let lost = try await run("SELECT 3", in: busy)
        guard case .failure(let message) = lost.last?.status else {
            throw ShowcaseError("a statement after losing an open transaction ran: \(String(describing: lost.last?.status))")
        }
        try expect(message.lowercased().contains("transaction"), "losing the transaction is reported: \(message)")
        try expect(!busy.transaction.isOpen, "the indicator no longer shows a transaction")
        try expectEqual(try await dbValue("SELECT coalesce(note, '') FROM smoke.items WHERE id = 10"), "",
                        "the lost transaction's UPDATE was not committed")
        try success(try await run("SELECT 4", in: busy), "the busy scratchpad works again afterwards")
        await ShowcaseRenderer.settle(window, turns: 6)
        try await capture("smoke-reconnect")
    }
}
#endif
