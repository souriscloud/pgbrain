# Release & Auto-Update Improvements (RELIMPR)

Notes comparing pgBrain's release/update pipeline against the sibling apps
(VirtualMirror, OptaKube) under `~/work/bench/`. VirtualMirror is the most
mature pipeline of the three and is treated as the reference here.

## Where pgBrain already does well

- Gitignored `scripts/.env` for credentials (good; matches VirtualMirror).
- Targeted git staging (`Info.plist` + `appcast.xml`), not `git add -A`.
- Clean-tree + tag-uniqueness preflight before releasing.
- Monotonic `CFBundleVersion` bump via `bump.sh` (correct for Sparkle).
- Nested Sparkle helpers signed deepest-first (modern Apple requirement).
- Best release docs of the three (`RELEASE.md` runbook + troubleshooting).
- DMG built with pure macOS tools (no `create-dmg` dependency).

## Status (adopted 2026-05-31)

Applied to `scripts/release.sh` this pass — chosen because they carry **no hidden
dependency** that could break a release or wipe history:

- ✅ **#3 Test gate** — runs `swift test` in preflight *only when* a `Tests/` dir
  or `.testTarget` exists. The package is executable-only today, so it logs
  "skipping" rather than failing; the gate activates automatically once tests
  are added. (Adding the test target itself is a separate refactor — an
  executable target needs a library split for `@testable import`.)
- ✅ **#4 Rollback trap** — an `EXIT` trap reverts the `Info.plist` version bump
  if the run aborts before the release commit; disarmed once committed.
- ✅ **#5a `chmod 600 scripts/.env`** — enforced right after the file is sourced.

Deferred **because of hidden dependencies that must be filled first** (doing them
naively would break things):

- ⏸ **#1 `generate_appcast`** — it regenerates the whole appcast from the
  contents of `releases/`, but we only copy the *current* DMG there. Adopting it
  as-is would **drop every prior `<item>`** from `appcast.xml` (history loss) and
  can't build deltas without the previous DMGs. **Gap to fill first:** backfill
  `releases/` with *all* historical DMGs (download them from the GitHub
  releases) and keep them committed/retained, then switch. Until then the
  robust awk-insert stays.
- ⏸ **#5b Rename `NOTARYTOOL_PROFILE`** away from `"VirtualMirror"` — the profile
  name must match a keychain credential created by `notarytool
  store-credentials <name>`. Renaming the var without creating the matching
  credential **breaks notarization**. **Gap to fill first (manual, needs Apple
  creds):** `xcrun notarytool store-credentials "pgBrain" --apple-id <email>
  --team-id $TEAM_ID --password <app-pw>`, then update `scripts/.env`.
- ⏸ **#2 Shared Sparkle key** and **#6 CI** — org-level decisions, not code
  changes; see below.

## Recommended improvements

### 1. Adopt Sparkle `generate_appcast` instead of hand-rolled awk insert
Currently `release.sh` builds an `<item>` via heredoc and awk-inserts it into
`appcast.xml`. VirtualMirror instead runs `generate_appcast` over a `releases/`
dir, which:
- produces **delta updates** (users download only the diff, not the full DMG);
- signs each enclosure/delta with EdDSA automatically (no manual `sign_update`);
- is far less brittle than string-splicing XML.
Action: copy VirtualMirror's `releases/` + `generate_appcast` step; keep
`--download-url-prefix` pointing at the GitHub release download URL.

### 2. Shared Sparkle signing key (org-wide decision)
`SUPublicEDKey = 4uTQZEdMy3jrq7GANt1oiPJuTk1q5pKHJLf6xMjiWz8=` is the **same
key used by VirtualMirror and OptaKube**. One private key signs updates for
every souris.cloud app. Risks:
- Losing/leaking it forces a re-key of *all* apps; pinned installs can't
  auto-update past a key change (manual reinstall required).
Action: decide deliberately — either per-app keys, or a documented, backed-up
custody plan for the single shared key.

### 3. Run tests before archiving
No `swift test` runs in the pipeline. Add a preflight `swift test` (or at least
the documented smoke test) gate so a broken build can't be released.

### 4. Rollback / failure safety
A failure after `bump.sh` leaves `Info.plist` modified (RELEASE.md documents the
manual `git checkout`). Consider a trap that reverts the version bump on
non-zero exit before any push/tag has happened.

### 5. Housekeeping
- `chmod 600 scripts/.env` (currently 644 — readable by other local users).
- `NOTARYTOOL_PROFILE="VirtualMirror"` is reused from another app; rename to a
  pgBrain-specific profile to remove the implicit cross-app coupling.
- Feed branch is `main` here vs `master` in the siblings — fine, but worth
  standardizing across the org.

### 6. (Optional) CI
All releases are manual/local. A GitHub Actions release workflow would remove
the single-machine bus factor, but requires moving signing material (Developer
ID cert, notary creds, Sparkle key) into CI secrets — a deliberate trade-off.

## Quick reference

| Item | pgBrain | Reference (VirtualMirror) |
|---|---|---|
| Appcast gen | hand-rolled awk, no deltas | `generate_appcast`, deltas ✅ |
| Credentials | gitignored `.env` ✅ | gitignored `.env` ✅ |
| Git staging | targeted ✅ | targeted ✅ |
| Tests in pipeline | none | none |
| Sparkle key | shared across apps ⚠️ | shared across apps ⚠️ |
