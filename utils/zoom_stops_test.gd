## Headless verification of the unified, bounds-aware zoom stops:
##  1. GRID portrait art on a landscape screen: the largest stop's card fits
##     the viewport height entirely (the screenshot bug: N=2 clipped cards).
##  2. GRID landscape art: N=2 remains reachable when it fits.
##  3. LIST: every stop's height <= viewport height; k=1 fills it exactly.
##  4. CAROUSEL: every stop's width <= viewport width; k=1 fills it exactly.
##  5. Level round-trip: set_zoom_level -> recalc -> card_size matches stop.
##  6. Resize: shrinking the viewport re-floors the stops; clamped levels stay
##     valid and fit.
## Run: godot --headless --path . -s res://utils/zoom_stops_test.gd
extends SceneTree

var _failures := 0
var _grid: VirtualScrollGridContainer

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _initialize() -> void:
	for i in 5:
		await process_frame

	var win := Window.new()
	win.size = Vector2i(1600, 900)
	root.add_child(win)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(host)

	_grid = VirtualScrollGridContainer.new()
	host.add_child(_grid)
	VirtualScrollGridContainer.startup_layout_suppressed = false
	var card_scene: PackedScene = load("res://components/cards/game_card.tscn")
	_grid.setup(card_scene, 200)
	_grid.size = Vector2(1600, 900)
	for i in 8:
		await process_frame

	# Portrait box art (2:3), media-only display: base dims (200, 300).
	UIManager.card_settings_state.display_mode = 2
	UIManager.card_settings_state.media_aspect_ratio = 2.0 / 3.0
	_grid.set_grid_orientation(_grid.ViewMode.GRID, true, 1.0)

	# --- 1. Grid portrait on landscape: whole card visible at every stop ---
	var avail := _grid._get_available_size()
	var sep := float(_grid.grid_separation)
	var base := _grid._get_base_dimensions_for_mode()
	var levels := _grid.get_snap_levels()
	_check(not levels.is_empty(), "grid stops exist (portrait)")
	var worst_over := -INF
	for n in levels:
		var cross := (avail.x - (n - 1) * sep) / n
		var h := cross * (base.y / base.x)
		worst_over = maxf(worst_over, h - avail.y)
	_check(worst_over <= 0.5, "every grid stop fits viewport height (worst over=%.1fpx, levels=%s)" % [worst_over, levels])
	# N=2 must NOT be a stop for portrait 2:3 on 16:9 (card_h ~1.19x viewport).
	_check(not levels.has(2), "N=2 excluded for portrait art on landscape (levels[0]=%d)" % levels[0])

	# Largest stop really is the smallest legal N.
	var n_min_expected := 2
	var denom := avail.y / (base.y / base.x) + sep
	n_min_expected = maxi(2, int(ceil((avail.x + sep) / denom)))
	_check(levels[0] == mini(n_min_expected, levels[levels.size() - 1]),
		"largest stop equals computed fit floor (levels[0]=%d expected>=%d)" % [levels[0], n_min_expected])

	# --- 2. Landscape art: N=2 allowed when it fits ---
	UIManager.card_settings_state.media_aspect_ratio = 16.0 / 9.0
	_grid._refresh_cached_settings()
	_grid.refresh_dimensions()
	var levels_wide := _grid.get_snap_levels()
	_check(levels_wide.has(2), "N=2 reachable for landscape art (levels[0]=%d)" % levels_wide[0])
	UIManager.card_settings_state.media_aspect_ratio = 2.0 / 3.0
	_grid._refresh_cached_settings()
	_grid.refresh_dimensions()

	# --- 5. Round-trip: set level 0 -> card fits ---
	_grid.set_zoom_level(0)
	for i in 6:
		await process_frame
	_check(_grid.card_size.y <= _grid._get_available_size().y + 0.5,
		"set_zoom_level(0) card fits (h=%.0f <= %.0f)" % [_grid.card_size.y, _grid._get_available_size().y])

	# --- 3. LIST stops ---
	_grid.set_grid_orientation(_grid.ViewMode.LIST, true, 1.0)
	for i in 6:
		await process_frame
	var list_stops := _grid.get_scroll_stop_lines()
	_check(list_stops.size() >= 2, "list stops exist (%s)" % list_stops)
	var list_ok := true
	for k in list_stops:
		if _grid._scroll_stop_size(k).y > _grid._get_available_size().y + 0.5:
			list_ok = false
	_check(list_ok, "every list stop height <= viewport")
	_check(is_equal_approx(_grid._scroll_stop_size(1).y, _grid._get_available_size().y),
		"list k=1 fills viewport exactly (%.0f)" % _grid._scroll_stop_size(1).y)
	var list_ratios := _grid.get_snap_ratios()
	_check(list_ratios.size() == list_stops.size() and list_ratios.size() >= 2,
		"list snap ratios mirror stops (%d)" % list_ratios.size())
	_grid.set_zoom_level(0)
	for i in 6:
		await process_frame
	_check(is_equal_approx(_grid.card_size.y, _grid._get_available_size().y),
		"list level 0 = one full card (%.0f)" % _grid.card_size.y)

	# --- 4. CAROUSEL stops ---
	_grid.set_grid_orientation(_grid.ViewMode.CAROUSEL, true, 1.0)
	for i in 6:
		await process_frame
	var car_stops := _grid.get_scroll_stop_lines()
	_check(car_stops.size() >= 2, "carousel stops exist (%s)" % car_stops)
	var car_ok := true
	for k in car_stops:
		if _grid._scroll_stop_size(k).x > _grid._get_available_size().x + 0.5:
			car_ok = false
	_check(car_ok, "every carousel stop width <= viewport")
	_check(is_equal_approx(_grid._scroll_stop_size(1).x, _grid._get_available_size().x),
		"carousel k=1 fills viewport exactly (%.0f)" % _grid._scroll_stop_size(1).x)
	_grid.set_zoom_level(0)
	for i in 6:
		await process_frame
	_check(is_equal_approx(_grid.card_size.x, _grid._get_available_size().x),
		"carousel level 0 = one full card (%.0f)" % _grid.card_size.x)

	# --- 6. Resize re-floors stops ---
	_grid.set_grid_orientation(_grid.ViewMode.GRID, true, 1.0)
	_grid.size = Vector2(800, 480)
	_grid.refresh_dimensions()
	for i in 6:
		await process_frame
	var small_levels := _grid.get_snap_levels()
	var small_avail := _grid._get_available_size()
	var small_worst := -INF
	for n in small_levels:
		var cross2 := (small_avail.x - (n - 1) * sep) / n
		small_worst = maxf(small_worst, cross2 * (base.y / base.x) - small_avail.y)
	_check(small_worst <= 0.5, "resized viewport stops still fit (levels[0]=%d)" % small_levels[0])
	_grid.set_zoom_level(0)
	for i in 6:
		await process_frame
	_check(_grid.card_size.y <= _grid._get_available_size().y + 0.5,
		"clamped max zoom on small viewport fits (h=%.0f <= %.0f)" % [_grid.card_size.y, _grid._get_available_size().y])

	if _failures == 0:
		print("ZOOM STOPS TEST PASSED")
	else:
		print("ZOOM STOPS TEST FAILED: ", _failures)
	quit(_failures)
