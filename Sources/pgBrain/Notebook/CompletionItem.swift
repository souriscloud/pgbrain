import SwiftUI

/// One row in the custom completion panel. Richer than a bare string: it
/// carries the text to insert, an optional dimmed `detail` (a column's
/// type, a function's signature, "table"/"keyword"), and a `kind` that
/// drives the leading icon + tint — the difference between a string list
/// and IDE-grade intellisense.
struct CompletionItem: Equatable, Identifiable {
    enum Kind: Equatable {
        case column, table, view, schema, function, keyword, enumValue, snippet
    }

    /// Text actually inserted (may end with `(` for a function call).
    let value: String
    /// Text shown in the row (usually == value).
    let label: String
    /// Dimmed right-hand detail: type, signature, category hint.
    let detail: String?
    let kind: Kind

    var id: String { "\(value)\u{1F}\(detail ?? "")" }

    init(value: String, label: String? = nil, detail: String? = nil, kind: Kind) {
        self.value = value
        self.label = label ?? value
        self.detail = detail
        self.kind = kind
    }
}

extension CompletionItem.Kind {
    var symbol: String {
        switch self {
        case .column:    return "rectangle.split.3x1"
        case .table:     return "tablecells"
        case .view:      return "rectangle.on.rectangle"
        case .schema:    return "folder"
        case .function:  return "function"
        case .keyword:   return "k.square"
        case .enumValue: return "list.bullet"
        case .snippet:   return "curlybraces"
        }
    }

    var tint: Color {
        switch self {
        case .column:    return .teal
        case .table:     return .blue
        case .view:      return .indigo
        case .schema:    return .secondary
        case .function:  return .purple
        case .keyword:   return .orange
        case .enumValue: return .pink
        case .snippet:   return .green
        }
    }

    /// Short category word shown when an item has no richer detail.
    var categoryLabel: String {
        switch self {
        case .column:    return "column"
        case .table:     return "table"
        case .view:      return "view"
        case .schema:    return "schema"
        case .function:  return "function"
        case .keyword:   return "keyword"
        case .enumValue: return "enum"
        case .snippet:   return "snippet"
        }
    }
}
