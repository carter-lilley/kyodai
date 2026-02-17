class_name VirtualScrollGridContainer
extends Control

signal items_requested(offset, limit)
signal visible_range_changed(start, end, total)
signal item_created(item, index)
signal batch_progress_changed(progress: float)  # 0.0 to 1.0 progress through current batch

# Configuration
@export var card_scene: PackedScene
@export var grid_columns: int = 5
@export var item_height: float = 290.0  # 280px card + 10px v_separation
@export var buffer_size: int = 75  # Total cards in circular buffer
@export var preload_distance: int = 25  # Items from edge to trigger preload (6 rows)
@export var debug_mode: bool = false  # Enable visual debugging

# Smooth Scrolling
@export var smooth_scrolling: bool = true
@export var smooth_scroll_duration: float = 2.0  # Duration of smooth scroll in seconds
@export var smooth_scroll_big_jump_threshold: float = 3500.0  # Distance (pixels) where we slow down big jumps
@export var smooth_scroll_big_jump_multiplier: float = 3.0  # How much to slow down big jumps (2x = twice as slow)

# Internal nodes
var _scroll_container: ScrollContainer
var _grid_container: GridContainer
var _spacer: Control
var _debug_camera: Camera2D

# State
var _total_items: int = 0
var _virtual_start: int = 0  # Virtual index of first visible card
var _virtual_end: int = 0    # Virtual index of last visible card
var _card_scene: PackedScene

# Batch progress tracking
var batch_progress: float = 0.0  # 0.0 to 1.0 progress through current batch

# Card pool and tracking
var _card_pool: Array[Control] = []
var _active_cards: Array[Control] = []  # Currently displayed cards in order
var _max_pool_size: int = 120

# Data cache
var _data_cache: Dictionary = {}  # offset -> Array[GameResource]
var _pending_loads: Dictionary = {}  # offset -> bool

# Loading state
var _is_loading: bool = false

# Smooth scrolling state
var _target_scroll_y: float = 0.0
var _scroll_tween: Tween
var _is_smooth_scrolling: bool = false

# Scrollbar drag smoothing
var _is_dragging_scrollbar: bool = false
var _scrollbar_drag_start_mouse_y: float = 0.0
var _scrollbar_drag_start_value: float = 0.0

func _ready():
	_setup_ui()

func _setup_ui():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.scroll_vertical = 0
	add_child(_scroll_container)
	
	# Connect to scrollbar value changes for efficient scroll detection
	var v_scrollbar = _scroll_container.get_v_scroll_bar()
	if v_scrollbar:
		v_scrollbar.value_changed.connect(_on_scroll_value_changed)
	
	# Connect to gui_input to intercept scroll wheel events for smooth scrolling
	if smooth_scrolling:
		_scroll_container.gui_input.connect(_on_scroll_container_input)
		# Also connect to scrollbar for drag smoothing
		v_scrollbar.gui_input.connect(_on_scrollbar_input)
	
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
	
	# Setup debug camera after everything is ready
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

func set_total_count(count: int):
	_total_items = count
	_update_layout()
	_refresh_buffer()

func _update_layout():
	var rows = ceili(float(_total_items) / grid_columns) if grid_columns > 0 else 0
	var total_height = rows * item_height
	_grid_container.custom_minimum_size.y = total_height

func _initial_load():
	_virtual_start = 0
	_virtual_end = min(buffer_size, _total_items) - 1
	
	# Create initial cards as placeholders
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
	"""Handle scroll position changes via scrollbar signal."""
	if _total_items == 0 or not _scroll_container:
		return
	
	# Sync target value when scroll changes from non-smooth sources
	# (touch pan, keyboard navigation, etc.) but NOT during scrollbar drag
	# or smooth scrolling animations
	if smooth_scrolling and not _is_smooth_scrolling and not _is_dragging_scrollbar:
		_target_scroll_y = value
	
	var scroll_pos = int(value)
	var viewport_height = _scroll_container.size.y
	
	# Calculate visible range
	var top_row = int(scroll_pos / item_height)
	var visible_rows = ceili(viewport_height / item_height)
	var visible_start_idx = top_row * grid_columns
	var visible_end_idx = min(visible_start_idx + (visible_rows + 1) * grid_columns, _total_items - 1)
	
	# Calculate target buffer range (visible area + padding)
	var target_start = max(0, visible_start_idx - grid_columns * 2)  # 2 rows padding above
	var target_end = min(_total_items - 1, visible_end_idx + grid_columns * 2)  # 2 rows padding below
	
	var changes_made = false
	var recycled_top = 0
	var recycled_bottom = 0
	
	# Check if current buffer overlaps with target range
	var buffer_overlaps = false
	if _active_cards.size() > 0:
		var current_first = _active_cards[0].get_meta("virtual_index", 0)
		var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		
		# Overlap check: current range intersects with target range
		buffer_overlaps = (current_first <= target_end) and (current_last >= target_start)
		
		# If no overlap (large jump), reload the buffer completely
		if not buffer_overlaps:
			print("[VScrollGrid] Large jump detected - reloading buffer. Current: %d-%d, Target: %d-%d" % [current_first, current_last, target_start, target_end])
			_reload_buffer_around_target(visible_start_idx, visible_end_idx)
			changes_made = true
			
			# Update virtual range tracking after reload
			if _active_cards.size() > 0:
				_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
				_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			
			# Update debug camera position to follow scroll
			if _debug_camera:
				_debug_camera.position = Vector2(0, scroll_pos)
			
			_update_spacer()
			_check_preload_needed()
			visible_range_changed.emit(visible_start_idx, min(visible_end_idx, _total_items), _total_items)
			
			if debug_mode:
				_update_debug_visuals(visible_start_idx, visible_end_idx)
			return
	
	# Only recycle incrementally if there's overlap
	if buffer_overlaps:
		# Recycle cards that are above the target range
		while _active_cards.size() > 0:
			var first_card = _active_cards[0]
			var first_idx = first_card.get_meta("virtual_index", -1)
			
			if first_idx < target_start:
				_recycle_card_at_index(0)
				recycled_top += 1
				changes_made = true
			else:
				break
		
		# Recycle cards that are below the target range
		while _active_cards.size() > 0:
			var last_card = _active_cards[_active_cards.size() - 1]
			var last_idx = last_card.get_meta("virtual_index", -1)
			
			if last_idx > target_end:
				_recycle_card_at_index(_active_cards.size() - 1)
				recycled_bottom += 1
				changes_made = true
			else:
				break
		
		# Fill buffer ahead (ensure we always have padding in front)
		if _active_cards.size() > 0:
			var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			while current_last < target_end and current_last < _total_items - 1:
				_add_card_at_end(current_last + 1)
				changes_made = true
				current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		
		# Fill buffer behind (ensure we always have padding behind)
		if _active_cards.size() > 0:
			var current_first = _active_cards[0].get_meta("virtual_index", 0)
			while current_first > target_start and current_first > 0:
				_add_card_at_start(current_first - 1)
				changes_made = true
				current_first = _active_cards[0].get_meta("virtual_index", 0)
	
	# Update virtual range tracking
	if _active_cards.size() > 0:
		_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
		_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	
	# Request data for any cards that don't have it (fixes orange cards)
	_request_missing_data()
	
	# Update debug camera position to follow scroll
	if _debug_camera:
		_debug_camera.position = Vector2(0, scroll_pos)
	
	_update_spacer()
	_check_preload_needed()
	
	# Update visible range signal
	visible_range_changed.emit(visible_start_idx, min(visible_end_idx, _total_items), _total_items)
	
	# Calculate batch progress (0.0 to 1.0 within each row update)
	# Progress resets every time spacer updates (each row = 240px)
	var batch_rows = 1  # Reset every 1 row when spacer updates
	var batch_height_pixels = batch_rows * item_height  # 240px per cycle
	var new_batch_progress = fmod(scroll_pos, batch_height_pixels) / batch_height_pixels
	
	if abs(new_batch_progress - batch_progress) > 0.001:
		batch_progress = clampf(new_batch_progress, 0.0, 1.0)
		batch_progress_changed.emit(batch_progress)
	
	# Update debug visuals if enabled
	if debug_mode:
		_update_debug_visuals(visible_start_idx, visible_end_idx)

func _recycle_card_at_index(index: int):
	if index < 0 or index >= _active_cards.size():
		return
	
	var card = _active_cards[index]
	_active_cards.remove_at(index)
	
	if is_instance_valid(card):
		_disconnect_card_signals(card)
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		
		if "game" in card:
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
	
	# Try to load data from cache
	if _data_cache.has(virtual_index):
		card.game = _data_cache[virtual_index]
		if card.has_method("update_display"):
			card.update_display()
	else:
		# Show placeholder and queue data request
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
		# Don't request here - let _request_missing_data batch them
	
	item_created.emit(card, virtual_index)

func _add_card_at_start(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return
	
	card.set_meta("virtual_index", virtual_index)
	_active_cards.insert(0, card)
	_grid_container.add_child(card)
	_grid_container.move_child(card, 1)  # After spacer
	
	# Try to load data from cache
	if _data_cache.has(virtual_index):
		card.game = _data_cache[virtual_index]
		if card.has_method("update_display"):
			card.update_display()
	else:
		# Show placeholder and queue data request
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
		# Don't request here - let _request_missing_data batch them
	
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
	#print(batch_progress)
	if _spacer and _active_cards.size() > 0:
		var first_idx = _active_cards[0].get_meta("virtual_index", 0)
		var rows_before = first_idx / grid_columns
		var spacer_height = rows_before * item_height
		_spacer.custom_minimum_size.y = spacer_height

func _request_missing_data():
	"""Request data for any cards that don't have it cached."""
	if _is_loading or _active_cards.size() == 0:
		return
	
	# Find ranges of cards that need data
	var missing_indices: Array[int] = []
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= 0 and not _data_cache.has(idx) and not _pending_loads.has(idx):
			missing_indices.append(idx)
	
	if missing_indices.size() == 0:
		return
	
	# Group consecutive indices into batches
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
	
	# Request each batch
	for batch in batches:
		if batch.size() > 0:
			var offset = batch[0]
			var limit = batch.size()
			_request_data(offset, limit)

func _check_preload_needed():
	if _is_loading:
		return
	
	# Check if we need to preload ahead (down)
	if _virtual_end < _total_items - 1:
		var distance_to_end = _total_items - 1 - _virtual_end
		if distance_to_end > 0 and distance_to_end <= preload_distance:
			var next_batch_start = _virtual_end + 1
			if not _pending_loads.has(next_batch_start) and not _data_cache.has(next_batch_start):
				print("[VScrollGrid] Preload forward: offset %d (distance %d)" % [next_batch_start, distance_to_end])
				_request_data(next_batch_start, min(buffer_size, _total_items - next_batch_start))
	
	# Check if we need to preload behind (up)
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
	
	# Cache the data
	for i in range(items.size()):
		_data_cache[offset + i] = items[i]
	
	# Update any visible cards that need this data
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= offset and idx < offset + items.size():
			var data_idx = idx - offset
			if data_idx < items.size():
				card.game = items[data_idx]
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()

func _refresh_buffer():
	# Clear all active cards
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	_data_cache.clear()
	_pending_loads.clear()
	_spacer.custom_minimum_size.y = 0
	_virtual_start = 0
	_virtual_end = 0
	_initial_load()

func _reload_buffer_around_target(visible_start: int, visible_end: int):
	"""Reload buffer around the current visible area when there's a large jump."""
	print("[VScrollGrid] Reloading buffer around visible range %d-%d" % [visible_start, visible_end])
	
	# Calculate new buffer range centered on visible area
	var visible_count = visible_end - visible_start + 1
	var target_buffer_size = min(buffer_size, _total_items)
	
	# Center the buffer on the visible area
	var new_start = visible_start - (target_buffer_size - visible_count) / 2
	new_start = max(0, min(new_start, _total_items - target_buffer_size))
	new_start = (new_start / grid_columns) * grid_columns  # Align to column
	
	var new_end = min(new_start + target_buffer_size - 1, _total_items - 1)
	
	print("[VScrollGrid] New buffer range: %d-%d" % [new_start, new_end])
	
	# Clear current buffer
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	# Load new cards
	for i in range(new_start, new_end + 1):
		_add_card_at_end(i)
	
	_virtual_start = new_start
	_virtual_end = new_end
	_update_spacer()
	
	# Request data for the new range
	_request_data(new_start, new_end - new_start + 1)

func get_target_scroll() -> float:
	"""Get the target scroll value for smooth scrolling."""
	if smooth_scrolling:
		return _target_scroll_y
	return float(_scroll_container.scroll_vertical) if _scroll_container else 0.0

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
		
		if animate and smooth_scrolling:
			_target_scroll_y = target_y
			_start_smooth_scroll()
		else:
			_scroll_container.scroll_vertical = target_y
		# The value_changed signal will trigger _on_scroll_value_changed automatically

func _on_scroll_container_input(event: InputEvent):
	if not smooth_scrolling:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# Intercept wheel events for smooth scrolling
			var scrollbar = _scroll_container.get_v_scroll_bar()
			if not scrollbar:
				return
			
			# Calculate scroll step (same logic as ScrollContainer)
			var step = scrollbar.custom_step
			if step <= 0:
				# Default step: scrollbar page / 10
				step = scrollbar.page / 10.0
			
			# Accumulate into target value instead of setting directly
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_target_scroll_y -= step
			else:
				_target_scroll_y += step
			
			# Clamp to valid range
			_target_scroll_y = clampf(_target_scroll_y, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			
			# Start smooth scroll tween
			_start_smooth_scroll()
			
			# Accept the event to prevent ScrollContainer from handling it
			_scroll_container.accept_event()

func _on_scrollbar_input(event: InputEvent):
	if not smooth_scrolling:
		return
	
	var scrollbar = _scroll_container.get_v_scroll_bar()
	if not scrollbar:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Start dragging - capture initial state
				_is_dragging_scrollbar = true
				_scrollbar_drag_start_mouse_y = event.global_position.y
				_scrollbar_drag_start_value = _target_scroll_y
				
				# Kill any existing tween to allow immediate response to drag
				if _scroll_tween and _scroll_tween.is_valid():
					_scroll_tween.kill()
				_is_smooth_scrolling = false
			else:
				# Release drag
				_is_dragging_scrollbar = false
	
	elif event is InputEventMouseMotion and _is_dragging_scrollbar:
		# Calculate drag delta
		var mouse_delta = event.global_position.y - _scrollbar_drag_start_mouse_y
		
		# Convert mouse movement to scroll value
		# The ratio depends on how much content is scrollable vs scrollbar size
		var scrollable_range = scrollbar.max_value - scrollbar.min_value - scrollbar.page
		var scrollbar_track_height = scrollbar.size.y - scrollbar.get_combined_minimum_size().y
		
		if scrollbar_track_height > 0 and scrollable_range > 0:
			var scroll_delta = (mouse_delta / scrollbar_track_height) * scrollable_range
			_target_scroll_y = _scrollbar_drag_start_value + scroll_delta
			
			# Clamp to valid range
			_target_scroll_y = clampf(_target_scroll_y, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			
			# Start smooth scroll - the scrollbar thumb will lag behind mouse
			_start_smooth_scroll()
			
			# Accept event to prevent native scrollbar handling
			scrollbar.accept_event()

func _start_smooth_scroll():
	if not _scroll_container:
		return
	
	# Kill any existing tween
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	
	var start_value = float(_scroll_container.scroll_vertical)
	var target_value = _target_scroll_y
	
	# Calculate distance and adjust duration for big jumps
	var distance = abs(target_value - start_value)
	var duration = smooth_scroll_duration
	
	# For massive jumps (like A-Z), slow down to hide loading boundaries
	if distance > smooth_scroll_big_jump_threshold:
		var extra_distance = distance - smooth_scroll_big_jump_threshold
		var extra_duration = (extra_distance / smooth_scroll_big_jump_threshold) * (smooth_scroll_duration * (smooth_scroll_big_jump_multiplier - 1.0))
		duration = smooth_scroll_duration + extra_duration
	
	# Create new tween for smooth scrolling
	_scroll_tween = create_tween()
	_scroll_tween.set_trans(Tween.TRANS_EXPO)
	_scroll_tween.set_ease(Tween.EASE_OUT)
	
	# Use tween_method to interpolate scroll position
	_scroll_tween.tween_method(
		func(val: float): 
			if _scroll_container:
				_scroll_container.scroll_vertical = int(val),
			start_value,
			target_value,
			duration
		)
	
	_is_smooth_scrolling = true
	_scroll_tween.finished.connect(func(): _is_smooth_scrolling = false)

func _setup_debug_camera():
	"""Setup a simple Camera2D to zoom out and see more cards."""
	if _debug_camera:
		return
	
	print("[VScrollGrid] Setting up debug camera")
	
	# Disable clipping
	_scroll_container.clip_contents = false
	
	# Add camera to grid container
	_debug_camera = Camera2D.new()
	_debug_camera.name = "_debug_camera"
	_debug_camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	_debug_camera.zoom = Vector2(0.4, 0.4)  # Zoom out to see ~2.5x more
	_grid_container.add_child(_debug_camera)
	_debug_camera.make_current()
	
	print("[VScrollGrid] Debug camera active - zoom: 0.4x")

func _update_debug_visuals(visible_start_idx: int, visible_end_idx: int):
	"""Update card visual debug indicators."""
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx < 0:
			continue
		
		# Determine card state
		var is_visible = idx >= visible_start_idx and idx <= visible_end_idx
		var has_data = _data_cache.has(idx)
		
		# Create or get debug panel
		var debug_panel = card.get_node_or_null("_debug_panel")
		if not debug_panel:
			debug_panel = Panel.new()
			debug_panel.name = "_debug_panel"
			debug_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			
			# Add label for virtual index
			var label = Label.new()
			label.name = "_debug_label"
			label.set_anchors_preset(Control.PRESET_TOP_LEFT)
			label.position = Vector2(5, 5)
			label.add_theme_font_size_override("font_size", 14)
			debug_panel.add_child(label)
			
			card.add_child(debug_panel)
			card.move_child(debug_panel, 0)
		
		# Update visual state
		var style = StyleBoxFlat.new()
		if is_visible:
			# In viewport - green border
			style.border_color = Color(0.0, 1.0, 0.0, 0.8) if has_data else Color(1.0, 0.5, 0.0, 0.8)
			style.bg_color = Color(0.0, 1.0, 0.0, 0.1) if has_data else Color(1.0, 0.5, 0.0, 0.1)
		else:
			# In buffer but off-screen - blue border
			style.border_color = Color(0.0, 0.5, 1.0, 0.5) if has_data else Color(0.5, 0.5, 0.5, 0.5)
			style.bg_color = Color(0.0, 0.5, 1.0, 0.05) if has_data else Color(0.5, 0.5, 0.5, 0.05)
		
		style.border_width_left = 3
		style.border_width_right = 3
		style.border_width_top = 3
		style.border_width_bottom = 3
		debug_panel.add_theme_stylebox_override("panel", style)
		
		# Update label
		var label = debug_panel.get_node("_debug_label")
		if label:
			var status = "DATA" if has_data else "LOADING"
			var location = "VISIBLE" if is_visible else "BUFFER"
			label.text = "#%d\n%s\n%s" % [idx, status, location]

func toggle_debug_mode():
	"""Toggle debug mode on/off."""
	debug_mode = not debug_mode
	
	if debug_mode:
		_setup_debug_camera()
	else:
		# Remove debug camera
		if _debug_camera:
			_debug_camera.queue_free()
			_debug_camera = null
		_scroll_container.clip_contents = true
		
		# Remove all debug panels
		for card in _active_cards:
			var debug_panel = card.get_node_or_null("_debug_panel")
			if debug_panel:
				debug_panel.queue_free()
