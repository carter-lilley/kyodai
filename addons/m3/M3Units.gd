class_name M3Units
extends RefCounted

## Material 3 Density-Independent Pixel (DP) Utilities
## All M3 components use this for consistent DP-to-pixel scaling

static var _cached_scale: float = -1.0

## Get the DP-to-pixel scale factor based on screen DPI.
## Desktop default: 96 DPI → scale = 0.6 (96/160)
## High-DPI displays: scale > 1.0
## Minimum scale: 1.0 to avoid tiny UI
static func get_scale() -> float:
	if _cached_scale < 0:
		var dpi = DisplayServer.screen_get_dpi()
		if dpi <= 0:
			dpi = 96  # Default desktop DPI
		_cached_scale = max(1.0, dpi / 160.0)
	return _cached_scale

## Invalidate cached scale (call after display/window changes)
static func invalidate_cache():
	_cached_scale = -1.0

## Convert dp value to pixels (float)
static func dp(value: float) -> float:
	return value * get_scale()

## Convert dp value to pixels (int, rounded)
static func dpi(value: float) -> int:
	return int(round(dp(value)))

## Convert dp value to pixels (int, ceiling)
static func dp_ceil(value: float) -> int:
	return int(ceil(dp(value)))

## Convert dp value to pixels (int, floor)
static func dp_floor(value: float) -> int:
	return int(floor(dp(value)))
