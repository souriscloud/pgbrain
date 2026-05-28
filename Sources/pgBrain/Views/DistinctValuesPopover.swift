import SwiftUI
import PostgresNIO

/// Pop-over content for the data grid's "Distinct values for X…" menu.
/// Issues `SELECT col, COUNT(*) … GROUP BY 1 ORDER BY 2 DESC LIMIT 100`
/// against the table and renders the result as a tappable list — picking
/// a row calls `onPick` which the host wires into the WHERE strip.
struct DistinctValuesPopover: View {
    let service: ConnectionService
    let schema: String
    let table: String
    let column: String
    let extraWhere: String     // current WHERE so the histogram respects it
    let onPick: (String?) -> Void

    @State private var rows: [(value: String?, count: Int64)] = []
    @State private var totalDistinct: Int64 = 0
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
                Text("Distinct values").font(.callout.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(8)
            Text(column)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            Divider()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
            } else if rows.isEmpty && !loading {
                Text("No distinct values.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { (idx, row) in
                            DistinctRow(value: row.value, count: row.count) {
                                onPick(row.value)
                            }
                            if idx < rows.count - 1 {
                                Divider().opacity(0.25)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack(spacing: 4) {
                Text("\(rows.count) shown")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                if totalDistinct > Int64(rows.count) {
                    Text("· \(totalDistinct) total").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .frame(width: 320)
        .task { await load() }
    }

    private func load() async {
        guard let client = service.client else {
            error = "Not connected."; loading = false; return
        }
        let qualifiedTable = SQLIdent.quote(schema) + "." + SQLIdent.quote(table)
        let qualifiedCol = SQLIdent.quote(column)
        let whereClause = extraWhere.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : " WHERE \(extraWhere)"
        let raw = """
        SELECT \(qualifiedCol)::text AS v, COUNT(*)::int8 AS c
        FROM \(qualifiedTable)\(whereClause)
        GROUP BY 1
        ORDER BY 2 DESC NULLS LAST, 1
        LIMIT 100
        """
        let totalRaw = """
        SELECT COUNT(DISTINCT \(qualifiedCol))::int8
        FROM \(qualifiedTable)\(whereClause)
        """
        do {
            async let rowsTask = fetchPairs(sql: raw, client: client)
            async let total: Int64 = fetchInt(sql: totalRaw, client: client)
            self.rows = try await rowsTask
            self.totalDistinct = (try? await total) ?? 0
            loading = false
        } catch {
            self.error = PostgresErrorMessage.describe(error)
            loading = false
        }
    }

    private func fetchPairs(sql: String, client: PostgresClient) async throws -> [(value: String?, count: Int64)] {
        let stream = try await client.query(PostgresQuery(unsafeSQL: sql))
        var out: [(String?, Int64)] = []
        for try await (v, c) in stream.decode((String?, Int64).self) {
            out.append((v, c))
        }
        return out
    }

    private func fetchInt(sql: String, client: PostgresClient) async throws -> Int64 {
        let stream = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await n in stream.decode(Int64.self) { return n }
        return 0
    }
}

/// One tappable distinct-value row with a hover highlight. Pulled out so
/// the per-row `@State` hover flag doesn't churn the whole list.
private struct DistinctRow: View {
    let value: String?
    let count: Int64
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(value ?? "NULL")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .italic(value == nil)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.clear)
        .onHover { hovering = $0 }
    }
}
