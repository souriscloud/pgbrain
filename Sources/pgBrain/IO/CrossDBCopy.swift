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
        case append, truncateAndInsert, upsert
        var id: String { rawValue }
        var uiLabel: String {
            switch self {
            case .append: return "Append (keep existing rows)"
            case .truncateAndInsert: return "Truncate then insert"
            case .upsert: return "Upsert (insert or update on conflict)"
            }
        }
        /// The upsert strategy needs a conflict target (the columns whose
        /// collision triggers an UPDATE instead of a failed INSERT).
        var needsConflictColumns: Bool { self == .upsert }
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
        /// Create the target table (from the source column types) when it
        /// doesn't already exist, instead of failing the copy.
        let autoCreate: Bool
        /// Conflict-target columns for `.upsert`. Ignored by other strategies.
        let conflictColumns: [String]

        init(source: TableNode, sourceClient: PostgresClient, target: TargetEndpoint,
             targetSchema: String, targetTable: String, strategy: Strategy,
             mappings: [Mapping], autoCreate: Bool = false, conflictColumns: [String] = []) {
            self.source = source
            self.sourceClient = sourceClient
            self.target = target
            self.targetSchema = targetSchema
            self.targetTable = targetTable
            self.strategy = strategy
            self.mappings = mappings
            self.autoCreate = autoCreate
            self.conflictColumns = conflictColumns
        }
    }

    // MARK: - SQL builders (pure)

    /// `CREATE TABLE IF NOT EXISTS schema.table (target_col source_type, …)` —
    /// each target column adopts its source column's declared type.
    static func createTableSQL(schema: String, table: String, mappings: [Mapping]) -> String {
        let cols = mappings.map { "\(SQLIdent.quote($0.targetColumnName)) \($0.sourceColumn.typeName)" }
        return "CREATE TABLE IF NOT EXISTS \(SQLIdent.qualified(schema: schema, name: table)) (\(cols.joined(separator: ", ")))"
    }

    /// `INSERT INTO target (cols) SELECT cols FROM temp ON CONFLICT (keys) …` —
    /// non-key columns are refreshed from `EXCLUDED`; if every column is part of
    /// the conflict key there's nothing to update, so it degrades to DO NOTHING.
    static func upsertSQL(fromTemp tempTable: String, schema: String, table: String,
                          targetColumns: [String], conflictColumns: [String]) -> String {
        let target = SQLIdent.qualified(schema: schema, name: table)
        let colList = targetColumns.map { SQLIdent.quote($0) }.joined(separator: ", ")
        let conflictList = conflictColumns.map { SQLIdent.quote($0) }.joined(separator: ", ")
        let updateCols = targetColumns.filter { !conflictColumns.contains($0) }
        let action: String
        if updateCols.isEmpty {
            action = "DO NOTHING"
        } else {
            let sets = updateCols.map { "\(SQLIdent.quote($0)) = EXCLUDED.\(SQLIdent.quote($0))" }
                .joined(separator: ", ")
            action = "DO UPDATE SET \(sets)"
        }
        return "INSERT INTO \(target) (\(colList)) SELECT \(colList) FROM \(SQLIdent.quote(tempTable)) "
            + "ON CONFLICT (\(conflictList)) \(action)"
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
                        let qualifiedTarget = SQLIdent.qualified(schema: plan.targetSchema, name: plan.targetTable)
                        if plan.autoCreate {
                            _ = try await targetConn.query(
                                PostgresQuery(unsafeSQL: createTableSQL(
                                    schema: plan.targetSchema, table: plan.targetTable, mappings: plan.mappings)),
                                logger: pgbrainQuietLogger
                            )
                        }
                        // Pick the COPY target: upsert stages into a temp table
                        // (dropped on commit) so we can INSERT … ON CONFLICT from it
                        // afterwards; other strategies copy straight into the table.
                        let copyTarget: String
                        var tempName: String? = nil
                        if plan.strategy == .upsert {
                            let tmp = "_pgb_copy_" + UUID().uuidString.prefix(8).lowercased()
                            _ = try await targetConn.query(
                                PostgresQuery(unsafeSQL: "CREATE TEMP TABLE \(SQLIdent.quote(tmp)) (LIKE \(qualifiedTarget) INCLUDING DEFAULTS) ON COMMIT DROP"),
                                logger: pgbrainQuietLogger
                            )
                            tempName = tmp
                            copyTarget = tmp
                        } else {
                            if plan.strategy == .truncateAndInsert {
                                _ = try await targetConn.query(
                                    PostgresQuery(unsafeSQL: "TRUNCATE \(qualifiedTarget)"),
                                    logger: pgbrainQuietLogger
                                )
                            }
                            copyTarget = plan.targetTable
                        }
                        try await targetConn.copyFrom(
                            table: copyTarget,
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
                        // Upsert: fold the staged temp rows into the real table.
                        if plan.strategy == .upsert, let tempName {
                            _ = try await targetConn.query(
                                PostgresQuery(unsafeSQL: upsertSQL(
                                    fromTemp: tempName, schema: plan.targetSchema, table: plan.targetTable,
                                    targetColumns: targetColumns, conflictColumns: plan.conflictColumns)),
                                logger: pgbrainQuietLogger
                            )
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
