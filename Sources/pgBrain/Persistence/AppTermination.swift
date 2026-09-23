import Foundation

/// Last-chance work at quit: flush debounced stores and kill ssh tunnels.
///
/// Debounced stores lose their final ~0.5s of writes if the app exits before
/// the timer fires, and ssh children outlive their parent. Stores register a
/// synchronous flush here (typically from their `init`, so only stores that
/// were actually created get flushed); `AppDelegate.applicationWillTerminate`
/// calls `run()`.
@MainActor
enum AppTermination {
    private static var handlers: [(name: String, flush: @MainActor () -> Void)] = []
    private static var didRun = false

    static func register(_ name: String, flush: @escaping @MainActor () -> Void) {
        handlers.removeAll { $0.name == name }
        handlers.append((name, flush))
    }

    static func run() {
        guard !didRun else { return }
        didRun = true
        QueryHistoryStore.shared.flushNow()
        for handler in handlers { handler.flush() }
        SSHTunnelManager.shared.stopAll()
    }
}
