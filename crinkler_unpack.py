#!/usr/bin/env python3
"""
crinkler_unpack.py  –  Standalone Crinkler decompressor for elevated.exe

Uses Unicorn Engine to emulate the x86 decompressor stub natively on macOS
(no Windows, no Wine, no Rosetta needed).

Entry point:   0x40005c  (radare2 confirmed)
Compressed at: 0x400154
Output base:   0x420000
"""

import sys
import struct
from unicorn import *
from unicorn.x86_const import *


def unpack(exe_path: str, out_path: str) -> bool:
    with open(exe_path, "rb") as f:
        raw = f.read()

    print(f"Input:  {exe_path}  ({len(raw)} bytes)")

    # ── Memory layout ──────────────────────────────────────────────
    FILE_BASE  = 0x400000   # PE load address
    FILE_SIZE  = 0x10000    # 64 KB – comfortably covers the 4 KB exe
    OUT_BASE   = 0x420000   # Crinkler decompresses here
    OUT_SIZE   = 0x200000   # 2 MB ceiling – more than enough
    STACK_TOP  = 0x700000
    STACK_SIZE = 0x10000

    mu = Uc(UC_ARCH_X86, UC_MODE_32)

    mu.mem_map(FILE_BASE,        FILE_SIZE)
    mu.mem_map(OUT_BASE,         OUT_SIZE)
    mu.mem_map(STACK_TOP - STACK_SIZE, STACK_SIZE)

    # Load the exe image at its preferred base
    mu.mem_write(FILE_BASE, raw.ljust(FILE_SIZE, b"\x00"))

    # Stack
    mu.reg_write(UC_X86_REG_ESP, STACK_TOP - 16)

    # ── Track output ───────────────────────────────────────────────
    out_shadow = bytearray(OUT_SIZE)
    high_water = [0]

    def on_mem_write(uc, access, addr, size, val, _ud):
        if OUT_BASE <= addr < OUT_BASE + OUT_SIZE:
            off = addr - OUT_BASE
            for i in range(size):
                out_shadow[off + i] = (val >> (8 * i)) & 0xFF
            if off + size > high_water[0]:
                high_water[0] = off + size

    mu.hook_add(UC_HOOK_MEM_WRITE, on_mem_write)

    # ── Stop when execution reaches decompressed code ──────────────
    reached_out = [None]

    def on_code(uc, addr, size, _ud):
        if addr >= OUT_BASE:
            reached_out[0] = addr
            uc.emu_stop()

    mu.hook_add(UC_HOOK_CODE, on_code)

    # ── Lazy-map any unmapped pages (zeroed) ───────────────────────
    def on_unmapped(uc, access, addr, size, val, _ud):
        page = addr & ~0xFFF
        try:
            uc.mem_map(page, 0x1000)
            uc.mem_write(page, b"\x00" * 0x1000)
        except UcError:
            pass
        return True

    mu.hook_add(
        UC_HOOK_MEM_READ_UNMAPPED |
        UC_HOOK_MEM_WRITE_UNMAPPED |
        UC_HOOK_MEM_FETCH_UNMAPPED,
        on_unmapped,
    )

    # ── Run ────────────────────────────────────────────────────────
    ENTRY = 0x40005C   # Crinkler decompressor entry point
    print(f"Emulating from 0x{ENTRY:08x} …")

    try:
        mu.emu_start(
            ENTRY,
            OUT_BASE + OUT_SIZE,
            timeout=120_000_000,   # 120 s wall-clock guard
            count=100_000_000,     # instruction count guard
        )
    except UcError as e:
        print(f"  Emulation stopped: {e}")

    # ── Results ────────────────────────────────────────────────────
    if reached_out[0]:
        print(f"  Execution reached decompressed code @ 0x{reached_out[0]:08x}")

    n = high_water[0]
    if n == 0:
        print("ERROR: nothing written to output region – wrong entry point?")
        return False

    print(f"  Decompressed {n:,} bytes  ({n // 1024} KB)")

    with open(out_path, "wb") as f:
        f.write(bytes(out_shadow[:n]))
    print(f"  Saved → {out_path}")
    return True


if __name__ == "__main__":
    exe = sys.argv[1] if len(sys.argv) > 1 else "elevated_1920_1080.exe"
    out = sys.argv[2] if len(sys.argv) > 2 else "elevated_unpacked.bin"
    sys.exit(0 if unpack(exe, out) else 1)
