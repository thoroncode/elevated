#!/usr/bin/env python3
"""Compare embedded MSL source size against precompiled Metal library sizes."""

from __future__ import annotations

import ast
import pathlib
import re
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent
SHADER_HDR = ROOT / "shaders.h"
SHADER_SRC = (ROOT / "../elevated/ElevatedCore/Shaders.metal").resolve()


def parse_embedded_source(header: pathlib.Path) -> bytes:
    lines = header.read_text().splitlines()
    try:
        start = lines.index("static const char kMSLSource[] =") + 1
    except ValueError as exc:
        raise SystemExit("kMSLSource not found in shaders.h") from exc
    parts = []
    for line in lines[start:]:
        if line.strip() == ";":
            break
        parts.extend(re.findall(r'"(?:[^"\\]|\\.)*"', line))
    data = bytearray()
    for part in parts:
        data.extend(ast.literal_eval(part).encode("utf-8"))
    return bytes(data)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def build_variant(src: pathlib.Path, flags: list[str]) -> tuple[int, int]:
    with tempfile.TemporaryDirectory() as td:
        td_path = pathlib.Path(td)
        air = td_path / "shader.air"
        lib = td_path / "shader.metallib"
        run(["xcrun", "-sdk", "macosx", "metal", *flags, "-c", str(src), "-o", str(air)])
        run(["xcrun", "-sdk", "macosx", "metallib", str(air), "-o", str(lib)])
        return air.stat().st_size, lib.stat().st_size


def main() -> int:
    variants: list[tuple[str, list[str]]] = [
        ("source-inline", []),
        ("metallib-baseline", ["-Os"]),
        ("metallib-smallest", ["-Oz", "-Qn"]),
    ]

    embedded = parse_embedded_source(SHADER_HDR)

    print("=== Shader Format Compare ===")
    print(f"Source file:              {SHADER_SRC}")
    print(f"Generated header:         {SHADER_HDR.name} ({SHADER_HDR.stat().st_size} B)")
    print(f"Embedded source payload:  {len(embedded)} B")
    print()
    print("Variant                  AIR bytes   MetalLib bytes   Delta vs embedded")
    print("-----------------------------------------------------------------------")
    print(f"{variants[0][0]:22} {'-':>9} {'-':>16} {0:>19}")

    best_name = None
    best_air = None
    best_lib = None
    for name, flags in variants[1:]:
        air_sz, lib_sz = build_variant(SHADER_SRC, flags)
        delta = lib_sz - len(embedded)
        print(f"{name:22} {air_sz:9} {lib_sz:16} {delta:19}")
        if best_lib is None or lib_sz < best_lib:
            best_name = name
            best_air = air_sz
            best_lib = lib_sz

    assert best_name is not None and best_air is not None and best_lib is not None
    print()
    if best_lib >= len(embedded):
        print(
            f"Recommendation: keep embedded source for now; best compiled blob "
            f"({best_name}, {best_lib} B) is {best_lib - len(embedded)} B larger."
        )
    else:
        print(
            f"Recommendation: compiled blob wins; best variant "
            f"({best_name}, {best_lib} B) saves {len(embedded) - best_lib} B."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
