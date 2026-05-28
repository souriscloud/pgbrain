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
        }
    }
}
