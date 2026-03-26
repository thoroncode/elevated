#!/usr/bin/env python3
# Reads a .metal file, strips comments, and emits a compact embedded MSL string.
import re
import sys


def compact_line(line):
    text = " ".join(line.split())
    if text.startswith("#"):
        return text
    text = re.sub(r"\s*([(){}\[\],;])\s*", r"\1", text)
    text = re.sub(r"\s*([=*/<>?:])\s*", r"\1", text)
    text = re.sub(r"\s*([+\-&|]=)\s*", r"\1", text)
    text = re.sub(
        r"(?<=[A-Za-z0-9_\]\).])\s*([+\-&|])\s*(?=[A-Za-z0-9_(\[\].])",
        r"\1",
        text,
    )
    text = re.sub(r"(?<![A-Za-z0-9_])0\.(\d)", r".\1", text)
    text = re.sub(r"(?<![A-Za-z0-9_])(\d+)\.0(?!\d)", r"\1.", text)
    return re.sub(r"\s+", " ", text)


def needs_space(prev, cur):
    if not prev or not cur:
        return False
    return prev[-1] in "._0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" and cur[0] in "._0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def emit_c_string(text):
    for part in text.splitlines(True):
        has_newline = part.endswith("\n")
        if has_newline:
            part = part[:-1]
        esc = part.replace("\\", "\\\\").replace('"', '\\"')
        while esc:
            chunk = esc[:96]
            esc = esc[96:]
            suffix = "\\n" if has_newline and not esc else ""
            print(f'    "{chunk}{suffix}"')


src = open(sys.argv[1]).read()
src = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
src = re.sub(r"//[^\n]*", "", src)

pieces = []
prev = ""
for raw_line in src.splitlines():
    if not raw_line.strip():
        continue
    line = compact_line(raw_line)
    if line.startswith("#"):
        pieces.append(line + "\n")
        prev = ""
        continue
    if prev and needs_space(prev, line):
        pieces.append(" ")
    pieces.append(line)
    prev = line

emit_c_string("".join(pieces))
