# Changelog

All notable changes to pgBrain. Newest first. Dates are release dates.

pgBrain auto-updates via Sparkle, so most users land on the latest build
without downloading anything — this log is for the curious and the changelog
page on [apps.souris.cloud](https://apps.souris.cloud/apps/pgbrain).

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
