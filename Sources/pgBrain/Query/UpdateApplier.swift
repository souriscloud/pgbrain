import Foundation
import Logging
import PostgresNIO

/// Commits a batch of `EditBuffer` edits as `UPDATE` statements against the
/// source table. One transaction per Apply — any failed row aborts the batch
/// so the user never sees a partial write.
///
/// Identifier interpolation goes through `SQLIdent`; cell values are bound as
/// parameters, then cast server-side to the column's declared type via
/// `$N::"<type_name>"`. That lets us roundtrip strings for everything from
/// `integer` to `jsonb` without needing per-type Swift encoders here.
enum UpdateApplier {
    struct Edit: Sendable {
        let rowIndex: Int             // index into the original page.rows
        let cells: [CellChange]
    }

    struct CellChange: Sendable {
        let column: ColumnNode
        let newValue: String?
    }

    enum Failure: Error, LocalizedError {
        case noPrimaryKey
        case unknownPrimaryKeyColumn(String)

        var errorDescription: String? {
            switch self {
            case .noPrimaryKey:
                return "This table has no primary key; rows can't be addressed for an UPDATE."
            case .unknownPrimaryKeyColumn(let name):
                return "Primary-key column \"\(name)\" isn't in the loaded result set."
            }
        }
    }

    /// Apply all `edits` against `table` using `client`. Resolves PK values by
    /// reading them out of `originalRows` (the snapshot the grid is showing).
    /// Throws on first failure — caller's transaction is already rolled back
    /// by `withTransaction`. Pass `bind` to register a cancellable operation
    /// so the user can cancel the in-flight UPDATE batch from the ops popover.
    static func apply(
        edits: [Edit],
        table: TableNode,
        originalRows: [[String?]],
        client: PostgresClient,
        operationID: UUID? = nil,
        tracker: OperationsCenter? = nil
    ) async throws {
        guard table.isEditable else { throw Failure.noPrimaryKey }
        let pkColumns = table.primaryKeyColumns
        guard pkColumns.count == table.primaryKey.count else {
            let missing = table.primaryKey.first(where: { name in
                !table.columns.contains(where: { $0.name == name })
            }) ?? "?"
            throw Failure.unknownPrimaryKeyColumn(missing)
        }

        let columnIndexByName = Dictionary(uniqueKeysWithValues:
            table.columns.enumerated().map { ($0.element.name, $0.offset) })

        let qualifiedTable = SQLIdent.qualified(schema: table.schema, name: table.name)
        let logger = pgbrainQuietLogger

        try await client.withTransaction(logger: logger) { connection in
            if let opID = operationID, let tracker {
                let pid = try await OperationsHelpers.fetchBackendPID(connection, logger: logger)
                let cancelHandler: @Sendable () async -> Void = { [weak client] in
                    guard let client else { return }
                    _ = try? await client.withConnection { sister in
                        _ = try await sister.query(
                            PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(pid))"),
                            logger: logger
                        )
                    }
                }
                Task { @MainActor in
                    tracker.attachCancellation(toOperationID: opID, pid: pid, handler: cancelHandler)
                }
            }
            for edit in edits {
                guard edit.rowIndex < originalRows.count else { continue }
                let originalRow = originalRows[edit.rowIndex]

                // SET clauses with positional binds + server-side casts.
                var binds = PostgresBindings()
                var setPieces: [String] = []
                for (index, change) in edit.cells.enumerated() {
                    let placeholder = "$\(index + 1)"
                    let typeCast = "::" + SQLIdent.quote(change.column.typeName)
                    setPieces.append("\(SQLIdent.quote(change.column.name)) = \(placeholder)\(typeCast)")
                    if let v = change.newValue {
                        binds.append(v)
                    } else {
                        binds.appendNull()
                    }
                }

                // WHERE pk1 = $N+1 AND pk2 = $N+2 ...
                var wherePieces: [String] = []
                for (offset, pkCol) in pkColumns.enumerated() {
                    guard let colIndex = columnIndexByName[pkCol.name] else {
                        throw Failure.unknownPrimaryKeyColumn(pkCol.name)
                    }
                    let placeholderIndex = edit.cells.count + offset + 1
                    let placeholder = "$\(placeholderIndex)"
                    let typeCast = "::" + SQLIdent.quote(pkCol.typeName)
                    wherePieces.append("\(SQLIdent.quote(pkCol.name)) = \(placeholder)\(typeCast)")
                    if let v = originalRow[colIndex] {
                        binds.append(v)
                    } else {
                        // PK columns shouldn't be NULL but bind defensively.
                        binds.appendNull()
                    }
                }

                let sql = "UPDATE \(qualifiedTable) SET \(setPieces.joined(separator: ", ")) WHERE \(wherePieces.joined(separator: " AND "))"
                let query = PostgresQuery(unsafeSQL: sql, binds: binds)
                _ = try await connection.query(query, logger: logger)
            }
        }
    }
}
