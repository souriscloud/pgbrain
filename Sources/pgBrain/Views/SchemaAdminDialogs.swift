import SwiftUI

/// Sheets for the three schema-level admin actions: create, rename,
/// drop. Each wraps `AdminActions.*Schema` and surfaces the server
/// error inline when it fails.
struct CreateSchemaSheet: View {
    let service: ConnectionService
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("New schema").font(.title3.weight(.semibold))
            TextField("schema_name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { run() }
                .disabled(saving)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Create") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 380)
    }

    private func run() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true
        Task {
            let result = await AdminActions.createSchema(name: trimmed, service: service)
            saving = false
            switch result {
            case .success:
                await service.loadSchema()
                onClose()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}

struct RenameSchemaSheet: View {
    let service: ConnectionService
    let original: String
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Rename schema “\(original)”").font(.title3.weight(.semibold))
            TextField("new_name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { run() }
                .disabled(saving)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Rename") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 380)
        .onAppear { name = original }
    }

    private func run() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != original else { return }
        saving = true
        Task {
            let result = await AdminActions.renameSchema(from: original, to: trimmed, service: service)
            saving = false
            switch result {
            case .success:
                await service.loadSchema()
                onClose()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}

struct DropSchemaSheet: View {
    let service: ConnectionService
    let target: String
    let onClose: () -> Void

    @State private var cascade = false
    @State private var confirmText: String = ""
    @State private var error: String?
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Drop schema “\(target)”").font(.title3.weight(.semibold))
            }
            Text("This permanently removes the schema. With CASCADE every table, view, function, and sequence inside is dropped too. There is no undo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Drop dependent objects (CASCADE)", isOn: $cascade)
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type the schema name to confirm:").font(.caption).foregroundStyle(.secondary)
                TextField(target, text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(dropping)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Drop", role: .destructive) { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.return)
                    .disabled(confirmText != target || dropping)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 440)
    }

    private func run() {
        dropping = true
        Task {
            let result = await AdminActions.dropSchema(name: target, cascade: cascade, service: service)
            dropping = false
            switch result {
            case .success:
                await service.loadSchema()
                onClose()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}
