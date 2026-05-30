import SwiftUI

/// Read-only collapsible tree for a JSON/JSONB value. Parses with
/// `JSONSerialization` (object key order isn't preserved, so keys are sorted
/// for a stable view) and renders nested objects/arrays as disclosure groups
/// with type-coloured leaves.
struct JSONTreeView: View {
    let jsonText: String

    var body: some View {
        if let root = JSONValue.parse(jsonText) {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 1) {
                    JSONNodeRow(key: nil, value: root, depth: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Not valid JSON — switch to Text to edit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }
}

/// Order-preserving-ish JSON model. Objects keep sorted keys.
indirect enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return convert(obj)
    }

    private static func convert(_ any: Any) -> JSONValue {
        switch any {
        case let dict as [String: Any]:
            let pairs = dict.keys.sorted().map { ($0, convert(dict[$0]!)) }
            return .object(pairs)
        case let arr as [Any]:
            return .array(arr.map(convert))
        case let n as NSNumber:
            // Distinguish bool from numeric NSNumber.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.stringValue)
        case let s as String:
            return .string(s)
        case is NSNull:
            return .null
        default:
            return .string("\(any)")
        }
    }

    var childCount: Int? {
        switch self {
        case .object(let p): return p.count
        case .array(let a): return a.count
        default: return nil
        }
    }
}

private struct JSONNodeRow: View {
    let key: String?
    let value: JSONValue
    let depth: Int
    @State private var expanded: Bool

    init(key: String?, value: JSONValue, depth: Int) {
        self.key = key
        self.value = value
        self.depth = depth
        // Expand the top couple of levels by default; collapse deeper.
        _expanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch value {
        case .object(let pairs):
            disclosure(suffix: "{\(pairs.count)}") {
                ForEach(pairs.indices, id: \.self) { i in
                    JSONNodeRow(key: pairs[i].0, value: pairs[i].1, depth: depth + 1)
                }
            }
        case .array(let items):
            disclosure(suffix: "[\(items.count)]") {
                ForEach(items.indices, id: \.self) { i in
                    JSONNodeRow(key: "[\(i)]", value: items[i], depth: depth + 1)
                }
            }
        default:
            leaf
        }
    }

    @ViewBuilder
    private func disclosure<Content: View>(suffix: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
        } label: {
            HStack(spacing: 4) {
                if let key { Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary) }
                else { Text("root").font(.caption2).foregroundStyle(.tertiary) }
                Text(suffix).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var leaf: some View {
        HStack(alignment: .top, spacing: 4) {
            if let key {
                Text("\(key):").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(renderedValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
        .padding(.leading, 2)
    }

    private var renderedValue: String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return ""
        }
    }

    private var valueColor: Color {
        switch value {
        case .string: return .green
        case .number: return .blue
        case .bool: return .purple
        case .null: return .secondary
        default: return .primary
        }
    }
}
