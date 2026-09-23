import SwiftUI

@main
struct pgBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About pgBrain") {
                    AppDelegate.shared?.showAbout()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    AppDelegate.shared?.showWelcome(focus: true)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    CommandPaletteWindow.shared.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
            // Window-scoped navigation. Routed to the key connection window's
            // workspace; no-ops when the key window isn't a connection.
            CommandMenu("Navigate") {
                Button("Go to Table…") {
                    CommandPaletteWindow.shared.toggle(mode: .goToTable)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Go to Anything…") {
                    CommandPaletteWindow.shared.toggle(mode: .everything)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Back") {
                    AppDelegate.shared?.windowManager.keyService?.workspace.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                Button("Forward") {
                    AppDelegate.shared?.windowManager.keyService?.workspace.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                Divider()
                Button("Filter Sidebar") { sidebarCommand("focusFilter") }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Reveal Active Tab in Sidebar") { sidebarCommand("reveal") }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Pin Active Table to Sidebar") {
                    guard let service = AppDelegate.shared?.windowManager.keyService,
                          let table = service.workspace.selectedTab?.tableNode else { return }
                    NavigationHistoryStore.shared.togglePinned(table.id, scope: service.navigationScope)
                }
                .keyboardShortcut("d", modifiers: [.command])
                Button("Keep Preview Tab Open") {
                    guard let workspace = AppDelegate.shared?.windowManager.keyService?.workspace,
                          let id = workspace.selectedID else { return }
                    workspace.keepTab(id: id)
                }
            }
            // View → editor zoom. Lives live across every open scratchpad.
            CommandGroup(after: .sidebar) {
                Button("Increase Font Size") {
                    AppSettings.shared.bumpFontSize(by: 1)
                }
                .keyboardShortcut("+", modifiers: [.command])
                Button("Decrease Font Size") {
                    AppSettings.shared.bumpFontSize(by: -1)
                }
                .keyboardShortcut("-", modifiers: [.command])
                Button("Reset Font Size") {
                    AppSettings.shared.editorFontSize = 12
                }
                .keyboardShortcut("0", modifiers: [.command])
                Divider()
            }
            // Replace the stock Help menu so "pgBrain Help" opens our in-app
            // guide and Send Feedback is one click from the top-level menu.
            CommandGroup(replacing: .help) {
                Button("pgBrain Help") {
                    AppDelegate.shared?.showHelp()
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                Button("Send Feedback…") {
                    AppDelegate.shared?.showFeedback()
                }
            }
        }
    }

    @MainActor
    private func sidebarCommand(_ command: String) {
        guard let workspace = AppDelegate.shared?.windowManager.keyService?.workspace else { return }
        NotificationCenter.default.post(name: .pgbrainSidebarCommand, object: workspace.windowID,
                                        userInfo: ["command": command])
    }
}
