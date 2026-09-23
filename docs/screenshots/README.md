# Screenshots

Generated — don't edit by hand. Regenerate with:

```bash
scripts/screenshots.sh                      # every scene, light + dark
scripts/screenshots.sh 01-hero,06-map       # just some scenes (others are kept)
```

`04-preview-sql` reuses the hero's staged edits and `07-explain` the
scratchpad's session, so include `01-hero` / `02-scratchpad` with them.

Needs a local PostgreSQL that lets `$USER` in without a password (trust or
peer auth). PostGIS is optional (without it the map scene is skipped);
`pngquant` is optional (`brew install pngquant`, roughly 3× smaller files).
A run takes about two minutes.

## What the script does

1. Creates the throwaway database `pgbrain_showcase` from
   `scripts/showcase/seed.sql` — a fictional store ("Driftwood Supply Co.")
   with `public`, `billing`, `analytics` and `inventory` schemas, a
   month-partitioned `orders` table, composite foreign keys, enums, jsonb,
   arrays, money, intervals, inet, views, a materialized view, functions and
   comments. Every name is made up. It is dropped again when the script
   exits, successfully or not.
2. Builds a debug app with ad-hoc signing (`PGBRAIN_ADHOC=1 scripts/bundle.sh`).
3. Starts a few extra `psql` sessions (a long report, a row lock and a writer
   waiting on it) so the Activity panel has something to show.
4. Runs the app binary once per appearance with `PGBRAIN_SHOWCASE=<dir>`. In
   that mode (DEBUG builds only, code in `Sources/pgBrain/Showcase/`) it:
   - never activates or gets a Dock icon (activation policy *prohibited*),
     and parks its windows at (-30000, -30000) below the desktop level —
     nothing appears on screen and focus never moves;
   - renders windows with `NSView.cacheDisplay` (no screen capture, no
     permission prompt);
   - never touches the Keychain, uses its own Application Support folder
     (`PGBRAIN_SUPPORT_DIR`) and preferences suite, skips Sparkle, the menu
     bar item and session restore;
   - drives each scene through the app's model objects, waits for the data
     to land, writes the PNGs and quits.
5. Frames the renders with `scripts/showcase/frame.swift`.

## Files

`<nn>-<scene>-<light|dark>[-variant].png`

| Variant | Size | Use |
|---|---|---|
| *(none)* | 3200×2000 (window @2x), rounded corners | docs, zoomed crops |
| `-framed` | window @1x + drop shadow, transparent | README, GitHub |
| `-marketing` | 1920×1080 on the brand gradient | website, social |

| # | Scene |
|---|---|
| 01 | hero — Pinned / Recent sidebar, breadcrumb, range selection, staged edits |
| 02 | scratchpad — open transaction, psql-exact types, inline chart |
| 03 | Go to Table (⌘O) palette |
| 04 | Preview SQL of staged grid edits |
| 05 | ERD of `public` |
| 06 | PostGIS map view |
| 07 | EXPLAIN plan viewer |
| 08 | Structure pane |
| 09 | Connection editor — verify-full + custom CA, read-only, timeouts, SSH |
| 10 | Activity panel — sessions, lock waits |

## Known approximations

- **Map tiles** are drawn by MapKit through the window server, which an
  off-screen render can't read. The harness puts an `MKMapSnapshotter`
  image of the same region under the map's own annotations (drawn as pins).
- **Sheets and the palette** are rendered in their own off-screen windows
  and composited over the parent window.
- **ERD**: the diagram leaves out partitions and extension-owned relations,
  the way the sidebar does; the ERD sheet itself still lists them.
- **Switches** that are on are redrawn (their knob lives in a Core Animation
  layer); tinted switches come out in the accent colour.
