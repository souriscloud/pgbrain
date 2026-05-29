import Foundation
import Observation

/// Per-connection queue of transient, auto-dismissing notifications shown in
/// the bottom-trailing corner of the connection window. The app already
/// tracks long-running work in the operations popover, but that's pull-based
/// — the user has to open it. Toasts are the push-based counterpart: a finished
/// export, a failed import, a saved `.sql` file each flash a short bubble so
/// success and (especially) failure never pass silently.
///
/// Failures linger longer than successes so they can be read before they fade,
/// and any toast can be dismissed early with a click.
@MainActor
@Observable
final class ToastCenter {
    @Observable
    final class Toast: Identifiable, Equatable {
        enum Style: Sendable {
            case success, error, info
        }

        let id = UUID()
        let style: Style
        let text: String

        init(style: Style, text: String) {
            self.style = style
            self.text = text
        }

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var toasts: [Toast] = []

    func show(_ style: Toast.Style, _ text: String) {
        let toast = Toast(style: style, text: text)
        toasts.append(toast)
        // Errors stay up long enough to read a server message; successes
        // and info blips clear quickly so they don't pile up.
        let lifetime: Duration = style == .error ? .seconds(6) : .seconds(3)
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.dismiss(toast)
        }
    }

    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }
}
