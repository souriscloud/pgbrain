import SwiftUI

/// Sheet that drives `CrossDBCopy.execute`. Picks a target connection (open
/// or known), a target schema/table, a strategy, and a (default 1:1)
/// column mapping. Submitting fires the copy on a background task and
/// surfaces progress through the iter-7 ops popover.
struct CrossDBCopyView: View {
    let source: TableNode
    let sourceService: ConnectionService

    @Environment(\.dismiss) private var dismiss
    @State private var store = ConnectionStore.shared
    @State private var selectedTargetID: UUID?
    @State private var targetSchema: String = ""
    @State private var targetTable: String = ""
    @State private var strategy: CrossDBCopy.Strategy = .append
    @State private var mappings: [Mapping] = []
    @State private var statusMessage: String?
    @State private var submitting = false

    private struct Mapping: Identifiable {
        let id = UUID()
        let sourceColumn: ColumnNode
        var include: Bool = true
        var targetName: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Copy \(source.qualifiedName) to…")
                .font(.title3.weight(.semibold))
            Form {
                Section("Target") {
                    Picker("Connection", selection: $selectedTargetID) {
                        Text("Pick a connection").tag(UUID?.none)
                        ForEach(otherConnections) { conn in
                            Text(label(for: conn)).tag(UUID?.some(conn.id))
                        }
                    }
                    TextField("Schema", text: $targetSchema)
                    TextField("Table", text: $targetTable)
                    Picker("Strategy", selection: $strategy) {
                        ForEach(CrossDBCopy.Strategy.allCases) { s in
                            Text(s.uiLabel).tag(s)
                        }
                    }
                }
                Section("Columns") {
                    ForEach($mappings) { $m in
                        HStack {
                            Toggle("", isOn: $m.include)
                                .labelsHidden()
                            Text(m.sourceColumn.name)
                                .font(.system(.body, design: .monospaced))
                            Text("→").foregroundStyle(.tertiary)
                            TextField("target column", text: $m.targetName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusMessage.hasPrefix("Failed") ? .red : .secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(submitting ? "Copying…" : "Start Copy") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
                    .disabled(!canSubmit)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: 560, height: 540)
        .onAppear {
            if mappings.isEmpty {
                mappings = source.columns.map { Mapping(sourceColumn: $0, targetName: $0.name) }
            }
            if targetSchema.isEmpty { targetSchema = source.schema }
            if targetTable.isEmpty { targetTable = source.name }
        }
    }

    private var otherConnections: [Connection] {
        store.connections.filter { $0.id != sourceService.connection.id }
    }

    private func label(for connection: Connection) -> String {
        let suffix = AppDelegate.shared?.windowManager.service(for: connection.id) != nil ? " · open" : ""
        let prod = connection.isProduction ? " · PROD" : ""
        return "\(connection.name)\(prod)\(suffix)"
    }

    private var canSubmit: Bool {
        !submitting
            && selectedTargetID != nil
            && !targetSchema.isEmpty
            && !targetTable.isEmpty
            && mappings.contains(where: { $0.include })
    }

    private func submit() async {
        guard let id = selectedTargetID,
              let targetConn = store.connections.first(where: { $0.id == id }),
              let client = sourceService.client
        else { return }

        let endpoint: CrossDBCopy.TargetEndpoint
        if let liveService = AppDelegate.shared?.windowManager.service(for: id),
           let liveClient = liveService.client {
            endpoint = .existing(liveClient)
        } else {
            let pw = Keychain.password(for: targetConn.id) ?? ""
            endpoint = .transient(targetConn, password: pw)
        }

        let included = mappings.filter { $0.include }
        let planMappings = included.map {
            CrossDBCopy.Mapping(sourceColumn: $0.sourceColumn, targetColumnName: $0.targetName)
        }
        let plan = CrossDBCopy.Plan(
            source: source,
            sourceClient: client,
            target: endpoint,
            targetSchema: targetSchema,
            targetTable: targetTable,
            strategy: strategy,
            mappings: planMappings
        )

        submitting = true
        statusMessage = "Copy started — track progress in the operations popover."
        let op = sourceService.operations.begin(
            kind: .export,
            summary: "Copy \(source.qualifiedName) → \(targetConn.name).\(targetSchema).\(targetTable)"
        )
        let tracker = sourceService.operations
        let opID = op.id

        do {
            let stats = try await CrossDBCopy.execute(plan: plan, tracker: tracker, operationID: opID)
            op.summary += " · \(stats.rowsCopied) row\(stats.rowsCopied == 1 ? "" : "s")"
            tracker.finish(op, status: .succeeded)
            statusMessage = "Copied \(stats.rowsCopied) rows in \(String(format: "%.1fs", stats.elapsed))."
            submitting = false
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch is CancellationError {
            tracker.finish(op, status: .cancelled)
            statusMessage = "Cancelled."
            submitting = false
        } catch {
            tracker.finish(op, status: .failed(error.localizedDescription))
            statusMessage = "Failed: \(error.localizedDescription)"
            submitting = false
        }
    }
}
