## Reproduction: random jump (L3) followed by platform switch (RB/LB) freeze.
## Synthetic 500-game grid (the local DB is too small to recycle), driven
## through the EXACT grid-internal path the user hits:
##   random jump -> scroll_to_index_and_focus(rand, false)
##   platform switch -> set_total_count(shrinks) -> _refresh_buffer's deferred
##     scroll_to_index_and_focus(saved_focus_index) with the now-out-of-range index
## Watchdog: main-thread frame counter must keep advancing.
## Run: godot --headless --path . res://utils/random_jump_platform_test.tscn
extends Node

var _failures := 0
var _grid: VirtualScrollGridContainer
var _items: Array = []
var _frames := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _process(_delta: float) -> void:
	_frames += 1

func _make_game(i: int) -> GameResource:
	var g := GameResource.new()
	g.id = "rj-%d" % i
	g.romm_id = i
	g.title = "Game %d" % i
	g.platform = "Test"
	return g

func _ready() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	get_tree().root.add_child(main)
	for i in 120:
		await get_tree().process_frame

	var UIM = get_tree().root.get_node("UIManager")
	_grid = UIM.get_view_grid(UIM.get_current_view())
	# Rebind the real view's grid to a synthetic 500-game data source so the
	# recycle/teleport paths actually engage (local DB is ~8 games).
	for i in 500:
		_items.append(_make_game(i))
	_grid.items_requested.connect(func(offset: int, limit: int):
		var batch: Array[GameResource] = []
		for j in range(offset, mini(offset + limit, _items.size())):
			batch.append(_items[j])
		_grid.on_items_loaded(batch, offset, false)
	)
	VirtualScrollGridContainer.startup_layout_suppressed = false
	_grid.set_total_count_with_available_size(500, Vector2(1600, 900), false)
	_grid._scroll_container.scroll_to(0.0, false)
	for i in 30:
		await get_tree().process_frame

	# --- 1. Random jump (L3): instant teleport + focus, as library_view does ---
	var random_index := 487
	_grid.scroll_to_index_and_focus(random_index, false)
	for i in 10:
		await get_tree().process_frame
	var deep_scroll := _grid._scroll_container.get_scroll_float()
	_check(deep_scroll > 1000.0, "random jump went deep (scroll=%.0f)" % deep_scroll)

	# --- 2. Platform switch (RB): shrink like a platform filter ---
	var frames_before := _frames
	_grid.set_total_count_with_available_size(12, Vector2(1600, 900), false)
	# library_view then resets scroll (its own call, before the deferred restore).
	_grid.scroll_to_index(0, false)
	for i in 25:
		await get_tree().process_frame

	var advanced := _frames - frames_before
	_check(advanced >= 23, "app kept pumping frames after platform switch (%d)" % advanced)
	_check(not _grid._scroll_container.is_scrolling(),
		"no eternal chase (float=%.1f target=%.1f chase=%s smooth=%s)" % [
			_grid._scroll_container.get_scroll_float(),
			_grid._scroll_container.get_target_scroll(),
			_grid._scroll_container._wheel_chase_active,
			_grid._scroll_container._is_smooth_scrolling])
	# The scroll must be within the COMPUTED content extent of the shrunken
	# library (centered index 0 lands at ~half a card, which is legitimate).
	var extent: float = _grid._get_content_end_position()
	_check(_grid._get_current_scroll_pos() <= extent + 1.0,
		"scroll within computed content extent (scroll=%.1f extent=%.1f)" % [_grid._get_current_scroll_pos(), extent])
	_check(not _grid._scroll_container._wheel_chase_active, "chase not stranded")

	# --- 3. Cycle back to the full set: must stay responsive, no runaway ---
	var frames_b2 := _frames
	_grid.set_total_count_with_available_size(500, Vector2(1600, 900), false)
	for i in 25:
		await get_tree().process_frame
	_check(_frames - frames_b2 >= 23, "second switch responsive")
	_check(not _grid._scroll_container.is_scrolling(), "no stranded scroll state on restore")
	var extent2: float = _grid._get_content_end_position()
	_check(_grid._get_current_scroll_pos() <= extent2 + 1.0,
		"scroll within computed extent after restore (scroll=%.1f extent=%.1f)" % [_grid._get_current_scroll_pos(), extent2])

	if _failures == 0:
		print("RANDOM JUMP + PLATFORM TEST PASSED")
	else:
		print("RANDOM JUMP + PLATFORM TEST FAILED: ", _failures)
	get_tree().quit(_failures)
