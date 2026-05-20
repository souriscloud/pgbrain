import SwiftUI
import UniformTypeIdentifiers

/// JetBrains-style horizontal tab strip. Active tab is highlighted with the
/// brand color; each tab has a hover-revealed close button. Tabs reorder by
/// dragging — `dropEntered` does the swap live so the row animates as the
/// user drags, matching the JetBrains feel.
struct TabStripView: View {
    @Bindable var workspace: WorkspaceState
    @State private var draggingID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: workspace.selectedID == tab.id,
                        isDragging: draggingID == tab.id,
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
        .frame(height: 30)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct TabChip: View {
    let tab: WorkspaceState.Tab
    let isSelected: Bool
    let isDragging: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Tokens.Brand.primary : .secondary)
            Text(tab.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
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
                        .fill(Tokens.Brand.primary)
                        .frame(height: 2)
                }
            }
        )
        .opacity(isDragging ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
    }

    private var icon: String {
        switch tab.kind {
        case .table(let t):
            switch t.kind {
            case .table: return "tablecells"
            case .view: return "rectangle.stack"
            case .materializedView: return "rectangle.stack.fill"
            }
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
