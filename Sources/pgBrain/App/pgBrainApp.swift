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
        }
    }
}
