import AppKit
import SwiftUI

/// SQL scratchpad tab: editor on top, result-block stack below, split so the
/// user can adjust the ratio. `⌘↩` runs the statement under the caret (or
/// the selection if non-empty). Newest result block sits at the top of the
/// stack — JetBrains DataGrip's "result is here, now" feel.
struct ScratchpadView: View {
    @Bindable var scratchpad: Scratchpad
    let service: ConnectionService
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var showHistory = false
    @State private var pendingScrollTarget: UUID?
    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                VSplitView {
                    SQLEditor(
                        text: $scratchpad.text,
                        selection: $selection,
                        onRun: runAtCaret
                    )
                    .frame(minHeight: 100, idealHeight: 240)

                    resultsPane
                        .frame(minHeight: 120)
                }
                .frame(minWidth: 360)

                if showHistory {
                    HistoryPanel(scratchpad: scratchpad) { block in
                        pendingScrollTarget = block.id
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(scratchpad.title)
                .font(.system(.body, design: .default).weight(.medium))
            Spacer()
            Button {
                runAtCaret()
            } label: {
                Label("Run", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.Brand.primary)
            .controlSize(.small)
            .help("Run statement at cursor (⌘↩)")
            .disabled(service.client == nil)

            Button {
                scratchpad.clearBlocks()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(scratchpad.blocks.isEmpty)
            .help("Clear all result blocks")

            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: showHistory ? "clock.fill" : "clock")
            }
            .buttonStyle(.borderless)
            .help(showHistory ? "Hide history panel" : "Show history panel")

            Button {
                showLibrary = true
            } label: {
                Image(systemName: "books.vertical")
            }
            .buttonStyle(.borderless)
            .help("Saved query library")
        }
        .sheet(isPresented: $showLibrary) {
            SavedQueriesView(scratchpad: scratchpad) {
                showLibrary = false
            }
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var resultsPane: some View {
        if scratchpad.blocks.isEmpty {
            VStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Press ⌘↩ to run the statement at the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(scratchpad.blocks) { block in
                            ResultBlockView(block: block) {
                                scratchpad.remove(blockID: block.id)
                            }
                            .id(block.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: pendingScrollTarget) { _, newValue in
                    guard let id = newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                    pendingScrollTarget = nil
                }
            }
        }
    }

    private func runAtCaret() {
        guard let client = service.client else { return }
        let buffer = scratchpad.text
        guard !buffer.isEmpty else { return }

        let sql: String?
        if selection.length > 0 {
            sql = sliceSelection(in: buffer)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let caret = caretIndex(in: buffer)
            sql = SQLStatementSplitter.statementAt(caret: caret, in: buffer)?.trimmed
        }
        guard let statement = sql, !statement.isEmpty else { return }

        // Destructive guardrail — production connections prompt before
        // unscoped UPDATE/DELETE/TRUNCATE/DROP/ALTER.
        if service.connection.isProduction {
            let verdict = SQLSafety.classify(statement)
            if verdict == .destructiveUnscoped || verdict == .ddl {
                let preview = statement.count > 240
                    ? String(statement.prefix(240)) + "…"
                    : statement
                let alert = NSAlert()
                alert.messageText = "Run on production?"
                alert.informativeText = """
                    The connection "\(service.connection.name)" is marked \
                    PRODUCTION and this statement is \
                    \(verdict == .ddl ? "DDL" : "an unscoped mutation").

                    \(preview)
                    """
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Run on PROD")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
        }

        let block = ResultBlock(statement: statement)
        scratchpad.addBlock(block)
        let op = service.operations.begin(kind: .query, summary: QueryRunner.summary(of: statement))
        let tracker = service.operations
        let opID = op.id
        let task = Task { @MainActor in
            do {
                let result = try await QueryRunner.run(statement, on: client, operationID: opID, tracker: tracker)
                block.outcome = .success(result)
                service.operations.finish(op, status: .succeeded)
            } catch is CancellationError {
                block.outcome = .failure("Cancelled")
                service.operations.finish(op, status: .cancelled)
            } catch {
                let msg = error.localizedDescription
                block.outcome = .failure(msg)
                let status: OperationsCenter.Operation.Status = Task.isCancelled
                    ? .cancelled
                    : .failed(msg)
                service.operations.finish(op, status: status)
            }
        }
        op.taskHandle = task
    }

    private func sliceSelection(in buffer: String) -> String? {
        let utf16 = buffer.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: selection.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: selection.length, limitedBy: utf16.endIndex),
              let lo = String.Index(start, within: buffer),
              let hi = String.Index(end, within: buffer)
        else { return nil }
        return String(buffer[lo..<hi])
    }

    private func caretIndex(in buffer: String) -> String.Index {
        let utf16 = buffer.utf16
        let offset = min(selection.location, utf16.count)
        guard let raw = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let idx = String.Index(raw, within: buffer)
        else { return buffer.endIndex }
        return idx
    }
}

// MARK: - SQL editor

/// Minimal NSTextView wrapper. Monospaced, no syntax highlighting yet —
/// that lands when we decide between native TextKit-2 tokenization and a
/// CodeMirror-in-WKWebView host in a later iter.
private struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let onRun: () -> Void

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var onRun: () -> Void
        var updatingFromUI = false

        init(text: Binding<String>, selection: Binding<NSRange>, onRun: @escaping () -> Void) {
            self.text = text
            self.selection = selection
            self.onRun = onRun
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            updatingFromUI = true
            text.wrappedValue = tv.string
            updatingFromUI = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            selection.wrappedValue = tv.selectedRange()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, onRun: onRun)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }

        let editor = SQLNSTextView(frame: tv.frame, textContainer: tv.textContainer)
        editor.autoresizingMask = tv.autoresizingMask
        scroll.documentView = editor

        editor.delegate = context.coordinator
        editor.onRun = onRun
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.usesFindBar = true
        editor.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.setSelectedRange(selection)

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SQLNSTextView else { return }
        // Update the closure each pass so it captures the latest binding.
        tv.onRun = onRun
        context.coordinator.onRun = onRun
        if !context.coordinator.updatingFromUI, tv.string != text {
            tv.string = text
        }
    }
}

private final class SQLNSTextView: NSTextView {
    var onRun: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars == "\r" || chars == "\n" {
            onRun?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Result block

private struct ResultBlockView: View {
    @Bindable var block: ResultBlock
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !block.isCollapsed {
                Divider()
                content
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Corner.card)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Corner.card))
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(block.preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            outcomeSummary
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .success(let result) = block.outcome, !result.page.columns.isEmpty {
                Menu {
                    ForEach(Exporter.Format.allCases) { fmt in
                        Button(fmt.uiLabel) { savePage(result.page, as: fmt) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption2)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Export result…")
            }
            Button {
                block.isCollapsed.toggle()
            } label: {
                Image(systemName: block.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func savePage(_ page: RowsFetcher.Page, as format: Exporter.Format) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "result.\(format.fileExtension)"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try Exporter.exportPage(page, format: format, destination: url)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.outcome {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        case .success(let result):
            if result.page.columns.isEmpty {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(result.commandTag ?? "OK").font(.caption.monospaced())
                    Spacer()
                }
                .padding(10)
            } else {
                DataGridView(page: result.page)
                    .frame(minHeight: 160, idealHeight: 280, maxHeight: 480)
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.outcome {
        case .running:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var outcomeSummary: some View {
        switch block.outcome {
        case .running:
            EmptyView()
        case .success(let result):
            let rows = result.page.rows.count
            let plural = rows == 1 ? "" : "s"
            Text("\(result.page.truncated ? "\(rows)+" : "\(rows)") row\(plural) · \(String(format: "%.0f ms", result.page.elapsed * 1000))")
        case .failure:
            Text("error")
        }
    }

    private var borderColor: Color {
        switch block.outcome {
        case .running: return .secondary.opacity(0.3)
        case .success: return .green.opacity(0.3)
        case .failure: return .red.opacity(0.4)
        }
    }
}

// MARK: - History panel

/// Compact list of past runs in this scratchpad. Newest at top to match the
/// result-block stack. Selecting a row asks the parent to scroll the matching
/// block into view via `onSelect`.
private struct HistoryPanel: View {
    @Bindable var scratchpad: Scratchpad
    let onSelect: (ResultBlock) -> Void
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("History")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(scratchpad.blocks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if scratchpad.blocks.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No runs yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(scratchpad.blocks) { block in
                            HistoryRow(
                                block: block,
                                isSelected: selectedID == block.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedID = block.id
                                onSelect(block)
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct HistoryRow: View {
    @Bindable var block: ResultBlock
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            statusIcon
                .frame(width: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.preview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(block.startedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    summary
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Tokens.Brand.primary.opacity(0.15) : Color.clear)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.outcome {
        case .running:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch block.outcome {
        case .running:
            Text("running…")
        case .success(let result):
            let rows = result.page.rows.count
            let prefix = result.page.truncated ? "\(rows)+" : "\(rows)"
            Text("\(prefix) rows · \(String(format: "%.0f ms", result.page.elapsed * 1000))")
        case .failure:
            Text("error")
        }
    }
}
