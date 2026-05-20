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

### Iter 4 — SQL scratchpad with inline results ("Livebook") (2026-05-20)
**Goal**: from any connection window, open a scratchpad tab, run SQL, see results inline below the statement.

- **`Scratchpad` / `ResultBlock`** — `@MainActor @Observable` model in `Sources/pgBrain/State/Scratchpad.swift`. Scratchpad owns editor buffer + chronological result-block stack (newest at top). Each block is mutable so `.running → .success(QueryResult) | .failure(String)` updates land in place.
- **`WorkspaceState.TabKind.scratchpad`** — same tab strip handles scratchpads alongside tables. `openScratchpad()` always creates a fresh tab (unlike `openTable` which dedupes — multiple independent scratchpads is a real workflow).
- **`SQLStatementSplitter`** — quote/comment/dollar-quote-aware splitter on PG's actual grammar (single quotes with `''` escape, double-quoted idents, `--` line / `/* */` nestable block comments, `$tag$…$tag$`). `statementAt(caret:)` picks the JetBrains-style "run statement under cursor" target.
- **`QueryRunner`** — async runner over the existing `PostgresClient`. Walks the row stream, materialises columns from the first row's cells, decodes every value as `String?` via the cell's typed decoder, and returns a `RowsFetcher.Page` so the grid renders unchanged. `limit + 1` to flag truncation. `commandTag` left `nil` for now — PostgresNIO's streaming `query()` doesn't surface it cleanly; non-SELECT statements show "OK".
- **`ScratchpadView`** — header (title, ⌘↩ Run, Clear, History toggle), `HSplitView` of `VSplitView { SQLEditor / result-block stack }` + optional `HistoryPanel`. SQL editor is an `NSTextView` subclass with monospaced font, autosubst/autocorrect off, ⌘↩ intercepted in `keyDown`. Multi-line result-block stack via `ScrollViewReader` so the history panel can `scrollTo(blockID)`.
- **`HistoryPanel`** — compact right-side list of past runs: status icon, preview, HH:mm:ss, "N rows · X ms". Click → scroll matching block to top + select.
- **`+` button + `⌘N`** in `TabStripView` opens a fresh scratchpad.
- **`ConnectionService.client`** exposed read-only so the runner can reuse the live `PostgresClient`.

**Verified**: build is clean (`swift build` ✓, `./scripts/bundle.sh` ✓). App launches, Welcome lists saved connections. End-to-end run-and-render flow ready for interactive smoke test.

**Deferred** (intentional):
- Backend PID tracking for `pg_cancel_backend` — pushed to the cancellation iter where it actually pays off.
- SQL syntax highlighting — TextKit-2 tokenizer vs. CodeMirror-in-WKWebView decision punted until we've used the plain editor for a bit.
- `commandTag` population — PostgresNIO's high-level streaming API doesn't surface it; would need to drop to raw `PSQLChannel` bits.

---

## Next — Iter 5: Editable data grid

Smallest useful step on top of iter-4: clicking a cell in any data grid (table tab or scratchpad result block) lets you edit it. Commit-on-focus-loss with a dirty marker so accidental edits don't escape.

1. **Dirty buffer per grid** — track `(rowIndex, columnIndex) → newValue?` in the `DataGridView`'s model, draw a yellow corner triangle on dirty cells, footer shows "N pending edits".
2. **Inline `NSTextField` editor** — per-cell editor commit on Enter / Tab / focus-loss, Esc reverts. Cell rendering switches to editor when double-clicked. Type-aware later; iter-5 ships text-edit-for-everything.
3. **PK detection** — `pg_catalog.pg_index` query at schema-fetch time so every `TableNode` knows its primary key. Without a PK, editing is disabled with a tooltip explaining why.
4. **Commit / revert** — "Apply" + "Revert" in the table tab header. Apply runs an `UPDATE … WHERE pk = …` per row in a single transaction; "Revert" drops the dirty buffer. Failure surfaces as a per-row error.
5. **Undo before commit** — `⌘Z` in the grid undoes the last cell edit (stack lives in the dirty buffer).

**Iter-5 done = double-click any cell in a `pg_*` table → type a new value → tab away → "1 pending edit" in footer → press Apply → row updated in the DB.**

---

## Backlog (rough order)

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
- **SQL syntax highlighting**: shipped iter-4 with a plain `NSTextView` (no highlighting). Pick a direction once we've felt the absence — TextKit-2 + hand-rolled Postgres lexer vs. CodeMirror-in-WKWebView. Native is more work but lower input latency and matches the rest of the chrome.
- **Sidebar tree perf**: at very large schemas (10k+ tables) `NSOutlineView` with lazy children works fine, but the search-as-you-type filter needs an index. Address when it bites.
- **Cancellation**: cancelling a long `PostgresQuery` requires opening a side connection and `pg_cancel_backend(pid)`. The runner doesn't track backend PIDs yet — wire it in when the cancellation iter lands.
- **`commandTag` for non-SELECT**: PostgresNIO's high-level streaming API doesn't expose the libpq-style command tag. To show "UPDATE 12" instead of "OK", drop to raw `PSQLChannel` or fork a thin wrapper around `query`.
