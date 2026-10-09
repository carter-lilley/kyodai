## Regression test for the one-frame recycle flash (whole-strip offset).
## Boots the REAL app, switches to CAROUSEL then LIST, wheel-scrolls through
## content while recycling, and after EVERY rendered frame compares each active
## marked card's stamped visual transform against the end-of-frame deterministic
## offset. A mid-cascade stamp (the bug) mismatches by ~one stride for a frame.
## Run: godot --headless --path . res://utils/recycle_flash_test.tscn
extends Node

var _failures := 0
var _worst := 0.0
var _worst_mode := ""
var _grid: VirtualScrollGridContainer
var _check_enabled := false

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _ready() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	get_tree().root.add_child(main)
	for i in 160:
		await get_tree().process_frame

	var UIM = get_tree().root.get_node("UIManager")
	if UIM == null:
		print("FAIL UIManager autoload missing")
		get_tree().quit(1)
		return
	_grid = UIM.get_view_grid(UIM.get_current_view())
	if _grid == null:
		print("FAIL no grid")
		get_tree().quit(1)
		return

	# Post-draw = every stamp that rendered this frame is final.
	RenderingServer.frame_post_draw.connect(_post_draw_check)

	for mode in [VirtualScrollGridContainer.ViewMode.CAROUSEL, VirtualScrollGridContainer.ViewMode.LIST]:
		UIM.card_settings_state.set_layout_mode(mode as int)
		for i in 10:
			await get_tree().process_frame
		_grid = UIM.get_view_grid(UIM.get_current_view())
		_worst = 0.0
		_check_enabled = true
		# Wheel-scroll through content: 40 ticks, each advancing the chase.
		# (Drive the chase state directly; ScrollContainer clamps overshoot.)
		for tick in 40:
			var sc: SmoothScrollContainer = _grid._scroll_container
			sc._owner_id += 1
			sc._wheel_target = sc._wheel_target + 120.0
			sc._wheel_chase_active = true
			sc._is_smooth_scrolling = true
			await get_tree().process_frame
			await get_tree().process_frame
		# Let the last glide settle.
		for i in 90:
			await get_tree().process_frame
		_check_enabled = false
		var mode_name := "CAROUSEL" if mode == VirtualScrollGridContainer.ViewMode.CAROUSEL else "LIST"
		_check(_worst <= 1.5, "%s: stamped offsets match end-of-frame truth every frame (worst=%.2fpx)" % [mode_name, _worst])

	if _failures == 0:
		print("RECYCLE FLASH TEST PASSED")
	else:
		print("RECYCLE FLASH TEST FAILED: ", _failures)
	get_tree().quit(_failures)

func _post_draw_check() -> void:
	if not _check_enabled or _grid == null or not is_instance_valid(_grid):
		return
	if _grid._active_cards.is_empty():
		return
	var scroll_f := _grid._scroll_container.get_scroll_float()
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		if card.get("_visuals_position_synced") != true:
			continue
		var lt = card.get("_last_visual_transform")
		if not lt is Transform2D:
			continue
		var exp: Vector2 = _grid._visual_sync.compute_offset(card)
		var cs_v = card.get("content_scale")
		var cs: Vector2 = cs_v if cs_v is Vector2 else Vector2.ONE
		if not cs.is_equal_approx(Vector2.ONE):
			var pivot: Vector2 = card._get_content_scale_pivot()
			exp += pivot - cs * pivot
		var d: float = (lt as Transform2D).origin.distance_to(exp)
		if d > _worst:
			_worst = d
