#!/usr/bin/env bash
# wine_dump.sh — run elevated.exe under Wine, let Crinkler decompress,
# then use lldb to dump the 0x400000–0x500000 region (1 MB).
#
# Usage:  ./wine_dump.sh [exe] [out.bin]
set -euo pipefail

EXE="${1:-elevated_1920_1080.exe}"
OUT="${2:-elevated_wine_dump.bin}"
TMP_SCRIPT="/tmp/lldb_memdump.txt"

echo "Launching $EXE under Wine…"
WINEDEBUG=-all wine "$EXE" &>/dev/null &
WINE_PID=$!
echo "  Wine top-level PID: $WINE_PID"

# Wait for Crinkler to decompress — it's fast at native x86 speed
echo "  Waiting 2 s for Crinkler to finish…"
sleep 2

# Find the child process that is actually running the Windows exe.
# Wine spawns a child (the 'wineloader') which holds the exe's address space.
CHILD_PID=$(pgrep -P $WINE_PID | head -1 || echo "")
TARGET_PID="${CHILD_PID:-$WINE_PID}"
echo "  Attaching to PID $TARGET_PID"

# Write an lldb batch script: attach, dump 1 MB from 0x400000, quit.
cat > "$TMP_SCRIPT" <<EOF
process attach --pid $TARGET_PID
memory read --binary --force --outfile /tmp/wine_memdump.bin --count 1048576 0x400000
process detach
quit
EOF

echo "  Running lldb memory dump…"
lldb --batch --source "$TMP_SCRIPT" 2>&1 | grep -v "^$" | head -30

echo "  Killing Wine…"
kill $WINE_PID 2>/dev/null || true
wait $WINE_PID 2>/dev/null || true

if [[ ! -f /tmp/wine_memdump.bin ]]; then
    echo "ERROR: /tmp/wine_memdump.bin not created — dump failed"
    exit 1
fi

mv /tmp/wine_memdump.bin "$OUT"
echo ""
echo "Dump saved → $OUT  ($(wc -c < "$OUT") bytes)"
echo ""

# Scan for readable text strings (HLSL keyword check)
echo "Scanning for text strings >= 30 chars…"
python3 - "$OUT" <<'PYEOF'
import sys, re

data = open(sys.argv[1], 'rb').read()
text = data.decode('latin-1')
matches = list(re.finditer(r'[ -~]{30,}', text))
print(f"  Found {len(matches)} strings")
for m in matches[:60]:
    addr = 0x400000 + m.start()
    s = m.group()[:100]
    print(f"  @0x{addr:08x} [{len(m.group()):4}]: {s}")
PYEOF
