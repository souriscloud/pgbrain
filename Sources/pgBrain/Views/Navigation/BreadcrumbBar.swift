import AppKit
import SwiftUI

/// Jump bar above the active tab: back/forward, then
/// `database ▸ schema ▾ ▸ table ▾` where each segment pops a menu of its
/// siblings for lateral hops. Scratchpads show `database ▸ name`.
struct BreadcrumbBar: View {
    let service: ConnectionService
    @Bindable var workspace: WorkspaceState
    let databases: [String]
    let onGoToTable: () -> Void

    static let menuItemLimit = 400

    var body: some View {
        HStack(spacing: 4) {
            navButton("chevron.left", enabled: workspace.canGoBack, help: "Back (⌘[)") { workspace.goBack() }
            navButton("chevron.right", enabled: workspace.canGoForward, help: "Forward (⌘])") { workspace.goForward() }
            Divider().frame(height: 14).padding(.horizontal, 2)
            segment(databaseName, icon: "cylinder.split.1x2", menu: databaseMenu)
            if let tab = workspace.selectedTab {
                switch tab.kind {
                case .table(let t):
                    chevron
                    segment(t.schema, icon: "folder", menu: { schemaMenu(current: t.schema) })
                    chevron
                    segment(t.name, icon: t.symbolName, menu: { siblingMenu(of: t) }, emphasized: true)
                    if tab.isStale {
                        Label("no longer exists", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                case .scratchpad(let pad):
                    chevron
                    Label(workspace.displayTitle(for: tab), systemImage: "doc.text")
                        .font(.system(size: 11, weight: .medium))
                    if let sp = pad.searchPath, !sp.isEmpty {
                        Text("search_path: \(sp)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var databaseName: String {
        let name = service.schema.databaseName
        if !name.isEmpty { return name }
        return service.connection.database.isEmpty ? "database" : service.connection.database
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
    }

    private func segment(_ title: String, icon: String, menu: @escaping () -> NSMenu,
                         emphasized: Bool = false) -> some View {
        Button {
            menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: emphasized ? .semibold : .regular))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Menus

    private func databaseMenu() -> NSMenu {
        let menu = NSMenu()
        let current = databaseName
        for db in databases {
            let item = ClosureMenuItem(title: db) { [service] in
                guard db != current else { return }
                AppDelegate.shared?.openConnection(service.connection, database: db)
            }
            item.state = db == current ? .on : .off
            menu.addItem(item)
        }
        if databases.isEmpty {
            let none = NSMenuItem(title: "No other databases listed", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    private func schemaMenu(current: String) -> NSMenu {
        let menu = NSMenu()
        for schema in service.visibleSchema.schemas {
            let item = NSMenuItem(title: schema.name, action: nil, keyEquivalent: "")
            item.state = schema.name == current ? .on : .off
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let tables = schema.tables
            let sub = LazyMenu { [workspace] sub in
                Self.fillTables(sub, tables: tables, workspace: workspace, onMore: onGoToTable)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        return menu
    }

    private func siblingMenu(of table: TableNode) -> NSMenu {
        let menu = NSMenu()
        let tables = service.schema.schemas.first(where: { $0.name == table.schema })?.tables ?? []
        Self.fillTables(menu, tables: tables, workspace: workspace, current: table.id, onMore: onGoToTable)
        return menu
    }

    private static func fillTables(_ menu: NSMenu, tables: [TableNode], workspace: WorkspaceState,
                                   current: String? = nil, onMore: @escaping () -> Void) {
        if tables.isEmpty {
            let none = NSMenuItem(title: "(no tables)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for t in tables.prefix(menuItemLimit) {
            let item = ClosureMenuItem(title: t.name) { workspace.navigate(toTable: t) }
            item.image = NSImage(systemSymbolName: t.symbolName, accessibilityDescription: t.kindLabel)
            item.state = t.id == current ? .on : .off
            menu.addItem(item)
        }
        if tables.count > menuItemLimit {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "\(tables.count - menuItemLimit) more — Go to Table… (⌘O)", action: onMore))
        }
    }
}

/// NSMenu that fills itself only when opened, so a schema list with
/// thousands of tables per schema costs nothing until the user hovers in.
final class LazyMenu: NSMenu, NSMenuDelegate {
    private let builder: (NSMenu) -> Void
    private var built = false

    init(builder: @escaping (NSMenu) -> Void) {
        self.builder = builder
        super.init(title: "")
        self.delegate = self
        // A placeholder keeps the parent item showing its submenu arrow.
        addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !built else { return }
        built = true
        removeAllItems()
        builder(self)
    }
}
