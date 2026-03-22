# stub_d3d9 — Minimal d3d9.dll for Music Extraction

## Purpose
Extract the raw float32 audio from the Elevated 4KB intro by running its
synthesizer under Wine on macOS, where the real D3D9 pipeline cannot run.

## How it works
The Elevated binary (Crinkler-packed) at startup:
1. Calls `Direct3DCreate9` → our stub runs: allocates synthesis memory, patches
   the music buffer address, noops the D3D setup function, hooks `ExitProcess`.
2. Runs music synthesis (~60s on M1 Pro). Writes float32 stereo samples to
   `music_buf_addr` (dynamically allocated, logged to `C:\stub_log.txt`).
3. Calls `IDirect3D9::CreateDevice` → stub_CreateDevice: **dumps the float32
   buffer to `C:\music_float.bin`** (76.5 MB, 44100 Hz stereo float32).

## Build
Requires `i686-w64-mingw32-gcc` (from `brew install mingw-w64`):

```bash
cd stub_d3d9
i686-w64-mingw32-gcc -shared -O2 -o d3d9.dll d3d9_stub.c d3d9.def \
    -nostdlib -lkernel32 -luser32
```

## Deploy
```bash
cp d3d9.dll ~/.wine/drive_c/windows/syswow64/d3d9.dll
cp d3d9.dll ~/.wine/drive_c/windows/system32/d3d9.dll
wine reg add "HKEY_CURRENT_USER\Software\Wine\DllOverrides" \
     /v d3d9 /t REG_SZ /d native /f
```

The DLL override must be set to `native`; without it Wine loads its own d3d9.

## Run
```bash
pkill -f elevated; sleep 1
wine ~/src/elevated/elevated_1920_1080.exe &>/dev/null &
# Wait ~75s for synthesis + dump, then:
ls -lh ~/.wine/drive_c/music_float.bin
tail ~/.wine/drive_c/stub_log.txt
```

## What gets patched at runtime (all reversible — in-process only)
| Address | Patch | Reason |
|---------|-------|--------|
| `0x420152` | `mov edi, 0xfbf70500` → `mov edi, <alloc>` | Original addr unmappable on macOS |
| `0x420500` | `pushal; pushal; ret` (noop) | Prevents d3dx9 crash on fake device |
| `[0x430000]` | `ExitProcess` → `stub_ExitProcess` | Dump before exit (belt+suspenders) |

## Memory layout (with stub)
- **Direct3DCreate9** calls `VirtualAlloc(NULL, 640 MB)` → `music_buf_addr`
- Main output buffer: `music_buf_addr` + 0 × 76.5 MB
- Operator working buffers: `music_buf_addr` + N × 76.5 MB (N operators)
- Without the alloc, the second operator buffer overflows past the binary's BSS
  end at `0x12c8b6eb`, crashing at `0x12c8c000` with `rep stosd`.

## Convert to WAV
```bash
python3 - << 'EOF'
import struct, wave
data = open(os.path.expanduser('~/.wine/drive_c/music_float.bin'), 'rb').read()
samples = struct.unpack_from('<' + 'f' * (len(data)//4), data)
pcm = bytes(struct.pack('<h', max(-32768, min(32767, int(s * 32767)))) for s in samples)
with wave.open('elevated_music.wav', 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(pcm)
print('Done: elevated_music.wav')
EOF
```

## Crash history (resolved)
| Crash address | Error | Fix |
|---|---|---|
| `0x420577` | Null deref in D3D setup (`lodsd` chain) | `stub_create3` writes fake pointer |
| `0x1554b84c` | d3dx9 using fake device | Noop the D3D setup at `0x420500` |
| `0xfbf70500` | Unmappable on macOS | Patch `mov edi` at `0x420152` |
| `0x12c8c000` | Operator buffer overflows binary end | `VirtualAlloc(NULL, 640MB)` dynamically |
