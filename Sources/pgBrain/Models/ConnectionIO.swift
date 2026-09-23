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

    /// nspasteboard.org markers: clipboard managers skip concealed items and
    /// don't keep transient ones in their history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Put `text` on the general pasteboard; when it carries a secret, mark
    /// it concealed + transient so clipboard managers don't record it.
    static func copyText(_ text: String, containsSecret: Bool, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if containsSecret {
            pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
            pasteboard.setData(Data(), forType: concealedType)
            pasteboard.setData(Data(), forType: transientType)
        }
        pasteboard.setString(text, forType: .string)
    }

    /// Exports are written 0600 — with passwords included they're secrets.
    static func exportToFile(_ connections: [Connection], includePasswords: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "pgbrain-connections.json"
        panel.canCreateDirectories = true
        panel.title = "Export Connections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ConnectionExchange.renderBundle(connections, includePasswords: includePasswords)
        do {
            try AppSupport.writePrivate(Data(text.utf8), to: url)
        } catch {
            Log.persistence.error("connection export failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func copyToClipboard(_ connections: [Connection], includePasswords: Bool) {
        let text = ConnectionExchange.renderBundle(connections, includePasswords: includePasswords)
        copyText(text, containsSecret: includePasswords)
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

    // MARK: - libpq files

    enum LibpqImportResult: Equatable {
        case done(added: Int, skipped: Int)
        case fileMissing(String)
        case nothingFound(String)
    }

    /// Create a connection per `[service]` in `~/.pg_service.conf`
    /// (or `$PGSERVICEFILE`). Duplicates are skipped like any import.
    static func importPgServiceFile(at url: URL = ConnInfoParser.defaultServiceFileURL) -> LibpqImportResult {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .fileMissing(url.path) }
        let services = ConnInfoParser.parseServiceFile(text)
        guard !services.isEmpty else { return .nothingFound(url.path) }
        let items = services.map { service -> ConnectionExchange.Imported in
            var (connection, password) = ConnInfoParser.connection(from: service)
            let warnings = ConnectionExchange.sanitize(&connection)
            return ConnectionExchange.Imported(connection: connection, password: password, warnings: warnings)
        }
        let added = ConnectionStore.shared.importConnections(items)
        return .done(added: added, skipped: items.count - added)
    }

    /// Fill missing Keychain passwords from `~/.pgpass` (or `$PGPASSFILE`).
    static func fillPasswordsFromPgPass(at url: URL = ConnInfoParser.defaultPgPassURL) -> LibpqImportResult {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .fileMissing(url.path) }
        let entries = ConnInfoParser.parsePgPass(text)
        guard !entries.isEmpty else { return .nothingFound(url.path) }
        let filled = ConnectionStore.shared.fillPasswords(from: entries)
        return .done(added: filled, skipped: 0)
    }
}
