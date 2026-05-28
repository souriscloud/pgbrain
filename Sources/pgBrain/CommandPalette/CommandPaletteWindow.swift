import AppKit
import SwiftUI

/// Singleton floating palette. One panel, reused across opens, so
/// invoking ⌘K twice toggles instead of stacking windows. The panel
/// becomes key (so the search field can take typing) but doesn't
/// activate the app over other apps — it appears centered above the
/// current key window.
@MainActor
final class CommandPaletteWindow {
    static let shared = CommandPaletteWindow()

    private var panel: NSPanel?
    private var model: CommandPaletteModel?
    private var localKeyMonitor: Any?
    private var globalDismissMonitor: Any?

    /// Open above the frontmost connection window (if any). Closes the
    /// palette if it's already visible so ⌘K acts as a true toggle.
    func toggle() {
        if let panel, panel.isVisible {
            dismiss()
            return
        }
        present()
    }

    func present() {
        let service = frontmostService()
        let items = CommandProviders.items(service: service)
        let model = CommandPaletteModel(items: items)
        self.model = model

        let root = CommandPaletteView(
            model: model,
            onExecute: { [weak self] item in
                self?.execute(item)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(x: 0, y: 0, width: 720, height: 540)

        let panel = self.panel ?? makePanel()
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 720, height: 540))
        centerOverFrontmostWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        installKeyMonitor()

        // SwiftUI's @FocusState doesn't reliably engage on first
        // present when the host's NSTextField isn't yet in the window's
        // responder chain. Walk the view hierarchy, find the field,
        // and make it first responder explicitly — once SwiftUI's
        // layout pass has run.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            if let field = self.findFirstTextField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
        }
    }

    private func findFirstTextField(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSTextField || view is NSTextView {
            return view
        }
        for sub in view.subviews {
            if let found = findFirstTextField(in: sub) { return found }
        }
        return nil
    }

    func dismiss() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        // Drop the model so closures captured in CommandItems don't
        // keep services alive longer than the palette open lifetime.
        model = nil
    }

    // MARK: - Implementation

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // SwiftUI overlay draws its own
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func centerOverFrontmostWindow(_ panel: NSPanel) {
        let host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0 !== panel })
        let screenFrame = (host?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 720, height: 540)
        // Slightly above geometric center looks more natural than dead-center.
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.midY - size.height / 2 + 80
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    private func execute(_ item: CommandItem) {
        // Tear the panel down first so any action that focuses another
        // window doesn't fight the still-key palette.
        dismiss()
        // One runloop hop so the panel is fully off-screen before the
        // action — important for actions that open sheets attached to
        // the connection window.
        DispatchQueue.main.async {
            item.action()
        }
    }

    private func installKeyMonitor() {
        // Local monitor: arrow navigation + Enter + Esc inside the panel,
        // without forcing the SwiftUI TextField to give up first-responder
        // status (which is what makes onKeyPress unreliable when focused).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 53: // Escape
                self.dismiss()
                return nil
            case 125: // Down arrow
                self.model?.move(by: 1)
                return nil
            case 126: // Up arrow
                self.model?.move(by: -1)
                return nil
            case 36, 76: // Return / numpad Enter
                if let item = self.model?.selected() {
                    self.execute(item)
                }
                return nil
            case 40 where event.modifierFlags.contains(.command): // ⌘K toggle
                self.dismiss()
                return nil
            default:
                return event
            }
        }
        // Global monitor for clicks outside — dismiss like a popover.
        // (NSPanel with .transient already dismisses on app-switch, but
        // clicks inside our app on other windows wouldn't trigger that.)
        globalDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.window !== panel {
                self.dismiss()
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalDismissMonitor { NSEvent.removeMonitor(m); globalDismissMonitor = nil }
    }

    private func frontmostService() -> ConnectionService? {
        guard let delegate = AppDelegate.shared else { return nil }
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        if let key, let entry = delegate.windowManager.entries.first(where: { $0.window === key }) {
            return entry.service
        }
        // Fall back to the first registered service when the keyWindow
        // is the palette itself (subsequent ⌘K open in the same place).
        return delegate.windowManager.entries.first(where: { $0.service != nil })?.service
    }
}
