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

---

## Next — Iter 3: Sidebar + first table view

Smallest useful step on top of iter-2: when you open a connection, you see what's in the database and can browse a table's rows.

1. **Schema fetch** — query `pg_catalog` to enumerate databases, schemas, tables, views, columns on connect. Cached per `ConnectionService`.
2. **`SidebarOutlineView`** — `NSOutlineView` in an `NSViewRepresentable`, four-level tree: database → schema → table/view → column. Disclosure carets, icon per node type.
3. **Tab strip** — custom AppKit tab bar inside the connection window with closeable, reorderable tabs. One tab = one open table (or, later, scratchpad).
4. **Table tab content** — `NSTableView`-backed grid loading the first 1000 rows of a selected table, with column headers from the schema fetch. Async fetch with a spinner; null cells visibly distinct from empty strings.
5. **Type-aware cell renderers** — text / number / bool / timestamp / jsonb pretty-print read-only for now (editing lands in iter-5).

**Iter-3 done = user double-clicks a table in the sidebar and sees the first 1000 rows in a real grid.**

---

## Backlog (rough order)

### Iter 4 — SQL scratchpad with inline results ("Livebook")
- Code-editor view (CodeMirror via WKWebView, or Apple's `TextKit 2` with a Postgres tokenizer). Decide at iter start.
- Run-on-cursor / run-selection. Results render inline as collapsible blocks below the query, JetBrains-style.
- Multiple result blocks per scratchpad; history of past runs in a side panel.

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
