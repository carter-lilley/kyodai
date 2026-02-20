class_name VirtualScrollGridContainer
extends Control

signal items_requested(offset, limit)
signal visible_range_changed(start, end, total)
signal item_created(item, index)
signal batch_progress_changed(progress: float)

@export var card_scene: PackedScene
@export var buffer_size: int = 75
@export var preload_distance: int = 25
@export var debug_mode: bool = true
@export var vertical: bool = true:
	set(value):
		if vertical != value:
			vertical = value
			if _flow_container:
				# FlowContainer.vertical = false means left-to-right flow (rows)
				# FlowContainer.vertical = true means top-to-bottom flow (columns)
				_flow_container.vertical = not vertical
			_recalculate_layout()
			_refresh_buffer()

const BASE_CARD_WIDTH: float = 202.0
const BASE_CARD_HEIGHT: float = 270.0
const GRID_SEPARATION: int = 10

var zoom: float = 1.0:
	set(value):
		var new_zoom = clampf(value, 0.5, 2.0)
		if not is_equal_approx(zoom, new_zoom):
			zoom = new_zoom
			_on_zoom_changed()

var item_height: float = 280.0
var item_width: float = 212.0

var _scroll_container: SmoothScrollContainer
var _margin_container: MarginContainer
var _flow_container: FlowContainer
var _debug_camera: Camera2D

var _total_items: int = 0
var _virtual_start: int = 0
var _virtual_end: int = 0
var _card_scene: PackedScene

var batch_progress: float = 0.0

var _card_pool: Array[Control] = []
var _active_cards: Array[Control] = []
var _max_pool_size: int = 120

var _data_cache: Dictionary = {}
var _pending_loads: Dictionary = {}

const MAX_CACHE_SIZE: int = 2000
var _cache_access_order: Array[int] = []

var _is_loading: bool = false

func _ready():
	_setup_ui()
	resized.connect(_on_resized)

func _on_resized():
	_recalculate_layout()

func _recalculate_layout():
	if not _flow_container or not _scroll_container:
		return
	
	var base_dims = _get_base_dimensions()
	item_width = (base_dims.x * zoom) + GRID_SEPARATION
	item_height = (base_dims.y * zoom) + GRID_SEPARATION
	
	_update_layout()
	_update_margin()
	if _scroll_container:
		if vertical:
			_on_scroll_value_changed(_scroll_container.scroll_vertical)
		else:
			_on_scroll_value_changed(_scroll_container.scroll_horizontal)

func _get_items_per_line() -> int:
	if not _scroll_container:
		return 1
	
	var result: int
	if vertical:
		result = max(1, int(size.x / item_width))
	else:
		result = max(1, int(size.y / item_height))
	return result

func _setup_ui():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_scroll_container = SmoothScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.scroll_vertical = 0
	add_child(_scroll_container)
	
	_scroll_container.scroll_value_changed.connect(_on_scroll_value_changed)
	
	_margin_container = MarginContainer.new()
	_margin_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.add_child(_margin_container)
	
	_flow_container = FlowContainer.new()
	# FlowContainer.vertical = false means left-to-right flow (rows) - for vertical scrolling
	# FlowContainer.vertical = true means top-to-bottom flow (columns) - for horizontal scrolling
	_flow_container.vertical = not vertical
	# FlowContainer needs to expand in both directions to properly wrap items
	_flow_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_flow_container.add_theme_constant_override("h_separation", GRID_SEPARATION)
	_flow_container.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_margin_container.add_child(_flow_container)
	
	if debug_mode:
		_setup_debug_camera()
		_scroll_container.clip_contents = false
	else:
		_scroll_container.clip_contents = true
	
	_recalculate_dimensions()

func _get_base_dimensions() -> Vector2:
	if SettingsManager:
		var orientation_setting = SettingsManager.get_setting("card_orientation")
		if orientation_setting:
			# Array settings store the index, not the string
			var orientation_idx = orientation_setting.value
			match orientation_idx:
				1: # Horizontal
					return Vector2(270.0, 202.0)
				2: # Square
					return Vector2(256.0, 256.0)
				_: # 0 = Vertical (default)
					return Vector2(202.0, 270.0)
	return Vector2(202.0, 270.0)

func _recalculate_dimensions():
	var base_dims = _get_base_dimensions()
	item_width = (base_dims.x * zoom) + GRID_SEPARATION
	item_height = (base_dims.y * zoom) + GRID_SEPARATION

func refresh_dimensions() -> void:
	"""Recalculate dimensions and refresh layout (call after orientation change)."""
	_recalculate_dimensions()
	_recalculate_layout()
	
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(zoom)
	
	_update_margin()

func _on_zoom_changed():
	_recalculate_dimensions()
	_recalculate_layout()
	
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(zoom)
	
	_update_margin()

func setup(card_scene_resource: PackedScene, total_items: int):
	_card_scene = card_scene_resource
	_total_items = total_items
	
	_instantiate_card_pool()
	
	# Wait for container sizing before initial load
	await get_tree().process_frame
	await get_tree().process_frame
	_recalculate_layout()
	# Only run initial load if it hasn't already been triggered (e.g., by set_total_count)
	if _active_cards.size() == 0:
		_initial_load()
	else:
		print("[VScrollGrid] setup skipped _initial_load, cards already exist: %d" % _active_cards.size())

func _instantiate_card_pool():
	if not _card_scene:
		return
	
	for card in _card_pool:
		if is_instance_valid(card):
			card.queue_free()
	_card_pool.clear()
	
	for i in range(_max_pool_size):
		var card = _card_scene.instantiate()
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		_card_pool.append(card)

func set_total_count(count: int, preserve_cache: bool = false):
	_total_items = count
	_update_layout()
	
	if preserve_cache:
		pass
	else:
		_refresh_buffer()

func _update_layout():
	var items_per_line = _get_items_per_line()
	var lines = ceili(float(_total_items) / items_per_line) if items_per_line > 0 else 0
	if vertical:
		var total_height = lines * item_height
		_flow_container.custom_minimum_size.y = total_height
	else:
		var total_width = lines * item_width
		_flow_container.custom_minimum_size.x = total_width

func _initial_load():
	print("[VScrollGrid] _initial_load CALLED - active_cards=%d" % _active_cards.size())
	print("[VScrollGrid] _initial_load - vertical: %s, flow_container.vertical: %s" % [vertical, _flow_container.vertical if _flow_container else "null"])
	print("[VScrollGrid] _initial_load - viewport size: %s, flow_container size: %s" % [size, _flow_container.size if _flow_container else "null"])
	var items_per_line = _get_items_per_line()
	print("[VScrollGrid] _initial_load - items_per_line: %d" % items_per_line)
	var visible_count: int
	if vertical:
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		visible_count = visible_rows * items_per_line
	else:
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		visible_count = visible_cols * items_per_line
	
	var initial_buffer = min(buffer_size, visible_count + items_per_line * 2)
	print("[VScrollGrid] _initial_load - visible_count: %d, initial_buffer: %d, total_items: %d" % [visible_count, initial_buffer, _total_items])
	
	_virtual_start = 0
	_virtual_end = min(initial_buffer, _total_items) - 1
	print("[VScrollGrid] _initial_load - creating cards %d to %d" % [_virtual_start, _virtual_end])
	
	for i in range(_virtual_end + 1):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			_active_cards.append(card)
			_flow_container.add_child(card)
			item_created.emit(card, i)
	
	print("[VScrollGrid] _initial_load - created %d cards, requesting data 0 to %d" % [_active_cards.size(), _virtual_end])
	_update_margin()
	_request_data(0, _virtual_end + 1)

func _on_scroll_value_changed(value: float):
	if _total_items == 0 or not _scroll_container:
		return
	
	var scroll_pos = int(value)
	var items_per_line = _get_items_per_line()
	
	var visible_start_idx: int
	var visible_end_idx: int
	var target_start: int
	var target_end: int
	
	if vertical:
		var viewport_height = size.y
		var top_row = int(scroll_pos / item_height)
		var visible_rows = ceili(viewport_height / item_height)
		visible_start_idx = top_row * items_per_line
		visible_end_idx = min(visible_start_idx + (visible_rows + 1) * items_per_line, _total_items - 1)
		target_start = max(0, visible_start_idx - items_per_line * 2)
		target_end = min(_total_items - 1, visible_end_idx + items_per_line * 2)
	else:
		var viewport_width = size.x
		var left_col = int(scroll_pos / item_width)
		var visible_cols = ceili(viewport_width / item_width)
		visible_start_idx = left_col * items_per_line
		visible_end_idx = min(visible_start_idx + (visible_cols + 1) * items_per_line, _total_items - 1)
		target_start = max(0, visible_start_idx - items_per_line * 2)
		target_end = min(_total_items - 1, visible_end_idx + items_per_line * 2)
	
	var changes_made = false
	var recycled_top = 0
	var recycled_bottom = 0
	
	var buffer_overlaps = false
	if _active_cards.size() > 0:
		var current_first = _active_cards[0].get_meta("virtual_index", 0)
		var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		
		buffer_overlaps = (current_first <= target_end) and (current_last >= target_start)
		
		if not buffer_overlaps:
			print("[VScrollGrid] Large jump detected - reloading buffer. Current: %d-%d, Target: %d-%d" % [current_first, current_last, target_start, target_end])
			_reload_buffer_around_target(visible_start_idx, visible_end_idx)
			changes_made = true
			
			if _active_cards.size() > 0:
				_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
				_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			
			_update_margin()
			_check_preload_needed()
			visible_range_changed.emit(visible_start_idx, min(visible_end_idx, _total_items), _total_items)
			
			if debug_mode:
				_update_debug_visuals(visible_start_idx, visible_end_idx)
			return
	
	if buffer_overlaps:
		while _active_cards.size() > 0:
			var first_card = _active_cards[0]
			var first_idx = first_card.get_meta("virtual_index", -1)
			
			if first_idx < target_start:
				_recycle_card_at_index(0)
				recycled_top += 1
				changes_made = true
			else:
				break
		
		while _active_cards.size() > 0:
			var last_card = _active_cards[_active_cards.size() - 1]
			var last_idx = last_card.get_meta("virtual_index", -1)
			
			if last_idx > target_end:
				_recycle_card_at_index(_active_cards.size() - 1)
				recycled_bottom += 1
				changes_made = true
			else:
				break
		
		if _active_cards.size() > 0:
			var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			while current_last < target_end and current_last < _total_items - 1:
				_add_card_at_end(current_last + 1)
				changes_made = true
				current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		
		if _active_cards.size() > 0:
			var current_first = _active_cards[0].get_meta("virtual_index", 0)
			while current_first > target_start and current_first > 0:
				_add_card_at_start(current_first - 1)
				changes_made = true
				current_first = _active_cards[0].get_meta("virtual_index", 0)
	
	if _active_cards.size() > 0:
		_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
		_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	
	_request_missing_data()
	
	_update_margin()
	_check_preload_needed()
	
	visible_range_changed.emit(visible_start_idx, min(visible_end_idx, _total_items), _total_items)
	
	if vertical:
		var batch_rows = 1
		var batch_height_pixels = batch_rows * item_height
		var new_batch_progress = fmod(scroll_pos, batch_height_pixels) / batch_height_pixels
		
		if abs(new_batch_progress - batch_progress) > 0.001:
			batch_progress = clampf(new_batch_progress, 0.0, 1.0)
			batch_progress_changed.emit(batch_progress)
	else:
		var batch_cols = 1
		var batch_width_pixels = batch_cols * item_width
		var new_batch_progress = fmod(scroll_pos, batch_width_pixels) / batch_width_pixels
		
		if abs(new_batch_progress - batch_progress) > 0.001:
			batch_progress = clampf(new_batch_progress, 0.0, 1.0)
			batch_progress_changed.emit(batch_progress)
	
	if debug_mode:
		_update_debug_visuals(visible_start_idx, visible_end_idx)

func _recycle_card_at_index(index: int):
	if index < 0 or index >= _active_cards.size():
		return
	
	var card = _active_cards[index]
	var old_game_title = ""
	if "game" in card and card.game:
		old_game_title = card.game.title
	_active_cards.remove_at(index)
	
	if is_instance_valid(card):
		_disconnect_card_signals(card)
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		
		if "game" in card:
			if card.game:
				print("[VScrollGrid] Recycling card '%s' back to pool" % old_game_title)
			card.game = null
		if card.has_method("reset"):
			card.reset()
		
		if card.get_parent() == _flow_container:
			_flow_container.remove_child(card)
		
		_card_pool.append(card)

func _add_card_at_end(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return
	
	card.set_meta("virtual_index", virtual_index)
	_active_cards.append(card)
	_flow_container.add_child(card)
	
	if _data_cache.has(virtual_index):
		card.game = _data_cache[virtual_index]
		if card.game:
			print("[VScrollGrid] Assigned game '%s' to card at index %d" % [card.game.title, virtual_index])
		_update_cache_access_order(virtual_index)
		if card.has_method("update_display"):
			card.update_display()
	else:
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
	
	item_created.emit(card, virtual_index)

func _add_card_at_start(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return
	
	card.set_meta("virtual_index", virtual_index)
	_active_cards.insert(0, card)
	_flow_container.add_child(card)
	_flow_container.move_child(card, 0)
	
	if _data_cache.has(virtual_index):
		card.game = _data_cache[virtual_index]
		if card.game:
			print("[VScrollGrid] Assigned game '%s' to card at index %d (at start)" % [card.game.title, virtual_index])
		_update_cache_access_order(virtual_index)
		if card.has_method("update_display"):
			card.update_display()
	else:
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
	
	item_created.emit(card, virtual_index)

func _acquire_card() -> Control:
	while _card_pool.size() > 0:
		var card = _card_pool.pop_back()
		if is_instance_valid(card):
			card.set_meta("pooled", false)
			card.visible = true
			# Reset game data when reusing from pool
			if "game" in card:
				card.game = null
			card.queue_redraw()
			return card
	
	if _card_scene:
		var card = _card_scene.instantiate()
		card.set_meta("pooled", false)
		return card
	
	return null

func _disconnect_card_signals(card: Control):
	# Only disconnect signals that are connected by external code (e.g., LibraryView)
	# Internal signals like 'pressed' should NOT be disconnected as they are
	# connected in the card's _ready() function, which only runs once
	if card.has_signal("download_requested"):
		for conn in card.get_signal_connection_list("download_requested"):
			card.disconnect("download_requested", conn["callable"])

func _update_margin():
	if _active_cards.size() == 0:
		if vertical:
			_margin_container.add_theme_constant_override("margin_top", 0)
		else:
			_margin_container.add_theme_constant_override("margin_left", 0)
		return
	
	var first_idx = _active_cards[0].get_meta("virtual_index", 0)
	var items_per_line = _get_items_per_line()
	
	if vertical:
		var lines_before = first_idx / items_per_line
		var margin_height = lines_before * item_height
		_margin_container.add_theme_constant_override("margin_top", int(margin_height))
	else:
		var lines_before = first_idx / items_per_line
		var margin_width = lines_before * item_width
		_margin_container.add_theme_constant_override("margin_left", int(margin_width))

func _request_missing_data():
	if _is_loading or _active_cards.size() == 0:
		return
	
	var missing_indices: Array[int] = []
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= 0 and not _data_cache.has(idx) and not _pending_loads.has(idx):
			missing_indices.append(idx)
	
	if missing_indices.size() == 0:
		return
	
	missing_indices.sort()
	var batches: Array[Array] = []
	var current_batch: Array[int] = [missing_indices[0]]
	
	for i in range(1, missing_indices.size()):
		if missing_indices[i] == missing_indices[i - 1] + 1:
			current_batch.append(missing_indices[i])
		else:
			batches.append(current_batch)
			current_batch = [missing_indices[i]]
	batches.append(current_batch)
	
	for batch in batches:
		if batch.size() > 0:
			var offset = batch[0]
			var limit = batch.size()
			_request_data(offset, limit)

func _check_preload_needed():
	if _is_loading:
		return
	
	if _virtual_end < _total_items - 1:
		var distance_to_end = _total_items - 1 - _virtual_end
		if distance_to_end > 0 and distance_to_end <= preload_distance:
			var next_batch_start = _virtual_end + 1
			if not _pending_loads.has(next_batch_start) and not _data_cache.has(next_batch_start):
				print("[VScrollGrid] Preload forward: offset %d (distance %d)" % [next_batch_start, distance_to_end])
				_request_data(next_batch_start, min(buffer_size, _total_items - next_batch_start))
	
	if _virtual_start > 0:
		var distance_to_start = _virtual_start
		if distance_to_start > 0 and distance_to_start <= preload_distance:
			var prev_batch_start = max(0, _virtual_start - buffer_size)
			if not _pending_loads.has(prev_batch_start) and not _data_cache.has(prev_batch_start):
				print("[VScrollGrid] Preload backward: offset %d (distance %d)" % [prev_batch_start, distance_to_start])
				_request_data(prev_batch_start, min(buffer_size, _virtual_start - prev_batch_start))

func _request_data(offset: int, limit: int):
	if limit <= 0 or offset < 0 or offset >= _total_items:
		return
	
	limit = min(limit, _total_items - offset)
	_pending_loads[offset] = true
	_is_loading = true
	
	print("[VScrollGrid] Requesting data: offset=%d, limit=%d" % [offset, limit])
	items_requested.emit(offset, limit)

func on_items_loaded(items: Array[GameResource], offset: int, _is_preload: bool = false):
	print("[VScrollGrid] Items loaded: %d items at offset %d (active_cards: %d)" % [items.size(), offset, _active_cards.size()])
	_is_loading = false
	_pending_loads.erase(offset)
	
	if items.is_empty():
		print("[VScrollGrid] WARNING: Empty items array received")
		return
	
	for i in range(items.size()):
		var cache_key = offset + i
		
		if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
			_evict_oldest_cache_entries(items.size())
		
		_data_cache[cache_key] = items[i]
		_update_cache_access_order(cache_key)
	
	var updated_count = 0
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= offset and idx < offset + items.size():
			var data_idx = idx - offset
			if data_idx < items.size():
				card.game = items[data_idx]
				_update_cache_access_order(idx)
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()
				updated_count += 1
				print("[VScrollGrid] Updated card at index %d with game '%s'" % [idx, items[data_idx].title if items[data_idx] else "null"])
	
	print("[VScrollGrid] Updated %d cards with loaded data" % updated_count)

func _refresh_buffer():
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	_data_cache.clear()
	_cache_access_order.clear()
	_pending_loads.clear()
	_margin_container.add_theme_constant_override("margin_top", 0)
	_virtual_start = 0
	_virtual_end = 0
	_initial_load()

func _reload_buffer_around_target(visible_start: int, visible_end: int):
	print("[VScrollGrid] Reloading buffer around visible range %d-%d" % [visible_start, visible_end])
	
	var visible_count = visible_end - visible_start + 1
	var target_buffer_size = min(buffer_size, _total_items)
	
	var items_per_line = _get_items_per_line()
	var new_start = visible_start - (target_buffer_size - visible_count) / 2
	new_start = max(0, min(new_start, _total_items - target_buffer_size))
	new_start = (new_start / items_per_line) * items_per_line
	
	var new_end = min(new_start + target_buffer_size - 1, _total_items - 1)
	
	print("[VScrollGrid] New buffer range: %d-%d" % [new_start, new_end])
	
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	for i in range(new_start, new_end + 1):
		_add_card_at_end(i)
	
	_virtual_start = new_start
	_virtual_end = new_end
	_update_margin()
	
	_request_data(new_start, new_end - new_start + 1)

func get_target_scroll() -> float:
	return _scroll_container.get_target_scroll() if _scroll_container else 0.0

func get_visible_range() -> Dictionary:
	var items_per_line = _get_items_per_line()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height) + 1
		var visible_start = int(scroll_pos / item_height) * items_per_line
		var visible_end = min(visible_start + (visible_rows * items_per_line), _total_items)
		
		return {
			"start": visible_start,
			"end": visible_end,
			"total": _total_items,
			"buffer_start": _virtual_start,
			"buffer_size": _active_cards.size()
		}
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width) + 1
		var visible_start = int(scroll_pos / item_width) * items_per_line
		var visible_end = min(visible_start + (visible_cols * items_per_line), _total_items)
		
		return {
			"start": visible_start,
			"end": visible_end,
			"total": _total_items,
			"buffer_start": _virtual_start,
			"buffer_size": _active_cards.size()
		}

func get_card_at_index(index: int) -> Control:
	for card in _active_cards:
		if card.get_meta("virtual_index", -1) == index:
			return card
	return null

func scroll_to_index(index: int, animate: bool = false):
	if _scroll_container:
		var items_per_line = _get_items_per_line()
		if vertical:
			var line = index / items_per_line
			var target_y = line * item_height
			_scroll_container.scroll_to(target_y, animate)
		else:
			var line = index / items_per_line
			var target_x = line * item_width
			# SmoothScrollContainer might need scroll_to support for horizontal
			_scroll_container.scroll_to(target_x, animate)

func _update_debug_visuals(visible_start_idx: int, visible_end_idx: int):
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx < 0:
			continue
		
		var is_visible = idx >= visible_start_idx and idx <= visible_end_idx
		var has_data = _data_cache.has(idx)
		
		var debug_panel = card.get_node_or_null("_debug_panel")
		if not debug_panel:
			debug_panel = Panel.new()
			debug_panel.name = "_debug_panel"
			debug_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			
			var label = Label.new()
			label.name = "_debug_label"
			label.set_anchors_preset(Control.PRESET_TOP_LEFT)
			label.position = Vector2(5, 5)
			label.add_theme_font_size_override("font_size", 14)
			debug_panel.add_child(label)
			
			card.add_child(debug_panel)
			card.move_child(debug_panel, 0)
		
		var style = StyleBoxFlat.new()
		if is_visible:
			style.border_color = Color(0.0, 1.0, 0.0, 0.8) if has_data else Color(1.0, 0.5, 0.0, 0.8)
			style.bg_color = Color(0.0, 1.0, 0.0, 0.1) if has_data else Color(1.0, 0.5, 0.0, 0.1)
		else:
			style.border_color = Color(0.0, 0.5, 1.0, 0.5) if has_data else Color(0.5, 0.5, 0.5, 0.5)
			style.bg_color = Color(0.0, 0.5, 1.0, 0.05) if has_data else Color(0.5, 0.5, 0.5, 0.05)
		
		style.border_width_left = 3
		style.border_width_right = 3
		style.border_width_top = 3
		style.border_width_bottom = 3
		debug_panel.add_theme_stylebox_override("panel", style)
		
		var label = debug_panel.get_node("_debug_label")
		if label:
			var status = "DATA" if has_data else "LOADING"
			var location = "VISIBLE" if is_visible else "BUFFER"
			label.text = "#%d\n%s\n%s" % [idx, status, location]

func toggle_debug_mode():
	debug_mode = not debug_mode
	
	print("[VScrollGrid] Toggle debug mode: %s, scroll_pos=%d, virtual_start=%d, active_cards=%d" % [debug_mode, _scroll_container.scroll_vertical if _scroll_container else 0, _virtual_start, _active_cards.size()])
	
	if debug_mode:
		_scroll_container.clip_contents = false
		_setup_debug_camera()
		# Update debug visuals for all existing cards
		if _active_cards.size() > 0:
			var first_idx = _active_cards[0].get_meta("virtual_index", 0)
			var last_idx = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			_update_debug_visuals(first_idx, last_idx)
		print("[VScrollGrid] Debug camera position: %s" % _debug_camera.position)
		print("[VScrollGrid] First card position: %s" % (_active_cards[0].global_position if _active_cards.size() > 0 else "N/A"))
	else:
		_scroll_container.clip_contents = true
		if _debug_camera:
			_debug_camera.queue_free()
			_debug_camera = null
		for card in _active_cards:
			var debug_panel = card.get_node_or_null("_debug_panel")
			if debug_panel:
				debug_panel.queue_free()

func _setup_debug_camera():
	if _debug_camera:
		return
	
	_debug_camera = Camera2D.new()
	_debug_camera.zoom = Vector2(0.5, 0.5)
	_debug_camera.enabled = true
	add_child(_debug_camera)
	_update_debug_camera_position()

func _update_debug_camera_position():
	if not _debug_camera or not _scroll_container:
		return
	_debug_camera.position = _scroll_container.position + _scroll_container.size / 2.0

func increment_total_count(amount: int = 1) -> int:
	if amount <= 0:
		return _total_items
	
	var start_index = _total_items
	_total_items += amount
	
	_update_layout()
	
	if start_index == 0 and _active_cards.size() == 0 and _total_items > 0:
		print("[VScrollGrid] Library went from empty to %d items, triggering initial load" % _total_items)
		_initial_load_from_increment()
		return start_index
	
	var items_per_line = _get_items_per_line()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height) + 1
		var visible_start = int(scroll_pos / item_height) * items_per_line
		var visible_end = min(visible_start + (visible_rows * items_per_line), _total_items)
		
		visible_range_changed.emit(visible_start, visible_end, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width) + 1
		var visible_start = int(scroll_pos / item_width) * items_per_line
		var visible_end = min(visible_start + (visible_cols * items_per_line), _total_items)
		
		visible_range_changed.emit(visible_start, visible_end, _total_items)
	
	return start_index

func _initial_load_from_increment():
	var items_per_line = _get_items_per_line()
	var visible_count: int
	
	if vertical:
		var viewport_height = size.y if size.y > 0 else 600
		var visible_rows = ceili(viewport_height / item_height)
		visible_count = visible_rows * items_per_line
	else:
		var viewport_width = size.x if size.x > 0 else 800
		var visible_cols = ceili(viewport_width / item_width)
		visible_count = visible_cols * items_per_line
	
	var initial_buffer = min(buffer_size, visible_count + items_per_line * 2)
	
	_virtual_start = 0
	_virtual_end = min(initial_buffer, _total_items) - 1
	
	print("[VScrollGrid] Creating initial %d cards for %d total items" % [_virtual_end + 1, _total_items])
	
	for i in range(_virtual_end + 1):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			_active_cards.append(card)
			_flow_container.add_child(card)
			
			if _data_cache.has(i):
				card.game = _data_cache[i]
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()
			elif card.has_method("set_placeholder"):
				card.set_placeholder(true)
			
			item_created.emit(card, i)
	
	_update_margin()

func cache_items_at_offset(items: Array[GameResource], offset: int):
	for i in range(items.size()):
		if offset + i < _total_items:
			var cache_key = offset + i
			
			if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
				_evict_oldest_cache_entries(items.size())
			
			_data_cache[cache_key] = items[i]
			_update_cache_access_order(cache_key)
	
	if items.size() > 0:
		print("[VScrollGrid] Cached %d items at offset %d" % [items.size(), offset])
		
		var updated_count = 0
		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx >= offset and idx < offset + items.size():
				if _data_cache.has(idx):
					card.game = _data_cache[idx]
					_update_cache_access_order(idx)
					if card.has_method("set_placeholder"):
						card.set_placeholder(false)
					if card.has_method("update_display"):
						card.update_display()
					updated_count += 1
		
		if updated_count > 0:
			print("[VScrollGrid] Populated %d cards with cached data" % updated_count)

func refresh_if_visible(start_index: int, end_index: int):
	if _active_cards.size() == 0:
		return
	
	var current_first = _active_cards[0].get_meta("virtual_index", 0)
	var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	
	var overlap_start = max(start_index, current_first)
	var overlap_end = min(end_index, current_last)
	
	if overlap_start <= overlap_end:
		var updated_count = 0
		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx >= overlap_start and idx <= overlap_end and _data_cache.has(idx):
				card.game = _data_cache[idx]
				_update_cache_access_order(idx)
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()
				updated_count += 1
		
		if updated_count > 0:
			print("[VScrollGrid] Updated %d visible cards in range %d-%d" % [updated_count, overlap_start, overlap_end])

func _update_cache_access_order(cache_key: int):
	var idx = _cache_access_order.find(cache_key)
	if idx != -1:
		_cache_access_order.remove_at(idx)
	_cache_access_order.append(cache_key)

func _evict_oldest_cache_entries(count: int):
	var to_evict = mini(count, _cache_access_order.size())
	if to_evict <= 0:
		return
	
	print("[VScrollGrid] Evicting %d oldest cache entries (cache size: %d/%d)" % [to_evict, _data_cache.size(), MAX_CACHE_SIZE])
	
	for i in range(to_evict):
		var oldest_key = _cache_access_order.pop_front()
		if _data_cache.has(oldest_key):
			_data_cache.erase(oldest_key)
