#!/usr/bin/env bash
# Compare reference frames vs captured frames side-by-side.
#
# Usage:
#   ./tools/compare.sh              # compare all matching pairs, open in Preview
#   ./tools/compare.sh 42           # compare only second 42
#   ./tools/compare.sh 10 20        # compare seconds 10-20
#
# Requires: ffmpeg, open (macOS)
# Reference frames: /tmp/elevated_ref/ref_XXXX.png
# Captured frames:  /tmp/elevated_cap/cap_XXXX.png

set -euo pipefail

REF="/tmp/elevated_ref"
CAP="/tmp/elevated_cap"
CMP="/tmp/elevated_cmp"

mkdir -p "$CMP"

if [[ $# -eq 0 ]]; then
    FRAMES=$(ls "$REF"/ref_*.png 2>/dev/null | sed 's/.*ref_\([0-9]*\)\.png/\1/' | sort -n)
elif [[ $# -eq 1 ]]; then
    FRAMES=$(printf "%04d" "$1")
else
    FRAMES=$(seq -f "%04g" "$1" "$2")
fi

COUNT=0
MISSING=0

for N in $FRAMES; do
    R="$REF/ref_${N}.png"
    C="$CAP/cap_${N}.png"
    O="$CMP/cmp_${N}.png"

    if [[ ! -f "$R" ]]; then
        echo "  skip $N — no reference"
        (( MISSING++ )) || true
        continue
    fi
    if [[ ! -f "$C" ]]; then
        echo "  skip $N — no capture"
        (( MISSING++ )) || true
        continue
    fi

    # Side-by-side with labels and diff highlight
    ffmpeg -y -loglevel error \
        -i "$R" -i "$C" \
        -filter_complex "
            [0]drawtext=text='REF t=%{pts\\:hms}':x=10:y=10:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.5[left];
            [1]drawtext=text='PORT':x=10:y=10:fontsize=18:fontcolor=lime:box=1:boxcolor=black@0.5[right];
            [left][right]hstack=inputs=2[side];
            [0][1]blend=all_mode=difference,eq=contrast=8[diff];
            [diff]scale=1280:720[diffscaled];
            [diffscaled]drawtext=text='DIFF (×8 contrast)':x=10:y=10:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.5[difflab];
            [side][difflab]vstack=inputs=2
        " \
        -frames:v 1 \
        "$O" 2>&1 | grep -v "^$" || true

    echo "  → $O"
    (( COUNT++ )) || true
done

echo ""
echo "Generated $COUNT comparison images in $CMP/  ($MISSING skipped)"

if [[ $COUNT -gt 0 ]]; then
    # Open all comparison images in Preview
    open "$CMP"/cmp_*.png
fi
