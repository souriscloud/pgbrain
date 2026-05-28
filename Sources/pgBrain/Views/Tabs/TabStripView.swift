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
                            isProduction: appearance.connection.isProduction,
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
            .keyboardShortcut("n", modifiers: .command)
            .help("New scratchpad (⌘N)")
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
    let isProduction: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    private var canRename: Bool {
        if case .scratchpad = tab.kind { return true }
        return false
    }

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
            if isProduction {
                Circle()
                    .fill(Tokens.Brand.danger)
                    .frame(width: 6, height: 6)
                    .help("Production connection — destructive queries will prompt for confirmation.")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 0.8 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            ZStack(alignment: .bottom) {
                Color.clear
                if isSelected {
                    Rectangle()
                        .fill(accent)
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
            Button("Close Tab", role: .destructive, action: onClose)
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
