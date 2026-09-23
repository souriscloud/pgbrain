import AppKit
import SwiftUI

/// Single-row strip pinned above the grid. Splits 50/50: left side
/// receives the body of a `WHERE` clause, right side the body of an
/// `ORDER BY` clause. The `WHERE` / `ORDER BY` keywords are
/// non-editable labels in front of each input — the user types only
/// the expression. Enter (or focus loss) triggers `onSubmit` which
/// the host re-fires as a server-side reload.
struct QueryStripView: View {
    @Binding var filter: RowsFetcher.Filter
    let table: TableNode
    let schema: SchemaSnapshot
    let isRefreshing: Bool
    let onSubmit: () -> Void

    /// We need a separate draft so we don't refetch on every keystroke.
    /// Submitted state lives in `filter`; `whereDraft` / `orderDraft`
    /// are what's currently in the fields. Submit writes through.
    @State private var whereDraft: String = ""
    @State private var orderDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            clauseField(
                keyword: "WHERE",
                text: $whereDraft,
                placeholder: "e.g. id = 5  OR  email ILIKE '%@example.com'",
                tint: .blue,
                clauseKind: .whereExpr
            ) { committed in
                // SwiftUI's TextField onCommit fires both on Enter AND
                // on focus loss on macOS, so guard against no-op
                // commits — otherwise tabbing between the two fields
                // triggers a useless server reload. Compare against the
                // live committed string, not the `whereDraft` snapshot,
                // which can lag a keystroke behind on a same-tick commit.
                guard committed != filter.whereClause else { return }
                whereDraft = committed
                filter.whereClause = committed
                onSubmit()
            }
            Divider()
            clauseField(
                keyword: "ORDER BY",
                text: $orderDraft,
                placeholder: "e.g. created_at DESC, id",
                tint: .purple,
                clauseKind: .orderBy
            ) { committed in
                guard committed != filter.orderByClause else { return }
                orderDraft = committed
                filter.orderByClause = committed
                onSubmit()
            }
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 30)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(.separator),
            alignment: .bottom
        )
        .onAppear {
            whereDraft = filter.whereClause
            orderDraft = filter.orderByClause
        }
        // If the loader rewrites the filter (e.g. header click → sort),
        // mirror the change into the drafts so the strip stays accurate.
        .onChange(of: filter.whereClause) { _, new in
            if new != whereDraft { whereDraft = new }
        }
        .onChange(of: filter.orderByClause) { _, new in
            if new != orderDraft { orderDraft = new }
        }
    }

    @ViewBuilder
    private func clauseField(
        keyword: String,
        text: Binding<String>,
        placeholder: String,
        tint: Color,
        clauseKind: SQLCompletionContext.ClauseKind,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Text(keyword)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(tint.opacity(0.12))
            CompletingTextField(
                text: text,
                placeholder: placeholder,
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                completions: { partial in
                    SQLCompletionProvider.items(
                        for: partial,
                        in: schema,
                        context: .clause(table: table, kind: clauseKind)
                    )
                },
                onCommit: onCommit
            )
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }
}
