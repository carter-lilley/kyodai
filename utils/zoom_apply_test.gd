## Regression test for the zoom-bar apply chain (run as a SCENE, not -s, so
## autoloads register before grid scripts compile):
##   godot --headless --path . res://utils/zoom_apply_test.tscn
##
## Covers the reported "zoom bar does nothing":
##  1. GRID integer path: set_zoom_level changes N and card_size.
##  2. CAROUSEL/LIST integer path: set_zoom_level changes card_size.
##  3. External ratio write through the target_card_width_ratio SETTER (the
##     toolbar no-stops fallback path) must re-resolve the list/carousel stop
##     — the stale _scroll_axis_lines cache regression.
##  4. _apply_zoom_ratio (the fallback's apply entry) resolves and applies.
extends Node

var _failures := 0
var _grid: VirtualScrollGridContainer
var _items: Array = []

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _make_game(i: int) -> GameResource:
	var g := GameResource.new()
	g.id = "zoom-%d" % i
	g.romm_id = i
	g.title = "Game %d" % i
	g.platform = "Test"
	return g

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var win := Window.new()
	win.size = Vector2i(1600, 900)
	get_tree().root.add_child(win)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(host)

	_grid = VirtualScrollGridContainer.new()
	host.add_child(_grid)
	VirtualScrollGridContainer.startup_layout_suppressed = false
	var card_scene: PackedScene = load("res://components/cards/game_card.tscn")
	for i in 200:
		_items.append(_make_game(i))
	_grid.setup(card_scene, _items.size())
	_grid.size = Vector2(1600, 900)
	_grid.items_requested.connect(func(offset: int, limit: int):
		var batch: Array[GameResource] = []
		for i in range(offset, mini(offset + limit, _items.size())):
			batch.append(_items[i])
		_grid.on_items_loaded(batch, offset, false)
	)
	for i in 10:
		await get_tree().process_frame

	# --- 1. GRID integer path ---
	_grid.set_grid_orientation(VirtualScrollGridContainer.ViewMode.GRID, true, 1.0)
	for i in 6:
		await get_tree().process_frame
	var levels := _grid.get_snap_levels()
	_check(levels.size() >= 2, "grid has >=2 stops (%d)" % levels.size())
	var n0 := _grid._grid_items_per_line
	_grid.set_zoom_level(levels.size() - 1)
	for i in 6:
		await get_tree().process_frame
	var n1 := _grid._grid_items_per_line
	_check(n1 != n0 and n1 == levels[levels.size() - 1],
		"grid set_zoom_level changed N (%d -> %d)" % [n0, n1])
	var cs1 := _grid.card_size
	_grid.set_zoom_level(0)
	for i in 6:
		await get_tree().process_frame
	_check(_grid.card_size.x > cs1.x and _grid._grid_items_per_line == levels[0],
		"grid level 0 = largest stop (N=%d, w=%.0f)" % [_grid._grid_items_per_line, _grid.card_size.x])

	# --- 3. CAROUSEL: external ratio write via the SETTER must re-resolve ---
	_grid.set_grid_orientation(VirtualScrollGridContainer.ViewMode.CAROUSEL, true, 1.0)
	for i in 8:
		await get_tree().process_frame
	var avail_x := _grid._get_available_size().x
	var k_resolved := _grid._get_scroll_lines_visible()
	var size_before := _grid.card_size.x
	_check(k_resolved > 0, "carousel stop resolved (k=%d, w=%.0f)" % [k_resolved, size_before])
	# External write — exactly what the toolbar fallback does.
	_grid.target_card_width_ratio = 0.5
	for i in 8:
		await get_tree().process_frame
	var expected_w: float = (avail_x - (_grid._resolve_lines_for_ratio(0.5) - 1) * _grid.grid_separation) / _grid._resolve_lines_for_ratio(0.5)
	_check(absf(_grid.card_size.x - expected_w) < 1.0 and absf(_grid.card_size.x - size_before) > 1.0,
		"carousel external ratio write re-resolved stop (w %.0f -> %.0f, expected %.0f)" % [size_before, _grid.card_size.x, expected_w])

	# --- 2. CAROUSEL integer path ---
	var stops := _grid.get_scroll_stop_lines()
	var w_a := _grid.card_size.x
	_grid.set_zoom_level(0)
	for i in 8:
		await get_tree().process_frame
	_check(stops.size() >= 2 and absf(_grid.card_size.x - avail_x) < 1.0,
		"carousel level 0 fills viewport (w=%.0f)" % _grid.card_size.x)
	_grid.set_zoom_level(stops.size() - 1)
	for i in 8:
		await get_tree().process_frame
	_check(_grid.card_size.x < w_a, "carousel max level shrinks cards (w=%.0f)" % _grid.card_size.x)

	# --- LIST: setter re-resolution + integer path ---
	_grid.set_grid_orientation(VirtualScrollGridContainer.ViewMode.LIST, true, 1.0)
	for i in 8:
		await get_tree().process_frame
	var avail_y := _grid._get_available_size().y
	var h_before := _grid.card_size.y
	_grid.target_card_width_ratio = 0.34
	for i in 8:
		await get_tree().process_frame
	_check(absf(_grid.card_size.y - h_before) > 1.0,
		"list external ratio write re-resolved stop (h %.0f -> %.0f)" % [h_before, _grid.card_size.y])
	_grid.set_zoom_level(0)
	for i in 8:
		await get_tree().process_frame
	_check(absf(_grid.card_size.y - avail_y) < 1.0,
		"list level 0 fills viewport height (h=%.0f)" % _grid.card_size.y)

	# --- 4. _apply_zoom_ratio (fallback apply entry) ---
	var changed: bool = _grid._apply_zoom_ratio(0.25)
	_grid.refresh_dimensions()
	for i in 8:
		await get_tree().process_frame
	_check(changed and absf(_grid.card_size.y - avail_y * 0.25) < avail_y * 0.08,
		"_apply_zoom_ratio(0.25) applied (h=%.0f, ~%.0f expected)" % [_grid.card_size.y, avail_y * 0.25])

	if _failures == 0:
		print("ZOOM APPLY TEST PASSED")
	else:
		print("ZOOM APPLY TEST FAILED: ", _failures)
	get_tree().quit(_failures)
