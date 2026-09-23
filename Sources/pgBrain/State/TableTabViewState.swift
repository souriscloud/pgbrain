import AppKit
import Observation

/// How a table tab's Data pane presents rows.
enum TableRowViewMode: String, Sendable {
    case grid, form, map
}

/// View state of one table tab that must survive the tab being unmounted
/// (only the selected tab's view exists). Lives on `WorkspaceState.Tab`.
@Observable
final class TableTabViewState {
    var pane: WorkspaceState.TablePane = .data
    var rowViewMode: TableRowViewMode = .grid
    var formRowIndex = 0
    var showFindBar = false

    /// Grid scroll offset and cursor, tagged with the page generation they
    /// belong to — a different page starts at the top instead. Not observed:
    /// they change on every scroll tick and nothing renders from them.
    @ObservationIgnored var scrollOrigin: NSPoint?
    @ObservationIgnored var cursor: GridSelection.Cell?
    @ObservationIgnored var anchorGeneration: Int?
}
