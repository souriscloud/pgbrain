import Foundation
import NIOCore
import Synchronization

/// A pinned server session for one scratchpad tab. Everything the tab runs
/// goes through a single long-lived backend, so `SET`, temp tables,
/// `SET ROLE` and an explicit `BEGIN` behave exactly as in psql — the pool
/// used elsewhere hands out a different connection per statement and would
/// return an open transaction to other callers.
///
/// A driver task owns the socket and serves requests one at a time from an
/// `AsyncStream`; the connection opens lazily on the first request and is
/// reopened on the next request if it died.
final class ScratchpadSession: Sendable {
    enum TransactionStatus: Sendable, Equatable {
        case idle, active, failed

        init(readyForQuery byte: UInt8) {
            switch byte {
            case UInt8(ascii: "T"): self = .active
            case UInt8(ascii: "E"): self = .failed
            default: self = .idle
            }
        }
    }

    struct Ticket: Sendable, Hashable {
        fileprivate let id: UInt64
    }

    struct Response: Sendable {
        var result: QueryResult
        var transaction: TransactionStatus
        /// Set when the previous connection had died and this request ran on
        /// a freshly opened one (session state such as temp tables was lost).
        var reconnected: Bool
    }

    let endpoint: PGWireEndpoint
    private let jobs: AsyncStream<Job>.Continuation
    private let driver: Task<Void, Never>
    private let shared: Shared

    init(endpoint: PGWireEndpoint) {
        self.endpoint = endpoint
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        let shared = Shared()
        self.jobs = continuation
        self.shared = shared
        self.driver = Task.detached(priority: .userInitiated) {
            await Self.drive(endpoint: endpoint, jobs: stream, shared: shared)
        }
    }

    deinit {
        close()
    }

    var backendPID: Int32? { shared.state.withLock { $0.pid } }
    /// Status from the most recent ReadyForQuery — also valid after a
    /// statement threw, which is how a failed transaction block is detected.
    var transactionStatus: TransactionStatus { shared.state.withLock { $0.transaction } }
    var isClosed: Bool { shared.state.withLock { $0.closed } }

    func makeTicket() -> Ticket {
        shared.state.withLock { s in
            defer { s.nextTicket += 1 }
            return Ticket(id: s.nextTicket)
        }
    }

    /// Run one statement. Cancelling the calling task sends a wire-level
    /// cancel for this ticket; the error then comes back from the server as
    /// `57014 query_canceled`, which callers treat as a cancellation.
    func run(_ sql: String, rowLimit: Int, ticket: Ticket? = nil) async throws -> Response {
        let ticket = ticket ?? makeTicket()
        let raw: RawResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let job = Job(ticket: ticket.id, sql: sql, rowLimit: rowLimit, continuation: continuation)
                if shared.state.withLock({ $0.closed }) {
                    continuation.resume(throwing: PGWireError.sessionClosed)
                    return
                }
                if case .terminated = jobs.yield(job) {
                    continuation.resume(throwing: PGWireError.sessionClosed)
                }
            }
        } onCancel: {
            Task { await self.cancel(ticket) }
        }
        if let error = raw.outcome.error { throw error }
        return Response(
            result: Self.makeResult(raw.outcome, typeNames: raw.typeNames, elapsed: raw.elapsed),
            transaction: TransactionStatus(readyForQuery: raw.outcome.status),
            reconnected: raw.reconnected
        )
    }

    /// Wire-level cancel of `ticket`. A queued ticket is dropped before it
    /// runs; a running one gets a CancelRequest for this session's own backend.
    /// The liveness check and the registration of the in-flight cancel happen
    /// under one lock, and the driver waits for that cancel to be delivered
    /// before it starts the next statement — so a late cancel can never land
    /// on a statement the user didn't mean.
    func cancel(_ ticket: Ticket) async {
        let endpoint = self.endpoint
        let task: Task<Void, Never>? = shared.state.withLock { s in
            guard s.inFlight == ticket.id else {
                if ticket.id > s.lastStarted { s.cancelledTickets.insert(ticket.id) }
                return nil
            }
            guard let pid = s.pid, let secret = s.secret else { return nil }
            if let existing = s.pendingCancel { return existing }
            let t = Task<Void, Never>.detached {
                try? await PGWireTransport.sendCancel(to: endpoint, pid: pid, secret: secret)
            }
            s.pendingCancel = t
            return t
        }
        await task?.value
    }

    /// Cancel whatever is running and drop the connection. The server rolls
    /// back any open transaction when the socket closes.
    func close() {
        let (busy, pid, secret, alreadyClosed) = shared.state.withLock { s in
            defer { s.closed = true }
            return (s.inFlight != nil, s.pid, s.secret, s.closed)
        }
        guard !alreadyClosed else { return }
        let driver = self.driver
        let jobs = self.jobs
        if busy, let pid, let secret {
            let endpoint = self.endpoint
            Task.detached {
                try? await PGWireTransport.sendCancel(to: endpoint, pid: pid, secret: secret)
                jobs.finish()
                driver.cancel()
            }
        } else {
            jobs.finish()
            driver.cancel()
        }
    }

    // MARK: - Driver

    private struct Job: Sendable {
        let ticket: UInt64
        let sql: String
        let rowLimit: Int
        let continuation: CheckedContinuation<RawResponse, any Error>
    }

    private struct RawResponse: Sendable {
        var outcome: PGWireOutcome
        var typeNames: [[String]]
        var reconnected: Bool
        var elapsed: TimeInterval
    }

    private struct SharedState {
        var nextTicket: UInt64 = 1
        var inFlight: UInt64?
        var lastStarted: UInt64 = 0
        var cancelledTickets: Set<UInt64> = []
        var pid: Int32?
        var secret: ByteBuffer?
        var closed = false
        var transaction: TransactionStatus = .idle
        var pendingCancel: Task<Void, Never>?
    }

    private final class Shared: Sendable {
        let state = Mutex(SharedState())

        func begin(_ ticket: UInt64) -> Bool {
            state.withLock { s in
                s.lastStarted = max(s.lastStarted, ticket)
                if s.cancelledTickets.remove(ticket) != nil { return false }
                s.inFlight = ticket
                return true
            }
        }

        func end(status: UInt8? = nil) async {
            let pending = state.withLock { s -> Task<Void, Never>? in
                s.inFlight = nil
                if let status { s.transaction = TransactionStatus(readyForQuery: status) }
                defer { s.pendingCancel = nil }
                return s.pendingCancel
            }
            await pending?.value
        }

        func connected(pid: Int32, secret: ByteBuffer) {
            state.withLock { $0.pid = pid; $0.secret = secret }
        }

        func disconnected() {
            state.withLock { $0.pid = nil; $0.secret = nil; $0.inFlight = nil; $0.transaction = .idle }
        }
    }

    private struct TypeKey: Hashable {
        let oid: UInt32
        let typmod: Int32
    }

    private static func drive(endpoint: PGWireEndpoint, jobs: AsyncStream<Job>, shared: Shared) async {
        var iterator = jobs.makeAsyncIterator()
        var carried: Job?
        var typeCache: [TypeKey: String] = [:]
        var everConnected = false
        var lostConnection = false

        while !Task.isCancelled {
            let next: Job?
            if let c = carried { next = c } else { next = await iterator.next() }
            guard let first = next else { break }
            carried = nil
            if !shared.begin(first.ticket) {
                first.continuation.resume(throwing: PGWireError.cancelled)
                continue
            }
            let channel: PGWireTransport.Channel
            do {
                channel = try await PGWireTransport.open(endpoint)
            } catch {
                await shared.end()
                first.continuation.resume(throwing: error)
                continue
            }
            let reconnected = everConnected && lostConnection
            var pending: Job? = first
            do {
                try await channel.executeThenClose { inbound, outbound in
                    var io = PGWireIO(inbound: inbound.makeAsyncIterator(), outbound: outbound)
                    do {
                        try await io.startup(endpoint)
                    } catch {
                        await shared.end()
                        pending?.continuation.resume(throwing: error)
                        pending = nil
                        throw error
                    }
                    everConnected = true
                    lostConnection = false
                    shared.connected(pid: io.backendPID, secret: io.backendSecret)
                    var firstOnThisConnection = true

                    while true {
                        let job: Job
                        if let p = pending {
                            job = p
                            pending = nil
                        } else {
                            guard let next = await iterator.next() else {
                                await io.terminate()
                                return
                            }
                            if !shared.begin(next.ticket) {
                                next.continuation.resume(throwing: PGWireError.cancelled)
                                continue
                            }
                            // The server may have dropped us while idle (restart,
                            // idle timeout). Nothing was sent yet, so it's safe
                            // to carry the request over to a fresh connection.
                            if !channel.channel.isActive {
                                carried = next
                                lostConnection = true
                                await shared.end()
                                return
                            }
                            job = next
                        }
                        do {
                            let started = Date()
                            let outcome = try await io.simpleQuery(job.sql, rowLimit: job.rowLimit)
                            let elapsed = Date().timeIntervalSince(started)
                            let names = await resolveTypeNames(outcome, io: &io, cache: &typeCache)
                            await shared.end(status: outcome.status)
                            job.continuation.resume(returning: RawResponse(
                                outcome: outcome, typeNames: names,
                                reconnected: firstOnThisConnection && reconnected,
                                elapsed: elapsed
                            ))
                            firstOnThisConnection = false
                        } catch {
                            await shared.end()
                            lostConnection = true
                            job.continuation.resume(throwing: PGWireError.connectionClosed)
                            throw error
                        }
                    }
                }
            } catch {
                if pending == nil, carried == nil { lostConnection = true }
            }
            shared.disconnected()
        }
        carried?.continuation.resume(throwing: PGWireError.sessionClosed)
        while let job = await iterator.next() {
            job.continuation.resume(throwing: PGWireError.sessionClosed)
        }
    }

    /// Column labels via `format_type`. Built-ins resolve locally; anything
    /// else (enums, domains' arrays, extension types) is looked up once per
    /// session — but only while idle, because a failing lookup inside the
    /// user's open transaction would abort it.
    private static func resolveTypeNames(
        _ outcome: PGWireOutcome, io: inout PGWireIO, cache: inout [TypeKey: String]
    ) async -> [[String]] {
        var unknown: [TypeKey] = []
        for rs in outcome.sets {
            for f in rs.fields {
                let key = TypeKey(oid: f.typeOID, typmod: f.typeModifier)
                if PGTypeNames.name(oid: f.typeOID, typmod: f.typeModifier) == nil,
                   cache[key] == nil, !unknown.contains(key) {
                    unknown.append(key)
                }
            }
        }
        if !unknown.isEmpty, outcome.status == UInt8(ascii: "I") {
            let oids = unknown.map { String($0.oid) }.joined(separator: ",")
            let mods = unknown.map { String($0.typmod) }.joined(separator: ",")
            let sql = "SELECT format_type(o, m) FROM unnest('{\(oids)}'::oid[], '{\(mods)}'::int4[]) AS u(o, m)"
            if let lookup = try? await io.simpleQuery(sql, rowLimit: unknown.count),
               lookup.error == nil, let rows = lookup.sets.first?.rows, rows.count == unknown.count {
                for (key, row) in zip(unknown, rows) {
                    if let name = row.first ?? nil { cache[key] = name }
                }
            }
        }
        return outcome.sets.map { rs in
            rs.fields.map { f in
                PGTypeNames.name(oid: f.typeOID, typmod: f.typeModifier)
                    ?? cache[TypeKey(oid: f.typeOID, typmod: f.typeModifier)]
                    ?? "oid \(f.typeOID)"
            }
        }
    }

    // MARK: - Result shaping

    /// The grid shows one result per statement: the last set that returned
    /// columns (so `SELECT …; ` inside a function-call batch still shows its
    /// rows), with the final command tag.
    static func makeResult(_ outcome: PGWireOutcome, typeNames: [[String]], elapsed: TimeInterval = 0) -> QueryResult {
        let index = outcome.sets.lastIndex(where: { !$0.fields.isEmpty })
        var columns: [ColumnNode] = []
        var rows: [[String?]] = []
        var truncated = false
        if let index {
            let set = outcome.sets[index]
            let names = typeNames.indices.contains(index) ? typeNames[index] : []
            for (i, f) in set.fields.enumerated() {
                columns.append(ColumnNode(
                    name: f.name,
                    typeName: names.indices.contains(i) ? names[i] : "oid \(f.typeOID)",
                    nullable: true,
                    ordinal: i
                ))
            }
            let normalisers = columns.map { TextValue.normaliser(for: $0.typeName) }
            rows = set.rows.map { row in
                row.enumerated().map { i, v in
                    guard let v else { return nil }
                    return i < normalisers.count ? normalisers[i](v) : v
                }
            }
            truncated = set.truncated
        }
        let limit = max(rows.count, 1)
        let page = RowsFetcher.Page(
            columns: columns, rows: rows, truncated: truncated,
            limit: limit, offset: 0, elapsed: elapsed
        )
        return QueryResult(
            page: page,
            commandTag: outcome.sets.last?.commandTag,
            notices: outcome.notices.map(\.noticeLine)
        )
    }
}

/// Post-processing of server text output for the two types where the app
/// relies on a different shape than psql prints.
enum TextValue {
    static func normaliser(for typeName: String) -> (String) -> String {
        switch typeName {
        case "boolean":
            return { $0 == "t" ? "true" : ($0 == "f" ? "false" : $0) }
        case "geometry", "geography":
            // PostGIS text output is hex EWKB; the inline map and spatial
            // sniffing expect (E)WKT.
            return { hex in ewkt(fromHex: hex) ?? hex }
        default:
            return { $0 }
        }
    }

    static func ewkt(fromHex hex: String) -> String? {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0, !utf8.isEmpty else { return nil }
        var buffer = ByteBuffer()
        buffer.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else { return nil }
            buffer.writeInteger(hi << 4 | lo)
            i += 2
        }
        return EWKB.toEWKT(buffer)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
