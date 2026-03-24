#!/usr/bin/env bash
# Extract reference frames from elevated_8000.avi at 1 fps.
# Output: /tmp/elevated_ref/ref_XXXX.png  (XXXX = second 0001..0215)
#
# Usage:
#   ./tools/extract_ref.sh               # extract all (215 frames)
#   ./tools/extract_ref.sh 60 90         # only seconds 60-90

set -euo pipefail

AVI="$(dirname "$0")/../elevated_8000.avi"
OUT="/tmp/elevated_ref"

START=${1:-0}
END=${2:-9999}

mkdir -p "$OUT"

echo "Extracting 1fps frames from $AVI → $OUT/"

if [[ "$START" -eq 0 && "$END" -ge 215 ]]; then
    # Full extraction
    ffmpeg -y -i "$AVI" \
        -vf "fps=1,scale=1280:720:flags=lanczos" \
        -vsync vfr \
        -q:v 2 \
        "$OUT/ref_%04d.png"
else
    # Partial: only frames in [START, END] seconds
    DURATION=$(( END - START + 1 ))
    ffmpeg -y -ss "$START" -t "$DURATION" -i "$AVI" \
        -vf "fps=1,scale=1280:720:flags=lanczos" \
        -vsync vfr \
        -start_number "$((START + 1))" \
        -q:v 2 \
        "$OUT/ref_%04d.png"
fi

COUNT=$(ls "$OUT"/ref_*.png 2>/dev/null | wc -l | tr -d ' ')
echo "Done. $COUNT frames in $OUT/"
