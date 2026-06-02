import Foundation
import Observation

/// A named, reusable SQL fragment. Placeholders: `$cursor$` marks where
/// the caret lands after insertion; `$1$`, `$2$`, … are tab-stops the
/// caller can step through (only the first is honoured today — we keep
/// the multi-stop shape so adding tab-through is non-breaking).
struct Snippet: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var body: String
    var createdAt: Date
}

/// JSON-backed snippet library, shared across connections (snippets are
/// generic SQL — pinning them to a connection would just hide them
/// when the user re-uses them elsewhere). Stored at
/// `AppSupport/snippets.json`. Debounced save.
@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore()

    private(set) var snippets: [Snippet] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL

    private init() {
        self.url = AppSupport.directory.appendingPathComponent("snippets.json")
        load()
    }

    #if DEBUG
    /// Test-only: back the store with an isolated file so `swift test` never
    /// touches the real snippet library. `flush()` is synchronous-on-demand
    /// via `flushNowForTests()`.
    init(testURL: URL) {
        self.url = testURL
        load()
    }
    func flushNowForTests() { flush() }
    #endif

    func add(name: String, body: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !body.isEmpty else { return }
        snippets.append(Snippet(id: UUID(), name: trimmed, body: body, createdAt: Date()))
        snippets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scheduleSave()
    }

    func update(id: UUID, name: String? = nil, body: String? = nil) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        if let name { snippets[i].name = name }
        if let body { snippets[i].body = body }
        snippets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scheduleSave()
    }

    func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Resolve `$cursor$` and `$1$` placeholders. Returns the expanded
    /// text plus the caret position (UTF-16 offset) the caller should
    /// place the caret at. `$cursor$` wins over `$1$` if both are
    /// present.
    static func expand(_ body: String) -> (text: String, caret: Int) {
        if let r = body.range(of: "$cursor$") {
            var out = body
            out.replaceSubrange(r, with: "")
            let pos = body[..<r.lowerBound].utf16.count
            return (out, pos)
        }
        if let r = body.range(of: "$1$") {
            var out = body
            out.replaceSubrange(r, with: "")
            let pos = body[..<r.lowerBound].utf16.count
            return (out, pos)
        }
        return (body, body.utf16.count)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    private func flush() {
        do {
            try AppSupport.ensureDirectoryExists()
            let data = try JSONEncoder().encode(snippets)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("pgBrain: SnippetStore.flush failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
