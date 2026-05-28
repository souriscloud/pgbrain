import SwiftUI

/// TRUNCATE confirmation sheet. Truncate is fast + irreversible, so it
/// gets the retype-to-confirm treatment like DROP. CASCADE and
/// RESTART IDENTITY are explicit toggles.
struct TruncateSheet: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let onClose: () -> Void
    let onDone: () -> Void

    @State private var cascade = false
    @State private var restartIdentity = false
    @State private var confirmText: String = ""
    @State private var error: String?
    @State private var running = false

    private var qualified: String { "\(schema).\(table)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack {
                Image(systemName: "trash.fill").foregroundStyle(.red)
                Text("Truncate “\(qualified)”").font(.title3.weight(.semibold))
            }
            Text("Removes every row immediately and can't be undone. CASCADE also truncates tables with foreign keys pointing here; RESTART IDENTITY resets owned sequences to their start value.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("CASCADE (also truncate referencing tables)", isOn: $cascade)
                .toggleStyle(.checkbox)
            Toggle("RESTART IDENTITY (reset owned sequences)", isOn: $restartIdentity)
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type the table name to confirm:").font(.caption).foregroundStyle(.secondary)
                TextField(table, text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(running)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Truncate", role: .destructive) { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.return)
                    .disabled(confirmText != table || running)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 460)
    }

    private func run() {
        running = true
        Task {
            let result = await AdminActions.truncate(
                schema: schema, table: table,
                cascade: cascade, restartIdentity: restartIdentity,
                service: service
            )
            running = false
            switch result {
            case .success: onDone(); onClose()
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}
