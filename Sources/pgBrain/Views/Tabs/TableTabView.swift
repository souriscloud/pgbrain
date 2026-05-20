import AppKit
import SwiftUI
import Observation
import PostgresNIO

/// Container view for a single table tab. Owns the row loader and switches
/// between loading / error / loaded grid states.
struct TableTabView: View {
    let table: TableNode
    let service: ConnectionService

    @State private var loader: RowsLoader

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
        _loader = State(initialValue: RowsLoader(table: table, service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: table.id) {
            await loader.load()
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
            Text(table.qualifiedName)
                .font(.system(.body, design: .monospaced).weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(table.columns.count) columns")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Group {
                switch loader.state {
                case .loaded(let page):
                    HStack(spacing: 6) {
                        Text(page.truncated ? "\(page.rows.count)+ rows" : "\(page.rows.count) rows")
                        Text(String(format: "%.0f ms", page.elapsed * 1000))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .loading:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("loading…").font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
                }
            }
            Button {
                Task { await loader.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading rows…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let page):
            if page.rows.isEmpty {
                VStack(spacing: Tokens.Spacing.sm) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No rows in \(table.qualifiedName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DataGridView(page: page)
            }
        case .error(let message):
            VStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text("Couldn't load rows")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { Task { await loader.load() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
@Observable
final class RowsLoader {
    enum State {
        case idle
        case loading
        case loaded(RowsFetcher.Page)
        case error(String)
    }

    let table: TableNode
    @ObservationIgnored let service: ConnectionService
    private(set) var state: State = .idle

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
    }

    func load() async {
        guard let client = service.client else {
            state = .error("Not connected.")
            return
        }
        state = .loading
        do {
            let page = try await RowsFetcher.first(1000, from: table, client: client)
            state = .loaded(page)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
