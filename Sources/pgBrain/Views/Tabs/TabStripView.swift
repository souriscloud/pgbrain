import SwiftUI
import UniformTypeIdentifiers

/// JetBrains-style horizontal tab strip. Active tab is highlighted with the
/// brand color; each tab has a hover-revealed close button. Tabs reorder by
/// dragging — `dropEntered` does the swap live so the row animates as the
/// user drags, matching the JetBrains feel.
struct TabStripView: View {
    @Bindable var workspace: WorkspaceState
    var appearance: ConnectionAppearance
    @State private var draggingID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isSelected: workspace.selectedID == tab.id,
                            isDragging: draggingID == tab.id,
                            accent: appearance.emphasized,
                            onSelect: { workspace.selectedID = tab.id },
                            onClose: { workspace.closeTab(id: tab.id) }
                        )
                        .onDrag {
                            draggingID = tab.id
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TabDropDelegate(
                                target: tab,
                                workspace: workspace,
                                draggingID: $draggingID
                            )
                        )
                        Divider().frame(height: 18).opacity(0.4)
                    }
                }
                .padding(.horizontal, 4)
                .animation(.easeInOut(duration: 0.18), value: workspace.tabs.map(\.id))
            }
            Spacer(minLength: 0)
            Button {
                workspace.openScratchpad()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // ⌘N belongs to the menu's "New Connection…" item; the
            // tab-creation shortcut is ⌘T, owned by
            // ConnectionWindowContent's keyboardShortcuts block.
            .help("New scratchpad (⌘T)")
            .padding(.trailing, 4)
        }
        .frame(height: 30)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct TabChip: View {
    @Bindable var tab: WorkspaceState.Tab
    let isSelected: Bool
    let isDragging: Bool
    let accent: Color
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var showColorPicker = false
    @FocusState private var renameFocused: Bool

    // Both kinds are renameable. Table tabs default to `schema.name`
    // but the user might want a custom label (e.g. "Production Users")
    // — `tab.title` is independent of the underlying `TableNode.name`
    // and persisted across session restore.
    private var canRename: Bool { true }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? accent : .secondary)
            if isRenaming {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .focused($renameFocused)
                    .frame(minWidth: 80, maxWidth: 220)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onAppear {
                        // One runloop hop lets the field render before
                        // we hand focus over — otherwise the @FocusState
                        // sometimes fails to engage on first display.
                        DispatchQueue.main.async { renameFocused = true }
                    }
            } else {
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if tab.hasPendingChanges {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("Unapplied edits — click Apply in the table header to commit.")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .opacity(hovering || isSelected ? 0.8 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            ZStack(alignment: .bottom) {
                // Soft color wash across the whole chip when a color
                // tag is set — visible enough to scan, not so loud it
                // fights the active-tab underline.
                tintBackground
                if isSelected {
                    Rectangle()
                        .fill(tintAccent)
                        .frame(height: 2)
                }
            }
        )
        .opacity(isDragging ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if canRename { startRename() } }
        .onTapGesture { if !isRenaming { onSelect() } }
        .onHover { hovering = $0 }
        .contextMenu {
            if canRename {
                Button("Rename Tab…") { startRename() }
            }
            Button("Pick Color…") { showColorPicker = true }
            Button("Close Tab", role: .destructive, action: onClose)
        }
        // External rename request (e.g. via ⌘K → "Rename Tab…")
        // arrives by flipping `tab.requestedRename` to true.
        .onChange(of: tab.requestedRename) { _, want in
            if want, canRename {
                startRename()
                tab.requestedRename = false
            } else if want {
                // Not renameable (e.g. table tab) — reset so the
                // signal doesn't linger.
                tab.requestedRename = false
            }
        }
        // Colour-picker popover, opened by ⌘K → "Color Tab…" or by
        // the right-click context menu's "Pick colour…" path.
        .onChange(of: tab.requestedColorPicker) { _, want in
            if want {
                showColorPicker = true
                tab.requestedColorPicker = false
            }
        }
        .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
            ColorSwatchPicker(
                selected: tab.color,
                onPick: { tag in
                    tab.color = (tag == .none) ? nil : tag
                    // Persist immediately — colour lives on the Tab,
                    // and Tab mutations don't auto-trigger the session
                    // snapshot the way workspace.tabs additions do.
                    SessionStateStore.shared.scheduleSnapshot()
                    showColorPicker = false
                },
                onCancel: { showColorPicker = false }
            )
            .padding(10)
        }
    }

    /// Bottom-line accent — the tab's color tag if set, otherwise the
    /// connection's brand accent.
    private var tintAccent: Color {
        if let c = tab.color, c != .none { return c.swiftUIColor }
        return accent
    }
    private var tintBackground: some View {
        Group {
            if let c = tab.color, c != .none {
                c.swiftUIColor.opacity(isSelected ? 0.18 : 0.10)
            } else {
                Color.clear
            }
        }
    }

    private func startRename() {
        draftTitle = tab.title
        isRenaming = true
        // Make sure the tab is also selected so the rename feels like
        // it's happening on the active surface.
        onSelect()
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.title = trimmed
            // Keep the underlying notebook's title in sync so the
            // saved-queries list, session restore, and command palette
            // all reflect the new name.
            if case .scratchpad(let pad) = tab.kind {
                pad.title = trimmed
            }
            // Persist the rename — without this the on-disk snapshot
            // keeps the original title and the rename is lost on
            // relaunch.
            SessionStateStore.shared.scheduleSnapshot()
        }
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }

    private var icon: String {
        switch tab.kind {
        case .table(let t):
            switch t.kind {
            case .table: return "tablecells"
            case .view: return "rectangle.stack"
            case .materializedView: return "rectangle.stack.fill"
            }
        case .scratchpad:
            return "doc.text"
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: WorkspaceState.Tab
    let workspace: WorkspaceState
    @Binding var draggingID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard let from = draggingID, from != target.id else { return }
        workspace.move(id: from, before: target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

/// Visual color picker that pops over a tab chip — a row of swatches
/// + a "clear" affordance. Fully keyboard-driven: ←/→ to move the
/// focus ring, ⏎ to commit, ⎋ to cancel. Mouse still works.
private struct ColorSwatchPicker: View {
    let selected: Connection.ColorTag?
    let onPick: (Connection.ColorTag) -> Void
    let onCancel: () -> Void

    /// Ordered the way picker UIs traditionally arrange tag colors —
    /// cool tones first, then warm, then neutrals. The final entry
    /// `.none` is the "clear" tile.
    private static let options: [Connection.ColorTag] = [
        .blue, .teal, .green, .yellow, .orange, .red, .pink, .purple, .gray, .none,
    ]

    @State private var focusedIndex: Int = 0
    @FocusState private var focused: Bool

    init(selected: Connection.ColorTag?, onPick: @escaping (Connection.ColorTag) -> Void, onCancel: @escaping () -> Void) {
        self.selected = selected
        self.onPick = onPick
        self.onCancel = onCancel
        let sel = selected ?? .none
        _focusedIndex = State(initialValue: Self.options.firstIndex(of: sel) ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(Array(Self.options.enumerated()), id: \.element) { (i, tag) in
                    Swatch(
                        tag: tag,
                        isSelected: (selected ?? .none) == tag,
                        isFocused: focusedIndex == i
                    )
                    .contentShape(Circle())
                    .onTapGesture { onPick(tag) }
                    .onHover { hovering in if hovering { focusedIndex = i } }
                    .accessibilityLabel(tag == .none ? "Clear color" : tag.rawValue.capitalized)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            Text("← →  ↩ to pick  ·  ⎋ to cancel")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            // One runloop hop so the popover finishes laying out before
            // we grab focus — otherwise the @FocusState binding can
            // silently drop on first present.
            DispatchQueue.main.async { focused = true }
        }
        .onKeyPress(.leftArrow)  { focusedIndex = max(0, focusedIndex - 1); return .handled }
        .onKeyPress(.rightArrow) { focusedIndex = min(Self.options.count - 1, focusedIndex + 1); return .handled }
        .onKeyPress(.return)     { onPick(Self.options[focusedIndex]); return .handled }
        .onKeyPress(.space)      { onPick(Self.options[focusedIndex]); return .handled }
        .onKeyPress(.escape)     { onCancel(); return .handled }
    }

    /// One swatch — a color circle (or the dashed "clear" tile). Two
    /// visual cues, NEVER stacked as competing rings:
    ///
    /// - **Focus** is a single brand-violet ring sitting 3pt outside
    ///   the swatch. Always present on the keyboard-focused tile, and
    ///   follows the mouse on hover.
    /// - **Selection** is a checkmark inside the swatch — no ring.
    ///   This makes the "currently applied" state legible without
    ///   double-bordering the focused swatch.
    private struct Swatch: View {
        let tag: Connection.ColorTag
        let isSelected: Bool
        let isFocused: Bool

        var body: some View {
            ZStack {
                base
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(checkmarkForeground)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(isFocused ? Tokens.Brand.primary : Color.clear, lineWidth: 2)
                    .padding(-4)
            )
        }

        @ViewBuilder
        private var base: some View {
            if tag == .none {
                Circle()
                    .stroke(Color.secondary.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else {
                Circle()
                    .fill(tag.swiftUIColor)
                    .overlay(Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.5))
            }
        }

        /// Yellow needs a dark check; everything else reads well in
        /// white. Clear-tile uses a secondary-tinted check.
        private var checkmarkForeground: Color {
            switch tag {
            case .none:    .secondary
            case .yellow:  .black
            default:       .white
            }
        }
    }
}
