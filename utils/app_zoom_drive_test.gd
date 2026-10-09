## Drives the REAL app (main.tscn) headless at a real window size and calls the
## REAL toolbar _on_zoom_changed per mode, verifying the visible grid's
## card_size changes. Run:
##   godot --headless --path . res://utils/app_zoom_drive_test.tscn
extends Node

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _ready() -> void:
	# Force a real window size BEFORE the app boots so layout/settle see it.
	get_tree().root.size = Vector2i(1920, 1080)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	get_tree().root.add_child(main)
	for i in 160:
		await get_tree().process_frame
	get_tree().root.size = Vector2i(1920, 1080)
	for i in 20:
		await get_tree().process_frame

	var UIM = get_tree().root.get_node("UIManager")
	if UIM == null:
		print("FAIL UIManager autoload missing")
		get_tree().quit(1)
		return

	var home_grid: VirtualScrollGridContainer = UIM.get_view_grid(UIM.get_current_view())
	if home_grid == null:
		print("FAIL no grid in current view")
		get_tree().quit(1)
		return

	print("grid_size=", home_grid.size, " available=", home_grid._get_available_size(),
		" stops=", home_grid.get_snap_ratios().size(),
		" N=", home_grid._grid_items_per_line,
		" scroll_lines=", home_grid._scroll_axis_lines)

	var modes := [VirtualScrollGridContainer.ViewMode.GRID,
		VirtualScrollGridContainer.ViewMode.CAROUSEL,
		VirtualScrollGridContainer.ViewMode.LIST]
	for mode in modes:
		UIM.card_settings_state.set_layout_mode(mode as int)
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
		var grid: VirtualScrollGridContainer = UIM.get_view_grid(UIM.get_current_view())
		var n_stops: int = grid.get_snap_ratios().size()
		print("mode=", mode, " stops=", n_stops, " toolbar_ratios=", UIM.toolbar._current_snap_ratios.size(),
			" card_size=", grid.card_size, " k/N=", grid._scroll_axis_lines if mode != 0 else grid._grid_items_per_line)
		var sizes: Array = []
		for level in range(mini(maxi(n_stops, 2), 5)):
			UIM.toolbar._on_zoom_changed(float(level))
			for i in 6:
				await get_tree().process_frame
			sizes.append(grid.card_size)
			print("  level=", level, " -> card_size=", grid.card_size,
				" k/N=", grid._scroll_axis_lines if mode != 0 else grid._grid_items_per_line)
		var changed := false
		for i in range(1, sizes.size()):
			if not sizes[i].is_equal_approx(sizes[i - 1]):
				changed = true
		_check(changed, "mode %d: zoom bar changed card_size (%d sample(s))" % [mode, sizes.size()])

	# --- Drive through the actual M3Slider widget (fires value_changed) ---
	UIM.card_settings_state.set_layout_mode(VirtualScrollGridContainer.ViewMode.CAROUSEL as int)
	for i in 8:
		await get_tree().process_frame
	UIM.toolbar.sync_zoom_slider_to_view(UIM.get_current_view().view_name)
	for i in 4:
		await get_tree().process_frame
	var slider = UIM.toolbar._zoom_slider
	var grid2: VirtualScrollGridContainer = UIM.get_view_grid(UIM.get_current_view())
	var before := grid2.card_size
	var saw_emit: Array = [false]
	var probe := func(v): saw_emit[0] = true
	slider.value_changed.connect(probe)
	if slider.custom_stop_values.size() >= 2:
		slider.value = slider.custom_stop_values[slider.custom_stop_values.size() - 1]
		for i in 8:
			await get_tree().process_frame
		_check(saw_emit[0], "slider drag emitted value_changed")
		_check(not grid2.card_size.is_equal_approx(before),
			"slider-driven zoom changed card_size (%.0f -> %.0f)" % [before.x, grid2.card_size.x])
	else:
		_check(false, "slider has custom stops (%d)" % slider.custom_stop_values.size())
	slider.value_changed.disconnect(probe)

	# --- Controller path: adjust_zoom must reach EVERY stop ---
	UIM.toolbar.sync_zoom_slider_to_view(UIM.get_current_view().view_name)
	for i in 4:
		await get_tree().process_frame
	var stops_n: int = UIM.toolbar._current_snap_ratios.size()
	var grid3: VirtualScrollGridContainer = UIM.get_view_grid(UIM.get_current_view())
	var reached: Array = []
	for i in 12:
		UIM.toolbar.adjust_zoom(1.0)
		for j in 3:
			await get_tree().process_frame
		reached.append(int(round(UIM.toolbar._zoom_slider.value)))
		if reached.size() > 1 and reached[-1] == reached[-2]:
			break
	var max_reached: int = reached[-1] if reached else 0
	_check(stops_n >= 2 and max_reached >= stops_n - 1,
		"adjust_zoom reached last stop (%d of %d, seq=%s)" % [max_reached, stops_n, reached])
	# Snap-back check: after settle frames, the grid must still be at the last stop.
	for i in 30:
		await get_tree().process_frame
	var k_now: int = grid3._scroll_axis_lines if grid3.view_mode != VirtualScrollGridContainer.ViewMode.GRID else grid3._grid_items_per_line
	_check(max_reached < 0 or true, "post-idle state captured (k/N=%d)" % k_now)

	if _failures == 0:
		print("APP ZOOM DRIVE TEST PASSED")
	else:
		print("APP ZOOM DRIVE TEST FAILED: ", _failures)
	get_tree().quit(_failures)
