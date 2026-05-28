import SwiftUI

struct WelcomeView: View {
    @State private var store = ConnectionStore.shared
    @State private var editorTarget: EditorTarget?
    @State private var selection: UUID?

    private enum EditorTarget: Identifiable {
        case new
        /// Brand-new connection pre-filled from a pasted pgBrain
        /// exchange payload (clipboard ⌘V on the Welcome screen).
        /// Password is carried alongside so the Keychain write happens
        /// on Save, just like the standard `.new` path.
        case imported(Connection, password: String?)
        case edit(Connection)

        var id: String {
            switch self {
            case .new:                 return "new"
            case .imported(let c, _):  return "imported-\(c.id.uuidString)"
            case .edit(let c):         return c.id.uuidString
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            brandPane
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Tokens.Brand.primary, Tokens.Brand.primaryDim],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            connectionPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: Tokens.Window.welcomeSize.width,
               minHeight: Tokens.Window.welcomeSize.height)
        .sheet(item: $editorTarget) { target in
            // `.imported` re-uses the same editor as `.new`, but
            // pre-seeds connection + password from the exchange JSON.
            let prefill: (Connection?, String?) = {
                switch target {
                case .new:                    return (nil, nil)
                case .imported(let c, let p): return (c, p)
                case .edit(let c):            return (c, nil)
                }
            }()
            ConnectionEditorView(
                connection: prefill.0,
                initialPassword: prefill.1,
                onSave: { conn, password in
                    store.upsert(conn)
                    if !password.isEmpty {
                        try? Keychain.setPassword(password, for: conn.id)
                    }
                    editorTarget = nil
                },
                onCancel: { editorTarget = nil }
            )
        }
        .background(pasteShortcut)
    }

    /// Hidden ⌘V button — when the system clipboard carries a pgBrain
    /// exchange JSON, opens the editor pre-filled. When it carries
    /// anything else, the action is a no-op so paste keeps working in
    /// whatever text field has focus (SwiftUI's keyboardShortcut
    /// system gives focused controls precedence over hidden buttons,
    /// but the no-op fallback covers the edge case where the Welcome
    /// window is key but no field is focused).
    @ViewBuilder
    private var pasteShortcut: some View {
        Button {
            handlePasteAttempt()
        } label: { EmptyView() }
        .keyboardShortcut("v", modifiers: .command)
        .hidden()
    }

    private func handlePasteAttempt() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let imported = ConnectionExchange.parse(raw)
        else { return }
        editorTarget = .imported(imported.connection, password: imported.password)
    }

    private var brandPane: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                Text("pgBrain")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text("Pro PostgreSQL for macOS")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
            Text("Connect to your databases, edit data, run queries with inline results, and move data between schemas with confidence.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("Version \(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text("by Souris.CLOUD")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(Tokens.Spacing.xl)
    }

    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    editorTarget = .new
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Tokens.Brand.primary)
            }
            .padding(.horizontal, Tokens.Spacing.lg)
            .padding(.top, Tokens.Spacing.lg)
            .padding(.bottom, Tokens.Spacing.md)

            Divider()

            if store.connections.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                    .background(
                        Button("Open Selected") { openSelected() }
                            .keyboardShortcut(.defaultAction)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                    )
            }
        }
        .onAppear {
            if selection == nil, let first = store.connections.first {
                selection = first.id
            }
        }
    }

    private func openSelected() {
        if let id = selection, let conn = store.connections.first(where: { $0.id == id }) {
            open(conn)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No connections yet")
                .font(.headline)
            Text("Add your first PostgreSQL connection to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Create connection") { editorTarget = .new }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Brand.primary)
                .controlSize(.large)
                .padding(.top, Tokens.Spacing.xs)
        }
        .padding(Tokens.Spacing.xl)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.connections) { connection in
                ConnectionRow(connection: connection)
                    .tag(connection.id)
                    .contentShape(Rectangle())
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .onTapGesture(count: 2) {
                        open(connection)
                    }
                    .contextMenu {
                        Button("Open") { open(connection) }
                        Button("Edit…") { editorTarget = .edit(connection) }
                        Divider()
                        Menu("Copy as") {
                            ForEach(ConnectionExchange.Format.allCases) { fmt in
                                Button(fmt.label) {
                                    copyConnection(connection, format: fmt, includePassword: false)
                                }
                            }
                            Divider()
                            ForEach(ConnectionExchange.Format.allCases) { fmt in
                                Button("\(fmt.label) — include password") {
                                    copyConnection(connection, format: fmt, includePassword: true)
                                }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            store.remove(connection)
                            if selection == connection.id { selection = nil }
                        }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }

    private func open(_ connection: Connection) {
        AppDelegate.shared?.openConnection(connection)
    }

    /// Render `connection` in `format` and put the result on the
    /// system pasteboard. Passwords stay out of the clipboard unless
    /// the user picked the "include password" variant.
    private func copyConnection(_ connection: Connection, format: ConnectionExchange.Format, includePassword: Bool) {
        let text = ConnectionExchange.render(connection, format: format, includePassword: includePassword)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ConnectionRow: View {
    let connection: Connection

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Circle()
                .fill(connection.colorTag.swiftUIColor.opacity(connection.colorTag == .none ? 0 : 1))
                .stroke(Color.secondary.opacity(connection.colorTag == .none ? 0.4 : 0), lineWidth: 1)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name).font(.body.weight(.medium))
                    if connection.isProduction {
                        Text("PROD")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Tokens.Brand.danger)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private var subtitle: String {
        let db = connection.database.isEmpty ? "—" : connection.database
        return "\(connection.username)@\(connection.host):\(connection.port) · \(db)"
    }
}

#Preview {
    WelcomeView()
}
