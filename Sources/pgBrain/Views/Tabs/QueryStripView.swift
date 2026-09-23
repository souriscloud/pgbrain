import AppKit
import SwiftUI

/// Single-row strip pinned above the grid: the body of a `WHERE` clause on
/// the left, an `ORDER BY` on the right. The keywords are fixed labels; the
/// user types only the expressions.
///
/// Return submits. The field also reports a commit when it loses focus;
/// that one submits only while nothing is staged — with pending edits the
/// text stays an (orange) draft, so clicking from the strip into the grid
/// never reloads the page out from under the edits.
struct QueryStripView: View {
    let filter: RowsFetcher.Filter
    let table: TableNode
    let schema: SchemaSnapshot
    let isRefreshing: Bool
    let hasPendingChanges: Bool
    let onSubmit: (RowsFetcher.Filter) -> Void

    @State private var whereDraft: String = ""
    @State private var orderDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            clauseField(
                keyword: "WHERE",
                text: $whereDraft,
                committed: filter.whereClause,
                placeholder: "e.g. id = 5  OR  email ILIKE '%@example.com'",
                tint: .blue,
                clauseKind: .whereExpr
            ) { committed in
                submit(where: committed, order: orderDraft, changed: committed != filter.whereClause)
            }
            Divider()
            clauseField(
                keyword: "ORDER BY",
                text: $orderDraft,
                committed: filter.orderByClause,
                placeholder: "e.g. created_at DESC, id",
                tint: .purple,
                clauseKind: .orderBy
            ) { committed in
                submit(where: whereDraft, order: committed, changed: committed != filter.orderByClause)
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
        // The loader rewrites the filter too (header sort, "filter to
        // value", FK jumps); mirror that into the fields.
        .onChange(of: filter.whereClause) { _, new in
            if new != whereDraft { whereDraft = new }
        }
        .onChange(of: filter.orderByClause) { _, new in
            if new != orderDraft { orderDraft = new }
        }
    }

    private func submit(where w: String, order o: String, changed: Bool) {
        switch DirtyGuard.clauseCommit(trigger: Self.currentTrigger(), changed: changed, hasPendingChanges: hasPendingChanges) {
        case .ignore, .keepDraft:
            return
        case .reload, .confirmReload:
            onSubmit(RowsFetcher.Filter(whereClause: w, orderByClause: o))
        }
    }

    /// The text field reports Return and focus loss through the same
    /// callback; the event being handled tells them apart.
    private static func currentTrigger() -> DirtyGuard.CommitTrigger {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return .focusLoss }
        return (event.keyCode == 36 || event.keyCode == 76) ? .enter : .focusLoss
    }

    @ViewBuilder
    private func clauseField(
        keyword: String,
        text: Binding<String>,
        committed: String,
        placeholder: String,
        tint: Color,
        clauseKind: SQLCompletionContext.ClauseKind,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        let isDraft = text.wrappedValue != committed
        HStack(spacing: 0) {
            Text(keyword)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(isDraft ? .orange : tint)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background((isDraft ? Color.orange : tint).opacity(0.12))
                .help(isDraft ? "Not applied yet — press Return to run it" : "")
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
