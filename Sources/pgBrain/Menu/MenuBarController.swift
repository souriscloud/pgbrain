import AppKit

@MainActor
protocol MenuBarDelegate: AnyObject {
    func bringAnyWindowToFront()
    func showWelcome(focus: Bool)
    func showAbout()
    var windowManager: WindowManager { get }
}

extension AppDelegate: MenuBarDelegate {}

@MainActor
final class MenuBarController: NSObject {
    private weak var delegate: MenuBarDelegate?
    private var statusItem: NSStatusItem?

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
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let welcome = NSMenuItem(title: "Show Welcome…", action: #selector(onShowWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        let bring = NSMenuItem(title: "Bring pgBrain to Front", action: #selector(onBringToFront), keyEquivalent: "")
        bring.target = self
        menu.addItem(bring)

        menu.addItem(.separator())

        // Placeholder: in iter-2 we will dynamically list open connection windows here.
        let windowsHeader = NSMenuItem(title: "Open Windows", action: nil, keyEquivalent: "")
        windowsHeader.isEnabled = false
        menu.addItem(windowsHeader)

        let none = NSMenuItem(title: "  — none —", action: nil, keyEquivalent: "")
        none.isEnabled = false
        menu.addItem(none)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About pgBrain", action: #selector(onAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let checkUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(onCheckUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit pgBrain", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
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

    @objc private func onCheckUpdates() {
        // Stub — wired up to Sparkle in a later iteration.
        let alert = NSAlert()
        alert.messageText = "Updates coming soon"
        alert.informativeText = "Sparkle auto-update is wired up in a later iteration."
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }
}
