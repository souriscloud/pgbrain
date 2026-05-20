import Foundation
import Observation

/// A single SQL scratchpad. Owns its editor buffer and the chronological
/// stack of result blocks produced by ⌘↩ runs. Reference type so multiple
/// SwiftUI views (the editor, the result stack, the tab strip) can observe
/// the same instance without value-type re-creation churn.
@MainActor
@Observable
final class Scratchpad: Identifiable {
    let id = UUID()
    var title: String
    var text: String = ""
    private(set) var blocks: [ResultBlock] = []

    init(title: String) {
        self.title = title
    }

    func addBlock(_ block: ResultBlock) {
        blocks.insert(block, at: 0)
    }

    func remove(blockID: UUID) {
        blocks.removeAll { $0.id == blockID }
    }

    func clearBlocks() {
        blocks.removeAll()
    }
}

/// One result of one ⌘↩ run. Mutable so a block can flip from .running to
/// .success/.failure when the query finishes without re-allocating its slot
/// in the scratchpad's `blocks` array.
@MainActor
@Observable
final class ResultBlock: Identifiable {
    enum Outcome {
        case running
        case success(QueryResult)
        case failure(String)
    }

    let id = UUID()
    let statement: String
    let startedAt: Date
    var outcome: Outcome
    var isCollapsed: Bool = false

    init(statement: String, startedAt: Date = Date(), outcome: Outcome = .running) {
        self.statement = statement
        self.startedAt = startedAt
        self.outcome = outcome
    }

    /// One-line preview used in the result header — collapses whitespace.
    var preview: String {
        let collapsed = statement
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 120 ? String(collapsed.prefix(120)) + "…" : collapsed
    }
}
