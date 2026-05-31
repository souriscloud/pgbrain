import SwiftUI

/// In-app Help: a small documentation browser. A topic sidebar on the left,
/// rich formatted content on the right. Intentionally self-contained (no web
/// view) so it works offline and matches the app's chrome.
struct HelpView: View {
    // List selection must be Optional to bind reliably; fall back to .welcome.
    @State private var selection: HelpTopic? = .welcome
    @State private var query: String = ""
    private var topic: HelpTopic { selection ?? .welcome }

    private var matches: [HelpTopic] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return HelpTopic.allCases }
        return HelpTopic.allCases.filter { $0.matches(q) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(matches, selection: $selection) { t in
                    Label(t.title, systemImage: t.icon)
                        .tag(t)
                }
                .listStyle(.sidebar)
                if matches.isEmpty {
                    Text("No matches")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 260)
            .searchable(text: $query, placement: .sidebar, prompt: "Search help")
            .onChange(of: query) { _, _ in
                // Keep the selection valid as the list filters under it.
                if let sel = selection, !matches.contains(sel) {
                    selection = matches.first
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                    topic.content
                }
                .padding(Tokens.Spacing.xl)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(topic)   // reset scroll on topic change
        }
        .frame(minWidth: 780, minHeight: 540)
    }
}

// MARK: - Topics

enum HelpTopic: String, CaseIterable, Identifiable {
    case welcome, connecting, connections, grid, editing, notebook, completion
    case schemaTools, importExport, postgis, dba, shortcuts, support
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome:      return "Welcome"
        case .connecting:   return "Connecting"
        case .connections:  return "Managing Connections"
        case .grid:         return "The Data Grid"
        case .editing:      return "Editing Data"
        case .notebook:     return "SQL Notebook"
        case .completion:   return "Autocomplete"
        case .schemaTools:  return "Schema & Objects"
        case .importExport: return "Import, Export & Copy"
        case .postgis:      return "PostGIS & Maps"
        case .dba:          return "DBA Toolkit"
        case .shortcuts:    return "Keyboard Shortcuts"
        case .support:      return "Support & Feedback"
        }
    }

    var icon: String {
        switch self {
        case .welcome:      return "sparkles"
        case .connecting:   return "server.rack"
        case .connections:  return "rectangle.connected.to.line.below"
        case .grid:         return "tablecells"
        case .editing:      return "pencil.and.list.clipboard"
        case .notebook:     return "doc.text"
        case .completion:   return "text.append"
        case .schemaTools:  return "hammer"
        case .importExport: return "square.and.arrow.up.on.square"
        case .postgis:      return "map"
        case .dba:          return "wrench.and.screwdriver"
        case .shortcuts:    return "keyboard"
        case .support:      return "heart"
        }
    }

    /// Searchable terms — title + synonyms + the feature words that appear in
    /// the topic body, so the search field works like a full-text index.
    var keywords: String {
        switch self {
        case .welcome:      return "overview start intro command palette speed native"
        case .connecting:   return "connect host port database user password keychain ssh tunnel bastion production ssl tls sslmode new connection"
        case .connections:  return "manage export import backup json clipboard copy paste bulk passwords share move connections between machines welcome window settings"
        case .grid:         return "data grid table rows cells filter where order by sort search find profile column distinct counts nulls form map view modes pagination"
        case .editing:      return "edit cell double click typed editor date time enum boolean json now expression default null insert row add delete row cmd backspace transaction apply revert staged commit values"
        case .notebook:     return "sql scratchpad notebook run cell statement under caret selection atomic transaction inline results pivot chart map history snippets save reopen explain format"
        case .completion:   return "autocomplete intellisense completion suggestions columns tables functions keywords fuzzy esc space schema aware popup"
        case .schemaTools:  return "schema duplicate clone create table designer function procedure index view materialized matview sequence rename drop hide comment column alter erd diagram database grant role"
        case .importExport: return "import export csv json sql pg_dump pg_restore dump backup copy table cross database mapping clipboard markdown slack"
        case .postgis:      return "postgis geometry geography spatial map wkt srid point line polygon marker"
        case .dba:          return "dba activity pg_stat_activity locks index usage vacuum analyze reindex maintenance listen notify sequences erd monitoring"
        case .shortcuts:    return "keyboard shortcuts keys hotkeys command font size zoom delete run page"
        case .support:      return "support feedback bug report github ko-fi donate version update sparkle"
        }
    }

    func matches(_ q: String) -> Bool {
        title.localizedCaseInsensitiveContains(q) || keywords.localizedCaseInsensitiveContains(q)
    }

    @ViewBuilder var content: some View {
        switch self {
        case .welcome:      HelpWelcome()
        case .connecting:   HelpConnecting()
        case .connections:  HelpConnections()
        case .grid:         HelpGrid()
        case .editing:      HelpEditing()
        case .notebook:     HelpNotebook()
        case .completion:   HelpCompletion()
        case .schemaTools:  HelpSchemaTools()
        case .importExport: HelpImportExport()
        case .postgis:      HelpPostGIS()
        case .dba:          HelpDBA()
        case .shortcuts:    HelpShortcuts()
        case .support:      HelpSupport()
        }
    }
}

// MARK: - Reusable building blocks

/// Section title with a brand-tinted icon.
private struct HelpHeader: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Tokens.Brand.primary)
                Text(title).font(.system(size: 24, weight: .bold))
            }
            if let subtitle {
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
            }
        }
    }
}

/// One feature row: icon, bold lead, explanation.
private struct HelpPoint: View {
    let icon: String
    let lead: String
    let body_: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Brand.primary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(lead).font(.headline)
                Text(body_).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A keyboard-shortcut row: the keys as chips, then what it does.
private struct ShortcutRow: View {
    let keys: [String]
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { k in
                    Text(k)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.separator))
                        )
                }
            }
            .frame(width: 132, alignment: .leading)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private func Para(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Topic content

private struct HelpWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "sparkles", title: "Welcome to pgBrain",
                       subtitle: "A native macOS PostgreSQL client.")
            Para("pgBrain pairs a DataGrip-style workflow — one window per connection, tabs, a SQL scratchpad with inline results — with Mac-native chrome and an AppKit data grid built for speed.")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "server.rack", lead: "One window per connection",
                          body_: "Each database gets its own window with a schema sidebar, table tabs, and SQL notebooks.")
                HelpPoint(icon: "command", lead: "Command Palette",
                          body_: "Press ⌘K for fuzzy access to tables, views, functions, ERDs, view modes, and every action.")
                HelpPoint(icon: "bolt.fill", lead: "Fast by default",
                          body_: "Streaming queries, an auto-LIMIT safety net on bare SELECTs, and type-aware cell rendering.")
            }
            Text("Pick a topic on the left to dig in.")
                .font(.callout).foregroundStyle(.tertiary).padding(.top, 4)
        }
    }
}

private struct HelpConnecting: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "server.rack", title: "Connecting")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "plus.rectangle.on.rectangle", lead: "New connection",
                          body_: "File → New Connection… (⌘N) opens the Welcome window. Fill in host, port, database, user, and password.")
                HelpPoint(icon: "key.fill", lead: "Passwords stay in Keychain",
                          body_: "Passwords are stored in the macOS Keychain, never in the connection file — so they survive app updates without re-prompting.")
                HelpPoint(icon: "lock.shield", lead: "SSH tunnels & production guards",
                          body_: "Tunnel through a bastion host, and mark a connection Production to get a red window chrome and confirm-before-write guardrails.")
            }
        }
    }
}

private struct HelpGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "tablecells", title: "The Data Grid")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "pencil", lead: "Edit in place",
                          body_: "Double-click a cell to edit; the ＋ button adds a draft row. Edits and inserts commit together in one transaction with Apply.")
                HelpPoint(icon: "line.3.horizontal.decrease.circle", lead: "Filter & sort",
                          body_: "Type a WHERE/ORDER BY in the strip above the grid, or right-click a cell to filter to its value. Click a header to sort.")
                HelpPoint(icon: "chart.bar.doc.horizontal", lead: "Profile a column",
                          body_: "Right-click a column — header or cell — → Profile column… for counts, nulls, distinct, and min/max/avg.")
                HelpPoint(icon: "rectangle.split.2x1", lead: "Grid · Form · Map",
                          body_: "Switch how rows render from the footer toggle, or via ⌘K → “View as …”. Map appears for tables with a geometry column.")
            }
        }
    }
}

private struct HelpNotebook: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "doc.text", title: "SQL Notebook")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "play.fill", lead: "Run cells, see results inline",
                          body_: "⌘T opens a scratchpad. Write SQL and press ⌘↵ to run; each result lands in its own block right below the query.")
                HelpPoint(icon: "tablecells.badge.ellipsis", lead: "Pivot, chart, map a result",
                          body_: "Every result block has Copy, Pivot, Chart, and (for geometry) Map buttons — reshape data without leaving the notebook.")
                HelpPoint(icon: "clock.arrow.circlepath", lead: "History & snippets",
                          body_: "Past statements are searchable via Query History…; save reusable fragments as Snippets. Both are in the Command Palette.")
            }
        }
    }
}

private struct HelpPostGIS: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "map", title: "PostGIS & Maps",
                       subtitle: "Spatial data, made visual.")
            Para("When a database has PostGIS installed, pgBrain detects it automatically — a “PostGIS” badge appears in the window header.")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "text.quote", lead: "Readable geometry",
                          body_: "geometry/geography columns render as WKT (SRID=4326;POINT(…)) instead of opaque WKB hex, in the grid and the scratchpad.")
                HelpPoint(icon: "mappin.and.ellipse", lead: "Map view",
                          body_: "Any table or query result with a geometry column gets a Map view — points as markers, lines as polylines, polygons as filled shapes, auto-fit to the data.")
            }
        }
    }
}

private struct HelpDBA: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "wrench.and.screwdriver", title: "DBA Toolkit")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "waveform.path.ecg", lead: "Activity & locks",
                          body_: "Show Activity Panel (⌘K) gives live pg_stat_activity, locks, and index usage.")
                HelpPoint(icon: "point.3.connected.trianglepath.dotted", lead: "ERD diagrams",
                          body_: "⌘K → “Show ERD: <schema>” lays out tables and their relationships visually.")
                HelpPoint(icon: "square.and.arrow.up.on.square", lead: "Import / export / dump",
                          body_: "Stream CSV in and out, run pg_dump / restore, and copy tables across databases with column mapping.")
                HelpPoint(icon: "hammer", lead: "Schema & object editing",
                          body_: "Create tables and indexes visually, edit views, functions, roles, sequences, partitions, grants, and more.")
            }
        }
    }
}

private struct HelpConnections: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "rectangle.connected.to.line.below", title: "Managing Connections",
                       subtitle: "Back up and move your connections.")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "square.and.arrow.up.on.square", lead: "Bulk export",
                          body_: "Welcome window → Import / Export → “Export All…” writes every connection to a JSON file, or “Copy All as JSON” puts them on the clipboard.")
                HelpPoint(icon: "square.and.arrow.down", lead: "Bulk import",
                          body_: "“Import from File…” or “Paste Connections” adds them back. Exact duplicates (same name/host/port/db/user) are skipped, so re-importing is safe.")
                HelpPoint(icon: "key.fill", lead: "Passwords",
                          body_: "Exports omit passwords by default. To include them, use Settings ▸ Connections and toggle “Include passwords” — treat that file as a secret.")
                HelpPoint(icon: "doc.on.doc", lead: "Single-connection share",
                          body_: "Right-click a connection → Copy as… for a pgBrain payload, Connection URL, or Laravel .env block. Paste a pgBrain payload back with ⌘V.")
            }
        }
    }
}

private struct HelpEditing: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "pencil.and.list.clipboard", title: "Editing Data",
                       subtitle: "Typed, transactional, reversible.")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "cursorarrow.click", lead: "Typed cell editor",
                          body_: "Double-click a cell to open an editor matched to the column type — date/time pickers, a true/false toggle, enum dropdowns, and a JSON editor with syntax highlighting and prettify.")
                HelpPoint(icon: "function", lead: "NULL, DEFAULT & expressions",
                          body_: "Every editor has a mode menu: set the value, NULL, the column DEFAULT, a quick now() / gen_random_uuid(), or a raw SQL expression that runs server-side.")
                HelpPoint(icon: "plus.square", lead: "Insert & delete rows",
                          body_: "The ＋ button adds a draft row. Select rows and press ⌘⌫ to stage them for deletion (or right-click → Delete). Nothing hits the database until you Apply.")
                HelpPoint(icon: "checkmark.circle", lead: "One transaction, with undo",
                          body_: "Edits, inserts and deletes are staged and committed together in a single transaction on Apply. ⌘Z steps back through pending edits; Revert clears them all.")
            }
        }
    }
}

private struct HelpCompletion: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "text.append", title: "Autocomplete",
                       subtitle: "Schema-aware, IDE-grade.")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "list.bullet.rectangle", lead: "Rich suggestions",
                          body_: "As you type SQL, a popup offers tables, columns (with their type), functions (with their signature), and keywords — ranked for the spot you're in (after FROM, after a dot, in a WHERE, …).")
                HelpPoint(icon: "magnifyingglass", lead: "Fuzzy & manual",
                          body_: "Matching is fuzzy (gru → gen_random_uuid). It opens automatically after two characters; press Esc or ⌥Esc to summon it, ↑/↓ to move, ↵ or ⇥ to accept.")
                HelpPoint(icon: "rectangle.and.pencil.and.ellipsis", lead: "Everywhere SQL lives",
                          body_: "The scratchpad, the WHERE / ORDER BY strips, and the expression mode of the cell editor all share the same completion — biased toward the relevant table's columns.")
            }
        }
    }
}

private struct HelpSchemaTools: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "hammer", title: "Schema & Objects")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "doc.on.doc.fill", lead: "Duplicate a schema",
                          body_: "Right-click a schema → Duplicate schema… to clone it into a new one, choosing exactly what to copy: table structure, data, views, materialized views, functions, and sequences.")
                HelpPoint(icon: "tablecells.badge.ellipsis", lead: "Create & alter visually",
                          body_: "Build tables and indexes with a visual designer; add/rename/alter columns; edit views, functions/procedures, sequences, and comments — each with a live SQL preview.")
                HelpPoint(icon: "eye.slash", lead: "Organize the sidebar",
                          body_: "Rename, drop, or hide schemas from the sidebar's context menu. Hidden schemas drop out of the tree, the palette, and completion until you show them again.")
                HelpPoint(icon: "point.3.connected.trianglepath.dotted", lead: "Diff & visualize",
                          body_: "Compare two databases with Diff Schemas…, and lay out a schema's relationships with ⌘K → “Show ERD: <schema>”.")
            }
        }
    }
}

private struct HelpImportExport: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "square.and.arrow.up.on.square", title: "Import, Export & Copy")
            VStack(alignment: .leading, spacing: 14) {
                HelpPoint(icon: "tablecells", lead: "Table export",
                          body_: "Export any table as CSV, JSON, or SQL INSERTs — from the table's menu or the Command Palette.")
                HelpPoint(icon: "tray.and.arrow.down", lead: "Import",
                          body_: "Stream CSV or JSON into a table. Large files load in chunks so memory stays flat.")
                HelpPoint(icon: "externaldrive", lead: "pg_dump / pg_restore",
                          body_: "Run a full database dump or restore through the bundled CLI. Set custom binary paths in Settings ▸ Binaries if they aren't auto-detected.")
                HelpPoint(icon: "arrow.left.arrow.right", lead: "Cross-database copy",
                          body_: "Copy a table into another connection with per-column mapping and an append / replace strategy. Selection copies as a Markdown table or Slack code block too.")
            }
        }
    }
}

private struct HelpShortcuts: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "keyboard", title: "Keyboard Shortcuts")
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(keys: ["⌘", "K"], label: "Command Palette")
                ShortcutRow(keys: ["⌘", "N"], label: "New connection")
                ShortcutRow(keys: ["⌘", "T"], label: "New SQL scratchpad")
                ShortcutRow(keys: ["⌘", "↵"], label: "Run statement under caret / selection")
                ShortcutRow(keys: ["⌥", "Esc"], label: "Trigger autocomplete")
                ShortcutRow(keys: ["⌘", "⌫"], label: "Stage selected row(s) for delete")
                ShortcutRow(keys: ["⌘", "Z"], label: "Undo a pending cell edit")
                ShortcutRow(keys: ["⌘", "+"], label: "Increase editor font size")
                ShortcutRow(keys: ["⌘", "−"], label: "Decrease editor font size")
                ShortcutRow(keys: ["⌘", "0"], label: "Reset editor font size")
                ShortcutRow(keys: ["⌘", "F"], label: "Find in the grid / editor")
                ShortcutRow(keys: ["⌘", "⇧", "←"], label: "Previous page of rows")
                ShortcutRow(keys: ["⌘", "⇧", "→"], label: "Next page of rows")
                ShortcutRow(keys: ["⌘", ","], label: "Settings")
                ShortcutRow(keys: ["⌘", "W"], label: "Close tab / window")
            }
        }
    }
}

private struct HelpSupport: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "heart.fill", title: "Support & Feedback")
            Para("pgBrain is built by one person. Bug reports and ideas genuinely shape it — and if it saves you time, a coffee keeps it going.")
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    AppDelegate.shared?.showFeedback()
                } label: {
                    Label("Send feedback or report a bug…", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.borderedProminent)

                Link(destination: URL(string: "https://github.com/\(GitHubFeedback.repo)")!) {
                    Label("pgBrain on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://ko-fi.com/souriscloud")!) {
                    Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                }
                .tint(.pink)
            }
            Text("pgBrain \(AppInfo.version) (build \(AppInfo.build))")
                .font(.footnote).foregroundStyle(.tertiary).padding(.top, 6)
        }
    }
}
