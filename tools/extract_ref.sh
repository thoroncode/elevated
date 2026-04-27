#!/usr/bin/env bash
# Extract reference frames from the local artifact copy of elevated_8000.avi at 1 fps.
# Output: /tmp/elevated_ref/ref_XXXX.png  (XXXX = second 0001..0215)
#
# Usage:
#   ./tools/extract_ref.sh               # extract all (215 frames)
#   ./tools/extract_ref.sh 60 90         # only seconds 60-90

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
DEFAULT_AVI="$ROOT/artifact/reference/elevated_8000.avi"
LEGACY_AVI="$ROOT/elevated_8000.avi"
AVI="${ELEVATED_REFERENCE_AVI:-}"
OUT="/tmp/elevated_ref"

START=${1:-0}
END=${2:-9999}

if [[ -z "$AVI" ]]; then
    if [[ -f "$DEFAULT_AVI" ]]; then
        AVI="$DEFAULT_AVI"
    elif [[ -f "$LEGACY_AVI" ]]; then
        AVI="$LEGACY_AVI"
    else
        echo "Reference video missing: $DEFAULT_AVI" >&2
        echo "Run \`make ref-video\` or set ELEVATED_REFERENCE_AVI=/path/to/elevated_8000.avi." >&2
        exit 1
    fi
fi

if [[ ! -f "$AVI" ]]; then
    echo "Reference video not found: $AVI" >&2
    exit 1
fi

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
