import SwiftUI

/// Sheet to clone an entire schema into a new one, choosing exactly which
/// content types to copy. Drives `SchemaDuplicator`.
struct DuplicateSchemaSheet: View {
    let service: ConnectionService
    let sourceSchema: String
    let onClose: () -> Void

    @State private var target: String = ""
    @State private var opts = SchemaDuplicator.Options()
    @State private var running = false
    @State private var error: String?

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var anySelected: Bool {
        opts.tableStructure || opts.sequences || opts.views || opts.matviews || opts.functions
    }
    private var canApply: Bool {
        !trimmedTarget.isEmpty && trimmedTarget != sourceSchema && anySelected && !running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2).foregroundStyle(Tokens.Brand.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Schema").font(.title3.weight(.semibold))
                    Text(sourceSchema).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Form {
                Section("New schema name") {
                    TextField("target schema", text: $target)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                Section("Include") {
                    Toggle("Tables (structure)", isOn: $opts.tableStructure)
                        .onChange(of: opts.tableStructure) { _, on in
                            if !on { opts.tableData = false; opts.foreignKeys = false }
                        }
                    Toggle("Table data", isOn: $opts.tableData).disabled(!opts.tableStructure)
                    Toggle("Foreign keys", isOn: $opts.foreignKeys).disabled(!opts.tableStructure)
                    Toggle("Sequences", isOn: $opts.sequences)
                    Toggle("Views", isOn: $opts.views)
                    Toggle("Materialized views", isOn: $opts.matviews)
                    Toggle("Functions & procedures", isOn: $opts.functions)
                }
                Section {
                    Text("Best-effort clone. Triggers, row-level security, grants/ownership, and partitioning are not copied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 320)

            if let error {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button {
                    run()
                } label: {
                    if running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Duplicating…") }
                    } else {
                        Text("Duplicate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 460)
        .onAppear { if target.isEmpty { target = "\(sourceSchema)_copy" } }
    }

    private func run() {
        running = true
        error = nil
        let src = sourceSchema
        let dst = trimmedTarget
        let options = opts
        Task {
            let result = await SchemaDuplicator.duplicate(from: src, to: dst, options: options, service: service)
            running = false
            switch result {
            case .success:
                await service.loadSchema()
                service.toasts.show(.success, "Duplicated \(src) → \(dst)")
                onClose()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}
