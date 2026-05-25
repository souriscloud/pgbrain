import Foundation
import NIOCore
import NIOSSL
import PostgresNIO

/// Pipes a table (or arbitrary subset of columns) from one Postgres
/// connection to another. Bytes never touch disk — rows stream from
/// `sourceClient` via a typed `SELECT` and land in `targetClient`'s
/// `copyFrom` writer using the Postgres COPY TEXT format.
///
/// For "extreme" cases (multi-million-row tables, slow client links) this
/// is the right shape: row sequence stays lazy on both ends, the worst-case
/// memory hit is a single 64KB ByteBuffer.
enum CrossDBCopy {
    enum Strategy: String, CaseIterable, Identifiable {
        case append, truncateAndInsert
        var id: String { rawValue }
        var uiLabel: String {
            switch self {
            case .append: return "Append (keep existing rows)"
            case .truncateAndInsert: return "Truncate then insert"
            }
        }
    }

    struct Mapping: Sendable {
        let sourceColumn: ColumnNode
        let targetColumnName: String
    }

    struct Plan: Sendable {
        let source: TableNode
        let sourceClient: PostgresClient
        let target: TargetEndpoint
        let targetSchema: String
        let targetTable: String
        let strategy: Strategy
        let mappings: [Mapping]
    }

    /// Either an already-leased client (when the target is currently open in
    /// another window) or a `Connection` we need to bring up a transient
    /// client for.
    enum TargetEndpoint {
        case existing(PostgresClient)
        case transient(Connection, password: String)
    }

    struct Stats: Sendable {
        var rowsCopied: Int
        var elapsed: TimeInterval
    }

    static func execute(
        plan: Plan,
        tracker: OperationsCenter? = nil,
        operationID: UUID? = nil
    ) async throws -> Stats {
        let started = Date()
        let qualifiedSource = SQLIdent.qualified(schema: plan.source.schema, name: plan.source.name)
        let projection = plan.mappings
            .map { "\(SQLIdent.quote($0.sourceColumn.name))::text" }
            .joined(separator: ", ")
        let selectSQL = "SELECT \(projection) FROM \(qualifiedSource)"

        let targetColumns = plan.mappings.map { $0.targetColumnName }
        let rowCount = RowCountBox()

        // Bring up a transient target client if needed; tear it down on exit.
        try await withTargetClient(plan.target) { targetClient in
            try await plan.sourceClient.withConnection { sourceConn in
                if let opID = operationID, let tracker {
                    let pid = try await OperationsHelpers.fetchBackendPID(sourceConn, logger: pgbrainQuietLogger)
                    let cancel: @Sendable () async -> Void = { [weak sourceClient = plan.sourceClient] in
                        guard let sourceClient else { return }
                        _ = try? await sourceClient.withConnection { sister in
                            _ = try await sister.query(
                                PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(pid))"),
                                logger: pgbrainQuietLogger
                            )
                        }
                    }
                    Task { @MainActor in
                        tracker.attachCancellation(toOperationID: opID, pid: pid, handler: cancel)
                    }
                }

                try await targetClient.withConnection { targetConn in
                    _ = try await targetConn.query(
                        PostgresQuery(unsafeSQL: "BEGIN"),
                        logger: pgbrainQuietLogger
                    )
                    do {
                        _ = try await targetConn.query(
                            PostgresQuery(unsafeSQL: "SET LOCAL search_path = \(SQLIdent.quote(plan.targetSchema))"),
                            logger: pgbrainQuietLogger
                        )
                        if plan.strategy == .truncateAndInsert {
                            let qualifiedTarget = SQLIdent.qualified(schema: plan.targetSchema, name: plan.targetTable)
                            _ = try await targetConn.query(
                                PostgresQuery(unsafeSQL: "TRUNCATE \(qualifiedTarget)"),
                                logger: pgbrainQuietLogger
                            )
                        }
                        try await targetConn.copyFrom(
                            table: plan.targetTable,
                            columns: targetColumns,
                            format: .text(.init()),
                            logger: pgbrainQuietLogger
                        ) { writer in
                            var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
                            let stream = try await sourceConn.query(
                                PostgresQuery(unsafeSQL: selectSQL),
                                logger: pgbrainQuietLogger
                            )
                            for try await row in stream {
                                try Task.checkCancellation()
                                let random = PostgresRandomAccessRow(row)
                                for i in 0..<plan.mappings.count {
                                    if i > 0 { buffer.writeString("\t") }
                                    let cell = random[i]
                                    if cell.bytes == nil {
                                        buffer.writeString("\\N")
                                    } else if let v = try? cell.decode(String.self, context: .default) {
                                        buffer.writeString(copyTextEscape(v))
                                    } else {
                                        buffer.writeString("\\N")
                                    }
                                }
                                buffer.writeString("\n")
                                rowCount.add(1)
                                if buffer.readableBytes >= 64 * 1024 {
                                    try await writer.write(buffer)
                                    buffer.clear()
                                }
                            }
                            if buffer.readableBytes > 0 {
                                try await writer.write(buffer)
                            }
                        }
                        _ = try await targetConn.query(
                            PostgresQuery(unsafeSQL: "COMMIT"),
                            logger: pgbrainQuietLogger
                        )
                    } catch {
                        _ = try? await targetConn.query(
                            PostgresQuery(unsafeSQL: "ROLLBACK"),
                            logger: pgbrainQuietLogger
                        )
                        throw error
                    }
                }
            }
        }

        return Stats(rowsCopied: rowCount.value, elapsed: Date().timeIntervalSince(started))
    }

    private static func withTargetClient<T: Sendable>(
        _ endpoint: TargetEndpoint,
        _ body: (PostgresClient) async throws -> T
    ) async throws -> T {
        switch endpoint {
        case .existing(let client):
            return try await body(client)
        case .transient(let connection, let password):
            let tls = try Self.tlsConfig(for: connection.sslMode)
            let config = PostgresClient.Configuration(
                host: connection.host,
                port: connection.port,
                username: connection.username,
                password: password.isEmpty ? nil : password,
                database: connection.database.isEmpty ? nil : connection.database,
                tls: tls
            )
            let client = PostgresClient(configuration: config)
            // Detached task drives the client's I/O loop. Cancelling on exit
            // brings down the pool's connections so we don't leak FDs.
            let runTask = Task.detached(priority: .userInitiated) {
                await client.run()
            }
            defer { runTask.cancel() }
            return try await body(client)
        }
    }

    private static func tlsConfig(for mode: Connection.SSLMode) throws -> PostgresClient.Configuration.TLS {
        switch mode {
        case .disable: return .disable
        case .allow, .prefer: return .prefer(TLSConfiguration.makeClientConfiguration())
        case .require, .verifyCA, .verifyFull: return .require(TLSConfiguration.makeClientConfiguration())
        }
    }

    /// Same escape rules as the Importer's CSV→COPY transcoder.
    private static func copyTextEscape(_ s: String) -> String {
        if !s.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            return s
        }
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    enum CopyError: LocalizedError {
        case transientClientGone

        var errorDescription: String? {
            switch self {
            case .transientClientGone: return "Lost transient connection during copy."
            }
        }
    }
}

/// Sendable mutable counter (the copy closure runs in a non-main context).
private final class RowCountBox: @unchecked Sendable {
    private(set) var value: Int = 0
    private let lock = NSLock()
    func add(_ n: Int) {
        lock.lock()
        value += n
        lock.unlock()
    }
}
