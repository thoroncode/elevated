# Elevated — Claude Code Context

Pixel-perfect Metal/Swift port of the Elevated 4KB intro (rgba/tbc, Breakpoint 2009).
Multi-platform: macOS, iOS/iPad, Apple TV, visionOS (WIP).

Full technical journal: `JOURNAL.md`

## App Store / TestFlight

- **Local release config**: Xcode identifiers live in `Config/Identifiers.local.xcconfig` (gitignored); Fastlane/Makefile identifiers live in `fastlane/.env` (gitignored)
- **Templates**: `Config/Identifiers.local.xcconfig.example` and `fastlane/.env.default`
- **App name**: "Elevated Intro"
- **Versioning**: `YY.M.D` plus optional `HH.MM` build metadata where the platform has a second field — `./stamp-version.sh` stamps all Xcode projects, and macOS `.pkg` uses the short version only
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
