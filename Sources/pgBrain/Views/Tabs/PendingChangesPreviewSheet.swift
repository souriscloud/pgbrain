import AppKit
import SwiftUI

/// "Preview SQL": the exact statements Apply will run for the staged
/// changes, as one copyable transaction script.
struct PendingChangesPreviewSheet: View {
    let script: Result<String, Error>
    let summary: String
    let onApply: () -> Void
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Text("Pending changes").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case .success(let sql) = script {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sql, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy SQL", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
            .padding(Tokens.Spacing.md)
            Divider()
            switch script {
            case .success(let sql):
                ScrollView([.vertical, .horizontal]) {
                    Text(SQLHighlighter.attributedString(for: sql))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Spacing.md)
                }
                .background(Color(nsColor: .textBackgroundColor))
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(Tokens.Spacing.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Text("Bind values are shown inline; Apply sends them as parameters in one transaction.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(); onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
                    .disabled({ if case .failure = script { return true } else { return false } }())
            }
            .padding(Tokens.Spacing.md)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 480)
    }
}
