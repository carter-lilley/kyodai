class_name GridVisualSync
extends Node

## Owns the grid's top-level visual layer and the per-frame visual stamping
## pipeline: layer-space offset computation, pre-draw stamping, the
## reveal-on-sort gate, the scroll-completed rest stamp, and the visual draw
## order. Reads grid state (scroll container, margins, window membership,
## layout generation) via the backref; the layout generation itself stays
## grid-owned (bumped in the grid's sort handlers before delegating here).
## Connects/disconnects its own RenderingServer.frame_pre_draw connection
## (children _exit_tree before the parent, so teardown is safe).

## TEMP DIAGNOSTIC (remove after flicker hunt): env-gated per-frame dump of the
## window bookkeeping that feeds both the content layout and the visual stamps.
## Enabled with KYODAI_FRAME_PROBE=1. One row per drawn frame so a one-frame
## spike in any shared input (window first index, margins, stride, flow width)
## shows up as a single anomalous row.
var _frame_probe_enabled: bool = OS.get_environment("KYODAI_FRAME_PROBE") == "1"

var _grid: VirtualScrollGridContainer = null

## Top-level layer the cards' RS items render into (draws outside the grid's
## bounds without being clipped by margins or scroll).
var layer: Control = null

## Position of the flow's content origin within the margin container, captured
## post-sort from Godot's own container results (center position + flow
## position). Scroll-independent, so capturing it on sort is race-free: during
## scroll only the scroll offset moves, which we track separately as a float.
var _content_chain_offset := Vector2.ZERO

# Skip-stamp cache: the pre-draw loop is skipped when nothing feeding the
# offset math changed since the last stamp (idle frames far outnumber scroll
# frames).
var _last_stamp_scroll: float = -1.0
var _last_stamp_margin: int = -1
var _last_stamp_first: int = -1
var _last_stamp_count: int = -1
var _last_stamp_generation: int = -1

# Reveal-on-sort gate: cards stay hidden until the FlowContainer sort commits
# their positions, then are stamped + marked exactly once (at pre-draw, after
# the whole sort cascade).
var _reveal_pending: bool = false
var _reveal_requested_frame: int = -1

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func _ready() -> void:
	# _ready re-fires on every tree entry (DS reparents, nav rebuilds); the
	# layer is created once.
	if not layer:
		layer = Control.new()
		layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
		layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		layer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.clip_contents = false
		layer.z_index = -1
		layer.top_level = true
		add_child(layer)
		layer.position = Vector2.ZERO
		layer.size = get_viewport().get_visible_rect().size

	# _exit_tree disconnects and _ready re-runs on every tree entry (DS
	# reparents, nav rebuilds) — otherwise the stamping loop dies for this
	# grid instance.
	if not RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)

func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)

## Keep the top-level layer pinned to the viewport (called on resize and
## display-size changes so the layer never holds a stale viewport rect).
func resize_to_viewport() -> void:
	if layer and layer.top_level:
		layer.position = Vector2.ZERO
		layer.size = get_viewport().get_visible_rect().size

func configure_card(card: Control) -> void:
	if card.has_method("set_visual_layer"):
		card.set_visual_layer(layer)

func on_scroll_completed() -> void:
	"""Stamp all cards against the final rest position. The terminal write of
	a tween/chase can land without any further drawn frame (idle tree, nothing
	dirty), which would leave the pre-draw stamps frozen at the last motion
	frame's float position. A pure scroll landing queues no sort cascade
	(card positions are scroll-independent; scroll enters the offset formula
	directly), so stamping here is immediately correct. Reveal marking stays
	pre-draw gated."""
	if not _grid._card_has_sync_visual_offset or not _grid._scroll_container or not layer:
		return
	if _grid._active_cards.size() == 0:
		return
	_last_stamp_scroll = _grid._scroll_container.get_scroll_float()
	_last_stamp_margin = _grid._last_margin_top if _grid.vertical else _grid._last_margin_left
	_last_stamp_first = _grid._active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_grid._active_cards[0]) else -1
	_last_stamp_count = _grid._active_cards.size()
	_last_stamp_generation = _grid._layout_generation
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		card.sync_visual_transform_with_offset(compute_offset(card))

func _on_frame_pre_draw() -> void:
	if _frame_probe_enabled and _grid:
		_grid._frame_probe_log()
	# Stamp visual offsets at the last moment before render, from pure
	# container arithmetic. At pre-draw time the scroll value, margin cache and
	# window membership are all final for the frame, so the stamps are
	# render-fresh by construction — independent of sort/flush/deferred order.
	if not _grid or not _grid._card_has_sync_visual_offset or not _grid._scroll_container or not layer:
		return
	if _grid._active_cards.size() == 0:
		return
	# Skip the stamp loop entirely when nothing that feeds the offset math
	# changed since the last stamp (idle frames far outnumber scroll frames).
	# Track the FLOAT motion model, not the int scrollbar: during tween/chase
	# tails the int can sit still for frames while the float keeps gliding —
	# skipping on the int would freeze the visual layer mid-glide.
	var scroll_now: float = _grid._scroll_container.get_scroll_float()
	var margin_now: int = _grid._last_margin_top if _grid.vertical else _grid._last_margin_left
	var first_now: int = _grid._active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_grid._active_cards[0]) else -1
	if not _reveal_pending and scroll_now == _last_stamp_scroll and margin_now == _last_stamp_margin and first_now == _last_stamp_first and _grid._active_cards.size() == _last_stamp_count and _grid._layout_generation == _last_stamp_generation:
		return
	# A pending reveal means a sort cascade is (or was) in flight. Pre-draw runs
	# after the ENTIRE cascade (margin -> center -> flow), so positions and the
	# chain are final here — this is the only stamp that may also MARK cards
	# visible: marking from mid-cascade states (e.g. on_flow_sorted) flashed a
	# whole-strip offset by the margin delta for a frame.
	var do_reveal: bool = _reveal_pending
	_reveal_pending = false
	_reveal_requested_frame = -1
	_last_stamp_scroll = scroll_now
	_last_stamp_margin = margin_now
	_last_stamp_first = first_now
	_last_stamp_count = _grid._active_cards.size()
	_last_stamp_generation = _grid._layout_generation
	for card in _grid._active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		var expected_offset := compute_offset(card)
		card.sync_visual_transform_with_offset(expected_offset)
		if do_reveal and _grid._card_has_mark_visuals_position_synced:
			card._mark_visuals_position_synced()

func compute_offset(card: Control) -> Vector2:
	"""Layer-space offset for a card — ONE deterministic source of truth.

	Composed entirely from Godot's own layout results plus the precisely
	tracked float scroll:
	    scroll_container.origin − scroll_float + content_chain + card.position
	where `content_chain` is the flow's offset within the margin container
	(captured post-sort) and `card.position` is the FlowContainer's own child
	position. Every card on a line goes through the identical formula, so no
	column can diverge, and reading it never depends on mid-frame transform
	flushes (only the scroll float moves during scrolling, and we track it).
	"""
	var layer_origin := layer.global_position
	var vidx: int = card.get_meta("virtual_index", -1)
	if vidx < 0 or not _grid._scroll_container or not _grid._flow_container:
		return card.global_position - layer_origin
	var scroll_f := _grid._scroll_container.get_scroll_float()
	var scroll_vec := Vector2(scroll_f, 0.0) if not _grid.vertical else Vector2(0.0, scroll_f)
	# Read the container chain LIVE rather than from the sort-captured snapshot:
	# center/flow positions only change on layout (never during scroll), and in
	# the hidden pre-sort window a stale read is harmless because the card is
	# not visible yet. Live reads make the offset immune to sort ordering.
	var chain := _content_chain_offset
	if _grid._center_container and _grid._flow_container:
		chain = _grid._center_container.position + _grid._flow_container.position
	return _grid._scroll_container.get_global_rect().position - scroll_vec \
		+ chain + card.position - layer_origin

func stamp_and_mark(_tag: String = "", mark: bool = true) -> void:
	var use_offsets: bool = _grid._card_has_sync_visual_offset and _grid._scroll_container and layer
	for card in _grid._active_cards:
		if not is_instance_valid(card):
			continue
		# Don't mark cards before _ready() has run; _setup_rs_items() resets the
		# synced flag, so marking earlier would be silently undone.
		if not card.is_node_ready():
			continue
		if use_offsets:
			card.sync_visual_transform_with_offset(compute_offset(card))
		elif _grid._card_has_sync_visual_transform:
			card.sync_visual_transform()
		# When mark=false (pre-sort passes), newly added cards keep their RS
		# items hidden until the deferred post-sort mark, so a stale pooled
		# position can never reach the screen even if the heal slips a frame.
		if mark and _grid._card_has_mark_visuals_position_synced:
			card._mark_visuals_position_synced()

## Capture the content chain post-sort (called from the grid's sort handlers
## after they bump the layout generation).
func on_content_sorted() -> void:
	if _grid._center_container and _grid._flow_container:
		_content_chain_offset = _grid._center_container.position + _grid._flow_container.position

## Request reveal-on-sort: cards stay hidden until the FlowContainer sort
## commits their positions, then are stamped + marked exactly once.
func request_reveal() -> void:
	_reveal_pending = true
	_reveal_requested_frame = Engine.get_process_frames()
	if _grid._flow_container:
		_grid._flow_container.queue_sort()

## The sort committed new FLOW child positions, but the container cascade may
## still be mid-flight: queued sorts flush in message-queue order, so the
## MARGIN/CENTER re-sorts (which move center.position via the new margins)
## can run AFTER this flow sort. Stamping now would mix the new child
## positions with the old chain — a whole-strip offset by the margin delta
## (one card pitch) flashing for a frame. The reveal therefore defers to
## _on_frame_pre_draw, which runs after the ENTIRE cascade, before render.
func on_flow_sorted_post() -> void:
	if _reveal_pending:
		_reveal_requested_frame = Engine.get_process_frames()

func has_reveal_pending() -> bool:
	return _reveal_pending

## Reveal fallback: if a sort never consumed the pending reveal (hidden view,
## container quirk), reveal after 3 frames rather than leaving cards hidden.
func check_reveal_fallback() -> void:
	if _reveal_pending and _reveal_requested_frame >= 0 \
		and Engine.get_process_frames() > _reveal_requested_frame + 3:
		_reveal_pending = false
		_reveal_requested_frame = -1
		stamp_and_mark("reveal-fallback", true)

func update_draw_order() -> void:
	var focused_idx = _grid._focus.focused_virtual_index()
	for card in _grid._active_cards:
		if not card.has_method("set_visual_draw_index"):
			continue
		var idx = card.get_meta("virtual_index", 0)
		var base_index = idx * 10
		if idx == focused_idx:
			base_index += 1000000
		card.set_visual_draw_index(base_index)
