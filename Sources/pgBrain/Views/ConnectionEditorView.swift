import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditorView: View {
    @State private var connection: Connection
    @State private var password: String
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var connectionString = ""
    @State private var connectionStringMessage: String?
    @State private var connectionStringOK = false

    let onSave: (Connection, String) -> Void
    let onCancel: () -> Void
    private let loadsKeychainPassword: Bool

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
        // Save). Otherwise `.edit` loads the Keychain entry in `.task`.
        _password = State(initialValue: initialPassword ?? "")
        loadsKeychainPassword = initialPassword == nil && connection != nil
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
        .frame(width: 540, height: 700)
        .task {
            // Keychain reads can block on an access prompt — keep them off-main.
            guard loadsKeychainPassword else { return }
            if let stored = await Keychain.passwordAsync(for: connection.id), password.isEmpty {
                password = stored
            }
        }
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
            if connection.readOnly {
                Text("READ-ONLY")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Corner.chip))
            }
            Spacer()
            // Quick-import from the clipboard: a pgBrain exchange JSON, a
            // postgres:// URL or a libpq key=value string.
            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Fill the fields from a pgBrain exchange JSON, postgres:// URL or key=value string on the clipboard")
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        .padding(Tokens.Spacing.lg)
    }

    private func pasteFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        guard let imported = ConnectionExchange.parse(raw) else {
            connectionString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            applyConnectionString()
            return
        }
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
        if !imported.warnings.isEmpty {
            connectionStringOK = false
            connectionStringMessage = imported.warnings.joined(separator: "\n")
        }
    }

    /// Fill fields from a `postgres://` URL or libpq `key=value` string.
    /// Only keys present in the string are touched.
    private func applyConnectionString() {
        do {
            let parsed = try ConnInfoParser.parse(connectionString)
            if let pw = ConnInfoParser.apply(parsed, to: &connection) { password = pw }
            if connection.name.isEmpty || connection.name == "Local Postgres" {
                let derived = parsed.service ?? [parsed.database, parsed.host].compactMap { $0 }.joined(separator: " @ ")
                if !derived.isEmpty { connection.name = derived }
            }
            connectionStringOK = true
            var note = "Filled from connection string."
            if !parsed.ignored.isEmpty {
                note += " Ignored: " + parsed.ignored.keys.sorted().joined(separator: ", ") + "."
            }
            connectionStringMessage = note
            connectionString = ""
        } catch {
            connectionStringOK = false
            connectionStringMessage = error.localizedDescription
        }
    }

    private var sshValidationError: String? {
        guard connection.sshEnabled else { return nil }
        do {
            try SSHCommand.validate(connection)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            field("Connection string (optional)") {
                HStack(spacing: 6) {
                    TextField("postgres://user@host:5432/db?sslmode=require  or  host=… dbname=…",
                              text: $connectionString)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyConnectionString)
                    Button("Fill", action: applyConnectionString)
                        .disabled(connectionString.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let connectionStringMessage {
                Label(connectionStringMessage,
                      systemImage: connectionStringOK ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(connectionStringOK ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            if connection.sslMode != .disable {
                sslFiles
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

            sessionSettings

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
                            .autocorrectionDisabled()
                    }
                    field("Port", flex: 0) {
                        TextField("22", value: $connection.sshPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
                HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                    field("SSH User") {
                        TextField("ec2-user", text: $connection.sshUser)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    field("Private key (optional)") {
                        HStack(spacing: 4) {
                            TextField("blank = agent / default keys", text: $connection.sshKeyPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { pickFile(into: $connection.sshKeyPath, directory: ".ssh") }
                        }
                    }
                }
                Text("Keys with a passphrase must be loaded into ssh-agent (ssh-add --apple-use-keychain). New hosts are added to known_hosts automatically; changed host keys are refused.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sshValidationError {
                    Label(sshValidationError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
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

    @ViewBuilder
    private var sslFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            pathRow("Root CA", placeholder: "system trust store", binding: $connection.sslRootCertPath)
            pathRow("Client cert", placeholder: "none", binding: $connection.sslClientCertPath)
            pathRow("Client key", placeholder: "none (unencrypted PEM)", binding: $connection.sslClientKeyPath)
            Text(sslHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sslHint: String {
        switch connection.sslMode {
        case .disable:
            return ""
        case .allow, .prefer:
            return "\(connection.sslMode.rawValue) encrypts when the server offers TLS but verifies nothing; the root CA is ignored."
        case .require:
            return "require encrypts without verifying — unless a Root CA is set, then the chain is verified (like verify-ca)."
        case .verifyCA:
            return "verify-ca checks the certificate chain against the Root CA (or the system trust store), not the hostname."
        case .verifyFull:
            return "verify-full checks the chain and that the certificate matches \(connection.host.isEmpty ? "the host" : connection.host) — also through an SSH tunnel."
        }
    }

    private func pathRow(_ label: String, placeholder: String, binding: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Button("Choose…") { pickFile(into: binding, directory: nil) }
                .controlSize(.small)
            if !binding.wrappedValue.isEmpty {
                Button {
                    binding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }

    @ViewBuilder
    private var sessionSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $connection.readOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read-only sessions").font(.callout.weight(.medium))
                    Text("Starts every session with default_transaction_read_only = on, so writes fail unless you explicitly SET it off. A guard rail, not a permission.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if connection.isProduction && !connection.readOnly {
                Label("Production connection — consider turning on read-only sessions.", systemImage: "lightbulb")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: Tokens.Spacing.md) {
                secondsField("Statement timeout", value: $connection.statementTimeoutSeconds)
                secondsField("Idle-in-transaction timeout", value: $connection.idleInTransactionTimeoutSeconds)
            }
            Text("Seconds; 0 keeps the server default. Sent as startup parameters — some poolers (PgBouncer) reject them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Tokens.Spacing.xs)
    }

    private func secondsField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("0", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = max(0, $0) }
            ), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private func pickFile(into binding: Binding<String>, directory: String?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let directory {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        binding.wrappedValue = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
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
            .disabled(isTesting || connection.host.isEmpty || sshValidationError != nil)
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(connection, password)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(connection.name.trimmingCharacters(in: .whitespaces).isEmpty || connection.host.isEmpty
                      || sshValidationError != nil)
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

        // Same pre-flight probe ConnectionService uses (through the SSH
        // tunnel when enabled), so both surfaces give identical errors.
        let outcome = await ConnectionService.testConnection(connection, password: password)
        switch outcome {
        case .ok:
            testOK = true
            testMessage = "Connected to \(connection.host):\(connection.port)\(connection.sshEnabled ? " via SSH" : "") — credentials accepted."
        case .failure(let message):
            testOK = false
            testMessage = message
        }
    }

    /// "host:port" → ("host", port). Accepts IPv4/hostname forms only —
    /// bracketed IPv6 (`[::1]:5432`) is left alone so we don't mangle it.
    private func splitHostPort(_ raw: String) -> (String, Int)? {
        guard !raw.contains("["), let colon = raw.lastIndex(of: ":") else { return nil }
        let portPart = raw[raw.index(after: colon)...]
        guard let port = Int(portPart), port > 0, port < 65_536 else { return nil }
        return (String(raw[..<colon]), port)
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
