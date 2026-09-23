import AppKit
import SwiftUI

/// Click-to-open popover showing the full multi-line apply error so the
/// user can actually read the server's reason (and copy it).
struct ApplyErrorPopover: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("Apply failed").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Text("Transaction rolled back. Your pending edits are still here — fix and Apply again, or Revert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.md)
        .frame(width: 460)
    }
}
