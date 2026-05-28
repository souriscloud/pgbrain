import SwiftUI

/// GRANT / REVOKE editor. Pick a role, a table, and a set of table
/// privileges, then grant or revoke them in one statement. Kept
/// deliberately table-scoped — column / sequence / schema grants are a
/// rarer need and would bloat the UI.
struct GrantEditorSheet: View {
    let service: ConnectionService
    let roles: [String]
    let onClose: () -> Void
    let onDone: () -> Void

    static let allPrivileges = ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"]

    @State private var role: String = ""
    @State private var schema: String = ""
    @State private var table: String = ""
    @State private var selected: Set<String> = ["SELECT"]
    @State private var error: String?
    @State private var working = false

    private var schemas: [String] { service.visibleSchema.schemas.map(\.name) }
    private var tables: [String] {
        service.visibleSchema.schemas.first(where: { $0.name == schema })?.tables.map(\.name) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Grant / Revoke privileges").font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Role").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $role) {
                        ForEach(roles, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Schema").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $schema) {
                        ForEach(schemas, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: schema) { _, _ in table = tables.first ?? "" }
                }
                GridRow {
                    Text("Table").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $table) {
                        ForEach(tables, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            }

            Text("Privileges").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Self.allPrivileges, id: \.self) { priv in
                    Toggle(priv, isOn: Binding(
                        get: { selected.contains(priv) },
                        set: { on in if on { selected.insert(priv) } else { selected.remove(priv) } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(.caption, design: .monospaced))
                }
            }
            HStack(spacing: 8) {
                Button("All") { selected = Set(Self.allPrivileges) }
                    .controlSize(.small).buttonStyle(.borderless)
                Button("None") { selected = [] }
                    .controlSize(.small).buttonStyle(.borderless)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Revoke", role: .destructive) { run(grant: false) }
                    .disabled(!canRun)
                Button("Grant") { run(grant: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 460)
        .onAppear {
            role = roles.first ?? ""
            schema = schemas.first ?? ""
            table = tables.first ?? ""
        }
    }

    private var canRun: Bool {
        !working && !role.isEmpty && !schema.isEmpty && !table.isEmpty && !selected.isEmpty
    }

    private func run(grant: Bool) {
        working = true
        Task {
            let result = await AdminActions.setPrivileges(
                grant: grant,
                privileges: Self.allPrivileges.filter { selected.contains($0) },
                schema: schema, table: table, role: role,
                service: service
            )
            working = false
            switch result {
            case .success: onDone(); onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}
