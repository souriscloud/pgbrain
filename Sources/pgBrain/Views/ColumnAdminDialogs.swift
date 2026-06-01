import SwiftUI

/// Column-level ALTER TABLE dialogs. Driven from the Structure pane's
/// per-column right-click menu.
struct AddColumnSheet: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var name: String = ""
    @State private var type: String = "text"
    @State private var nullable: Bool = true
    @State private var hasDefault = false
    @State private var defaultValue: TypedInputValue = .literal("")
    @State private var saving = false
    @State private var error: String?

    /// The DEFAULT clause expression, or nil when no default is set.
    private var defaultExpr: String? {
        hasDefault ? defaultValue.sqlFragment(typeName: type, cast: false) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Add column to \(schema).\(table)").font(.title3.weight(.semibold))
            labelled("Name") {
                TextField("column_name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            labelled("Type") {
                TextField("text", text: $type)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            labelled("Default") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Set a default", isOn: $hasDefault).toggleStyle(.checkbox).font(.callout)
                    if hasDefault {
                        TypedValueEditor(
                            typeName: type, nullable: nullable, enums: service.schema.enums,
                            allowsDefault: false, allowsExpression: true,
                            completions: { p, _, _ in
                                SQLCompletionProvider.items(for: p, in: service.schema, context: .expression(columns: []))
                            },
                            value: $defaultValue
                        )
                    }
                }
            }
            Toggle("Nullable", isOn: $nullable).toggleStyle(.checkbox)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Add") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || type.isEmpty)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 420)
    }

    @ViewBuilder
    private func labelled<Body: View>(_ title: String, @ViewBuilder content: () -> Body) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content()
        }
    }

    private func run() {
        saving = true
        Task {
            let result = await AdminActions.addColumn(
                schema: schema, table: table,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                type: type, nullable: nullable,
                defaultExpr: defaultExpr,
                service: service
            )
            saving = false
            switch result {
            case .success: onSaved(); onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}

struct RenameColumnSheet: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let original: String
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var name: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Rename column “\(original)”").font(.title3.weight(.semibold))
            TextField("new_name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { run() }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Rename") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == original)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 380)
        .onAppear { name = original }
    }

    private func run() {
        saving = true
        Task {
            let result = await AdminActions.renameColumn(
                schema: schema, table: table,
                from: original, to: name.trimmingCharacters(in: .whitespacesAndNewlines),
                service: service
            )
            saving = false
            switch result {
            case .success: onSaved(); onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}

struct AlterColumnTypeSheet: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let column: String
    let currentType: String
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var newType: String = ""
    @State private var usingExpr: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Change type of \(column)").font(.title3.weight(.semibold))
            Text("Current: \(currentType)").font(.caption).foregroundStyle(.secondary)
            TextField("new type (e.g. bigint)", text: $newType)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            VStack(alignment: .leading, spacing: 3) {
                Text("USING (cast expression for non-implicit conversions)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("e.g. \(column)::bigint", text: $usingExpr)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Alter") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(saving || newType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 460)
    }

    private func run() {
        saving = true
        Task {
            let result = await AdminActions.alterColumnType(
                schema: schema, table: table, column: column,
                newType: newType, using: usingExpr.trimmingCharacters(in: .whitespaces).isEmpty ? nil : usingExpr,
                service: service
            )
            saving = false
            switch result {
            case .success: onSaved(); onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}
