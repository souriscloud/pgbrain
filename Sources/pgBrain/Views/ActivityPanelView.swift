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

    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case locks    = "Locks"
        case indexes  = "Indexes"
        case slow     = "Slow queries"
        case sizes    = "Sizes"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .sessions
    @State private var rows: [ActivityRow] = []
    @State private var lockRows: [LockRow] = []
    @State private var indexRows: [IndexUsageRow] = []
    @State private var stmtRows: [StatementStatRow] = []
    @State private var stmtSort: StatementStatsFetcher.SortKey = .total
    @State private var stmtInstalled: Bool? = nil
    @State private var sizes: SizeStats? = nil
    @State private var error: String?
    @State private var loading = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var pendingTerminate: ActivityRow?

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider()
            content
        }
        .frame(width: 880, height: 580)
        .task { startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: tab) { _, _ in Task { await refreshOnce() } }
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
            Text(countSummary)
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

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.bottom, 8)
    }

    private var countSummary: String {
        switch tab {
        case .sessions: return "(\(rows.count) sessions)"
        case .locks:    return "(\(lockRows.count) locks)"
        case .indexes:  return "(\(indexRows.count) indexes)"
        case .slow:     return stmtInstalled == false ? "(extension not installed)" : "(top \(stmtRows.count))"
        case .sizes:    return sizes.map { "(\(formatSize($0.databaseBytes)) total)" } ?? ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .sessions: sessionsContent
        case .locks:    locksContent
        case .indexes:  indexesContent
        case .slow:     slowContent
        case .sizes:    sizesContent
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
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

    @ViewBuilder
    private var locksContent: some View {
        if lockRows.isEmpty && !loading {
            VStack(spacing: 6) {
                Image(systemName: "lock.open")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("No locks held by other sessions")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(lockRows) {
                TableColumn("PID") { Text("\($0.pid)").font(.system(.caption, design: .monospaced)) }
                    .width(min: 50, ideal: 60)
                TableColumn("Granted") { row in
                    HStack(spacing: 5) {
                        Circle().fill(row.granted ? .green : .orange).frame(width: 7, height: 7)
                        Text(row.granted ? "held" : "waiting")
                            .font(.system(.caption, design: .monospaced))
                    }
                }.width(min: 70, ideal: 80)
                TableColumn("Type") { Text($0.lockType ?? "—").font(.system(.caption, design: .monospaced)) }
                    .width(min: 80, ideal: 110)
                TableColumn("Mode") { Text($0.mode ?? "—").font(.system(.caption, design: .monospaced)) }
                    .width(min: 80, ideal: 120)
                TableColumn("Relation") { Text($0.relation ?? "—").font(.system(.caption, design: .monospaced)) }
                    .width(min: 100, ideal: 200)
                TableColumn("App / User") { row in
                    Text([row.application, row.user].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }.width(min: 100, ideal: 150)
                TableColumn("Query") { row in
                    Text((row.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var indexesContent: some View {
        if indexRows.isEmpty && !loading {
            VStack(spacing: 6) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("No user indexes — fresh database?")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(indexRows) {
                TableColumn("Schema.Table") { row in
                    Text("\(row.schema).\(row.table)")
                        .font(.system(.caption, design: .monospaced))
                }.width(min: 120, ideal: 180)
                TableColumn("Index") { row in
                    HStack(spacing: 5) {
                        if row.isUnused {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Unused — 0 scans, not constraint-backed")
                        }
                        Text(row.index)
                            .font(.system(.caption, design: .monospaced))
                    }
                }.width(min: 130, ideal: 200)
                TableColumn("Scans") { row in
                    Text(formatInt(row.scans))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(row.isUnused ? .orange : .secondary)
                }.width(min: 60, ideal: 70)
                TableColumn("Tup Read") { row in
                    Text(formatInt(row.tuplesRead))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }.width(min: 70, ideal: 90)
                TableColumn("Tup Fetched") { row in
                    Text(formatInt(row.tuplesFetched))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }.width(min: 70, ideal: 90)
                TableColumn("Size") { row in
                    Text(formatSize(row.sizeBytes))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }.width(min: 70, ideal: 80)
            }
        }
    }

    // MARK: - Slow queries (pg_stat_statements)

    @ViewBuilder
    private var slowContent: some View {
        if stmtInstalled == false {
            VStack(spacing: 8) {
                Image(systemName: "wrench.adjustable")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("pg_stat_statements isn't installed in this database").font(.callout)
                Text("As a superuser, run:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("CREATE EXTENSION pg_stat_statements;")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
                Text("…and add 'pg_stat_statements' to shared_preload_libraries in postgresql.conf, then restart.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Re-check") { Task { await refreshOnce() } }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 0) {
                HStack {
                    Picker("Sort by", selection: $stmtSort) {
                        ForEach(StatementStatsFetcher.SortKey.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    Spacer()
                    Button {
                        Task {
                            guard let client = service.client else { return }
                            _ = try? await StatementStatsFetcher.reset(client: client)
                            await refreshOnce()
                        }
                    } label: {
                        Label("Reset stats", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Calls pg_stat_statements_reset() — needs adequate grants")
                }
                .padding(.horizontal, Tokens.Spacing.md)
                .padding(.bottom, 6)
                .onChange(of: stmtSort) { _, _ in Task { await refreshOnce() } }

                Table(stmtRows) {
                    TableColumn("Calls") { row in
                        Text(formatInt(row.calls))
                            .font(.system(.caption, design: .monospaced))
                    }.width(min: 60, ideal: 70)
                    TableColumn("Total ms") { row in
                        Text(String(format: "%.1f", row.totalMs))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(row.totalMs > 60_000 ? .orange : .primary)
                    }.width(min: 70, ideal: 90)
                    TableColumn("Mean ms") { row in
                        Text(String(format: "%.2f", row.meanMs))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(row.meanMs > 100 ? .orange : .secondary)
                    }.width(min: 70, ideal: 90)
                    TableColumn("Rows") { row in
                        Text(formatInt(row.rows))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }.width(min: 60, ideal: 70)
                    TableColumn("Query") { row in
                        Text(row.query)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Size dashboard

    @ViewBuilder
    private var sizesContent: some View {
        if let sizes {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                    HStack(spacing: Tokens.Spacing.lg) {
                        sizeKpi("Database", formatSize(sizes.databaseBytes))
                        sizeKpi("Top tables", "\(sizes.tables.count)")
                        sizeKpi("Top indexes", "\(sizes.indexes.count)")
                    }
                    .padding(.horizontal, Tokens.Spacing.md)
                    .padding(.top, Tokens.Spacing.md)

                    sizeSection("Tables by total size") {
                        Table(sizes.tables) {
                            TableColumn("Schema.Table") { row in
                                Text("\(row.schema).\(row.table)")
                                    .font(.system(.caption, design: .monospaced))
                            }.width(min: 140, ideal: 220)
                            TableColumn("Total") { row in
                                Text(formatSize(row.totalBytes))
                                    .font(.system(.caption, design: .monospaced))
                            }.width(min: 70, ideal: 80)
                            TableColumn("Heap+TOAST") { row in
                                Text(formatSize(row.tableBytes))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }.width(min: 80, ideal: 100)
                            TableColumn("Indexes") { row in
                                Text(formatSize(row.indexBytes))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }.width(min: 70, ideal: 80)
                            TableColumn("~Rows") { row in
                                Text(formatInt(row.rowEstimate))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }.width(min: 70, ideal: 90)
                        }
                        .frame(minHeight: 180, maxHeight: 280)
                    }
                    sizeSection("Indexes by size") {
                        Table(sizes.indexes) {
                            TableColumn("Schema.Table") { row in
                                Text("\(row.schema).\(row.table)")
                                    .font(.system(.caption, design: .monospaced))
                            }.width(min: 140, ideal: 200)
                            TableColumn("Index") { row in
                                Text(row.index)
                                    .font(.system(.caption, design: .monospaced))
                            }.width(min: 140, ideal: 200)
                            TableColumn("Size") { row in
                                Text(formatSize(row.bytes))
                                    .font(.system(.caption, design: .monospaced))
                            }.width(min: 70, ideal: 80)
                        }
                        .frame(minHeight: 180, maxHeight: 240)
                    }
                    Spacer(minLength: Tokens.Spacing.md)
                }
            }
        } else if loading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No size data yet").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sizeKpi(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold))
        }
    }

    @ViewBuilder
    private func sizeSection<Body: View>(_ title: String, @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
                .padding(.horizontal, Tokens.Spacing.md)
            content()
                .padding(.horizontal, Tokens.Spacing.md)
        }
    }

    private func formatInt(_ n: Int64) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000     { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000         { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
    private func formatSize(_ bytes: Int64) -> String {
        let v = Double(bytes)
        if v >= 1_073_741_824 { return String(format: "%.1fGB", v / 1_073_741_824) }
        if v >= 1_048_576     { return String(format: "%.1fMB", v / 1_048_576) }
        if v >= 1_024         { return String(format: "%.1fkB", v / 1_024) }
        return "\(bytes)B"
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
            error = "Not connected."; rows = []; lockRows = []; indexRows = []
            stmtRows = []; sizes = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            switch tab {
            case .sessions: rows = try await ActivityFetcher.fetch(client: client)
            case .locks:    lockRows = try await LockFetcher.fetch(client: client)
            case .indexes:  indexRows = try await IndexUsageFetcher.fetch(client: client)
            case .slow:
                let installed = await StatementStatsFetcher.isInstalled(client: client)
                stmtInstalled = installed
                if installed {
                    stmtRows = try await StatementStatsFetcher.fetch(sort: stmtSort, client: client)
                } else {
                    stmtRows = []
                }
            case .sizes:
                sizes = try await SizeStatsFetcher.fetch(client: client)
            }
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
