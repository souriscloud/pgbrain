import AppKit
import SwiftUI

struct DDLPane: View {
    let state: InspectorLoader.State
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Generating DDL…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(_, let ddl):
            DDLBody(ddl: ddl)
        case .error(let msg):
            InspectorError(msg: msg, retry: onRetry)
        }
    }
}

struct DDLBody: View {
    let ddl: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CREATE statement")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ddl, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy SQL", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, Tokens.Spacing.md)
            .padding(.vertical, 6)
            Divider().opacity(0.5)

            ScrollView([.vertical, .horizontal]) {
                // Run the SQL lexer over the DDL so keywords / strings /
                // comments / numbers come out coloured — same palette
                // the notebook cells use.
                Text(SQLHighlighter.attributedString(for: ddl))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.md)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
