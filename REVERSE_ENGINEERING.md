# Elevated Binary — Reverse Engineering Notes

## Binary: elevated_1920_1080.exe
- Size: 4066 bytes, PE32 x86, packed with Crinkler
- Entry point: 0x40005c (Crinkler decompressor stub)
- Single section "blob" at paddr 0x5c / vaddr 0x40005c

## Memory Layout (post-decompression, seen via Wine)

| Address | Size | Contents |
|---------|------|----------|
| 0x400000 | 4KB  | Crinkler stub + PE header |
| 0x401000–0x41FFFF | ~124KB | Crinkler scratch/BSS (zeroed) |
| 0x420000 | ~11KB | Decompressed program code |
| 0x421000–0x8400000 | ~127MB | Heap: music synthesis buffer, render data |
| 0x430000 | 256B | Resolved Windows API function pointers |

## Decompressed Code Map (0x420000+)

| Address | Function |
|---------|----------|
| 0x420000 | Import resolver (walks PEB, hash-compares DLL exports) |
| 0x420082 | Entry: CreateWindow, D3D9 init, launch render loop |
| 0x420148 | **Music synthesis init** — pre-renders all audio, takes ~20-30s |
| 0x420189 | Spline interpolator (cubic, FPU-based) |
| 0x4201d5 | Camera spline evaluation |
| 0x4201fa | LCG random number generator (seed at 0x4300d8) |
| 0x4201e3 | Sine wave synthesis (FPU fsin loop) |
| 0x420305 | D3D9 SetShaderConstantF helper |
| 0x420500 | D3D9 setup (shaders, geometry, textures) |
| 0x42075e | **Render loop** — called every frame |
| 0x420a9d | Spline keyframe data (byte-encoded, loaded by render loop) |
| 0x420d08 | Shader constants buffer (written per-frame) |
| 0x420d28 | Music synthesizer dispatch table |
| 0x420d7c | Spline normalization table (int16 offsets/scales) |
| 0x420dac | Camera keyframe index lookup table |
| 0x421304 | Camera spline control points |
| 0x421880 | Vertex declaration data |
| 0x422700 | Camera keyframe → constant-register mapping table |

## Shader Constant Buffer

**Location**: 0x870100 (written by render loop each frame)
**Size**: 0x40 float4 vectors (64 vectors × 16 bytes = 1024 bytes)

The constants map directly to HLSL `float4 q[16]` + `float4x4 v:register(c16)`:

| Index | HLSL | Contents |
|-------|------|----------|
| q[0] | `q[0]` | Water wave offset (xy), time scale (z), ? (w) |
| q[1] | `q[1]` | Terrain offset (xy), ? (z), water level y (w) |
| q[2] | `q[2]` | season/snow blend (x), post brightness (y), post gamma (z), terrain height scale (w) |
| q[3] | `q[3]` | Sun direction (xyz), **time in seconds** (w) |
| q[4] | `q[4]` | Camera world position (xyz) |
| q[5..12] | `q[5..12]` | Cloud band parameters (8 bands, .x = distance/density) |
| q[16..19] | `v` | 4×4 view-projection matrix (register c16-c19) |

### Extracting Live Constants

**The render loop only runs AFTER music synthesis completes (~20-30 seconds).**

```bash
cd /Users/pk/src/elevated
WINEDEBUG=-all wine elevated_1920_1080.exe &>/dev/null &
WINE_PID=$!
sleep 35   # wait for music synthesis (~20-30s) + a few rendered frames

TARGET_PID=$(ps aux | grep "elevated_1920_1080" | grep -v grep | grep -v "wine$" | awk '{print $2}' | head -1)

cat > /tmp/dump.txt << EOF
process attach --pid $TARGET_PID
memory read --binary --force --outfile /tmp/consts.bin --count 65536 0x870000
process detach
quit
EOF
lldb --batch --source /tmp/dump.txt
kill $WINE_PID
```

Then parse with:
```python
import struct
data = open('/tmp/consts.bin', 'rb').read()
# q[0..15] starts at offset 0x100 (= 0x870100 - 0x870000)
for i in range(20):
    vals = struct.unpack_from('<4f', data, 0x100 + i*16)
    print(f"q[{i}] = {vals}")
```

## API/Vtable Calls (D3D9, vtable offsets)

The device pointer is stored at `[0x430090]`. All D3D9 calls go through `[device_vtable + offset]`:

| Offset | Method | Notes |
|--------|--------|-------|
| 0x44   | CreateDevice | init |
| 0x94   | SetStreamSource | |
| 0xa4   | BeginScene | |
| 0xa8   | EndScene | |
| 0xac   | Clear | |
| 0x104  | SetVertexDeclaration | |
| 0x14c  | DrawIndexedPrimitive | |
| 0x164  | SetIndices | |
| 0x170  | SetVertexShader | |
| 0x178  | **SetVertexShaderConstantF** | q[0..63] from 0x870100 |
| 0x1ac  | SetPixelShader | |
| 0x1b4  | **SetPixelShaderConstantF** | q[0..63] from 0x870100 |

## Windows API Import Table (0x430000)

Resolved at startup by the import resolver:

| Address | Function |
|---------|----------|
| 0x430000 | ExitProcess |
| 0x430004 | LoadLibraryA (d3d9) |
| 0x430008 | CreateWindowExA |
| 0x43000c | timeGetTime (or GetMessage) |
| 0x430010 | PostQuitMessage |
| 0x430014 | Direct3DCreate9 |
| 0x430018 | D3D9 device create helpers |
| 0x430028 | StretchRect (D3D surface copy) |
| 0x430040 | (Message loop) |
| 0x430044 | SetVertexShaderConstantF (via device, init) |
| 0x430048 | SetPixelShaderConstantF (via device, init) |
| 0x430090 | **D3D9 Device pointer** |
| 0x4300d8 | LCG random seed |

## HLSL Shader Source

Extracted from Wine memory dump at 0x42193f (length 3510 bytes).

Saved to:
- `elevated_raw.hlsl` — minified original
- `elevated_pretty.hlsl` — formatted for readability

### Shader Functions

| HLSL | Metal equiv | Description |
|------|-------------|-------------|
| `no(p)` | `no()` | Perlin smooth noise, returns (value, gradient.xy). Quintic interp, 256×256 hash texture. |
| `f(p, o)` | `fbm()` | FBM terrain, o octaves. Domain rotation `float2x2(1.6,-1.2,1.2,1.6)`, derivative damping `1/(1+dot(d,d))`. |
| `cn(p, e, o)` | `cn()` | Terrain normal via finite differences. Scale by `q[2].w`. |
| `b(p, n, d)` | `skyLight()` | Sky/diffuse lighting. `q[3].xyz` = sun dir, `q[2].x` = season. |
| `m0` | `terrainVert` | Vertex shader: `height = q[2].w * f(pos.yx, 8)` |
| `m1` | `waterVert` | Water surface from cosine wave synthesis. |
| `m2` | `gbufferFrag` | Pass-through color. |
| `m3` | `deferredFrag` | Deferred pixel shader: sky, terrain (snow/rock/soil), water (Fresnel/specular), fog. |
| `m4` | `postFrag` | Post: motion blur (16 samples), gamma `pow(c,0.45)`, vignette, chromatic aberration, film grain. |

## Timer / Music Sync

- Timer = audio sample position (loaded each frame via `timeGetTime` or `QueryPerformanceCounter`)
- `q[3].w` = timer / 44100 (seconds) — used in shaders as time
- Demo duration: `0x910000 = 9,502,720` samples / 44100 = ~215 seconds (~3.5 min)
- Music buffer: large area near 0xFBF70500 (pre-synthesized at startup)

## Build / Run

```bash
# Build Metal port
cd ElevatedMac && swift build

# Run
.build/debug/ElevatedMac

# Re-dump Wine memory (if needed)
./wine_dump.sh
```

## Key Files

| File | Description |
|------|-------------|
| `elevated_1920_1080.exe` | Original 4KB Crinkler-packed intro |
| `elevated_raw.hlsl` | Extracted HLSL shaders (minified) |
| `elevated_pretty.hlsl` | Extracted HLSL shaders (formatted) |
| `ElevatedMac/` | Swift/Metal port |
| `elevated/ElevatedCore/SHADER_NOTES.md` | Render-pass and shader-structure notes for the Metal port |
| `crinkler-unpack/` | Rust Unicorn emulator (too slow, use Wine instead) |
| `wine_dump.sh` | Wine + lldb memory dump script |
| `REVERSE_ENGINEERING.md` | This file |
