import SwiftUI

/// Collects values for DataGrip-style `:name` query parameters before a
/// scratchpad statement runs. Values are raw SQL fragments — the user
/// supplies the quoting (`'alice'`, `42`, `now()`), matching how DataGrip's
/// parameter panel behaves. Confirmed values are remembered on the notebook
/// so re-runs reuse them without re-prompting.
struct QueryParametersView: View {
    let names: [String]
    /// Previously remembered values, used to pre-fill the fields.
    let values: [String: String]
    let onRun: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var entries: [String: String]
    @FocusState private var focused: String?

    init(
        names: [String],
        values: [String: String],
        onRun: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.names = names
        self.values = values
        self.onRun = onRun
        self.onCancel = onCancel
        var seed: [String: String] = [:]
        for name in names { seed[name] = values[name] ?? "" }
        _entries = State(initialValue: seed)
    }

    private var allFilled: Bool {
        names.allSatisfy { !(entries[$0] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "questionmark.square.dashed")
                    .foregroundStyle(Tokens.Brand.primary)
                Text("Query parameters")
                    .font(.headline)
            }

            Text("Supply a value for each placeholder. Values are spliced in as raw SQL — quote strings yourself (e.g. 'alice').")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(":\(name)")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField(
                                "value",
                                text: Binding(
                                    get: { entries[name] ?? "" },
                                    set: { entries[name] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .focused($focused, equals: name)
                            .onSubmit(submit)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!allFilled)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 380)
        .onAppear { focused = names.first }
    }

    private func submit() {
        guard allFilled else { return }
        onRun(entries)
    }
}
