import SwiftUI
import PostgresNIO

/// LISTEN / NOTIFY console. One channel at a time — start typing,
/// hit Listen, and incoming notifications append to the table below.
/// Send NOTIFYs back to the same channel from the composer at the
/// bottom to round-trip in-app.
///
/// A live LISTEN ties up one connection from the pool for as long as
/// it's running — we surface that in the header so users don't accidentally
/// starve the pool by opening a dozen subscriptions.
struct NotifyPanelView: View {
    let service: ConnectionService
    let onClose: () -> Void

    struct Event: Identifiable, Equatable {
        let id: UUID = UUID()
        let receivedAt: Date
        let payload: String
    }

    @State private var channel: String = ""
    @State private var composerPayload: String = ""
    @State private var listening = false
    @State private var events: [Event] = []
    @State private var listenError: String?
    @State private var listenTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            Divider()
            composer
        }
        .frame(width: 760, height: 540)
        .onDisappear { stopListening() }
    }

    private var header: some View {
        HStack {
            Text("LISTEN / NOTIFY").font(.title3.weight(.semibold))
            if listening {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("listening on \(channel)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            TextField("channel name", text: $channel)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(listening)
                .onSubmit { if !listening { startListening() } }
            if listening {
                Button {
                    stopListening()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            } else {
                Button {
                    startListening()
                } label: {
                    Label("Listen", systemImage: "ear")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmedChannel.isEmpty)
            }
            Button {
                events.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(events.isEmpty)
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let listenError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24)).foregroundStyle(.orange)
                Text("Listener failed").font(.headline)
                Text(listenError)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if events.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: listening ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(listening
                     ? "Waiting for notifications on \(channel)…"
                     : "Enter a channel and press Listen")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(events.reversed()) {
                TableColumn("Received") { e in
                    Text(e.receivedAt.formatted(date: .omitted, time: .standard))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Payload") { e in
                    Text(e.payload.isEmpty ? "(empty)" : e.payload)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(e.payload.isEmpty ? .tertiary : .primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Text("NOTIFY")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(trimmedChannel.isEmpty ? "—" : trimmedChannel)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(trimmedChannel.isEmpty ? Color.secondary : Tokens.Brand.primary)
            TextField("payload (optional)", text: $composerPayload)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { sendNotify() }
            Button {
                sendNotify()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(trimmedChannel.isEmpty)
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 8)
    }

    private var trimmedChannel: String {
        channel.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Actions

    private func startListening() {
        guard let client = service.client else {
            listenError = "Not connected."
            return
        }
        let ch = trimmedChannel
        guard !ch.isEmpty else { return }
        listenError = nil
        listening = true
        events.removeAll()
        // Holding `withConnection` open dedicates one pool slot to this
        // subscriber — fine for ad-hoc debugging. The Task is cancelled
        // on Stop / sheet close, which lets the withConnection block
        // return its connection.
        listenTask = Task { @MainActor in
            do {
                try await client.withConnection { conn in
                    try await conn.listen(on: ch) { stream in
                        for try await note in stream {
                            events.append(Event(receivedAt: Date(), payload: note.payload))
                            if Task.isCancelled { break }
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    listenError = PostgresErrorMessage.describe(error)
                }
            }
            listening = false
        }
    }

    private func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        listening = false
    }

    private func sendNotify() {
        let ch = trimmedChannel
        guard !ch.isEmpty else { return }
        let payload = composerPayload
        Task {
            let result = await AdminActions.notify(channel: ch, payload: payload, service: service)
            switch result {
            case .success:
                composerPayload = ""
            case .failure(let err):
                listenError = err.localizedDescription
            }
        }
    }
}
