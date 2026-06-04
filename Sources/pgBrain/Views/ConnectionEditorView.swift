import SwiftUI
import PostgresNIO
import NIOCore
import NIOSSL

struct ConnectionEditorView: View {
    @State private var connection: Connection
    @State private var password: String
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testOK = false

    let onSave: (Connection, String) -> Void
    let onCancel: () -> Void

    init(
        connection: Connection?,
        initialPassword: String? = nil,
        onSave: @escaping (Connection, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let initial = connection ?? Connection(name: "Local Postgres", host: "localhost", database: "postgres", username: NSUserName())
        _connection = State(initialValue: initial)
        // `initialPassword` wins (used by the Welcome paste-import
        // path so the user sees the pasted secret before they hit
        // Save). Falls back to the Keychain entry for `.edit`.
        _password = State(initialValue: initialPassword ?? Keychain.password(for: initial.id) ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                form.padding(Tokens.Spacing.lg)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 620)
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Circle()
                .fill(connection.colorTag.swiftUIColor.opacity(connection.colorTag == .none ? 0 : 1))
                .stroke(Color.secondary.opacity(connection.colorTag == .none ? 0.4 : 0), lineWidth: 1)
                .frame(width: 14, height: 14)
            Text(connection.name.isEmpty ? "New Connection" : connection.name)
                .font(.title2.weight(.semibold))
            if connection.isProduction {
                Text("PRODUCTION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Tokens.Brand.danger)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Corner.chip))
            }
            Spacer()
            // Quick-import: paste a pgBrain exchange JSON from the
            // clipboard and the editor's fields fill in. Button is
            // dimmed when the pasteboard doesn't carry a recognisable
            // payload. ⌘V on this button also triggers the same path
            // (any-key for accessibility).
            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Paste a pgBrain exchange JSON from the clipboard to fill the fields")
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        .padding(Tokens.Spacing.lg)
    }

    /// Look at the pasteboard for the canonical exchange JSON. If
    /// found, copy each field into the bound `connection`. We don't
    /// auto-fire on the editor opening — too magical — but ⌘⇧V or the
    /// header button both reach this path.
    private func pasteFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let imported = ConnectionExchange.parse(raw)
        else { return }
        // Preserve the existing id (so "Edit…" doesn't clobber the
        // saved connection's identity), but copy everything else.
        let existingID = connection.id
        connection = imported.connection
        connection.id = existingID
        if let pw = imported.password {
            // Drop into the editor's local password field so the user
            // sees what was imported before they hit Save.
            password = pw
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            field("Name") {
                TextField("e.g. Local Postgres", text: $connection.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                // Port gets a fixed 100pt; Host takes the remaining width.
                // Earlier we used `.layoutPriority(2/1)`, which doesn't
                // proportion — the higher priority just claims everything
                // and the lower-priority field collapses to zero.
                field("Host") {
                    TextField("localhost", text: $connection.host)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        // Users routinely paste "localhost:5444" into the
                        // host field; PostgresNIO then DNS-looks that up
                        // verbatim and fails. Split it on the fly so the
                        // port lands where it belongs.
                        .onChange(of: connection.host) { _, newValue in
                            if let (h, p) = splitHostPort(newValue) {
                                connection.host = h
                                connection.port = p
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port").font(.caption).foregroundStyle(.secondary)
                    TextField("5432", value: $connection.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                }
                .frame(width: 100)
            }

            field("Database") {
                TextField("postgres", text: $connection.database)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            field("Default schema") {
                TextField("leave blank for the server default search_path",
                          text: $connection.defaultSearchPath)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            HStack(spacing: Tokens.Spacing.md) {
                field("Username", flex: 1) {
                    TextField(NSUserName(), text: $connection.username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                field("Password", flex: 1) {
                    SecureField("•••••", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: Tokens.Spacing.md) {
                field("SSL Mode", flex: 1) {
                    Picker("", selection: $connection.sslMode) {
                        ForEach(Connection.SSLMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                field("Color tag", flex: 1) {
                    HStack(spacing: 6) {
                        ForEach(Connection.ColorTag.allCases) { tag in
                            ColorTagSwatch(tag: tag, isSelected: connection.colorTag == tag) {
                                connection.colorTag = tag
                            }
                        }
                    }
                }
            }

            Toggle(isOn: $connection.isProduction) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Production").font(.callout.weight(.medium))
                    Text("Show danger chrome everywhere this connection is referenced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Tokens.Brand.danger)
            .padding(.top, Tokens.Spacing.xs)

            // SSH tunnel section — optional. When enabled we shell
            // out to /usr/bin/ssh with `-L localport:dbhost:dbport`
            // and point the Postgres client at the local forward.
            Divider().padding(.vertical, 4)
            Toggle(isOn: $connection.sshEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH tunnel").font(.callout.weight(.medium))
                    Text("Connect through a bastion. Public-key auth only — set up your key in ssh-agent or specify a key file.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if connection.sshEnabled {
                HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                    field("SSH Host") {
                        TextField("bastion.example.com", text: $connection.sshHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Port", flex: 0) {
                        TextField("22", value: $connection.sshPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
                HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                    field("SSH User") {
                        TextField("ec2-user", text: $connection.sshUser)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Private key (optional)") {
                        TextField("~/.ssh/id_ed25519 — leave blank to use agent / defaults",
                                  text: $connection.sshKeyPath)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if let testMessage {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                    Image(systemName: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(testOK ? .green : .orange)
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, Tokens.Spacing.xs)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await runTest() }
            } label: {
                if isTesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Label("Test Connection", systemImage: "bolt.horizontal")
                }
            }
            .disabled(isTesting || connection.host.isEmpty)
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(connection, password)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(connection.name.trimmingCharacters(in: .whitespaces).isEmpty || connection.host.isEmpty)
        }
        .padding(Tokens.Spacing.md)
    }

    private func field<C: View>(_ label: String, flex: Int = 1, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
        .layoutPriority(Double(flex))
    }

    @MainActor
    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testMessage = nil

        // Delegate to the same pre-flight probe ConnectionService uses, so
        // both surfaces give identical, actionable errors. We don't pull a
        // version string back from this — the probe just answers "can we
        // authenticate against this server?" — and on success we tell the
        // user as much.
        let outcome = await ConnectionService.probe(connection: connection, password: password)
        switch outcome {
        case .ok:
            testOK = true
            testMessage = "Connected to \(connection.host):\(connection.port) — credentials accepted."
        case .failure(let message):
            testOK = false
            testMessage = message
        }
    }

    private enum ProbeResult: Sendable {
        case ok(String)
        case failure(String)
    }

    /// "host:port" → ("host", port). Accepts IPv4/hostname forms only —
    /// bracketed IPv6 (`[::1]:5432`) is left alone so we don't mangle it.
    private func splitHostPort(_ raw: String) -> (String, Int)? {
        guard !raw.contains("["), let colon = raw.lastIndex(of: ":") else { return nil }
        let portPart = raw[raw.index(after: colon)...]
        guard let port = Int(portPart), port > 0, port < 65_536 else { return nil }
        return (String(raw[..<colon]), port)
    }

    nonisolated private static func probe(connection: Connection, password: String) async -> ProbeResult {
        let tls: PostgresClient.Configuration.TLS
        switch connection.sslMode {
        case .disable: tls = .disable
        case .allow, .prefer:
            tls = .prefer(TLSConfiguration.makeClientConfiguration())
        case .require, .verifyCA, .verifyFull:
            tls = .require(TLSConfiguration.makeClientConfiguration())
        }

        let config = PostgresClient.Configuration(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password.isEmpty ? nil : password,
            database: connection.database.isEmpty ? nil : connection.database,
            tls: tls
        )
        let client = PostgresClient(configuration: config)
        // Hard 10s timeout so a wrong host / mismatched SSL mode surfaces
        // as a real error instead of leaving the user staring at a spinner.
        return await withTaskGroup(of: ProbeResult?.self, returning: ProbeResult.self) { group in
            group.addTask { await client.run(); return nil }
            group.addTask {
                do {
                    let rows = try await client.query("SELECT version()")
                    for try await (v) in rows.decode(String.self) {
                        return .ok(v)
                    }
                    return .failure("Connected but no version returned.")
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return .failure("Timed out after 10s. If SSL mode is require/verify-*, try \"prefer\" — some servers don't speak TLS.")
            }
            var outcome: ProbeResult = .failure("Unknown error")
            for await result in group {
                if let result {
                    outcome = result
                    group.cancelAll()
                    break
                }
            }
            return outcome
        }
    }
}

private struct ColorTagSwatch: View {
    let tag: Connection.ColorTag
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(tag == .none ? Color.clear : tag.swiftUIColor)
                    .stroke(Color.secondary.opacity(tag == .none ? 0.6 : 0), lineWidth: 1)
                    .frame(width: 18, height: 18)
                if isSelected {
                    Circle()
                        .stroke(Color.primary, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tag.rawValue.capitalized)
    }
}
