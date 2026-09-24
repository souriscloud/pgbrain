# Changelog

All notable changes to pgBrain. Newest first. Dates are release dates.

pgBrain auto-updates via Sparkle, so most users land on the latest build
without downloading anything — this log is for the curious and the changelog
page on [apps.souris.cloud](https://apps.souris.cloud/apps/pgbrain).

## v0.10.0 — 2026-09-24

A full sweep: navigation rebuilt around how you actually move through a
database, a spreadsheet-grade grid, real scratchpad sessions, sturdier
connections, and a long list of fixes for bugs that could silently lose or
mangle data. Recommended for everyone.

### Welcome tour
- **A guided tour of the connection window** the first time you connect:
  nine short steps that spotlight the sidebar, schema picker, tabs and
  breadcrumbs, Go to Table, the grid, staged changes, scratchpads and the
  database switcher, with the shortcuts worth learning. Arrow keys to move,
  Esc to skip; Help ▸ Show Tour replays it any time.

### Navigation
- **The sidebar stays how you left it.** Expanded and collapsed schemas,
  selection and scroll position survive refreshes, tab switches and relaunch;
  refreshing dims the tree instead of blanking it. Column lists now fill in
  reliably, and empty schemas show up (a schema you just created appears).
- **Schema picker.** Focus on one schema, hide the rest ("Hide Schema", "Show
  Only This Schema"), with an "N hidden · Show all" footer. Databases with many
  schemas open with only `public` (or your search_path schema) expanded.
  PostGIS and other extension-owned objects are hidden by default; partitions
  nest under their parent table.
- **Fuzzy sidebar filter** (⌥⌘F): `pub.us` finds `public.users`; matches tables,
  views and functions (columns optional), shown in their real schemas.
- **Keyboard-first tree:** Return opens, Space previews, arrows expand and
  collapse, type to jump; ↓ from the filter goes to the results.
- **Go to Table (⌘O)** with recent tables first; ⌘K remains the everything
  palette.
- **Preview tabs:** a single click opens an italic preview tab that the next
  click replaces; double-click, Return, editing or filtering keeps it.
- **Tab management:** pin tabs, Close Others / to the Right / All, an overflow
  menu, middle-click to close, short titles (schema only when names collide).
- **Back / Forward (⌘[ / ⌘])** across tables, including foreign-key jumps —
  going back restores the previous filter.
- **Breadcrumb bar:** `database ▸ schema ▾ ▸ table ▾`, each part a menu of its
  siblings.
- **Pinned and Recent tables** at the top of the sidebar (⌘D pins).
- **Database switcher** in the title bar opens other databases on the same
  server in their own windows; creating a database offers to open it.
- ⌘T and "New Query in …" start a scratchpad in the selected schema.
- Tabs follow renamed tables; tabs for dropped tables are marked stale.

### Data grid
- **Spreadsheet-style editing:** click a cell, ⇧-click or ⇧-arrows to select a
  range, ⌘C / ⌘V copy and paste cells (TSV), Tab / Return to move, start typing
  to edit, ⌫ sets NULL, ⌘Z / ⌘⇧Z undo and redo.
- **Pending changes badge** with **Preview SQL**, Apply (⌘S) and Discard (⌘⎋).
- **Your staged edits are safe:** paging, sorting, filtering, refreshing,
  foreign-key jumps, closing a tab or window, and quitting now ask before
  throwing edits away; edits made while a refresh is running are kept, and
  renaming the table elsewhere keeps the tab and its edits.
- **Apply shows what the server stored** (normalised numbers, booleans, JSON)
  and refuses to overwrite a row someone else changed or deleted meanwhile.
- **Tables without a primary key can be edited**, with a clear warning.
- Pages are ordered by primary key by default, so rows don't jump between
  pages after an edit; sorting a numeric column by its header sorts
  numerically.
- **Paging moved to ⌃⌘← / ⌃⌘→** so ⌘⇧← / ⌘⇧→ select text again in the
  filter fields and extend the grid selection.
- ⌘-click follows multi-column foreign keys. The map view honours WHERE.
  Structure / DDL pane and grid / form / map mode are remembered per tab.
- CSV / JSON import asks for encoding, delimiter and header options.

### Scratchpad
- **Every PostgreSQL type shows exactly as psql shows it** — time, interval,
  arrays, inet, money, NaN / infinity, exact big numerics, your session's time
  zone, BC dates. `SELECT * FROM pg_class` no longer fails.
- **One server session per scratchpad:** `SET`, temp tables, `SET ROLE` and
  `BEGIN` carry over between runs.
- **Transaction indicator** with Commit / Roll Back, an Auto / Manual commit
  switch, and a prompt before closing a tab or window — or quitting — with an
  open transaction. If the server drops the connection mid-transaction, the
  next statement is refused with a clear message instead of silently running
  outside the transaction.
- Stop (⌘.) cancels exactly your statement; a double ⌘↩ no longer runs it
  twice. Server NOTICEs show under results.
- Explain is now ⌘⇧E (⌘E is "Use Selection for Find" again); keypad Enter
  runs; Open .sql… is ⌥⌘O.
- Function and view editors zoom with the rest and autocomplete.
- Result history is capped per cell, with a Clear results button.

### Connections
- **Automatic reconnect** after sleep or a network change; a dropped SSH
  tunnel restarts; the status bar shows the connection's health with a
  Reconnect button.
- **Custom root CA and client certificates**; verify-full now works through
  an SSH tunnel.
- **Per-connection read-only mode**, statement timeout and idle-in-transaction
  timeout; sessions show up as "pgBrain" in `pg_stat_activity`.
- **Paste a `postgres://` URL or `key=value` string** into the connection
  editor; import `~/.pg_service.conf`, fill passwords from `~/.pgpass`
  (Settings ▸ Connections).
- **pg_dump / pg_restore** find PostgreSQL 18 (Postgres.app, Homebrew, EDB),
  pick the version that matches your server, work through SSH tunnels, and
  can be cancelled. A failed dump no longer destroys an earlier dump at the
  same path; dump files are created private to your user.
- SSH tunnels are non-interactive, accept a new host key on first use, explain
  failures clearly, are shared between windows and stop when you quit.

### Fixed — could lose or corrupt data
- A data-modifying CTE (`WITH … INSERT`) or `SELECT … INTO` in the scratchpad
  was silently cut to 1,001 rows by the automatic LIMIT and skipped the
  production guard.
- CSV import crashed or swapped values between columns when the file's header
  order differed from the table's.
- Editing a timestamp could replace it with the current time or shift it by
  your time-zone offset; microseconds were dropped.
- After paging or re-sorting, the grid could keep showing the previous rows.
- The SQL formatter swallowed the line after a `--` comment.
- A WHERE filter ending in `-- comment` disabled paging and loaded the whole
  table.
- One unreadable entry could wipe the whole connection list; a failed Keychain
  write could lose a saved password.
- Stopping a query could cancel a different query running on the same server.
- An edit could update several rows when a child table repeated the parent's
  key; row edits now refuse to touch more than one row.
- Importing into a table could land in a same-named temporary table.
- Statement splitting and the safety check misread E'…' strings, Windows line
  endings after `--` comments, and `$1` parameters.
- CSV export wrote NULL and empty strings identically; JSON export could emit
  invalid NaN / Infinity; a failed export left a partial file.
- JSON import turned 0 / 1 into booleans and lost precision on big numbers.
- Cross-database copy: enum and domain columns, sequences after the copy,
  duplicate upsert keys, and SSH / TLS targets all work now; Upsert from the
  copy sheet no longer fails outright.
- Schema duplicate no longer rewrites look-alike names or text inside strings.

### Fixed — other
- ⌘C / ⌘Z in the WHERE field, find bar or SQL editor no longer act on the grid.
- The cell editor opens on the right cell while find is active.
- A column named `description` no longer shows a descending sort arrow.
- Closing a window while it was still connecting left an SSH process behind.
- The "unsaved changes" dot vanished when you switched tabs.
- A partitioned table's header showed "0 bytes"; it now shows the size of
  all its partitions.
- The empty-window hint now says ⌘T (not ⌘N) opens a scratchpad.
- Choosing the current database in the switcher no longer opens a duplicate
  window; cross-DB copy and schema diff target the right database window.
- ⇧ / ⌘ / ⌥⇧ with arrow keys in the SQL editor select text instead of jumping
  between cells.

### Security
- Saved passwords are readable only by pgBrain (the old "any app" Keychain
  access list is gone; items migrate on first use). Note: after updating,
  going back to 0.9.x means re-entering passwords.
- Query history masks password literals and can be turned off or cleared.
- The scratchpad's SCRAM login always verifies the server's signature.
- If the connection list can't be read safely, pgBrain refuses to overwrite it
  and says so on the Welcome window.
- Exported connection files are private (0600); copied connection strings with
  passwords are hidden from clipboard managers.
- pg_dump / pg_restore get the password via a private temporary file instead
  of the environment.

### Under the hood
- The Beta update channel was removed (it pointed at a feed that never
  existed); Settings ▸ Updates now has the automatic-check toggle.
- "Verbose Postgres logging" works (it was never wired up); logs go to the
  unified log under `cloud.souris.pgbrain`.
- PostgresNIO 1.33.1, Sparkle 2.10.0; the release build carries no hardened
  runtime exemptions.

## v0.9.7 — 2026-06-09

### Fixed
- The cell-edit popup now takes keyboard focus, so Tab and ⌘C act on the
  editor instead of the grid behind it.

## v0.9.6 — 2026-06-09

### Fixed
- **WHERE / ORDER BY filter** re-applies on every change. Before, switching one
  non-empty filter straight to another didn't re-run the query.
- **⌘C in the cell-edit popup** no longer copies the whole row.

## v0.9.5 — 2026-06-04

### Changed
- Font zoom applies consistently everywhere; accessibility labels on icon-only
  buttons; consistent button and label wording; Help lists every shortcut.
- pgBrain is now published under the AGPL-3.0 licence.

## v0.9.4 — 2026-06-04

### Added
- **`:var` query parameters** in the scratchpad — pgBrain asks for the values
  and remembers them while the window is open.
- **Restore Database…** (pg_restore) with clean / no-owner /
  single-transaction / parallel-jobs options.
- **Cross-database copy**: upsert mode (`ON CONFLICT … DO UPDATE / NOTHING`)
  and automatic creation of the target table.
- **Appearance** setting: System / Light / Dark.
- **Default schema per connection**, used by new scratchpads.
- Grid: ⌃⌘N sets a cell to NULL; hovering a long or JSON cell shows a preview.

### Fixed
- Saving edits to a row that someone else deleted or re-keyed now fails
  clearly and rolls back, instead of silently updating nothing.

## v0.9.3 — 2026-06-01

### Added
- **⌘+ / ⌘− / ⌘0 now zoom the whole window** — the data grid scales with the SQL
  editor, not just the scratchpad.
- **Schema duplication got thorough** — it now also copies **partitioning**
  (single-level), **triggers**, **row-level-security policies**, and optionally
  **ownership & grants** (best-effort, applied after the clone).
- **Typed column defaults** — setting a column default in the table designer or
  Add Column now offers the same typed editor (date/enum/now()/expression) as
  cell editing.

### Fixed
- The cell editor no longer closes when you click an autocomplete suggestion.

## v0.9.2 — 2026-06-01

### Added
- **Duplicate a whole schema.** Right-click a schema → Duplicate schema… (or ⌘K)
  to clone it into a new one, choosing exactly what to copy: table structure,
  data, sequences, foreign keys, views, materialized views, and functions.
- **Bulk import/export connections.** Export every connection to a JSON file or
  the clipboard (passwords opt-in) and import them back — from the Welcome
  window's Import/Export menu or the new **Settings ▸ Connections** tab.
  Duplicates are skipped on import.
- **Live font zoom.** ⌘+ / ⌘− / ⌘0 resize the SQL editor instantly across every
  open scratchpad.
- **⌘⌫ deletes rows.** Select rows and press ⌘⌫ to stage them for deletion
  (committed with the rest of your edits on Apply).
- **Searchable, comprehensive Help.** A search field and many more topics —
  editing, autocomplete, schema tools, import/export, and connection management.

### Changed
- Settings grew up: a Connections tab, a live font preview, and a real Updates
  tab with “Check for Updates Now” and version info.

## v0.9.1 — 2026-05-31

A big upgrade to how you enter and edit values, plus IDE-grade SQL completion.

### Added
- **One typed-input family across the app.** Every data-value field now adapts to
  the column's Postgres type: date/time pickers, a true/false segment, **enum
  dropdowns** (loaded from the database), numeric fields, and a JSON editor with
  **syntax highlighting**, prettify/minify, and a tree view. Each field has a mode
  menu for `NULL`, the column `DEFAULT`, `now()` / `gen_random_uuid()` shortcuts,
  or a raw **SQL expression** — so you can set a timestamp cell to `now()` and it
  writes as real SQL, not a quoted string. Live in the grid cell editor, the row
  form, the Run-a-Function dialog, and Generate Data.
- **IDE-grade completion popup.** A custom panel with an icon, name, and dimmed
  detail per row — **columns show their type, functions show their signature** —
  with keyboard navigation, fuzzy matching, and brand-tinted selection. Replaces
  the plain macOS list in the SQL scratchpad, the WHERE / ORDER BY strips, and the
  new expression fields.
- **Expression inputs are real SQL editors** — syntax highlighting plus
  schema-aware completion biased toward the row's own columns.

## v0.9.0 — 2026-05-31

Marks the scratchpad + command-palette work of the 0.8.x line as a minor
milestone.

### Changed
- **The scratchpad's "TX" toggle is now labelled "Atomic"** with a plainer
  tooltip — it wraps a multi-statement run in one transaction so any error rolls
  the whole batch back.

## v0.8.3 — 2026-05-31

### Added
- **Run gutter in the scratchpad.** Every SQL cell now has a left rail with a
  **▶ per statement** (runs just that statement, result inline) plus a thin
  outline of each statement's extent, and a **floating ▶** in the cell's
  top-right that runs the whole input. `⌘↩` now runs only the statement under
  the caret — or, with a selection, just the selected statements — never the
  whole cell.
- **Results stack instead of replacing.** Re-running a cell appends the new
  result block(s) below the previous ones (the older ones auto-collapse to
  headers), so a cell accumulates a history you can scroll. ✕ removes any block.
- **Pivot / Chart / Map are inline.** Each result block has a Grid · Pivot ·
  Chart · Map switcher that renders right in the block — no more modal sheets.
- **Save & reopen scratchpads.** Save a scratchpad to the library and reopen it
  later as a new tab (from the toolbar's **Saved** button or ⌘K).
- **A much richer command palette (⌘K).** Added: pgBrain Help, Send Feedback,
  New Table, Diff Schemas, pg_dump (per format); per-schema Rename / Drop /
  Hide-Show + Show-all; contextual front-table actions (Structure, CREATE SQL,
  Find Usages, Edit Comments, New Index, Generate Data, Truncate, Export
  CSV/JSON/SQL, Import CSV/JSON, VACUUM / ANALYZE / REINDEX); and Save / Open
  saved scratchpads.

### Fixed
- **Inline map ignored a scratchpad's custom search_path** and failed with
  "relation does not exist" when the scratchpad was scoped to a specific schema.
  The map now applies (and resets) that search_path on its fetch connection.
- **Creating a SQL-standard function in the scratchpad split mid-body.** A
  `CREATE FUNCTION … LANGUAGE sql BEGIN ATOMIC …; …; END` carries top-level
  semicolons inside its body; "run statement under caret" used to cut it at the
  first one and the server rejected the fragment. The statement splitter now
  treats a `BEGIN ATOMIC … END` body as one unit (balancing nested `CASE … END`,
  and still respecting strings / comments / dollar-quotes), so these functions
  run whole. Plain `BEGIN; … COMMIT;` transactions are unaffected.

## v0.8.2 — 2026-05-31

### Added
- **Function Designer — create *and* edit functions/procedures.** A unified
  editor: structured essentials (schema · name · arguments · returns · language ·
  volatility · strict · security definer) over a body editor, with a live
  `CREATE OR REPLACE` preview on the right. Editing loads the routine from the
  catalog; change the body and Save runs a plain `CREATE OR REPLACE`, change the
  signature (name, argument types, or return type) and it DROPs + recreates in
  **one transaction**. Functions that carry attributes the form doesn't model
  (`SET`, `LEAKPROOF`, custom `COST`/`ROWS`, parallel-safety, SQL-standard
  bodies) drop to a full-statement editor so nothing is ever silently lost.
  Reachable from a function's right-click menu, a schema/Functions group, the
  connection ⋯ menu, or ⌘K → "New function…".
- **Run a function from the UI.** Right-click a function → **Run** (or a
  procedure → **Call**), or ⌘K → "Run …": a form lists the input parameters, you
  fill values (blanks fall back to the function's own defaults via `name =>`
  notation), and it builds + runs the exact `SELECT * FROM fn(…)` / `CALL proc(…)`
  — shown live — rendering the result inline. No more hand-writing the call in a
  scratchpad.

### Fixed
- **The sidebar didn't refresh after creating an object in the scratchpad.**
  Running a `CREATE` / `DROP` / `ALTER` / `COMMENT` in a notebook (single-run or
  run-as-transaction) now reloads the schema on success, so a new function (or
  table, schema, …) shows up in the tree immediately instead of after a
  reconnect. Saving from the Function Designer refreshes it too.

## v0.8.1 — 2026-05-31

### Changed
- **Deleting rows is now staged, not instant.** Right-click a row (or selection)
  → "Delete row(s)" marks it with a red wash and a "N to delete" count instead of
  firing a `DELETE` immediately. It commits on **Apply** — in the *same
  transaction* as your pending edits and inserts — or vanishes on **Revert**.
  Right-click a staged row again to keep it. (Tables still need a primary key.)

### Added
- **Table Designer — edit an existing table's structure.** A roomy visual editor
  (column list on the left, live SQL on the right) for **both** creating tables
  and *restructuring existing ones*. Add / rename / retype / reorder-intent
  columns, toggle NOT NULL & primary key, set defaults and comments — the right
  pane shows the exact `ALTER TABLE` batch it'll run, and Apply commits it
  **atomically in one transaction**. New columns show a green "new" badge,
  changed ones an orange "modified" badge. Open it from a table's **Edit
  structure…** button (Data/Structure toolbar), or ⌘K → "Edit structure…". The
  old cramped New-table sheet is replaced by this designer.
- **In-app Help.** A real Help guide (Help → pgBrain Help, ⌘?, or the menu-bar
  dropdown): a topic sidebar — Welcome, Connecting, the Data Grid, SQL Notebook,
  PostGIS & Maps, DBA Toolkit, Keyboard Shortcuts, Support — with formatted
  content, shortcut chips, and quick links to feedback / GitHub / Ko-fi.
- **Switch table view from the Command Palette.** ⌘K now offers "View as Grid /
  Form / Map" for the front table tab ("Map" only when it has geometry), so you
  can flip the grid into the map (and back) without reaching for the toggle.
- **Send Feedback in more places.** The feedback form is now reachable from the
  top-level **Help** menu and the menu-bar dropdown, not just the connection ⋯
  menu.
- **Send Feedback.** A built-in feedback / bug-report form that opens a pre-filled
  GitHub issue — bug / feature / question, with optional app + system info. No
  account? "Copy report" puts the whole thing on the clipboard. Free, no token,
  your GitHub login.

### Fixed
- **Column profiler popover was parked at the bottom of the window**, nowhere
  near the column. It now presents as a popover anchored directly under the
  column's header, pointing at the column it profiles.
- **"Profile column" only worked from a cell right-click, not the column
  header.** Right-clicking a column header now opens a column menu (profile,
  distinct values, copy name, filter NULL / NOT NULL).
- **Map view hid the Grid/Form/Map toggle**, so once you switched a table to the
  map you couldn't switch back. The footer with the toggle now stays visible in
  map mode.

## v0.8.0 — 2026-05-30

### Fixed
- **Keychain re-prompted for the password on every window / launch.** Connection
  passwords were stored with a data-protection attribute the legacy keychain
  ignores, so items kept a "this exact binary only" ACL and re-prompted whenever
  the signature changed (every update). They now use an all-apps ACL; existing
  items migrate on their next read (one prompt, once), then stay silent.
- **Autocomplete could overwrite what you typed** — the popup preselected the
  top suggestion, which the native completer then committed on space/return (so
  typing `FROM ` could become a function name). It no longer preselects: a
  suggestion is only inserted when you explicitly pick it. It can never silently
  replace your text.
- **Scratchpad "Map" on a table with a text column like `kind`** ("point"/"polygon"
  values) mis-detected that as the geometry column and errored. Detection now
  requires real WKT (`POINT(`…), not the bare words.
- **Scratchpad showed control-char garbage for binary columns** (PostGIS
  geometry, `bytea`). Geometry now decodes to WKT; `bytea`/other binary shows hex.
- **Scratchpad showed empty cells for numbers/dates** (e.g. `SELECT count(*)` was
  blank). Ad-hoc query results are now decoded per type (int, numeric, bool, uuid,
  date, timestamp) instead of only as text.
- **Unbounded `SELECT` on a huge table could hang or crash.** Bare top-level
  SELECT/WITH/VALUES queries without a `LIMIT` now get one appended automatically
  (first 1,000 rows + a "more" indicator), so the server stops early instead of
  scanning the whole table. Add your own `LIMIT` to override.

### Added
- **PostGIS map view.** Any table with a geometry/geography column gets a **Map**
  toggle next to Grid/Form — it plots features on a real map (points as markers,
  linestrings as polylines, polygons as filled shapes), auto-fitting to the data.
  Scratchpad results with a geometry column get a **Map** button too.
- **Geometry as WKT in the scratchpad.** A built-in EWKB decoder turns raw
  geometry into `SRID=4326;POINT(…)` (matching `ST_AsEWKT`) — `SELECT *` over a
  PostGIS table now reads cleanly instead of showing hex.
- **PostGIS awareness.** Spatial databases are auto-detected (no setting needed) —
  a "PostGIS x.y" badge shows in the window header, and geometry/geography columns
  render as readable WKT (`ST_AsEWKT`) in the grid instead of opaque WKB hex.
- **JSON tree view.** The cell editor's JSON/JSONB view gains a Text / Tree
  toggle — Tree renders a collapsible, type-coloured tree of the value.
- **New index builder.** Right-click a table → "New index…": tick columns (in
  index order), choose UNIQUE + access method (btree/hash/gin/gist/brin/spgist),
  add an optional partial `WHERE`, with a live SQL preview and auto-suggested name.
- **New table builder.** Visual `CREATE TABLE`: pick a schema, name it, add column
  rows (name · type · NOT NULL · PK · default) with a type-preset menu and a live
  SQL preview. Reachable from the connection menu, or right-clicking a database or
  schema in the sidebar. Creates, then opens the new table.
- **Insert rows.** The table grid's **＋** button adds a blank draft row (green
  wash, ✦ gutter marker); fill its cells and **Apply** to `INSERT`. Only the
  columns you touch are sent, so identity sequences, defaults, and triggers fill
  the rest. Updates and inserts commit together in one transaction.
- **Live header vitals.** The sidebar header shows the server version and live
  database size + table count; the table toolbar shows the open table's on-disk
  size. Sizes refresh on load and animate as they change.
- **Custom window chrome bar.** The macOS title bar is now a single full-width
  bar that carries the connection's identity — red for production, the tag colour
  otherwise — with the traffic lights riding on it: name, PROD badge, server
  version, live db size + table count, and a connection-state pill. No more stock
  title bar with a name; the Window menu still shows "name — active tab".

## v0.7.0 — 2026-05-29

**Feedback you can see, data tools you reach for.**

### Added
- **Toast notifications.** Exports, imports, dumps, cross-DB copies, maintenance,
  and edits now flash a short success/failure bubble in the corner — no more
  opening the operations popover to find out whether something worked. Failures
  show the server's message; click any toast to dismiss it.
- **Column profiler.** Right-click any column → **Profile column…** for row count,
  non-null / null counts (with a populated-fraction bar), distinct count (with a
  "unique" callout), and min / max / avg. Respects the table's active filter.
- **Delete rows.** Right-click a row — or a multi-row selection — → **Delete rows…**.
  Builds a primary-key-keyed `DELETE` behind a confirmation, then reloads. Tables
  without a primary key are refused rather than risk a broad match.
- **Copy as…** Copy any result block or the visible table page to the clipboard as
  a **Markdown table**, **JSON**, **TSV** (pastes straight into a spreadsheet), or
  **CSV**.
- Result blocks now show a `rows · cols` badge.

### Changed
- Operation results report **how much** they moved: "Exported 12,480 rows",
  "Imported 3,001 rows", pg_dump shows the output file size.
- Tooltips on the row-form ◀/▶ steppers and the ERD zoom controls.

### Fixed
- Saving or opening a `.sql` file that failed used to do nothing silently — it now
  reports the error (and confirms a successful save).
- The column profiler revealed that Postgres has no `min(boolean)` aggregate;
  boolean and json/jsonb columns now skip min/max cleanly.

## v0.6.0 — 2026-05-29

DBA suite, ERD diagrams, row form view, view/matview editor, replication + FDW
tabs, TRUNCATE, generate-data, grant editor, partitions, SQL file open/save,
psql slash commands, run-as-transaction, pivot + charts. Plus a tolerant
connection decoder so older `connections.json` files survive upgrades.

## v0.5.x — 2026-05-29

Polish pass on the DBA rounds: browsable functions in the sidebar, palette
coverage for new object types, keyboard/consistency audit.

## v0.4.0 / v0.5.0 — 2026-05-28

Pro IDE rounds: structure pane, schema-aware autocomplete + hover, pagination,
maintenance actions, schema admin, sequences, diagnostics, snippets, triggers,
function editor, roles, database CRUD, column ALTER, find usages.

## v0.3.0 — 2026-05-28

Cell-stack notebook scratchpad, typed data grid, command palette (⌘K),
SSH tunnels, production guardrails.

## v0.0.1 – v0.2.x — 2026-05-20 → 2026-05-25

Foundations: native window-per-connection shell, PostgresNIO-backed connect,
Keychain passwords, editable grid, streaming export/import, pg_dump wrapper,
cross-DB copy, state restoration, Settings, Sparkle auto-update, and the signed
+ notarized DMG release pipeline.
