import AppKit
import Foundation
import Logging
import Observation
import PostgresNIO

/// Per-connection registry of in-flight operations (queries, schema fetches,
/// updates, imports, exports). Drives the status-footer popover so the user
/// can see what's running and cancel it from one place.
///
/// Cancellation strategy: each operation captures `pg_backend_pid()` from its
/// own checked-out connection at start. Cancelling fires
/// `SELECT pg_cancel_backend($pid)` on a *sister* connection from the same
/// `PostgresClient` pool. This matches what `psql` does on `^C`.
@MainActor
@Observable
final class OperationsCenter {
    enum Kind: String, Sendable {
        case query, update, schema, export, importJob

        var label: String {
            switch self {
            case .query: return "Query"
            case .update: return "Update"
            case .schema: return "Schema fetch"
            case .export: return "Export"
            case .importJob: return "Import"
            }
        }

        var symbolName: String {
            switch self {
            case .query: return "play.rectangle.fill"
            case .update: return "pencil.line"
            case .schema: return "rectangle.3.group.fill"
            case .export: return "arrow.up.doc"
            case .importJob: return "arrow.down.doc"
            }
        }
    }

    @Observable
    final class Operation: Identifiable {
        enum Status: Sendable, Equatable {
            case running
            case succeeded
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let kind: Kind
        var summary: String
        let startedAt: Date
        var finishedAt: Date?
        var backendPID: Int32?
        var status: Status = .running

        /// Set by the runner once the operation actually has a checked-out
        /// connection — closure issues `pg_cancel_backend($pid)` on a sister
        /// connection. No-op if the operation finished already.
        @ObservationIgnored var cancellationHandler: (@Sendable () async -> Void)?
        /// Owning Task so the local await can also be torn down on cancel.
        @ObservationIgnored var taskHandle: Task<Void, Never>?

        init(kind: Kind, summary: String) {
            self.kind = kind
            self.summary = summary
            self.startedAt = Date()
        }

        var elapsed: TimeInterval {
            (finishedAt ?? Date()).timeIntervalSince(startedAt)
        }

        var isFinished: Bool {
            if case .running = status { return false }
            return true
        }
    }

    private(set) var operations: [Operation] = []

    /// Fired every time an operation reaches a terminal status. Wired by
    /// `ConnectionService` to flash a toast — keeps this type decoupled from
    /// the toast presentation layer.
    @ObservationIgnored var onFinish: ((Operation) -> Void)?

    var runningCount: Int {
        operations.lazy.filter { !$0.isFinished }.count
    }

    func begin(kind: Kind, summary: String) -> Operation {
        let op = Operation(kind: kind, summary: summary)
        operations.append(op)
        return op
    }

    func finish(_ op: Operation, status: Operation.Status) {
        op.status = status
        op.finishedAt = Date()
        op.cancellationHandler = nil
        // Long-query toast — fire only when the app is in the
        // background so the user gets pinged without spamming
        // notifications for queries they're sitting on.
        if op.elapsed > 30, NSApp.isActive == false {
            LongQueryNotifier.notify(operation: op)
        }
        onFinish?(op)
    }

    /// User-initiated cancellation from the popover. Fires the cancel handler
    /// (sister-connection pg_cancel_backend) and cancels the owning Task so
    /// the local await unwinds. Caller's catch block flips the op state to
    /// `.cancelled` via `finish(_:status:)`.
    func cancel(_ op: Operation) {
        guard !op.isFinished else { return }
        op.taskHandle?.cancel()
        let handler = op.cancellationHandler
        Task.detached { await handler?() }
    }

    func clearFinished() {
        operations.removeAll { $0.isFinished }
    }

    /// Called by a runner after it has checked out a connection and queried
    /// `pg_backend_pid()`. Hop back to main, find the op by id, attach the
    /// PID + the sister-connection cancellation closure. No-op if the op is
    /// already gone or finished.
    func attachCancellation(
        toOperationID id: UUID,
        pid: Int32,
        handler: @escaping @Sendable () async -> Void
    ) {
        guard let op = operations.first(where: { $0.id == id }), !op.isFinished else { return }
        op.backendPID = pid
        op.cancellationHandler = handler
    }
}

/// Helper for runners: fetch the backend PID from a checked-out connection so
/// the operation can register a real cancellation handler.
enum OperationsHelpers {
    static func fetchBackendPID(_ connection: PostgresConnection, logger: Logger) async throws -> Int32 {
        let rows = try await connection.query("SELECT pg_backend_pid()", logger: logger)
        for try await pid in rows.decode(Int32.self) {
            return pid
        }
        return 0
    }
}
