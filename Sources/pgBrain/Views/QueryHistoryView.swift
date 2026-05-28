import SwiftUI

/// Browse + search the persisted query history for one connection.
/// Click any row to copy the SQL to the clipboard or to insert it
/// into a scratchpad. Filter via the search field.
struct QueryHistoryView: View {
    let connectionID: UUID
    let onInsert: (String) -> Void
    let onClose: () -> Void

    @State private var store = QueryHistoryStore.shared
    @State private var search = ""
    @State private var selection: UUID?

    private var filtered: [QueryHistoryEntry] {
        let all = store.entries(for: connectionID)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return all }
        return all.filter { $0.sql.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 320, idealWidth: 380)
                detail
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
        .frame(width: 880, height: 580)
    }

    private var header: some View {
        HStack {
            Text("Query History").font(.title3.weight(.semibold))
            Text("(\(filtered.count) of \(store.entries(for: connectionID).count))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("Search SQL", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Button(role: .destructive) {
                store.clear(for: connectionID)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear all history for this connection")
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Spacing.md)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { entry in
                HStack(spacing: 8) {
                    Circle()
                        .fill(entry.success ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.sql)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text(entry.startedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f ms", entry.elapsedSec * 1000))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            if let rows = entry.rowsAffected {
                                Text("\(rows) rows")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .tag(entry.id)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let entry = filtered.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(entry.success ? "Succeeded" : "Failed",
                          systemImage: entry.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(entry.success ? .green : .red)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.sql, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button {
                        onInsert(entry.sql)
                    } label: { Label("Insert", systemImage: "arrow.down.left.square") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(Tokens.Brand.primary)
                    .help("Insert into the active scratchpad")
                }
                Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(SQLHighlighter.attributedString(for: entry.sql))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Spacing.sm)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                if let err = entry.errorMessage {
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            .padding(Tokens.Spacing.md)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Pick a query to see its SQL").font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
