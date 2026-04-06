# Elevated — Claude Code Context

Pixel-perfect Metal/Swift port of the Elevated 4KB intro (rgba/tbc, Breakpoint 2009).
Multi-platform: macOS, iOS/iPad, Apple TV, visionOS (WIP).

Full technical journal: `JOURNAL.md`

## Git Identity and SSH Setup

This repo belongs to the `thoroncode` GitHub account. Commits must use the identity:

    Petri Koistinen <thoron@iki.fi>

The default SSH key (`id_ed25519`) belongs to the `pkoistin` work account. This repo needs the `thoroncode-m3` key instead. Both identity and SSH key are configured per-repo in `.git/config` — no SSH host aliases needed.

### Clone and configure

```bash
GIT_SSH_COMMAND="ssh -i ~/.ssh/thoroncode-m3" git clone git@github.com:thoroncode/elevated.git
cd elevated
git config user.name "Petri Koistinen"
git config user.email "thoron@iki.fi"
git config core.sshCommand "ssh -i ~/.ssh/thoroncode-m3"
```

This sets `core.sshCommand` in `.git/config` so all subsequent git operations (fetch, push, pull) use the correct key automatically.

## Xcode Cloud

- **Workflow creation**: In Xcode 16+, use **Integrate** menu (not Product → Xcode Cloud)
- **Post-clone script**: `ci_scripts/ci_post_clone.sh` generates `Identifiers.local.xcconfig` from CI env vars
- **Required env vars** (set as secrets in workflow): `ELEVATED_APPLE_TEAM_ID`, `ELEVATED_APP_IDENTIFIER`
- **Version stamping**: `stamp-version.sh` runs automatically in post-clone
- **Code signing**: Xcode Cloud manages certificates automatically (cloud-managed)
- **Workflows cannot be created from CLI** — initial setup must be done in Xcode, then manageable from App Store Connect web UI

## App Store / TestFlight

- **Local release config**: Xcode identifiers live in `Config/Identifiers.local.xcconfig` (gitignored); Fastlane/Makefile identifiers live in `fastlane/.env` (gitignored)
- **Templates**: `Config/Identifiers.local.xcconfig.example` and `fastlane/.env.default`
- **App name**: "Elevated Intro"
- **Versioning**: `YY.M.D` plus optional `HH.MM` build metadata where the platform has a second field — local release targets inject that version at build time, `make stamp-version` updates tracked Xcode projects explicitly, and macOS `.pkg` uses the short version only
- **Export compliance**: Must set `usesNonExemptEncryption: false` on each build via API or ASC web UI
- **TestFlight group/app IDs**: treat as local release config, not tracked repo data
- **Fastlane 2.232.2**: `pilot builds/distribute/list` broken due to `betaBuildMetrics` API change. Use Spaceship Ruby API directly.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make ios-release` | Stamp + archive + upload iOS to App Store Connect |
| `make tv-release` | Stamp + archive (unsigned) + export+upload tvOS |
| `make tv-submit` | Submit latest tvOS build for App Store review |

## tvOS Key Findings

- **Code signing workaround**: No registered tvOS devices → archive unsigned (`CODE_SIGNING_ALLOWED=NO`), sign at export with `-allowProvisioningUpdates`
- **Performance**: Must use `autoResizeDrawable = false` + explicit `drawableSize` to force render resolution. `contentScaleFactor` alone is unreliable. 1080p runs smooth on A15, 4K is unusable.
- **App icons**: tvOS uses `.imagestack` (layered, min 2 layers) in `.brandassets`. Role for App Store icon is `primary-app-icon` at 1280x768 — NOT a separate `app-store-icon` role.
- **Top Shelf**: needs both @1x (2320x720) and @2x (4640x1440) wide images
- **Upload method**: `scripts/write_export_options_plist.sh` + `xcodebuild -exportArchive` — uses Xcode's built-in auth, no app-specific password needed

## Architecture

- **3-pass Metal**: G-buffer (terrain mesh) → deferred shading → post-processing
- **Uniforms**: q[0..12], VP matrix + inverse VP
- **Camera**: CPU `m1Camera(xdot:)` replicates D3D9 m1 pixel shader
- **Terrain**: 1024×1024 grid ±52 units, alternating quad diagonals
- **Renderer.renderFrame()**: headless rendering with custom VP matrix (for visionOS VR)
- **Background handling**: MTKView.isPaused=true on background, preserves play/pause state

## Features

- **tvOS scrub bar**: Siri Remote pan gesture, velocity-based seeking, auto-hiding transport overlay
- **iOS scrub bar**: Tap to show transport, pan to scrub (only when transport visible), preserves state
- **Background muting**: iOS + tvOS pause renderer + audio + stop MTKView on background
- **visionOS immersive (WIP)**: CompositorServices + ARKit head tracking, demo camera position + head orientation, needs API fixes

## Xcode Cloud Build Strategy

Current: all workflows trigger on every push to `main` (wasteful).

Planned: single `release` branch triggers all workflows. Develop freely on `main` with no CI builds.
- To release: `git push origin main:release`
- Configure each workflow's Start Conditions in App Store Connect to watch `release` branch only
- Manual trigger in ASC available for ad-hoc builds during development
- TODO: implement once all platforms build cleanly

## iOS Simulator

- **Landscape orientation**: iPhone always launches in portrait (Apple TN2244). The app rotates to landscape automatically, but the simulator window stays portrait. Rotate manually or use:
  ```
  osascript -e 'tell application "Simulator" to activate' -e 'tell application "System Events" to keystroke (ASCII character 29) using command down'
  ```
  On real hardware the landscape transition is instant and invisible.
