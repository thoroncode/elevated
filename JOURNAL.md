# Elevated Mac Port — Development Journal

A log of discoveries, fixes, and decisions for future agent sessions.

---

## Project Overview

**Goal**: Pixel-perfect Metal/Swift port of the Elevated 4KB intro (rgba/tbc, Breakpoint 2009).
**Original**: `elevated_1920_1080.exe` — Direct3D9, HLSL shaders, x86 assembly synth.
**Port**: `ElevatedMac/` — Metal 3-pass renderer, Swift CPU logic, C synth port.
**Reference**: `elevated_8000.avi` — high-quality AVI of the original running natively.
**Source**: `~/Downloads/mtt_iq_Elevated/` — MIT-licensed release by iq/Puryx/Mentor.

---

## Architecture

### 3-Pass Metal Renderer

**Pass 1 — G-buffer** (`terrainVert` + `gbufferFrag`):
- Flat XZ grid (256×256, scale=104 units = ±52) displaced by FBM terrain height in vertex shader
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
- `xdot = VPOS.x`: 0.5 → camPos, 1.5 → camTarget
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
- **Port**: 256×256 regular grid, scale=104 (±52 units) — covers same area, different topology

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

## Known Remaining Issues (as of 2026-03-24)

### Camera Path — Minor Residual Drift
After the xdot fix, the camera is broadly correct — mountains are visible at all key timestamps and composition is close. Remaining drift is subtle: slightly different framing at specific moments (e.g. t=136). Likely sources:

1. Terrain mesh topology differences (diamond vs grid) cause slightly different normal interpolation and perceived shape at some XZ positions
2. Minor FBM float precision differences between HLSL and MSL (hard to eliminate without the original GPU pipeline)

### Light Beams — Verified Working (2026-03-24)
Instrument sync confirmed working after full capture. Beams appear synced to music at t=132-136. Light beam at t=132 appears ~1 frame early in reference vs our port — likely a ≤1-step offset in the sync scan. Functionally correct.

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
| `tools/d3d9proxy/d3d9_proxy.c` | D3D9 vtable proxy for Wine (incomplete — see below) |
| `tools/extract_ref.sh` | Extract 1fps frames from elevated_8000.avi → /tmp/elevated_ref/ |
| `tools/compare.sh` | Side-by-side comparison with ffmpeg hstack |
| `Makefile` | `make run/debug/capture/ref/compare` |

---

## Wine D3D9 Extraction Attempt (Blocked)

Tried to extract ground-truth camera data from `elevated_1920_1080.exe` under Wine by replacing `d3d9.dll` with a vtable-patching proxy. The existing `~/.wine/drive_c/windows/system32/d3d9.dll` is a **custom 12KB stub** (`d3d9_stub.c`) that:
1. Intercepts D3D9 and provides a **fake device** (no GPU rendering)
2. Dumps `d3d_code.bin` and `synth_code.bin` from the exe
3. The demo's m1 shader never runs (no real pixel shader execution)

**Conclusion**: Ground-truth camera extraction via Wine is not viable without replacing the d3d9 stub with a real GPU implementation. Option would be running under Windows or using a proper D3D9 → Vulkan/Metal translation layer.

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

## Key Visual Timestamps to Verify

| Time | Expected | Status |
|------|----------|--------|
| 0:00-0:03 | Fade from black | Not verified |
| 0:05 | Mountains top-to-bottom, water at bottom | **Fixed** (xdot fix) — close match |
| 0:17 | Dramatic mountain shot | **Fixed** — very close match |
| 0:48 | Mountains | **Fixed** — nearly identical |
| 1:32-1:37 | **Light beams synced to music** | **Fixed** — beams visible and music-synced |
