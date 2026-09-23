# PLAN.md — pgBrain

Living plan: what's in flight, what's next, what's parked. Architecture and
conventions live in `CLAUDE.md`; user-facing history lives in `CHANGELOG.md`;
the iteration-by-iteration log for v0.0.1 → v0.9.7 is archived in
`docs/history/iterations-v0.0-v0.9.md`.

## Now — v0.10.0 (full sweep, started 2026-09-23)

A full audit of the codebase (navigation UX, grid/editor, data layer and
security, repo hygiene) fed one release that fixes everything it found and
overhauls navigation. 1.0.0 comes after this settles.

- [x] **Phase 0 — cleanup & toolchain.** CI + codecov removed (free account,
      no macOS minutes); dead i18n scaffold and Beta channel removed; verbose
      Postgres logging wired to `os.Logger`; `Package.resolved` committed,
      postgres-nio 1.33.1, Sparkle 2.10.0; empty release entitlements;
      `release.sh` dry run, CHANGELOG-driven notes, appcast pruning.
- [ ] **Phase 1 — silent-data bugs.** SQL classification (`WITH … INSERT`,
      `SELECT INTO`, CRLF, E-strings, `$1`) via one shared lexer; CSV import
      column mapping; scratchpad type rendering (text results); staged-edit
      loss; stale grid on same-size pages; timestamp editing; formatter
      eating code after `--`; connection list / Keychain data-loss paths.
- [ ] **Phase 2 — navigation overhaul.** Stable sidebar tree (no re-expand on
      every render, no spinner on refresh); schema picker; tree keyboard;
      fuzzy filter; Go to Table (⌘O); preview tabs; tab management; breadcrumb
      bar; back/forward; recent & pinned tables; database switcher;
      schema-aware new scratchpad; cleaner catalog (empty schemas, extension
      objects, partitions).
- [ ] **Phase 3 — grid & editor.** First-responder-gated key equivalents;
      load generations; PK-ordered paging; `UPDATE … RETURNING`; cell/range
      selection, paste, keyboard editing, redo; pending-SQL preview; editing
      tables without a PK via `ctid`; per-tab view state; god-file splits.
- [ ] **Phase 4 — sessions, connectivity, security.** Pinned session per
      scratchpad with transaction indicator; reconnect after sleep / network
      change; SSH tunnel supervision; TLS server name over SSH, custom CA and
      client certs; startup parameters and read-only mode; pg_dump 18 +
      version matching + tunnel; Keychain ACL; history password redaction;
      conninfo / pgpass / pg_service import.
- [ ] **Phase 5 — tests, docs, release.** Regression tests for every Phase 1
      bug; CLAUDE.md / README / RELEASE.md refresh; CHANGELOG; release v0.10.0.

## Backlog

- **UI-level E2E (XCUITest)** — needs an Xcode UI-test bundle, which collides
  with the no-`.xcodeproj` rule. Tier-A headless AppKit tests
  (`DataGridKeyEquivalentTests`, `CompletingTextFieldTests`) cover the glue in
  the meantime.
- **Beta update channel** — removed in 0.10.0; reintroduce with a real
  `appcast-beta.xml` and a release.sh `--beta` flag when needed
  (`docs/SPARKLE-NIGHTLY-CHANNEL.md` has the recipe).
- **Localisation** — the English/Czech scaffold was removed as dead code;
  redo properly (String Catalog embedded by `bundle.sh`) if there's demand.

## Open questions

- **`COPY … TO STDOUT`** — postgres-nio exposes `copyFrom` but no public
  copy-out, so exports stay on `SELECT … ::text`. Revisit when it ships.
- **`generate_appcast`** — staying on the hand-written `<item>` prepend in
  `release.sh`; switching needs every historical DMG locally or it rewrites
  appcast history.
- **Sidebar at 10k+ tables** — lazy children and the `SchemaIndex` trie keep
  it usable; re-measure after the 0.10.0 tree rewrite.
