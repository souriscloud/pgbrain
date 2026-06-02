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
        let value: Value

        /// How the new cell value reaches SQL.
        enum Value: Sendable, Equatable {
            case literal(String?)     // bound param, cast `$N::type`; nil = NULL
            case expression(String)   // inlined raw SQL, implicit assignment cast
            case defaultKeyword       // the column DEFAULT
        }

        /// Convenience for the common literal/NULL path so existing call
        /// sites keep reading naturally.
        init(column: ColumnNode, newValue: String?) {
            self.column = column
            self.value = .literal(newValue)
        }

        init(column: ColumnNode, value: Value) {
            self.column = column
            self.value = value
        }

        /// Bridge from the edit buffer's staged entry.
        init(column: ColumnNode, entry: EditBuffer.Entry) {
            self.column = column
            switch entry {
            case .literal(let v):    self.value = .literal(v)
            case .expression(let e): self.value = .expression(e)
            case .defaultKeyword:    self.value = .defaultKeyword
            }
        }
    }

    /// A brand-new row to INSERT. `cells` holds only the columns the user
    /// actually filled in — every other column is left out so the table's
    /// DEFAULT (identity sequences, `now()`, …) applies. An empty `cells`
    /// becomes `INSERT … DEFAULT VALUES`.
    struct Insert: Sendable {
        let cells: [CellChange]
    }

    /// An existing row to DELETE, addressed by its primary key. `rowIndex`
    /// points into `originalRows` so PK values can be read out of the snapshot.
    struct Delete: Sendable {
        let rowIndex: Int
    }

    enum Failure: Error, LocalizedError {
        case noPrimaryKey
        case unknownPrimaryKeyColumn(String)
        case staleRow(String)

        var errorDescription: String? {
            switch self {
            case .noPrimaryKey:
                return "This table has no primary key; rows can't be addressed for an UPDATE."
            case .unknownPrimaryKeyColumn(let name):
                return "Primary-key column \"\(name)\" isn't in the loaded result set."
            case .staleRow(let pk):
                return "The row \(pk) no longer exists — it was deleted or its key changed since this grid loaded. Nothing was saved; refresh and try again."
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
        inserts: [Insert] = [],
        deletes: [Delete] = [],
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

        do {
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
                // Type names from `format_type()` are already in canonical
                // PG syntax (`integer`, `timestamp with time zone`,
                // `character varying(255)`, …) and MUST NOT be wrapped in
                // double quotes — quoting makes PG look up a
                // case-sensitive user-defined type with that literal
                // name (`type "bigint" does not exist`).
                // Only literal cells consume a bind placeholder; expression
                // and DEFAULT cells inline raw SQL, so we count binds as we
                // go rather than assuming one per cell.
                var binds = PostgresBindings()
                var setPieces: [String] = []
                var bindCount = 0
                for change in edit.cells {
                    let name = SQLIdent.quote(change.column.name)
                    switch change.value {
                    case .literal(let v):
                        bindCount += 1
                        let placeholder = "$\(bindCount)"
                        setPieces.append("\(name) = \(placeholder)::\(change.column.typeName)")
                        if let v { binds.append(v) } else { binds.appendNull() }
                    case .expression(let expr):
                        // Assignment context casts the expression to the
                        // column type implicitly (`col = now()`), so no `::`.
                        setPieces.append("\(name) = \(expr)")
                    case .defaultKeyword:
                        setPieces.append("\(name) = DEFAULT")
                    }
                }
                guard !setPieces.isEmpty else { continue }

                // WHERE pk1 = $N+1 AND pk2 = $N+2 ...
                var wherePieces: [String] = []
                var pkDisplay: [String] = []
                for (offset, pkCol) in pkColumns.enumerated() {
                    guard let colIndex = columnIndexByName[pkCol.name] else {
                        throw Failure.unknownPrimaryKeyColumn(pkCol.name)
                    }
                    let placeholderIndex = bindCount + offset + 1
                    let placeholder = "$\(placeholderIndex)"
                    let typeCast = "::" + pkCol.typeName
                    wherePieces.append("\(SQLIdent.quote(pkCol.name)) = \(placeholder)\(typeCast)")
                    pkDisplay.append("\(pkCol.name)=\(originalRow[colIndex] ?? "NULL")")
                    if let v = originalRow[colIndex] {
                        binds.append(v)
                    } else {
                        // PK columns shouldn't be NULL but bind defensively.
                        binds.appendNull()
                    }
                }

                let sql = "UPDATE \(qualifiedTable) SET \(setPieces.joined(separator: ", ")) WHERE \(wherePieces.joined(separator: " AND "))"
                let query = PostgresQuery(unsafeSQL: sql, binds: binds)
                // Materialise so we can read the affected-row count: a 0-row
                // UPDATE means the row was deleted (or its PK changed) between
                // load and apply. Surface that instead of silently "succeeding"
                // — throwing rolls back the whole batch via withTransaction.
                let result = try await connection.query(query, logger: logger).get()
                if result.metadata.rows == 0 {
                    throw Failure.staleRow(pkDisplay.joined(separator: ", "))
                }
            }

            // INSERTs run after UPDATEs, still inside the one transaction.
            for insert in inserts {
                if insert.cells.isEmpty {
                    let sql = "INSERT INTO \(qualifiedTable) DEFAULT VALUES"
                    _ = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    continue
                }
                var binds = PostgresBindings()
                var cols: [String] = []
                var placeholders: [String] = []
                var bindCount = 0
                for change in insert.cells {
                    switch change.value {
                    case .defaultKeyword:
                        // Omit the column entirely so the table DEFAULT
                        // (identity sequence, now(), …) applies.
                        continue
                    case .literal(let v):
                        cols.append(SQLIdent.quote(change.column.name))
                        bindCount += 1
                        placeholders.append("$\(bindCount)::" + change.column.typeName)
                        if let v { binds.append(v) } else { binds.appendNull() }
                    case .expression(let expr):
                        cols.append(SQLIdent.quote(change.column.name))
                        placeholders.append(expr)
                    }
                }
                // Every staged cell resolved to DEFAULT → fall back to the
                // all-defaults insert.
                if cols.isEmpty {
                    _ = try await connection.query(
                        PostgresQuery(unsafeSQL: "INSERT INTO \(qualifiedTable) DEFAULT VALUES"),
                        logger: logger)
                    continue
                }
                let sql = "INSERT INTO \(qualifiedTable) (\(cols.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
                _ = try await connection.query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: logger)
            }

            // DELETEs run last, still inside the one transaction. Each row is
            // addressed by its full primary key, read from the snapshot.
            for del in deletes {
                guard del.rowIndex < originalRows.count else { continue }
                let originalRow = originalRows[del.rowIndex]
                var binds = PostgresBindings()
                var wherePieces: [String] = []
                for (offset, pkCol) in pkColumns.enumerated() {
                    guard let colIndex = columnIndexByName[pkCol.name] else {
                        throw Failure.unknownPrimaryKeyColumn(pkCol.name)
                    }
                    if let v = originalRow[colIndex] {
                        let placeholder = "$\(offset + 1)"
                        wherePieces.append("\(SQLIdent.quote(pkCol.name)) = \(placeholder)::" + pkCol.typeName)
                        binds.append(v)
                    } else {
                        // A NULL PK component can't be matched by `=`; use IS NULL.
                        wherePieces.append("\(SQLIdent.quote(pkCol.name)) IS NULL")
                    }
                }
                let sql = "DELETE FROM \(qualifiedTable) WHERE \(wherePieces.joined(separator: " AND "))"
                _ = try await connection.query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: logger)
            }
        }
        } catch let txError as PostgresTransactionError {
            // withTransaction wraps a thrown closure error; surface the real
            // cause (our Failure / the server's PSQLError) so callers show a
            // meaningful message instead of the opaque transaction wrapper.
            throw txError.closureError ?? txError
        }
    }
}
