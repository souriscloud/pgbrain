import AppKit
import SwiftUI
import Observation

/// IDE-grade completion popup. Replaces macOS's string-only native
/// completion with a custom, non-activating panel that shows an icon +
/// name + dimmed detail (column type / function signature) per row, with
/// keyboard navigation and fuzzy matching.
///
/// One controller drives one `NSTextView` (including an `NSTextField`'s
/// field editor). The host editor:
///   - calls `requestCompletion()` to open / refresh (⌘Space, ⌥Esc, or a
///     debounced as-you-type trigger),
///   - routes nav keys while `isVisible` via `moveSelection`, `acceptSelected`,
///     `cancel` (from `keyDown` or `doCommandBy`),
///   - calls `refreshIfVisible()` after each text change.
///
/// The panel is non-activating, so the text view keeps first responder and
/// keystrokes keep flowing to the editor — the panel is display-only.
@MainActor
final class CompletionController: NSObject {
    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 24
    static let maxRows = 9

    private weak var textView: NSTextView?
    private let provider: (_ partial: String, _ fullText: String, _ caret: Int) -> [CompletionItem]

    private var panel: NSPanel?
    private let model = CompletionModel()
    /// The identifier range under the caret being completed.
    private var partialRange = NSRange(location: 0, length: 0)
    private var mouseMonitor: Any?

    init(textView: NSTextView,
         provider: @escaping (_ partial: String, _ fullText: String, _ caret: Int) -> [CompletionItem]) {
        self.textView = textView
        self.provider = provider
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Trigger

    /// Compute candidates at the caret and show / refresh the panel. Hides
    /// when there's nothing to offer.
    func requestCompletion() {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret <= ns.length else { hide(); return }
        let range = identifierRange(in: ns, caret: caret)
        let partial = ns.substring(with: range)
        let items = provider(partial, ns as String, range.location)
        guard !items.isEmpty else { hide(); return }
        partialRange = range
        present(items: items, anchorAt: range.location, in: tv)
    }

    /// Re-run after a text change, but only if already showing.
    func refreshIfVisible() {
        guard isVisible else { return }
        requestCompletion()
    }

    // MARK: - Keyboard ops (called by the host editor)

    func moveSelection(_ delta: Int) { model.move(delta) }

    @discardableResult
    func acceptSelected() -> Bool {
        guard isVisible, let item = model.selectedItem, let tv = textView else { return false }
        insert(item, into: tv)
        hide()
        return true
    }

    func cancel() { hide() }

    /// Map an AppKit command selector to a nav op. Returns true if consumed.
    /// Lets field-editor hosts route via `doCommandBy` without keyCodes.
    @discardableResult
    func handleCommand(_ selector: Selector) -> Bool {
        guard isVisible else { return false }
        switch selector {
        case #selector(NSStandardKeyBindingResponding.moveUp(_:)):       moveSelection(-1); return true
        case #selector(NSStandardKeyBindingResponding.moveDown(_:)):     moveSelection(+1); return true
        case #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
             #selector(NSStandardKeyBindingResponding.insertTab(_:)):    return acceptSelected()
        case #selector(NSStandardKeyBindingResponding.cancelOperation(_:)):
            cancel(); return true
        default: return false
        }
    }

    // MARK: - Insertion

    private func insert(_ item: CompletionItem, into tv: NSTextView) {
        guard partialRange.location + partialRange.length <= (tv.string as NSString).length else { return }
        if tv.shouldChangeText(in: partialRange, replacementString: item.value) {
            tv.replaceCharacters(in: partialRange, with: item.value)
            tv.didChangeText()
        }
    }

    /// Identifier run ending at the caret (letters/digits/underscore). Zero
    /// length when the caret isn't on a word boundary.
    private func identifierRange(in ns: NSString, caret: Int) -> NSRange {
        var start = caret
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: caret - start)
    }

    private func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x30 && c <= 0x39) || c == 0x5F
    }

    // MARK: - Panel lifecycle

    private func present(items: [CompletionItem], anchorAt location: Int, in tv: NSTextView) {
        model.items = items
        if model.selected >= items.count { model.selected = 0 }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Size to content.
        let rows = min(items.count, Self.maxRows)
        let height = CGFloat(rows) * Self.rowHeight + 10
        panel.setContentSize(NSSize(width: Self.width, height: height))

        // Anchor below the partial-word start; flip above if it would clip.
        let caretRect = tv.firstRect(forCharacterRange: NSRange(location: location, length: 0),
                                     actualRange: nil)
        let screen = tv.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - height - 4)
        if origin.y < visible.minY { origin.y = caretRect.maxY + 4 } // flip above
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - Self.width - 4)
        panel.setFrameOrigin(origin)

        if !panel.isVisible {
            tv.window?.addChildWindow(panel, ordered: .above)
            installMouseMonitor()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: CompletionListView(model: model,
                                                              onPick: { [weak self] idx in
            self?.model.selected = idx
            self?.acceptSelected()
        }))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)
        return panel
    }

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        removeMouseMonitor()
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            // Dismiss on any click outside the panel, or on scroll.
            if event.type == .scrollWheel {
                if event.window !== panel { self.hide() }
            } else if event.window !== panel {
                self.hide()
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
    }
}

/// Selection state for the panel. `@Observable` so the SwiftUI list tracks
/// `items` / `selected` and the controller can drive selection by key.
@MainActor
@Observable
final class CompletionModel {
    var items: [CompletionItem] = []
    var selected: Int = 0

    var selectedItem: CompletionItem? {
        items.indices.contains(selected) ? items[selected] : nil
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }
}

/// The panel's content: a scrolling list of icon + name + dimmed detail
/// rows, with the keyboard-selected row tinted.
private struct CompletionListView: View {
    let model: CompletionModel
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        row(idx, item)
                            .id(idx)
                            .onTapGesture { onPick(idx) }
                    }
                }
                .padding(4)
            }
            .onChange(of: model.selected) { _, newValue in
                proxy.scrollTo(newValue, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func row(_ idx: Int, _ item: CompletionItem) -> some View {
        let isSel = idx == model.selected
        HStack(spacing: 7) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSel ? Color.white : item.kind.tint)
                .frame(width: 16)
            Text(item.label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isSel ? Color.white : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSel ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: CompletionController.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSel ? Tokens.Brand.primary : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
