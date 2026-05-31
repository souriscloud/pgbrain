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
}
