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

    # ── Skip the 79M-iteration rep stosw probability-table init ───────
    # At 0x4000c8 Crinkler does `rep stosw` with ECX≈79M to zero the
    # probability table.  Fresh mapped memory is already zeroed, so we
    # can skip it by forcing ECX=0.  Use address-range filter so Python
    # is only called ONCE for this address, not for every instruction.
    REP_STOSW_ADDR = 0x4000C8

    def on_rep_stosw(uc, addr, size, _ud):
        ax  = uc.reg_read(UC_X86_REG_EAX) & 0xFFFF
        ecx = uc.reg_read(UC_X86_REG_ECX)
        print(f"  [skip] rep stosw @ 0x{addr:08x}  AX=0x{ax:04x}  ECX={ecx:,} → set ECX=0")
        uc.reg_write(UC_X86_REG_ECX, 0)

    mu.hook_add(UC_HOOK_CODE, on_rep_stosw,
                begin=REP_STOSW_ADDR, end=REP_STOSW_ADDR + 1)

    # ── Stop when execution reaches decompressed code ──────────────
    # Address-range filter: only fire Python callback inside output region
    reached_out = [None]

    def on_code(uc, addr, size, _ud):
        reached_out[0] = addr
        uc.emu_stop()

    mu.hook_add(UC_HOOK_CODE, on_code,
                begin=OUT_BASE, end=OUT_BASE + OUT_SIZE)

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
            timeout=300_000_000,   # 300 s wall-clock guard
            count=500_000_000,     # 500M instruction guard
        )
    except UcError as e:
        print(f"  Emulation stopped: {e}")

    # ── Results: read memory directly from emulator ────────────────
    if reached_out[0]:
        print(f"  Execution reached decompressed code @ 0x{reached_out[0]:08x}")
    else:
        print("  WARNING: never reached decompressed code (stopped by limit?)")

    out_bytes = bytes(mu.mem_read(OUT_BASE, OUT_SIZE))

    # Trim trailing zeros for a useful size indicator
    trimmed = out_bytes.rstrip(b"\x00")
    n = len(trimmed)
    if n == 0:
        print("ERROR: output region is empty – wrong entry point?")
        return False

    print(f"  Decompressed {n:,} useful bytes  ({n // 1024} KB), full window {OUT_SIZE // 1024} KB")

    with open(out_path, "wb") as f:
        f.write(out_bytes)          # save full window so all offsets are correct
    print(f"  Saved → {out_path}  ({OUT_SIZE // 1024} KB padded)")
    return True


if __name__ == "__main__":
    exe = sys.argv[1] if len(sys.argv) > 1 else "elevated_1920_1080.exe"
    out = sys.argv[2] if len(sys.argv) > 2 else "elevated_unpacked.bin"
    sys.exit(0 if unpack(exe, out) else 1)
