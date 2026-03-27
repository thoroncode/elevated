#!/usr/bin/env python3
"""Build a self-extracting shell launcher around an xz-compressed binary.

Usage:
    python3 make_pack.py <stripped-binary> <output> [xz-flags...]

Example:
    python3 make_pack.py build/ElevatedMac4k.stripped build/ElevatedMac4k.4k -9 --extreme

The output file is a shell script that:
  1. Extracts the appended compressed payload
  2. Decompresses with xz
  3. Writes to a temp file, marks executable, execs it, then cleans up
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
XZ = shutil.which("xz") or "xz"

TARGET = 4096


def compress(data: bytes, xz_args: list[str]) -> bytes:
    try:
        result = subprocess.run(
            [XZ, "--stdout", *xz_args],
            input=data,
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"ERROR: xz failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)
        return result.stdout
    except FileNotFoundError:
        print(f"ERROR: xz not found (tried: {XZ}). Install it: brew install xz", file=sys.stderr)
        sys.exit(1)


def make_stub(offset: int) -> str:
    # tail -c +N is 1-based: byte N is the first byte of the payload.
    # We decompress to a temp file, exec it, clean up on exit.
    return (
        "#!/bin/sh\n"
        f"t=$(mktemp);tail -c +{offset} \"$0\"|xz -d>$t;"
        "chmod +x $t;$t;r=$?;rm $t;exit $r\n"
    )


def compute_stub() -> str:
    """Return the stub with the correct self-referential offset."""
    # The offset is 1-based byte position of the payload in the final file,
    # which equals len(stub) + 1. Iterate until stable (handles digit-count
    # changes, e.g. 9→10 or 99→100 which shift the stub length by 1).
    offset = 1
    for _ in range(8):
        stub = make_stub(offset)
        needed = len(stub.encode()) + 1
        if needed == offset:
            return stub
        offset = needed
    raise RuntimeError("stub offset did not converge")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <stripped-binary> <output> [xz-flags...]")
        sys.exit(1)

    src_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    xz_args = sys.argv[3:] if len(sys.argv) > 3 else ["-9", "--extreme"]

    if not src_path.exists():
        print(f"ERROR: {src_path} not found", file=sys.stderr)
        sys.exit(1)

    data = src_path.read_bytes()
    print(f"Input:    {src_path}  ({len(data):,} bytes)")

    print(f"Compressing with xz {' '.join(xz_args)} ...")
    compressed = compress(data, xz_args)
    print(f"Compressed: {len(compressed):,} bytes")

    stub = compute_stub()
    total = len(stub.encode()) + len(compressed)
    payload = stub.encode() + compressed

    out_path.write_bytes(payload)
    os.chmod(out_path, 0o755)

    print(f"Stub:     {len(stub)} bytes")
    print(f"Output:   {out_path}  ({total:,} bytes total)")

    if total <= TARGET:
        print(f"✓ Fits in {TARGET} bytes!")
    else:
        over = total - TARGET
        print(f"✗ {over:,} bytes over {TARGET} ({total:,} / {TARGET})")


if __name__ == "__main__":
    main()
