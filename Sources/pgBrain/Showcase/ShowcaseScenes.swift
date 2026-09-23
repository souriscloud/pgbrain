#if DEBUG
import AppKit
import SwiftUI

/// The marketing scenes. Each one puts the app into a state through its
/// model objects (workspace, loaders, notebooks) — never through synthetic
/// input — waits for the async work to land, and renders them in the run's
/// appearance. Light and dark are separate runs: flipping a live window's
/// appearance leaves stale layer contents behind in an off-screen render.
@MainActor
final class ShowcaseScenes {
    enum Appearance: String, CaseIterable {
        case light, dark
        var ns: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
    }

    /// Where a panel composited over the window sits: a sheet hangs under
    /// the title bar, the palette floats in the upper middle.
    enum Placement { case sheet, palette }

    let delegate: AppDelegate
    let outputDirectory: URL
    let appearance: Appearance = ProcessInfo.processInfo.environment["PGBRAIN_SHOWCASE_APPEARANCE"]
        .flatMap(Appearance.init(rawValue:)) ?? .light
    private let only: Set<String>
    private var window: NSWindow!
    private var service: ConnectionService!
    /// Sheet / palette host windows, kept alive until the run ends.
    private var scratchWindows: [NSWindow] = []
    private var failures: [String] = []

    init(delegate: AppDelegate, outputDirectory: URL) {
        self.delegate = delegate
        self.outputDirectory = outputDirectory
        let filter = ProcessInfo.processInfo.environment["PGBRAIN_SHOWCASE_ONLY"] ?? ""
        only = Set(filter.split(separator: ",").map(String.init))
    }

    private let connection = Connection(
        name: "Driftwood", host: "localhost", port: 5432,
        database: ShowcaseEnvironment.databaseName, username: NSUserName(),
        sslMode: .disable, colorTag: .purple)

    // MARK: - Driver

    func runAll() async throws {
        ShowcaseHooks.forceActiveAppearance()
        NSApp.appearance = appearance.ns
        seedNavigation()
        try await openWindow()

        let scenes: [(String, () async throws -> Void)] = [
            ("01-hero", hero),
            ("04-preview-sql", previewSQL),
            ("03-go-to-table", goToTable),
            ("02-scratchpad", scratchpad),
            ("07-explain", explain),
            ("05-erd", erd),
            ("06-map", map),
            ("08-structure", structure),
            ("10-activity", activity),
            ("09-connection-editor", connectionEditor),
        ]
        for (name, scene) in scenes where only.isEmpty || only.contains(name) {
            ShowcaseLog.write("scene \(name)")
            do {
                try await scene()
            } catch {
                ShowcaseLog.write("scene \(name) failed: \(error)")
                failures.append(name)
            }
        }
        if !failures.isEmpty {
            throw ShowcaseError("scenes failed: \(failures.joined(separator: ", "))")
        }
    }

    private var scope: NavigationHistoryStore.Scope {
        NavigationHistoryStore.Scope(connectionID: connection.id, database: connection.database)
    }

    private func seedNavigation() {
        let store = NavigationHistoryStore.shared
        for id in ["public.customers", "public.products"] {
            store.setPinned(true, tableID: id, scope: scope)
        }
        for id in ["analytics.events", "billing.invoices", "public.order_items"] {
            store.recordOpen(id, scope: scope)
        }
    }

    private func openWindow() async throws {
        let result = ConnectionWindowFactory.make(connection: connection) { _ in }
        window = result.window
        service = result.service
        delegate.windowManager.register(window: window, service: service)
        window.setContentSize(ShowcaseRunner.windowSize)
        window.appearance = appearance.ns
        ShowcaseRenderer.orderInOffscreen(window)
        try await ShowcaseRunner.wait("connection") {
            if case .connected = self.service.state { return true }
            if case .error(let message) = self.service.state {
                ShowcaseLog.write("connect error: \(message)")
            }
            return false
        }
        try await ShowcaseRunner.wait("schema") { self.service.schemaState == .loaded }
        try await ShowcaseRunner.wait("column enrichment") {
            (try? self.table("public", "orders").columns.isEmpty == false) ?? false
        }
        try await ShowcaseRunner.wait("server info") { self.service.serverInfo != nil }
        ShowcaseLog.write("connected, \(service.tableCount) relations")
    }

    private func table(_ schema: String, _ name: String) throws -> TableNode {
        guard let t = service.schema.schemas.first(where: { $0.name == schema })?
            .tables.first(where: { $0.name == name }) else {
            throw ShowcaseError("\(schema).\(name) is not in the schema snapshot")
        }
        return t
    }

    private func closeAllTabs() {
        for tab in service.workspace.tabs {
            if let node = tab.tableNode { service.loader(for: tab, table: node).revert() }
        }
        service.workspace.closeTabs(service.workspace.tabs.map(\.id))
    }

    /// Open `table` as a kept tab and wait until its first page is on screen.
    @discardableResult
    private func openLoaded(_ node: TableNode, orderBy: String = "",
                            where filter: String = "") async throws -> (WorkspaceState.Tab, RowsLoader) {
        service.workspace.openTable(node)
        guard let tab = service.workspace.selectedTab else { throw ShowcaseError("no tab for \(node.id)") }
        tab.tableOrderByClause = orderBy
        tab.tableWhereClause = filter
        let loader = service.loader(for: tab, table: node)
        try await ShowcaseRunner.wait("rows of \(node.id)") {
            if case .loaded = loader.state { return true }
            return false
        }
        try await ShowcaseRunner.wait("size of \(node.id)", timeout: 5) { loader.tableSizePretty != nil }
        await ShowcaseRenderer.settle(window)
        return (tab, loader)
    }

    // MARK: - Scenes

    private var heroLoader: RowsLoader?

    private func hero() async throws {
        closeAllTabs()
        let customers = try table("public", "customers")
        let orders = try table("public", "orders")
        try await openLoaded(customers)
        try await openLoaded(try table("billing", "invoices"))
        let (_, loader) = try await openLoaded(orders, orderBy: "placed_at DESC",
                                                where: "status <> 'cancelled'")
        heroLoader = loader

        guard let grid = findView(EditableTableView.self, in: window.contentView),
              let coordinator = grid.delegate as? DataGridView.Coordinator else {
            throw ShowcaseError("orders grid not found")
        }
        tidyColumns(grid)

        loader.editBuffer.set(row: 1, column: column(named: "status", in: loader), value: "shipped")
        loader.editBuffer.set(row: 3, column: column(named: "shipping", in: loader), value: "0.00")
        loader.editBuffer.set(row: 3, column: column(named: "status", in: loader), value: "cancelled")
        await ShowcaseRenderer.settle(window)

        let firstCol = coordinator.displayCol(forTableColumn: grid.column(withIdentifier: identifier(of: "subtotal", in: grid)))
        let lastCol = coordinator.displayCol(forTableColumn: grid.column(withIdentifier: identifier(of: "total", in: grid)))
        if let firstCol, let lastCol {
            coordinator.changeSelection(scroll: false) { sel in
                sel.select(GridSelection.Cell(row: 6, col: firstCol))
                sel.extend(to: GridSelection.Cell(row: 10, col: lastCol))
            }
        }
        window.makeFirstResponder(grid)
        try await capture("01-hero")
    }

    private func previewSQL() async throws {
        guard let loader = heroLoader, loader.hasPendingChanges else {
            throw ShowcaseError("preview needs the hero scene's staged edits")
        }
        let script = loader.previewSQL()
        let s = loader.pendingSummary
        let summary = "\(s.cells) edited cells"
        let sheet = PendingChangesPreviewSheet(script: script, summary: summary, onApply: {}, onClose: {})
            .frame(width: 760, height: 480)
        try await capture("04-preview-sql", overlay: { self.hostWindow(sheet) }, placement: .sheet)
    }

    private func goToTable() async throws {
        let model = CommandPaletteModel(items: CommandProviders.goToItems(service: service),
                                        placeholder: "Go to table, view, or function…  (schema.name works)")
        model.query = "pub.ord"
        let view = CommandPaletteView(model: model, onExecute: { _ in }, onDismiss: {})
            .frame(width: 720, height: 540)
        try await capture("03-go-to-table", overlay: { self.hostWindow(view, transparent: true) },
                              placement: .palette, dim: 0.18, cornerRadius: 0)
    }

    private var scratchpadNotebook: Notebook?

    private func scratchpad() async throws {
        closeAllTabs()
        let pad = service.workspace.openScratchpad()
        service.workspace.selectedTab?.title = "Q3 review"
        pad.title = "Q3 review"
        scratchpadNotebook = pad
        let statements = [
            """
            BEGIN;
            UPDATE products SET price = round(price * 0.85, 2)
            WHERE 'sale' = ANY (tags) AND status = 'active';
            """,
            """
            -- Top customers this year
            SELECT c.first_name || ' ' || c.last_name AS customer, c.tags,
                   count(*) AS orders, sum(o.total)::money AS revenue,
                   date_trunc('minute', now() - max(o.placed_at)) AS since_last_order,
                   c.preferences, c.last_login_ip
            FROM customers c JOIN orders o ON o.customer_id = c.id
            WHERE o.placed_at >= '2026-01-01'
            GROUP BY c.id ORDER BY sum(o.total) DESC LIMIT 6;
            """,
            """
            -- Daily revenue, last two weeks
            SELECT to_char(day, 'Mon DD') AS day, revenue
            FROM analytics.daily_revenue WHERE day >= date '2026-09-07' ORDER BY day;
            """,
        ]
        ShowcaseHooks.resultModes["Daily revenue"] = "chart"

        guard let first = pad.cells.first(where: { $0.kind == .sql }) else { throw ShowcaseError("empty notebook") }
        first.text = statements[0]
        var cells = [first]
        for text in statements.dropFirst() {
            let cell = NotebookCell(kind: .sql, text: text)
            pad.insert(cell, after: pad.cells.last!.id)
            cells.append(cell)
        }
        await ShowcaseRenderer.settle(window)
        for cell in cells {
            NotebookRunner.run(cell: cell, selection: nil, notebook: pad, service: service)
            try await ShowcaseRunner.wait("scratchpad run") { !pad.isRunning }
            for result in pad.cells.compactMap({ c -> NotebookResult? in
                if case .result(let id) = c.kind { return pad.result(id: id) } else { return nil }
            }) {
                if case .failure(let message) = result.status {
                    throw ShowcaseError("scratchpad statement failed: \(message)")
                }
            }
        }
        try await ShowcaseRunner.wait("transaction indicator") { pad.transaction.isOpen }
        for cell in pad.cells {
            if case .result(let id) = cell.kind, let result = pad.result(id: id),
               result.statement.hasPrefix("BEGIN") || result.statement.hasPrefix("UPDATE") {
                result.isCollapsed = true
            }
        }
        findView(NSOutlineView.self, in: window.contentView)?.deselectAll(nil)
        await ShowcaseRenderer.settle(window, turns: 6)
        scrollToBottom(in: window)
        await ShowcaseRenderer.settle(window, turns: 8)
        try await capture("02-scratchpad")
    }

    private func explain() async throws {
        guard let pad = scratchpadNotebook else { throw ShowcaseError("explain needs the scratchpad scene") }
        let sql = """
        SELECT c.country, count(*) AS orders, sum(o.total) AS revenue
        FROM orders o
        JOIN customers c ON c.id = o.customer_id
        WHERE o.placed_at >= '2026-08-01' AND o.status IN ('paid', 'packed', 'shipped')
        GROUP BY c.country
        ORDER BY revenue DESC
        """
        let service = self.service!
        let view = ExplainPlanView(
            initialSQL: sql,
            runExplain: { analyze in
                await NotebookRunner.explain(sql: sql, analyze: analyze, notebook: pad, service: service)
            },
            onClose: {})
        try await capture("07-explain", overlay: { self.hostWindow(view) }, placement: .sheet, settleTurns: 20)
    }

    private func erd() async throws {
        closeAllTabs()
        try await openLoaded(try table("public", "order_items"))
        guard var schema = service.visibleSchema.schemas.first(where: { $0.name == "public" }) else {
            throw ShowcaseError("public schema missing")
        }
        // The ERD sheet doesn't yet drop partitions and extension-owned
        // relations the way the sidebar does (see the report); show the
        // diagram the way the sidebar presents the schema.
        schema.tables.removeAll { $0.partitionOf != nil || $0.isExtensionOwned }
        let view = ERDView(schema: schema, onOpenTable: { _ in }, onClose: {})
        try await capture("05-erd", overlay: { self.hostWindow(view) }, placement: .sheet)
    }

    private func map() async throws {
        guard service.hasPostGIS, let stores = try? table("public", "stores") else {
            ShowcaseLog.write("PostGIS not available — skipping the map scene")
            return
        }
        closeAllTabs()
        let (tab, _) = try await openLoaded(stores)
        tab.tableViewState.rowViewMode = .map
        // Map tiles stream in over the network; give them time to land.
        await ShowcaseRenderer.settle(window, turns: 60)
        try await capture("06-map", settleTurns: 30)
    }

    private func structure() async throws {
        closeAllTabs()
        let products = try table("public", "products")
        try await openLoaded(try table("public", "orders"))
        let (tab, _) = try await openLoaded(products)
        tab.tableViewState.pane = .structure
        let inspector = service.inspector(for: tab, table: products)
        await ShowcaseRenderer.settle(window)
        try await ShowcaseRunner.wait("structure") {
            if case .loaded = inspector.state { return true }
            return false
        }
        try await capture("08-structure")
    }

    private func activity() async throws {
        closeAllTabs()
        try await openLoaded(try table("analytics", "events"), orderBy: "occurred_at DESC")
        let view = ActivityPanelView(service: service, onClose: {})
        try await capture("10-activity", overlay: { self.hostWindow(view) }, placement: .sheet, settleTurns: 40)
    }

    private func connectionEditor() async throws {
        let store = ConnectionStore.shared
        let prod = Connection(
            name: "Driftwood production", host: "db.example.com", port: 5432,
            database: "driftwood", username: "analyst", sslMode: .verifyFull, colorTag: .red,
            sshEnabled: true, sshHost: "bastion.example.com", sshUser: "deploy",
            sshKeyPath: "~/.ssh/id_ed25519", isProduction: true,
            sslRootCertPath: "~/certs/driftwood-root-ca.pem",
            statementTimeoutSeconds: 30, idleInTransactionTimeoutSeconds: 300, readOnly: true)
        for c in [
            prod,
            Connection(name: "Driftwood staging", host: "staging-db.example.com", database: "driftwood",
                       username: "app", sslMode: .require, colorTag: .orange),
            Connection(name: "Analytics warehouse", host: "warehouse.example.com", port: 6432,
                       database: "events", username: "reporting", sslMode: .verifyCA, colorTag: .teal),
            connection,
        ] {
            store.upsert(c)
        }
        let welcome = WelcomeWindowFactory.make {}
        welcome.setContentSize(CGSize(width: 1080, height: 800))
        ShowcaseRenderer.orderInOffscreen(welcome)
        let editor = ConnectionEditorView(connection: prod, initialPassword: "not-a-real-password",
                                          onSave: { _, _ in }, onCancel: {})
        // Scrolled to the lower half: SSL files, production, read-only,
        // timeouts and the SSH tunnel are what set this editor apart.
        let sheet = hostWindow(editor)
        await ShowcaseRenderer.settle(sheet, turns: 6)
        scrollToBottom(in: sheet)
        try await capture("09-connection-editor", base: welcome, overlay: { sheet }, placement: .sheet)
    }

    /// Scroll the tallest SwiftUI scroll view in `window` to its end.
    private func scrollToBottom(in window: NSWindow) {
        var clips: [NSClipView] = []
        func collect(_ v: NSView) {
            if let clip = v as? NSClipView,
               let scroll = v.superview, String(describing: type(of: scroll)).contains("HostingScrollView") {
                clips.append(clip)
            }
            v.subviews.forEach(collect)
        }
        if let root = window.contentView { collect(root) }
        guard let clip = clips.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = clip.documentView, doc.frame.height > clip.bounds.height else { return }
        let y = doc.isFlipped ? doc.frame.height - clip.bounds.height : 0
        clip.scroll(to: NSPoint(x: 0, y: y))
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
    }

    // MARK: - Grid helpers

    private func column(named name: String, in loader: RowsLoader) -> Int {
        guard case .loaded(let page) = loader.state,
              let idx = page.columns.firstIndex(where: { $0.name == name }) else { return 0 }
        return idx
    }

    private func identifier(of name: String, in grid: NSTableView) -> NSUserInterfaceItemIdentifier {
        grid.tableColumns.first { $0.identifier.rawValue.hasSuffix("_\(name)") }?.identifier
            ?? NSUserInterfaceItemIdentifier("")
    }

    /// Auto-sized columns are generous; trim the wide ones so the hero shows
    /// the whole order at a glance.
    private func tidyColumns(_ grid: NSTableView) {
        let widths: [String: CGFloat] = [
            "id": 64, "order_number": 104, "customer_id": 96, "status": 96, "placed_at": 196,
            "items": 56, "subtotal": 96, "shipping": 80, "total": 96, "currency": 72,
            "channel": 76, "ship_to_country": 118,
        ]
        for column in grid.tableColumns {
            let raw = column.identifier.rawValue
            guard let underscore = raw.firstIndex(of: "_") else { continue }
            let name = String(raw[raw.index(after: underscore)...])
            if let w = widths[name] { column.width = w }
            // End the grid on a whole column instead of a clipped one.
            if name == "client_ip" || name == "gift_note" { column.isHidden = true }
        }
        grid.sizeLastColumnToFit()
    }

    private func findView<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let hit = root as? T { return hit }
        for sub in root.subviews {
            if let hit = findView(type, in: sub) { return hit }
        }
        return nil
    }

    // MARK: - Capture

    /// A borderless off-screen window hosting a sheet / panel view at its
    /// fitting size, with the window background a real sheet would have.
    private func hostWindow<V: View>(_ view: V, transparent: Bool = false) -> NSWindow {
        let root = view.background(transparent ? Color.clear : Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.backgroundColor = transparent ? .clear : .windowBackgroundColor
        w.isOpaque = !transparent
        w.contentView = hosting
        ShowcaseRenderer.orderInOffscreen(w)
        scratchWindows.append(w)
        return w
    }

    private func capture(_ name: String, base: NSWindow? = nil,
                             overlay makeOverlay: (() -> NSWindow)? = nil,
                             placement: Placement = .sheet, dim: CGFloat = 0.12,
                             cornerRadius: CGFloat = 16, settleTurns: Int = 8) async throws {
        let baseWindow = base ?? window!
        let overlayWindow = makeOverlay?()
        do {
            baseWindow.appearance = appearance.ns
            overlayWindow?.appearance = appearance.ns
            await ShowcaseRenderer.settle(baseWindow, turns: settleTurns)
            if let overlayWindow { await ShowcaseRenderer.settle(overlayWindow, turns: settleTurns) }
            guard let frameView = baseWindow.contentView?.superview,
                  var image = ShowcaseRenderer.image(of: frameView) else {
                throw ShowcaseError("render failed for \(name)")
            }
            image = await ShowcaseMaps.patch(image, root: frameView, appearance: appearance.ns)
            var blank: Error?
            if baseWindow === window {
                let size = baseWindow.frame.size
                do {
                    try ShowcaseRenderer.assertNotBlank(image, pointSize: size, probes: [
                    ("chrome bar", CGRect(x: 80, y: 4, width: 700, height: 40)),
                    ("sidebar", CGRect(x: 8, y: 110, width: 240, height: 360)),
                    ("content", CGRect(x: 300, y: 200, width: 1200, height: 600)),
                    ("status footer", CGRect(x: 4, y: size.height - 22, width: 500, height: 18)),
                    ])
                } catch {
                    blank = error
                }
            }
            if let overlayWindow {
                guard let content = overlayWindow.contentView,
                      let overlayImage = ShowcaseRenderer.image(of: content) else {
                    throw ShowcaseError("overlay render failed for \(name)")
                }
                let base = baseWindow.frame.size
                let size = content.bounds.size
                let x = ((base.width - size.width) / 2).rounded()
                let top: CGFloat = placement == .sheet ? 58 : ((base.height - size.height) / 2 - 60).rounded()
                let y = base.height - top - size.height
                guard let composed = ShowcaseRenderer.composite(
                    base: image, dim: dim,
                    overlays: [(overlayImage, CGPoint(x: x, y: y))],
                    baseSizePoints: base, dark: appearance == .dark,
                    cornerRadius: cornerRadius) else {
                    throw ShowcaseError("compositing failed for \(name)")
                }
                image = composed
            }
            let url = outputDirectory.appendingPathComponent("\(name)-\(appearance.rawValue).png")
            try ShowcaseRenderer.writePNG(image, to: url)
            ShowcaseLog.write("wrote \(url.lastPathComponent) \(image.width)x\(image.height)")
            // Written first so a failing guard still leaves the image to look at.
            if let blank { throw blank }
        }
    }
}
#endif
