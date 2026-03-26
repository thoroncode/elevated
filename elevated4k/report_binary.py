#!/usr/bin/env python3
"""Print a compact size report for the 4K prototype binary."""

from __future__ import annotations

import os
import subprocess
import sys
from collections import Counter
from pathlib import Path


PAGE_SIZE = 0x4000

KNOWN_CONST_SYMBOLS = [
    "_kSyncData",
    "_kMSLSource",
    "_kMachineTreeDataPacked",
    "_ENV_STOP",
    "_ENV_NORMAL",
    "_kSequenceDataPacked",
    "_kPatternDataPacked",
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


def parse_symbols(path: Path) -> tuple[dict[str, tuple[int, str]], list[tuple[int, str, str]]]:
    by_name = {}
    by_addr = []
    for line in run("nm", "-nm", str(path)).splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        head = parts[0]
        if not all(ch in "0123456789abcdefABCDEF" for ch in head):
            continue
        section = parts[1].strip("()")
        name = parts[-1]
        addr = int(head, 16)
        by_name[name] = (addr, section)
        by_addr.append((addr, section, name))
    by_addr.sort()
    return by_name, by_addr


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


def section_by_name(segments: list[dict], segname: str, sectname: str) -> dict | None:
    for segment in segments:
        if segment.get("segname") != segname:
            continue
        for section in segment["sections"]:
            if section.get("sectname") == sectname:
                return section
    return None


def read_section_bytes(path: Path, section: dict) -> bytes:
    offset = section.get("offset", 0)
    size = section.get("size", 0)
    with path.open("rb") as handle:
        handle.seek(offset)
        return handle.read(size)


def parse_cstrings(path: Path, segments: list[dict]) -> list[str]:
    section = section_by_name(segments, "__TEXT", "__cstring")
    if not section:
        return []

    blob = read_section_bytes(path, section)
    strings = []
    for row in blob.split(b"\x00"):
        if not row:
            continue
        strings.append(row.decode("utf-8", errors="replace"))
    return strings


def shorten(text: str, limit: int = 72) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def parse_imports(path: Path) -> list[tuple[str, str]]:
    imports = []
    for line in run("nm", "-um", str(path)).splitlines():
        line = line.strip()
        if "(undefined)" not in line or " external " not in line:
            continue

        symbol = line.split(" external ", 1)[1]
        dylib = "?"
        if " (from " in symbol:
            symbol, dylib = symbol.split(" (from ", 1)
            dylib = dylib.rstrip(")")
        imports.append((symbol, dylib))
    return imports


def basename_dylib(name: str) -> str:
    if name.startswith("lib"):
        return name
    return name.rsplit("/", 1)[-1].removesuffix(".framework").removesuffix(".dylib")


def segment_used_span(segment: dict) -> int:
    sections = [section for section in segment["sections"] if section.get("offset", 0) >= segment.get("fileoff", 0)]
    if not sections:
        return 0
    used_end = max(section["offset"] + section["size"] for section in sections)
    return max(0, used_end - segment.get("fileoff", 0))


def page_blocker_rows(segments: list[dict]) -> list[dict]:
    rows = []
    for segment in segments:
        filesize = segment.get("filesize", 0)
        if filesize == 0:
            continue
        used_span = segment_used_span(segment)
        if used_span == 0:
            continue
        pages = (filesize + PAGE_SIZE - 1) // PAGE_SIZE
        previous_boundary = max(0, (pages - 1) * PAGE_SIZE)
        rows.append(
            {
                "segname": segment["segname"],
                "used_span": used_span,
                "pages": pages,
                "tail_slack": max(0, filesize - used_span),
                "cut_to_previous": max(0, used_span - previous_boundary),
            }
        )
    return rows


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
    symbols, symbol_rows = parse_symbols(unstripped)
    section_rows = file_backed_sections(segments)
    string_rows = strings_output(stripped)
    cstring_rows = parse_cstrings(stripped, segments)
    imports = parse_imports(unstripped)
    page_rows = page_blocker_rows(segments)

    text_const = section_by_name(segments, "__TEXT", "__const")
    text_cstring = section_by_name(segments, "__TEXT", "__cstring")

    known_blobs = []
    if text_const:
        const_end = text_const["addr"] + text_const["size"]
        for name in KNOWN_CONST_SYMBOLS:
            info = symbols.get(name)
            if info is None:
                continue
            start, section = info
            if section != "__TEXT,__const":
                continue
            end = const_end
            for addr, row_section, _ in symbol_rows:
                if row_section == "__TEXT,__const" and addr > start:
                    end = addr
                    break
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

    if text_cstring and cstring_rows:
        selector_like = sum(1 for row in cstring_rows if ":" in row)
        class_like = sum(1 for row in cstring_rows if row and row[0].isupper() and ":" not in row)
        print_header("__cstring Focus")
        print(f"Section bytes           {fmt_bytes(text_cstring['size'])}")
        print(f"Decoded strings         {len(cstring_rows):>7d}")
        print(f"Selector-like strings   {selector_like:>7d}")
        print(f"Class-ish strings       {class_like:>7d}")
        print("Longest strings:")
        for row in sorted(cstring_rows, key=len, reverse=True)[:10]:
            print(f"  {len(row):>3d}  {shorten(row)}")

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

    if imports:
        import_counts = Counter(basename_dylib(dylib) for _, dylib in imports)
        print_header("Import Pressure")
        print(f"Imported symbols        {len(imports):>7d}")
        print(f"Imported libraries      {len(import_counts):>7d}")
        print("By library:")
        for dylib, count in import_counts.most_common():
            print(f"  {dylib:<18} {count:>3d}")
        print("Symbols:")
        for symbol, dylib in sorted(imports, key=lambda item: (basename_dylib(item[1]), item[0]))[:16]:
            print(f"  {basename_dylib(dylib):<18} {symbol}")

    if page_rows:
        print_header("Page Boundary Blockers")
        for row in page_rows:
            if row["pages"] > 1:
                target = f"cut {row['cut_to_previous']} B to drop to {row['pages'] - 1} page(s)"
            else:
                target = f"remove {row['cut_to_previous']} B to eliminate this file-backed page"
            print(
                f"{row['segname']:<12} "
                f"used {fmt_bytes(row['used_span'])} in {row['pages']} page(s), "
                f"tail slack {fmt_bytes(row['tail_slack'])}, {target}"
            )

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
