import AppKit
import SwiftUI

/// Header row above the sidebar tree: schema picker, refresh progress, and
/// the extension-objects toggle.
struct SidebarHeader: View {
    let schemaNames: [String]
    let hidden: Set<String>
    let isRefreshing: Bool
    @Binding var showExtensionObjects: Bool
    let onShowAll: () -> Void
    let onFocus: (String) -> Void
    let onSetHidden: (Set<String>) -> Void
    let onCollapseAll: () -> Void
    @State private var showManager = false

    private var visibleCount: Int { schemaNames.filter { !hidden.contains($0) }.count }

    private var label: String {
        if hidden.isEmpty || visibleCount == schemaNames.count { return "All schemas" }
        if visibleCount == 1, let only = schemaNames.first(where: { !hidden.contains($0) }) { return only }
        return "\(visibleCount) of \(schemaNames.count) schemas"
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    onShowAll()
                } label: {
                    Label("All Schemas", systemImage: hidden.isEmpty ? "checkmark" : "")
                }
                Divider()
                ForEach(schemaNames, id: \.self) { name in
                    Button {
                        onFocus(name)
                    } label: {
                        Label(name, systemImage: hidden.contains(name) ? "" : "checkmark")
                    }
                }
                Divider()
                Button("Manage…") { showManager = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(label).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a schema to focus on. Checkmarks show the visible schemas.")
            .popover(isPresented: $showManager, arrowEdge: .bottom) {
                SchemaManagerPopover(
                    schemaNames: schemaNames,
                    hidden: hidden,
                    showExtensionObjects: $showExtensionObjects,
                    onSetHidden: onSetHidden
                )
            }
            Spacer(minLength: 4)
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .help("Reloading schema…")
            }
            Button(action: onCollapseAll) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Collapse all schemas")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// Checkbox list for bulk show/hide, with a search box for databases that
/// have dozens of schemas.
private struct SchemaManagerPopover: View {
    let schemaNames: [String]
    let hidden: Set<String>
    @Binding var showExtensionObjects: Bool
    let onSetHidden: (Set<String>) -> Void
    @State private var search = ""

    private var filtered: [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? schemaNames : schemaNames.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visible schemas").font(.headline)
            if schemaNames.count > 8 {
                TextField("Search schemas", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { !hidden.contains(name) },
                            set: { visible in
                                var next = hidden
                                if visible { next.remove(name) } else { next.insert(name) }
                                onSetHidden(next)
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            Divider()
            HStack {
                Button("Show All") { onSetHidden([]) }
                Button("Hide All") { onSetHidden(Set(schemaNames)) }
                Spacer()
            }
            .controlSize(.small)
            Toggle("Show extension-owned objects (e.g. PostGIS)", isOn: $showExtensionObjects)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// "N schemas hidden · Show all" strip under the tree.
struct SidebarHiddenFooter: View {
    let hiddenCount: Int
    let onShowAll: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash").font(.system(size: 10))
            Text("\(hiddenCount) schema\(hiddenCount == 1 ? "" : "s") hidden")
            Text("·").foregroundStyle(.tertiary)
            Button("Show all", action: onShowAll)
                .buttonStyle(.link)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider().opacity(0.4), alignment: .top)
    }
}

/// AppKit search field for the sidebar filter. A real NSSearchField (not a
/// SwiftUI TextField) because the field editor swallows ↓ / Return / Esc
/// before SwiftUI's key handlers see them; the delegate's
/// `doCommandBy` hook gets them first.
struct SidebarFilterField: NSViewRepresentable {
    @Binding var text: String
    let controller: SidebarController
    /// Large schemas debounce keystrokes; small ones filter live.
    var debounce: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Filter  (⌥⌘F)"
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .small
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchAction(_:))
        controller.filterField = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        controller.filterField = field
        if field.stringValue != text, field.currentEditor() == nil || text.isEmpty {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SidebarFilterField
        private var pending: Task<Void, Never>?

        init(parent: SidebarFilterField) { self.parent = parent }

        /// Fires for the field's own clear button as well as typing.
        @objc func searchAction(_ sender: NSSearchField) {
            if sender.stringValue.isEmpty, !parent.text.isEmpty {
                pending?.cancel()
                parent.text = ""
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            let value = field.stringValue
            pending?.cancel()
            if !parent.debounce || value.isEmpty {
                parent.text = value
                return
            }
            pending = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                self?.parent.text = value
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                flush(control)
                parent.controller.focusOutline(selectFirst: true)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                flush(control)
                parent.controller.openFirstMatch()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if (control as? NSSearchField)?.stringValue.isEmpty ?? true {
                    parent.controller.focusOutline()
                } else {
                    (control as? NSSearchField)?.stringValue = ""
                    pending?.cancel()
                    parent.text = ""
                }
                return true
            default:
                return false
            }
        }

        /// Apply a pending debounced value before acting on the results.
        private func flush(_ control: NSControl) {
            pending?.cancel()
            if let field = control as? NSSearchField {
                if parent.text != field.stringValue { parent.text = field.stringValue }
                parent.controller.syncFilter(field.stringValue)
            }
        }
    }
}
