import AppKit
import SwiftUI

/// One runnable statement located within an SQL cell: its character range and
/// vertical geometry (in the cell editor's coordinate space, points from the
/// text top), computed from the text view's layout manager.
struct StatementMarker: Identifiable, Equatable {
    let id: Int
    let range: NSRange
    let yTop: CGFloat
    let height: CGFloat
}

/// DataGrip-style run gutter for an SQL cell: a thin left rail that outlines
/// each statement and offers a ▶ to run just that statement (inline). Lives in
/// an `HStack` to the left of the cell editor, top-aligned so the markers'
/// `yTop` offsets line up with the statements they point at.
struct SqlGutter: View {
    let markers: [StatementMarker]
    var accent: Color
    /// Run a single statement (its result lands inline after the cell).
    let onRun: (NSRange) -> Void

    @State private var hovered: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(markers) { m in
                // Outline bar spanning the statement's vertical extent.
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.opacity(hovered == m.id ? 0.55 : 0.22))
                    .frame(width: 2, height: max(8, m.height - 2))
                    .offset(x: 19, y: m.yTop + 1)

                // Run-this-statement button, aligned to the statement's first line.
                Button { onRun(m.range) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovered == m.id ? accent : accent.opacity(0.65))
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Run this statement")
                .offset(x: 3, y: m.yTop)
                .onHover { inside in hovered = inside ? m.id : (hovered == m.id ? nil : hovered) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}
