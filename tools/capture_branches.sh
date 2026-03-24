#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Capture one exact demo frame across one or more branches using temporary git worktrees.

Usage:
  tools/capture_branches.sh --time <seconds> [--out <dir>] [branch ...]

Examples:
  tools/capture_branches.sh --time 81.383333
  tools/capture_branches.sh --time 81.383333 --out /tmp/elevated_branch_frames main my-branch other-branch

Defaults:
  out dir  = /tmp/elevated_branch_frames
  branches = main (or main + current branch if not on main)
EOF
}

time_arg=""
out_dir="/tmp/elevated_branch_frames"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --time)
            [[ $# -ge 2 ]] || { echo "Missing value for --time" >&2; exit 1; }
            time_arg="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || { echo "Missing value for --out" >&2; exit 1; }
            out_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ -z "$time_arg" ]]; then
    echo "Missing required --time argument" >&2
    usage >&2
    exit 1
fi

branches=("$@")
if [[ ${#branches[@]} -eq 0 ]]; then
    current_branch=$(git branch --show-current)
    if [[ -n "$current_branch" && "$current_branch" != "main" ]]; then
        branches=(main "$current_branch")
    else
        branches=(main)
    fi
fi

repo_root=$(git rev-parse --show-toplevel)
mkdir -p "$out_dir"

scratch_root=$(mktemp -d /tmp/elevated-branch-frame.XXXXXX)
declare -a worktrees=()

cleanup() {
    set +e
    if [[ ${worktrees[*]-} != "" ]]; then
        for wt in "${worktrees[@]}"; do
            git -C "$repo_root" worktree remove -f "$wt" >/dev/null 2>&1 || rm -rf "$wt"
        done
    fi
    rm -rf "$scratch_root"
}
trap cleanup EXIT HUP INT TERM

time_tag=$(printf '%s' "$time_arg" | tr -c '0-9A-Za-z._-' '_')
summary_file="$out_dir/frame_${time_tag}_summary.txt"
: > "$summary_file"

echo "Capturing frame at t=$time_arg"
echo "Output dir: $out_dir"
echo ""

idx=0
for branch in "${branches[@]}"; do
    if ! git -C "$repo_root" rev-parse --verify --quiet "${branch}^{commit}" >/dev/null; then
        echo "Unknown branch or commit: $branch" >&2
        exit 1
    fi

    safe_branch=$(printf '%s' "$branch" | tr '/:' '__')
    wt="$scratch_root/${idx}_${safe_branch}"
    out_png="$out_dir/${safe_branch}_t${time_tag}.png"
    commit=$(git -C "$repo_root" rev-parse --short "${branch}^{commit}")

    echo "[$((idx + 1))/${#branches[@]}] $branch ($commit)"
    git -C "$repo_root" worktree add --detach "$wt" "$branch" >/dev/null
    worktrees+=("$wt")

    make -C "$wt" build >/dev/null
    "$wt"/ElevatedMac/.build/release/ElevatedMac --icon-at="$time_arg" --icon-out="$out_png" >/dev/null

    sha=$(shasum -a 256 "$out_png" | awk '{print $1}')
    printf '%s %s %s\n' "$branch" "$commit" "$sha" | tee -a "$summary_file"
    echo "  -> $out_png"
    echo ""
    idx=$((idx + 1))
done

echo "Summary: $summary_file"
