import AppKit

@MainActor
protocol MenuBarDelegate: AnyObject {
    func bringAnyWindowToFront()
    func showWelcome(focus: Bool)
    func showAbout()
    func showFeedback()
    var windowManager: WindowManager { get }
}

extension AppDelegate: MenuBarDelegate {}

@MainActor
final class MenuBarController: NSObject {
    private weak var delegate: MenuBarDelegate?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    init(delegate: MenuBarDelegate) {
        self.delegate = delegate
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // SF Symbol "cylinder.split.1x2" reads as a stylized DB icon and tints with the system.
            let image = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: "pgBrain")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "pgBrain"
        }
        let m = buildMenu()
        m.delegate = self
        item.menu = m
        menu = m
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let welcome = NSMenuItem(title: "Show Welcome…", action: #selector(onShowWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        let bring = NSMenuItem(title: "Bring pgBrain to Front", action: #selector(onBringToFront), keyEquivalent: "")
        bring.target = self
        menu.addItem(bring)

        menu.addItem(.separator())

        let windowsHeader = NSMenuItem(title: "Open Windows", action: nil, keyEquivalent: "")
        windowsHeader.isEnabled = false
        windowsHeader.tag = MenuTag.windowsHeader.rawValue
        menu.addItem(windowsHeader)

        // Placeholder; replaced by `refreshOpenWindows()` on each menu open.
        let none = NSMenuItem(title: "  — none —", action: nil, keyEquivalent: "")
        none.isEnabled = false
        none.tag = MenuTag.windowsPlaceholder.rawValue
        menu.addItem(none)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About pgBrain", action: #selector(onAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let feedback = NSMenuItem(title: "Send Feedback…", action: #selector(onFeedback), keyEquivalent: "")
        feedback.target = self
        menu.addItem(feedback)

        let checkUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(onCheckUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit pgBrain", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private enum MenuTag: Int {
        case windowsHeader = 100
        case windowsPlaceholder = 101
        case windowEntry = 102
    }

    /// Rebuilds the dynamic window-list block between the "Open Windows" header
    /// and the next separator. Called on menu open via `NSMenuDelegate`.
    private func refreshOpenWindows() {
        guard let menu else { return }
        // Drop all current entries (placeholder + any previously added rows).
        menu.items.removeAll { $0.tag == MenuTag.windowsPlaceholder.rawValue || $0.tag == MenuTag.windowEntry.rawValue }

        guard let headerIdx = menu.items.firstIndex(where: { $0.tag == MenuTag.windowsHeader.rawValue }) else { return }
        let entries = delegate?.windowManager.connectionWindows ?? []
        var insertAt = headerIdx + 1

        if entries.isEmpty {
            let none = NSMenuItem(title: "  — none —", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.tag = MenuTag.windowsPlaceholder.rawValue
            menu.insertItem(none, at: insertAt)
            return
        }

        for entry in entries {
            let connection = ConnectionStore.shared.connections.first(where: { $0.id == entry.connectionID })
            let appearance = connection.map(ConnectionAppearance.init)
            let title = "  " + entry.window.title + (appearance?.suffix ?? "")
            let item = NSMenuItem(title: title, action: #selector(onWindowEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = MenuTag.windowEntry.rawValue
            item.representedObject = entry.window
            // SF Symbol coloured dot lines up the colour tag with the row.
            if let appearance, appearance.connection.colorTag != .none {
                let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(appearance.accent)])
                item.image = dot?.withSymbolConfiguration(config)
            }
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
    }

    @objc private func onWindowEntry(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func onShowWelcome() {
        delegate?.showWelcome(focus: true)
    }

    @objc private func onBringToFront() {
        delegate?.bringAnyWindowToFront()
    }

    @objc private func onAbout() {
        delegate?.showAbout()
    }

    @objc private func onFeedback() {
        delegate?.showFeedback()
    }

    @objc private func onCheckUpdates() {
        UpdateController.shared.checkForUpdates(self)
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshOpenWindows()
    }
}
