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

    def try_xz(tag, args):
        comp = compress(data, args)
        if comp:
            candidates.append((tag, comp, args))
        # silently skip failures (unsupported filter combos, etc.)

    # ── Plain lzma2 baselines ─────────────────────────────────────────────────
    try_xz("xz -6",          ["-6"])
    try_xz("xz -9",          ["-9"])
    try_xz("xz -9e",         ["-9", "--extreme"])
    try_xz("lzma -9e",       ["-9", "--extreme", "--format=lzma"])

    # ── ARM64 BCJ filter ─────────────────────────────────────────────────────
    # Converts relative branch/call offsets to absolute addresses so lzma2
    # can find matches across longer distances. Key for ARM64 Mach-O binaries.
    # Note: must use --lzma2=preset=N, not -N, when combining with BCJ flags.
    A64 = ["--arm64"]
    for nice in (64, 128, 273):
        try_xz(f"arm64 nice={nice}",
               A64 + [f"--lzma2=preset=9e,mf=bt4,nice={nice},depth=0"])

    # lc (literal context bits): higher = more context for literal coding.
    # lc+lp must not exceed 4. lp=0 is default (fine for code).
    for lc in (2, 3, 4):
        try_xz(f"arm64 lc={lc}",
               A64 + [f"--lzma2=preset=9e,lc={lc},mf=bt4,nice=273,depth=0"])

    # lc=2, lp=2: position-aware literals (lp helps aligned data like tables).
    try_xz("arm64 lc=2 lp=2",
           A64 + ["--lzma2=preset=9e,lc=2,lp=2,mf=bt4,nice=273,depth=0"])

    # pb (position bits): default 2, try 0 (good for code with no alignment).
    try_xz("arm64 pb=0",
           A64 + ["--lzma2=preset=9e,pb=0,mf=bt4,nice=273,depth=0"])
    try_xz("arm64 pb=0 lc=4",
           A64 + ["--lzma2=preset=9e,lc=4,pb=0,mf=bt4,nice=273,depth=0"])

    # Larger dict: probably no help on a 50 KB binary but worth confirming.
    try_xz("arm64 dict=16MiB",
           A64 + ["--lzma2=preset=9e,dict=16MiB,mf=bt4,nice=273,depth=0"])

    # ── Delta filter on raw binary (helps synth table blobs) ─────────────────
    for dist in (1, 2, 4, 8):
        try_xz(f"delta={dist} -9e",
               [f"--delta=dist={dist}",
                "--lzma2=preset=9e,mf=bt4,nice=273,depth=0"])

    # ── ARM64 BCJ + delta via --filters string syntax ─────────────────────────
    # filter chain: arm64 BCJ → delta → lzma2
    for dist in (1, 2):
        try_xz(f"arm64+delta={dist}",
               [f"--filters=arm64--delta=dist={dist}--lzma2=preset=9e,mf=bt4,nice=273"])

    # ── gzip baseline ─────────────────────────────────────────────────────────
    comp = gzip_compress(data, 9)
    if comp:
        candidates.append(("gzip -9", comp, []))

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
