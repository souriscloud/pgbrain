import SwiftUI

/// Browse + poke sequences in the current database. Useful when an
/// IDENTITY column got out of sync with the data and `setval(...)` is
/// the only way back. Re-fetches on action so the displayed
/// `last_value` reflects whatever the action just did.
struct SequenceInspectorView: View {
    let service: ConnectionService
    let onClose: () -> Void

    @State private var sequences: [SequenceInfo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var setvalDraft: [String: String] = [:]
    @State private var restartDraft: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 880, height: 540)
        .task { await refresh() }
    }

    private var header: some View {
        HStack {
            Text("Sequences").font(.title3.weight(.semibold))
            Text("(\(sequences.count))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Button { Task { await refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24)).foregroundStyle(.orange)
                Text("Couldn't load sequences").font(.headline)
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sequences.isEmpty && !loading {
            VStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("No user sequences in this database")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    ForEach(sequences) { seq in
                        row(seq)
                    }
                }
                .padding(Tokens.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private func row(_ s: SequenceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "number")
                    .foregroundStyle(Tokens.Brand.primary)
                Text("\(s.schema).\(s.name)")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(s.dataType)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.secondary)
                if !s.ownedBy.isEmpty {
                    Text("owned by \(s.ownedBy)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("last: \(s.lastValue.map(String.init) ?? "(unread)")")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 16) {
                meta("start", "\(s.startValue)")
                meta("min", "\(s.minValue)")
                meta("max", "\(s.maxValue)")
                meta("inc", "\(s.increment)")
                meta("cache", "\(s.cacheSize)")
                meta("cycle", s.cycle ? "yes" : "no")
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        if case .failure(let err) = await AdminActions.nextval(schema: s.schema, sequence: s.name, service: service) {
                            error = err.localizedDescription
                        } else {
                            await refresh()
                        }
                    }
                } label: {
                    Label("nextval", systemImage: "arrow.right.circle")
                }
                TextField("setval", text: Binding(
                    get: { setvalDraft[s.id] ?? "" },
                    set: { setvalDraft[s.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: 130)
                Button("setval") {
                    guard let v = Int64(setvalDraft[s.id] ?? "") else { return }
                    Task {
                        if case .failure(let err) = await AdminActions.setval(schema: s.schema, sequence: s.name, value: v, service: service) {
                            error = err.localizedDescription
                        } else {
                            setvalDraft[s.id] = ""
                            await refresh()
                        }
                    }
                }
                Divider().frame(height: 16)
                TextField("restart with", text: Binding(
                    get: { restartDraft[s.id] ?? "" },
                    set: { restartDraft[s.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: 130)
                Button("RESTART") {
                    guard let v = Int64(restartDraft[s.id] ?? "") else { return }
                    Task {
                        if case .failure(let err) = await AdminActions.restartSequence(schema: s.schema, sequence: s.name, to: v, service: service) {
                            error = err.localizedDescription
                        } else {
                            restartDraft[s.id] = ""
                            await refresh()
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Tokens.Spacing.sm)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }

    private func refresh() async {
        guard let client = service.client else {
            error = "Not connected."; return
        }
        loading = true; defer { loading = false }
        do {
            sequences = try await SequenceFetcher.fetchAll(client: client)
            error = nil
        } catch {
            self.error = PostgresErrorMessage.describe(error)
        }
    }
}
