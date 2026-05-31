import AppKit
import UniformTypeIdentifiers

/// File + clipboard plumbing for bulk connection export/import. Shared by
/// the Welcome window menu and the Settings → Connections tab so both speak
/// the same `ConnectionExchange` bundle format.
@MainActor
enum ConnectionIO {
    /// Result of an import attempt, so callers can toast meaningfully.
    enum ImportResult {
        case imported(Int)     // count actually added (may be 0 if all dupes)
        case cancelled         // user dismissed the panel / empty clipboard
        case unrecognised      // input wasn't a pgBrain connection bundle
    }

    static func exportToFile(_ connections: [Connection], includePasswords: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "pgbrain-connections.json"
        panel.canCreateDirectories = true
        panel.title = "Export Connections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ConnectionExchange.renderBundle(connections, includePasswords: includePasswords)
        try? text.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    static func copyToClipboard(_ connections: [Connection], includePasswords: Bool) {
        let text = ConnectionExchange.renderBundle(connections, includePasswords: includePasswords)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func importFromFile() -> ImportResult {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Connections"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .cancelled }
        guard let items = ConnectionExchange.parseBundle(text) else { return .unrecognised }
        return .imported(ConnectionStore.shared.importConnections(items))
    }

    static func importFromClipboard() -> ImportResult {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return .cancelled }
        guard let items = ConnectionExchange.parseBundle(text) else { return .unrecognised }
        return .imported(ConnectionStore.shared.importConnections(items))
    }
}
