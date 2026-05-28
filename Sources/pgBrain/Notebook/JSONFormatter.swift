import Foundation

/// Tiny wrapper around `JSONSerialization` for the cell-editor JSON
/// path. Both `pretty(_:)` and `compact(_:)` return nil if the input
/// isn't valid JSON — callers fall back to the raw text so we never
/// destructively transform a draft the user is mid-typing.
///
/// `fragmentsAllowed` is on so `42`, `"foo"`, `true`, `null` all work
/// — PG's `jsonb` lets you store any JSON value, including primitives.
enum JSONFormatter {
    static func pretty(_ raw: String) -> String? {
        guard let object = parse(raw),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func compact(_ raw: String) -> String? {
        guard let object = parse(raw),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func isValid(_ raw: String) -> Bool {
        parse(raw) != nil
    }

    private static func parse(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data,
                                                 options: [.fragmentsAllowed])
    }
}
