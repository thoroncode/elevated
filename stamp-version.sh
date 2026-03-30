#!/bin/sh
# Stamp date-based version: YY.M.DD (HH.MM)
# Run before local xcodebuild archive, or from Xcode Cloud ci_post_clone.

shortver=$(printf '%s.%d.%s' $(date +%y) $(date +%-m) $(date +%d))
buildver=$(date +%H.%M)

dir="$(cd "$(dirname "$0")" && pwd)"

for proj in "$dir"/Elevated*.xcodeproj; do
    pbx="$proj/project.pbxproj"
    [ -f "$pbx" ] || continue
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $shortver/" "$pbx"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $buildver/" "$pbx"
done

echo "Stamped version $shortver ($buildver)"
