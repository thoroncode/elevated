#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 OUTPUT_PATH" >&2
    exit 64
fi

out="$1"
team_id="${ELEVATED_ASC_TEAM_ID:-}"

if [ -z "$team_id" ] || [ "$team_id" = "TEAMIDPLACEHOLDER" ]; then
    echo "Set ELEVATED_ASC_TEAM_ID in fastlane/.env before exporting uploads." >&2
    exit 65
fi

mkdir -p "$(dirname "$out")"

cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>${team_id}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
