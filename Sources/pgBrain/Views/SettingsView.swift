import SwiftUI

/// Real settings window. Tabbed in the standard macOS style; all bindings
/// flow through `AppSettings` and persist to `UserDefaults`.
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }
            EditorSettings(settings: settings)
                .tabItem { Label("Editor", systemImage: "text.cursor") }
            BinariesSettings(settings: settings)
                .tabItem { Label("Binaries", systemImage: "terminal") }
            UpdatesSettings(settings: settings)
                .tabItem { Label("Updates", systemImage: "arrow.down.app") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Restore last session on launch", isOn: $settings.restoreLastSession)
                    .help("Re-open the windows + tabs you had open at quit. Scratchpad SQL survives.")
            }
            Section("Queries") {
                Stepper(value: $settings.defaultRowLimit, in: 100...100_000, step: 100) {
                    HStack {
                        Text("Default row limit")
                        Spacer()
                        Text(settings.defaultRowLimit.formatted())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .help("Maximum rows pulled for SELECT into a result block (truncation is detected via limit+1).")
                Toggle("Verbose Postgres logging", isOn: $settings.verbosePostgresLogging)
                    .help("Pipe PostgresNIO's internal log stream to the system log. Off by default; useful when debugging weird wire-protocol behaviour.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("SQL editor") {
                Stepper(value: $settings.editorFontSize, in: 10...22, step: 1) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(settings.editorFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("Restart the scratchpad tab to pick up font changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BinariesSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                BinaryPathRow(label: "pg_dump", binding: $settings.pgDumpPath, defaultName: "pg_dump")
                BinaryPathRow(label: "pg_restore", binding: $settings.pgRestorePath, defaultName: "pg_restore")
                BinaryPathRow(label: "psql", binding: $settings.psqlPath, defaultName: "psql")
            } header: {
                Text("External binaries")
            } footer: {
                Text("Leave blank to auto-detect from Postgres.app, Homebrew, EnterpriseDB installers, or /usr/bin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BinaryPathRow: View {
    let label: String
    @Binding var binding: String
    let defaultName: String
    @State private var discovered: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 100, alignment: .leading)
            TextField("auto", text: $binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Button("Browse…") {
                pick()
            }
        }
        .help(discovered.map { "Auto-discovered: \($0)" } ?? "")
        .task {
            // Best-effort discovery preview.
            discovered = try? PgDumpCLI.locateBinary(named: defaultName).path
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            binding = url.path
        }
    }
}

private struct UpdatesSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Channel", selection: $settings.sparkleChannel) {
                    Text("Stable").tag("stable")
                    Text("Beta").tag("beta")
                }
                .pickerStyle(.segmented)
                Text("Sparkle auto-update lands in iter-12. The channel choice is captured now so first-update is one click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Auto-update")
            }
        }
        .formStyle(.grouped)
    }
}
