import AppKit
import UserNotifications

/// Posts a macOS Notification Center toast when a long-running
/// operation finishes while pgBrain is in the background. The
/// `OperationsCenter` calls in once per such finish; we ask for
/// authorisation lazily on first call so users who never run
/// 30s+ queries never get prompted.
@MainActor
enum LongQueryNotifier {
    private static var didRequestAuthorization = false

    static func notify(operation: OperationsCenter.Operation) {
        ensureAuthorization()
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = headline(for: operation)
        content.body = body(for: operation)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "pgbrain.longQuery.\(operation.id.uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { _ in /* best-effort */ }
    }

    private static func ensureAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func headline(for op: OperationsCenter.Operation) -> String {
        switch op.status {
        case .succeeded:        return "Query finished"
        case .failed:           return "Query failed"
        case .cancelled:        return "Query cancelled"
        case .running:          return "Query update"
        }
    }

    private static func body(for op: OperationsCenter.Operation) -> String {
        let elapsed = String(format: "%.1fs", op.elapsed)
        let summary = op.summary.count > 80
            ? String(op.summary.prefix(78)) + "…"
            : op.summary
        return "\(elapsed) · \(summary)"
    }
}
