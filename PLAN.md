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

### Iter 11 — Settings window (2026-05-25)
**Goal**: replace the iter-1 placeholder Settings scene with a real, useful preferences window driven by `AppSettings`.

- **`SettingsView`** — standard macOS `TabView` of `General / Editor / Binaries / Updates`. 520×360.
- **General** — toggles `restoreLastSession` (live binds to iter-10 launch flow), `Stepper` for `defaultRowLimit` (100-100k, step 100; wired into `RowsLoader.load`), `verbosePostgresLogging` stub.
- **Editor** — `editorFontSize` stepper (10-22pt) for the future scratchpad redo.
- **Binaries** — `pg_dump`, `pg_restore`, `psql` override paths with NSOpenPanel browse buttons. Each row runs `PgDumpCLI.locateBinary` in the background to show the auto-discovered path as a tooltip. Writes to the same `pgbrain.binaryOverride.*` keys iter-8 already reads.
- **Updates** — `sparkleChannel` segmented picker (`stable` / `beta`) — captured now so iter-12 first-update is one click.
- `AppSettings.defaultRowLimit` now drives `RowsLoader.load`, replacing the hardcoded 1000.

**Verified**: `swift build` ✓.

**Deferred**:
- Theme picker (system / light / dark) — gated on Sequoia tinting redesign; current single-violet brand survives both modes.
- Connection-level defaults (default SSL mode, default schema) — needs a separate "Connection defaults" section that defers to the per-connection editor.
- `verbosePostgresLogging` live re-routing — `pgbrainQuietLogger` is a `let`; flipping to live re-routing means turning it into a computed property + a logger swap. Add when first user hits a wire bug.

### Iter 12 — Sparkle + release pipeline (2026-05-25)
**Goal**: in-app auto-update via Sparkle, plus a one-command release script that handles version bump → build → sign → notarize → DMG → GitHub release.

- **Sparkle dependency** — `Sparkle 2.6+` added to `Package.swift`. SPM integration handles linking. (Non-sandboxed runtime keeps the framework story straightforward; we'd need extra XPC bundling for sandboxed builds.)
- **`UpdateController`** — `@MainActor` wrapper around `SPUStandardUpdaterController`. Initialised at app launch from `AppDelegate.applicationDidFinishLaunching`; `MenuBarController.onCheckUpdates` now routes through it. Implements `SPUUpdaterDelegate.feedURLString(for:)` so the iter-11 `AppSettings.sparkleChannel` flips between `appcast.xml` (stable) and `appcast-beta.xml` (beta) without restart.
- **Info.plist Sparkle keys** — `SUFeedURL` (apps.souris.cloud/pgbrain/appcast.xml), `SUPublicEDKey` placeholder (must be set to the production EdDSA public key before first release), `SUEnableAutomaticChecks`, `SUScheduledCheckInterval = 86400` (daily).
- **`scripts/bump.sh`** — semver bumper using `PlistBuddy`. Accepts `patch|minor|major|X.Y.Z`. Also increments `CFBundleVersion` (build number). Prints `<version> (build <n>)` to stdout for piping.
- **`scripts/release.sh`** — end-to-end pipeline. Idempotent until step 5 (notarise). Stages:
  1. `bump.sh`
  2. `bundle.sh release`
  3. `codesign --options runtime --timestamp --entitlements …` with `DEV_ID_APPLICATION_IDENTITY`
  4. `xcrun notarytool submit --keychain-profile $NOTARY_PROFILE --wait` + `stapler staple` (skippable via `--skip-notarize`)
  5. DMG build via `scripts/build-dmg.sh` (iter-13) with a `hdiutil` fallback
  6. `sign_update` for the EdDSA appcast signature (uses `SPARKLE_PRIVATE_KEY_PATH`)
  7. `gh release create` upload (skippable via `--skip-upload`)
- All credentials are env-driven; nothing is checked in.

**Verified**: `swift build` ✓, `./scripts/bundle.sh` ✓. Sparkle initialises at launch; auto-update activates once the first signed release lands on GitHub.

**Resolved (2026-05-27)**:
- `SUPublicEDKey` baked into `Info.plist` (`4uTQZEdMy3jrq7GANt1oiPJuTk1q5pKHJLf6xMjiWz8=`) — same EdDSA key Sparkle stores in the user's macOS Keychain via `generate_keys`. Shared with the other souris.cloud apps (VirtualMirror et al.) by design.
- `SUFeedURL` repointed at `https://raw.githubusercontent.com/souriscloud/pgbrain/main/appcast.xml`. No external hosting needed — GitHub's raw CDN serves the file directly from the repo's default branch.
- Empty `appcast.xml` committed at the repo root so the URL resolves immediately.
- `scripts/release.sh` rewritten end-to-end to match the VirtualMirror flow: bump → bundle → codesign → notarize → DMG → notarize DMG → `sign_update` → append `<item>` to `appcast.xml` via awk → commit + push → `gh release create`. Idempotent before notarize; `--skip-notarize` + `--skip-upload` flags for dry runs.
- `scripts/sparkle-tools.sh` locates the Sparkle CLI binaries from `.build/artifacts/sparkle/Sparkle/bin/` (SPM path, not DerivedData like the VM helper).
- `scripts/.env.example` documents the four env values the release script needs (`TEAM_ID`, `CODESIGN_IDENTITY`, `NOTARYTOOL_PROFILE`, `GITHUB_REPO`); real `.env` is gitignored.

**Still deferred** (won't affect first release):
- Sparkle's XPC bundling for a sandboxed build (we're hardened-runtime-only for now).
- Channel-aware appcast (`appcast-beta.xml`) — `UpdateController.feedURLString` already picks the right URL based on `AppSettings.sparkleChannel`; the beta file just doesn't exist yet.
- Delta updates (`BinaryDelta` is bundled with Sparkle but the release script doesn't invoke it yet).

### Iter 13 — Custom DMG background (2026-05-25)
**Goal**: ship the .dmg with branded chrome — gradient background, drag-to-Applications arrow, sized window.

- **`scripts/gen-dmg-background.swift`** — CoreGraphics-rendered PNG matching the Welcome/AppIcon brand gradient. Adds a "Drag pgBrain to Applications" headline + a centred drag-arrow between the two icon slots. 660×400 to line up with `create-dmg`'s window size.
- **`scripts/build-dmg.sh`** — wraps `create-dmg` when installed (`brew install create-dmg`) for the full branded layout (background, icon at 180,200, Applications drop-link at 480,200, 96pt icons). Falls back to `hdiutil` if not present so the build never fails for lack of a Homebrew formula.
- **Idempotent regeneration** — `build-dmg.sh` re-runs `gen-dmg-background.swift` whenever the generator is newer than the PNG, matching the AppIcon flow.
- **Release pipeline** — `release.sh` already calls `scripts/build-dmg.sh` when present; iter-13 fulfils that contract.

**Verified**: `swift scripts/gen-dmg-background.swift Resources/dmg-background.png` ✓ (266KB PNG written).

**Deferred**:
- `.DS_Store` icon arrangement baked-in via `create-dmg`'s defaults — fine for now; revisit if QA wants pixel-perfect placement.
- Light/dark adaptive background — `.dmg` window doesn't honor system appearance, so one fixed image is the right answer.

### Iter 14 — Polish: saved queries + schema diff + i18n scaffold (2026-05-25)
**Goal**: three high-leverage polish features without touching the scratchpad (gated on its imminent redo).

- **Saved query library**:
  - `SavedQuery` value type (`id`, `name`, `notes`, `sql`, timestamps) + `SavedQueryStore` `@Observable` singleton persisting to `~/Library/Application Support/pgBrain/saved-queries.json`.
  - `SavedQueriesView` sheet: search-as-you-type, per-row Insert/Edit/Delete, "Save current scratchpad" captures the editor body into a new entry. Reached from a new books icon in the scratchpad header.
- **Schema diff**:
  - `SchemaDiff.diff(left:right:)` — pure value-type computation over `SchemaSnapshot`s. Returns added/removed/changed tables; per-changed-table reports added/removed/type-changed columns.
  - `SchemaDiffView` sheet: pick another *currently-open* connection (`WindowManager.service(for:)` is the discovery surface), compare on demand, scrolling diff with green/red/orange categorisation. Reached from the sidebar header's "ellipsis.circle" menu.
- **i18n scaffold**:
  - `Localizable.xcstrings` with English + Czech for menu, welcome, and common-button strings; resource pipeline wired into `Package.swift` (`resources: [.process("Resources")]`).
  - `L10n` enum centralises lookups (`L10n.Menu.about`, `L10n.Welcome.title`, …) so adding a key is one accessor + one `.xcstrings` entry. New strings should reach for `L10n.*` from now on.

**Verified**: `swift build` ✓.

**Deferred** (intentional):
- Quick-look-style hover preview of a wide/json/text cell — needs an `NSPopover` on hover delay; revisit after the grid sees real use.
- Per-connection `:var` substitution in scratchpads — gated on the upcoming scratchpad redo so we don't double-build it.
- Czech translations for the *other* ~200 strings still in source — iter-14 ships the *pattern*; bulk migration happens once we know which strings are stable.

### Open Q — Sidebar perf at 10k+ tables (2026-05-25)
**Goal**: search-as-you-type filtering that holds up on schemas the size of an EnterpriseDB extract.

- **`SchemaIndex`** — substring trie over every `qualifiedName.lowercased()`. ~200k inserts for a 10k-table schema (~20ms on M-series). `matches(_:)` walks the trie in O(needle length) + match count and returns a sorted `[TableNode]`.
- **`SidebarOutlineView`** — new `filterTerm: String` parameter. When non-empty, the coordinator rebuilds a synthetic root labelled `matches (N)` containing only matching tables grouped by their source schema; when empty, the full outline returns.
- **`ConnectionWindowContent`** — magnifying-glass `TextField` ("Filter tables") above the sidebar header with an `xmark.circle.fill` clear button.
- **Cheap reload heuristic** — `snapshotMatchesIndex` compares total-table counts so the `SidebarNode` + `SchemaIndex` rebuild only fires when the schema actually changes; filter keystrokes only rebuild the filtered subtree.
- `NSOutlineView` was already row-virtualised, so raw display perf was never the bottleneck; the trie-backed filter is what unlocks 10k+ in practice.

### Iter 15 — Notebook scratchpad rebuild (2026-05-25)
**Goal**: SQL and result widgets live inline in one flowing document, JetBrains-style green outline around the running range. Replaces the iter-4 stack-of-results model the user explicitly flagged as wrong.

- **`Notebook`** — replaces `Scratchpad`. Owns a single `NSTextStorage`; an `[UUID: NotebookResult]` dict carries result data out-of-band so the storage only holds a single attachment character per result. `startResult(id:statement:)` either resets an existing entry (replace-in-place) or creates a new one.
- **`NotebookResult`** — `@Observable` per-block status (`running / success / failure / cancelled`), `statement`, timestamps, `isCollapsed`. Mutable in place so SwiftUI binds re-render on status flips without dict churn.
- **`ResultAttachment` + `ResultAttachmentViewProvider`** — `NSTextAttachment` subclass keyed by result UUID; view provider hosts a SwiftUI `InlineResultView` (status glyph, preview, elapsed, collapse, remove, and either `DataGridView` or a one-line command tag). Provider is `nonisolated final class … @unchecked Sendable` and bridges into `MainActor.assumeIsolated` via a small `ProviderBox` wrapper, since AppKit's `loadView` signature can't be marked `@MainActor`.
- **`NotebookTextView`** — `NSTextView` subclass. Cmd+⏎ resolves the run target (selection wins over statement-under-caret via `SQLStatementSplitter`). Multi-statement selections split into N targets, each kicking off a separate run and inserting/replacing N attachments in document order. The **green run outline** is drawn in `draw(_:)` by querying the layout manager for the glyph bounds of `notebook.runningRange` and stroking a rounded rectangle with a faint green fill (cleared as soon as the batch finishes).
- **Replace-or-insert** — `reuseOrInsertAttachment(at:)` walks past whitespace at the run-end cursor; if the next non-whitespace character is our attachment, it reuses its ID (result is replaced in place). Otherwise inserts a fresh attachment on its own line with leading/trailing newlines so users can keep typing. Multi-statement selections cascade the cursor past each attachment so a re-run with the same selection replaces all N widgets in order.
- **Production confirmation + ops popover** — reuses iter-6's `SQLSafety` and iter-7's `OperationsCenter` unchanged.
- **`SavedQueriesView`** — now binds to `Notebook`; "Insert" overwrites `textStorage` with the chosen SQL.
- **`SessionState`** — persists notebook text only (results are transient by user request); restore creates a `Notebook` and seeds its `textStorage` with the saved text.
- **`WorkspaceState.TabKind.scratchpad`** now holds a `Notebook` instead of the old `Scratchpad`. The tab name stays `.scratchpad` so existing session files keep restoring without migration.
- Old `Scratchpad.swift` and `ScratchpadView.swift` deleted.

**Verified**: `swift build` ✓, `./scripts/bundle.sh` ✓.

**Deferred** (intentional):
- Live height-tracking for attachment widgets — fixed 260pt is the current attachment bounds; `DataGridView` itself caps at 320 so tall results just scroll. Add a layout pass when first user complains.
- `:var` substitution — was deferred from iter-14; can now slot in cleanly since the notebook owns the text storage.
- Syntax highlighting — still a separate decision (TextKit 2 lexer vs. CodeMirror); now unblocked because the editor is a single `NSTextView`.

### Iter 16 — Cell-stack notebook + typed grid + Cmd+K (2026-05-28)
**Goal**: usable notebook + usable editable grid + a real command palette. The iter-15 TextKit-attachment design failed in practice (`NSTextAttachmentViewProvider` never rendered widgets correctly), and the iter-3 grid couldn't actually edit anything.

- **Notebook rewrite — cell-stack architecture**. `NSTextAttachment` is gone. `Notebook` is now `[NotebookCell]` (SQL cell or result cell) plus an out-of-band `[UUID: NotebookResult]` map. SwiftUI eager `VStack` (LazyVStack collapses off-screen focus targets) with a `ScrollViewReader` for auto-scroll. `SqlCellNSTextView` intercepts Cmd+⏎ (run), ⌥↑/⌥↓ (unconditional jump), and plain ↑/↓ at line boundaries (jump to neighbor cell). Multi-statement runs auto-collapse their results so you get a scannable header stack. Replace-in-place via `reuseOrInsertAttachment` pattern preserves the iter-15 UX without the attachment headaches. Deleted: `ResultAttachment.swift`.
- **Notebook search_path picker**. Per-scratchpad chip in the header (`default`/`schema_name`). Selecting one runs `SET search_path TO "name"` on the checked-out pool connection before each statement and `RESET search_path` after, so the pool stays clean. Lets `SELECT * FROM users` resolve in any schema. Persisted in `SessionState.scratchpadSearchPath`.
- **Typed data grid**. Modernised look (6pt horizontal intercell spacing, horizontal-only grid lines, 36pt headers). `TypedHeaderCell` uses `attributedStringValue` (custom Swift props don't survive `NSCell.copy(with:)`). `CellFormat` renders type-aware: NULL italic-tertiary, bool ✓/·, integer/number right-aligned with grouping, date parsed `yyyy-MM-dd`, timestamp parsed `yyyy-MM-dd HH:mm:ss`, json single-line dimmed-braces, uuid half-tone monospaced, bytes `〈N bytes〉` placeholder.
- **Typed cell editor popover**. NSPopover-based, kind-driven: bool → segmented picker, date → `DatePicker(.date)`, timestamp → `DatePicker([.date, .hourAndMinute])`, json → multiline monospaced editor (480×360), numeric → right-aligned monospaced field, default → plain field. "Set NULL" button (⌘⇧0) when the column is nullable. Inline editing removed; popover is the only edit path.
- **Apply UX**. Dirty cells get a yellow left rail + tint, applied cells flash a green left rail + tint for 3.5s. `effectiveValue` now correctly returns the pending value (including `nil` for Set-NULL) before commit so changes show immediately, not only after Apply — the previous double-optional `flatMap` collapsed Set-NULL back to the server value. Commit explicitly reloads the affected row so same-key re-edits land instantly without waiting on SwiftUI's observation debounce. `EditBuffer.clearCell` drops no-op edits.
- **`PostgresErrorMessage`**. Unwraps `PostgresTransactionError` (closureError → beginError → commitError → rollbackError) and `PSQLError.serverInfo` into `Transaction rolled back — duplicate key value violates unique constraint "x" [23505]\n\nDetail: …`. Replaces the unreadable `PostgresNIO.PostgresTransactionError error 1.`. Wired into both the grid's Apply path (with a Copy-able popover) and the notebook's result widget.
- **`UpdateApplier` type-cast quoting bug**. `format_type()` returns canonical PG syntax (`bigint`, `timestamp with time zone`, `character varying(255)`); wrapping in `SQLIdent.quote` made PG search for a case-sensitive user-defined type named `"bigint"` (`type "bigint" does not exist [42704]`). Casts now emit unquoted.
- **Cmd+K command palette**. Floating `NSPanel` (vibrant blur, 14pt corners, brand-violet selection ring) centered over the frontmost window. Categories: actions, saved connections, open tabs, tables (every `schema.table`), schemas (set search_path on the active scratchpad), running operations (cancel). Fuzzy matcher: subsequence + prefix bonus + word-boundary bonus + contiguity bonus, with **needle-trimming fallback** so over-typed queries like `connections` still match `New Connection…` (peels trailing chars until ≥60% of the needle still matches; per-char penalty so exact matches win). Matched chars highlighted violet-bold via `AttributedString`. `↑/↓ ⏎ ⎋ ⌘K` keymap via `NSEvent.addLocalMonitorForEvents`; first-responder forced onto the host's NSTextField after present (SwiftUI's `@FocusState` wasn't reliably engaging on first show under `.nonactivatingPanel`). Re-asserted on every selection change so arrow-nav doesn't kill typing.
- **Renameable scratchpad tabs**. Double-click any scratchpad tab (or right-click → Rename Tab…) opens an inline `TextField`; Enter commits to both `Tab.title` and the underlying `Notebook.title` (so saved-queries, ⌘K, and session restore see the new name). Table tabs intentionally aren't renameable — their names come from the schema. `WorkspaceState.Tab` is now `@Observable` so per-tab title mutations trigger SwiftUI re-renders.
- **Sparkle URL + startup check fix**. `feedURLString(for:)` was pointing at `apps.souris.cloud/pgbrain/appcast.xml` (404 — that host doesn't serve the appcast), silently failing every check. Now points at the actual published feed (`raw.githubusercontent.com/souriscloud/pgbrain/main/appcast.xml`, beta = `appcast-beta.xml`). Added `checkForUpdatesInBackground()` on launch so updates land on next open instead of only after the 24h scheduled timer.
- **Connection editor polish**. Host/Port no longer fight for space (Port had been invisible); host:port pasted into Host auto-splits. Pre-flight probe via raw `PostgresConnection.connect()` surfaces real PSQLError immediately (PostgresClient pool was silently retrying auth failures). 15s hard timeout with friendly message. `friendlyMessage` extracts server-side error from `PSQLError.serverInfo`. TLS mapping now matches libpq semantics: prefer/require → `.certificateVerification = .none`, verify-ca → `.noHostnameVerification`, verify-full → `.fullVerification`.

**Verified**: `swift build` ✓, `./scripts/bundle.sh` ✓, Sparkle `SULastCheckTime` updates on launch confirming the background check fires.

### Iter 17 — IDE polish: structure, intellisense, pagination, keyboard, polish pass (2026-05-28)
**Goal**: close the gap with JetBrains DataGrip in the day-to-day. Structure + DDL panes, schema-aware autocomplete + hover, real WHERE/ORDER BY strip, sortable headers, ⌘K command palette, tab caching + pagination, IDE-style keyboard everywhere, palette-driven rename / colour / paste-import.

- **Structure + DDL panes per table** — `TableInspector` (one-pass async load of columns / constraints / indexes / comments via `pg_get_constraintdef`, `pg_get_indexdef`, `pg_get_viewdef`). New `Data | Structure | DDL` segmented picker on every table tab. Structure pane uses SwiftUI `Grid` for content-aware column sizing; constraint + index rows render as cards with selectable, wrapping definitions. DDL pane runs the bundled `SQLHighlighter` over the rendered CREATE script + a Copy SQL button.
- **JetBrains-style WHERE / ORDER BY strip** — single full-width row pinned above every grid. Blue `WHERE` and violet `ORDER BY` chips with prepended keywords; user types just the body. Enter commits + reloads. Bad clauses surface their server-side error in a red banner *above the still-mounted previous page* (no more "everything disappears on a typo"). Strip + grid both stay visible during cold errors too. Header click cycles sort and writes into the ORDER BY field.
- **Pagination** — `RowsFetcher.page(offset:pageSize:…)` does proper `LIMIT N+1 OFFSET M`. Default page size dropped from 1000 → 200 (wide tables were 20s+). New bottom pager strip: `pageSize/page` dropdown (50/100/200/500/1000/5000), `Rows X–Y[+]` range, « ‹ › arrows with ⌘⇧← / ⌘⇧→ shortcuts. Offset auto-resets on filter / sort changes.
- **Tab caching** — loaders + inspectors cached on `ConnectionService` keyed by `tab.id`. Switching away from a tab and back doesn't re-fetch; ⌘R (rebound) and the refresh button are the explicit reload paths. Cache pruned automatically on tab close via a new `WorkspaceState.onTabClosed` hook.
- **⌘K command palette** — floating `NSPanel` (vibrant blur, 14pt corners) with fuzzy-ranked search across saved connections, open tabs, schema-visible tables, schemas (set search_path on the active scratchpad), running operations (cancel), and active-tab actions (Rename Tab…, Color Tab…). Needle-trimming fallback so overtyped queries like `connections` still match `New Connection…`. ⌘K toggles; ⌃Space removed (was eating the macOS input-source switcher).
- **Modern data grid** — row-number gutter (subtle separator-tinted band) · row hover tint · keyboard-navigable cell focus ring (arrows / Enter to edit) · truncated-cell tooltip on hover · sortable headers with cycling ↑/↓ glyph · per-row right-click menu (Copy as INSERT / DELETE / Duplicate row, type-aware SQL literal quoting) · ⌘C → TSV of selected rows · ⌘F → yellow find-in-grid bar · `selectionHighlightStyle = .regular` restored after `.none` silently killed double-click on macOS 15; soft accent wash painted via `HoverableRowView.drawSelection`.
- **SQL highlighting + intellisense** — `SQLHighlighter` (NSTextStorage delegate, also exposed as `attributedString(for:)` for the DDL pane). `SQLTokenizer` + `SQLScope` inline Postgres-dialect tokenizer + scope analyzer that tracks `FROM users u`-style aliases. Schema-aware completion provider routes through `SQLScope.analyze` so `alias.|` shows that alias's columns, `schema.|` shows that schema's tables/functions, `SELECT * FROM users WHERE em|` ranks `email` from `users` over duplicates. Database functions / procedures / aggregates / window functions fetched from `pg_proc` and surfaced both in completions and hover.
- **Hover-to-identify** — mouse over an identifier in a scratchpad cell → tooltip resolves it via `SQLHoverResolver` (`schema · N tables` / `schema.table · N columns · PK …` / `schema.table.col  type [NOT NULL]` for column overloads / `schema.fn(args) → ret [fn|procedure|aggregate|window]`).
- **As-you-type completion** properly debounced — 180ms gate, fires only on forward typing of word chars when prefix ≥ 2, cancelled by whitespace / backspace / punctuation. Provider returns `[]` inside string literals + comments. Esc (native NSTextView) + ⌥Esc trigger manually.
- **Schema visibility filter** — sidebar's `…` menu has a Schemas submenu with per-schema checkmarks. Hidden schemas drop out of the sidebar tree, command palette, and completions uniformly via `ConnectionService.visibleSchema`. Per-connection, persisted via `SchemaVisibility` (UserDefaults).
- **Renameable + colourable tabs** — double-click or right-click "Rename Tab…" inline-edits any tab's title (table tabs too — title is independent of `TableNode.name`). Palette-driven via `tab.requestedRename`. Colour picker is a SwiftUI popover anchored to the chip itself with 9 colour swatches + clear; keyboard-controlled (←/→ between, ⏎/Space pick, ⎋ cancel) with brand-violet focus ring + checkmark on the active selection. Both rename and colour now correctly trigger `SessionStateStore.scheduleSnapshot()` so changes survive relaunch; `SessionState.Tab.tabTitle` carries custom titles for both kinds.
- **Connection exchange** — right-click any saved connection → Copy as → Laravel `.env`, Laravel Vault JSON, Connection URL, or pgBrain Exchange JSON (tagged with `"pgbrain.connection": "v1"`). Each format has a `— include password` variant. ⌘V on the Welcome screen pastes a pgBrain Exchange payload straight into a new-connection sheet pre-filled. ⌘⇧V inside the editor's Paste button does the same from inside the form.
- **Cell editor JSON UX** — opens prettified, saves compacted. `Prettify` / `Minify` buttons + a live `✓ Valid` / `⚠ Invalid` chip. Invalid JSON falls through to raw save so server errors surface.
- **Modern keyboard model** (per-window, scoped via hidden buttons in `ConnectionWindowContent.keyboardShortcuts`):
  - ⌘W close tab (cascades to window when empty) · ⌘⇧W force-close window · ⌘T new scratchpad · ⌘N unblocked back to "New Connection" (tab-strip `+` dropped its ⌘N override) · ⌘B toggle sidebar
  - ⌘1…⌘8 jump to tab N · ⌘9 last tab · ⌃1…⌃9 switch *between connection windows* via `AppDelegate.focusConnectionWindow(at:)` · ⌘⌥← / ⌘⌥→ · ⌘⇧[ / ⌘⇧] · ⌃Tab / ⌃⇧Tab all switch tabs
  - ⌘F find-in-grid · ⌘R reload active tab · ⌘⇧R reload schema · ⌘K palette · ⌘, settings
- **Session restore** — `tabTitle`, `colorTag`, `tableWhereClause`, `tableOrderByClause`, `scratchpadSearchPath` all persisted per-tab. Restore loop fixed: was waiting `while case .loading`, fell through immediately when state was `.idle`. Now waits for terminal state with a 30s cap.
- **Sparkle URL fix** — was pointing at `apps.souris.cloud/pgbrain/appcast.xml` (404), silently failing every check. Now points at the real published feed (`raw.githubusercontent.com/souriscloud/pgbrain/main/appcast.xml`). Added `checkForUpdatesInBackground()` on launch so updates land on next open instead of waiting for the 24h scheduled timer.
- **`UpdateApplier` type-cast quoting** — `format_type()` returns canonical PG syntax (`bigint`, `timestamp with time zone`); wrapping in `SQLIdent.quote` triggered `type "bigint" does not exist [42704]`. Casts now emit unquoted.
- **`PostgresErrorMessage`** — unwraps `PostgresTransactionError` (closure → begin → commit → rollback) and `PSQLError.serverInfo` into readable `Transaction rolled back — duplicate key value violates unique constraint … [23505]` strings. Wired into both the grid's Apply path and the notebook's result widget.
- **`TypedHeaderCell` reverts to zero Swift stored fields** (re-introduced via sort-glyph work, crashed on `NSCell.copy(with:)` again). All state baked into `attributedStringValue`; sort-direction changes replace the whole cell.

**Verified**: `swift build` ✓, `./scripts/bundle.sh` ✓, ad-hoc grid + scratchpad + palette + colour-picker + connection-paste flows tested live.

### Open Q — commandTag for non-SELECT (2026-05-25)
**Goal**: scratchpad result block shows "UPDATE 12" / "INSERT 0 5" / "DELETE 3" instead of "OK".

- `QueryRunner.runOnConnection` now uses `SQLSafety.classify` to split the path:
  - `readOnly` → streaming `PostgresRowSequence` (unchanged); synthetic `SELECT N` tag from materialised row count.
  - everything else → `PostgresConnection.query(...).get()` (materialised `EventLoopFuture` path), reads `PostgresQueryMetadata` for the real libpq tag.
- `formatCommandTag` reconstructs `INSERT oid rows` / `<CMD> rows` / `<CMD>` from the parsed metadata.
- Streaming SELECTs are untouched — no memory regression at large row counts. The materialised path is only taken for statements that typically return 0–few rows.

---

## Open questions for later
- **SQL syntax highlighting**: shipped iter-4 with a plain `NSTextView` (no highlighting). Held until the scratchpad redo so we don't double-build.
- **`COPY ... TO STDOUT` (binary)**: PostgresNIO doesn't expose `COPY TO STDOUT` through the high-level API yet, so iter-8/iter-9 use `SELECT … ::text`. Drop to the raw channel when first user hits row-stream throughput limits.
- **Scratchpad redo (next major area of work)**: per user — current `ScratchpadView` isn't the right model. Hold polish like `:var` substitution and per-keystroke autosave until the redo lands.
