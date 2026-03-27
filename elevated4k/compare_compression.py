#!/usr/bin/env python3
"""Compare xz/lzma/gzip compression options on the stripped 4K binary.

Usage:
    python3 compare_compression.py <stripped-binary>

Ranks every candidate by compressed size and shows what fits in 4096 bytes
when combined with the self-extracting shell launcher stub.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

# Honour Homebrew on Apple Silicon even when launched from a bare make session.
os.environ.setdefault("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
XZ = shutil.which("xz") or "xz"

TARGET = 4096
# Shell launcher stub that will prefix the compressed binary.
# tail skips to byte OFFSET (placeholder), xz -d decompresses, exec runs it.
STUB_TEMPLATE = "#!/bin/sh\nt=$(mktemp);tail -c +{offset} \"$0\"|xz -d>$t;chmod +x $t;$t;rm $t;exit\n"


def compress(data: bytes, args: list[str]) -> bytes | None:
    """Run xz with given args, return compressed bytes or None on failure."""
    try:
        result = subprocess.run(
            [XZ, "--stdout", *args],
            input=data,
            capture_output=True,
        )
        if result.returncode != 0:
            return None
        return result.stdout
    except FileNotFoundError:
        print(f"ERROR: xz not found (tried: {XZ}). Install it: brew install xz", file=sys.stderr)
        sys.exit(1)


def gzip_compress(data: bytes, level: int) -> bytes | None:
    try:
        import gzip
        return gzip.compress(data, compresslevel=level)
    except Exception:
        return None


def _compute_stub() -> str:
    """Return stub with the correct self-referential offset (handles digit changes)."""
    offset = 1
    for _ in range(8):
        stub = STUB_TEMPLATE.format(offset=offset)
        needed = len(stub.encode()) + 1
        if needed == offset:
            return stub
        offset = needed
    raise RuntimeError("stub offset did not converge")

_STUB = _compute_stub()
_STUB_LEN = len(_STUB.encode())


def stub_size(compressed: bytes) -> tuple[int, str]:
    """Return total (stub + compressed) size and stub text."""
    return _STUB_LEN + len(compressed), _STUB


def bar(ratio: float, width: int = 30) -> str:
    filled = int(ratio * width)
    return "█" * filled + "░" * (width - filled)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <stripped-binary>")
        sys.exit(1)

    binary = Path(sys.argv[1])
    if not binary.exists():
        print(f"ERROR: {binary} not found")
        sys.exit(1)

    data = binary.read_bytes()
    raw_size = len(data)

    print(f"\n=== Compression Comparison for {binary.name} ({raw_size:,} bytes) ===")
    print(f"Target: {TARGET} bytes total (stub + compressed)")
    print()

    candidates = []

    # ── xz with lzma2 (default), presets 1–9 and 9e ─────────────────────────
    for level in range(1, 10):
        tag = f"xz -{level}"
        comp = compress(data, [f"-{level}"])
        if comp:
            candidates.append((tag, comp, [f"-{level}"]))

    tag = "xz -9e"
    comp = compress(data, ["-9", "--extreme"])
    if comp:
        candidates.append((tag, comp, ["-9", "--extreme"]))

    # ── lzma1 format (compatible with Compression.framework COMPRESSION_LZMA) ─
    for level in (6, 9):
        tag = f"lzma -{level}"
        comp = compress(data, [f"-{level}", "--format=lzma"])
        if comp:
            candidates.append((tag, comp, [f"-{level}", "--format=lzma"]))

    tag = "lzma -9e"
    comp = compress(data, ["-9", "--extreme", "--format=lzma"])
    if comp:
        candidates.append((tag, comp, ["-9", "--extreme", "--format=lzma"]))

    # ── xz with x86 BCJ filter (helps Mach-O x86_64 code sections) ──────────
    for level in (9,):
        tag = f"xz -9e +x86"
        comp = compress(data, ["-9", "--extreme", "--x86"])
        if comp:
            candidates.append((tag, comp, ["-9", "--extreme", "--x86"]))

    # ── xz with delta filter (helps periodic data like synth tables) ─────────
    for dist in (1, 2, 4, 8):
        tag = f"xz -9e +delta{dist}"
        comp = compress(data, ["-9", "--extreme", f"--delta=dist={dist}"])
        if comp:
            candidates.append((tag, comp, ["-9", "--extreme", f"--delta=dist={dist}"]))

    # ── gzip for baseline comparison ─────────────────────────────────────────
    for level in (9,):
        tag = f"gzip -{level}"
        comp = gzip_compress(data, level)
        if comp:
            candidates.append((tag, comp, []))   # no xz args, gzip only

    # ── Sort by compressed size ───────────────────────────────────────────────
    candidates.sort(key=lambda x: len(x[1]))

    best_size = len(candidates[0][1]) if candidates else raw_size
    header = f"  {'Method':<20} {'Compressed':>10} {'+ Stub':>8} {'Ratio':>7}  {'vs best':>8}  Bar"
    print(header)
    print("  " + "─" * (len(header) - 2))

    winner_tag = None
    for tag, comp, _ in candidates:
        total, stub = stub_size(comp)
        ratio = len(comp) / raw_size
        vs_best = len(comp) - best_size
        fits = total <= TARGET
        marker = " ◀ FITS 4K!" if fits else ""
        if fits and winner_tag is None:
            winner_tag = tag
        print(
            f"  {tag:<20} {len(comp):>10,} {total:>8,} {ratio:>7.1%}"
            f"  {vs_best:>+7,}b  {bar(ratio)}{marker}"
        )

    print()

    best_tag, best_comp, best_args = candidates[0]
    best_total, best_stub = stub_size(best_comp)
    print(f"Best method : {best_tag}  ({len(best_comp):,} bytes compressed)")
    print(f"With stub   : {best_total:,} bytes total")
    if best_total <= TARGET:
        print(f"✓ Fits in {TARGET} bytes!")
    else:
        over = best_total - TARGET
        print(f"✗ {over:,} bytes over {TARGET} — need to shrink binary further")

    print()
    print(f"To pack with best method:")
    xz_flags = " ".join(best_args) if best_args else "-9"
    print(f"  make pack XZ_FLAGS='{xz_flags}'")


if __name__ == "__main__":
    main()
