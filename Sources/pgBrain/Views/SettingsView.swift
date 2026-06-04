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
            ConnectionsSettings()
                .tabItem { Label("Connections", systemImage: "rectangle.connected.to.line.below") }
            BinariesSettings(settings: settings)
                .tabItem { Label("Binaries", systemImage: "terminal") }
            UpdatesSettings(settings: settings)
                .tabItem { Label("Updates", systemImage: "arrow.down.app") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Force pgBrain into Light or Dark, or follow the macOS system setting.")
            }
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
            Section {
                Stepper(value: $settings.editorFontSize,
                        in: AppSettings.fontRange, step: 1) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(settings.editorFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("Sample SELECT * FROM users WHERE id = 1;")
                    .font(.system(size: settings.editorFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } header: {
                Text("SQL editor")
            } footer: {
                Text("Applies live to every open scratchpad. Zoom with ⌘+ / ⌘− (⌘0 resets).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionsSettings: View {
    @State private var store = ConnectionStore.shared
    @State private var includePasswords = false
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Toggle("Include passwords", isOn: $includePasswords)
                    .help("Embeds Keychain passwords in the exported JSON. Treat the file as a secret.")
                HStack {
                    Button("Copy All as JSON") {
                        ConnectionIO.copyToClipboard(store.connections, includePasswords: includePasswords)
                        status = "Copied \(store.connections.count) connection\(store.connections.count == 1 ? "" : "s") to the clipboard."
                    }
                    Button("Export to File…") {
                        ConnectionIO.exportToFile(store.connections, includePasswords: includePasswords)
                    }
                    Spacer()
                }
                .disabled(store.connections.isEmpty)
            } header: {
                Text("Export \(store.connections.count) saved connection\(store.connections.count == 1 ? "" : "s")")
            } footer: {
                if includePasswords {
                    Label("Export will contain plain-text passwords.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Passwords are left out unless you opt in above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Import") {
                HStack {
                    Button("Paste from Clipboard") { handle(ConnectionIO.importFromClipboard()) }
                    Button("Import from File…") { handle(ConnectionIO.importFromFile()) }
                    Spacer()
                }
                Text("Duplicates (same name/host/port/db/user) are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func handle(_ result: ConnectionIO.ImportResult) {
        switch result {
        case .imported(let n):
            status = n == 0 ? "Nothing new — all connections already exist." : "Imported \(n) connection\(n == 1 ? "" : "s")."
        case .cancelled:
            break
        case .unrecognised:
            status = "That doesn't look like a pgBrain connection export."
        }
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
                HStack {
                    Button("Check for Updates Now") {
                        UpdateController.shared.checkForUpdates(nil)
                    }
                    Spacer()
                }
            } header: {
                Text("Auto-update")
            } footer: {
                Text("pgBrain auto-updates via Sparkle. Stable is recommended; Beta opts into pre-release builds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                HStack {
                    Link("Website", destination: URL(string: "https://apps.souris.cloud/apps/pgbrain")!)
                    Link("Source", destination: URL(string: "https://github.com/souriscloud/pgbrain")!)
                    Link("Support", destination: URL(string: "https://ko-fi.com/souriscloud")!)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
