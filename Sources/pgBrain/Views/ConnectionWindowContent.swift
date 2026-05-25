import SwiftUI

struct ConnectionWindowContent: View {
    @Bindable var service: ConnectionService

    private var appearance: ConnectionAppearance {
        ConnectionAppearance(connection: service.connection)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thin coloured stripe at the very top — connection colour, or
            // red on production. Disappears entirely for an uncoloured,
            // non-prod connection.
            if appearance.connection.colorTag != .none || appearance.connection.isProduction {
                Rectangle()
                    .fill(appearance.emphasized)
                    .frame(height: 3)
            }
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusFooter(service: service)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var mainArea: some View {
        switch service.state {
        case .idle, .connecting:
            connectingPlaceholder
        case .connected:
            connectedWorkspace
        case .error(let message):
            errorPlaceholder(message: message)
        case .closed:
            closedPlaceholder
        }
    }

    @ViewBuilder
    private var connectedWorkspace: some View {
        HSplitView {
            sidebarPane
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)
            workspacePane
                .frame(minWidth: 400, maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var sidebarPane: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().opacity(0.6)
            switch service.schemaState {
            case .loaded:
                SidebarOutlineView(snapshot: service.schema) { table in
                    service.workspace.openTable(table)
                }
            case .loading, .idle:
                VStack(spacing: Tokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading schema…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: Tokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Schema load failed")
                        .font(.callout)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") { Task { await service.loadSchema() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appearance.connection.colorTag == .none
                      ? Color.secondary.opacity(0.25)
                      : appearance.connection.colorTag.swiftUIColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(appearance.connection.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(appearance.connection.database.isEmpty ? appearance.connection.host : appearance.connection.database)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if appearance.connection.isProduction {
                Text("PROD")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Tokens.Brand.danger)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Menu {
                Section("pg_dump") {
                    ForEach(PgDumpCLI.Format.allCases) { fmt in
                        Button("Dump as \(fmt.rawValue)") { runPgDump(format: fmt) }
                    }
                }
                Divider()
                Button("Reload schema") { Task { await service.loadSchema() } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Connection actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(appearance.emphasized.opacity(0.08))
    }

    private func runPgDump(format: PgDumpCLI.Format) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let ext = format.fileExtension
        let stem = service.connection.database.isEmpty ? service.connection.name : service.connection.database
        panel.nameFieldStringValue = ext.isEmpty ? stem : "\(stem).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let conn = service.connection
        let password = Keychain.password(for: conn.id) ?? ""
        let op = service.operations.begin(
            kind: .export,
            summary: "pg_dump → \(url.lastPathComponent)"
        )
        let tracker = service.operations
        Task {
            do {
                _ = try await PgDumpCLI.dump(
                    connection: conn,
                    password: password,
                    format: format,
                    destination: url
                )
                tracker.finish(op, status: .succeeded)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "pg_dump failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @ViewBuilder
    private var workspacePane: some View {
        VStack(spacing: 0) {
            TabStripView(workspace: service.workspace, appearance: appearance)
            Divider()
            if let selected = service.workspace.selectedTab {
                switch selected.kind {
                case .table(let table):
                    TableTabView(table: table, service: service)
                        .id(table.id)
                case .scratchpad(let pad):
                    ScratchpadView(scratchpad: pad, service: service)
                        .id(pad.id)
                }
            } else {
                emptyWorkspace
            }
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "tablecells")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Pick a table from the sidebar")
                .font(.headline)
            Text("Double-click any table or view to load its first 1,000 rows, or press ⌘N to open a SQL scratchpad.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectingPlaceholder: some View {
        VStack(spacing: Tokens.Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(service.connection.name)…")
                .font(.headline)
            Text("\(service.connection.username)@\(service.connection.host):\(service.connection.port)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPlaceholder(message: String) -> some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't connect")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.xl)
                .textSelection(.enabled)
            Button { service.retry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .controlSize(.large)
            .padding(.top, Tokens.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closedPlaceholder: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Disconnected").font(.headline)
            Button("Reconnect") { service.start() }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusFooter: View {
    @Bindable var service: ConnectionService
    @State private var opsPopoverShown = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            statusDot
            Text(stateLabel)
                .font(.caption.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            if service.connection.colorTag != .none {
                Circle()
                    .fill(service.connection.colorTag.swiftUIColor)
                    .frame(width: 8, height: 8)
                    .help("Connection color tag")
            }
            if service.connection.isProduction {
                Text("PRODUCTION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Tokens.Brand.danger)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(targetDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            opsIndicator
            if case .connected(_, let since) = service.state {
                Text("connected at \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var opsIndicator: some View {
        let running = service.operations.runningCount
        let total = service.operations.operations.count
        let visible = running > 0 || total > 0
        return Button {
            opsPopoverShown.toggle()
        } label: {
            HStack(spacing: 4) {
                if running > 0 {
                    ProgressView().controlSize(.mini)
                    Text("\(running) running")
                        .font(.caption.weight(.medium))
                } else if total > 0 {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .help("Show running operations")
        .popover(isPresented: $opsPopoverShown, arrowEdge: .bottom) {
            OperationsPopover(operations: service.operations)
        }
    }

    private var targetDescription: String {
        let conn = service.connection
        let db = conn.database.isEmpty ? "—" : conn.database
        return "\(conn.username)@\(conn.host):\(conn.port) · \(db)"
    }

    private var stateLabel: String {
        switch service.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error: return "Error"
        case .closed: return "Closed"
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch service.state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .error: return .red
        case .closed: return .secondary
        }
    }
}
