#!/usr/bin/env python3
"""Report the binary floor for tiny macOS hello executables."""

from __future__ import annotations

import shutil
import signal
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


PAGE_SIZE = 0x4000
INTERESTING_LOADS = {
    "LC_MAIN",
    "LC_UNIXTHREAD",
    "LC_LOAD_DYLINKER",
    "LC_LOAD_DYLIB",
    "LC_DYLD_CHAINED_FIXUPS",
    "LC_DYLD_EXPORTS_TRIE",
    "LC_UUID",
    "LC_CODE_SIGNATURE",
}


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, errors="replace")


def parse_segments(path: Path) -> tuple[list[dict], list[str]]:
    lines = run("otool", "-l", str(path)).splitlines()
    segments = []
    load_commands = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("cmd LC_"):
            load_commands.append(line.split(None, 1)[1])
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
    return segments, load_commands


def parse_imports(path: Path) -> list[tuple[str, str]]:
    rows = []
    result = subprocess.run(
        ["nm", "-um", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        return rows
    for line in result.stdout.splitlines():
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


def describe_file(path: Path) -> str:
    return run("file", str(path)).strip().split(": ", 1)[1]


def format_output(data: bytes) -> str:
    if not data:
        return "(empty)"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return data.hex(" ")
    return repr(text)


def format_status(returncode: int | None, error: str | None = None, timed_out: bool = False) -> str:
    if timed_out:
        return "timeout"
    if error:
        return error
    assert returncode is not None
    if returncode < 0:
        sig = -returncode
        try:
            name = signal.Signals(sig).name
        except ValueError:
            name = f"SIG{sig}"
        return f"signal {sig} ({name}), shell rc {128 + sig}"
    return f"exit {returncode}"


def probe_run(path: Path) -> dict[str, object]:
    try:
        result = subprocess.run(
            [str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            check=False,
        )
    except FileNotFoundError as exc:
        return {"status": str(exc)}
    except PermissionError as exc:
        return {"status": str(exc)}
    except OSError as exc:
        return {"status": str(exc)}
    except subprocess.TimeoutExpired as exc:
        return {
            "status": format_status(None, timed_out=True),
            "stdout": exc.stdout or b"",
            "stderr": exc.stderr or b"",
        }

    return {
        "status": format_status(result.returncode),
        "stdout": result.stdout,
        "stderr": result.stderr,
    }


def probe_signed_run(path: Path) -> dict[str, object]:
    with tempfile.TemporaryDirectory() as tmp:
        signed = Path(tmp) / path.name
        shutil.copy2(path, signed)
        sign = subprocess.run(
            ["codesign", "-s", "-", str(signed)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if sign.returncode != 0:
            stderr = (sign.stderr or sign.stdout).strip().splitlines()
            detail = stderr[0] if stderr else "codesign failed"
            return {"status": detail}

        run_result = probe_run(signed)
        run_result["size"] = signed.stat().st_size
        return run_result


def print_binary_report(path: Path) -> None:
    size = path.stat().st_size
    kind = describe_file(path)
    segments, load_commands = parse_segments(path)
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
    unsigned_probe = probe_run(path)
    signed_probe = probe_signed_run(path)

    print()
    print(f"{path.name}: {size} bytes ({size / 1024:.1f} KB)")
    print(f"Kind: {kind}")
    loads = [cmd for cmd in load_commands if cmd in INTERESTING_LOADS]
    if loads:
        print("Load Commands:")
        for cmd in loads:
            print(f"  {cmd}")

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
    if not imports:
        print("  (none)")
    else:
        for dylib, count in sorted(import_counts.items()):
            print(f"  {dylib:<14} {count:>2d}")
        for symbol, dylib in imports:
            print(f"    {basename_dylib(dylib):<14} {symbol}")

    print("Launchability:")
    print(f"  unsigned            {unsigned_probe['status']}")
    stdout = unsigned_probe.get("stdout", b"")
    stderr = unsigned_probe.get("stderr", b"")
    if stdout:
        print(f"    stdout            {format_output(stdout)}")
    if stderr:
        first = stderr.decode('utf-8', errors='replace').splitlines()[0]
        print(f"    stderr            {first}")

    signed_status = signed_probe["status"]
    if "size" in signed_probe:
        signed_size = signed_probe["size"]
        delta = signed_size - size
        print(f"  signed temp copy    {signed_status}")
        print(f"    size              {signed_size} B ({delta:+d} B)")
        stdout = signed_probe.get("stdout", b"")
        stderr = signed_probe.get("stderr", b"")
        if stdout:
            print(f"    stdout            {format_output(stdout)}")
        if stderr:
            first = stderr.decode('utf-8', errors='replace').splitlines()[0]
            print(f"    stderr            {first}")
    else:
        print(f"  signed temp copy    {signed_status}")

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
