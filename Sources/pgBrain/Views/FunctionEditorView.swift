import SwiftUI
import PostgresNIO

/// Sheet for editing the body of a function / procedure. We fetch the
/// existing CREATE OR REPLACE via `pg_get_functiondef`, pre-populate
/// the editor, and let the user save → that's a full
/// `CREATE OR REPLACE FUNCTION …` round-trip.
///
/// Read-only fallback: if the user lacks the permission to fetch the
/// body (e.g. SECURITY DEFINER owned by another role) we still show the
/// signature and disable the editor.
struct FunctionEditorView: View {
    let service: ConnectionService
    let function: FunctionNode
    let onClose: () -> Void

    @State private var body_: String = ""
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var savedToast = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading function body…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topTrailing) {
                    SQLEditorTextView(text: $body_, schemaProvider: { service.schema })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if savedToast {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Saved").font(.caption.weight(.medium))
                        }
                        .padding(6)
                        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.green)
                        .padding(8)
                        .transition(.opacity)
                    }
                }
            }
            if let error {
                Divider()
                ScrollView {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            Divider()
            HStack {
                Text(function.qualifiedSignature)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || loading || body_.isEmpty)
            }
            .padding(Tokens.Spacing.md)
        }
        .frame(width: 760, height: 540)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "function").foregroundStyle(Tokens.Brand.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(function.signature)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Text("\(function.schema) · \(function.kind.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Tokens.Spacing.md)
    }

    private func load() async {
        guard let client = service.client else {
            error = "Not connected."; loading = false; return
        }
        let qualified = "\(SQLIdent.quote(function.schema)).\(SQLIdent.quote(function.name))\(function.arguments)"
        let sql = "SELECT pg_get_functiondef('\(qualified.replacingOccurrences(of: "'", with: "''"))'::regprocedure)"
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await def in rows.decode(String.self) {
                self.body_ = def
                self.loading = false
                return
            }
            self.error = "Function body wasn't returned."
            self.loading = false
        } catch {
            self.error = PostgresErrorMessage.describe(error)
            self.loading = false
        }
    }

    private func save() {
        saving = true
        Task {
            let result = await AdminActions.saveFunctionBody(body_, service: service)
            saving = false
            switch result {
            case .success:
                error = nil
                withAnimation { savedToast = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation { savedToast = false }
                }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}

/// Tiny NSTextView wrapper used by the function editor — reuses the
/// same SQL highlighter the scratchpad cells use without inheriting
/// all their cell-management state.
private struct SQLEditorTextView: NSViewRepresentable {
    @Binding var text: String
    let schemaProvider: (() -> SchemaSnapshot?)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            binding.wrappedValue = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isRichText = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.delegate = context.coordinator
            tv.allowsUndo = true
            tv.string = text
            tv.usesFindBar = true
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.textContainerInset = NSSize(width: 6, height: 6)
            if let storage = tv.textStorage {
                let highlighter = SQLHighlighter()
                storage.delegate = highlighter
                tv.attachedHighlighter = highlighter
                highlighter.highlight(storage)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            if let storage = tv.textStorage,
               let highlighter = tv.attachedHighlighter as? SQLHighlighter {
                highlighter.highlight(storage)
            }
        }
    }
}

// Pointer-stable address for objc_getAssociatedObject's key. UTF-8 bytes
// of a string literal have a stable address for the program lifetime,
// and `StaticString.utf8Start` exposes one without involving Swift's
// concurrency-safety analyzer (the value is shared-immutable C data).
private nonisolated(unsafe) let attachedHighlighterKey: UnsafeRawPointer = {
    let s: StaticString = "pgbrain.attachedHighlighter"
    return UnsafeRawPointer(s.utf8Start)
}()

private extension NSTextView {
    /// Retain the SQLHighlighter delegate alongside the text view so it
    /// outlives the makeNSView scope.
    var attachedHighlighter: AnyObject? {
        get { objc_getAssociatedObject(self, attachedHighlighterKey) as AnyObject? }
        set { objc_setAssociatedObject(self, attachedHighlighterKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
