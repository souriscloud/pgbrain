# CLAUDE.md — pgBrain architecture & conventions

This file is read at the start of every Claude Code session in this repo. Keep it as the **current state** of the project, not a changelog. Use `PLAN.md` for "now / backlog", `CHANGELOG.md` for user-facing history, and commit history for the diff record.

## Product in one line
Native macOS PostgreSQL GUI that copies JetBrains DataGrip's professional flow (windows per connection, tabs, data grids, SQL scratchpad) while feeling Mac-native (SwiftUI chrome, AppKit grids, system menu/dock/window decorations).

## Sibling docs
- **PLAN.md** — what's in flight, backlog, open questions.
- **CHANGELOG.md** — user-facing release notes. `scripts/release.sh` refuses to release without a `## vX.Y.Z` section and publishes it as the GitHub release notes.
- **RELEASE.md** — release runbook. Read before running `scripts/release.sh`.
- **docs/history/** — archived iteration log (v0.0.1 → v0.9.7).

## Foundational decisions
| | |
|---|---|
| Display name | **pgBrain** |
| Bundle identifier | `cloud.souris.pgbrain` |
| Min macOS | **15.0 Sequoia** |
| Build host | Xcode 26.x / Swift 6.3 (Swift 6 language mode, strict concurrency) |
| UI framework | SwiftUI for chrome (Welcome, Settings, sheets, menus, tab strip, breadcrumb). AppKit (`NSOutlineView` / `NSTableView`) for the sidebar tree and the data grid. |
| Postgres driver | **PostgresNIO** for everything pooled. The scratchpad uses its own small wire client (see *Data access*). |
| Build system | **SwiftPM** — `Package.swift` + committed `Package.resolved`. `scripts/bundle.sh` wraps the executable into a `.app`. No `.xcodeproj`, no XcodeGen, no Tuist. |
| Sandbox | Not sandboxed. Hardened runtime with **no** entitlement exemptions in release. |
| Distribution | DMG + Developer ID + notarization; auto-update via **Sparkle** from `appcast.xml` on `main` and GitHub Releases. Single (stable) channel. |
| CI | **None**, deliberately (free GitHub account; macOS minutes are limited). The `swift test` gate in `release.sh` is the only automated check. |

## Repo layout
```
Sources/pgBrain/
├── App/            @main app, AppDelegate (windows, restore, quit guard), Log (os.Logger
│                   categories + swift-log bridge), UpdateController (Sparkle), tokens
├── Windows/        NSWindow factories (Welcome, Connection, About, Help, Feedback)
├── Views/          SwiftUI views: ConnectionWindowContent (window shell, chrome bar,
│   │               status footer), editors/sheets/panels, Settings, Help
│   ├── Sidebar/    SidebarOutline — the NSOutlineView schema tree
│   ├── Navigation/ schema picker, database switcher, breadcrumb bar, TabCloseGuard
│   ├── Tabs/       TabStripView, TableTabView (+Data, +Actions), NotebookView,
│   │   │           SqlCellNSTextView, pending-changes preview, import options
│   │   ├── Grid/   data grid: coordinator, EditableTableView, cells, header, menus
│   │   └── Inspector/  Structure / DDL panes
│   └── TypedInput/ typed value editors (dates via PGTemporal, JSON, SQL expressions)
├── State/          @Observable per-window state: WorkspaceState (tabs, preview/pinned,
│                   back/forward), RowsLoader, EditBuffer, GridSelection, DirtyGuard,
│                   Notebook, OperationsCenter, toasts, WindowManager
├── Services/       ConnectionService (pool, health/reconnect, shared TLS/endpoint
│                   helpers), SSHTunnelManager (ref-counted ssh -L tunnels)
├── Schema/         catalog fetch + model, SchemaIndex (sidebar filter), RowsFetcher,
│                   TableInspector, ForeignKeyResolver, SQLIdent
├── Query/          QueryRunner, SQLSafety, statement splitter, UpdateApplier, admin
│   │               actions, fetchers, ScratchpadSession, NotebookRunner
│   └── Wire/       minimal PG wire client (simple-query protocol, text results)
├── Notebook/       SQL lexer (SQLTokenizer), highlighter, formatter, completion
├── IO/             Importer, Exporter, CrossDBCopy, PgDumpCLI, clipboard
├── Models/         Connection, conninfo/pgpass/pg_service parsing, import/export
├── Persistence/    JSON stores in ~/Library/Application Support/pgBrain, Keychain,
│                   AppSettings (UserDefaults), SessionState, AppTermination
├── CommandPalette/ ⌘K / ⌘O palette
├── Menu/           NSStatusItem menu
├── Feedback/       GitHub issue link builder
└── Showcase/       DEBUG-only screenshot harness (PGBRAIN_SHOWCASE): scenes, off-screen
                    renderer, map snapshots — compiled out of release builds
Tests/pgBrainTests/ XCTest; pure tests + live-DB E2E (see Testing)
Resources/          .app bundle resources: Info.plist, entitlements (release + dev),
                    AppIcon.icns (generated), dmg-background.png
scripts/            bundle.sh, run.sh, clean.sh, release.sh, bump.sh, build-dmg.sh,
                    sparkle-tools.sh, gen-icon.swift, gen-dmg-background.swift, .env.example,
                    screenshots.sh + showcase/ (seed.sql, frame.swift)
docs/screenshots/   generated marketing screenshots (scripts/screenshots.sh)
appcast.xml         Sparkle feed (release.sh prepends items, keeps the newest 10)
```
There is no SwiftPM resource bundle (`Bundle.module`): `bundle.sh` doesn't embed one, so don't add `resources:` to the target without also embedding it.

## Build & run
```bash
./scripts/bundle.sh           # debug build → build/pgBrain.app
./scripts/bundle.sh release   # release build
./scripts/run.sh              # bundle + launch
./scripts/clean.sh
```
`bundle.sh` signs with the Developer ID from `scripts/.env` when it's available (stable identity → the Keychain treats every rebuild as the same app, no password prompts); otherwise ad-hoc with `Resources/pgBrain-dev.entitlements`. `PGBRAIN_ADHOC=1` forces ad-hoc.

## Testing
```bash
swift test                                            # local pgbrain_demo as $USER
PGBRAIN_TEST_DSN=postgres://u:p@host:5432/db swift test  # explicit target
PGBRAIN_KEYCHAIN_TESTS=1 swift test                   # also the real-Keychain tests
```
- `@testable import pgBrain` drives the real engines against a live Postgres in throwaway schemas. **No database reachable → E2E tests SKIP** (5s-bounded probe), so the release gate passes on a DB-less box.
- **Never touch the real Keychain by default**: every rebuilt test binary has a new signature and macOS prompts for the login password. Keychain tests are opt-in via `PGBRAIN_KEYCHAIN_TESTS=1`; everything else injects closures or uses random ids that don't exist.
- Engines meant to be tested expose a **pure entrypoint** with no `ConnectionService`/UI dependency (e.g. `SchemaDuplicator.duplicate(client:…)`); the `@MainActor` UI wrapper adds operation tracking on top. Keep that split. Grid/navigation logic lives in pure types (`GridSelection`, `DirtyGuard`, `WorkspaceState`) for the same reason.
- AppKit glue is tested headlessly by instantiating the view/coordinator and calling its overrides (`DataGridKeyEquivalentTests`, `CompletingTextFieldTests`). XCUITest is out (needs an Xcode UI-test bundle, which collides with the no-`.xcodeproj` rule).

## Screenshots
`scripts/screenshots.sh` seeds a throwaway `pgbrain_showcase` database, runs a debug build in showcase mode (one run per appearance) and frames the PNGs into `docs/screenshots/`. Showcase mode must stay invisible and side-effect free: activation policy *prohibited*, windows parked at (-30000, -30000) below the desktop level and rendered with `cacheDisplay` (never screen capture), no Keychain access (guarded in `Keychain`), its own `AppSupport` directory (`PGBRAIN_SUPPORT_DIR`) and defaults suite, no Sparkle / menu bar item / session restore. Scenes drive the app through model objects only. Hooks into app code are `#if DEBUG` and keyed off `ShowcaseEnvironment.isActive`.

## Window model (DataGrip-style)
- **Welcome window** at launch and whenever no other window is open.
- **One window per (connection, database)**. The database switcher opens a sibling window with the database overridden; `WindowManager` keys on both, and `SessionState` persists the override.
- Closing a tab, a window, or quitting goes through `TabCloseGuard`: unapplied grid edits (Discard / Cancel) first, then open scratchpad transactions (Commit / Roll Back / Cancel).
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` — the menu bar item keeps the app alive. `applicationWillTerminate` runs `AppTermination` (flush debounced stores, stop ssh).
- Window factories return `NSWindow` and use the `WindowCloseObserver` helper to fire a `@MainActor` close callback without strong references.
- Notifications aimed at a window carry the connection id as `object`; receivers check `service.owns(notif)`, which also honours an optional window id (sibling database windows share the connection id).

## Data access
- **Pool** — `ConnectionService` owns a `PostgresClient` per window: grid, catalog, admin actions, import/export. Health-checked (ping, wake, network change, ssh exit) with automatic reconnect.
- **Scratchpad** — each scratchpad tab has its own pinned `ScratchpadSession` over `Query/Wire/` (simple-query protocol) because PostgresNIO can only return binary results and exposes neither transaction status nor the cancel key. This gives psql-exact text rendering, session affinity (`SET`, temp tables, `BEGIN`), and protocol-level cancel. GSSAPI/SSPI servers fall back to the pool.
- **One source of connection settings** — `ConnectionService.tlsConfiguration(for:)`, `clientConfiguration(...)`, `openEndpoint/releaseEndpoint(for:owner:)` and `Connection.startupParameters()` are used by the pool, the scratchpad wire client, cross-DB copy and the connection test. Read-only mode and timeouts are startup parameters, so they apply everywhere. Don't build a `PostgresClient.Configuration` by hand.
- **Identifiers and literals** — `SQLIdent.quote` for identifiers; bind parameters (`$1`) wherever the statement allows, otherwise the escaping helpers. SQL text analysis (splitting, safety classification, formatting, highlighting) goes through the single `SQLLexer`.
- **Secrets** — passwords live in the Keychain (default ACL, service `cloud.souris.pgbrain.connection`; legacy items migrate on first read). pg_dump/pg_restore get them via a temporary 0600 `PGPASSFILE`. Query history masks password literals.

## SwiftUI ↔ AppKit boundary
- SwiftUI views are hosted in `NSHostingController` inside plain `NSWindow`s — **not** `WindowGroup` — for control over title bars, restoration and per-connection identity.
- The only SwiftUI `Scene` is `Settings { … }`, so `⌘,` and the standard app menu come for free.
- Keyboard: AppKit views (`EditableTableView`, sidebar outline) only handle key equivalents when they are the first responder of the key window; don't add global key handling that ignores focus.

## Concurrency
Swift 6 language mode. UI-facing types are `@MainActor`. Background work uses detached tasks with `Sendable` values; `@unchecked Sendable` only for lock-protected boxes (say so in a why-comment).

## Tokens & branding
Brand colors live in `AppearanceTokens.Brand`. Primary is a deep violet (`#6B52DB` approx), used by the gradient on Welcome's left pane and the About icon. **Icons are designed for macOS tinting**: simple monochromatic foregrounds on a flat or single-direction gradient. `gen-icon.swift` draws a white stacked-cylinder mark over the brand gradient.

## Conventions
- No `.xcodeproj`. To debug in Xcode, "File → Open Package…" on this directory.
- No comments that explain *what* the code does. Only *why*-comments when a non-obvious constraint is at play.
- No `print()` / `NSLog`. Log through `Log.<category>` (`os.Logger`, subsystem `cloud.souris.pgbrain`). PostgresNIO's own logging is silent unless Settings ▸ Verbose Postgres logging is on.
- When a feature spans more than one file, update `PLAN.md`; user-visible changes go into `CHANGELOG.md` under the next version.
- Don't run anything that makes macOS prompt for the Keychain/login password (see Testing, Build & run).
