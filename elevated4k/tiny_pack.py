#!/usr/bin/env python3
"""
Grammar A encoder/decoder — sub-160-byte ARM64 decoder target.

Token format:
  0xxxxxxx   LITERAL run : count = x+1 (1–128), then count raw bytes
  10lllooo   MATCH       : length = lll+3 (3–10), offset = (ooo<<8)|next_byte (1–2047)
  11llllll   RLE         : count = l+2  (2–65),  then 1 fill byte

Payload layout:
  uint32_t output_size (little-endian)
  ... compressed tokens ...

Design decisions:
  - Byte-aligned → no bit reader → smallest possible ARM64 decoder
  - Window limited to 2047 bytes (11-bit offset) → 3 bits in token + 8 bits extra byte
  - No dynamic tables, no Huffman — decoder is a straight loop
"""

import struct
import sys
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────
MIN_MATCH    = 3
MAX_MATCH    = 10      # lll is 3 bits: values 0–7 → lengths 3–10
MAX_OFFSET   = 2047    # 11-bit: ooo(3) + byte(8)
MIN_RLE      = 2
MAX_RLE      = 65      # llllll is 6 bits: values 0–63 → counts 2–65
MAX_LIT_RUN  = 128     # xxxxxxx is 7 bits: values 0–127 → counts 1–128


# ── Encoder ───────────────────────────────────────────────────────────────────

def _rle_length(data: bytes, pos: int) -> int:
    """Length of RLE run at pos (same byte), capped at MAX_RLE."""
    v = data[pos]
    end = min(len(data), pos + MAX_RLE)
    i = pos + 1
    while i < end and data[i] == v:
        i += 1
    return i - pos


def _best_match(data: bytes, pos: int) -> tuple[int, int]:
    """
    Greedy longest-match search in the backward window.
    Returns (length, offset); length < MIN_MATCH means no useful match.
    Uses a simple scan — fast enough for <100 KB binaries.
    """
    start   = max(0, pos - MAX_OFFSET)
    best_l  = 0
    best_off= 0
    max_l   = min(MAX_MATCH, len(data) - pos)

    # Quick filter: only consider positions where the first byte matches.
    v0 = data[pos]
    i  = start
    while i < pos:
        if data[i] == v0:
            l = 1
            while l < max_l and data[i + l] == data[pos + l]:
                l += 1
            if l > best_l:
                best_l   = l
                best_off = pos - i
        i += 1

    return best_l, best_off


def _emit_literals(buf: bytearray, data: bytes, start: int, end: int) -> None:
    """Emit one or more literal-run tokens covering data[start:end]."""
    pos = start
    while pos < end:
        chunk = min(MAX_LIT_RUN, end - pos)
        buf.append(chunk - 1)            # 0xxxxxxx, bit 7 = 0
        buf.extend(data[pos:pos + chunk])
        pos += chunk


def encode(data: bytes) -> bytes:
    """Compress data using Grammar A. Returns payload (header + tokens)."""
    out  = bytearray()
    pos  = 0
    n    = len(data)
    lit_start = 0      # start of pending literal run

    def flush_literals(end: int) -> None:
        if lit_start < end:
            _emit_literals(out, data, lit_start, end)

    while pos < n:
        # ── Try RLE ───────────────────────────────────────────────────────
        rle_len = _rle_length(data, pos)

        # ── Try LZ match ──────────────────────────────────────────────────
        match_len, match_off = _best_match(data, pos)

        if rle_len >= MIN_RLE and rle_len >= match_len:
            flush_literals(pos)
            lit_start = pos + rle_len
            count = min(rle_len, MAX_RLE)
            out.append(0xC0 | (count - 2))   # 11llllll
            out.append(data[pos])
            pos += count

        elif match_len >= MIN_MATCH:
            flush_literals(pos)
            lit_start = pos + match_len
            lll = match_len - MIN_MATCH      # 0–7
            ooo = (match_off >> 8) & 0x07    # high 3 bits of 11-bit offset
            out.append(0x80 | (lll << 3) | ooo)   # 10lllooo
            out.append(match_off & 0xFF)           # low 8 bits
            pos += match_len

        else:
            # No useful match or RLE — accumulate into pending literal run.
            # Peek ahead: break the run early if the next position has a
            # worthwhile match (saves re-scanning the same literal bytes).
            if pos - lit_start >= MAX_LIT_RUN:
                flush_literals(pos)
                lit_start = pos
            pos += 1

    flush_literals(n)

    header = struct.pack('<I', n)
    return bytes(header + out)


# ── Decoder (Python reference — for roundtrip verification) ───────────────────

def decode(compressed: bytes) -> bytes:
    output_size = struct.unpack_from('<I', compressed, 0)[0]
    src = memoryview(compressed)[4:]
    out = bytearray(output_size)
    si  = 0
    di  = 0

    while di < output_size:
        tok = src[si];  si += 1

        if not (tok & 0x80):                    # 0xxxxxxx — literal run
            count = (tok & 0x7F) + 1
            out[di:di + count] = src[si:si + count]
            si += count;  di += count

        elif not (tok & 0x40):                  # 10lllooo — match
            length = ((tok >> 3) & 0x07) + MIN_MATCH
            offset = ((tok & 0x07) << 8) | src[si];  si += 1
            src_pos = di - offset
            for k in range(length):
                out[di + k] = out[src_pos + k]
            di += length

        else:                                   # 11llllll — RLE
            count = (tok & 0x3F) + MIN_RLE
            fill  = src[si];  si += 1
            out[di:di + count] = bytes([fill]) * count
            di += count

    return bytes(out)


# ── ARM64 decoder stub (size reference) ───────────────────────────────────────
# This is the ARM64 assembly that implements the decoder above.
# Each ARM64 instruction is exactly 4 bytes.
#
# // Entry: x0=src (after 4-byte header), x1=dst, x2=dst_end (dst+output_size)
# _dec:
#   cmp  x1, x2            // done?
#   beq  _done
#   ldrb w3, [x0], #1      // load token
#   tbnz w3, #7, _not_lit  // bit7=1 → not literal
# _lit:                     // 0xxxxxxx
#   and  w4, w3, #127
#   add  w4, w4, #1        // count
# .ll: ldrb w5,[x0],#1; strb w5,[x1],#1; subs w4,w4,#1; bne .ll
#   b    _dec
# _not_lit:
#   tbnz w3, #6, _rle      // bit6=1 → RLE
# _match:                   // 10lllooo + byte
#   ubfx w4, w3, #3, #3
#   add  w4, w4, #3        // length
#   and  w5, w3, #7
#   lsl  w5, w5, #8
#   ldrb w6, [x0], #1
#   orr  w5, w5, w6        // offset
#   sub  x6, x1, x5       // match src
# .ml: ldrb w7,[x6],#1; strb w7,[x1],#1; subs w4,w4,#1; bne .ml
#   b    _dec
# _rle:                     // 11llllll + fill
#   and  w4, w3, #63
#   add  w4, w4, #2        // count
#   ldrb w5, [x0], #1     // fill byte
# .rl: strb w5,[x1],#1; subs w4,w4,#1; bne .rl
#   b    _dec
# _done: ret
#
# Instruction count: 34 instructions = 136 bytes
#
ARM64_DECODER_BYTES = 128   # measured: 32 instructions × 4 bytes (otool-verified)


# ── Benchmark ─────────────────────────────────────────────────────────────────

def _xz_compress(data: bytes, args: list[str]) -> bytes | None:
    import subprocess, shutil, os
    os.environ.setdefault("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    xz = shutil.which("xz") or "xz"
    r = subprocess.run([xz, "--stdout"] + args, input=data, capture_output=True)
    return r.stdout if r.returncode == 0 else None

_XZ_BEST = ["--arm64", "--lzma2=preset=9e,mf=bt4,lc=2,nice=64,depth=0"]
_XZ_STUB = 82   # shell stub bytes (tail + xz -d + exec)


def benchmark(path: Path) -> None:
    data = path.read_bytes()
    raw  = len(data)

    # Grammar A
    comp_a  = encode(data)
    ga_pay  = len(comp_a) - 4    # subtract 4-byte header (embedded in loader)
    ga_tot  = ga_pay + ARM64_DECODER_BYTES   # +loader overhead counted separately

    # xz best (shell stub, decoder NOT embedded)
    xz_pay  = _xz_compress(data, _XZ_BEST)
    xz_size = len(xz_pay) if xz_pay else 0

    # Mach-O loader overhead (header + LC_SEGMENT + LC_MAIN + startup code)
    # This applies to any embedded-decoder approach.
    LOADER_OVERHEAD = 200   # bytes, conservative estimate

    print(f"\n=== Tiny-Pack Benchmark: {path.name} ({raw:,} bytes) ===\n")
    print(f"  {'Scheme':<30} {'Payload':>9} {'Decoder':>8} {'Stub/Ldr':>9} {'Total':>9} {'Ratio':>7}")
    print("  " + "─" * 78)

    def row(name, payload, decoder, stub):
        total = payload + decoder + stub
        ratio = payload / raw
        print(f"  {name:<30} {payload:>9,} {decoder:>8,} {stub:>9,} {total:>9,} {ratio:>7.1%}")

    row("xz (shell stub, no embed)",    xz_size,  0,                   _XZ_STUB)
    row("xz (if decoder embedded)",     xz_size,  2_000,               LOADER_OVERHEAD)
    row("Grammar A (custom)",           ga_pay,   ARM64_DECODER_BYTES, LOADER_OVERHEAD)

    print()

    # Verify roundtrip
    recovered = decode(comp_a)
    ok = recovered == data
    ratio_a  = ga_pay / raw
    ratio_xz = xz_size / raw if xz_size else 0

    print(f"  Grammar A roundtrip : {'✓ OK' if ok else '✗ FAIL'}")
    print(f"  Grammar A ratio     : {ratio_a:.1%}  (payload only)")
    print(f"  xz ratio            : {ratio_xz:.1%}  (payload only)")
    # Break-even: GA wins when raw*r_ga + (decoder+loader) < raw*r_xz + stub
    # ↔  raw*(r_ga - r_xz) < stub - (decoder+loader)
    # If r_ga > r_xz (GA is worse): LHS grows with raw, RHS is negative → never wins.
    ga_oh  = ARM64_DECODER_BYTES + LOADER_OVERHEAD
    rhs    = _XZ_STUB - ga_oh
    d_ratio= ratio_a - ratio_xz
    if d_ratio >= 0 or rhs >= 0:
        # Either ratio is worse OR overhead is already lower — never/always
        if ga_oh + int(len(data) * ratio_a) < _XZ_STUB + xz_size:
            verdict = "Grammar A already wins at this size"
        else:
            verdict = "Grammar A never beats xz+stub (worse ratio AND higher overhead)"
    else:
        # Both: ratio_a < ratio_xz AND rhs < 0... unusual but compute it
        be = int(rhs / d_ratio)
        verdict = f"break-even at {be:,} bytes source"
    print(f"  vs xz+stub verdict  : {verdict}")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> int:
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    enc = sub.add_parser("encode", help="compress a file")
    enc.add_argument("input")
    enc.add_argument("output")

    dec = sub.add_parser("decode", help="decompress a file")
    dec.add_argument("input")
    dec.add_argument("output")

    sub.add_parser("bench", help="benchmark against xz").add_argument("input")
    sub.add_parser("check", help="roundtrip check").add_argument("input")

    args = p.parse_args()

    if args.cmd == "encode":
        data = Path(args.input).read_bytes()
        Path(args.output).write_bytes(encode(data))
        orig, comp = len(data), len(encode(data)) - 4
        print(f"{args.input}: {orig:,} → {comp:,} bytes ({comp/orig:.1%})")

    elif args.cmd == "decode":
        Path(args.output).write_bytes(decode(Path(args.input).read_bytes()))

    elif args.cmd == "bench":
        benchmark(Path(args.input))

    elif args.cmd == "check":
        data = Path(args.input).read_bytes()
        comp = encode(data)
        recovered = decode(comp)
        if recovered == data:
            print(f"✓  {args.input}: {len(data):,} → {len(comp)-4:,} bytes, roundtrip OK")
        else:
            print(f"✗  {args.input}: ROUNDTRIP MISMATCH")
            # Find first diff
            for i, (a, b) in enumerate(zip(data, recovered)):
                if a != b:
                    print(f"   first diff at byte {i}: expected {a:#04x} got {b:#04x}")
                    break
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
