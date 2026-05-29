import SwiftUI

/// Floating stack of toast bubbles, anchored bottom-trailing over the
/// workspace area (above the status footer). Newest toast sits at the bottom.
/// Click any bubble to dismiss it early.
struct ToastOverlay: View {
    @Bindable var center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.sm) {
            ForEach(center.toasts) { toast in
                ToastBubble(toast: toast) { center.dismiss(toast) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(Tokens.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!center.toasts.isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: center.toasts.map(\.id))
    }
}

private struct ToastBubble: View {
    let toast: ToastCenter.Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.callout.weight(.semibold))
            Text(toast.text)
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Corner.card))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Corner.card)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 9, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .help("Click to dismiss")
    }

    private var symbol: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .success: return .green
        case .error: return .orange
        case .info: return .accentColor
        }
    }
}
