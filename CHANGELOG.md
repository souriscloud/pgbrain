# Changelog

All notable changes to pgBrain. Newest first. Dates are release dates.

pgBrain auto-updates via Sparkle, so most users land on the latest build
without downloading anything — this log is for the curious and the changelog
page on [apps.souris.cloud](https://apps.souris.cloud/apps/pgbrain).

## Unreleased

### Fixed
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
