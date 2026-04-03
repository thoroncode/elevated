#!/bin/sh
# Stamp date-based version: YY.M.D (HH.MM)
# Run before local xcodebuild archive, or from Xcode Cloud ci_post_clone.
set -eu

dir="$(cd "$(dirname "$0")" && pwd)"
shortver=$("$dir/scripts/version.sh" short)
buildver=$("$dir/scripts/version.sh" build)

for proj in "$dir"/Elevated*.xcodeproj; do
    pbx="$proj/project.pbxproj"
    [ -f "$pbx" ] || continue
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $shortver/" "$pbx"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $buildver/" "$pbx"
done

echo "Stamped version $shortver ($buildver)"
