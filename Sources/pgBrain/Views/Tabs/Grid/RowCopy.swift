import AppKit

/// "Copy rows as…" renderers for the grid's context menu. Values are the
/// grid's effective ones (pending edits included); SQL statements address
/// rows by their *loaded* key so a copied UPDATE targets the row as the
/// server still has it.
enum RowCopy {
    enum Format: String, CaseIterable, Identifiable {
        case tsv, csv, json, markdown, slack, insert, update, delete
        var id: String { rawValue }

        var label: String {
            switch self {
            case .tsv: return "TSV (with header)"
            case .csv: return "CSV"
            case .json: return "JSON"
            case .markdown: return "Markdown table"
            case .slack: return "Slack code block"
            case .insert: return "INSERT statements"
            case .update: return "UPDATE statements"
            case .delete: return "DELETE statements"
            }
        }

        var needsTable: Bool { self == .insert || self == .update || self == .delete }
    }

    /// Where SQL formats point. Nil on grids without a backing table.
    struct Target: Sendable {
        let schema: String
        let table: String
        let primaryKey: [String]
    }

    struct Rows {
        let columns: [ColumnNode]
        /// What the grid shows (pending values applied).
        let effective: [[String?]]
        /// What the server returned — keys for UPDATE / DELETE.
        let original: [[String?]]
        let locators: [String?]?
    }

    static func text(_ format: Format, rows: Rows, target: Target?) -> String? {
        switch format {
        case .tsv, .csv, .json, .markdown:
            return nil
        case .slack:
            return slack(rows)
        case .insert:
            guard let target else { return nil }
            return insert(rows, target)
        case .update:
            guard let target else { return nil }
            return rows.effective.indices.compactMap { update(rows, $0, target) }.joined(separator: "\n")
        case .delete:
            guard let target else { return nil }
            return rows.effective.indices.compactMap { i in
                keyPredicate(rows, i, target).map { "DELETE FROM \(qualified(target)) WHERE \($0);" }
            }.joined(separator: "\n")
        }
    }

    /// Put `format` on the pasteboard; returns the row count for a toast.
    @MainActor
    @discardableResult
    static func copy(_ format: Format, rows: Rows, target: Target?) -> Int {
        let clip: ClipboardCopy.Format?
        switch format {
        case .tsv: clip = .tsv
        case .csv: clip = .csv
        case .json: clip = .json
        case .markdown: clip = .markdown
        default: clip = nil
        }
        if let clip {
            let page = RowsFetcher.Page(columns: rows.columns, rows: rows.effective, truncated: false,
                                        limit: rows.effective.count, offset: 0, elapsed: 0)
            return ClipboardCopy.copy(page, as: clip)
        }
        guard let text = text(format, rows: rows, target: target), !text.isEmpty else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return rows.effective.count
    }

    private static func qualified(_ t: Target) -> String {
        SQLIdent.qualified(schema: t.schema, name: t.table)
    }

    private static func insert(_ rows: Rows, _ target: Target) -> String {
        let cols = rows.columns.map { SQLIdent.quote($0.name) }.joined(separator: ", ")
        let values = rows.effective.map { row in
            "(" + rows.columns.indices.map { i in
                UpdateApplier.typedLiteral(i < row.count ? row[i] : nil, typeName: rows.columns[i].typeName)
            }.joined(separator: ", ") + ")"
        }
        return "INSERT INTO \(qualified(target)) (\(cols)) VALUES\n" + values.joined(separator: ",\n") + ";"
    }

    private static func update(_ rows: Rows, _ i: Int, _ target: Target) -> String? {
        guard let predicate = keyPredicate(rows, i, target) else { return nil }
        let row = rows.effective[i]
        let sets = rows.columns.indices
            .filter { !target.primaryKey.contains(rows.columns[$0].name) }
            .map { c in
                "\(SQLIdent.quote(rows.columns[c].name)) = \(UpdateApplier.typedLiteral(c < row.count ? row[c] : nil, typeName: rows.columns[c].typeName))"
            }
        guard !sets.isEmpty else { return nil }
        return "UPDATE \(qualified(target)) SET \(sets.joined(separator: ", ")) WHERE \(predicate);"
    }

    /// `pk = …` from the loaded values, or the physical location when the
    /// table has no primary key.
    private static func keyPredicate(_ rows: Rows, _ i: Int, _ target: Target) -> String? {
        guard i < rows.original.count else { return nil }
        let original = rows.original[i]
        if target.primaryKey.isEmpty {
            guard let locs = rows.locators, i < locs.count, let loc = locs[i], let at = loc.lastIndex(of: "@") else { return nil }
            return "ctid = \(UpdateApplier.quoteLiteral(String(loc[..<at])))::tid"
        }
        let pieces = target.primaryKey.compactMap { name -> String? in
            guard let c = rows.columns.firstIndex(where: { $0.name == name }) else { return nil }
            let v = c < original.count ? original[c] : nil
            guard let v else { return "\(SQLIdent.quote(name)) IS NULL" }
            return "\(SQLIdent.quote(name)) = \(UpdateApplier.typedLiteral(v, typeName: rows.columns[c].typeName))"
        }
        return pieces.count == target.primaryKey.count ? pieces.joined(separator: " AND ") : nil
    }

    /// Monospaced, space-padded block for pasting into chat.
    private static func slack(_ rows: Rows) -> String {
        let names = rows.columns.map(\.name)
        let cells = rows.effective.map { row in
            names.indices.map { i in (i < row.count ? row[i] : nil).map { $0.replacingOccurrences(of: "\n", with: " ") } ?? "NULL" }
        }
        var widths = names.map(\.count)
        for row in cells { for (i, c) in row.enumerated() { widths[i] = max(widths[i], c.count) } }
        func line(_ values: [String]) -> String {
            values.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }
        var lines = ["```", line(names), line(widths.map { String(repeating: "-", count: $0) })]
        lines += cells.map(line)
        lines.append("```")
        return lines.joined(separator: "\n")
    }
}
