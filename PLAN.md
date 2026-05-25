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

### Iter 5 — Editable data grid (2026-05-23)
**Goal**: double-click any cell in a table tab, type a new value, press Apply → row updated in Postgres.

- **PK detection in schema fetcher** — new third query against `pg_index` joined with `pg_attribute` (via `unnest(indkey) WITH ORDINALITY` to preserve composite-key order), merged into `TableNode.primaryKey: [String]`. `TableNode.isEditable` gates editing on `kind == .table` + non-empty PK; views and PK-less tables show a lock icon with a tooltip.
- **`EditBuffer`** — `@MainActor @Observable` per-grid store of dirty `(row, column) → newValue` plus a per-edit history stack so `undo()` walks one cell at a time. Lives on `RowsLoader` for the tab's lifetime.
- **`UpdateApplier`** — runs all pending edits inside one `client.withTransaction { … }`. Generates one `UPDATE` per dirty row with positional binds + server-side `::"<typename>"` casts so we don't need per-type Swift encoders. PK values are read out of the in-memory snapshot, so deletes between load and apply will be detected by zero rows affected (treated as success today; row-existence check is on the backlog).
- **`EditableTableView`** — `NSTableView` subclass that owns `doubleAction` → `editColumn(_:row:with:select:)` and intercepts ⌘Z via `performKeyEquivalent` to pop the `EditBuffer` undo stack.
- **`DataGridView` editing** — per-cell `NSTextField` editor (commit on Enter/Tab/focus-loss, Esc reverts via cached `lastConfiguredText`). Dirty cells get a yellow corner triangle + faint yellow tint. Bool glyph (`✓`) swaps to raw token on edit start so the server gets a parseable value. Empty-string commits on originally-NULL cells are no-ops to avoid silently overwriting NULL.
- **`TableTabView` header** — pending count, Apply (transactional commit, splices new values into `page.rows` on success), Revert (drops the buffer), inline error text on failure. Apply button is brand-tinted, prominent; Revert is bordered.
- **`RowsFetcher.Page.rows`** — now `var` so apply can mutate in place without a refetch.

**Verified**: `swift build` ✓, `./scripts/bundle.sh` ✓. App launches; tables with a PK show the lock-free header and editable cells, tables without a PK show the lock icon.

**Deferred** (intentional):
- Explicit "Set NULL" affordance for non-NULL cells — empty-string-on-non-NULL is treated as the literal empty string today.
- Row-existence guard before UPDATE (zero rows affected → warn). PK values are still trusted from the snapshot.
- Type-specific editors (date pickers, bool toggles, JSON editor). iter-5 ships text-edit-for-everything per plan.
- `INSERT` and `DELETE` from the grid — separate iter.

### Iter 6 — Production + color UX everywhere (2026-05-25)
**Goal**: connection identity (colour tag + PROD flag) reads at a glance from every surface, and destructive SQL on a PROD connection has to be confirmed.

- **`ConnectionAppearance`** — single value type wrapping a `Connection`; exposes `accent` (brand violet → connection colour), `emphasized` (production red wins), `windowTintNS`, and a `" · PROD"` suffix string. Used by every painted surface so colour rules live in one file.
- **Sidebar header** (`ConnectionWindowContent.sidebarHeader`) — name + db, colour dot, PROD pill, tinted background. Sits above the schema outline.
- **Top stripe** — 3pt coloured bar above the workspace; red on production, connection colour otherwise, hidden for plain connections.
- **Tab strip** (`TabStripView`) — active-tab underline + icon use `appearance.emphasized`; production connections show a small red dot per tab as a passive warning.
- **Status footer** — adds the colour dot beside the existing PROD pill; the dot is hidden for uncoloured connections.
- **Menu bar window list** — entries pick up a coloured `circle.fill` palette symbol image and a `" · PROD"` suffix so prod windows are obvious in the dropdown.
- **`SQLSafety`** — quote/comment/dollar-quote-aware token sniffer that classifies a statement as `readOnly | write | destructiveUnscoped | ddl`. `ScratchpadView.runAtCaret()` consults it and, on production connections, shows a critical NSAlert with the SQL preview before firing the actual query.

**Verified**: `swift build` ✓. Existing PROD-tinted window background from iter-2 stays; the new chrome layers on top.

**Deferred**:
- Per-cell red border on the editable grid for PROD connections — added passive dot on the tab badge instead; cell-level treatment can wait until we have a clearer signal it's noisy enough to need it.
- Confirm dialog on Apply-against-PROD in the data grid — UpdateApplier is intrinsically scoped to a single PK so it's strictly safer than scratchpad SQL; revisit if real usage proves otherwise.

### Iter 7 — Operations popover + real cancellation (2026-05-25)
**Goal**: every long-running query/update/schema fetch is visible from the status footer, with a working Cancel button that actually stops server-side work.

- **`OperationsCenter`** — `@MainActor @Observable` per-`ConnectionService` registry. Each `Operation` has kind (query / update / schema / export / import), summary, status (`running / succeeded / failed / cancelled`), startedAt/finishedAt, `backendPID`, a Sendable `cancellationHandler`, and an owning `Task` handle.
- **`OperationsHelpers.fetchBackendPID`** — one-shot `SELECT pg_backend_pid()` on a checked-out connection. Runners call this once when they enter `withConnection { … }` so the op gets a real PID.
- **Cancellation flow** — `OperationsCenter.cancel(op)` cancels the owning Task and fires `cancellationHandler` on a detached Task. The handler checks out a *sister* connection from the same `PostgresClient` pool and runs `SELECT pg_cancel_backend($pid)`. This matches what psql does on ^C and works through pooling.
- **Sendable boundary** — runners take `operationID: UUID` + `tracker: OperationsCenter` rather than the @MainActor `Operation` itself, then hop back to main with `Task { @MainActor in tracker.attachCancellation(...) }`. Avoids strict-concurrency races without `@unchecked Sendable` escape hatches.
- **`QueryRunner.run`** — refactored to use `client.withConnection`, capture PID, register cancellation. New `summary(of:max:)` helper for popover labels. Inner `runOnConnection(_:on:limit:)` extracted for iter-9's cross-DB copy.
- **`UpdateApplier.apply`** — adds `operationID`/`tracker` parameters; UPDATE batch becomes cancellable mid-transaction (Postgres rolls back automatically).
- **`ConnectionService.loadSchema`** — also tracked (no cancellation handle — schema fetch fans out across parallel queries).
- **`pgbrainQuietLogger`** — shared `SwiftLogNoOpLogHandler`-backed logger so we stop spinning up a new `Logger` per call. iter-11 Settings will let users flip it to a real logger.
- **`OperationsPopover`** — anchored to a new "N running" indicator in the status footer. Per-row: status glyph, kind icon, PID (when known), one-line summary, elapsed, Cancel button while live, failure text inline. "Clear Finished" at the bottom. 380×280, runs in alphabetical-by-recency order (newest running first).
- **Status footer indicator** — `ProgressView` + "N running" when live, plus a "total" badge after everything's done; hidden entirely when the center is empty.

**Verified**: `swift build` ✓. Build now uses Swift 6 strict concurrency with the runner/tracker boundary, no `@unchecked` escape hatches.

**Deferred**:
- Per-statement cancellation inside the schema fetch fan-out — single batch op for now since the user rarely wants to cancel "loading schema".
- Persisting the operations log across relaunches — popover only shows the current session.

### Iter 8 — Streaming export / import + pg_dump (2026-05-25)
**Goal**: get data out of and into a table fast and at any scale, without loading the whole thing into memory.

- **`Exporter`** — streams full tables via `SELECT col::text … FROM …` (no LIMIT) → buffered 64KB writes → file. Three formats: `.csv` (RFC 4180), `.json` (streaming array with type-aware values), `.sql` (one `INSERT` per row). Cancellable via `OperationsCenter` + sister-connection `pg_cancel_backend`. `exportPage` for already-materialised scratchpad results.
- **`Importer`** — CSV reader streams the input file (no whole-file load); transcodes each row to Postgres COPY TEXT format and pushes through PostgresNIO's `copyFrom`. RFC 4180 parsing (quotes, `""` escape, embedded newlines), header-driven column mapping (or positional fallback), `emptyAsNull` toggle. Whole import runs inside a single transaction with `SET LOCAL search_path` for schema-qualified targets, rolls back on cancel/error.
- **`PgDumpCLI`** — `pg_dump` wrapper. Auto-discovers binaries from Postgres.app, Homebrew (Apple Silicon + Intel), EnterpriseDB installer, `/usr/bin`, with a `pgbrain.binaryOverride.<name>` UserDefaults override hook for iter-11 Settings. Subprocess receives `PGPASSWORD` via env (never on the command line). Supports `.plain` / `.custom` / `.directory` / `.tar` output formats.
- **UI hooks**:
  - Table tab header: `Menu` with "Export full table (streaming)" (CSV/JSON/SQL) → `NSSavePanel`, "Export visible page" for the loaded 1000 rows, "Import CSV into this table…" → `NSOpenPanel`. Reloads after import.
  - Scratchpad result block: per-format Export menu in the block header (in-memory `exportPage`).
  - Sidebar header: `ellipsis.circle` menu with pg_dump format options + reload schema.
- Every long-running export/import shows up in the iter-7 operations popover with a working Cancel button.

**Verified**: `swift build` ✓. Streaming row iteration confirmed via `PostgresRowSequence`; `copyFrom` confirmed in PostgresNIO 1.21.

**Deferred**:
- Column-mapping wizard UI (manual reorder, type coercion override, on-conflict strategy) — iter-8 ships header-driven mapping; the wizard lands when the first user needs to reshape CSV to fit.
- `pg_restore` action — the dump side covers backup-on-demand; restore wizard belongs in iter-11/Settings flow.
- Server-side `COPY ... TO STDOUT` instead of `SELECT ... FROM` — would be faster for very wide tables but PostgresNIO's high-level API doesn't expose it. Add when we drop to the raw channel for the same reason as commandTag.

### Iter 9 — Cross-DB / cross-schema copy (2026-05-25)
**Goal**: pipe a table from one connection to another without staging it on disk and without holding everything in memory.

- **`CrossDBCopy`** — Wraps source `SELECT … FROM` (streaming row sequence) → target `copyFrom` (PostgresNIO COPY TEXT writer). Bytes never touch disk; worst-case memory is one 64KB `ByteBuffer`. Source rows are projected via per-column `::text` so we don't need typed encoders on either end.
- **Two-sided cancellation** — same sister-connection `pg_cancel_backend` handshake from iter-7, wired to the *source* connection (the side actually pulling rows). Cancelling the operation cleanly rolls back the target transaction via `ROLLBACK`.
- **Transient target client** — when the target connection isn't currently open in another window, a fresh `PostgresClient` is brought up for the duration of the copy and torn down via `Task.detached { client.run() }` + `defer cancel`. When it *is* open (via `WindowManager.service(for:)`), we reuse the already-running pool so we don't double-connect.
- **`WindowManager` upgrade** — now tracks `(connectionID, NSWindow, weak service)` so cross-DB copy (and any future "act on the other open connection" feature) can grab the live `PostgresClient` directly.
- **Strategies** — `.append` and `.truncateAndInsert` ship; `.upsert` (INSERT ... ON CONFLICT) deferred until we have a column-mapping wizard that needs it.
- **`CrossDBCopyView`** — SwiftUI sheet reached from the sidebar right-click context menu (`Copy table to…`). Lists every saved connection except the current one (with "· open" hint when a window already holds it). Default mapping is 1:1 source→target by name with per-column include toggles + free-text rename. Submits → opens an op in the popover, then dismisses on success.
- **Sidebar context menu** — `SidebarOutline` is now an `NSOutlineView` subclass; the coordinator builds per-row menus with `Open in tab / Copy table to… / Export… / Import CSV…` and selects the right-clicked row first (Finder behaviour).

**Verified**: `swift build` ✓.

**Deferred**:
- True bidirectional `COPY ... TO STDOUT BINARY → COPY ... FROM STDIN BINARY` pipe (same blocker as iter-8 — PostgresNIO's high-level API doesn't expose `COPY TO STDOUT` yet).
- Upsert / `MERGE` strategy.
- Auto-create target table when it doesn't exist (column mapping currently assumes the target already matches).

### Iter 10 — State restoration (2026-05-25)
**Goal**: quit pgBrain, relaunch, find every window and tab where you left it — including unsaved SQL in scratchpads.

- **`SessionState`** — Codable model: per-window `connectionID`, `CodableRect` frame, `[Tab]` (kind / `(schema, name)` for tables / `title + text` for scratchpads), `selectedTabIndex`. Versioned (v1) for future migrations.
- **`SessionStateStore`** — singleton with `load()` (best-effort decode) and `scheduleSnapshot(delay:)` (debounced 0.5s write on a serial utility-QoS queue so a flurry of mutations writes once). Captures from `AppDelegate.windowManager.entries`.
- **`AppSettings`** — `@Observable` shim around `UserDefaults` with first-launch defaults. `restoreLastSession` is the iter-10 trigger; the rest (binary overrides, default row limit, verbose logging, editor font, Sparkle channel) are stubs that iter-11 Settings will bind to.
- **Launch flow** — `AppDelegate.applicationDidFinishLaunching` checks `restoreLastSession`, walks each saved window, looks up the connection from `ConnectionStore`, and re-opens it via the existing `openConnection(_:restoring:)` overload. Welcome is suppressed if any window was restored.
- **Tab replay** — `restoreTabs` waits for `service.schemaState` to become `.loaded`, then resolves persisted `(schema, name)` against the live schema (silently drops tables that no longer exist), replays scratchpads with their `text` intact, and re-selects the right tab.
- **Persist on change** — `WorkspaceState.openTable/openScratchpad/closeTab/move` and the window-close handler all call `scheduleSnapshot()`. Scratchpad text edits aren't captured per-keystroke (deferred to iter-11); the on-close snapshot still catches them on a clean quit.

**Verified**: `swift build` ✓.

**Deferred**:
- Per-keystroke scratchpad text persistence — current snapshot covers clean quits; iter-11 Settings can expose an "autosave every N seconds" toggle.
- Restoring per-window grid scroll positions or selection ranges — needs additional state piped from `RowsLoader` / `EditBuffer`.
- Restoring open scratchpad result blocks — they're transient by design; the SQL is what matters and that already round-trips.

---

## Next — Iter 11: Settings window

---

## Backlog (rough order)

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
