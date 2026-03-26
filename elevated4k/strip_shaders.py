#!/usr/bin/env python3
# Reads a .metal file, strips all comments and blank lines,
# and emits a C string literal body for inclusion in shaders.h.
import re, sys

src = open(sys.argv[1]).read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)  # block comments
src = re.sub(r'//[^\n]*', '', src)                     # line comments
src = re.sub(r'\n{3,}', '\n\n', src)                   # collapse blank lines

for line in src.splitlines():
    if line.strip():
        esc = line.replace('\\', '\\\\').replace('"', '\\"')
        print('    "%s\\n"' % esc)
