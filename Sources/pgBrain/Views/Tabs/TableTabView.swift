import AppKit
import SwiftUI
import Observation
import PostgresNIO

/// Container view for a single table tab. Owns the row loader, the per-grid
/// edit buffer, and switches between loading / error / loaded grid states.
struct TableTabView: View {
    let table: TableNode
    let service: ConnectionService

    @State private var loader: RowsLoader
    @State private var showApplyErrorPopover = false

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
            if !table.isEditable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help(table.kind == .table
                        ? "No primary key; editing disabled."
                        : "Views aren't editable.")
            }
            Spacer()
            editControls
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
            Menu {
                Section("Export full table (streaming)") {
                    ForEach(Exporter.Format.allCases) { fmt in
                        Button(fmt.uiLabel) { exportFullTable(as: fmt) }
                    }
                }
                if case .loaded(let page) = loader.state, !page.rows.isEmpty {
                    Divider()
                    Section("Export visible page") {
                        ForEach(Exporter.Format.allCases) { fmt in
                            Button(fmt.uiLabel) { exportPage(page, as: fmt) }
                        }
                    }
                }
                Divider()
                Button("Import CSV into this table…", action: importCSV)
            } label: {
                Image(systemName: "tray.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Import / Export")
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func exportFullTable(as format: Exporter.Format) {
        guard let client = service.client else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(table.schema).\(table.name).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(
            kind: .export,
            summary: "Export \(table.qualifiedName) → \(url.lastPathComponent)"
        )
        let tracker = service.operations
        let opID = op.id
        Task {
            do {
                _ = try await Exporter.exportTable(
                    table,
                    format: format,
                    destination: url,
                    client: client,
                    tracker: tracker,
                    operationID: opID
                )
                tracker.finish(op, status: .succeeded)
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }

    private func exportPage(_ page: RowsFetcher.Page, as format: Exporter.Format) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(table.schema).\(table.name)_page.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? Exporter.exportPage(page, format: format, destination: url, tableNameHint: table.name)
        }
    }

    private func importCSV() {
        guard let client = service.client else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let op = service.operations.begin(
            kind: .importJob,
            summary: "Import \(url.lastPathComponent) → \(table.qualifiedName)"
        )
        let tracker = service.operations
        let opID = op.id
        Task {
            do {
                _ = try await Importer.importCSV(
                    into: table,
                    from: url,
                    client: client,
                    tracker: tracker,
                    operationID: opID
                )
                tracker.finish(op, status: .succeeded)
                await loader.load()
            } catch is CancellationError {
                tracker.finish(op, status: .cancelled)
            } catch {
                tracker.finish(op, status: .failed(error.localizedDescription))
            }
        }
    }

    @ViewBuilder
    private var editControls: some View {
        if let applyError = loader.applyError {
            Button {
                showApplyErrorPopover = true
            } label: {
                Label {
                    Text("Apply failed")
                        .font(.caption.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Click to see the full error message")
            .popover(isPresented: $showApplyErrorPopover, arrowEdge: .bottom) {
                ApplyErrorPopover(message: applyError)
            }
        }
        if let applySuccess = loader.applySuccess {
            Label(applySuccess, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .transition(.opacity)
        }
        if loader.editBuffer.isDirty {
            Text("\(loader.editBuffer.dirtyCount) pending")
                .font(.caption)
                .foregroundStyle(.orange)
            Button {
                loader.revert()
            } label: {
                Text("Revert")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(loader.isApplying)

            Button {
                Task { await loader.apply() }
            } label: {
                if loader.isApplying {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Applying…")
                    }
                } else {
                    Text("Apply")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Tokens.Brand.primary)
            .disabled(loader.isApplying)
        }
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
                DataGridView(
                    page: page,
                    editBuffer: table.isEditable ? loader.editBuffer : nil,
                    appliedHighlights: loader.appliedHighlights
                )
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

    /// Per-tab pending-edit buffer; lives as long as the loader does.
    let editBuffer = EditBuffer()
    private(set) var isApplying = false
    private(set) var applyError: String?
    /// Short-lived green message after a successful Apply.
    private(set) var applySuccess: String?
    /// Cells that were just applied — rendered with a fading green tint
    /// in the grid so the user can see exactly what landed. Cleared on a
    /// timer so the highlight doesn't loiter.
    private(set) var appliedHighlights: Set<EditBuffer.CellKey> = []

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
        editBuffer.clear()
        applyError = nil
        let limit = AppSettings.shared.defaultRowLimit
        do {
            let page = try await RowsFetcher.first(limit, from: table, client: client)
            state = .loaded(page)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func revert() {
        editBuffer.clear()
        applyError = nil
    }

    func apply() async {
        guard let client = service.client else {
            applyError = "Not connected."
            return
        }
        guard case .loaded(var page) = state else { return }
        let pending = editBuffer.editsByRow()
        guard !pending.isEmpty else { return }

        let edits: [UpdateApplier.Edit] = pending.map { rowEdits in
            let cells: [UpdateApplier.CellChange] = rowEdits.cells.map { c in
                UpdateApplier.CellChange(column: page.columns[c.column], newValue: c.value)
            }
            return UpdateApplier.Edit(rowIndex: rowEdits.row, cells: cells)
        }

        isApplying = true
        applyError = nil
        applySuccess = nil
        defer { isApplying = false }
        let op = service.operations.begin(
            kind: .update,
            summary: "UPDATE \(table.qualifiedName) (\(edits.count) row\(edits.count == 1 ? "" : "s"))"
        )
        let started = Date()
        do {
            try await UpdateApplier.apply(
                edits: edits,
                table: table,
                originalRows: page.rows,
                client: client,
                operationID: op.id,
                tracker: service.operations
            )
            service.operations.finish(op, status: .succeeded)
            // Splice the applied values into the in-memory page so the grid
            // shows the new state without a round-trip refetch.
            for edit in edits {
                for cell in edit.cells {
                    page.rows[edit.rowIndex][page.columns.firstIndex(where: { $0.name == cell.column.name }) ?? 0] = cell.newValue
                }
            }
            state = .loaded(page)
            let elapsed = Date().timeIntervalSince(started)
            applySuccess = "Applied \(edits.count) row\(edits.count == 1 ? "" : "s") · \(String(format: "%.0f ms", elapsed * 1000))"
            // Flash every applied (row, col) green in the grid for a few
            // seconds before fading.
            var highlights: Set<EditBuffer.CellKey> = []
            for edit in edits {
                for cell in edit.cells {
                    if let colIdx = page.columns.firstIndex(where: { $0.name == cell.column.name }) {
                        highlights.insert(EditBuffer.CellKey(row: edit.rowIndex, column: colIdx))
                    }
                }
            }
            appliedHighlights = highlights
            editBuffer.clear()
            let snapshot = applySuccess
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if self?.applySuccess == snapshot {
                    self?.applySuccess = nil
                    self?.appliedHighlights = []
                }
            }
        } catch is CancellationError {
            applyError = "Cancelled"
            service.operations.finish(op, status: .cancelled)
        } catch {
            // Unwrap PostgresTransactionError / PSQLError into a real
            // server message — by default they read "error 1" / opaque
            // code, which isn't actionable.
            let message = PostgresErrorMessage.describe(error)
            applyError = message
            service.operations.finish(op, status: .failed(message))
        }
    }
}

/// Click-to-open popover showing the full multi-line apply error so the
/// user can actually read the server's reason (and copy it).
private struct ApplyErrorPopover: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("Apply failed").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Text("Transaction rolled back. Your pending edits are still here — fix and Apply again, or Revert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.md)
        .frame(width: 460)
    }
}
