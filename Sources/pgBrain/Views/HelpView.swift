import SwiftUI

/// In-app Help: a small documentation browser. A topic sidebar on the left,
/// rich formatted content on the right. Intentionally self-contained (no web
/// view) so it works offline and matches the app's chrome.
struct HelpView: View {
    // List selection must be Optional to bind reliably; fall back to .welcome.
    @State private var selection: HelpTopic? = .welcome
    private var topic: HelpTopic { selection ?? .welcome }

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selection) { t in
                Label(t.title, systemImage: t.icon)
                    .tag(t)
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 208, max: 240)
            .listStyle(.sidebar)
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
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Topics

enum HelpTopic: String, CaseIterable, Identifiable {
    case welcome, connecting, grid, notebook, postgis, dba, shortcuts, support
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome:   return "Welcome"
        case .connecting:return "Connecting"
        case .grid:      return "The Data Grid"
        case .notebook:  return "SQL Notebook"
        case .postgis:   return "PostGIS & Maps"
        case .dba:       return "DBA Toolkit"
        case .shortcuts: return "Keyboard Shortcuts"
        case .support:   return "Support & Feedback"
        }
    }

    var icon: String {
        switch self {
        case .welcome:   return "sparkles"
        case .connecting:return "server.rack"
        case .grid:      return "tablecells"
        case .notebook:  return "doc.text"
        case .postgis:   return "map"
        case .dba:       return "wrench.and.screwdriver"
        case .shortcuts: return "keyboard"
        case .support:   return "heart"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .welcome:    HelpWelcome()
        case .connecting: HelpConnecting()
        case .grid:       HelpGrid()
        case .notebook:   HelpNotebook()
        case .postgis:    HelpPostGIS()
        case .dba:        HelpDBA()
        case .shortcuts:  HelpShortcuts()
        case .support:    HelpSupport()
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

private struct HelpShortcuts: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HelpHeader(icon: "keyboard", title: "Keyboard Shortcuts")
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(keys: ["⌘", "K"], label: "Command Palette")
                ShortcutRow(keys: ["⌘", "N"], label: "New connection")
                ShortcutRow(keys: ["⌘", "T"], label: "New SQL scratchpad")
                ShortcutRow(keys: ["⌘", "↵"], label: "Run the current query / cell")
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
