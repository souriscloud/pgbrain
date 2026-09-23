import Foundation
import Logging
import PostgresNIO

/// Commits a batch of staged grid changes — UPDATEs, INSERTs and DELETEs —
/// in one transaction. Any statement that fails, or that doesn't touch
/// exactly one row, aborts the whole batch so the user never sees a partial
/// write.
///
/// Identifier interpolation goes through `SQLIdent`; cell values are bound as
/// parameters, then cast server-side to the column's declared type via
/// `$N::type`. Every write carries a `RETURNING` of the grid's own text
/// projection, so the caller can splice back exactly what the server stored
/// (normalised numerics, trimmed `char(n)`, trigger-set columns, identity
/// values) instead of what was typed.
///
/// Optimistic concurrency: an UPDATE's WHERE also requires each edited
/// column to still hold the value the grid loaded. If someone else changed
/// it (or deleted the row) the UPDATE touches zero rows and the batch fails
/// with `.staleRow`.
enum UpdateApplier {
    struct Edit: Sendable {
        let rowIndex: Int             // index into originalRows
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

            init(_ entry: EditBuffer.Entry) {
                switch entry {
                case .literal(let v):    self = .literal(v)
                case .expression(let e): self = .expression(e)
                case .defaultKeyword:    self = .defaultKeyword
                }
            }
        }

        init(column: ColumnNode, newValue: String?) {
            self.column = column
            self.value = .literal(newValue)
        }

        init(column: ColumnNode, value: Value) {
            self.column = column
            self.value = value
        }

        init(column: ColumnNode, entry: EditBuffer.Entry) {
            self.column = column
            self.value = Value(entry)
        }
    }

    /// A brand-new row to INSERT. `cells` holds only the columns the user
    /// actually filled in — every other column is left out so the table's
    /// DEFAULT applies. An empty `cells` becomes `INSERT … DEFAULT VALUES`.
    struct Insert: Sendable {
        let cells: [CellChange]
    }

    /// An existing row to DELETE. `rowIndex` points into `originalRows`.
    struct Delete: Sendable {
        let rowIndex: Int
    }

    enum Failure: Error, LocalizedError, Equatable {
        case notEditable
        case unknownPrimaryKeyColumn(String)
        case staleRow(String)
        case missingRowLocator(Int)

        var errorDescription: String? {
            switch self {
            case .notEditable:
                return "This relation isn't editable (views and materialized views are read-only)."
            case .unknownPrimaryKeyColumn(let name):
                return "Primary-key column \"\(name)\" isn't in the loaded result set."
            case .staleRow(let row):
                return "The row \(row) was changed or deleted by someone else since this grid loaded. Nothing was saved — reload to see the current data, then re-apply."
            case .missingRowLocator(let index):
                return "Row \(index + 1) has no physical locator; reload the grid and try again."
            }
        }
    }

    struct Statement: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case update(rowIndex: Int)
            case insert(index: Int)
            case delete(rowIndex: Int)
        }
        let kind: Kind
        let sql: String
        let binds: [String?]
        /// Human-readable row address for error messages ("id=4").
        let rowLabel: String
    }

    /// What the server stored, in the grid's text projection.
    struct Outcome: Sendable, Equatable {
        var updatedRows: [Int: [String?]] = [:]
        var updatedLocators: [Int: String] = [:]
        var insertedRows: [[String?]] = []
        var insertedLocators: [String?] = []
        var deletedRows: [Int] = []
    }

    // MARK: - Planning

    /// Build the exact statements `apply` will run, in order. Pure — used by
    /// the "Preview SQL" sheet and by the tests.
    static func plan(
        edits: [Edit],
        inserts: [Insert] = [],
        deletes: [Delete] = [],
        table: TableNode,
        originalRows: [[String?]],
        rowLocators: [String?]? = nil,
        spatial: Bool = false
    ) throws -> [Statement] {
        let identity = RowsFetcher.RowIdentity.resolve(for: table)
        switch identity {
        case .readOnly:
            if table.kind == .table, let missing = table.primaryKey.first(where: { name in
                !table.columns.contains(where: { $0.name == name })
            }) {
                throw Failure.unknownPrimaryKeyColumn(missing)
            }
            throw Failure.notEditable
        case .primaryKey, .physical:
            break
        }
        let columnIndexByName = Dictionary(
            table.columns.enumerated().map { ($0.element.name, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let qualified = SQLIdent.qualified(schema: table.schema, name: table.name)
        let returning = "\nRETURNING " + RowsFetcher.projection(columns: table.columns, spatial: spatial, identity: identity)

        var out: [Statement] = []

        func locate(_ rowIndex: Int, binds: inout [String?]) throws -> (sql: String, label: String) {
            let row = originalRows[rowIndex]
            switch identity {
            case .primaryKey(let pkCols):
                var pieces: [String] = []
                var label: [String] = []
                for pkCol in pkCols {
                    guard let idx = columnIndexByName[pkCol.name] else {
                        throw Failure.unknownPrimaryKeyColumn(pkCol.name)
                    }
                    let v = idx < row.count ? row[idx] : nil
                    label.append("\(pkCol.name)=\(v ?? "NULL")")
                    if let v {
                        binds.append(v)
                        pieces.append("\(SQLIdent.quote(pkCol.name)) = $\(binds.count)::\(pkCol.typeName)")
                    } else {
                        pieces.append("\(SQLIdent.quote(pkCol.name)) IS NULL")
                    }
                }
                return (pieces.joined(separator: " AND "), label.joined(separator: ", "))
            case .physical:
                guard let locators = rowLocators, rowIndex < locators.count,
                      let loc = locators[rowIndex], let at = loc.lastIndex(of: "@")
                else { throw Failure.missingRowLocator(rowIndex) }
                let ctid = String(loc[..<at])
                let oid = String(loc[loc.index(after: at)...])
                binds.append(ctid)
                let ctidParam = binds.count
                binds.append(oid)
                return ("ctid = $\(ctidParam)::tid AND tableoid = $\(binds.count)::oid", "ctid=\(ctid)")
            case .readOnly:
                throw Failure.notEditable
            }
        }

        for edit in edits {
            guard edit.rowIndex >= 0, edit.rowIndex < originalRows.count, !edit.cells.isEmpty else { continue }
            let row = originalRows[edit.rowIndex]
            var binds: [String?] = []
            var setPieces: [String] = []
            // Type names from `format_type()` are already canonical SQL and
            // must not be quoted (`"bigint"` would name a user type).
            for change in edit.cells {
                let name = SQLIdent.quote(change.column.name)
                switch change.value {
                case .literal(let v):
                    binds.append(v)
                    setPieces.append("\(name) = $\(binds.count)::\(change.column.typeName)")
                case .expression(let expr):
                    // Newline so a trailing `-- comment` in the expression
                    // can't swallow the rest of the statement.
                    setPieces.append("\(name) = (\(expr)\n)")
                case .defaultKeyword:
                    setPieces.append("\(name) = DEFAULT")
                }
            }
            let (whereIdentity, label) = try locate(edit.rowIndex, binds: &binds)
            var guards: [String] = []
            for change in edit.cells {
                guard let idx = columnIndexByName[change.column.name] else { continue }
                let original = idx < row.count ? row[idx] : nil
                binds.append(original)
                guards.append("\(RowsFetcher.columnExpression(change.column, spatial: spatial)) IS NOT DISTINCT FROM $\(binds.count)::text")
            }
            let whereSQL = ([whereIdentity] + guards).joined(separator: "\n  AND ")
            let sql = "UPDATE \(qualified)\nSET \(setPieces.joined(separator: ",\n    "))\nWHERE \(whereSQL)\(returning)"
            out.append(Statement(kind: .update(rowIndex: edit.rowIndex), sql: sql, binds: binds, rowLabel: label))
        }

        for (i, insert) in inserts.enumerated() {
            var binds: [String?] = []
            var cols: [String] = []
            var values: [String] = []
            for change in insert.cells {
                switch change.value {
                case .defaultKeyword:
                    continue
                case .literal(let v):
                    cols.append(SQLIdent.quote(change.column.name))
                    binds.append(v)
                    values.append("$\(binds.count)::\(change.column.typeName)")
                case .expression(let expr):
                    cols.append(SQLIdent.quote(change.column.name))
                    values.append("(\(expr)\n)")
                }
            }
            let sql = cols.isEmpty
                ? "INSERT INTO \(qualified) DEFAULT VALUES\(returning)"
                : "INSERT INTO \(qualified) (\(cols.joined(separator: ", ")))\nVALUES (\(values.joined(separator: ", ")))\(returning)"
            out.append(Statement(kind: .insert(index: i), sql: sql, binds: binds, rowLabel: "new row \(i + 1)"))
        }

        for del in deletes {
            guard del.rowIndex >= 0, del.rowIndex < originalRows.count else { continue }
            var binds: [String?] = []
            let (whereIdentity, label) = try locate(del.rowIndex, binds: &binds)
            let sql = "DELETE FROM \(qualified)\nWHERE \(whereIdentity)"
            out.append(Statement(kind: .delete(rowIndex: del.rowIndex), sql: sql, binds: binds, rowLabel: label))
        }
        return out
    }

    /// The planned statements as one runnable script, bind values inlined as
    /// typed literals — what "Preview SQL" shows.
    static func previewScript(_ statements: [Statement]) -> String {
        guard !statements.isEmpty else { return "" }
        let body = statements.map { inlineBinds($0.sql, $0.binds) + ";" }.joined(separator: "\n\n")
        return "BEGIN;\n\n\(body)\n\nCOMMIT;"
    }

    /// Replace `$N` placeholders (outside quotes) with quoted literals.
    static func inlineBinds(_ sql: String, _ binds: [String?]) -> String {
        let chars = Array(sql)
        var out = ""
        var i = 0
        var quote: Character?
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                out.append(c)
                i += 1
                continue
            }
            if c == "$", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                if let n = Int(digits), n >= 1, n <= binds.count {
                    out += binds[n - 1].map(quoteLiteral) ?? "NULL"
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// A single-quoted SQL string literal. Escape-string syntax only when a
    /// backslash is present, so the result is correct under either
    /// `standard_conforming_strings` setting.
    static func quoteLiteral(_ s: String) -> String {
        let doubled = s.replacingOccurrences(of: "'", with: "''")
        if s.contains("\\") {
            return "E'" + doubled.replacingOccurrences(of: "\\", with: "\\\\") + "'"
        }
        return "'" + doubled + "'"
    }

    /// A typed SQL literal for hand-built text (WHERE fragments, clipboard
    /// INSERTs): always quoted and cast, so `NaN`, `Infinity`, `t` and
    /// friends can't escape as bare identifiers or keywords.
    static func typedLiteral(_ value: String?, typeName: String) -> String {
        guard let value else { return "NULL" }
        return "\(quoteLiteral(value))::\(typeName)"
    }

    // MARK: - Execution

    /// Run the batch in one transaction and report what the server stored.
    /// Pass `operationID` + `tracker` to make the batch cancellable from the
    /// operations popover.
    @discardableResult
    static func apply(
        edits: [Edit],
        inserts: [Insert] = [],
        deletes: [Delete] = [],
        table: TableNode,
        originalRows: [[String?]],
        rowLocators: [String?]? = nil,
        spatial: Bool = false,
        client: PostgresClient,
        operationID: UUID? = nil,
        tracker: OperationsCenter? = nil
    ) async throws -> Outcome {
        let statements = try plan(
            edits: edits, inserts: inserts, deletes: deletes, table: table,
            originalRows: originalRows, rowLocators: rowLocators, spatial: spatial)
        let columnCount = table.columns.count
        let physical = RowsFetcher.RowIdentity.resolve(for: table) == .physical
        let logger = pgbrainQuietLogger

        do {
            return try await client.withTransaction(logger: logger) { connection in
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
                var outcome = Outcome()
                for statement in statements {
                    var binds = PostgresBindings()
                    for b in statement.binds {
                        if let b { binds.append(b) } else { binds.appendNull() }
                    }
                    let result = try await connection.query(
                        PostgresQuery(unsafeSQL: statement.sql, binds: binds), logger: logger
                    ).get()
                    switch statement.kind {
                    case .update(let rowIndex):
                        guard let row = result.rows.first else { throw Failure.staleRow(statement.rowLabel) }
                        let random = PostgresRandomAccessRow(row)
                        outcome.updatedRows[rowIndex] = RowsFetcher.decodeText(random, count: columnCount)
                        if physical, let loc = RowsFetcher.decodeText(random, at: columnCount) {
                            outcome.updatedLocators[rowIndex] = loc
                        }
                    case .insert:
                        guard let row = result.rows.first else { continue }
                        let random = PostgresRandomAccessRow(row)
                        outcome.insertedRows.append(RowsFetcher.decodeText(random, count: columnCount))
                        outcome.insertedLocators.append(physical ? RowsFetcher.decodeText(random, at: columnCount) : nil)
                    case .delete(let rowIndex):
                        if (result.metadata.rows ?? 0) != 1 { throw Failure.staleRow(statement.rowLabel) }
                        outcome.deletedRows.append(rowIndex)
                    }
                }
                return outcome
            }
        } catch let txError as PostgresTransactionError {
            // withTransaction wraps a thrown closure error; surface the real
            // cause (our Failure / the server's PSQLError).
            throw txError.closureError ?? txError
        }
    }
}
