# Elevated — Development Journal

A log of discoveries, fixes, and decisions for future agent sessions.

---

## Project Overview

**Goal**: Pixel-perfect Metal/Swift port of the Elevated 4KB intro (rgba/tbc, Breakpoint 2009).
**Original**: `elevated_1920_1080.exe` — Direct3D9, HLSL shaders, x86 assembly synth.
**macOS port**: `elevated/ElevatedMac/` — Metal 3-pass renderer, Swift CPU logic, C synth port.
**iPadOS port**: `elevated/ElevatedIOS/` + `ElevatedIOS.xcodeproj` — fullscreen landscape playback.
**Reference**: `elevated_8000.avi` — high-quality AVI of the original running natively.
**Source**: `~/Downloads/mtt_iq_Elevated/` — upstream source release by iq/Puryx/Mentor.

---

## Architecture

### 3-Pass Metal Renderer

**Pass 1 — G-buffer** (`terrainVert` + `gbufferFrag`):
- Flat XZ grid (512×512, scale=104 units = ±52) displaced by FBM terrain height in vertex shader
- Outputs world-space position to `gbufWorldPos` (rgba32float) — w=1.0 flags geometry hit

**Pass 2 — Deferred shading** (`deferredFrag`):
- Full-screen quad reads G-buffer
- Terrain: normal + FBM color + sky lighting
- Water: planar reflection with animated normals
- Sky: FBM clouds + sun halo + cloud bands (light beams)
- Fog: exponential `exp(-0.042*t)` distance fog

**Pass 3 — Post-processing** (`postFrag`):
- Motion blur (16 samples along reprojected vector)
- Gamma + brightness/contrast from sync params
- Vignette, chromatic aberration, film grain

### Uniform Layout (`q[0..15]`)

| Index | Content | Scale formula |
|-------|---------|---------------|
| q[0]  | camSeedX, camSeedY, camSpeed, camFov | /256, /256, /4096, /96 |
| q[1]  | camPosY, camTarY, sunAngle, waterLevel | /64, (raw-128)/4, /32, (raw-192)/128 |
| q[2]  | season, brightness, contrast, terScale | /256, (raw-128)/128, /128, (raw-128)/128 |
| q[3]  | sunDir.x, sunDir.y=0.3125, sunDir.z, time | cos/sin(sunAngle) |
| q[4]  | camPos.xyz from m1Camera, w=1 | world-space float3 |
| q[5..12] | instrument sync for 8 light beams | samples since last note |
| q[13..15] | unused |

### Camera Formula (m1 shader port)

CPU-side `m1Camera(xdot:)` replicates the HLSL pixel shader that renders to a 2×1 D3D9 RT:
- `xdot = VPOS.x`: 0 → camPos, 1 → camTarget
- `o` starts at `(camSeedX + xdot*0.37, camSeedY + xdot*0.37)`
- 8 noise texture samples → cx, cz (camera XZ path)
- `cy = terScale * fbm3(cx,cz) + camPosY + camTarY * xdot`
- Jitter: 3 separate `cpuNo(o).x` calls with `o += 0.1` increments

### Instrument Sync (Light Beams)

`q[5+i].x` = "sample position of last note for beam i", computed by scanning channel 2 of the music sequence from beat 0 to current beat. The shader uses `exp(-q[5+i].x * 0.0002)` for beam brightness.

Exact port of `demo_deb.cpp` DemoEffect() lines 184-200:
```c
int d = position;
for (int i = 0; i < 8; i++) sync[i] = float(d);
int r = 0;
do {
    int beat = r >> 4;
    if (beat >= NUM_ROWS) break;
    int pat = sequence_data[NUM_ROWS*2 + beat];
    int note = pattern_data[(pat<<4) | (r&0xF)];
    if (note) sync[note & 7] = float(d);
    r++;
    d -= MAX_NOTE_SAMPLES;  // 5210 samples per step
} while (d >= 0);
```
Exposed as `elevated_instrument_sync(position, sync_out)` in CSynth.

---

## Critical Fixes Applied

### Fix 1: FBM Matrix Rotation (Major visual fix, 2026-03-23)

**Problem**: HLSL `float2x2(a,b,c,d)` is row-major; Metal MSL is column-major. Same constructor args produce a transposed matrix.

**HLSL** (row-major): `float2x2(1.6,-1.2, 1.2,1.6) * p` = (1.6px - 1.2py, 1.2px + 1.6py)

**Wrong Metal** (col-major same args): gives (1.6px + 1.2py, -1.2px + 1.6py) — WRONG rotation

**Fix in `Shaders.metal`** (fbm function):
```metal
// Before (wrong):
p = float2x2(1.6,-1.2,1.2,1.6) * p;
// After (correct — transposed constructor):
p = float2x2(1.6,1.2,-1.2,1.6) * p;
```
This affects ALL fbm calls: terrain height, normals, sky, water normals.

### Fix 2: Camera Jitter — Three Separate cpuNo Calls

**Problem**: Originally misread as one `cpuNo` call returning `.xyz`. HLSL uses scalar implicit truncation: `c.x += float3 → c.x += float3.x`.

**Correct HLSL** (from `idata.cpp`):
```hlsl
c.x += .002*no(o+=.1);   // no() returns float3, HLSL takes .x implicitly
c.y += .002*no(o+=.1);
c.z += .002*no(o+=.1);
```

**Correct Swift**:
```swift
o += SIMD2(repeating: q3.w * 0.5)
o += SIMD2(repeating: 0.1); cx_ += 0.002 * cpuNo(o).x
o += SIMD2(repeating: 0.1); cy  += 0.002 * cpuNo(o).x
o += SIMD2(repeating: 0.1); cz_ += 0.002 * cpuNo(o).x
```

### Fix 4: Camera xdot — Integer VPOS, Not Pixel Centers (2026-03-24)

**Problem**: m1Camera was called with `xdot: 0.5` (camPos) and `xdot: 1.5` (camTarget), treating D3D9 VPOS as pixel centers. But D3D9 VPOS for this hardware/driver gives integer pixel indices: 0 for pixel 0, 1 for pixel 1.

**Evidence**: `idata.cpp` line 108 comment: `// camera shader - x.x = 0 for cam  x.x = 1 for target`

**Impact**: When `camTarY_raw = 32` (the default at t < ~16s), `q1.y = (32-128)/4 = -24`. With xdot=0.5, camera Y gets `+q1.y*0.5 = -12`, placing the camera ~12 units underground. All rays pointed downward → miss terrain entirely → pure white sky rendered. This caused fully white/overexposed frames at t=5s, t=17s, and the entire early part of the demo.

**Fix in `Renderer.swift`**:
```swift
// Before (wrong — pixel centers):
let camPos    = m1Camera(xdot: 0.5)
let camTarget = m1Camera(xdot: 1.5)

// After (correct — integer VPOS):
let camPos    = m1Camera(xdot: 0.0)
let camTarget = m1Camera(xdot: 1.0)
```

**Result**: All key timestamps now show correct terrain. t=5 (mountains + water), t=17 (dramatic mountains), t=48 (mountains), t=132-136 (light beams) all match reference closely.

### Fix 3: Instrument Sync (Light Beams, 2026-03-24)

**Problem**: Used a linear approximation `base + cloudTimer` for q[5..12], not music-driven. Light beams never flash on beats.

**Fix**: Implemented `elevated_instrument_sync()` in CSynth (synth.c + synth.h) that exactly ports the DemoEffect() beat-scan algorithm. Called from `Renderer.updateUniforms()`. Position clamped to `[0, ELEVATED_TOTAL_SAMPLES]` to prevent Int32 overflow during initialization.

---

## Original Demo Architecture (from source code)

### Shader Pipeline (HLSL)
- **m0** (vertex): FBM terrain displacement
- **m1** (pixel on 2×1 RT): camera position + target computation
- **m2** (pixel): G-buffer pass (not used in our port — merged into vertex output)
- **m3** (pixel): deferred shading
- **m4** (pixel): post-processing

### constructMatrix() — Critical Detail
```cpp
D3DXMatrixLookAtLH(mat, pptr[0].xyz, pptr[1].xyz, up);
D3DXMatrixPerspectiveFovLH(&tmp, camFov, aspect, 0.03125f, 256.0f);
D3DXMatrixMultiply(mat, mat, &tmp);  // mat = View * Proj
D3DXMatrixInverse(..., mat, mat);     // INVERT before uploading to m3!
```
The m3 pixel shader receives VP^{-1}, not VP. Our port handles this with `uniforms.v` (VP) and `uniforms.vi` (inverse VP).

### Terrain Mesh — Original vs Port
- **Original**: `D3DXCreatePolygon(52.0f, 4)` + `D3DXTessellateNPatches(512)` → diamond, ~1M triangles
- **Port**: 512×512 regular grid, scale=104 (±52 units) — much closer density, but still different topology from the tessellated diamond

### Noise Texture
- Format: D3DFMT_R16F (stored as R32F in Metal)
- Size: 256×256
- Generator: LCG `seed = seed * 16307 + 17; return (int16)(seed>>14) / 32768.0`
- Sampler: D3DTEXF_POINT (nearest-neighbor) — Metal: `filter::nearest`

### Camera Roll
```cpp
// From constructMatrix():
const float up[3] = { sinf(pptr->w), cosf(pptr->w), 0.0f };
// pptr[0].w = 0.3 * cos(t * 2) ... times camSpeed in our port
```
**Swift**: `let roll = 0.3 * cos(t * camSpeed * 2)`

---

## Fix 5: Back-Face Culling Direction (2026-03-24)

**Problem**: Added `enc.setCullMode(.back)` to fix terrain-from-below, but this caused "mangled" terrain — flat horizontal slabs cutting through the scene.

**Root cause**: Metal and D3D9 have opposite handedness for front-face determination after the viewport Y-flip.

- D3D9 default `D3DCULL_CCW`: culls CCW triangles in screen space (Y-down) = CW in NDC (Y-up).
  → D3D9 renders triangles that are **CCW in NDC (Y-up)** = CW in screen (Y-down).
- Metal `.setCullMode(.back)` + default `.counterClockwise` front face: culls CW in framebuffer (Y-down) = CCW in NDC (Y-up).
  → Metal with `.back` renders triangles that are **CW in NDC (Y-up)** = CCW in framebuffer.

Our terrain mesh top-surface triangles are **CCW in NDC** (correct, matches D3D9 front face). With `.back` culling in Metal, these get culled as "back faces." Only the undersides (CW in NDC) are rendered — exactly backwards.

**Fix in `Renderer.swift`** (G-buffer encoder):
```swift
// Before (wrong — culls terrain tops):
enc.setCullMode(.back)
// After (correct — matches D3D9 D3DCULL_CCW):
enc.setCullMode(.front)
```

With `.front` culling: Metal culls CCW-in-framebuffer = CW-in-NDC = what D3D9 also culls. Both show terrain tops, hide bottoms.

---

## Fix 6: Water Seam — Higher Density Plus Alternating Quad Diagonals (2026-03-24)

**Problem**: A hard diagonal seam appeared in reflective water around `00:01:21` and again at later camera angles such as row `175`. The artifact presented as a large straight-edged slab, clearly geometric rather than post-process driven.

**Root cause**: The port shades water from a proxy terrain mesh stored in the G-buffer. A regular grid with a fixed triangle split direction leaves long planar interpolation features in screen space. Raising density from `256` to `512` helped, but some seam cases remained because the grid still split every quad along the same diagonal.

**Evidence**:
- `256` grid: severe slab artifact
- `512` grid: major improvement, but not complete
- `1024` grid: further improvement, but still residual seam at row `175`
- alternating quad diagonals: reduces the fixed-direction slab pattern
- `1024` + alternating diagonals: best visual result among the tested pragmatic fixes

**Decision**: Keep the pragmatic visual fix instead of pursuing a larger mesh-topology rewrite. This is not the most source-faithful option, but it removes the visible artifact in the tested bad shots and matches demoscene priorities better.

**Fix**:
- terrain grid density increased to `1024`
- terrain quad split direction alternates by checkerboard parity instead of using one global diagonal

**Code shape in `Renderer.swift`**:
```swift
let (vb, ib, ic) = makeTerrainMesh(device: device, size: 1024, scale: 104)
```

and the index generation alternates the triangle split:

```swift
if ((x + z) & 1) == 0 {
    indices += [i, i+1, i+row, i+1, i+row+1, i+row]
} else {
    indices += [i, i+1, i+row+1, i, i+row+1, i+row]
}
```

---

## Demo Timing (Exact, from Sync Data)

All times computed from `row = position / 20840`, `position = t × 44100`.

| Event | Row | Time (s) | SMPTE (60fps) |
|-------|-----|----------|---------------|
| Fade from black starts | 0 | 0.000 | 00:00:00:00 |
| Fade from black ends | 8 | 3.778 | 00:00:03:47 |
| Fade to black starts | 424 | 200.37 | 00:03:20:22 |
| Screen fully black | 448 | 211.71 | 00:03:31:43 |
| Audio ends | — | 216.97 | 00:03:36:58 |

The dark ending has two phases:
- **Fade** (rows 424→448): 11.34 seconds — `imgBrightness` linearly goes 100→0 (`brightness` goes -0.22→-1.0)
- **Pure black tail** (row 448→audio end): 5.26 seconds — brightness stays at -1.0
- **Total dark period**: 16.6 seconds (user guessed "~15 seconds" — close)

The original AVI at 3:35=215s sits between the visual blackout (211.71s) and audio end (216.97s), suggesting the AVI was trimmed ~4s after the screen went black.

**Code change**: All `217.0` hardcodes replaced with `kDemoDuration = Double(ELEVATED_TOTAL_SAMPLES) / 44100.0 = 216.967s`. Computed constant eliminates drift.

---

## Known Remaining Issues (as of 2026-03-25)

### terScale Formula — Resolved (2026-03-25)
Confirmed `(raw-128)/128` by hardware capture. See Parallels section above.

### Camera Path — Minor Residual Drift
After the xdot fix, the camera is broadly correct — mountains are visible at all key timestamps and composition is close. Remaining drift is subtle: slightly different framing at specific moments (e.g. t=136). Likely sources:

1. Terrain mesh topology differences (tessellated diamond vs regular grid) still cause slightly different normal interpolation and perceived shape at some XZ positions
2. Minor FBM float precision differences between HLSL and MSL (hard to eliminate without the original GPU pipeline)

### Light Beams — Verified Working (2026-03-24)
Instrument sync confirmed working after full capture. Beams appear synced to music at t=132-136. Light beam at t=132 appears ~1 frame early in reference vs our port — likely a ≤1-step offset in the sync scan. Functionally correct.

### Fix 7: Fade from Black — Scene Color Buffer LDR (2026-03-24)

**Problem**: With `sceneColor` as `rgba16Float` (HDR), the sun halo term could push sky pixels to ~1.55 linear. After `pow(1.55, 0.45) × 1.17 − 1.0 ≈ 0.42`, these pixels were visible even at brightness=−1.0, so the fade from black leaked bright sky at t=0.

**Fix**: Change `sceneColor` from `rgba16Float` to `bgra8Unorm`. The deferred pass now clamps to [0,1] before the post-pass reads it. Maximum possible output at brightness=−1.0 is `pow(1.0, 0.45) × 1.17 − 1.0 = 0.17`, which is dark enough that the fade appears clean.

**Why this matches D3D9**: The original demo used an A8R8G8B8 (8-bit UNORM) intermediate render target — exactly LDR. Our earlier `rgba16Float` choice added HDR that the original never had, breaking the fade math.

**Code change in `Renderer.swift`**: `sceneColor` pixel format changed in both `buildPipelines` and `rebuildOffscreen`.

### Tooling: Exact Cross-Branch Frame Capture (2026-03-24)

Added `tools/capture_branches.sh` plus `make branch-frame` for deterministic image comparisons across branches using temporary `git worktree`s.

Purpose:
- render the exact same timestamp on multiple branches
- avoid manual branch switching and pause/seek drift
- keep the current checkout untouched

Example:
```sh
make branch-frame T=81.383333 BRANCHES="main feature/foo feature/bar"
```

Outputs:
- PNGs in `/tmp/elevated_branch_frames/`
- `frame_<time>_summary.txt` with branch, commit, and SHA-256 per capture

### Build Versioning — Date+Time Stamp (2026-03-24)

The app bundle uses a date+time versioning scheme that stamps itself at build time:

| Key | Format | Example |
|-----|--------|---------|
| `CFBundleShortVersionString` | `YY.M.DD` | `26.3.24` |
| `CFBundleVersion` | `HH.MM` | `18.33` |

The About panel (`⌘+About Elevated`) shows **"Version 26.3.24 (18.33)"**.

Both are valid macOS version formats (sequences of up to three non-negative integers). The short version is stamped per-day; the build number is stamped per-minute — so every `make app`/`zip`/`pkg` run produces a unique, human-readable version that encodes exactly when the binary was assembled.

**Makefile implementation** — shell fragment inside the `app` target:
```makefile
shortver=$$(printf '%s.%d.%s' $$(date +%y) $$(date +%-m) $$(date +%d)); \
buildver=$$(date +%H.%M); \
/usr/libexec/PlistBuddy \
    -c "Add :CFBundleShortVersionString string $$shortver" \
    -c "Add :CFBundleVersion string $$buildver" \
    ...
```

`%-m` strips the leading zero from the month (March → `3`, not `03`).

### Color/Tone Differences
Our capture is slightly warmer/more orange-tinted at some timestamps vs the cooler blue reference. Likely a minor difference in sun direction or color computation. Low priority.

---

## Key File Locations

| File | Purpose |
|------|---------|
| `ElevatedMac/ElevatedMac/Shaders.metal` | All Metal shaders |
| `ElevatedMac/ElevatedMac/Renderer.swift` | Renderer, camera math, uniform setup |
| `ElevatedMac/ElevatedMac/Sync.swift` | Rocket-sync track data (all 12 params) |
| `ElevatedMac/CSynth/synth.c` | C port of synth.asm (music synthesis + instrument sync) |
| `ElevatedMac/CSynth/include/synth.h` | CSynth public API |
| `tools/d3d9log/d3d9log.c` | D3D9 shader-constant logger DLL (Parallels, KERNEL32-only, vtable entry patch) |
| `tools/extract_ref.sh` | Extract 1fps frames from elevated_8000.avi → /tmp/elevated_ref/ |
| `tools/compare.sh` | Side-by-side comparison with ffmpeg hstack |
| `Makefile` | `make run/debug/capture/ref/compare` |

---

## Wine D3D9 Extraction Attempt (Blocked — Superseded by Parallels)

Tried to extract ground-truth camera data from `elevated_1920_1080.exe` under Wine by replacing `d3d9.dll` with a vtable-patching proxy. The existing `~/.wine/drive_c/windows/system32/d3d9.dll` is a **custom 12KB stub** (`d3d9_stub.c`) that:
1. Intercepts D3D9 and provides a **fake device** (no GPU rendering)
2. Dumps `d3d_code.bin` and `synth_code.bin` from the exe
3. The demo's m1 shader never runs (no real pixel shader execution)

**Conclusion**: Ground-truth extraction via Wine is not viable. Superseded by the Parallels approach below.

---

## Ground-Truth Extraction via Parallels D3D9 Logging DLL (2026-03-25)

### Motivation

The terScale formula in the port — `(raw-128)/128` vs `raw/128` — could not be confirmed from source comments alone. The only way to get definitive ground truth was to capture the actual shader constant values (`q[0..4]`) from the original `elevated_1920_1080.exe` running under real Direct3D9.

### Setup

`elevated_1920_1080.exe` runs natively in a Parallels Windows VM. The Mac `~/Desktop` is mounted as the Windows Desktop (Parallels shared folder), so files dropped there are immediately visible on both sides.

The demo is a Crinkler-packed executable, which means:
- No PE import table — Crinkler resolves all imports at runtime via `LoadLibraryA` / `GetProcAddress`
- `d3d9.dll` is loaded from the **executable's directory** first (standard Windows DLL search order)
- Placing a custom `d3d9.dll` next to the exe is sufficient to intercept all D3D9 calls

### DLL Implementation (`tools/d3d9log/d3d9log.c`)

A 32-bit Windows DLL cross-compiled on Mac with `i686-w64-mingw32-gcc`. Key design decisions:

**Vtable entry patching (not pointer replacement)**: The original design replaced `d3d->lpVtbl` with a heap-allocated copy. This crashed inside `IDirect3D9::CreateDevice` — the D3D9 runtime apparently validates that the vtable pointer still points into its own module's read-only memory. The correct technique:

```c
// Make the real vtable temporarily writable, patch the entry directly
IDirect3D9Vtbl *vt = d3d->lpVtbl;
DWORD old;
VirtualProtect(vt, sizeof(IDirect3D9Vtbl), PAGE_READWRITE, &old);
orig_CreateDevice = vt->CreateDevice;
vt->CreateDevice  = hook_CreateDevice;
VirtualProtect(vt, sizeof(IDirect3D9Vtbl), old, &old);
```

`d3d->lpVtbl` is never changed — D3D9's internal validation sees the same pointer as always.

**No CRT dependency**: The MinGW-w64 toolchain defaults to UCRT (`api-ms-win-crt-*`), which may not be present in minimal VMs. Built with `-nostdlib`, providing `_DllMainCRTStartup` manually and using only KERNEL32 + a dynamically-loaded `msvcrt.dll` for `sprintf` (float formatting). The resulting DLL imports only `KERNEL32.dll`.

**File I/O**: `CreateFileA` / `WriteFile` / `CloseHandle` — no stdio. The CSV and debug log are written next to the exe (= Windows Desktop = Mac `~/Desktop`).

**Launching from Mac**: `open ~/Desktop/elevated_1920_1080.exe` triggers Parallels to run the exe, no manual Windows interaction needed.

### Results — `elevated_q.csv`

~12,700 frames (~7 minutes) captured. The `q[2].w` column (terScale) confirmed the formula by direct comparison:

| Sync row | Raw value | `(raw-128)/128` | Captured `q[2].w` |
|----------|-----------|-----------------|-------------------|
| 0        | 200       | **0.562500**    | 0.562500 ✓        |
| 26       | 140       | **0.093750**    | 0.093750 ✓        |
| 120      | 255       | **0.992188**    | 0.992188 ✓        |

All three match exactly. **The formula `(raw-128)/128` is confirmed 100% correct.**

The alternative `raw/128` (which would map raw=200 → 1.5625, raw=140 → 1.09375) does not appear anywhere in the capture — ruling it out completely.

### Negative terScale — Intentional Effect at t≈2:35

Row 328 has raw=20 → terScale = `(20-128)/128 = −0.84375`. This runs from t≈155s to t≈170s. The negative value inverts the terrain height (mountains become valleys), producing a dramatic visual inversion. This is intentional demo effect — not a bug in the formula or the port.

The "broken terrain slabs" seen previously at t=2:00 were caused by testing the wrong `raw/128` formula (which gave terScale≈2 and drove the camera underground), not by the negative-terScale region.

### Status After Confirmation

`Renderer.swift:475` already contains the correct formula:
```swift
let terScale = (syncParam(position, Sync.terScale) - 128.0) / 128.0
```

No code change required. The formula is now proven correct by hardware capture from the original exe.

---

## Comparison Infrastructure

```bash
make ref       # Extract 1fps from elevated_8000.avi to /tmp/elevated_ref/
make capture   # Run and save 1fps to /tmp/elevated_cap/ (runs full 215s, Cmd-Q to stop)
make compare   # Side-by-side all matching frames in Preview
make compare-one T=42  # Single frame
make compare-range T0=30 T1=60  # Range of seconds
```

Reference frames: `/tmp/elevated_ref/ref_XXXX.png` (1280×720)
Capture frames: `/tmp/elevated_cap/cap_XXXX.png` (1920×1080, scaled to 1280×720 for comparison)

---

## GitHub Migration (2026-03-24)

The repository was published to a dedicated private GitHub remote:

- `git@github.com:thoroncode/elevated.git`

The local repository is configured to keep project-specific GitHub settings inside `.git/config`:

- repo-local commit name: `Petri Koistinen`
- repo-local visible commit address: `thoron@iki.fi`
- repo-local SSH command selects the dedicated key for this repository

The private key is kept outside the repository under `~/.ssh/`. No credential material is stored in tracked files.

Normal workflow:

```bash
git add ...
git commit -m "..."
git push
```

This keeps authorship stable for this project while leaving other repositories on the machine free to use different Git identities.

---

## Key Visual Timestamps to Verify

| Time | Expected | Status |
|------|----------|--------|
| 0:00-0:03 | Fade from black | Not verified |
| 0:05 | Mountains top-to-bottom, water at bottom | **Fixed** (xdot fix) — close match |
| 0:17 | Dramatic mountain shot | **Fixed** — very close match |
| 0:48 | Mountains | **Fixed** — nearly identical |
| 1:32-1:37 | **Light beams synced to music** | **Fixed** — beams visible and music-synced |

---

## iPadOS Port (2026-03-25)

### Architecture

Package restructured into three targets inside `elevated/`:

| Target | Platform | Contents |
|--------|----------|----------|
| `CSynth` | macOS + iOS | C synth, `-march=native` macOS only |
| `ElevatedCore` | macOS + iOS | Renderer, Sync, SynthPlayer, Shaders.metal — all `public` |
| `ElevatedMac` | macOS | AppDelegate, main.swift — AppKit, debug/transport/menus |
| `ElevatedIOS` | iOS | AppDelegate, ViewController — UIKit, `#if canImport(UIKit)` |

iOS app shell: `ElevatedIOS.xcodeproj` + `App/main.swift` + `App/Info.plist`.
iPad-only (TARGETED_DEVICE_FAMILY=2), landscape-locked, iPadOS 26.0 deployment target.

### macOS-specific code in ElevatedCore (`#if os(macOS)`)

- `DebugOverlay` class (NSTextField, NSColor, NSFont, NSView)
- `debugOverlay` property + `installDebugOverlay(in:)`
- `captureNextFramePath`, `maybeCaptureFrame`, `saveDrawable`, `savePNG` (NSBitmapImageRep)
- `emitDebug()` call in `draw()`
- `NSApplication.shared.terminate(nil)` — replaced with `pause()` on iOS

### Metal Library Loading (critical — three build configurations)

Xcode compiles `Shaders.metal` to `default.metallib` inside `elevated_ElevatedCore.bundle`.
The CLI `swift build` keeps it as source in the same bundle. `Renderer.buildPipelines` tries:

1. `Bundle.module.url(forResource: "default", withExtension: "metallib")` — **Xcode iOS/Mac builds**
2. `device.makeDefaultLibrary()` — **Mac .app via Makefile** (Shaders.metal copied to Contents/Resources)
3. `Bundle.module` / `Bundle.main` source + `device.makeLibrary(source:)` — **Mac CLI `swift build`**

If you skip step 1 and only try source compilation, the iOS build crashes with `EXC_BREAKPOINT`
in `buildPipelines` because the `.metal` source isn't in the bundle — only the compiled `.metallib` is.

### AVAudioSession (iOS only)

Must call before any playback:
```swift
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
try AVAudioSession.sharedInstance().setActive(true)
```
Done in `ViewController.activateAudioSession()` before synthesis starts.

### Build commands

```bash
# macOS
swift build -c release --package-path elevated --product ElevatedMac

# iOS simulator (resolve once, then build)
xcodebuild -project ElevatedIOS.xcodeproj -resolvePackageDependencies
xcodebuild -project ElevatedIOS.xcodeproj -scheme Elevated \
    -destination "id=<SIMULATOR_UDID>" -configuration Debug build

# Install + launch on simulator
xcrun simctl install <UDID> path/to/Elevated.app </dev/null
xcrun simctl launch <UDID> org.rgba.elevated </dev/null

# Physical iPad (after pairing in Xcode)
xcodebuild -project ElevatedIOS.xcodeproj -scheme Elevated \
    -destination "platform=iOS,name=pk-ipad" -configuration Debug \
    -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> path/to/Elevated.app
xcrun devicectl device process launch --device <UDID> org.rgba.elevated
```

**Note:** First run on a physical device requires trusting the developer profile:
Settings → General → VPN & Device Management → [your Apple ID] → Trust.
With a free Apple ID the profile expires after 7 days and the app must be reinstalled.

### End-of-demo behaviour (iOS)

On macOS the app calls `NSApplication.shared.terminate(nil)` when the demo ends.
On iOS: the renderer pauses on the last frame, then `Renderer.onDemoEnd` fires and
`ViewController` calls `exit(0)` after a 5-second hold.

### App icon

`App/Assets.xcassets/AppIcon.appiconset/icon_1024.png` — 1024×1024 resized from
`assets/icon_source.png` (the same frame used for the macOS `.icns`).
Xcode picks it up via `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in the target
build settings.

### Status — confirmed working

- iPad Pro 13-inch M5 (iPadOS 26.2 simulator) — synthesis ~1.1 s, full playback, exits after show
- iPad Pro 12.9-inch 6th gen / iPad14,6 (physical device, iPadOS 26.x) — full playback confirmed

---

## 2026-03-26 — Codex checkpoint: 4K prototype + platform target updates

This checkpoint was first saved as commit `9cea445` (`wip: checkpoint 4k prototype and platform updates`).
Follow-up journal work was moved onto Codex branch `task/codex-4k-journal` in its own worktree to keep later edits off the integration checkout.

### 4K prototype work captured in the checkpoint

- Added `elevated4k/` as a size-reduction prototype for macOS.
- Architecture is deliberately minimal:
  - one Objective-C source file (`main.m`)
  - `CAMetalLayer` instead of MetalKit
  - runtime-compiled inline MSL from generated `shaders.h`
  - shared synth from `../elevated/CSynth`
  - `AudioUnit` output instead of the Swift app/audio stack
- Added top-level `make` entry points for the prototype:
  - `make 4k`
  - `make 4k-shaders`
  - `make 4k-size`
  - `make 4k-run`
  - `make 4k-clean`
- Added `.gitignore` entry for `elevated4k/build/`.

### Current measured result

`make 4k-size` produced a stripped binary of `70,440` bytes on this machine at checkpoint time.
This is still far from a true 4096-byte result; the current work is a dependency/runtime-overhead reduction prototype, not a final packed intro.

### Other same-day changes bundled into the checkpoint

- `elevated/Package.swift` was updated to target `26.0` for macOS, iOS, tvOS, and visionOS.
- `ElevatedVision.xcodeproj` was updated to use `XROS_DEPLOYMENT_TARGET = 26.0`.
- The top-level `Makefile` app packaging path now writes `LSMinimumSystemVersion = 26.0`.

### Practical note for future sessions

The latest implementation focus before credits ran out was the 4K binary-size-reduction path.
If resuming optimization work, start from the `elevated4k/` prototype rather than the higher-level Swift app targets.

---

## 2026-03-27 — 4K binary reduction: xz pipeline, Grammar A packer, __DATA_CONST elimination

### Starting point

Binary at start of session: 70,440 bytes (from prior checkpoint). Target: ≤ 4,096 bytes.

### MSL shader minifier: regex → tokenizer

`strip_shaders.py` was rewritten from a line-by-line regex approach to a proper tokenizer using `re.compile` with named groups (`id`, `num`, `attr`, `op`, `pun`, `ws`). The old regex missed spaces in cases like `float3(...) + .1` because the `)` in a prior pass consumed the trailing space, leaving `+ .1` — the leading `.` looked like a member accessor so no space was inserted. The tokenizer is deterministic: only insert a space between two adjacent "word-like" tokens (identifiers or numbers), never around punctuation or operators. Also optimises float literals (`0.5` → `.5`, `1.0` → `1.`).

### Eliminating __DATA_CONST: 50,176 → 33,792 bytes

The binary was at 50,176 bytes before this step (3 Mach-O pages: __TEXT×2 + __DATA_CONST + __DATA + __LINKEDIT). The goal was to collapse to 2 pages by eliminating __DATA_CONST.

**Linker flag**: `-Wl,-no_data_const` moves GOT (88B), `__const` (16B), and `__objc_imageinfo` (8B) from __DATA_CONST into __DATA. This flag alone was not sufficient — the large data arrays (`kMSLSource`, music tables) stayed in `__TEXT,__const` because the linker promotes `static const` to read-only.

**Root cause**: `static const` arrays go to `__TEXT,__const`, not `__DATA`. Simply removing `const` was also insufficient — ld64 with `-Os` still promoted them. Fix: add `__attribute__((section("__DATA,__data")))` to each large array.

**Arrays moved to __DATA**:
- `kMSLSource[]` in `shaders.h` (4,336 bytes) — changed to `static char` + section attribute
- `kPatternDataPacked[]`, `kSequenceDataPacked[]`, `kMachineTreeDataPacked[]` in `music_tables_packed.h` (2,088 bytes total) — changed from `static const uint8_t` to `static uint8_t`
- `kSyncData[]`, `kSyncCount[]`, `kSyncOffset[]` in `main.m` — added section attribute

**Result**: 50,176 → 33,792 bytes. Segments now: `__TEXT` (16,384, 1 page) + `__DATA` (16,384, 1 page) + `__LINKEDIT` (1,024). The third segment (`__DATA_CONST`) is gone.

### xz compression pipeline

`compare_compression.py` benchmarks all xz/lzma option combinations: presets 1–9, `-9e`, ARM64 BCJ filter (`--arm64`), LZMA2 tuning (`mf=bt4`, `nice=64/128/273`, `lc=2/3/4`, `pb=0`). Key discovery: the ARM64 BCJ filter (branch-call-jump rewriter) reduces the binary from ~34% ratio to ~21% ratio by normalising all `bl`/`b`/`adrp` instructions before LZMA2, dramatically improving cross-reference matches.

**Best flags**: `--arm64 --lzma2=preset=9e,mf=bt4,nice=64,depth=0` → **10,616 bytes** (31.4% of 33,792).

**Shell stub** (originally `make_pack.py`, now inline in Makefile): 54 bytes. `#!/bin/sh\ntail -c+55 $0|xz -d>_&&chmod +x _&&exec ./_` — fixed offset, no convergence loop, no mktemp, no cleanup. `exec` replaces the shell process so the binary payload is never interpreted as shell commands after exit. Total packed: **10,662 bytes**.

**Gotchas**:
- `--arm64` is incompatible with plain `-N` preset syntax → must use `--lzma2=preset=N`
- `--arm64` is incompatible with `--format=lzma` (LZMA1 doesn't support BCJ filters)
- `lc + lp` must not exceed 4; `lc=4, lp=1` is rejected by xz
- `xz --stdout` pipes result to stdout — avoids the `file.raw.xz` naming issue when using temp files

**Pre-compressing the shader is worse**: empirically tested — shader separately compresses to 1,780 bytes but within the whole binary contributes only ~1,636 bytes (cross-boundary LZMA matches save 144 bytes). Pre-compressing kills those matches: whole-binary xz result is 184 bytes larger.

### Grammar A custom packer (sub-160-byte ARM64 decoder)

Designed a minimal LZ format with byte-aligned tokens (no bit reader → smallest possible decoder):

```
0xxxxxxx   LITERAL run : count = x+1 (1–128), then count raw bytes
10lllooo   MATCH       : length = lll+3 (3–10), offset = (ooo<<8)|next (1–2047, 11-bit)
11llllll   RLE         : count = l+2  (2–65),  then 1 fill byte
```

Python encoder in `tiny_pack.py`. ARM64 decoder in `decoder_a64.s`: **32 instructions = 128 bytes** (measured with `otool -tv`; initial estimate was 136 bytes).

**Compression result**: 33,792 → 16,164 bytes payload (47.8% ratio).

**Verdict**: Grammar A never beats xz+shell stub. xz achieves 31.4% vs Grammar A's 47.8%. Even though Grammar A's decoder (128B) is far smaller than the xz approach's overhead, the ratio difference dominates at all tested sizes. Break-even would require Grammar A to have a better ratio than xz, which it doesn't. `tiny_pack.py bench` confirms this with exact numbers.

**libcompression.framework**: Also evaluated — COMPRESSION_LZMA (LZMA1) is available by default on all macOS (no xz dependency), but it doesn't support the ARM64 BCJ filter. This makes it 619 bytes worse than xz+stub due to the ratio penalty. Not viable.

### Selector string audit (next targets)

`__TEXT,__cstring` is 1,660 bytes — the dominant remaining __TEXT cost. The longest string that can be shortened:
- `texture2DDescriptorWithPixelFormat:width:height:mipmapped:` (59 bytes) — used 4× → replace with `new` + individual property setters (`setPixelFormat:`, `setWidth:`, `setHeight:`) which are all already in the binary or are short. Saves ~38 bytes in cstring.
- `activateIgnoringOtherApps:` (27 bytes) — deprecated macOS 14+, replacement is `activate` (9 bytes). Target is macOS 26. Saves ~18 bytes.

### File inventory

| File | Change |
|------|--------|
| `elevated4k/strip_shaders.py` | Full rewrite: tokenizer-based minifier |
| `elevated4k/compare_compression.py` | New: ranks all xz option combos by size |
| `elevated4k/make_pack.py` | New: self-extracting xz shell launcher |
| `elevated4k/tiny_pack.py` | New: Grammar A encoder/decoder/benchmark |
| `elevated4k/decoder_a64.s` | New: 128-byte ARM64 Grammar A decoder |
| `elevated4k/Makefile` | Added `-no_data_const`, hexdump/pack/bench targets |
| `elevated4k/main.m` | Arrays moved to __DATA with section attribute |
| `elevated4k/shaders.h` | `static char` (was `static const char`) |
| `elevated/CSynth/music_tables_packed.h` | Non-const table declarations |

---

## 2026-03-28 — Fix both builds: procedural terrain draw + 4K window visibility

Both the Swift debug build (`make debug`) and the 4K build (`make 4k-run`) were broken after the
procedural-terrain vertex shader was introduced in an earlier session. This session fixed both.

### Bug 1 — Swift debug build: indexed draw broken by procedural vertex shader

**Symptom**: Black triangular artifacts over diagonal bands of terrain; terrain was clearly wrong.

**Root cause**: `Renderer.swift` was calling `drawIndexedPrimitives` with a prebuilt index buffer
(`terrainIBuf`). The vertex shader `a()` (in `Shaders.metal`) computes terrain XZ position purely
from `[[vertex_id]]`, expecting sequential IDs 0, 1, 2, 3 … . With indexed drawing, `vertex_id`
receives index-buffer values (0, 1, 1024, 1025, …), completely breaking the procedural grid math.

**Fix** (`elevated/ElevatedCore/Renderer.swift`):
- Removed `enc.setVertexBuffer(terrainVBuf, …, index: 0)` — no vertex buffer needed
- Changed `drawIndexedPrimitives(…)` → `drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 1023 * 1023 * 2 * 3)`

The prebuilt vertex and index buffers (`terrainVBuf`, `terrainIBuf`) were already populated in
`buildGeometry()` but are now unused; they remain allocated (no size impact on debug build) but
the draw call no longer references them.

### Bug 2 — 4K build (`make 4k-run`): audio plays, no window visible

**Symptom**: Audio played but no window or rendered content appeared.

Diagnostic added (`NSLog` in `renderFrame`): drawable size was non-zero (2624×1696 on the test
display) and frames 1 and 2 were logged — so the GPU was doing real work, PSOs compiled and ran
successfully. The issue was purely in window/compositor setup.

**Root causes (three separate problems)**:

1. **Layer-hosting order** — `setWantsLayer:YES` was called *before* `setLayer:` on the content
   view. AppKit documentation requires the opposite: set the layer first (`setLayer:`), then enable
   layer-hosting (`setWantsLayer:YES`). The reversed order caused AppKit to create its own default
   backing layer first; the Metal layer was then substituted but may not have been the actual
   compositor target.

2. **`[NSApp activate]` vs `activateIgnoringOtherApps:YES`** — when the binary is launched from a
   shell script/terminal (not via `open`), `[NSApp activate]` does not force the app to the front
   because another app (Terminal) is already active. `activateIgnoringOtherApps:YES` is required.

3. **Main thread run loop never pumped** — the render loop is a tight `while (gRunning) { renderFrame(); }` on the main thread. `makeKeyAndOrderFront:` schedules the window appearance but
   the actual display update requires at least one pass through the AppKit run loop. Without it,
   the window is in "pending show" state but never appears. Similarly, the CA compositor may need
   periodic run loop passes to composite the Metal layer content.

**Fixes** (`elevated4k/main.m`):
- Swapped `setLayer:` / `setWantsLayer:YES` to the correct layer-hosting order.
- Changed `activate` → `activateIgnoringOtherApps:YES`.
- Added `[NSApp finishLaunching]` before `makeKeyAndOrderFront:` to complete NSApp initialisation.
- Added `[[NSRunLoop mainRunLoop] runUntilDate: +0.1s]` after showing the window — pumps the
  run loop long enough for the window show event to be processed (window appears before audio gen).
- Added per-frame AppKit event drain inside the render loop (`nextEventMatchingMask:distantPast`)
  so the CA compositor stays active for the full playback duration.

**Also added** to `buildPipelines()`: proper error capture (`NSError **`) for
`newLibraryWithSource:options:error:` and all three `newRenderPipelineStateWithDescriptor:error:`
calls, with `NSLog` output on failure. Previously all errors were silently discarded via `NULL`.

### Makefile: `make clean` kills running binaries

Added `-killall ElevatedMac ElevatedMac4k ElevatedMac4k.run 2>/dev/null` as the first step of
the `clean` target. The `-` prefix tells make to ignore the non-zero exit when nothing is running.
This prevents "file busy" errors when doing `make clean 4k-run` while a prior run is still open.

---

## 2026-03-28 — 4K self-extracting stub: design, iteration, and minimum size

### Motivation

The prior `make_pack.py` Python script generated an 82-byte shell stub using `mktemp` for a safe
temp file and `xz -d` to decompress. Replacing it with an inline Makefile recipe and a tighter
stub reduces overhead and eliminates the Python dependency.

### Stub evolution

| Bytes | Stub | Notes |
|------:|------|-------|
| 82 | `t=$(mktemp);tail -c +83 "$0"\|xz -d>$t;chmod +x $t;$t;r=$?;rm $t;exit $r` | original `make_pack.py` |
| 57 | `tail -c +58 "$0"\|xz -d>_&&chmod +x _&&exec ./_` | fixed name, exec, quoted |
| 54 | `tail -c+55 $0\|xz -d>_&&chmod +x _&&exec ./_` | `tail -c+N` no space, unquoted `$0` |
| — | `tail -c+59 $0\|xzcat>_&&codesign -f -s- _&&./_` | **broken**: no `chmod +x`, codesign doesn't set execute bit |
| 71 | `tail -c+72 $0\|xz -d>_&&chmod +x _&&codesign -s - _&&exec ./_` | codesign added (AMFI requires it) |
| **62** | `tail -c+63 $0\|xz -d>_;chmod +x _;codesign -s- _;./_` | **current** — semicolons, merged `-s-`, drop exec |

### Why each byte in the final stub is mandatory

```
#!/bin/sh\n               10 bytes  kernel needs absolute interpreter path; no shorter shebang exists
tail -c+63 $0|xz -d>_    21 bytes  tail + xz are shortest available tools; _ is 1-char filename
;chmod +x _               11 bytes  macOS won't exec without execute bit — cannot skip
;codesign -s- _           15 bytes  AMFI kills unsigned binaries with SIGKILL — cannot skip on macOS 13+
;./_                       4 bytes  ./ required since . is not in PATH
\n                         1 byte   shell must see newline before binary payload starts
```

Total: **62 bytes**. This is the minimum for a working macOS self-extracting xz binary.

### Key decisions

- **`;` vs `&&`**: semicolons save 1 byte per separator (3 used). Error propagation doesn't matter
  for a demo — if any step fails the binary just won't run.
- **`codesign -s-`** (no space): `-s-` passes `-` as the identity argument to `-s` directly.
  Verified working; saves 1 char vs `-s -`.
- **No `exec`**: saves 5 bytes (`exec ` prefix). Without exec, the shell continues after `./_`
  exits and tries to interpret the compressed payload bytes as commands, producing terminal errors
  after the demo ends. Acceptable for a competition where the user quits early with Ctrl+C.
- **`tail -c+N` (no space)**: valid BSD tail syntax on macOS, saves 1 byte vs `tail -c +N`.
- **`_` as temp file**: 1-char filename, no `mktemp` overhead. Left on disk after exit.
  Safe for single-instance use (demo scene context).
- **Codesign required**: `make 4k-run` runs `ElevatedMac4k.run` which is pre-signed. The packed
  stub extracts to an unsigned binary — macOS AMFI sends SIGKILL immediately without a signature.
  Discovered by testing: `make 4k-pack-run` was killed instantly until `codesign -s- _` was added.
- **Fixed offset**: the stub length is self-consistent at exactly 62 bytes / offset 63. No
  convergence loop needed — the offset fits in 2 digits and the digit count doesn't change.

### `make 4k-pack-run`

New top-level target added alongside the existing `make 4k-run`:
- `make 4k-run` — runs `ElevatedMac4k.run` (stripped + pre-signed, no compression, fast for dev)
- `make 4k-pack-run` — packs with xz, runs the self-extracting `.4k` file (tests the final artifact)

Current packed size: **10,670 bytes** (target ≤ 4,096 bytes; main remaining work is binary reduction).

---

## 2026-03-28 — Live shader compare mode, and why the grain shortcut was rejected

### Goal

Evaluate whether the shared macOS Metal shader could be made smaller without changing the artistic
result to the human eye.

### What was built

- Added `make debug-compare`, which opens a split debug window with two synchronized renderers.
- Left side uses a preserved baseline shader (`ShadersBaseline.metal`).
- Right side uses the editable current shader (`Shaders.metal`).
- Both panes share the same transport, seek, pause/play, and audio timing, so visual differences
  can be judged in motion instead of from isolated screenshots only.

### What was learned

- Screenshot diffs and binary-size measurements are useful for narrowing options, but they are not
  sufficient for subjective post-process changes.
- The post film-grain path is especially sensitive. Even when a simplification is numerically close
  and saves some bytes, it can still feel wrong in motion.
- A first shortcut created a drifting screen-space overlay ("glass layer") because the noise was
  tied to a time-driven horizontal screen offset.
- A second, less aggressive shortcut removed the obvious drift but still felt unstable/blinky in
  motion compared with the original.

### Decision

- Revert the grain optimization.
- Keep the live compare tooling.
- Treat the post grain path as artistically locked unless a future change survives side-by-side
  motion review, not just still-frame comparison.

### Practical takeaway

The compare mode is a permanent quality tool for future shader work. The grain optimization is not
worth shipping on macOS at the measured byte savings because it changes the perceived texture of
the image.

---

## App Store / TestFlight Release (2026-03-30)

### Apple Developer Setup

- **Developer Program**: configure locally in gitignored release config
- **Release Apple ID**: local `FASTLANE_USER` in `fastlane/.env` (gitignored)
- **Signing identities**: supplied by the local Xcode/Keychain setup for the selected Apple ID
- Note: a contributor may also have a separate personal team. Xcode projects and Fastlane config
  should resolve team IDs from local config rather than tracked literals.

### Bundle Identifiers

Bundle/team identifiers are local release config now, not tracked repo data.

- Xcode projects read them from `Config/Identifiers.local.xcconfig` (gitignored)
- Fastlane and Makefile release steps read them from `fastlane/.env` (gitignored)
- Templates live in `Config/Identifiers.local.xcconfig.example` and `fastlane/.env.default`

### App Store Connect

- **App name**: "Elevated Intro" ("Elevated" was already taken globally)
- **SKU**: `elevated`
- **Platforms**: iOS, macOS, tvOS, visionOS (all selected)
- **Primary language**: English (U.K.)
- **User Access**: Full Access

### Versioning

Date-based scheme matching the macOS Makefile:

- **MARKETING_VERSION** (CFBundleShortVersionString): `YY.M.DD` (e.g. `26.3.30`)
- **CURRENT_PROJECT_VERSION** (CFBundleVersion): `HH.MM` (e.g. `10.47`)

**Local builds**: Run `./stamp-version.sh` before archiving. It updates all `.xcodeproj` files via sed.

**Xcode Cloud**: `ci_scripts/ci_post_clone.sh` calls `stamp-version.sh` automatically after cloning,
before the build starts.

**Why not a Run Script build phase?** Xcode 26's build sandbox blocks scripts from writing to either
the built Info.plist (`TARGET_BUILD_DIR`) or the source tree (`SRCROOT`). `agvtool` also fails because
there are multiple `.xcodeproj` files in the root. The `ci_post_clone.sh` approach runs outside the
sandbox.

### Metal Shader Linking Fix

SPM compiles all `.metal` files in a target into a single metallib. Both `Shaders.metal` and
`ShadersBaseline.metal` define the same 9 functions (`no`, `fbm`, `cn`, `sl`, `a`, `b`, `c`, `d`, `e`),
causing "9 duplicated symbols" from `air-lld`.

**Fix**: Renamed `ShadersBaseline.metal` to `ShadersBaseline.txt` so SPM doesn't compile it. The
renderer's `loadLibrarySource()` was updated to also look for `.txt` extension — it compiles the
shader source at runtime via `device.makeLibrary(source:options:)`.

In `Package.swift`:
```swift
resources: [
    .process("Shaders.metal"),       // compiled into default.metallib
    .copy("ShadersBaseline.txt")     // bundled as raw source, compiled at runtime
]
```

The macOS Makefile was already compiling them into separate `.metallib` files, so this only affected
the Xcode/SPM builds for iOS, tvOS, and visionOS.

### Local Archive (without Xcode Cloud)

```sh
./stamp-version.sh
xcodebuild -project ElevatedIOS.xcodeproj -scheme Elevated \
    -destination 'generic/platform=iOS' -configuration Release \
    archive -archivePath /tmp/Elevated.xcarchive
```

Then open Xcode Organizer (Window > Organizer) to validate and distribute.

### Xcode Cloud

Workflow configured to build on push to `main`, archive for iOS, and deploy to TestFlight.
GitHub repo: `thoroncode/elevated` (private). Xcode Cloud accesses it via the GitHub App
authorization.

### Fastlane Automation

Installed locally via Ruby. The executable path may vary by machine; on this workstation the
usable binary was `/opt/homebrew/lib/ruby/gems/4.0.0/bin/fastlane`. Fastlane 2.232.2.

**Makefile targets:**

| Target | Description |
|--------|-------------|
| `make ios-screenshots` | Render 5 key demo frames, scale to iPhone 6.9" + iPad 13" |
| `make ios-archive` | Stamp version + build iOS archive |
| `make ios-upload` | Upload archive to TestFlight via `xcodebuild -exportArchive` |
| `make ios-release` | One-step: stamp + archive + upload |
| `make ios-metadata` | Upload screenshots to App Store Connect (hides `Elevated.pkg` to prevent macOS detection) |
| `make ios-submit` | Submit latest build for App Store review |
| `make ios-add-tester` | Add tester via `pilot` (currently broken — use App Store Connect web UI) |

**Configuration:**
- `Config/Identifiers.xcconfig` — tracked generic defaults plus optional local Xcode override include
- `Config/Identifiers.local.xcconfig` — local bundle/team IDs for Xcode builds (gitignored; copy from `.example`)
- `fastlane/Appfile` — reads bundle/team IDs from env vars instead of tracked literals
- `fastlane/.env` — Apple IDs plus shell/Fastlane release identifiers (gitignored, copy from `.env.default`)
- `fastlane/metadata/en-GB/` — description, keywords, copyright, URLs
- `fastlane/screenshots/en-GB/` — generated screenshots (5 iPhone + 5 iPad)
- `scripts/write_export_options_plist.sh` — generates the temporary export plist from local env

**Screenshot timestamps:** t=5s (mountains+water), t=17s (dramatic mountains), t=48s (mountain
composition), t=95s (mid-demo), t=185s (icon frame — the best single frame).

**Known Fastlane issues (as of 2.232.2):**
- `deliver` crashes with "No data" on `fetch_app_store_review_detail` for new apps that have never
  been submitted for review. Workaround: upload screenshots only (`skip_metadata: true`), set text
  metadata in App Store Connect web UI for the first version.
- `pilot add/list` crashes with "'betaTesterMetrics' is not a valid relationship name" due to
  App Store Connect API changes. Workaround: add testers via web UI.
- Fastlane auto-detects `Elevated.pkg` in repo root and forces `platform: osx`. Workaround:
  Makefile temporarily moves pkg out of the way during `ios-metadata`.

**Observed release hurdles (2026-04-03):**
- `fastlane ios release` stamped version `26.4.3 (18.42)` but failed in `build_app` because
  `xcpretty` was not installed (`sh: xcpretty: command not found`, exit 127).
- In the same failed run, `gym` reported scheme `ElevatedIOS` even though `fastlane/Fastfile`
  requested `scheme: "Elevated"`. `xcodebuild -list -project ElevatedIOS.xcodeproj` confirmed that
  `Elevated` is the shared app scheme. When Fastlane output looks contradictory, verify with
  direct `xcodebuild -list`.
- The direct release path succeeded: `xcodebuild archive` followed by `xcodebuild -exportArchive`
  uploaded build `26.4.3 (18.42)` to TestFlight.
- `stamp-version.sh` rewrites all `Elevated*.xcodeproj/project.pbxproj` files. Run release
  automation in a disposable worktree if you do not want local version bumps left in the main
  checkout.

**Config boundary:**
- Keep Apple IDs, team IDs, bundle IDs, App Store Connect numeric app IDs, tester group names,
  API keys, sessions, and other operator/org-specific release settings in gitignored local config.
- Keep only the release workflow, variable names, templates, and generic placeholder defaults in
  the repo.
- The tracked repo should remain portable across contributors and Apple teams without embedding one
  organization's identifiers.

### Web Presence

- **Support page**: https://thoron.iki.fi/elevated/
- **Privacy policy**: https://thoron.iki.fi/elevated/privacy.html
- Hosted at `ssh://thoron@thoron.iki.fi/public_html/elevated/`
- The app collects no data, has no network access, no analytics, no tracking.

### TestFlight Status (2026-04-03)

- First build **26.3.30 (10.47)** uploaded and verified running on device.
- Latest build **26.4.3 (18.42)** uploaded on 2026-04-03 via direct `xcodebuild` export after the
  Fastlane lane failed.
- Active TestFlight group and App Store Connect app ID live in local release config, not tracked docs.
- Copyright: "Petri Koistinen et al."

---

## Apple TV (tvOS) Release

### Setup (2026-04-02)

**Bundle/team identifiers**: loaded from local release config. A unified bundle identifier can still
be used across platforms if the local App Store Connect setup is structured that way.

**First tvOS build uploaded**: 26.4.02 (21.52).

Note: App Store Connect record choices are local/operator data and are no longer tracked here.

### tvOS-Specific Asset Requirements

tvOS app icons use **image stacks** (layered images for parallax), not flat `.appiconset`
files like iOS. The asset catalog uses a **Brand Assets** structure:

```
AppTV/Assets.xcassets/
  App Icon & Top Shelf Image.brandassets/
    Contents.json                          ← roles: primary-app-icon, top-shelf-image, top-shelf-image-wide
    App Icon - Small.imagestack/           ← 400x240 home screen icon (2 layers, @1x + @2x)
    App Icon - Large.imagestack/           ← 1280x768 App Store icon (2 layers)
    Top Shelf Image.imageset/              ← 1920x720 standard top shelf
    Top Shelf Image Wide.imageset/         ← 2320x720 wide top shelf
```

Key points:
- Image stacks require **at least 2 layers** (front + back). Both layers use the same image
  for now (no parallax effect). Can be improved later with separate foreground/background art.
- The `role` for the App Store icon is `"primary-app-icon"` at `"size": "1280x768"` — there is
  **no** separate `"app-store-icon"` role.
- `Info.plist` must include `TVTopShelfImage` (with `TVTopShelfPrimaryImage` and
  `TVTopShelfPrimaryImageWide` keys) and `CFBundleIcons` (with `CFBundlePrimaryIcon`).
- Build setting: `ASSETCATALOG_COMPILER_APPICON_NAME = "App Icon & Top Shelf Image"`.

### tvOS Code Signing Workaround

The Nitor team has no registered tvOS devices, so Xcode's automatic signing cannot create
a **development** provisioning profile during archive. Workaround: archive unsigned, then
sign and upload during the export step:

```sh
# Step 1: Archive without code signing
xcodebuild -project ElevatedTV.xcodeproj -scheme Elevated \
    -destination 'generic/platform=tvOS' -configuration Release \
    archive -archivePath /tmp/ElevatedTV.xcarchive \
    -allowProvisioningUpdates \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Step 2: Export with distribution signing + upload
./scripts/write_export_options_plist.sh /tmp/ElevatedTVExportOptions.plist
xcodebuild -exportArchive \
    -archivePath /tmp/ElevatedTV.xcarchive \
    -exportOptionsPlist /tmp/ElevatedTVExportOptions.plist \
    -exportPath /tmp/ElevatedTVExport \
    -allowProvisioningUpdates
```

This is automated via `make tv-release` / `fastlane appletv release`.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make tv-release` | Stamp version, archive, sign, and upload tvOS to App Store Connect |
| `make tv-submit` | Submit latest tvOS build for App Store review |

### Configuration Files

- `scripts/write_export_options_plist.sh` — generates the temporary export plist from local env
- `Config/Identifiers.xcconfig` — tracked defaults for team/bundle settings with optional local override
- `Config/Identifiers.local.xcconfig.example` — template for gitignored local Apple identifiers
- `fastlane/Fastfile` — `platform :appletv` block with `release` and `submit` lanes
- `fastlane/Appfile` — `for_platform :appletv` block (bundle/team IDs from env, Apple ID from env)
- `fastlane/.env.default` — template for gitignored shell/Fastlane release identifiers

### Performance: Forced Drawable Size

Apple TV 4K (3rd gen, A15) renders at native 3840x2160 by default — too slow for the
3-pass renderer with 1024-vertex terrain mesh and 16-sample motion blur.

**Key finding**: `contentScaleFactor = 1.0` alone does NOT reliably force the resolution.
The correct approach is:
```swift
mtkView.autoResizeDrawable = false
mtkView.drawableSize = CGSize(width: 1920, height: 1080)
```
This guarantees the GPU renders at the specified resolution regardless of the TV's native
resolution. The display upscales from 1080p to 4K automatically.

**Tested resolutions on Apple TV 4K (A15)**:
- 3840×2160 (native 4K): extremely slow, unusable
- 1920×1080 (forced): smooth 60fps ← **shipped**
- 1280×720 (forced): smooth 60fps, confirmed resolution is the bottleneck

**Not the bottleneck**: the 1024×1024 terrain mesh and rgba32Float G-buffer are fine at 1080p.
Reducing mesh to 512 or switching to rgba16Float showed no visible improvement at 1080p and
hurt visual quality. Reverted to full quality settings.

### Lessons Learned

1. **tvOS code signing**: No registered tvOS devices = no dev provisioning profiles.
   Workaround: archive unsigned (`CODE_SIGNING_ALLOWED=NO`), sign at export time with
   `-allowProvisioningUpdates`.
2. **tvOS app icons are image stacks**, not flat PNGs. Minimum 2 layers (front + back).
   Use a Brand Assets (`.brandassets`) structure with `primary-app-icon` role for both
   home screen (400x240) and App Store (1280x768) sizes.
3. **No separate `app-store-icon` role** — the App Store icon is a `primary-app-icon`
   at 1280x768. This was the hardest to figure out.
4. **Top Shelf images need both @1x and @2x**: Wide is 2320x720 (@1x) + 4640x1440 (@2x).
5. **Export compliance** must be set on each build before it becomes testable. Set
   `usesNonExemptEncryption: false` via API or App Store Connect.
6. **A unified bundle ID can work across multiple platforms** under one
   App Store Connect record if the local identifiers are configured that way.
7. **Free Apple Developer teams** (personal) cannot create App Store provisioning profiles.
   Must use a paid team.
8. **Fastlane 2.232.2** has broken `betaBuildMetrics` API — `pilot builds`, `pilot distribute`,
   and `pilot list` all crash. Use Spaceship Ruby API or App Store Connect web UI as workaround.

### tvOS Transport Scrubber (2026-04-02)

Native-feeling transport bar for the Apple TV, implemented in the tvOS ViewController
without any debug mode — always available via the Siri Remote.

**Controls:**
- **Swipe left/right** on touchpad: velocity-based scrubbing (faster swipe = faster seek)
- **Click touchpad** or **Play/Pause button**: toggle play/pause
- Transport bar appears on any interaction, auto-hides after 4 seconds

**Implementation:**
- `UIPanGestureRecognizer` maps `velocity.x` to seek speed (~800 points/sec = 1x playback speed)
- During scrub: only Renderer seeks (visual preview), SynthPlayer seeks on gesture end (no audio glitch)
- Progress bar: white fill on gray track, elapsed/remaining time labels, rounded container with
  semi-transparent background — follows Apple TV video app conventions
- `CADisplayLink` updates the progress bar every frame when visible

**No AVPlayerViewController** — Apple's built-in transport bar only works with AVPlayer. Custom Metal
players must implement their own scrub UI. The Siri Remote's outer ring scrubbing is exclusive to
AVPlayerViewController and not available to third-party apps.

### Background Muting (2026-04-02)

Both iOS and tvOS now pause renderer + audio when the app enters background, and resume on
foreground return. Implemented via `sceneDidEnterBackground` / `sceneWillEnterForeground` in
the SceneDelegates, calling `pausePlayback()` / `resumePlayback()` on the ViewController.
