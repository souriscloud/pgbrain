# pgBrain

**Pro PostgreSQL for macOS.** Native. Mac-fast. No Electron. No subscriptions. No telemetry.

![macOS](https://img.shields.io/badge/macOS-15.0%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-success) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![Release](https://img.shields.io/github/v/release/souriscloud/pgbrain) ![License](https://img.shields.io/badge/license-AGPL--3.0-green)

> If JetBrains DataGrip and macOS had a kid that actually feels like a Mac app, you'd get pgBrain.

## Why

JetBrains tools are powerful but feel like a Java app glued to your menu bar. The Postgres GUIs that *do* feel Mac-native are either toy projects or stuck circa 2017. pgBrain is the missing middle — DataGrip-density workflows in a SwiftUI/AppKit shell that respects your trackpad, your dark mode, and your battery.

## What's in the box

- 🪟 **One window per connection.** Connection windows, multi-tab workspaces, JetBrains-style tab strip with drag-reorder.
- 🗂️ **Schema sidebar.** Tree of database → schemas → tables → columns. Trie-indexed filter that holds up on 10k+ tables.
- 📋 **Editable data grid.** Double-click any cell with a PK, type a new value, hit Apply — runs as a single transaction with server-side type casts. ⌘Z for one-step undo on pending edits.
- 📝 **Notebook scratchpad.** SQL and result widgets live inline in one flowing document. Cmd+⏎ runs the statement under your caret (or your selection) and inlines the result right after it. Green outline marks the running range. Re-running replaces in place; new contexts add new widgets. JetBrains feel, Jupyter ergonomics.
- 🛑 **Production guardrails.** Mark a connection as PROD → red chrome everywhere. Unscoped `DELETE`/`UPDATE`/`TRUNCATE`/DDL prompts before it runs.
- ⏯️ **Real cancellation.** Status footer shows in-flight operations. Cancel actually stops the server-side query via a sister-connection `pg_cancel_backend(pid)` — same trick `psql` uses on `^C`.
- ↔️ **Cross-DB copy.** Pipe a table from one connection to another via streaming `SELECT` → `COPY FROM STDIN`. Worst-case memory: one 64 KB buffer, regardless of row count.
- 📤📥 **Streaming export/import.** Full-table CSV/JSON/SQL export for any size table (memory stays flat). CSV import with header→column mapping. `pg_dump` wrapper that auto-discovers your binary.
- 🔁 **State restoration.** Quit, relaunch, find every window and tab right where you left it — scratchpad SQL included.
- 🎨 **Per-connection color tags + PROD flag** visible on every surface — sidebar, tab strip, status footer, menu bar window list.
- 📚 **Saved query library.** Snippets cross-cut all connections; search-as-you-type.
- 🪞 **Schema diff** between any two open connections.
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
