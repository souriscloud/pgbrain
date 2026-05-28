import AppKit
import SwiftUI

@MainActor
@Observable
final class CommandPaletteModel {
    let items: [CommandItem]
    var query: String = ""
    var selectionIndex: Int = 0

    var filtered: [CommandItem] {
        CommandMatcher.filter(items, query: query)
    }

    init(items: [CommandItem]) {
        self.items = items
    }

    func selected() -> CommandItem? {
        let list = filtered
        guard !list.isEmpty else { return nil }
        let clamped = max(0, min(selectionIndex, list.count - 1))
        return list[clamped]
    }

    func move(by delta: Int) {
        let list = filtered
        guard !list.isEmpty else { selectionIndex = 0; return }
        let next = selectionIndex + delta
        selectionIndex = max(0, min(list.count - 1, next))
    }

    func reset() {
        selectionIndex = 0
    }
}

/// Top-level palette view — single search field, scrollable result
/// list, footer hint strip. Visual goal: feel like Linear / Raycast,
/// not like macOS Spotlight. Vibrant background + 14pt corners +
/// brand-violet selection ring.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    let onExecute: (CommandItem) -> Void
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.25)
            results
            Divider().opacity(0.25)
            footer
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 16)
        .onAppear { searchFocused = true }
        .onChange(of: model.query) { _, _ in model.reset() }
        // The local NSEvent monitor consumes ↑/↓ before they reach the
        // text field, but the @FocusState binding silently drops to
        // false after a consumed event (SwiftUI quirk on
        // nonactivating NSPanels). Re-asserting focus on every
        // selection change keeps the caret in the search bar so typing
        // continues to work after arrow-key navigation.
        .onChange(of: model.selectionIndex) { _, _ in searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Type a command, table, or schema…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($searchFocused)
                .onSubmit { execute() }
            // Tiny chip showing result count — handy on huge schemas
            // where you want to know whether your query narrowed at all.
            Text("\(model.filtered.count)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { idx, item in
                        CommandRow(
                            item: item,
                            isSelected: idx == model.selectionIndex,
                            highlightQuery: model.query
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectionIndex = idx
                            onExecute(item)
                        }
                        .onHover { hovering in
                            if hovering { model.selectionIndex = idx }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
            .onChange(of: model.selectionIndex) { _, new in
                guard new < model.filtered.count else { return }
                let id = model.filtered[new].id
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay {
                if model.filtered.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No matches for “\(model.query)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            FooterHint(keys: "↩", label: "Run")
            FooterHint(keys: "↑↓", label: "Navigate")
            FooterHint(keys: "⎋", label: "Close")
            Spacer()
            if let sel = model.selected() {
                Text(sel.category.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func execute() {
        guard let item = model.selected() else { return }
        onExecute(item)
    }
}

private struct FooterHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                )
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct CommandRow: View {
    let item: CommandItem
    let isSelected: Bool
    let highlightQuery: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconBackground)
                    .frame(width: 28, height: 28)
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconForeground)
            }

            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Tokens.Brand.primary.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Tokens.Brand.primary.opacity(0.4) : .clear, lineWidth: 0.75)
        )
    }

    private var iconBackground: Color {
        switch item.category {
        case .action:     Tokens.Brand.primary.opacity(0.18)
        case .connection: Color.cyan.opacity(0.18)
        case .table:      Color.blue.opacity(0.18)
        case .schema:     Color.orange.opacity(0.18)
        case .tab:        Color.green.opacity(0.18)
        case .query:      Color.pink.opacity(0.18)
        }
    }

    private var iconForeground: Color {
        switch item.category {
        case .action:     Tokens.Brand.primary
        case .connection: .cyan
        case .table:      .blue
        case .schema:     .orange
        case .tab:        .green
        case .query:      .pink
        }
    }

    /// Wraps `Text` with attributed-string highlight of matched
    /// characters. Falls back to plain title when the query is empty.
    private var highlightedTitle: Text {
        let title = item.title
        let ranges = CommandMatcher.matchedRanges(in: title, needle: highlightQuery)
        if ranges.isEmpty {
            return Text(title).foregroundStyle(.primary)
        }
        var out = AttributedString(title)
        for r in ranges {
            // Convert String.Index range → AttributedString range.
            let lower = AttributedString.Index(r.lowerBound, within: out)
            let upper = AttributedString.Index(r.upperBound, within: out)
            if let lo = lower, let hi = upper {
                out[lo..<hi].foregroundColor = Tokens.Brand.primary
                out[lo..<hi].font = .system(size: 14, weight: .bold)
            }
        }
        return Text(out)
    }
}
