import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Restore a database with `pg_restore` from a chosen archive.
    static let pgbrainRestoreDatabase = Notification.Name("cloud.souris.pgbrain.restoreDatabase")
}

/// Sheet pairing with the `pg_dump` flow: pick a custom/tar/directory archive
/// and `pg_restore` it into a target database. Mirrors the admin dialogs in
/// `DatabaseAdminDialogs.swift`. The restore runs on a background `Task`,
/// tracked through `service.operations`, with the password pulled from the
/// Keychain (never placed on the command line).
struct RestoreDatabaseSheet: View {
    let service: ConnectionService
    let onClose: () -> Void

    @State private var archive: URL?
    @State private var dbname: String
    @State private var clean = false
    @State private var noOwner = false
    @State private var singleTransaction = false
    @State private var jobs: Int = 1
    @State private var error: String?
    @State private var stderr: String?
    @State private var running = false
    @State private var done = false

    init(service: ConnectionService, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
        let current = service.connection.database
        _dbname = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Restore database").font(.title3.weight(.semibold))
            Text("Reads a pg_dump custom/tar/directory archive into the target database with pg_restore.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                labelled("Archive", required: true) {
                    HStack(spacing: 6) {
                        Text(archive?.lastPathComponent ?? "No file selected")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(archive == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: pickArchive).disabled(running)
                    }
                }
                labelled("Target DB", required: true) {
                    TextField("database_name", text: $dbname)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(running)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Clean (drop objects before recreating)", isOn: $clean)
                    .toggleStyle(.checkbox)
                Toggle("No owner (skip SET OWNER / ALTER OWNER)", isOn: $noOwner)
                    .toggleStyle(.checkbox)
                Toggle("Single transaction (atomic; disables parallel jobs)", isOn: $singleTransaction)
                    .toggleStyle(.checkbox)
                HStack(spacing: 8) {
                    Text("Parallel jobs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Stepper(value: $jobs, in: 1...16) {
                        Text("\(jobs)").font(.system(.body, design: .monospaced)).monospacedDigit()
                    }
                    .disabled(singleTransaction)
                }
                .opacity(singleTransaction ? 0.5 : 1)
            }
            .disabled(running)

            if let stderr, !stderr.isEmpty {
                ScrollView {
                    Text(stderr)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(done ? "Close" : "Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Restore") { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
                    .keyboardShortcut(.return)
                    .disabled(!canRun)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 480)
    }

    private var canRun: Bool {
        archive != nil
            && !dbname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !running
    }

    @ViewBuilder
    private func labelled<Body: View>(_ title: String, required: Bool = false, @ViewBuilder content: () -> Body) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title + (required ? " *" : ""))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            content()
        }
    }

    private func pickArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Directory-format archives are folders, so allow picking those too.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        var types: [UTType] = [.data]
        if let tar = UTType(filenameExtension: "tar") { types.append(tar) }
        if let dump = UTType(filenameExtension: "dump") { types.append(dump) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archive = url
        error = nil
        stderr = nil
        done = false
    }

    private func run() {
        guard let archive else { return }
        running = true
        done = false
        error = nil
        stderr = nil

        let conn = service.connection
        let target = dbname.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = Keychain.password(for: conn.id) ?? ""
        let options = PgDumpCLI.RestoreOptions(
            clean: clean,
            noOwner: noOwner,
            singleTransaction: singleTransaction,
            jobs: jobs
        )
        let op = service.operations.begin(
            kind: .importJob,
            summary: "pg_restore → \(target)"
        )
        let tracker = service.operations
        Task {
            do {
                let result = try await PgDumpCLI.restore(
                    connection: conn,
                    password: password,
                    dbname: target,
                    archive: archive,
                    options: options
                )
                running = false
                done = true
                stderr = result.stderr
                tracker.finish(op, status: .succeeded)
            } catch {
                running = false
                if let cliError = error as? PgDumpCLI.CLIError,
                   case .nonZeroExit(_, let err) = cliError {
                    stderr = err
                }
                self.error = error.localizedDescription
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }
}
