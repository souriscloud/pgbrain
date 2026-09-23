import AppKit
import SwiftUI

/// Drives the "Change type" sheet in the Structure pane.
struct AlterTypeRequest: Identifiable {
    let id = UUID()
    let column: String
    let currentType: String
}

struct StructurePane: View {
    let state: InspectorLoader.State
    let onRetry: () -> Void
    var service: ConnectionService? = nil
    var onReload: (() -> Void)? = nil

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading structure…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let snap, _):
            StructureBody(snapshot: snap, service: service, onReload: onReload)
        case .error(let msg):
            InspectorError(msg: msg, retry: onRetry)
        }
    }
}

struct StructureBody: View {
    let snapshot: TableInspector.Snapshot
    var service: ConnectionService? = nil
    var onReload: (() -> Void)? = nil

    @State private var showAddColumn = false
    @State private var renameColumnTarget: IdentifiedString?
    @State private var alterTypeTarget: AlterTypeRequest?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                if let comment = snapshot.comment {
                    Text(comment)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Tokens.Spacing.sm)
                }

                section("Columns") {
                    StructureColumnsTable(
                        columns: snapshot.columns,
                        pkColumns: pkColumnNames(snapshot),
                        canEdit: service != nil,
                        onRename: { renameColumnTarget = IdentifiedString(id: $0) },
                        onAlterType: { col in
                            alterTypeTarget = AlterTypeRequest(column: col.name, currentType: col.typeName)
                        },
                        onDrop: { col in dropColumnPrompt(col) },
                        onAdd: { showAddColumn = true }
                    )
                }

                if !snapshot.constraints.isEmpty {
                    section("Constraints") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.constraints, id: \.name) { c in
                                constraintRow(c)
                            }
                        }
                    }
                }

                if !snapshot.indexes.isEmpty {
                    section("Indexes") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.indexes, id: \.name) { i in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(i.name)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    Text(i.definition)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                if !snapshot.triggers.isEmpty {
                    section("Triggers") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.triggers, id: \.name) { t in
                                triggerRow(t)
                            }
                        }
                    }
                }

                if let part = snapshot.partitioning {
                    section("Partitioning") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(part.strategy.uppercased())
                                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Tokens.Brand.primary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(Tokens.Brand.primary)
                                Text(part.key)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            ForEach(part.children, id: \.name) { child in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(child.schema).\(child.name)")
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                    Text(child.bound.isEmpty ? "DEFAULT" : child.bound)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                            if part.children.isEmpty {
                                Text("No partitions yet")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Spacer(minLength: Tokens.Spacing.md)
            }
            .padding(Tokens.Spacing.md)
            .frame(minWidth: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAddColumn) {
            if let service {
                AddColumnSheet(
                    service: service, schema: snapshot.schema, table: snapshot.table,
                    onClose: { showAddColumn = false },
                    onSaved: { onReload?() }
                )
            }
        }
        .sheet(item: $renameColumnTarget) { target in
            if let service {
                RenameColumnSheet(
                    service: service, schema: snapshot.schema, table: snapshot.table,
                    original: target.value,
                    onClose: { renameColumnTarget = nil },
                    onSaved: { onReload?() }
                )
            }
        }
        .sheet(item: $alterTypeTarget) { req in
            if let service {
                AlterColumnTypeSheet(
                    service: service, schema: snapshot.schema, table: snapshot.table,
                    column: req.column, currentType: req.currentType,
                    onClose: { alterTypeTarget = nil },
                    onSaved: { onReload?() }
                )
            }
        }
    }

    private func dropColumnPrompt(_ col: TableInspector.Column) {
        guard let service else { return }
        let alert = NSAlert()
        alert.messageText = "Drop column \(col.name)?"
        alert.informativeText = "Data in this column is gone permanently. Drop CASCADE also removes anything depending on it (views, FKs)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Drop CASCADE")
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let cascade = (answer == .alertSecondButtonReturn)
        Task {
            _ = await AdminActions.dropColumn(
                schema: snapshot.schema, table: snapshot.table,
                column: col.name, cascade: cascade, service: service
            )
            onReload?()
        }
    }

    @ViewBuilder
    private func triggerRow(_ t: TableInspector.Trigger) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(t.enabled ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(t.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                if !t.enabled {
                    Text("disabled")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let service {
                    Button(t.enabled ? "Disable" : "Enable") {
                        Task {
                            _ = await AdminActions.setTriggerEnabled(
                                schema: snapshot.schema, table: snapshot.table,
                                trigger: t.name, enabled: !t.enabled,
                                service: service
                            )
                            onReload?()
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Drop trigger \(t.name)?"
                        alert.informativeText = "This cannot be undone."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Drop")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            Task {
                                _ = await AdminActions.dropTrigger(
                                    schema: snapshot.schema, table: snapshot.table,
                                    trigger: t.name, service: service
                                )
                                onReload?()
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
            Text(t.definition)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func constraintRow(_ c: TableInspector.Constraint) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(badge(for: c.kind))
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(constraintColor(for: c.kind).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(constraintColor(for: c.kind))
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Text(c.definition)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func section<Body: View>(_ title: String, @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }

    private func pkColumnNames(_ s: TableInspector.Snapshot) -> Set<String> {
        // Pull the primary-key column names out of the constraint def so we
        // can flag them inline in the column table — there's always at most
        // one PK so this stays cheap.
        guard let pk = s.constraints.first(where: { $0.kind == "p" }) else { return [] }
        guard let open = pk.definition.firstIndex(of: "("),
              let close = pk.definition.firstIndex(of: ")"),
              open < close
        else { return [] }
        let body = pk.definition[pk.definition.index(after: open)..<close]
        return Set(body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
              .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        })
    }

    private func badge(for kind: Character) -> String {
        switch kind {
        case "p": "PK"
        case "u": "UK"
        case "f": "FK"
        case "c": "CK"
        case "x": "EX"
        default:  String(kind).uppercased()
        }
    }

    private func constraintColor(for kind: Character) -> Color {
        switch kind {
        case "p": Tokens.Brand.primary
        case "u": .indigo
        case "f": .blue
        case "c": .orange
        default:  .gray
        }
    }
}

/// Columns rendered as a real SwiftUI `Grid` so each column sizes to
/// content with sensible minimums, instead of fighting hardcoded
/// widths that overflowed when the window was narrow and clipped long
/// types like `character varying(255)`.
struct StructureColumnsTable: View {
    let columns: [TableInspector.Column]
    let pkColumns: Set<String>
    var canEdit: Bool = false
    var onRename: ((String) -> Void)? = nil
    var onAlterType: ((TableInspector.Column) -> Void)? = nil
    var onDrop: ((TableInspector.Column) -> Void)? = nil
    var onAdd: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 14,
                 verticalSpacing: 4) {
                GridRow {
                    headerCell("#", alignment: .trailing)
                    headerCell("Name")
                    headerCell("Type")
                    headerCell("Nullable", alignment: .center)
                    headerCell("Default")
                    headerCell("Comment")
                }
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))

                ForEach(Array(columns.enumerated()), id: \.element.ordinal) { (idx, c) in
                    GridRow {
                        Text("\(c.ordinal)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)

                        HStack(spacing: 4) {
                            if pkColumns.contains(c.name) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Tokens.Brand.primary)
                            }
                            Text(c.name)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .textSelection(.enabled)
                        }

                        Text(c.typeName)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(c.nullable ? "yes" : "no")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(c.nullable ? .secondary : .primary)
                            .gridColumnAlignment(.center)

                        Text(c.defaultExpr ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(c.defaultExpr == nil ? .tertiary : .secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(c.comment ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        if canEdit {
                            Button("Rename column…") { onRename?(c.name) }
                            Button("Change type…") { onAlterType?(c) }
                            Divider()
                            Button("Drop column…", role: .destructive) { onDrop?(c) }
                        }
                    }
                    if idx < columns.count - 1 {
                        Divider().opacity(0.35).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            if canEdit, let onAdd {
                Button {
                    onAdd()
                } label: {
                    Label("Add column", systemImage: "plus.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func headerCell(_ s: String, alignment: HorizontalAlignment = .leading) -> some View {
        Text(s.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
            .gridColumnAlignment(alignment)
    }
}

struct InspectorError: View {
    let msg: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Couldn't load metadata")
                .font(.headline)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
