import AppKit

/// Formats an in-memory result `Page` into one of several text representations
/// and puts it on the general pasteboard. Distinct from `Exporter` (which
/// streams to a file at any size): this is for the small, already-materialised
/// result the user is looking at — "copy this so I can paste it into a doc, a
/// spreadsheet, or a code review".
enum ClipboardCopy {
    enum Format: String, CaseIterable, Identifiable {
        case markdown, json, tsv, csv
        var id: String { rawValue }
        var menuLabel: String {
            switch self {
            case .markdown: return "Markdown table"
            case .json: return "JSON"
            case .tsv: return "TSV (for spreadsheets)"
            case .csv: return "CSV"
            }
        }
    }

    /// Render `page` as `format` and place it on the pasteboard. Returns the
    /// number of rows copied so the caller can confirm via a toast.
    @discardableResult
    static func copy(_ page: RowsFetcher.Page, as format: Format) -> Int {
        let text: String
        switch format {
        case .markdown: text = markdown(page)
        case .json: text = json(page)
        case .tsv: text = delimited(page, separator: "\t")
        case .csv: text = delimited(page, separator: ",")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return page.rows.count
    }

    // MARK: - Renderers

    private static func markdown(_ page: RowsFetcher.Page) -> String {
        let names = page.columns.map(\.name)
        var lines: [String] = []
        lines.append("| " + names.map(escapeMarkdown).joined(separator: " | ") + " |")
        lines.append("| " + names.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in page.rows {
            let cells = (0..<names.count).map { i -> String in
                escapeMarkdown(i < row.count ? (row[i] ?? "∅") : "")
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func json(_ page: RowsFetcher.Page) -> String {
        let names = page.columns.map(\.name)
        var objects: [String] = []
        for row in page.rows {
            var pairs: [String] = []
            for (i, name) in names.enumerated() {
                let value = i < row.count ? row[i] : nil
                let rendered: String
                if let value {
                    let kind = ColumnTypeKind.from(typeName: page.columns[i].typeName)
                    switch kind {
                    case .integer, .number:
                        rendered = value
                    case .bool:
                        switch value.lowercased() {
                        case "t", "true", "1": rendered = "true"
                        case "f", "false", "0": rendered = "false"
                        default: rendered = jsonString(value)
                        }
                    case .json:
                        rendered = value   // already valid JSON text
                    default:
                        rendered = jsonString(value)
                    }
                } else {
                    rendered = "null"
                }
                pairs.append("\(jsonString(name)): \(rendered)")
            }
            objects.append("  { " + pairs.joined(separator: ", ") + " }")
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    private static func delimited(_ page: RowsFetcher.Page, separator: String) -> String {
        let needsQuote = separator == ","
        var lines: [String] = []
        lines.append(page.columns.map { field($0.name, quoteForCSV: needsQuote) }.joined(separator: separator))
        for row in page.rows {
            let cells = (0..<page.columns.count).map { i -> String in
                field(i < row.count ? (row[i] ?? "") : "", quoteForCSV: needsQuote)
            }
            lines.append(cells.joined(separator: separator))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Escaping

    private static func escapeMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func field(_ s: String, quoteForCSV: Bool) -> String {
        guard quoteForCSV else {
            // TSV: tabs/newlines would break the grid — strip to spaces.
            return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
