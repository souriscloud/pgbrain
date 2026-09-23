import SwiftUI

/// Sheet that diffs the current connection's schema against another open
/// connection's schema. Side-by-side counts, then drills into per-table
/// column changes.
struct SchemaDiffView: View {
    let source: ConnectionService
    let onClose: () -> Void

    @State private var selectedTarget: Target?
    @State private var diff: SchemaDiff.Result?
    @State private var status: String?

    /// One open window, identified by (connection, database): sibling
    /// windows of the same connection sit on different databases, and the
    /// diff must read exactly the one picked.
    struct Target: Hashable {
        let connectionID: UUID
        let database: String
        let username: String
        let label: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let diff {
                content(diff)
            } else if let status {
                placeholder(status)
            } else {
                placeholder("Pick a connection to compare with.")
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 540)
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "rectangle.split.2x1.fill")
            Text("Diff schemas — left: \(source.connection.name)")
                .font(.headline)
            Spacer()
            Picker("Right", selection: $selectedTarget) {
                Text("Pick…").tag(Target?.none)
                ForEach(eligibleTargets, id: \.self) { t in
                    Text(t.label).tag(Target?.some(t))
                }
            }
            .frame(width: 240)
            Button("Compare") { Task { await compare() } }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
                .disabled(selectedTarget == nil)
        }
        .padding(Tokens.Spacing.md)
    }

    private var eligibleTargets: [Target] {
        guard let manager = AppDelegate.shared?.windowManager else { return [] }
        return manager.entries.compactMap { entry in
            guard let service = entry.service, service !== source else { return nil }
            let db = entry.resolvedDatabase
            return Target(connectionID: entry.connectionID, database: service.connection.database,
                          username: service.connection.username,
                          label: db.isEmpty ? service.connection.name : "\(service.connection.name) · \(db)")
        }
    }

    private func content(_ diff: SchemaDiff.Result) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                summary(diff)
                if !diff.addedTables.isEmpty {
                    section(title: "Added tables (only on right)", color: .green) {
                        ForEach(diff.addedTables) { t in
                            Text(t.qualifiedName).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if !diff.removedTables.isEmpty {
                    section(title: "Removed tables (only on left)", color: .red) {
                        ForEach(diff.removedTables) { t in
                            Text(t.qualifiedName).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if !diff.changedTables.isEmpty {
                    section(title: "Changed tables", color: .orange) {
                        ForEach(diff.changedTables) { ch in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ch.left.qualifiedName)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                ForEach(ch.addedColumns) { c in
                                    Label("+ \(c.name) \(c.typeName)", systemImage: "plus.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                ForEach(ch.removedColumns) { c in
                                    Label("− \(c.name) \(c.typeName)", systemImage: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                ForEach(ch.changedColumns) { c in
                                    Label("\(c.name): \(c.leftType)\(c.leftNullable ? "?" : "") → \(c.rightType)\(c.rightNullable ? "?" : "")", systemImage: "arrow.left.arrow.right")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(Tokens.Spacing.md)
        }
    }

    private func summary(_ diff: SchemaDiff.Result) -> some View {
        HStack(spacing: Tokens.Spacing.lg) {
            stat(label: "added", value: diff.addedTables.count, color: .green)
            stat(label: "removed", value: diff.removedTables.count, color: .red)
            stat(label: "changed", value: diff.changedTables.count, color: .orange)
            Spacer()
        }
    }

    private func stat(label: String, value: Int, color: Color) -> some View {
        VStack {
            Text("\(value)").font(.title2.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(title: String, color: Color, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            body()
        }
    }

    private func placeholder(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(msg).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close", action: onClose)
        }
        .padding(Tokens.Spacing.md)
    }

    @MainActor
    private func compare() async {
        guard let target = selectedTarget,
              let other = AppDelegate.shared?.windowManager.service(
                  for: target.connectionID, database: target.database, username: target.username) else {
            status = "Target connection isn't open."
            return
        }
        if case .loaded = other.schemaState {
            diff = SchemaDiff.diff(left: source.schema, right: other.schema)
            status = nil
            return
        }
        status = "Waiting for target schema to load…"
        await other.loadSchema()
        diff = SchemaDiff.diff(left: source.schema, right: other.schema)
        status = nil
    }
}
