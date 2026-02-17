class_name VirtualScrollGridContainer
extends Control

signal items_requested(offset, limit)
signal visible_range_changed(start, end, total)
signal item_created(item, index)
signal batch_progress_changed(progress: float)

@export var card_scene: PackedScene
@export var grid_columns: int = 5
@export var item_height: float = 290.0
@export var buffer_size: int = 75
@export var preload_distance: int = 25
@export var debug_mode: bool = false

var _scroll_container: SmoothScrollContainer
var _grid_container: GridContainer
var _spacer: Control
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
	
	_grid_container = GridContainer.new()
	_grid_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_container.add_theme_constant_override("h_separation", 10)
	_grid_container.add_theme_constant_override("v_separation", 10)
	_grid_container.columns = grid_columns
	_scroll_container.add_child(_grid_container)
	
	_spacer = Control.new()
	_spacer.custom_minimum_size = Vector2(1, 0)
	_grid_container.add_child(_spacer)

func setup(card_scene_resource: PackedScene, total_items: int, columns: int = 5):
	_card_scene = card_scene_resource
	grid_columns = columns
	_grid_container.columns = grid_columns
	_total_items = total_items
	
	_instantiate_card_pool()
	_update_layout()
	_initial_load()
	
	if debug_mode:
		_setup_debug_camera()

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
	var rows = ceili(float(_total_items) / grid_columns) if grid_columns > 0 else 0
	var total_height = rows * item_height
	_grid_container.custom_minimum_size.y = total_height

func _initial_load():
	_virtual_start = 0
	_virtual_end = min(buffer_size, _total_items) - 1
	
	for i in range(_virtual_end + 1):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			_active_cards.append(card)
			_grid_container.add_child(card)
			item_created.emit(card, i)
	
	_update_spacer()
	_request_data(0, _virtual_end + 1)

func _on_scroll_value_changed(value: float):
	if _total_items == 0 or not _scroll_container:
		return
	
	var scroll_pos = int(value)
	var viewport_height = _scroll_container.size.y
	
	var top_row = int(scroll_pos / item_height)
	var visible_rows = ceili(viewport_height / item_height)
	var visible_start_idx = top_row * grid_columns
	var visible_end_idx = min(visible_start_idx + (visible_rows + 1) * grid_columns, _total_items - 1)
	
	var target_start = max(0, visible_start_idx - grid_columns * 2)
	var target_end = min(_total_items - 1, visible_end_idx + grid_columns * 2)
	
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
			
			if _debug_camera:
				_debug_camera.position = Vector2(0, scroll_pos)
			
			_update_spacer()
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
	
	if _debug_camera:
		_debug_camera.position = Vector2(0, scroll_pos)
	
	_update_spacer()
	_check_preload_needed()
	
	visible_range_changed.emit(visible_start_idx, min(visible_end_idx, _total_items), _total_items)
	
	var batch_rows = 1
	var batch_height_pixels = batch_rows * item_height
	var new_batch_progress = fmod(scroll_pos, batch_height_pixels) / batch_height_pixels
	
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
		
		if card.get_parent() == _grid_container:
			_grid_container.remove_child(card)
		
		_card_pool.append(card)

func _add_card_at_end(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return
	
	card.set_meta("virtual_index", virtual_index)
	_active_cards.append(card)
	_grid_container.add_child(card)
	
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
	_grid_container.add_child(card)
	_grid_container.move_child(card, 1)
	
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
			return card
	
	if _card_scene:
		var card = _card_scene.instantiate()
		card.set_meta("pooled", false)
		return card
	
	return null

func _disconnect_card_signals(card: Control):
	if card.has_signal("download_requested"):
		for conn in card.get_signal_connection_list("download_requested"):
			card.disconnect("download_requested", conn["callable"])
	if card.has_signal("pressed"):
		for conn in card.get_signal_connection_list("pressed"):
			card.disconnect("pressed", conn["callable"])
	if card.has_signal("button_down"):
		for conn in card.get_signal_connection_list("button_down"):
			card.disconnect("button_down", conn["callable"])
	if card.has_signal("button_up"):
		for conn in card.get_signal_connection_list("button_up"):
			card.disconnect("button_up", conn["callable"])

func _update_spacer():
	if _spacer and _active_cards.size() > 0:
		var first_idx = _active_cards[0].get_meta("virtual_index", 0)
		var rows_before = first_idx / grid_columns
		var spacer_height = rows_before * item_height
		_spacer.custom_minimum_size.y = spacer_height

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
	print("[VScrollGrid] Items loaded: %d items at offset %d" % [items.size(), offset])
	_is_loading = false
	_pending_loads.erase(offset)
	
	if items.is_empty():
		return
	
	for i in range(items.size()):
		var cache_key = offset + i
		
		if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
			_evict_oldest_cache_entries(items.size())
		
		_data_cache[cache_key] = items[i]
		_update_cache_access_order(cache_key)
	
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

func _refresh_buffer():
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	_data_cache.clear()
	_cache_access_order.clear()
	_pending_loads.clear()
	_spacer.custom_minimum_size.y = 0
	_virtual_start = 0
	_virtual_end = 0
	_initial_load()

func _reload_buffer_around_target(visible_start: int, visible_end: int):
	print("[VScrollGrid] Reloading buffer around visible range %d-%d" % [visible_start, visible_end])
	
	var visible_count = visible_end - visible_start + 1
	var target_buffer_size = min(buffer_size, _total_items)
	
	var new_start = visible_start - (target_buffer_size - visible_count) / 2
	new_start = max(0, min(new_start, _total_items - target_buffer_size))
	new_start = (new_start / grid_columns) * grid_columns
	
	var new_end = min(new_start + target_buffer_size - 1, _total_items - 1)
	
	print("[VScrollGrid] New buffer range: %d-%d" % [new_start, new_end])
	
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	for i in range(new_start, new_end + 1):
		_add_card_at_end(i)
	
	_virtual_start = new_start
	_virtual_end = new_end
	_update_spacer()
	
	_request_data(new_start, new_end - new_start + 1)

func get_target_scroll() -> float:
	return _scroll_container.get_target_scroll() if _scroll_container else 0.0

func get_visible_range() -> Dictionary:
	var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
	var viewport_height = _scroll_container.size.y if _scroll_container else 600
	var visible_rows = ceili(viewport_height / item_height) + 1
	var visible_start = int(scroll_pos / item_height) * grid_columns
	var visible_end = min(visible_start + (visible_rows * grid_columns), _total_items)
	
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
		var row = index / grid_columns
		var target_y = row * item_height
		_scroll_container.scroll_to(target_y, animate)

func _setup_debug_camera():
	if _debug_camera:
		return
	
	print("[VScrollGrid] Setting up debug camera")
	
	_scroll_container.clip_contents = false
	
	_debug_camera = Camera2D.new()
	_debug_camera.name = "_debug_camera"
	_debug_camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	_debug_camera.zoom = Vector2(0.4, 0.4)
	_grid_container.add_child(_debug_camera)
	_debug_camera.make_current()
	
	print("[VScrollGrid] Debug camera active - zoom: 0.4x")

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
	
	if debug_mode:
		_setup_debug_camera()
	else:
		if _debug_camera:
			_debug_camera.queue_free()
			_debug_camera = null
		_scroll_container.clip_contents = true
		
		for card in _active_cards:
			var debug_panel = card.get_node_or_null("_debug_panel")
			if debug_panel:
				debug_panel.queue_free()

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
	
	var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
	var viewport_height = _scroll_container.size.y if _scroll_container else 600
	var visible_rows = ceili(viewport_height / item_height) + 1
	var visible_start = int(scroll_pos / item_height) * grid_columns
	var visible_end = min(visible_start + (visible_rows * grid_columns), _total_items)
	
	visible_range_changed.emit(visible_start, visible_end, _total_items)
	
	return start_index

func _initial_load_from_increment():
	_virtual_start = 0
	_virtual_end = min(buffer_size, _total_items) - 1
	
	print("[VScrollGrid] Creating initial %d cards for %d total items" % [_virtual_end + 1, _total_items])
	
	for i in range(_virtual_end + 1):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			_active_cards.append(card)
			_grid_container.add_child(card)
			
			if _data_cache.has(i):
				card.game = _data_cache[i]
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()
			elif card.has_method("set_placeholder"):
				card.set_placeholder(true)
			
			item_created.emit(card, i)
	
	_update_spacer()

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
