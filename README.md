# pgBrain

**Pro PostgreSQL for macOS.** Native. Mac-fast. No Electron. No subscriptions. No telemetry.

![macOS](https://img.shields.io/badge/macOS-15.0%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-success) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![Release](https://img.shields.io/github/v/release/souriscloud/pgbrain) ![License](https://img.shields.io/badge/license-AGPL--3.0-green)

> If JetBrains DataGrip and macOS had a kid that actually feels like a Mac app, you'd get pgBrain.

## Why

JetBrains tools are powerful but feel like a Java app glued to your menu bar. The Postgres GUIs that *do* feel Mac-native are either toy projects or stuck circa 2017. pgBrain is the missing middle — DataGrip-density workflows in a SwiftUI/AppKit shell that respects your trackpad, your dark mode, and your battery.

## What's in the box

### Windows, tabs & navigation
- 🪟 **One window per connection.** Connection windows, multi-tab workspaces, JetBrains-style tab strip with drag-reorder, renameable + colour-taggable tabs.
- 🗂️ **Schema sidebar.** Tree of database → schemas → tables → columns → functions. Trie-indexed filter that holds up on 10k+ tables. Per-connection schema-visibility toggles.
- ⌨️ **Command palette (⌘K).** Fuzzy-ranked across connections, tabs, tables, functions, schemas, ERDs, and every action.
- 🧭 **IDE keyboard model.** ⌘T new scratchpad, ⌘1–9 tab jump, ⌃1–9 window jump, ⌘B sidebar, ⌘R reload, ⌘F find — the muscle memory you already have.
- 💾 **Saved workspaces + state restoration.** Snapshot a tab set, or just quit and relaunch to find every window and tab where you left it.

### Reading & editing data
- 📋 **Editable data grid.** Double-click any cell with a PK, edit, Apply — one transaction with server-side type casts. ⌘Z undo, type-aware editors (date pickers, bool toggles, JSON), per-column width memory.
- 📇 **Row form view.** Flip any grid to a single-row vertical form with ←/→ stepping — edits share the grid's dirty set.
- 🔎 **Filter, sort, paginate.** WHERE/ORDER BY strip with autocomplete, sortable headers, keyset-friendly paging, filter-to-cell, distinct-values popover per column, FK ⌘-click navigation.
- 📊 **Pivot & chart.** Pivot any result (row/col/value + agg) or chart it (bar/line/point) without leaving the result block.
- 🪄 **Generate test data.** Per-column strategies → one `INSERT … SELECT generate_series` with a live SQL preview.
- 🧮 **Column profiler.** Right-click any column → rows / nulls (with a populated bar) / distinct / min·max·avg, scoped to your active filter.
- 🗑️ **Delete rows.** Right-click one or a multi-selection → a primary-key-keyed `DELETE` behind a confirmation. Refuses tables without a PK.
- 📑 **Copy as…** Markdown, JSON, TSV (paste into spreadsheets), or CSV — from any result block or the table grid.

### The notebook scratchpad
- 📝 **Inline results.** SQL and result widgets in one flowing document. Cmd+⏎ runs the statement under your caret; the result inlines right after it. JetBrains feel, Jupyter ergonomics.
- 🐘 **psql slash commands.** `\dt`, `\d table`, `\df`, `\du`, `\l`, `\dn`, `\dx` … translated to catalog queries inline.
- 🔁 **Run-as-transaction.** Wrap a multi-statement run in BEGIN/COMMIT — any error rolls the whole batch back.
- ✨ **Editor niceties.** Syntax highlighting, schema-aware autocomplete + hover, bracket/quote auto-pairing, auto-indent, Format SQL, `EXPLAIN`/`EXPLAIN ANALYZE` plan viewer, find/replace, snippets with `$cursor$` placeholders, open/save `.sql`.
- 📜 **Query history + result diff.** Every statement logged with timing; diff the last two results side-by-side.

### DBA & schema management
- 🏗️ **Structure pane.** Columns, constraints, indexes, triggers (enable/disable/drop), partitions, comments editor — plus a Copy-ready `CREATE` script.
- ✏️ **Edit objects.** Function/procedure editor (`pg_get_functiondef` round-trip), view/matview editor, column ALTER (rename/type/drop/add), schema + database CRUD, sequence inspector (setval/nextval/restart).
- 🧹 **Maintenance.** VACUUM / ANALYZE / REINDEX / TRUNCATE / REFRESH MATERIALIZED VIEW from the sidebar, tracked in the ops popover.
- 🗺️ **ERD diagram.** Draggable table boxes, FK lines, double-click to open.
- 🔗 **Find usages.** Locate a table across every function body, view definition, and trigger.
- 🔐 **Roles & grants.** Browse `pg_roles`, view per-table grants, GRANT/REVOKE editor.
- 📈 **Live activity panels.** Sessions, locks, index usage, `pg_stat_statements`, size dashboard, replication (pubs/subs/slots), foreign tables/FDW.
- 📡 **LISTEN/NOTIFY console.** Subscribe to a channel, watch payloads stream in, send NOTIFYs back.

### Safety, transport & ops
- 🛑 **Production guardrails.** Mark a connection PROD → red chrome everywhere; unscoped `DELETE`/`UPDATE`/`TRUNCATE`/DDL prompts before it runs.
- 🔒 **SSH tunnels.** Per-connection local-forward via the system `ssh` (agent or key-file auth).
- ⏯️ **Real cancellation.** Cancel actually stops the server-side query via a sister-connection `pg_cancel_backend(pid)` — same trick `psql` uses on `^C`.
- ↔️ **Cross-DB copy.** Stream a table between connections via `SELECT` → `COPY FROM STDIN`. Flat memory regardless of row count.
- 📤📥 **Streaming export/import.** CSV/JSON/SQL export at any size; CSV/JSON import with header→column mapping; auto-discovering `pg_dump` wrapper.
- 🔔 **Long-query notifications.** Background queries over 30s ping you when they finish.
- ⚙️ **Sparkle auto-update.** Signed + notarized; updates land daily without a click.

## Download

[**→ Latest release (DMG)**](https://github.com/souriscloud/pgbrain/releases/latest)

1. Open the DMG, drag **pgBrain** onto **Applications**.
2. Launch pgBrain.
3. Add your first connection on the Welcome window.

> Signed with our Developer ID and notarized by Apple. Auto-updates via Sparkle so you only download once.

## Requires

- macOS 15 Sequoia or newer
- Apple Silicon Mac (arm64)

## Support the work

pgBrain is built by [Lukáš Novotný](https://bio.souris.cloud) at [Souris.CLOUD](https://apps.souris.cloud) — one human, no VC. If pgBrain saves you an hour, [buy me a coffee](https://ko-fi.com/souriscloud). ☕

## Build from source

```bash
git clone https://github.com/souriscloud/pgbrain.git
cd pgbrain
./scripts/run.sh                # debug build + bundle + launch
./scripts/bundle.sh release     # release build → build/pgBrain.app
```

Pure SwiftPM. No Xcode project — though you can open the package in Xcode if you want a graphical debugger. See [CLAUDE.md](CLAUDE.md) for full architecture, conventions, and dependency tree. See [PLAN.md](PLAN.md) for the iteration-by-iteration changelog.

## Releasing

See [RELEASE.md](RELEASE.md). One command (`./scripts/release.sh patch`) does bump → bundle → codesign → notarize → DMG → sign update → push → publish.

## License

AGPL-3.0. If you fork it, fork it loud.

## Links

- 🌐 [apps.souris.cloud/apps/pgbrain](https://apps.souris.cloud/apps/pgbrain)
- 🧑‍💻 [github.com/souriscloud/pgbrain](https://github.com/souriscloud/pgbrain)
- ☕ [ko-fi.com/souriscloud](https://ko-fi.com/souriscloud)
- 🐦 [bio.souris.cloud](https://bio.souris.cloud)
