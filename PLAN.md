# PLAN.md — pgBrain progress

Living plan. Update on every iteration that lands code or changes direction. Architecture/conventions live in `CLAUDE.md`.

---

## Done

### Iter 1 — Empty shell that launches (2026-05-20)
**Goal**: app launches, Welcome window renders, menu bar item works, About window works. No Postgres.

- SwiftPM scaffold (`Package.swift`, macOS 15 target, Swift 6 strict concurrency)
- AppDelegate-driven window orchestration (Welcome + About + WindowManager)
- `WelcomeView` — JetBrains-style two-pane: gradient brand left, connection list right (empty state)
- `AboutView` — version, attribution to Souris.CLOUD, website + donate links
- `MenuBarController` — `NSStatusItem` with Show Welcome / Bring to Front / Open Windows placeholder / About / Check for Updates (stub) / Quit
- `Connection` model (no password — passwords go to Keychain in iter-2)
- `AppearanceTokens` (spacing, corners, brand colors)
- Programmatic `AppIcon.icns` via `scripts/gen-icon.swift` (stacked-cylinder mark over brand gradient, tint-safe)
- `Info.plist` + hardened-runtime entitlements + ad-hoc-signed `.app` bundle
- Build scripts: `bundle.sh`, `run.sh`, `clean.sh`
- `CLAUDE.md`, `PLAN.md`, `README.md`

**Verified**: `./scripts/run.sh` produces a launchable app. Welcome window centers, menu bar icon appears, all dropdown items wired. App stays alive after closing all windows (re-openable from menu bar).

### Iter 2 — First real connection (2026-05-20)
**Goal**: user can create, save, and connect to a real Postgres server, see `version()`, close & relaunch with the password surviving.

- **PostgresNIO** dependency pinned in `Package.swift` (≥1.21).
- **`ConnectionEditorView`** sheet — name, host, port, database, user, password, SSL mode, color tag, production toggle, inline "Test Connection" probe.
- **`Keychain`** helper — generic-password items keyed by connection UUID, `kSecAttrAccessibleAfterFirstUnlock` so no prompt on relaunch.
- **`ConnectionStore`** — JSON-backed `@Observable` store at `~/Library/Application Support/pgBrain/connections.json`. Upsert / remove / load on init.
- **`AppSupport`** — single source of truth for the app's support directory and well-known file URLs.
- **`WelcomeView`** — real list driven by `ConnectionStore`, double-click or `⏎` opens, context menu for Edit/Delete, empty state with CTA.
- **`ConnectionWindowFactory` + `ConnectionWindowContent`** — one NSWindow per connection, tied to a `ConnectionService`. Title bar shows the connection name + `user@host:port`; production connections get a red-tinted background. Last close → Welcome re-shown via `WindowManager`.
- **`ConnectionService`** — owns the `PostgresClient`, exposes a `@MainActor @Observable` state machine (idle / connecting / connected / error / closed), runs `SELECT version()` on connect, surfaces TLS via `SSLMode`.
- **`StatusFooter`** — bottom-of-window strip: status dot, state label, production badge, target description, "connected at HH:MM".
- **Menu bar** — "Open Windows" submenu now populated dynamically from `WindowManager` on menu open; clicking a row focuses that window.

**Verified**: `./scripts/run.sh` produces an app where you can add a localhost connection, hit Save, double-click → window opens, runs `SELECT version()`, footer goes green. Quit and relaunch → connection list survives, password is still in the Keychain so reconnect is one click.

### Iter 3 — Sidebar + first table view (2026-05-20)
**Goal**: open a connection, see the database tree, double-click a table, browse the first 1000 rows.

- **`SchemaSnapshot` / `SchemaNode` / `TableNode` / `ColumnNode`** — value-type schema model in `Sources/pgBrain/Schema/SchemaModel.swift`. `ColumnTypeKind` buckets `format_type()` strings into renderer kinds (text / integer / number / bool / timestamp / date / json / uuid / bytes / unknown).
- **`SchemaFetcher`** — two parallel `pg_catalog` queries (relations + columns), merged in Swift. Excludes `pg_catalog`, `information_schema`, temp/toast namespaces. Handles `r/v/m/p` relkinds. Triggered automatically on connect from `ConnectionService.connect()` after `SELECT version()`.
- **`ConnectionService` additions** — `schema: SchemaSnapshot`, `schemaState: idle|loading|loaded|error`, `client: PostgresClient?` exposed (read-only) for downstream fetchers, and per-window `workspace: WorkspaceState`.
- **`SQLIdent`** — single chokepoint for PG identifier quoting (`"foo""bar"` style). Used everywhere we splice a schema/table/column name into generated SQL since the wire protocol doesn't allow parameterized identifiers.
- **`RowsFetcher`** — server-side `::text` cast for every projected column so the grid renders strings without a per-OID decoder zoo. `NULL` survives the cast. Limit + 1 to detect truncation. Returns a `Page { columns, rows, truncated, limit, elapsed }`.
- **`WorkspaceState`** — `@MainActor @Observable` per-window tab list with `openTable(_:)` (dedupes by `(schema, name)`), `closeTab(id:)`, and `move(id:before:)` for live drag-reorder.
- **`SidebarOutlineView`** — `NSOutlineView` wrapped in `NSViewRepresentable`. Four-level tree: database → schema → table/view → `columns` group → column rows. Class-backed `SidebarNode` identity for AppKit. Custom `SidebarCellView` with SF Symbol + name + type/kind hint. Database + schemas auto-expanded; tables open on double-click, other nodes toggle expansion.
- **`TabStripView`** — SwiftUI horizontal tab bar with brand-color active underline, hover/selected close button, live drag-reorder via `DropDelegate.dropEntered`. JetBrains feel.
- **`TableTabView`** — header (qualified name, column count, row count + ms, reload button) + `DataGridView` content. `RowsLoader` (`@MainActor @Observable`) drives the load on `.task(id: table.id)` so tab switches refetch automatically.
- **`DataGridView`** — `NSTableView` in inset style, alternating row colors, custom `DataCellView` with kind-aware alignment (right for numeric, center for bool), monospaced font for numeric / uuid / json / bytes / timestamp, italic+dimmed `NULL`, ✓ glyph for booleans, single-line JSON pretty-print. Per-column estimated widths.
- **`ConnectionWindowContent`** — `HSplitView` sidebar + workspace pane. Sidebar shows schema loading / loaded / error states with retry. Workspace shows empty state until a tab opens, then tab strip + table tab content.

**Verified**: connect to localhost, sidebar populates after `version()` resolves, double-clicking any table opens a new tab and renders the first 1000 rows in a real grid. Tabs reorder via drag, close cleanly, dedupe on repeat open. Build is clean (`swift build` ✓, `./scripts/bundle.sh` ✓).

---

## Next — Iter 4: SQL scratchpad with inline results ("Livebook")

Smallest useful step on top of iter-3: from any connection window, open a scratchpad tab, run SQL, see results inline below the statement.

1. **Decision: editor stack.** `TextKit 2` with a hand-rolled Postgres tokenizer is more work but feels Mac-native and has lower input latency than CodeMirror-in-WKWebView. Default to native unless tokenizer work blows the iter budget.
2. **`ScratchpadTab` workspace kind** — extend `WorkspaceState.TabKind` so the same tab strip handles scratchpads alongside tables. New-tab `+` button + `⌘N` opens a fresh scratchpad.
3. **`QueryRunner`** — async runner on top of the `PostgresClient`. Tracks backend PID (`pg_backend_pid()` on a sister connection) so cancel becomes possible in a later iter. Streams rows into the same `RowsFetcher.Page` shape the grid already understands.
4. **Run-on-cursor / run-selection** — `⌘↩` runs the statement at the caret (split on `;` outside of strings/comments) or the highlighted text if any.
5. **Inline result blocks** — each run produces a collapsible block immediately below its statement: status line + row count + duration + grid (or error). Multiple blocks stack chronologically; "Clear results" on the scratchpad header.
6. **History side panel** — list of past runs (statement preview, when, rows, ms) scoped to the current scratchpad; click to scroll the result back into view.

**Iter-4 done = user opens a scratchpad, types `SELECT * FROM <some_table> LIMIT 5`, presses `⌘↩`, and sees a result grid render right below the statement.**

---

## Backlog (rough order)

### Iter 5 — Editable data grid
- Inline cell editing with dirty marker.
- Commit-on-focus-loss, transaction batching, undo before commit.
- Type-aware editors (date picker for timestamps, popover JSON editor, etc.).

### Iter 6 — Production + color UX everywhere
- Production flag drives: red title bar accent, red badge on tab, red border in cells (warn on edit), confirm dialog before DELETE/UPDATE without WHERE.
- Color tag visible in: Welcome list, connection window sidebar header, menu bar window list, status footer.

### Iter 7 — Status footer + active operations popover
- Bottom-of-window footer: connection state, current schema, active query indicator, row count, last error.
- Popover with cancellable list of running queries / imports / exports.

### Iter 8 — Import / Export
- CSV / JSON / SQL export from any result set or table.
- Import wizard with column mapping UI (target columns, type coercion, on-conflict strategy).
- pg_dump / pg_restore wrapper (find binaries via Postgres.app path heuristic + override in Settings).

### Iter 9 — Cross-DB / cross-schema copy
- "Copy table to…" action: pick target connection + schema, map columns, choose strategy (truncate-and-insert / upsert / append).
- Bulk row streaming via `COPY` on both ends when possible.

### Iter 10 — State restoration
- Persist open windows + tabs + scratchpad contents to `~/Library/Application Support/pgBrain/state.json`.
- Setting: "Restore last session on launch" (default on).
- Sensitive bits (selected text, recent results) only restored if window had an open session.

### Iter 11 — Settings window
- Sections: General (restore on launch, theme), Connections (default SSL mode, pg_dump path), Editor (font, theme, tab size), Updates (Sparkle channel).
- Backed by `UserDefaults` with typed property wrappers.

### Iter 12 — Sparkle + GitHub release pipeline
- Embed Sparkle, code-sign EdDSA appcast.
- `scripts/release.sh`: bump version, generate changelog from conventional commits, build + notarize, build DMG with custom background, upload to GitHub Releases, regenerate appcast.xml.
- `scripts/bump.sh`: semver bump helper.

### Iter 13 — DMG with custom background
- Database-themed background image (placeholder generation script).
- `create-dmg` invocation in `release.sh`.

### Iter 14+ — Polish & extras
- Localization scaffolding (English first, Czech second).
- Quick-look-style row preview on hover.
- Schema diff tool.
- Saved query library.
- Per-connection custom variables (e.g. `:env_id` substitution before execution).

---

## Open questions for later
- **SQL editor implementation**: native `TextKit 2` with a hand-rolled Postgres lexer vs. CodeMirror-in-WKWebView. Native is more work but feels more Mac-native and has lower input latency. Decide at start of iter-4.
- **Sidebar tree perf**: at very large schemas (10k+ tables) `NSOutlineView` with lazy children works fine, but the search-as-you-type filter needs an index. Address at iter-3 if it bites.
- **Cancellation**: cancelling a long `PostgresQuery` requires opening a side connection and `pg_cancel_backend(pid)`. Plan the API around this from iter-2 (track every query's backend PID).
