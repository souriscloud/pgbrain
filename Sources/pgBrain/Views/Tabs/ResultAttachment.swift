import AppKit
import SwiftUI

/// `NSTextAttachment` subclass that ties a single character in the notebook's
/// text storage to a `NotebookResult` record. Lifetime: the result entry
/// lives in `Notebook.results`; the attachment carries only the `UUID` so
/// edit/cut/paste of the surrounding text doesn't mutate the result data.
final class ResultAttachment: NSTextAttachment {
    let resultID: UUID
    weak var notebook: Notebook?

    init(resultID: UUID, notebook: Notebook) {
        self.resultID = resultID
        self.notebook = notebook
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = ResultAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        return provider
    }
}

/// Hosts the SwiftUI `InlineResultView` inside an `NSView` that TextKit can
/// position. AppKit always invokes `loadView` / `attachmentBounds` on the
/// main thread (they touch NSView state, which is main-actor-isolated in
/// Swift). We mark the overrides `nonisolated` to match the SDK
/// declaration, then bridge into main-actor code via `MainActor.assumeIsolated`.
/// `@unchecked Sendable` here is safe because the only thing crossing the
/// boundary is `self` — and AppKit guarantees we're on main when called.
final class ResultAttachmentViewProvider: NSTextAttachmentViewProvider, @unchecked Sendable {
    nonisolated override func loadView() {
        let boxed = ProviderBox(self)
        MainActor.assumeIsolated {
            let provider = boxed.value
            guard let attachment = provider.textAttachment as? ResultAttachment else {
                provider.view = NSView(frame: .zero)
                return
            }
            provider.view = InlineResultHostView(attachment: attachment)
            provider.tracksTextAttachmentViewBounds = true
        }
    }

    nonisolated override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        // Width spans the full line fragment, less a small inset so the
        // border doesn't collide with the document edge. Fixed-ish height
        // covers most cases; the host's DataGridView caps at maxHeight 320.
        let width = max(200, proposedLineFragment.width - 24)
        return CGRect(x: 0, y: 0, width: width, height: 260)
    }
}

/// `@unchecked Sendable` wrapper so we can hand the provider into a
/// `MainActor.assumeIsolated` closure without Swift 6 yelling about
/// crossing isolation boundaries. AppKit guarantees the call site is
/// already on main.
private struct ProviderBox: @unchecked Sendable {
    let value: ResultAttachmentViewProvider
    init(_ v: ResultAttachmentViewProvider) { self.value = v }
}

/// Resizable `NSView` that hosts the SwiftUI result widget. The hosting view
/// observes the notebook's results dictionary so status transitions
/// (running → success/failure) propagate without us having to manually
/// trigger redisplay.
final class InlineResultHostView: NSView {
    private let attachment: ResultAttachment
    private let hosting: NSHostingView<InlineResultView>
    private var lastHeight: CGFloat = 220

    init(attachment: ResultAttachment) {
        self.attachment = attachment
        self.hosting = NSHostingView(rootView: InlineResultView(attachment: attachment))
        super.init(frame: .zero)
        wantsLayer = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        // Match the SwiftUI hosting view's fitting size so TextKit picks a
        // height that doesn't clip content.
        let fitting = hosting.fittingSize
        let h = max(60, min(420, fitting.height > 0 ? fitting.height : lastHeight))
        lastHeight = h
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }
}

/// SwiftUI presentation of a result block. Renders the run header (status
/// glyph, preview SQL, elapsed, row count), a collapse toggle, a remove
/// button, and either the `DataGridView` or a "command tag" line.
///
/// The attachment is just a value carrier — observation tracking flows
/// through the `Notebook` (which is `@Observable`) so a status flip on
/// `notebook.results[id]` triggers this view's body re-evaluation.
struct InlineResultView: View {
    let attachment: ResultAttachment

    var body: some View {
        if let notebook = attachment.notebook,
           let result = notebook.result(id: attachment.resultID) {
            BoundView(result: result, notebook: notebook)
        } else {
            EmptyView()
        }
    }
}

private struct BoundView: View {
    @Bindable var result: NotebookResult
    let notebook: Notebook

    var body: some View {
        VStack(spacing: 0) {
            header
            if !result.isCollapsed {
                Divider().opacity(0.5)
                body(for: result.status)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            statusGlyph
            Text(result.preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            outcomeSummary
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button {
                result.isCollapsed.toggle()
            } label: {
                Image(systemName: result.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            Button {
                notebook.remove(id: result.id)
                NotebookCommands.removeAttachment(notebook: notebook, resultID: result.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func body(for status: NotebookResult.Status) -> some View {
        switch status {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        case .success(let q):
            if q.page.columns.isEmpty {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(q.commandTag ?? "OK").font(.caption.monospaced())
                    Spacer()
                }
                .padding(10)
            } else {
                VStack(spacing: 0) {
                    DataGridView(page: q.page)
                        .frame(minHeight: 120, idealHeight: 220, maxHeight: 320)
                }
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(10)
        case .cancelled:
            HStack {
                Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch result.status {
        case .running: ProgressView().controlSize(.mini)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var outcomeSummary: some View {
        switch result.status {
        case .running: EmptyView()
        case .success(let q):
            let rows = q.page.rows.count
            let prefix = q.page.truncated ? "\(rows)+" : "\(rows)"
            Text("\(prefix) row\(rows == 1 ? "" : "s") · \(String(format: "%.0f ms", q.page.elapsed * 1000))")
        case .failure: Text("error")
        case .cancelled: Text("cancelled")
        }
    }

    private var borderColor: Color {
        switch result.status {
        case .running: return .secondary.opacity(0.3)
        case .success: return .green.opacity(0.3)
        case .failure: return .red.opacity(0.4)
        case .cancelled: return .secondary.opacity(0.3)
        }
    }
}

/// Static helpers the inline result view calls to mutate the parent
/// `NSTextStorage` (find the attachment character and delete it).
enum NotebookCommands {
    @MainActor
    static func removeAttachment(notebook: Notebook, resultID: UUID) {
        let storage = notebook.textStorage
        let length = storage.length
        var locationToDelete: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, stop in
            if let attachment = value as? ResultAttachment, attachment.resultID == resultID {
                locationToDelete = range.location
                stop.pointee = true
            }
        }
        if let loc = locationToDelete {
            // Also eat a trailing newline if it's the one we inserted with
            // the attachment, to keep the document tidy.
            var deleteRange = NSRange(location: loc, length: 1)
            if loc + 1 < length,
               storage.string[storage.string.index(storage.string.startIndex, offsetBy: loc + 1)] == "\n" {
                deleteRange.length = 2
            }
            storage.deleteCharacters(in: deleteRange)
        }
    }
}
