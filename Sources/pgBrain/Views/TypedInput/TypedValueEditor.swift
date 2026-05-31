import SwiftUI

/// The one input control the whole app speaks through. Given a Postgres
/// type string (and the connection's enum catalog) it resolves an
/// `InputKind` and renders the matching native control — date/time pickers,
/// a boolean segment, an enum dropdown, a syntax-highlighted JSON editor,
/// numeric fields — all wrapped in one consistent chrome.
///
/// A leading **mode menu** lets the user step outside the literal value to
/// `NULL`, the column `DEFAULT`, a raw SQL `expression`, or type-specific
/// quick actions (`now()`, generate UUID). Everything funnels back through
/// a single `TypedInputValue` binding, so callers stay simple and the write
/// path stays uniform.
struct TypedValueEditor: View {
    let typeName: String
    var nullable: Bool = true
    var enums: [String: [String]] = [:]
    /// Offer the column `DEFAULT` as a mode (inserts / column defaults).
    var allowsDefault: Bool = false
    /// Offer raw-SQL expression mode + quick actions. Off for pure-literal
    /// contexts (e.g. a search value) where an expression makes no sense.
    var allowsExpression: Bool = true
    /// Compact single-row layout for dense forms (row form, dialog grids).
    var compact: Bool = false
    /// Schema-aware completion for expression mode: (partial, full, caret) →
    /// rich items. Nil → no completion (e.g. contexts without a schema).
    var completions: ((_ partial: String, _ fullText: String, _ caretIndex: Int) -> [CompletionItem])? = nil
    @Binding var value: TypedInputValue

    @State private var mode: Mode = .value
    @State private var text: String = ""
    @State private var exprText: String = ""
    @State private var jsonText: String = ""
    @State private var jsonTree = false
    @State private var date: Date = Date()
    @State private var bool: Bool = true
    @State private var enumSel: String = ""

    private enum Mode: Hashable { case value, expression, null, defaultKeyword }

    private var kind: InputKind { InputKind.resolve(typeName: typeName, enums: enums) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : Tokens.Spacing.sm) {
            header
            Group {
                switch mode {
                case .value:          valueEditor
                case .expression:     expressionEditor
                case .null:           passiveChip("NULL", icon: "circle.dashed", tint: .secondary)
                case .defaultKeyword: passiveChip("DEFAULT", icon: "wand.and.stars", tint: Tokens.Brand.primary)
                }
            }
        }
        .onAppear(perform: hydrate)
    }

    // MARK: - Header (type chip + mode menu)

    private var header: some View {
        HStack(spacing: 6) {
            Label {
                Text(typeName).font(.system(.caption2, design: .monospaced).weight(.medium))
            } icon: {
                Image(systemName: kind.symbol).font(.caption2)
            }
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)

            Spacer(minLength: 8)

            modeMenu
        }
    }

    private var modeMenu: some View {
        Menu {
            Button { switchTo(.value) } label: { Label("Value", systemImage: "pencil") }
            if allowsExpression {
                ForEach(TypedQuickAction.actions(for: kind)) { qa in
                    Button {
                        exprText = qa.expression
                        switchTo(.expression)
                    } label: { Label(qa.label, systemImage: qa.symbol) }
                }
                Button { switchTo(.expression) } label: { Label("SQL expression…", systemImage: "function") }
            }
            Divider()
            if nullable {
                Button { switchTo(.null) } label: { Label("NULL", systemImage: "circle.dashed") }
            }
            if allowsDefault {
                Button { switchTo(.defaultKeyword) } label: { Label("DEFAULT", systemImage: "wand.and.stars") }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: modeIcon).font(.system(size: 9, weight: .semibold))
                Text(modeLabel).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(modeTint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(modeTint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(modeTint.opacity(0.25), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var modeLabel: String {
        switch mode {
        case .value: return "Value"
        case .expression: return "Expr"
        case .null: return "NULL"
        case .defaultKeyword: return "Default"
        }
    }
    private var modeIcon: String {
        switch mode {
        case .value: return "pencil"
        case .expression: return "function"
        case .null: return "circle.dashed"
        case .defaultKeyword: return "wand.and.stars"
        }
    }
    private var modeTint: Color {
        switch mode {
        case .value: return .secondary
        case .expression: return Tokens.Brand.primary
        case .null: return .secondary
        case .defaultKeyword: return Tokens.Brand.primary
        }
    }

    // MARK: - Value editors per kind

    @ViewBuilder
    private var valueEditor: some View {
        switch kind {
        case .boolean:
            Picker("", selection: $bool) {
                Text("true").tag(true)
                Text("false").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: bool) { _, _ in publish() }

        case .date:
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field)
                .onChange(of: date) { _, _ in publish() }

        case .time:
            DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.field)
                .onChange(of: date) { _, _ in publish() }

        case .timestamp:
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.field)
                .onChange(of: date) { _, _ in publish() }

        case .enumType(let labels):
            Picker("", selection: $enumSel) {
                ForEach(labels, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .onChange(of: enumSel) { _, _ in publish() }

        case .json:
            jsonEditor

        case .uuid:
            HStack(spacing: 6) {
                plainField(monospaced: true, placeholder: "00000000-0000-0000-0000-000000000000")
                Button {
                    exprText = "gen_random_uuid()"; switchTo(.expression)
                } label: { Image(systemName: "wand.and.stars") }
                .buttonStyle(.borderless)
                .help("Generate server-side with gen_random_uuid()")
            }

        case .integer, .decimal:
            plainField(monospaced: true, alignTrailing: true, placeholder: "0")

        case .bytes:
            plainField(monospaced: true, placeholder: "\\x… (hex)")

        case .network:
            plainField(monospaced: true, placeholder: kindHint)

        case .interval:
            plainField(monospaced: true, placeholder: "1 day 02:30:00")

        case .array(let element):
            plainField(monospaced: true, placeholder: "{…}  (\(element)[])")

        case .geometry:
            plainField(monospaced: true, placeholder: "SRID=4326;POINT(…)")

        case .text, .unknown:
            plainField(monospaced: false, placeholder: "")
        }
    }

    private var kindHint: String {
        switch kind {
        case .network: return "192.168.0.0/24"
        default: return ""
        }
    }

    private func plainField(monospaced: Bool, alignTrailing: Bool = false, placeholder: String) -> some View {
        TextField(placeholder, text: $text, axis: compact ? .horizontal : .vertical)
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .multilineTextAlignment(alignTrailing ? .trailing : .leading)
            .lineLimit(compact ? 1...1 : 1...6)
            .onChange(of: text) { _, _ in publish() }
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: $jsonTree) {
                    Text("Text").tag(false)
                    Text("Tree").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                jsonValidityChip
                Spacer()
                Button("Prettify") { if let p = JSONFormatter.pretty(jsonText) { jsonText = p; publish() } }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(!JSONFormatter.isValid(jsonText))
                Button("Minify") { if let c = JSONFormatter.compact(jsonText) { jsonText = c; publish() } }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(!JSONFormatter.isValid(jsonText))
            }
            if jsonTree {
                JSONTreeView(jsonText: jsonText)
                    .frame(minHeight: compact ? 120 : 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
            } else {
                JSONSyntaxEditor(text: $jsonText)
                    .frame(minHeight: compact ? 90 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    .onChange(of: jsonText) { _, _ in publish() }
            }
        }
    }

    @ViewBuilder
    private var jsonValidityChip: some View {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if JSONFormatter.isValid(jsonText) {
                Label("Valid", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Label("Invalid", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).labelStyle(.titleAndIcon)
            }
        }
    }

    private var expressionEditor: some View {
        VStack(alignment: .leading, spacing: 3) {
            SQLExpressionEditor(text: $exprText, completions: completions)
                .frame(minHeight: compact ? 30 : 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                .onChange(of: exprText) { _, _ in publish() }
            Text("Inlined as SQL — cast to \(typeName) on write.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func passiveChip(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).font(.system(.callout, design: .monospaced).weight(.medium))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, compact ? 4 : 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - State <-> binding

    private func switchTo(_ m: Mode) {
        mode = m
        publish()
    }

    /// Recompute `value` from the active mode + draft state.
    private func publish() {
        switch mode {
        case .null:
            value = .null
        case .defaultKeyword:
            value = .defaultKeyword
        case .expression:
            value = .expression(exprText)
        case .value:
            value = .literal(literalFromDraft())
        }
    }

    private func literalFromDraft() -> String {
        switch kind {
        case .boolean:        return bool ? "true" : "false"
        case .date:           return Self.format(date, "yyyy-MM-dd")
        case .time:           return Self.format(date, "HH:mm:ss")
        case .timestamp:      return Self.format(date, "yyyy-MM-dd HH:mm:ss")
        case .enumType:       return enumSel
        case .json:           return JSONFormatter.compact(jsonText) ?? jsonText
        default:              return text
        }
    }

    /// Seed the draft state from the incoming `value` exactly once.
    private func hydrate() {
        switch value {
        case .null:
            mode = .null
        case .defaultKeyword:
            mode = .defaultKeyword
        case .expression(let e):
            mode = .expression; exprText = e
        case .literal(let s):
            mode = .value
            seedDrafts(from: s)
        }
    }

    private func seedDrafts(from raw: String) {
        text = raw
        switch kind {
        case .boolean:
            bool = Self.parseBool(raw) ?? true
        case .date, .time, .timestamp:
            date = Self.parseDate(raw) ?? Date()
        case .enumType(let labels):
            enumSel = labels.contains(raw) ? raw : (labels.first ?? raw)
        case .json:
            jsonText = JSONFormatter.pretty(raw) ?? raw
        default:
            break
        }
    }

    // MARK: - Parse / format helpers

    private static func format(_ d: Date, _ fmt: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
        return f.string(from: d)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formats = ["yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "HH:mm:ss", "HH:mm"]
        for fmt in formats {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "t", "true", "1", "yes", "y", "on": return true
        case "f", "false", "0", "no", "n", "off": return false
        default: return nil
        }
    }
}
