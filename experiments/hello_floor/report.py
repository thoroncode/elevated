#!/usr/bin/env python3
"""Report the binary floor for tiny macOS hello executables."""

from __future__ import annotations

import subprocess
import sys
from collections import Counter
from pathlib import Path


PAGE_SIZE = 0x4000


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, errors="replace")


def parse_segments(path: Path) -> list[dict]:
    lines = run("otool", "-l", str(path)).splitlines()
    segments = []
    i = 0
    while i < len(lines):
        if lines[i].strip() != "cmd LC_SEGMENT_64":
            i += 1
            continue

        segment = {"sections": []}
        i += 1
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("Load command "):
                break
            if line == "Section":
                section = {}
                i += 1
                while i < len(lines):
                    line = lines[i].strip()
                    if line == "Section" or line.startswith("Load command "):
                        break
                    parts = line.split(None, 1)
                    if len(parts) == 2:
                        key, value = parts
                        if key in {"sectname", "segname"}:
                            section[key] = value
                        elif key in {"size", "offset"}:
                            section[key] = int(value, 0)
                    i += 1
                segment["sections"].append(section)
                continue

            parts = line.split(None, 1)
            if len(parts) == 2:
                key, value = parts
                if key == "segname":
                    segment["segname"] = value
                elif key in {"fileoff", "filesize"}:
                    segment[key] = int(value, 0)
            i += 1

        segments.append(segment)
    return segments


def parse_imports(path: Path) -> list[tuple[str, str]]:
    rows = []
    for line in run("nm", "-um", str(path)).splitlines():
        line = line.strip()
        if "(undefined)" not in line or " external " not in line:
            continue
        symbol = line.split(" external ", 1)[1]
        dylib = "?"
        if " (from " in symbol:
            symbol, dylib = symbol.split(" (from ", 1)
            dylib = dylib.rstrip(")")
        rows.append((symbol, dylib))
    return rows


def basename_dylib(name: str) -> str:
    if name.startswith("lib"):
        return name
    return name.rsplit("/", 1)[-1].removesuffix(".framework").removesuffix(".dylib")


def fmt_bytes(value: int) -> str:
    return f"{value:>6d} B"


def print_binary_report(path: Path) -> None:
    size = path.stat().st_size
    segments = parse_segments(path)
    imports = parse_imports(path)
    file_sections = [
        (section["segname"], section["sectname"], section["size"])
        for segment in segments
        for section in segment["sections"]
        if section.get("offset", 0) != 0 and section.get("size", 0) > 0
    ]
    payload = sum(row[2] for row in file_sections)
    linkedit = next((segment for segment in segments if segment.get("segname") == "__LINKEDIT"), None)
    if linkedit:
        payload += linkedit.get("filesize", 0)
    padding = max(0, size - payload)
    import_counts = Counter(basename_dylib(dylib) for _, dylib in imports)

    print()
    print(f"{path.name}: {size} bytes ({size / 1024:.1f} KB)")
    print("Segments:")
    for segment in segments:
        if segment.get("filesize", 0) == 0:
            continue
        pages = (segment["filesize"] + PAGE_SIZE - 1) // PAGE_SIZE
        print(f"  {segment['segname']:<12} {fmt_bytes(segment['filesize'])}  {pages} page(s)")

    print("Sections:")
    for segname, sectname, section_size in sorted(file_sections, key=lambda row: row[2], reverse=True):
        print(f"  {segname},{sectname:<18} {fmt_bytes(section_size)}")

    print("Imports:")
    for dylib, count in sorted(import_counts.items()):
        print(f"  {dylib:<14} {count:>2d}")
    for symbol, dylib in imports:
        print(f"    {basename_dylib(dylib):<14} {symbol}")

    print("Overhead:")
    print(f"  payload              {fmt_bytes(payload)}")
    print(f"  headers/padding      {fmt_bytes(padding)}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: report.py <binary> [<binary> ...]", file=sys.stderr)
        return 2

    for arg in sys.argv[1:]:
        print_binary_report(Path(arg))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
