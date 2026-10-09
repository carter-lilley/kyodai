#!/usr/bin/env bash
# Single scroll-writer contract check.
#
# SmoothScrollContainer is the sole owner of scroll position. Nothing outside
# base_class/nodes/smooth_scroll_container.gd may:
#   1. access its private motion state (_target_scroll, _wheel_target,
#      _wheel_velocity, _wheel_chase_active, _scroll_float, _owner_id,
#      _write_depth, external_write_count)
#   2. write scroll_vertical / scroll_horizontal on a scroll container
#
# utils/ is exempt: tests instrument internals deliberately.
#
# Exit 0 = clean, 1 = violations found (prints them).
set -u
cd "$(dirname "$0")/.."
SSC="base_class/nodes/smooth_scroll_container.gd"
fail=0

hits=$(grep -rnE '\.(_target_scroll|_wheel_target|_wheel_velocity|_wheel_chase_active|_scroll_float|_owner_id|_write_depth|external_write_count)\b' \
  --include='*.gd' --exclude-dir=.godot --exclude-dir=.git . \
  | grep -v "^\./$SSC:" \
  | grep -v '^\./utils/') || true
if [ -n "${hits:-}" ]; then
  echo "PRIVATE-STATE ACCESS VIOLATIONS (outside $SSC):"
  echo "$hits"
  fail=1
fi

# Raw scroll writes: only flag files that hold SmoothScrollContainer instances
# (plain engine ScrollContainers in dialogs etc. are outside the contract).
hits=$(grep -rnE '\.scroll_(vertical|horizontal)[[:space:]]*=[^=]' \
  --include='*.gd' --exclude-dir=.godot --exclude-dir=.git . \
  | grep -v "^\./$SSC:" \
  | grep -v '^\./utils/') || true
if [ -n "${hits:-}" ]; then
  filtered=""
  while IFS= read -r line; do
    f="${line%%:*}"
    if grep -q "SmoothScrollContainer" "$f"; then
      filtered="${filtered}${line}\n"
    fi
  done <<< "$hits"
  if [ -n "$filtered" ]; then
    echo "RAW SCROLL WRITE VIOLATIONS (on SmoothScrollContainer, outside $SSC):"
    printf "%b" "$filtered"
    fail=1
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "PRIVATE ACCESS CHECK PASSED"
fi
exit "$fail"
