# RELEASE.md — pgBrain release runbook

This file is the source of truth for "how do we ship a release." Read this before running `scripts/release.sh`. Update it whenever the flow changes — anything not written here will get rediscovered the hard way.

---

## TL;DR

```bash
./scripts/release.sh patch        # 0.0.1 → 0.0.2
./scripts/release.sh minor        # 0.0.1 → 0.1.0
./scripts/release.sh major        # 0.0.1 → 1.0.0
./scripts/release.sh 1.2.3        # explicit
```

One command does: **tests → bump → build → bundle → embed Sparkle.framework → codesign (deepest first) → notarize app → DMG (branded, with Applications symlink) → codesign DMG → notarize DMG → EdDSA sign update → prepend `<item>` to appcast.xml → commit + push + tag → `gh release create` with DMG and the CHANGELOG section as notes**.

There is **no CI** (free GitHub account; macOS runner minutes are limited). The
release script's `swift test` gate is the only automated check, so run it on a
machine with a local Postgres (`pgbrain_demo`) or set `PGBRAIN_TEST_DSN`, or the
E2E tests skip.

**Before running it:** add a `## vX.Y.Z — YYYY-MM-DD` section to `CHANGELOG.md`
and commit. The script refuses to release without one, and uses it verbatim as
the GitHub release notes.

Total runtime: 5–15 min (notarytool is the long pole, ~1–5 min per submission, two submissions).

---

## Prereqs (one-time setup; all in place)

| Piece | What | Where |
|---|---|---|
| `.env` | `TEAM_ID`, `CODESIGN_IDENTITY`, `NOTARYTOOL_PROFILE`, `GITHUB_REPO` | `scripts/.env` (gitignored) |
| Developer ID cert | "Developer ID Application: … (26GLU32796)" — exact name in `CODESIGN_IDENTITY` | macOS Keychain |
| notarytool profile | Name in `NOTARYTOOL_PROFILE` (shared across souris.cloud apps) | macOS Keychain, set via `xcrun notarytool store-credentials` |
| Sparkle EdDSA key | Public key in `Resources/Info.plist`, private in Keychain | Shared across souris.cloud apps via Sparkle's `generate_keys` |
| GitHub repo | `souriscloud/pgbrain` (public, `main` is default) | github.com |
| `gh` CLI | Authenticated as `souriscloud` | `gh auth status` |
| Sparkle tools | `.build/artifacts/sparkle/Sparkle/bin/` (sign_update, generate_keys, generate_appcast) | Auto-fetched by `swift build` |

The release script's preflight checks all of these and bails with a useful message if any are missing.

---

## What it actually does, step by step

1. **Preflight** — gh auth, codesigning identity present, notarytool profile reachable, Sparkle key in Keychain, `swift test` green (log in `build/test.log`), working tree clean. Right after the bump it also checks the tag is free and that `CHANGELOG.md` has a section for the new version; any failure from here until the commit reverts the bump automatically.
2. **`scripts/bump.sh <kind>`** — bumps `CFBundleShortVersionString` + `CFBundleVersion` in `Resources/Info.plist` via PlistBuddy. Prints `<version> (build <n>)` for piping.
3. **`scripts/bundle.sh release`** — `swift build -c release --arch arm64`, assembles `build/pgBrain.app`, embeds `Sparkle.framework` from `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/` into `Contents/Frameworks/`, ad-hoc signs nested helpers (release script re-signs with Developer ID in step 4).
4. **Codesign with Developer ID** — signs nested Sparkle helpers first (XPCServices/Downloader.xpc → Installer.xpc → Autoupdate → Updater.app → Sparkle.framework), then the main app last. Uses `--options runtime --timestamp` with `Resources/pgBrain.entitlements` (intentionally empty: hardened runtime with no exemptions). Local ad-hoc builds use `Resources/pgBrain-dev.entitlements`, which only disables library validation because ad-hoc signatures carry no Team ID. No `--deep` (deprecated).
5. **Notarize app** — `xcrun notarytool submit ... --wait` then `xcrun stapler staple`.
6. **`scripts/build-dmg.sh`** — pure macOS tools, no `create-dmg` dep: stages `pgBrain.app` + `Applications` symlink + `.background/background.png`; creates UDRW DMG; mounts; AppleScript Finder into the branded layout (window 660×400, icon size 96, pgBrain at (180,200), Applications at (480,200), brand-gradient bg); detaches; converts to compressed UDZO.
7. **Codesign + notarize DMG** — same identity and notary profile.
8. **`sparkle-tools.sh sign_update`** — produces the EdDSA `sparkle:edSignature` for the DMG.
9. **Update `appcast.xml`** — awk inserts a fresh `<item>` block in the channel (after the channel metadata, before any existing items so newest-first), with `minimumSystemVersion` read from `LSMinimumSystemVersion`, then prunes to the 10 newest items. Older DMGs stay on GitHub Releases.
10. **Commit, tag, push** — single "release vX.Y.Z" commit for `Info.plist` + `appcast.xml`; tags `vX.Y.Z`; pushes branch + tag.
11. **`gh release create`** — publishes the GitHub Release with the DMG attached and the version's `CHANGELOG.md` section as notes.

---

## Flags

```bash
./scripts/release.sh patch --skip-notarize    # dry-run: ad-hoc sign, no Apple round-trip
./scripts/release.sh patch --skip-upload      # skip gh release create at the end
```

`--skip-notarize` is a true dry run: it builds, ad-hoc signs and EdDSA-signs the DMG, then **stops** — no appcast change, commit, tag, push or upload, and the version bump is reverted. Useful for catching script bugs without touching Apple's submission history, the appcast users poll, or GitHub Releases. Flags may come in any order.

---

## When something goes wrong

### "Apple Developer agreement needs signing" at preflight
Apple returns HTTP 403 on notarytool when an agreement is pending. Open both:
- https://appstoreconnect.apple.com/agreements/
- https://developer.apple.com/account → Agreements

Click Accept on whatever's pending. **Must be done as the Account Holder**, not just an Admin. Propagation is usually instant but can take ~60s.

### "Notary profile not configured"
Recreate the keychain profile:
```bash
xcrun notarytool store-credentials "$NOTARYTOOL_PROFILE" \
    --apple-id <email> --team-id 26GLU32796 --password <app-specific-password>
```
Generate an app-specific password at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords.

### Script bailed mid-flight (between bump and commit)
Preflight runs *before* bump, so failures in preflight never mutate the tree. If a later step fails, an exit trap reverts `Resources/Info.plist`; no tag, push or GitHub release will have happened.

### Tests failed at preflight
The last 40 lines are printed; the full log is `build/test.log`.

### DMG looks blank / no Applications folder
Finder's AppleScript layout occasionally loses a race with the mount. `build-dmg.sh` detaches leftover `/Volumes/pgBrain*` volumes first (a stale one used to make the layout land on the wrong disk); just rerun.

### "Library not loaded: @rpath/Sparkle.framework/..." at launch
The binary lost its `@executable_path/../Frameworks` rpath. It's pinned in `Package.swift` via `linkerSettings` — verify it didn't get removed. Otool check:
```bash
otool -l build/pgBrain.app/Contents/MacOS/pgBrain | grep -A2 LC_RPATH
```
Should include `@executable_path/../Frameworks`.

### `sign_update` not found
The Sparkle CLI tools live under `.build/artifacts/sparkle/Sparkle/bin/`. Run `swift build` once to fetch the dependency, then retry. `scripts/sparkle-tools.sh` is the wrapper.

---

## Before running release.sh — mandatory smoke test

Two production releases (v0.0.2 and v0.0.3) shipped with crashes that 30 seconds of clicking would have caught. Don't skip this:

```bash
./scripts/bundle.sh release
open build/pgBrain.app
```

Then **manually**:
1. Welcome window appears → click **New Connection** → fill in any host → click **Save**.
2. Double-click the row to open the connection window.
3. Open a table, switch schemas, open a scratchpad and run `SELECT 1`. Wait 1–2 seconds — close the connection window. (Closing is what tripped v0.0.3's `SessionStateStore.scheduleSnapshot` isolation crash.)
4. Open **About pgBrain** from the menu bar.
5. Right-click the menu-bar icon → **Quit**.

If the app survives all five steps without crashing, you've covered: launch, sheet present, ConnectionService init, window register, SessionStateStore debounce fire, window close, menu bar interaction, quit. That's where every recent regression has lived.

Only then run `./scripts/release.sh patch`. For anything bigger than a patch, `./scripts/release.sh minor --skip-notarize` first is a cheap end-to-end rehearsal.

---

## After a release

- Check https://github.com/souriscloud/pgbrain/releases/latest looks right.
- Hit `https://raw.githubusercontent.com/souriscloud/pgbrain/main/appcast.xml` — should contain the new `<item>`. Note: GitHub's raw CDN cache is 5 minutes, so existing pgBrain installs won't see the update *immediately*, but they will on their next daily check (or via Settings → Updates → Check for Updates).
- If this is the first release after a big architectural change, do `open build/pgBrain.app` locally before celebrating — Sparkle update only fixes problems if the new binary actually launches.

---

## When you tell Claude "do a release"

Claude has all the pieces:

- `.env` is set, Keychain has cert + notary profile + Sparkle key, `gh` is authed, repo is `souriscloud/pgbrain`.
- It writes the `CHANGELOG.md` section first, then runs `./scripts/release.sh patch` (or whatever kind you specify) in the background.
- If preflight fails, Claude reads the actual error from `xcrun notarytool` and tells you which way to fix it.
- If the run succeeds, Claude verifies the release artifacts (DMG downloadable, appcast XML parses, GitHub Release exists).

Default to **patch** bump unless you specify otherwise. For breaking changes or major UX shifts, ask for `minor` or `major`.
