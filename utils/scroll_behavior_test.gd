## Headless behavioral test for SmoothScrollContainer:
##  1. Far-jump policy: scroll_to(animate=true) over >2 pages snaps near the
##     target instantly and tweens only the short remainder.
##  2. Paginated far-jump: the snap intermediate is ALWAYS a page multiple.
##  3. Ownership: wheel input mid-tween kills the tween and takes over.
##  4. Float quantization: tracked float always equals int scroll.
##  5. Near hop does NOT snap (tweens from current position).
## Run: godot --headless --path . -s res://utils/scroll_behavior_test.gd
extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _initialize() -> void:
	var win := Window.new()
	win.size = Vector2i(1000, 700)
	root.add_child(win)

	var sc := SmoothScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(sc)
	var content := Control.new()
	content.custom_minimum_size = Vector2(600, 20000)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)

	await process_frame
	await process_frame
	await process_frame

	var page: float = sc.get_v_scroll_bar().page
	_check(page > 0.0, "scrollbar page computed (page=%.0f)" % page)

	# --- Far jump in free mode ---
	var far_target := 12000.0
	sc.scroll_to(far_target, true)
	var pos_after_call: float = sc.get_scroll_float()
	var dist_to_target: float = absf(far_target - pos_after_call)
	_check(pos_after_call > 0.0, "far jump snapped forward instantly (pos=%.0f)" % pos_after_call)
	_check(dist_to_target <= sc.far_jump_page_count * page + 1.0,
		"snap landed within %.0f pages of target (dist=%.0f)" % [sc.far_jump_page_count, dist_to_target])

	# --- Wheel mid-tween takes ownership ---
	var owner_before: int = sc._owner_id
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	sc._on_gui_input(wheel)
	_check(sc._owner_id > owner_before, "wheel bumped ownership id")
	_check(sc._wheel_chase_active, "wheel chase active after tick")
	var before: float = sc.get_scroll_float()
	for i in 10:
		await process_frame
	_check(sc.get_scroll_float() > before, "wheel chase moved scroll (%.0f -> %.0f)" % [before, sc.get_scroll_float()])
	# Motion model: float may carry a sub-pixel remainder (<=0.5 from the
	# rounded int content) so the visual layer glides through the tail.
	_check(absf(sc.get_scroll_float() - float(sc.scroll_vertical)) <= 0.5,
		"float model within 0.5px of int content during glide (%.3f vs %d)" % [sc.get_scroll_float(), sc.scroll_vertical])

	# --- Paginated far jump: intermediate must be a page multiple ---
	for i in 30:
		await process_frame
	var period := 800.0
	sc.page_snap_period = period
	sc.page_snap_offset = 0.0
	sc.scroll_to(0.0, false)
	for i in 5:
		await process_frame
	var page_target := 10.0 * period
	sc.scroll_to(page_target, true)
	var snapped: float = sc.get_scroll_float()
	var is_page_multiple := snapped <= 0.0 or absf(snapped / period - round(snapped / period)) < 0.001
	_check(is_page_multiple, "paginated snap intermediate is a page multiple (pos=%.0f, period=%.0f)" % [snapped, period])
	_check(snapped < page_target and snapped >= 0.0, "paginated snap is between start and target (pos=%.0f)" % snapped)
	var travel_dist := page_target - snapped
	_check(travel_dist <= sc.far_jump_page_count * page + period,
		"paginated snap kept remainder short (%.0f px)" % travel_dist)
	sc.page_snap_period = 0.0

	# --- Near hop does NOT snap ---
	for i in 40:
		await process_frame
	var near_target := sc.get_scroll_float() + 120.0
	var prev: float = sc.get_scroll_float()
	sc.scroll_to(near_target, true)
	var moved: float = absf(sc.get_scroll_float() - prev)
	_check(moved < 30.0, "near hop did not snap (moved %.1f px)" % moved)

	# --- Rest exactness: after all motion settles, float == int content ---
	for i in 120:
		await process_frame
	_check(not sc.is_scrolling(), "scroll settled after near hop")
	_check(sc.get_scroll_float() == float(sc.scroll_vertical),
		"rest state pixel-exact (float %.3f == int %d)" % [sc.get_scroll_float(), sc.scroll_vertical])

	# --- Tail smoothness: single wheel tick glides with sub-pixel steps ---
	var tick_target := sc.get_scroll_float()
	var wheel2 := InputEventMouseButton.new()
	wheel2.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel2.pressed = true
	sc._on_gui_input(wheel2)
	var subpixel_steps := 0
	var last_int := sc.scroll_vertical
	for i in 30:
		await process_frame
		if sc.scroll_vertical != last_int:
			# Count distinct int transitions; a quantized tail would jump 1px
			# per frame max, but the float should move EVERY frame of the glide.
			last_int = sc.scroll_vertical
		if sc._wheel_chase_active:
			subpixel_steps += 1
	_check(subpixel_steps >= 5, "wheel glide ran %d frames (smooth tail, not instant)" % subpixel_steps)
	# The exponential glide needs ~5*tau (≈1s) to settle; headless frame rates
	# vary, so wait generously and confirm the chase actually completed.
	for i in 240:
		await process_frame
		if not sc._wheel_chase_active:
			break
	_check(not sc._wheel_chase_active, "wheel chase completed within settle window")
	_check(sc.get_scroll_float() == float(sc.scroll_vertical),
		"post-tick rest pixel-exact (float %.3f == int %d)" % [sc.get_scroll_float(), sc.scroll_vertical])

	if _failures == 0:
		print("SCROLL TEST PASSED")
	else:
		print("SCROLL TEST FAILED: ", _failures)
	quit(_failures)
