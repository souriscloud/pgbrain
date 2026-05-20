import SwiftUI

struct ConnectionWindowContent: View {
    @Bindable var service: ConnectionService

    var body: some View {
        VStack(spacing: 0) {
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
        case .connected(let version, _):
            connectedPlaceholder(version: version)
        case .error(let message):
            errorPlaceholder(message: message)
        case .closed:
            closedPlaceholder
        }
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

    private func connectedPlaceholder(version: String) -> some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Tokens.Brand.primary)
            Text("Connected")
                .font(.title2.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.xl)
                .textSelection(.enabled)
            Text("Sidebar with schemas + tables lands in iter-3. SQL scratchpad in iter-4.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Tokens.Spacing.sm)
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

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            statusDot
            Text(stateLabel)
                .font(.caption.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
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
            if case .connected(_, let since) = service.state {
                Text("connected at \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
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
