class_name GridDebugOverlay
extends Node

## Debug/audit tooling for VirtualScrollGridContainer: debug-mode card panels,
## zoomed-out debug camera, flow panel outline, and the frame-post-draw audits
## (DrawAudit stamp-vs-formula, RsAudit, GridInv, VisHole).
## Pure introspection: READS grid state via the backref but
## never writes it (writes go through the grid's own methods).

const DEBUG_LOG: bool = false

var _grid: VirtualScrollGridContainer = null

var _debug_camera: Camera2D
var _debug_flow_panel: Panel

# Debug visuals: cached styleboxes for card debug panels
var _debug_style_visible_data: StyleBoxFlat
var _debug_style_visible_loading: StyleBoxFlat
var _debug_style_buffer_data: StyleBoxFlat
var _debug_style_buffer_loading: StyleBoxFlat

var _drawaudit_last_deltas: Dictionary = {}

func setup(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func _enter_tree() -> void:
	# _exit_tree drops the audit connection and _ready does not re-fire on
	# reparents, so re-establish it here while debug visuals are up (the
	# camera only exists when enabled).
	if _debug_camera and not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw_audit)

func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw_audit)

func set_enabled(enabled: bool) -> void:
	if not _grid or not _grid.is_inside_tree():
		return

	if enabled:
		setup_camera()
		setup_flow_panel()
		if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
			RenderingServer.frame_post_draw.connect(_on_frame_post_draw_audit)
		if _grid._active_cards.size() > 0:
			var first_idx = _grid._active_cards[0].get_meta("virtual_index", 0)
			var last_idx = _grid._active_cards[_grid._active_cards.size() - 1].get_meta("virtual_index", 0)
			update_debug_visuals(first_idx, last_idx)
	else:
		if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
			RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw_audit)
		if _debug_camera:
			_debug_camera.queue_free()
			_debug_camera = null
		if _debug_flow_panel:
			_debug_flow_panel.queue_free()
			_debug_flow_panel = null
		# Clear draw-audit dedup state so it cannot grow unbounded while debug
		# mode is on and never leaks across debug sessions.
		_drawaudit_last_deltas.clear()
		# Clean debug panels from both active cards and pool cards
		for card in _grid._active_cards:
			if card.has_meta("_debug_panel_ref"):
				var debug_panel = card.get_meta("_debug_panel_ref")
				if is_instance_valid(debug_panel):
					debug_panel.queue_free()
				card.remove_meta("_debug_panel_ref")
		for card in _grid._pool.cards:
			if card.has_meta("_debug_panel_ref"):
				var debug_panel = card.get_meta("_debug_panel_ref")
				if is_instance_valid(debug_panel):
					debug_panel.queue_free()
				card.remove_meta("_debug_panel_ref")
		_debug_style_visible_data = null
		_debug_style_visible_loading = null
		_debug_style_buffer_data = null
		_debug_style_buffer_loading = null

func update_debug_visuals(visible_start_idx: int, visible_end_idx: int):
	# Lazy-init cached style boxes
	if not _debug_style_visible_data:
		_debug_style_visible_data = StyleBoxFlat.new()
		_debug_style_visible_data.border_color = Color(0.0, 1.0, 0.0, 0.8)
		_debug_style_visible_data.bg_color = Color(0.0, 1.0, 0.0, 0.1)
		_debug_style_visible_data.set_border_width_all(3)
		_debug_style_visible_loading = StyleBoxFlat.new()
		_debug_style_visible_loading.border_color = Color(1.0, 0.5, 0.0, 0.8)
		_debug_style_visible_loading.bg_color = Color(1.0, 0.5, 0.0, 0.1)
		_debug_style_visible_loading.set_border_width_all(3)
		_debug_style_buffer_data = StyleBoxFlat.new()
		_debug_style_buffer_data.border_color = Color(0.0, 0.5, 1.0, 0.5)
		_debug_style_buffer_data.bg_color = Color(0.0, 0.5, 1.0, 0.05)
		_debug_style_buffer_data.set_border_width_all(3)
		_debug_style_buffer_loading = StyleBoxFlat.new()
		_debug_style_buffer_loading.border_color = Color(0.5, 0.5, 0.5, 0.5)
		_debug_style_buffer_loading.bg_color = Color(0.5, 0.5, 0.5, 0.05)
		_debug_style_buffer_loading.set_border_width_all(3)

	for card in _grid._active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx < 0:
			continue

		var card_visible = idx >= visible_start_idx and idx <= visible_end_idx
		var has_data = _grid._data.has_index(idx)

		# Use cached metadata reference instead of tree traversal for performance
		var debug_panel = card.get_meta("_debug_panel_ref") if card.has_meta("_debug_panel_ref") else null
		if not debug_panel or not is_instance_valid(debug_panel):
			debug_panel = Panel.new()
			debug_panel.name = "_debug_panel"
			debug_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

			var label = M3Label.new()
			label.name = "_debug_label"
			label.set_anchors_preset(Control.PRESET_TOP_LEFT)
			label.position = Vector2(M3Units.dp(5), M3Units.dp(5))
			label.label_style = M3Label.Style.BODY_SMALL
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			debug_panel.add_child(label)

			card.add_child(debug_panel)
			card.move_child(debug_panel, 0)
			card.set_meta("_debug_panel_ref", debug_panel)

		var style: StyleBoxFlat
		if card_visible:
			style = _debug_style_visible_data if has_data else _debug_style_visible_loading
		else:
			style = _debug_style_buffer_data if has_data else _debug_style_buffer_loading
		debug_panel.add_theme_stylebox_override("panel", style)

		var debug_label = debug_panel.get_node("_debug_label")
		if debug_label:
			var status = "DATA" if has_data else "LOADING"
			var location = "VISIBLE" if card_visible else "BUFFER"
			debug_label.text = "#%d\n%s\n%s" % [idx, status, location]

	update_flow_panel_position()

func setup_camera():
	if _debug_camera:
		return

	_debug_camera = Camera2D.new()
	_debug_camera.zoom = Vector2(0.5, 0.5)
	_debug_camera.enabled = true
	add_child(_debug_camera)
	update_camera_position()

func update_camera_position():
	if not _debug_camera or not _grid._scroll_container:
		return
	_debug_camera.position = _grid._scroll_container.position + _grid._scroll_container.size / 2.0

func setup_flow_panel():
	if _debug_flow_panel:
		return

	_debug_flow_panel = Panel.new()
	_debug_flow_panel.name = "_debug_flow_panel"
	_debug_flow_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_flow_panel.z_index = -1
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.0, 0.0, 0.2)
	style.border_color = Color(1.0, 0.0, 0.0, 0.8)
	style.set_border_width_all(2)
	_debug_flow_panel.add_theme_stylebox_override("panel", style)
	_grid._margin_container.add_child(_debug_flow_panel)
	update_flow_panel_position()

func update_flow_panel_position():
	if not _debug_flow_panel or not _grid._flow_container:
		return
	var flow_pos = _grid._flow_container.global_position
	var parent_pos = _grid._margin_container.global_position
	_debug_flow_panel.position = flow_pos - parent_pos
	_debug_flow_panel.size = _grid._flow_container.size

func frame_probe_log() -> void:
	if not _grid._scroll_container:
		return
	var first_idx := -1
	var last_idx := -1
	if _grid._active_cards.size() > 0:
		if is_instance_valid(_grid._active_cards[0]):
			first_idx = _grid._active_cards[0].get_meta("virtual_index", -1)
		if is_instance_valid(_grid._active_cards[_grid._active_cards.size() - 1]):
			last_idx = _grid._active_cards[_grid._active_cards.size() - 1].get_meta("virtual_index", -1)
	var ref_pos := Vector2.INF
	var ref_glob := Vector2.INF
	var ref_min := Vector2.INF
	var ref_card: Control = _grid._active_cards_by_index.get(first_idx + 2, null) if first_idx >= 0 else null
	if ref_card and is_instance_valid(ref_card):
		ref_pos = ref_card.position
		ref_glob = ref_card.global_position
		ref_min = ref_card.custom_minimum_size
	print("[FrameProbe] f=", Engine.get_process_frames(),
		" sf=", snappedf(_grid._scroll_container.get_scroll_float(), 0.01),
		" si=", _grid._scroll_container.scroll_vertical if _grid.vertical else _grid._scroll_container.scroll_horizontal,
		" buf=", _grid._buffer_target_start, "-", _grid._buffer_target_end,
		" act=", first_idx, "-", last_idx, " n=", _grid._active_cards.size(),
		" vis=", _grid._visible_start_idx, "-", _grid._visible_end_idx,
		" ml=", _grid._last_margin_left, " mr=", _grid._last_margin_right,
		" mt=", _grid._last_margin_top, " mb=", _grid._last_margin_bottom,
		" fw=", snappedf(_grid._last_flow_width, 0.01), " fh=", snappedf(_grid._last_flow_height, 0.01),
		" stride=", snappedf(_grid._get_normal_stride(), 0.01),
		" bl=", _grid._current_buffer_lines,
		" tot=", _grid._total_items, " src=", _grid._source_total_items,
		" ctr=", _grid._center_container.position if _grid._center_container else Vector2.INF,
		" flw=", _grid._flow_container.position if _grid._flow_container else Vector2.INF,
		" ref=", ref_pos, " refg=", ref_glob, " refmin=", ref_min,
		" fsz=", _grid._flow_container.size if _grid._flow_container else Vector2.INF,
		" fmin=", _grid._flow_container.get_combined_minimum_size() if _grid._flow_container else Vector2.INF,
		" fcnt=", _grid._flow_container.get_child_count() if _grid._flow_container else -1,
		" csz=", _grid._center_container.size if _grid._center_container else Vector2.INF,
		" msz=", _grid._margin_container.size if _grid._margin_container else Vector2.INF,
		" ssz=", _grid._scroll_container.size if _grid._scroll_container else Vector2.INF,
		" g=", _grid._layout_generation)

func _on_frame_post_draw_audit() -> void:
	# Render-time truth check: after the frame was drawn, the stamped origins
	# must equal the arithmetic offsets computed from the final frame state.
	if not _grid.debug_mode:
		return
	if not _grid._card_has_sync_visual_offset or not _grid._scroll_container or not _grid._visual_sync.layer:
		return
	if _grid._active_cards.size() == 0:
		return
	var worst := 0.0
	var worst_idx := -1
	var worst_stamp := Vector2.ZERO
	var worst_exp := Vector2.ZERO
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		var lt_v = card.get("_last_visual_transform")
		if not lt_v is Transform2D:
			continue
		var stamp: Vector2 = lt_v.origin
		var expected: Vector2 = _grid._visual_sync.compute_offset(card)
		var cs_v = card.get("content_scale")
		var cs: Vector2 = cs_v if cs_v is Vector2 else Vector2.ONE
		if not cs.is_equal_approx(Vector2.ONE):
			var pivot: Vector2 = card._get_content_scale_pivot() if card.has_method("_get_content_scale_pivot") else card.size * 0.5
			expected += pivot - cs * pivot
		var d := stamp.distance_to(expected)
		if d > worst:
			worst = d
			worst_idx = card.get_meta("virtual_index", -1)
			worst_stamp = stamp
			worst_exp = expected
	if worst > 2.0:
		# De-spam: report a card only when its delta changes materially; a static
		# layout-vs-model constant is printed once, oscillation prints per change.
		var delta_key := int(round(worst * 2.0))
		var last_delta: int = _drawaudit_last_deltas.get(worst_idx, -1000)
		if delta_key != last_delta:
			_drawaudit_last_deltas[worst_idx] = delta_key
			if DEBUG_LOG: print("[DrawAudit] MISMATCH: worst=", worst, " idx=", worst_idx, " stamp=", worst_stamp, " exp=", worst_exp, " scroll=", _grid._scroll_container.scroll_vertical if _grid.vertical else _grid._scroll_container.scroll_horizontal, " margin=", _grid._last_margin_top if _grid.vertical else _grid._last_margin_left, " first=", _grid._active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_grid._active_cards[0]) else -1, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

func audit_structure(tag: String) -> void:
	if not _grid.debug_mode:
		return
	var prev_idx := -2
	var dup := -1
	var nonmono := -1
	var seen := {}
	for c in _grid._active_cards:
		if not is_instance_valid(c):
			continue
		var m: int = c.get_meta("virtual_index", -1)
		if seen.has(m):
			dup = m
			break
		seen[m] = true
		if m <= prev_idx:
			nonmono = m
			break
		prev_idx = m
	var flow_cards := 0
	var spacers := 0
	for ch in _grid._flow_container.get_children():
		if ch.has_meta("page_spacer") or ch.has_meta("stagger_spacer"):
			spacers += 1
		else:
			flow_cards += 1
	if dup >= 0 or nonmono >= 0 or flow_cards != _grid._active_cards.size():
		var first: int = _grid._active_cards[0].get_meta("virtual_index", -1) if _grid._active_cards.size() > 0 else -1
		if DEBUG_LOG: print("[GridInv] VIOLATION tag=", tag, " dup=", dup, " nonmono=", nonmono, " active=", _grid._active_cards.size(), " flow_cards=", flow_cards, " spacers=", spacers, " first=", first, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

func audit_visual_holes() -> void:
	if not _grid.debug_mode:
		return
	var unsynced: Array = []
	var invisible: Array = []
	for card in _grid._active_cards:
		if not is_instance_valid(card):
			continue
		var vidx: int = card.get_meta("virtual_index", -1)
		if not card.visible:
			invisible.append(vidx)
		if _grid._card_has_mark_visuals_position_synced and card.get("_visuals_position_synced") == false:
			unsynced.append(vidx)
	if unsynced.size() > 0 or invisible.size() > 0:
		if DEBUG_LOG: print("[VisHole] unsynced=", unsynced, " invisible=", invisible, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

func soak_test(iterations: int = 20) -> void:
	"""Debug stress test: random teleports + scroll bursts with all violation
	audits active. Any [GridInv]/[VisHole]/[RsAudit]/[DrawAudit] output during
	the run indicates a broken invariant. Call from the debugger or a hotkey."""
	if DEBUG_LOG: print("[SoakTest] starting: iterations=", iterations, " items=", _grid._source_total_items, " mode=", _grid.view_mode)
	for i in iterations:
		if _grid._source_total_items <= 0 or not _grid._scroll_container:
			break
		_grid.scroll_to_index_and_focus(randi() % _grid._source_total_items, false)
		await get_tree().process_frame
		await get_tree().process_frame
		for j in 4:
			var dir := 1.0 if j % 2 == 0 else -1.0
			_grid._scroll_container.scroll_to(_grid._get_current_scroll_pos() + dir * _grid._get_normal_stride() * 2.5, false)
			await get_tree().process_frame
		audit_structure("soak")
	if DEBUG_LOG: print("[SoakTest] complete: iterations=", iterations, " mode=", _grid.view_mode)

func audit_render_state(tag: String) -> void:
	"""Compare what is actually rendered (RS canvas item transforms, visual
	layer state, scroll content offset) against the layout truth. Runs deferred
	(post-sort, post-sync) so any divergence here is a genuine render bug."""
	if not _grid.debug_mode:
		return
	if not _grid._visual_sync.layer or not _grid._scroll_container:
		return
	var layer_pos := _grid._visual_sync.layer.global_position
	if _grid._visual_sync.layer.position != Vector2.ZERO or not _grid._visual_sync.layer.top_level or not _grid._visual_sync.layer.visible:
		if DEBUG_LOG: print("[LayerAudit] tag=", tag, " pos=", _grid._visual_sync.layer.position, " global=", layer_pos, " top_level=", _grid._visual_sync.layer.top_level, " visible=", _grid._visual_sync.layer.visible, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())
	var mc_pos: float = _grid._margin_container.position.y if _grid.vertical else _grid._margin_container.position.x
	var scroll_now: float = float(_grid._scroll_container.scroll_vertical if _grid.vertical else _grid._scroll_container.scroll_horizontal)
	var mc_delta: float = absf(mc_pos + scroll_now)
	var worst := 0.0
	var worst_idx := -1
	var worst_rs := Vector2.ZERO
	var worst_exp := Vector2.ZERO
	var worst_cs := Vector2.ONE
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		var lt_v = card.get("_last_visual_transform")
		if not lt_v is Transform2D:
			continue
		var rs_origin: Vector2 = lt_v.origin
		var exp_origin: Vector2 = _grid._visual_sync.compute_offset(card)
		var cs_v = card.get("content_scale")
		var cs: Vector2 = cs_v if cs_v is Vector2 else Vector2.ONE
		if not cs.is_equal_approx(Vector2.ONE):
			var pivot: Vector2 = card._get_content_scale_pivot() if card.has_method("_get_content_scale_pivot") else card.size * 0.5
			exp_origin += pivot - cs * pivot
		var d: float = rs_origin.distance_to(exp_origin)
		if d > worst:
			worst = d
			worst_idx = card.get_meta("virtual_index", -1)
			worst_rs = rs_origin
			worst_exp = exp_origin
			worst_cs = cs
	if worst > 2.0 or mc_delta > 2.0:
		if DEBUG_LOG: print("[RsAudit] tag=", tag, " worst=", worst, " idx=", worst_idx, " rs=", worst_rs, " exp=", worst_exp, " cs=", worst_cs, " margin_lag=", mc_delta, " scroll=", scroll_now, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())
