#!/usr/bin/env bash
# Port of sync-m3.ps1: commits/pushes changes inside addons/m3, then bumps
# the submodule pointer in the kyodai repo.
#
# Usage: ./sync-m3.sh [commit message]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m3="$root/addons/m3"
message="${1:-}"

fail() {
    printf 'sync-m3: %s\n' "$1" >&2
    exit 1
}

cd "$root"

branch="$(git -C "$m3" symbolic-ref --short -q HEAD || true)"
if [[ "$branch" != "main" ]]; then
    echo "m3: switching from detached HEAD to main"
    git -C "$m3" checkout main >/dev/null
fi

git -C "$m3" fetch origin main >/dev/null
read -r ahead behind <<< "$(git -C "$m3" rev-list --left-right --count main...origin/main)"

if (( ahead > 0 && behind > 0 )); then
    fail "m3 has diverged from origin/main. Run 'git -C addons/m3 pull --rebase' first."
fi
if (( behind > 0 )); then
    echo "m3: fast-forwarding $behind commit(s) from origin/main"
    git -C "$m3" pull --ff-only >/dev/null
fi

dirty="$(git -C "$m3" status --porcelain)"
if [[ -n "$dirty" ]]; then
    if [[ -z "$message" ]]; then
        read -rp "m3 has uncommitted changes - commit message: " message
        [[ -n "$message" ]] || fail "commit message required"
    fi
    git -C "$m3" add -A
    git -C "$m3" commit -q -m "$message"
    echo "m3: committed local changes ($message)"
    ahead=1
fi

if (( ahead > 0 )); then
    git -C "$m3" push origin main
    echo "m3: pushed to M3Godot"
elif [[ -z "$dirty" ]]; then
    echo "m3: nothing to commit or push"
fi

pointer_changed="$(git status --porcelain -- addons/m3)"
if [[ -n "$pointer_changed" ]]; then
    bump_msg="m3: update submodule"
    [[ -n "$message" ]] && bump_msg="m3: $message"
    git add addons/m3
    git commit -q -m "$bump_msg"
    echo "kyodai: bumped m3 submodule pointer ($bump_msg)"
    echo "kyodai: run 'git push' when ready"
else
    echo "kyodai: pointer already up to date"
fi
