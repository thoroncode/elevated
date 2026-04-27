# AGENTS

This file defines the default workflow for human and AI contributors in this repository.

## Git Worktree Policy

By default, if you are going to modify files, do not work in the main checkout and do not work on `main`.

- Treat the main checkout as read-only integration space for normal implementation work.
- Read-only investigation on `main` is allowed.
- Each AI agent should keep one long-lived default worktree outside the main checkout, for example `~/src/codex-elevated` or `~/src/claude-elevated`.
- Normal day-to-day agent work should happen in that agent's default worktree, not in the main checkout.
- Extra task-specific worktrees are for work that is unusually risky, long-running, experimental, or likely to overlap with another active branch.
- Merge validated task branches back to `main` from the integration checkout.

### Small Fix Exception

Tiny, low-risk fixes may be done directly on `main` in the main checkout when all of the following are true:

- The change is isolated and easy to review.
- The change does not span multiple subsystems.
- There is no parallel agent or human work that could conflict with it.
- The change does not rewrite or reorganize existing work.

Examples:

- Excluding one stray file from a package manifest
- Fixing a typo in docs or comments
- Adjusting a small build warning with an obvious one-file fix

When in doubt, use the agent's default worktree first. Make an extra task worktree only when the default one is not enough.

## Branch Naming

Use a branch prefix that matches the task:

- `task/<name>` for general implementation work
- `fix/<name>` for bug fixes
- `exp/<name>` for experiments and visual comparisons

Keep names short, concrete, and filesystem-friendly.

## Standard Task Setup

For normal AI work, bootstrap one default agent worktree and keep using it:

```bash
cd /path/to/repo
git switch main
git pull --ff-only
git worktree add ~/src/<agent>-elevated -b task/<agent>-default main
cd ~/src/<agent>-elevated
```

If the default worktree is already busy and you need a separate feature branch, create an extra task worktree:

```bash
cd /path/to/repo
git switch main
git pull --ff-only
git worktree add ../repo-<task-name> -b task/<task-name> main
cd ../repo-<task-name>
```

If a sibling directory is inconvenient, use another suitable location such as `/tmp`.

## Merge And Cleanup

After the task is validated:

```bash
cd /path/to/repo
git switch main
git merge --ff-only task/<task-name>
git worktree remove ../repo-<task-name>
git branch -d task/<task-name>
```

For experiments, keep the branch only as long as it still adds comparison value.

## Safety Rules

- Do not rewrite or delete someone else's in-progress work without explicit approval.
- Do not use destructive git commands unless explicitly requested.
- If multiple agents are working at once, each agent should use a separate worktree.
- Do not add `Co-Authored-By:` trailers to commits.

## Elevated Repository Context

Pixel-perfect Metal/Swift port of the Elevated 4KB intro (rgba/tbc, Breakpoint 2009).
Multi-platform: macOS, iOS/iPad, Apple TV, visionOS (WIP).

Full technical journal: `JOURNAL.md`

### Git Identity and SSH Setup

This repo belongs to the `thoroncode` GitHub account. Commits must use the identity:

    Petri Koistinen <thoron@iki.fi>

The default SSH key (`id_ed25519`) belongs to the `pkoistin` work account. This repo needs the `thoroncode-m3` key instead. Both identity and SSH key are configured per-repo in `.git/config` — no SSH host aliases needed.

#### Clone and configure

```bash
GIT_SSH_COMMAND="ssh -i ~/.ssh/thoroncode-m3" git clone git@github.com:thoroncode/elevated.git
cd elevated
git config user.name "Petri Koistinen"
git config user.email "thoron@iki.fi"
git config core.sshCommand "ssh -i ~/.ssh/thoroncode-m3 -o IdentitiesOnly=yes"
```

This sets `core.sshCommand` in `.git/config` so all subsequent git operations (fetch, push, pull) use the correct key automatically. `IdentitiesOnly=yes` is required: without it, ssh-agent offers `id_ed25519` (the pkoistin work key) first, authenticates as the wrong account, and GitHub responds with "Repository not found" before the thoroncode key is ever tried.

### Xcode Cloud

- **Workflow creation**: In Xcode 16+, use **Integrate** menu (not Product → Xcode Cloud)
- **Post-clone script**: `ci_scripts/ci_post_clone.sh` generates `Identifiers.local.xcconfig` from CI env vars
- **Required env vars** (set as secrets in workflow): `ELEVATED_APPLE_TEAM_ID`, `ELEVATED_APP_IDENTIFIER`
- **Version stamping**: `stamp-version.sh` runs automatically in post-clone
- **Code signing**: Xcode Cloud manages certificates automatically (cloud-managed)
- **Workflows cannot be created from CLI** — initial setup must be done in Xcode, then manageable from App Store Connect web UI

### App Store / TestFlight

- **Local release config**: Xcode identifiers live in `Config/Identifiers.local.xcconfig` (gitignored); Fastlane/Makefile identifiers live in `fastlane/.env` (gitignored)
- **Templates**: `Config/Identifiers.local.xcconfig.example` and `fastlane/.env.default`
- **App name**: "Elevated Intro"
- **Versioning**: `YY.M.D` plus optional `HH.MM` build metadata where the platform has a second field — local release targets inject that version at build time, `make stamp-version` updates tracked Xcode projects explicitly, and macOS `.pkg` uses the short version only
- **Export compliance**: Must set `usesNonExemptEncryption: false` on each build via API or ASC web UI
- **TestFlight group/app IDs**: treat as local release config, not tracked repo data
- **Fastlane 2.232.2**: `pilot builds/distribute/list` broken due to `betaBuildMetrics` API change. Use Spaceship Ruby API directly.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make ios-release` | Stamp + archive + upload iOS to App Store Connect |
| `make tv-release` | Stamp + archive (unsigned) + export+upload tvOS |
| `make tv-submit` | Submit latest tvOS build for App Store review |

### Reference Artifacts

- **Reference AVI**: `make ref-video` downloads the original `elevated_8000.avi` from scene.org to `artifact/reference/elevated_8000.avi` and verifies SHA-256 `2c8d12fcb757ba1e5080f53e2bc5ba52f14dca92115cc53f3ed131d67effb73c`
- **Original intro source**: `make intro-source` downloads `rgba_tbc_elevated_2016.zip` from scene.org to `artifact/original-source/rgba_tbc_elevated_2016.zip`, verifies SHA-256 `2a650b0b0f7ae16362d5edf0ea0610a156c2e773b70c7362a5e5a5f976fafabe`, and extracts it to `artifact/original-source/rgba_tbc_elevated_2016/`
- **Canonical party text**: the original `file_id.diz` text is preserved in `doc/file_id.diz`; treat it as authoritative context alongside the 2016 compatibility repack
- **Reference frames**: `make ref` extracts 1 fps PNGs from that local artifact into `/tmp/elevated_ref/`

### tvOS Key Findings

- **Code signing workaround**: No registered tvOS devices → archive unsigned (`CODE_SIGNING_ALLOWED=NO`), sign at export with `-allowProvisioningUpdates`
- **Performance**: Must use `autoResizeDrawable = false` + explicit `drawableSize` to force render resolution. `contentScaleFactor` alone is unreliable.
- **Mesh LOD**: 342×342 grid for A8 (proven identical: 1023 % 341 == 0). 9× fewer triangles, zero visual difference. Valid LOD sizes: [4, 12, 32, 34, 94, 342, 1024].
- **Apple TV HD (A8)**: 342 mesh + 240p = ~24fps. Was 1024 mesh + 144p = ~11fps. Vertex-bound → fragment-bound transition at ~270p.
- **Apple TV 4K (A15+)**: 1024 mesh + 1080p, runs smooth at 60fps.
- **Idle timer**: `UIApplication.shared.isIdleTimerDisabled = true` prevents screensaver during playback.
- **App icons**: tvOS uses `.imagestack` (layered, min 2 layers) in `.brandassets`. Role for App Store icon is `primary-app-icon` at 1280x768 — NOT a separate `app-store-icon` role.
- **Top Shelf**: needs both @1x (2320x720) and @2x (4640x1440) wide images
- **Upload method**: `scripts/write_export_options_plist.sh` + `xcodebuild -exportArchive` — uses Xcode's built-in auth, no app-specific password needed

### Architecture

- **3-pass Metal**: G-buffer (terrain mesh) → deferred shading → post-processing
- **Uniforms**: q[0..12], q[14]=mesh grid size, q[15]=sRGB gamma, VP matrix + inverse VP
- **Camera**: CPU `m1Camera(xdot:)` replicates D3D9 m1 pixel shader
- **Terrain**: configurable grid (default 1024×1024) ±52 units, alternating quad diagonals, vertex shader reads size from q[14].x
- **Renderer.renderFrame()**: headless rendering with custom VP matrix (for visionOS VR)
- **Background handling**: MTKView.isPaused=true on background, preserves play/pause state

### Features

- **tvOS scrub bar**: Siri Remote pan gesture, velocity-based seeking, auto-hiding transport overlay
- **iOS scrub bar**: Tap to show transport, pan to scrub (only when transport visible), preserves state
- **Background muting**: iOS + tvOS pause renderer + audio + stop MTKView on background
- **visionOS immersive (WIP)**: CompositorServices + ARKit head tracking, demo camera position + head orientation, needs API fixes

### Xcode Cloud Build Strategy

Per-platform release branches so a push only rebuilds the affected app:

| Branch | Triggers |
|--------|----------|
| `release-ios` | iOS workflow |
| `release-macos` | macOS workflow |
| `release-tvos` | tvOS workflow |
| `release-visionos` | visionOS workflow |

Develop freely on `main` with no CI builds. To release one platform:

```bash
git push origin main:release-ios       # or release-macos / release-tvos / release-visionos
```

Cross-platform changes (shaders, renderer) need one push per affected branch — explicit beats wasteful.

- Configure each workflow's Start Conditions in App Store Connect to watch its specific `release-*` branch
- Manual trigger in ASC remains available for ad-hoc builds
- TODO: reconfigure each workflow's Start Conditions in ASC (cannot be done from CLI)

### iOS Simulator

- **Landscape orientation**: iPhone always launches in portrait (Apple TN2244). The app rotates to landscape automatically, but the simulator window stays portrait. Rotate manually or use:
  ```
  osascript -e 'tell application "Simulator" to activate' -e 'tell application "System Events" to keystroke (ASCII character 29) using command down'
  ```
  On real hardware the landscape transition is instant and invisible.

## 4K Fidelity Policy

The `elevated4k/` path is not a freeform reinterpretation of Elevated. Treat it as
an engineering port with size constraints, not as an art direction sandbox.
See also `elevated4k/FIDELITY.md`.

- Preserve rendering semantics unless the user explicitly approves a visual change.
- Do not make "looks close enough" shader edits just because they save bytes.
- Cleanup, simplification, and tooling improvements are welcome when they preserve
  the produced image and timing behavior.
- When a change touches modeling, shading, texturing, camera behavior, motion blur,
  postprocessing, or pass structure, assume it is high risk for visual regression.
- High-risk visual changes must be validated with output comparison at representative
  timestamps before they are treated as acceptable optimizations.
- If a change is exploratory or intentionally changes the image, keep it on an
  experiment branch such as `exp/...` until it has been reviewed.

The historical reference for Elevated matters. The Function 2009 "behind elevated"
seminar describes the intended architecture and image goals. In particular:

- The intro uses the "2 triangles plus 1,000,000" approach: rasterized primary
  intersections plus fullscreen procedural shading.
- The final image pipeline is a 3-pass structure: geometry/intersection pass,
  deferred shading pass, then postprocessing pass.
- Motion blur is a postprocess effect and is not license to replace the shading
  model with a cheaper approximation.

If there is tension between visual fidelity and packed size, fidelity wins by
default unless the user says otherwise.
