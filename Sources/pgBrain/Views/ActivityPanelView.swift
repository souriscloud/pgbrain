import SwiftUI
import PostgresNIO

/// Live `pg_stat_activity` view. Refreshes every 3s while the sheet
/// is up; rows can be cancelled (pg_cancel_backend) or terminated
/// (pg_terminate_backend, with a confirm). State colour codes:
///
///   - **active**  → green
///   - **idle in transaction** → orange (these hold locks)
///   - **idle in transaction (aborted)** → red
///   - **idle** → secondary
///   - anything else → secondary
struct ActivityPanelView: View {
    let service: ConnectionService
    let onClose: () -> Void

    @State private var rows: [ActivityRow] = []
    @State private var error: String?
    @State private var loading = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var pendingTerminate: ActivityRow?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 880, height: 580)
        .task { startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
        .confirmationDialog(
            "Terminate session PID \(pendingTerminate?.pid ?? 0)?",
            isPresented: Binding(
                get: { pendingTerminate != nil },
                set: { if !$0 { pendingTerminate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Terminate", role: .destructive) {
                if let pid = pendingTerminate?.pid { terminate(pid: pid) }
                pendingTerminate = nil
            }
            Button("Cancel", role: .cancel) { pendingTerminate = nil }
        } message: {
            Text("Forcibly disconnects the session. Anything mid-flight rolls back.")
        }
    }

    private var header: some View {
        HStack {
            Text("Activity").font(.title3.weight(.semibold))
            Text("(\(rows.count) sessions)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Button { Task { await refreshOnce() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24)).foregroundStyle(.orange)
                Text("Couldn't load activity").font(.headline)
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty && !loading {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("No other sessions on this database")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn("PID") { row in
                    Text("\(row.pid)").font(.system(.caption, design: .monospaced))
                }.width(min: 50, ideal: 60)
                TableColumn("State") { row in
                    HStack(spacing: 5) {
                        Circle().fill(stateColor(row.state)).frame(width: 7, height: 7)
                        Text(row.state ?? "—")
                            .font(.system(.caption, design: .monospaced))
                    }
                }.width(min: 100, ideal: 160)
                TableColumn("Elapsed") { row in
                    Text(elapsedLabel(row))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }.width(min: 70, ideal: 90)
                TableColumn("Wait") { row in
                    Text([row.waitEventType, row.waitEvent].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
                TableColumn("App / User") { row in
                    Text([row.application, row.user].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }.width(min: 100, ideal: 160)
                TableColumn("Query") { row in
                    Text((row.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                TableColumn("") { row in
                    HStack(spacing: 6) {
                        Button {
                            cancel(pid: row.pid)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .help("Cancel current query (pg_cancel_backend)")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            pendingTerminate = row
                        } label: {
                            Image(systemName: "bolt.slash")
                                .help("Terminate session (pg_terminate_backend)")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }.width(min: 60, ideal: 60)
            }
        }
    }

    // MARK: - Refresh + actions

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await refreshOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                await refreshOnce()
            }
        }
    }

    private func refreshOnce() async {
        guard let client = service.client else {
            error = "Not connected."; rows = []; return
        }
        loading = true
        defer { loading = false }
        do {
            rows = try await ActivityFetcher.fetch(client: client)
            error = nil
        } catch {
            self.error = PostgresErrorMessage.describe(error)
        }
    }

    private func cancel(pid: Int32) {
        guard let client = service.client else { return }
        Task {
            _ = try? await ActivityFetcher.cancel(pid: pid, client: client)
            await refreshOnce()
        }
    }

    private func terminate(pid: Int32) {
        guard let client = service.client else { return }
        Task {
            _ = try? await ActivityFetcher.terminate(pid: pid, client: client)
            await refreshOnce()
        }
    }

    // MARK: - Cosmetic helpers

    private func stateColor(_ state: String?) -> Color {
        switch state {
        case "active":                              return .green
        case "idle in transaction":                 return .orange
        case "idle in transaction (aborted)":       return .red
        case "idle":                                return .secondary
        default:                                    return .secondary
        }
    }

    private func elapsedLabel(_ row: ActivityRow) -> String {
        let secs = row.queryElapsed ?? row.stateElapsed
        guard let s = secs else { return "—" }
        if s < 1 { return String(format: "%.0fms", s * 1000) }
        if s < 60 { return String(format: "%.1fs", s) }
        if s < 3600 { return String(format: "%dm %ds", Int(s) / 60, Int(s) % 60) }
        return String(format: "%dh %dm", Int(s) / 3600, (Int(s) % 3600) / 60)
    }
}
