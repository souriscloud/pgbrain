# Recipe — adding a Nightly channel to Sparkle (post-1.0.0)

Reference implementation lives in pgBrain; copy this to any Souris app that
uses the same `scripts/release.sh` + `scripts/bump.sh` + `UpdateController`
pattern. **Not implemented yet** — pick it up when an app hits 1.0.0 and you
want a pre-release channel.

## The model

- **Nightly = live `main`.** Every bump you cut on `main` becomes a
  `nightly`-tagged appcast item. Ship as many minors/patches a day as you like
  — they all flow to nightly subscribers.
- **Stable = the subset you promote.** Occasionally you cut an **untagged**
  release; untagged items are seen by *everyone* (stable + nightly). That's a
  stable minor.
- **Patches on stable = hotfixes.** A stable patch is an untagged `x.y.(z+1)`
  cut straight on top of the last stable.

One appcast file holds both streams, distinguished by a channel tag. This is
**Sparkle 2's `<sparkle:channel>` mechanism (Option B)** — chosen over
separate feed files because graduation back to stable is automatic and there's
only one pipeline to maintain.

## Why the versioning Just Works

`bump.sh` already keeps two independent numbers:

| Field | Role | Example |
|---|---|---|
| `CFBundleShortVersionString` | marketing string, **cosmetic**, shown in UI | `0.10.0-nightly.27` |
| `CFBundleVersion` | **monotonic integer counter**, `+1` per build — this is what Sparkle orders by | `27` |

Because the build counter is decoupled from semver:

- **Infinite space** — no semver→int packing, no collisions. Every build is the
  next integer.
- **Graduation is automatic** — a stable cut after nightlies has a higher
  counter, so Sparkle offers it to nightly users with no special handling.
- **Only rule:** never reset `CFBundleVersion`. Always `+1`, across both channels.

> The marketing string is the *only* channel signal in Sparkle's UI, so give
> nightlies a suffix (`-nightly.<buildno>`) and keep stables clean (`0.10.0`).

## App change (~30 min)

Drop the feed-URL-per-channel switch in `UpdateController` and use Sparkle's
channel allow-list instead. Keep a **single** feed (`appcast.xml`, via
`SUFeedURL` in Info.plist or one constant).

```swift
// SPUUpdaterDelegate
nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    // Stable users get untagged items only; nightly users also get
    // <sparkle:channel>nightly</sparkle:channel> items.
    let channel = MainActor.assumeIsolated { AppSettings.shared.sparkleChannel }
    return channel == "nightly" ? ["nightly"] : []
}
// Remove feedURLString(for:) — one feed now. The channel name string here
// MUST match the tag the release script writes, exactly.
```

Settings: relabel the picker **Stable / Nightly** (it already drives
`AppSettings.sparkleChannel`). Add a one-line "Nightly ships untested builds
from main" warning.

## Release-script change (~1 hr)

Add a `--nightly` flag to `release.sh`:

1. **Marketing label:** suffix the version, e.g. set
   `CFBundleShortVersionString = <base>-nightly.<CFBundleVersion>`.
   (`bump.sh` still `+1`s `CFBundleVersion` as today.)
2. **Tag the appcast item.** In the `<item>` template, when nightly, add:
   ```xml
   <sparkle:channel>nightly</sparkle:channel>
   ```
   Untagged item = stable (the current behaviour, unchanged).
3. **One file.** Keep writing to `appcast.xml`. Nightly and stable items
   coexist; the tag does the filtering.
4. **Prune nightlies** (optional but recommended): after inserting, keep only
   the newest ~5 `nightly`-tagged `<item>`s so the feed and GitHub Releases
   don't balloon. Stable items are never pruned.
5. **Everything else is identical** — notarize, `sign_update` (EdDSA), DMG,
   tag, `gh release`. Each nightly still gets notarized so Gatekeeper stays
   clean (this is the real per-build cost; see below).

Promotion to stable = just run the normal `release.sh minor` (no `--nightly`):
untagged item, clean marketing string, higher build counter → everyone updates.

## Gotchas

- **Build counter is sacred.** Never reset `CFBundleVersion`; it's the global
  order across both channels. Stable cut after nightlies is automatically newer.
- **Channel string must match** between the appcast tag and `allowedChannels`
  (`"nightly"` == `"nightly"`), or nightly users see nothing.
- **GitHub raw caches ~5 min.** `raw.githubusercontent.com/.../appcast.xml`
  isn't instant; fine for updates, just not real-time.
- **Notarization is the cost of frequency.** Every nightly DMG still needs
  notarize (~3–5 min Apple round-trip) + EdDSA sign, or users hit Gatekeeper.
  If nightly cadence gets heavy, automate via a **local `launchd`/cron on your
  Mac** (Keychain already has the Developer ID cert, notary creds, and Sparkle
  key) — **not** GitHub Actions macOS runners (10× minutes cost + secrets
  sprawl). We have nothing in GH Actions and should keep it that way.
- **Don't offer downgrades.** Sparkle never offers a lower build number, so the
  monotonic counter is what prevents a stale stable from being pushed to a
  newer nightly. Handled for free by the counter.

## Minimal checklist

- [ ] `UpdateController`: `allowedChannels` instead of `feedURLString` switch; single feed.
- [ ] Settings picker → Stable / Nightly with a warning line.
- [ ] `release.sh --nightly`: `-nightly.<build>` label + `<sparkle:channel>nightly</sparkle:channel>` tag.
- [ ] Prune to last ~5 nightly items.
- [ ] Smoke test: install stable build, flip to Nightly in Settings, confirm it offers the latest nightly; flip back, confirm it waits for the next untagged stable.

## Effort / cost

| Piece | Effort | Recurring cost |
|---|---|---|
| App `allowedChannels` + settings | ~45 min | none |
| `release.sh --nightly` + prune | ~1 hr | none |
| Per nightly cut | `./scripts/release.sh --nightly` | one notarize (~3–5 min) |
| (Later) auto-nightly | local `launchd`, ~half day | notarize per build |

**TL;DR:** the build counter is already a clean monotonic integer, so a Nightly
channel is just (a) `allowedChannels` in the app, (b) a `--nightly` flag that
tags the appcast item and suffixes the marketing string. Promotion to stable is
a normal untagged release. No GH Actions.
