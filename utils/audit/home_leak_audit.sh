#!/bin/bash
# home_leak_audit.sh — verifies an emulator keeps all of its state inside
# Kyodai's managed emulator directory instead of leaking into OS user folders.
#
# Usage:
#   ./home_leak_audit.sh <emulator_dir> <command...>
#
# Example (from the emulator's install dir):
#   ./home_leak_audit.sh ~/kyodai/emulators/xenia-edge ./squashfs-root/AppRun
#
# What it does:
#   1. Snapshots ~/.config, ~/.local/share, ~/.cache and /tmp/.mount_* (paths +
#      mtimes), then launches the given command with the same XDG environment
#      Kyodai would inject.
#   2. Waits RUN_SECONDS (default 15), closes the emulator, waits for exit.
#   3. Snapshots again and reports anything created or modified OUTSIDE the
#      managed emulator directory. Zero output under "LEAKS" = clean.
#
# Env overrides: RUN_SECONDS=20, SHOW_MODIFIED=1 (also report mtime-changed
# files; noisy on live desktops)

set -u

EMU_DIR="${1:?usage: $0 <emulator_dir> <command...>}"
shift
if [ $# -eq 0 ]; then
	echo "usage: $0 <emulator_dir> <command...>" >&2
	exit 2
fi

EMU_DIR="$(realpath "$EMU_DIR")"
RUN_SECONDS="${RUN_SECONDS:-15}"
WORK="$(mktemp -d /tmp/kyodai-leak-audit.XXXXXX)"

snapshot() {
	# $1 = output file. Records "mtime path" for every file in the XDG dirs
	# and any live AppImage FUSE mounts. Trash and friends churn constantly
	# on a live desktop and are never emulator state — prune them.
	{
		find "$HOME/.config" "$HOME/.local/share" "$HOME/.cache" \
			-mindepth 1 \
			-path "$HOME/.local/share/Trash" -prune -o \
			-path "$HOME/.cache/baloo" -prune -o \
			-printf '%T@ %p\n' 2>/dev/null
		find /tmp -maxdepth 1 -name '.mount_*' -printf '%T@ %p\n' 2>/dev/null
	} | sort -k2 > "$1"
}

echo "[audit] emulator dir : $EMU_DIR"
echo "[audit] command      : $*"
echo "[audit] run window   : ${RUN_SECONDS}s"
echo "[audit] snapshot dir : $WORK"

snapshot "$WORK/before"

# Launch with the same XDG redirection Kyodai applies (belt-and-braces: the
# audit must prove the emulator honors it, or proves it ignores it).
XDG_CONFIG_HOME="$EMU_DIR/.config" \
XDG_DATA_HOME="$EMU_DIR/.local/share" \
XDG_CACHE_HOME="$EMU_DIR/.cache" \
"$@" > "$WORK/emulator.log" 2>&1 &
EMU_PID=$!

sleep "$RUN_SECONDS"

# Ask nicely, then forcefully, then wait for the tree to settle.
kill -TERM "$EMU_PID" 2>/dev/null
sleep 2
kill -KILL "$EMU_PID" 2>/dev/null
wait "$EMU_PID" 2>/dev/null
sleep 1

snapshot "$WORK/after"

echo
echo "=== LEAKS: new files outside the emulator dir ==="
# New paths are the strong leak signal: an emulator writing somewhere it
# never should. (Emulator-dir writes are expected — they're the whole point.)
awk -v emu="$EMU_DIR/" '
NR==FNR { before[$2]=$1; next }
$2 ~ /\.mount_/ { next }
index($2, emu) == 1 { next }
!($2 in before) { print "NEW " $2 }
' "$WORK/before" "$WORK/after" | sort

if [ "${SHOW_MODIFIED:-0}" = "1" ]; then
	echo
	echo "=== LEAKS: modified files outside the emulator dir (noisy on live desktops) ==="
	awk -v emu="$EMU_DIR/" '
	NR==FNR { before[$2]=$1; next }
	$2 ~ /\.mount_/ { next }
	index($2, emu) == 1 { next }
	($2 in before) && before[$2] != $1 { print "MODIFIED " $2 }
	' "$WORK/before" "$WORK/after" | sort
else
	echo
	echo "(mtime-change detection off; SHOW_MODIFIED=1 to enable — noisy under Steam/Discord/etc.)"
fi

echo
echo "=== FUSE mounts left behind in /tmp ==="
awk '/\.mount_/ { print $2 }' "$WORK/after" | while read -r m; do
	grep -qF "$m" "$WORK/before" || echo "LEAKED MOUNT $m"
done

echo
echo "=== Managed-dir writes (expected; sanity check that redirection works) ==="
awk -v emu="$EMU_DIR/" '
NR==FNR { before[$2]=$1; next }
!($2 in before) && index($2, emu) == 1 { print "NEW " $2 }
' "$WORK/before" "$WORK/after" | head -20

echo
echo "[audit] emulator log tail:"
tail -5 "$WORK/emulator.log" 2>/dev/null
echo "[audit] full artifacts in $WORK"
