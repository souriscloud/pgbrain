import SwiftUI

/// Sheets for cluster-level database admin: create + drop. Sit next
/// to `SchemaAdminDialogs.swift` so they're easy to find together.
struct CreateDatabaseSheet: View {
    let service: ConnectionService
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var owner: String = ""
    @State private var template: String = ""
    @State private var encoding: String = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("New database").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                labelled("Name", required: true) {
                    TextField("database_name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                labelled("Owner") {
                    TextField("(current user)", text: $owner)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                labelled("Template") {
                    TextField("template1", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                labelled("Encoding") {
                    TextField("UTF8", text: $encoding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .disabled(saving)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Create") { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
                    .keyboardShortcut(.return)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 420)
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

    private func run() {
        saving = true
        Task {
            let result = await AdminActions.createDatabase(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                owner: owner.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                template: template.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                encoding: encoding.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                service: service
            )
            saving = false
            switch result {
            case .success: onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}

struct DropDatabaseSheet: View {
    let service: ConnectionService
    let target: String
    let onClose: () -> Void

    @State private var force = false
    @State private var confirmText: String = ""
    @State private var error: String?
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Drop database “\(target)”").font(.title3.weight(.semibold))
            }
            Text("Every schema, table, function, role-grant, and row inside this database goes away. The drop can't proceed if other sessions are connected — WITH FORCE terminates them first.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("WITH FORCE (kicks other sessions first)", isOn: $force)
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type the database name to confirm:").font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 460)
    }

    private func run() {
        dropping = true
        Task {
            let result = await AdminActions.dropDatabase(name: target, force: force, service: service)
            dropping = false
            switch result {
            case .success: onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
