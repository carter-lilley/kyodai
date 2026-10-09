## Single scroll-writer contract test (grid architecture refactor, Phase 0).
##
## SmoothScrollContainer is the SOLE owner of scroll position. Every scroll
## mutation must pass through its write API (_set_current_scroll and future
## write_immediate()/scroll_to()); raw writes to scroll_vertical /
## scroll_horizontal or pokes of SSC private motion state from the grid are
## contract violations. SSC counts them in external_write_count.
##
## This test drives the grid through the operations that historically wrote
## scroll directly (instant jump, library shrink clamp, zoom recalc restore)
## and asserts zero external writes, plus rest-state coherence.
##
## RED on the pre-refactor baseline by design: the failure list is the
## Phase 1 migration checklist.
##
## Run: godot --headless --path . res://utils/scroll_single_writer_test.tscn
extends Node

var _failures := 0
var _grid: VirtualScrollGridContainer
var _ssc: SmoothScrollContainer
var _items: Array = []

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _make_game(i: int) -> GameResource:
	var g := GameResource.new()
	g.id = "test-%d" % i
	g.romm_id = i
	g.title = "Game %d" % i
	g.platform = "Test"
	return g

func _settle(frames: int = 40, wait_for_idle: bool = false) -> void:
	for i in frames:
		await get_tree().process_frame
	if wait_for_idle:
		# The exponential wheel chase needs ~1s to converge; poll generously.
		for i in 300:
			if not _ssc.is_scrolling():
				break
			await get_tree().process_frame

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame

	# Size the ROOT window: headless embedded child Windows clamp to the root
	# viewport (and the app forces a 400x300 minimum at startup), so a child
	# Window would leave the grid at a degenerate ~324x224 available size.
	get_tree().root.size = Vector2i(1600, 900)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_tree().root.add_child(host)

	_grid = VirtualScrollGridContainer.new()
	host.add_child(_grid)

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
	await _settle(10)

	_ssc = _grid._scroll_container
	_check(is_instance_valid(_ssc), "grid scroll container exists")

	# --- Op 1: instant jump (scroll_to_index_and_focus, animate=false) ---
	_ssc.external_write_count = 0
	_grid.scroll_to_index_and_focus(300, false)
	await _settle()
	_check(_ssc.external_write_count == 0,
		"instant jump: zero external scroll writes (got %d)" % _ssc.external_write_count)
	_check(_ssc.get_scroll_float() == float(_ssc.scroll_vertical),
		"post-jump rest pixel-exact (float %.3f == int %d)" % [_ssc.get_scroll_float(), _ssc.scroll_vertical])
	_check(not _ssc.is_scrolling(), "post-jump: no stranded motion state")

	# --- Op 2: library shrink (extent clamp) ---
	_ssc.external_write_count = 0
	_grid.set_total_count(80)
	await _settle()
	_check(_ssc.external_write_count == 0,
		"library shrink: zero external scroll writes (got %d)" % _ssc.external_write_count)
	var extent: float = _grid._get_content_end_position() - _ssc.get_v_scroll_bar().page
	_check(_ssc.get_scroll_float() <= maxf(0.0, extent) + 0.5,
		"post-shrink scroll within computed extent (%.1f <= %.1f)" % [_ssc.get_scroll_float(), extent])

	# --- Op 3: zoom recalc (scroll anchor restore) ---
	_grid.set_total_count(500)
	await _settle()
	_grid.scroll_to_index(200, false)
	await _settle()
	_ssc.external_write_count = 0
	_grid.set_zoom_level(0)
	await _settle()
	_check(_ssc.external_write_count == 0,
		"zoom recalc: zero external scroll writes (got %d)" % _ssc.external_write_count)
	_check(_ssc.get_scroll_float() == float(_ssc.scroll_vertical),
		"post-zoom rest pixel-exact (float %.3f == int %d)" % [_ssc.get_scroll_float(), _ssc.scroll_vertical])

	# --- Op 4: animated far jump + mid-tween wheel (writer handoff) ---
	_ssc.external_write_count = 0
	_grid.scroll_to_index(490, true)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	_ssc._on_gui_input(wheel)
	await _settle(10, true)
	_check(_ssc.external_write_count == 0,
		"wheel mid-tween handoff: zero external scroll writes (got %d)" % _ssc.external_write_count)
	_check(not _ssc.is_scrolling(), "post-handoff: motion settled")

	if _failures == 0:
		print("SINGLE WRITER TEST PASSED")
	else:
		print("SINGLE WRITER TEST FAILED: ", _failures)
	get_tree().quit(_failures)
