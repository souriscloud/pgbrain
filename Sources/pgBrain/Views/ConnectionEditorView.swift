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

    init(connection: Connection?, onSave: @escaping (Connection, String) -> Void, onCancel: @escaping () -> Void) {
        let initial = connection ?? Connection(name: "Local Postgres", host: "localhost", database: "postgres", username: NSUserName())
        _connection = State(initialValue: initial)
        _password = State(initialValue: Keychain.password(for: initial.id) ?? "")
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
        }
        .padding(Tokens.Spacing.lg)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            field("Name") {
                TextField("e.g. Local Postgres", text: $connection.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: Tokens.Spacing.md) {
                field("Host", flex: 2) {
                    TextField("localhost", text: $connection.host)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                field("Port", flex: 1) {
                    TextField("5432", value: $connection.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                }
            }

            field("Database") {
                TextField("postgres", text: $connection.database)
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

        let result = await Self.probe(connection: connection, password: password)
        switch result {
        case .ok(let version):
            testOK = true
            testMessage = "Connected — \(version)"
        case .failure(let message):
            testOK = false
            testMessage = message
        }
    }

    private enum ProbeResult: Sendable {
        case ok(String)
        case failure(String)
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
