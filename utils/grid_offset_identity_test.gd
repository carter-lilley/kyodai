## Headless verification that the deterministic visual-offset identity holds:
##   card.global - layer.global  ==  sc.origin - scroll_float + content_chain + card.position
## where content_chain = center.position + flow.position (captured post-sort).
## Run: godot --headless --path . -s res://utils/grid_offset_identity_test.gd
extends SceneTree

var _failures := 0

func _initialize() -> void:
	var win := Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)

	# Mirror the grid's container chain.
	var grid := Control.new()
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(grid)
	var outer_margin := 22
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	sc.offset_left = outer_margin
	sc.offset_top = outer_margin
	sc.offset_right = -outer_margin
	sc.offset_bottom = -outer_margin
	grid.add_child(sc)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(margin)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_FILL
	margin.add_child(center)
	var flow := FlowContainer.new()
	flow.vertical = false
	var sep := 16
	flow.add_theme_constant_override("h_separation", sep)
	flow.add_theme_constant_override("v_separation", sep)
	center.add_child(flow)
	var layer := Control.new()
	layer.top_level = true
	layer.position = Vector2.ZERO
	win.add_child(layer)

	var card_size := Vector2(180, 270)
	var total := 400
	var cards: Array = []
	for i in total:
		var c := Control.new()
		c.custom_minimum_size = card_size
		c.size_flags_horizontal = 0
		flow.add_child(c)
		cards.append(c)

	await process_frame
	await process_frame
	await process_frame

	# Captured post-sort chain offset.
	var content_chain: Vector2 = center.position + flow.position
	print("content_chain=", content_chain, " center.pos=", center.position, " flow.pos=", flow.position)
	print("scroll page=", sc.get_v_scroll_bar().page, " viewport=", sc.size)

	var scrolls := [0.0, 333.7, 1500.2, 4000.9]
	for sf in scrolls:
		sc.scroll_vertical = roundi(sf)
		# Mirror SmoothScrollContainer._set_current_scroll: content holds the
		# ROUNDED int; the float motion model carries the raw value (they differ
		# by <=0.5 during motion and converge exactly at rest).
		var scroll_float: float = sf
		await process_frame
		await process_frame
		var max_err := 0.0
		var worst := -1
		for i in cards.size():
			var c: Control = cards[i]
			# Truth (post-flush globals):
			var truth: Vector2 = c.global_position - layer.global_position
			# Deterministic formula:
			var scroll_vec := Vector2(0.0, scroll_float)
			var formula: Vector2 = sc.get_global_rect().position - scroll_vec + content_chain + c.position - layer.global_position
			var err: float = truth.distance_to(formula)
			if err > max_err:
				max_err = err
				worst = i
		var status := "OK" if max_err < 0.75 else "FAIL"
		if max_err >= 0.75:
			_failures += 1
		print("scroll=", sf, " max_err=", max_err, " worst_idx=", worst, " ", status)

	# --- Horizontal (carousel-style) geometry: column flow, horizontal scroll ---
	var grid2 := Control.new()
	grid2.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(grid2)
	var sc2 := ScrollContainer.new()
	sc2.set_anchors_preset(Control.PRESET_FULL_RECT)
	sc2.offset_left = outer_margin
	sc2.offset_top = outer_margin
	sc2.offset_right = -outer_margin
	sc2.offset_bottom = -outer_margin
	grid2.add_child(sc2)
	var margin2 := MarginContainer.new()
	margin2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc2.add_child(margin2)
	var center2 := CenterContainer.new()
	center2.size_flags_horizontal = Control.SIZE_FILL
	center2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin2.add_child(center2)
	var flow2 := FlowContainer.new()
	flow2.vertical = true  # column-major flow = horizontal carousel strip
	flow2.add_theme_constant_override("h_separation", sep)
	flow2.add_theme_constant_override("v_separation", sep)
	center2.add_child(flow2)

	var card2_size := Vector2(600, 660)
	var cards2: Array = []
	for i in 40:
		var c := Control.new()
		c.custom_minimum_size = card2_size
		flow2.add_child(c)
		cards2.append(c)

	await process_frame
	await process_frame
	await process_frame

	var chain2: Vector2 = center2.position + flow2.position
	var h_scrolls := [0.0, 250.4, 1300.6]
	for sf in h_scrolls:
		sc2.scroll_horizontal = roundi(sf)
		var scroll_float2: float = sf
		await process_frame
		await process_frame
		var max_err2 := 0.0
		for i in cards2.size():
			var c: Control = cards2[i]
			var truth2: Vector2 = c.global_position - layer.global_position
			var scroll_vec2 := Vector2(scroll_float2, 0.0)
			var formula2: Vector2 = sc2.get_global_rect().position - scroll_vec2 + chain2 + c.position - layer.global_position
			max_err2 = maxf(max_err2, truth2.distance_to(formula2))
		var status2 := "OK" if max_err2 < 0.75 else "FAIL"
		if max_err2 >= 0.75:
			_failures += 1
		print("hscroll=", sf, " max_err=", max_err2, " ", status2)

	if _failures == 0:
		print("IDENTITY TEST PASSED")
	else:
		print("IDENTITY TEST FAILED: ", _failures, " scroll positions")
	quit(_failures)
