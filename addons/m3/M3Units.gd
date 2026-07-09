class_name M3Units
extends RefCounted

## Material 3 Density-Independent Pixel (DP) Utilities
## All M3 components use this for consistent DP-to-pixel scaling.
## When a SystemManager.display is available, the scale is owned by it (screen/monitor
## based). Otherwise this class falls back to a standalone computation.

static var _cached_scale: float = -1.0

const BASE_HEIGHT := 1080.0
const BASE_DPI := 160.0
const DEFAULT_DPI := 96.0
const MIN_SCALE := 1.0
const MAX_SCALE := 4.0

static func _get_display_manager() -> Node:
	var main_loop := Engine.get_main_loop()
	if not main_loop:
		return null
	var root: Window = main_loop.root
	if not root:
		return null
	var system_manager := root.get_node_or_null("/root/SystemManager")
	if system_manager:
		return system_manager.display
	return null

## Get the DP-to-pixel scale factor.
## Prefers SystemManager.display's screen-based scale when available.
static func get_scale() -> float:
	if _cached_scale >= 0:
		return _cached_scale

	var dm := _get_display_manager()
	if dm and dm.has_method("get_ui_scale"):
		_cached_scale = dm.get_ui_scale()
		return _cached_scale

	# Fallback standalone computation (used when SystemManager.display isn't ready yet).
	var screen := DisplayServer.window_get_current_screen()
	var os_scale := DisplayServer.screen_get_scale(screen)
	if os_scale <= 0:
		os_scale = 1.0

	var screen_size := DisplayServer.screen_get_size(screen)
	var resolution_scale := pow(screen_size.y / BASE_HEIGHT, 0.75)

	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0:
		dpi = DEFAULT_DPI
	var dpi_scale := dpi / BASE_DPI

	_cached_scale = clamp(max(os_scale, resolution_scale, dpi_scale), MIN_SCALE, MAX_SCALE)
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
