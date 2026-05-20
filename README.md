# pgBrain

Pro PostgreSQL for macOS. Native, JetBrains-density, no Electron.

> Status: iter-1 — empty shell launches with Welcome window, menu bar, and About. Real Postgres connectivity lands in iter-2. See [PLAN.md](PLAN.md).

## Requirements

- macOS 15 Sequoia or newer
- Xcode 26.5 / Swift 6.3+ (for building)

## Build & run

```bash
./scripts/run.sh             # build (debug) + bundle + launch
./scripts/bundle.sh release  # release build → build/pgBrain.app
./scripts/clean.sh
```

The first build regenerates `Resources/AppIcon.icns` via `scripts/gen-icon.swift`. Edit that script if you want a different icon.

## Layout

See [CLAUDE.md](CLAUDE.md) for the full architecture and conventions guide.

## Author

[Souris.CLOUD](https://apps.souris.cloud)
