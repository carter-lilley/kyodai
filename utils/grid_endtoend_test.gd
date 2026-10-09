## End-to-end headless test of the REAL VirtualScrollGridContainer + GameCard:
##  1. Builds the grid with 500 mock games, real card scene.
##  2. Scrolls to several positions (including far jumps) and lets tweens run.
##  3. At each rest, verifies every active card's stamped visual transform
##     matches the deterministic grid offset (column-sync / no drift).
## Run: godot --headless --path . res://utils/grid_endtoend_test.tscn
## (scene-based so autoloads register before grid scripts compile)
extends Node

var _failures := 0
var _grid: VirtualScrollGridContainer
var _items: Array = []

func _make_game(i: int) -> GameResource:
	var g := GameResource.new()
	g.id = "test-%d" % i
	g.romm_id = i
	g.title = "Game %d" % i
	g.platform = "Test"
	return g

func _ready() -> void:
	# Wait for autoloads to settle.
	for i in 5:
		await get_tree().process_frame

	var win := Window.new()
	win.size = Vector2i(1600, 900)
	get_tree().root.add_child(win)

	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(host)

	_grid = VirtualScrollGridContainer.new()
	host.add_child(_grid)
	_grid.debug_mode = true

	for i in 500:
		_items.append(_make_game(i))

	_grid.items_requested.connect(func(offset: int, limit: int):
		var batch: Array[GameResource] = []
		for i in range(offset, mini(offset + limit, _items.size())):
			batch.append(_items[i])
		_grid.on_items_loaded(batch, offset, false)
	)

	VirtualScrollGridContainer.startup_layout_suppressed = false
	var card_scene: PackedScene = load("res://components/cards/game_card.tscn")
	_grid.setup(card_scene, _items.size())
	_grid.size = Vector2(1600, 900)

	# Settle layout over several frames.
	for i in 10:
		await get_tree().process_frame

	_check_sync("initial")

	# Scroll positions to exercise recycling: small hop, medium, far jump.
	var stride: float = _grid._get_normal_stride()
	var targets := [0.0, stride * 3.0, stride * 20.0, stride * 120.0, stride * 60.0]
	for t in targets:
		_grid.scroll_to_index(int(t / stride) * _grid._get_items_per_line(), true)
		# Let snap + tween + sorts + reveal run.
		for i in 40:
			await get_tree().process_frame
		_check_sync("scroll->%.0f" % t)

	if _failures == 0:
		print("GRID E2E TEST PASSED")
	else:
		print("GRID E2E TEST FAILED: ", _failures)
	get_tree().quit(_failures)

func _check_sync(tag: String) -> void:
	if _grid._active_cards.is_empty():
		print("FAIL ", tag, ": no active cards")
		_failures += 1
		return
	var worst := 0.0
	var worst_idx := -1
	var unsynced := 0
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		if card.get("_visuals_position_synced") == false:
			unsynced += 1
		var lt = card.get("_last_visual_transform")
		if not lt is Transform2D:
			continue
		var exp: Vector2 = _grid._compute_visual_layer_offset(card)
		var cs_v = card.get("content_scale")
		var cs: Vector2 = cs_v if cs_v is Vector2 else Vector2.ONE
		if not cs.is_equal_approx(Vector2.ONE):
			var pivot: Vector2 = card._get_content_scale_pivot()
			exp += pivot - cs * pivot
		var d: float = (lt as Transform2D).origin.distance_to(exp)
		if d > worst:
			worst = d
			worst_idx = card.get_meta("virtual_index", -1)
	var ok := worst < 2.0 and unsynced == 0
	if ok:
		print("OK   ", tag, " active=", _grid._active_cards.size(), " worst_drift=", worst)
	else:
		_failures += 1
		print("FAIL ", tag, " active=", _grid._active_cards.size(), " worst_drift=", worst, " worst_idx=", worst_idx, " unsynced=", unsynced)
