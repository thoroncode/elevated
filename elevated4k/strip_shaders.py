#!/usr/bin/env python3
# Reads a .metal file, strips comments, drops blank lines,
# and collapses formatting whitespace so the embedded MSL stays compact.
import re, sys

src = open(sys.argv[1]).read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)  # block comments
src = re.sub(r'//[^\n]*', '', src)                     # line comments
src = re.sub(r'\n{3,}', '\n\n', src)                   # collapse blank lines

for line in src.splitlines():
    if line.strip():
        esc = ' '.join(line.split())
        esc = esc.replace('\\', '\\\\').replace('"', '\\"')
        print('    "%s\\n"' % esc)
