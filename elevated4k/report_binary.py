#!/usr/bin/env python3
"""Print a compact size report for the 4K prototype binary."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


KNOWN_CONST_SYMBOLS = [
    "_kSyncData",
    "_kMSLSource",
    "_machine_tree_data",
    "_ENV_STOP",
    "_ENV_NORMAL",
    "_sequence_data",
    "_pattern_data",
]

PRESSURE_SECTIONS = {
    ("__TEXT", "__objc_methname"): "Objective-C method names",
    ("__TEXT", "__objc_stubs"): "Objective-C message stubs",
    ("__DATA", "__objc_selrefs"): "Objective-C selector refs",
    ("__TEXT", "__objc_methtype"): "Objective-C method types",
    ("__DATA", "__objc_const"): "Objective-C class/protocol metadata",
    ("__DATA_CONST", "__cfstring"): "CFString records",
}

SURVIVING_STRING_HINTS = [
    "Elevated",
    "Shader error: %@",
    "terrainVert",
    "fullscreenVert",
    "deferredFrag",
    "postFrag",
    "MetalView",
    "AppDelegate",
]

CREDIT_KEYWORDS = [
    "rgba",
    "tbc",
    "breakpoint",
    "mentor",
    "blueberry",
    "puryx",
    "iq",
    "credits",
    "gargaj",
    "music by",
    "code by",
    "graphics by",
]


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, errors="replace")


def fmt_bytes(count: int) -> str:
    return f"{count:>7d} B"


def fmt_pct(value: float) -> str:
    return f"{value:5.1f}%"


def parse_segment_layout(path: Path) -> list[dict]:
    lines = run("otool", "-l", str(path)).splitlines()
    segments = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line != "cmd LC_SEGMENT_64":
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
                        elif key in {"addr", "size", "offset"}:
                            section[key] = int(value, 0)
                    i += 1
                segment["sections"].append(section)
                continue

            parts = line.split(None, 1)
            if len(parts) == 2:
                key, value = parts
                if key == "segname":
                    segment["segname"] = value
                elif key in {"vmaddr", "vmsize", "fileoff", "filesize"}:
                    segment[key] = int(value, 0)
            i += 1

        segments.append(segment)
    return segments


def parse_symbols(path: Path) -> dict[str, int]:
    symbols = {}
    for line in run("nm", "-nm", str(path)).splitlines():
        parts = line.split()
        if not parts:
            continue
        head = parts[0]
        if not all(ch in "0123456789abcdefABCDEF" for ch in head):
            continue
        symbols[parts[-1]] = int(head, 16)
    return symbols


def file_backed_sections(segments: list[dict]) -> list[tuple[str, str, int]]:
    result = []
    for segment in segments:
        for section in segment["sections"]:
            if section.get("offset", 0) == 0:
                continue
            result.append((segment["segname"], section["sectname"], section["size"]))
    return result


def segment_by_name(segments: list[dict], name: str) -> dict | None:
    for segment in segments:
        if segment.get("segname") == name:
            return segment
    return None


def strings_output(path: Path) -> list[str]:
    return run("strings", "-a", "-n", "4", str(path)).splitlines()


def print_header(title: str) -> None:
    print()
    print(f"=== {title} ===")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: report_binary.py <unstripped> <stripped>", file=sys.stderr)
        return 2

    unstripped = Path(sys.argv[1])
    stripped = Path(sys.argv[2])
    if not unstripped.exists():
        print(f"missing unstripped binary: {unstripped}", file=sys.stderr)
        return 1
    if not stripped.exists():
        print(f"missing stripped binary: {stripped}", file=sys.stderr)
        return 1

    file_size = stripped.stat().st_size
    segments = parse_segment_layout(stripped)
    symbols = parse_symbols(unstripped)
    section_rows = file_backed_sections(segments)
    string_rows = strings_output(stripped)

    text_const = next(
        (s for seg in segments for s in seg["sections"] if seg.get("segname") == "__TEXT" and s.get("sectname") == "__const"),
        None,
    )

    known_blobs = []
    if text_const:
        const_end = text_const["addr"] + text_const["size"]
        for idx, name in enumerate(KNOWN_CONST_SYMBOLS):
            start = symbols.get(name)
            if start is None:
                continue
            if idx + 1 < len(KNOWN_CONST_SYMBOLS):
                end = symbols.get(KNOWN_CONST_SYMBOLS[idx + 1], const_end)
            else:
                end = const_end
            known_blobs.append((name, max(0, end - start)))

    linkedit = segment_by_name(segments, "__LINKEDIT")
    section_bytes = sum(size for _, _, size in section_rows)
    if linkedit:
        section_bytes += linkedit.get("filesize", 0)
    padding_overhead = max(0, file_size - section_bytes)

    original_exe = unstripped.parent.parent / "elevated_1920_1080.exe"

    print_header("4K Binary Report")
    print(f"Unstripped: {unstripped}")
    print(f"Stripped:   {stripped}")
    print(f"Final size: {file_size} bytes ({file_size / 1024:.1f} KB)")
    if original_exe.exists():
        original_size = original_exe.stat().st_size
        ratio = file_size / original_size if original_size else 0.0
        print(f"Original EXE: {original_size} bytes ({ratio:.2f}x larger)")
    else:
        print("Original EXE: not present in this checkout")

    print_header("On-disk Segments")
    for segment in segments:
        size = segment.get("filesize", 0)
        if size == 0:
            continue
        print(f"{segment['segname']:<12} {fmt_bytes(size)}  {fmt_pct(size / file_size * 100.0)}")

    print_header("Top File-backed Sections")
    for segname, sectname, size in sorted(section_rows, key=lambda item: item[2], reverse=True)[:10]:
        print(f"{segname},{sectname:<18} {fmt_bytes(size)}")

    if known_blobs:
        print_header("Known Payload Blobs")
        for name, size in known_blobs:
            print(f"{name:<20} {fmt_bytes(size)}")

    pressure_rows = []
    for key, label in PRESSURE_SECTIONS.items():
        segname, sectname = key
        for row in section_rows:
            if row[0] == segname and row[1] == sectname:
                pressure_rows.append((label, row[2]))
                break
    if pressure_rows:
        print_header("Metadata Pressure")
        for label, size in sorted(pressure_rows, key=lambda item: item[1], reverse=True):
            print(f"{label:<30} {fmt_bytes(size)}")

    print_header("File Layout Overhead")
    print(f"Section/linker payload   {fmt_bytes(section_bytes)}")
    print(f"Headers/page padding     {fmt_bytes(padding_overhead)}  {fmt_pct(padding_overhead / file_size * 100.0)}")

    print_header("String Check")
    lower_strings = [row.lower() for row in string_rows]
    hits = [keyword for keyword in CREDIT_KEYWORDS if any(keyword in row for row in lower_strings)]
    if hits:
        print("Credit-like strings found: " + ", ".join(sorted(set(hits))))
    else:
        print("Credit-like strings found: none")

    survivors = [label for label in SURVIVING_STRING_HINTS if label in string_rows]
    if survivors:
        print("Readable strings still present: " + ", ".join(survivors))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
