#!/bin/sh
set -eu

shortver=${ELEVATED_SHORT_VERSION:-$(printf '%s.%d.%d' "$(date +%y)" "$(date +%-m)" "$(date +%-d)")}
buildver=${ELEVATED_BUILD_VERSION:-$(date +%H.%M)}

usage() {
    echo "usage: $0 [short|build|display]" >&2
    exit 1
}

case "${1:-display}" in
    short)
        printf '%s\n' "$shortver"
        ;;
    build)
        printf '%s\n' "$buildver"
        ;;
    display)
        printf '%s (%s)\n' "$shortver" "$buildver"
        ;;
    *)
        usage
        ;;
esac
