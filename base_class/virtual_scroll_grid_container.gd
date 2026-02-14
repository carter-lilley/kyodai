class_name VirtualScrollGridContainer
extends Control

signal items_requested(offset, limit)
signal visible_range_changed(start, end, total)
signal item_created(item, index)

# Configuration
@export var card_scene: PackedScene
@export var grid_columns: int = 5
@export var item_height: float = 240.0
@export var buffer_size: int = 100  # Fixed 100 items for debugging
@export var debounce_time: float = 0.15  # 150ms after scroll stops
@export var fast_scroll_debounce: float = 0.05  # 50ms for fast scrolls
@export var slow_scroll_debounce: float = 0.15  # 150ms for slow scrolls
@export var velocity_threshold: float = 500.0  # Pixels per second to consider "fast scroll"
@export var preload_threshold: float = 300.0  # Start preloading when velocity > this pixels/sec
@export var preload_ahead: int = 2  # Number of rows to preload ahead of current position

# Internal nodes
var _scroll_container: ScrollContainer
var _grid_container: GridContainer
var _spacer: Control

# State
var _total_items: int = 0
var _buffer_start: int = 0  # Virtual index of first REAL card (not spacer)
var _is_loading: bool = false
var _scroll_debounce_timer: Timer
var _last_scroll_value: float = 0.0
var _card_scene: PackedScene

# Optimization: Object pool
var _card_pool: Array[Control] = []
var _max_pool_size: int = 120  # Slightly larger than buffer_size for padding

# Optimization: Scroll velocity tracking
var _scroll_velocity: float = 0.0
var _last_scroll_time: int = 0

# Optimization: Predictive preloading
var _preloaded_items: Array[GameResource] = []  # Items loaded ahead of time
var _preload_offset: int = -1  # Offset of preloaded items (-1 = none)
var _preload_direction: int = 0  # Direction we were preloading (-1 = up, 1 = down, 0 = none)

func _ready():
	_setup_ui()
	_setup_timer()

func _setup_ui():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_scroll_container)
	
	_grid_container = GridContainer.new()
	_grid_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_container.add_theme_constant_override("h_separation", 10)
	_grid_container.add_theme_constant_override("v_separation", 10)
	_grid_container.columns = grid_columns
	_scroll_container.add_child(_grid_container)
	
	_spacer = Control.new()
	_spacer.custom_minimum_size = Vector2(1, 0)
	_grid_container.add_child(_spacer)
	
	_scroll_container.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)

func _setup_timer():
	_scroll_debounce_timer = Timer.new()
	_scroll_debounce_timer.one_shot = true
	_scroll_debounce_timer.timeout.connect(_on_scroll_stopped)
	add_child(_scroll_debounce_timer)

func setup(card_scene_resource: PackedScene, total_items: int, columns: int = 5):
	_card_scene = card_scene_resource
	grid_columns = columns
	_grid_container.columns = grid_columns
	_total_items = total_items
	
	# Pre-instantiate card pool
	_instantiate_card_pool()
	
	_update_layout()
	_initial_load()

func _instantiate_card_pool():
	"""Pre-instantiate cards for object pooling."""
	if not _card_scene:
		return
	
	# Clear existing pool
	for card in _card_pool:
		if is_instance_valid(card):
			card.queue_free()
	_card_pool.clear()
	
	# Pre-instantiate pool
	for i in range(_max_pool_size):
		var card = _card_scene.instantiate()
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		_card_pool.append(card)
	
	print("[VScrollGrid] Instantiated %d cards in pool" % _card_pool.size())

func set_total_count(count: int):
	_total_items = count
	_update_layout()
	_refresh_buffer()

func _update_layout():
	var rows = ceili(float(_total_items) / grid_columns) if grid_columns > 0 else 0
	var total_height = rows * item_height
	_grid_container.custom_minimum_size.y = total_height

func _initial_load():
	_buffer_start = 0
	items_requested.emit(0, min(buffer_size, _total_items))
	_update_spacer()

func _on_scroll_changed(value: float):
	var current_time = Time.get_ticks_msec()
	
	# Calculate velocity and direction
	var scroll_direction = 0
	if _last_scroll_time > 0:
		var delta_time = (current_time - _last_scroll_time) / 1000.0
		if delta_time > 0:
			var delta_scroll = value - _last_scroll_value
			_scroll_velocity = abs(delta_scroll) / delta_time
			scroll_direction = sign(delta_scroll)  # -1 = up, 1 = down, 0 = no change
	
	_last_scroll_value = value
	_last_scroll_time = current_time
	
	# Adjust debounce time based on scroll speed
	var debounce = fast_scroll_debounce if _scroll_velocity > velocity_threshold else slow_scroll_debounce
	
	_scroll_debounce_timer.stop()
	_scroll_debounce_timer.start(debounce)
	
	# Start preloading if we're scrolling fast enough
	if _scroll_velocity > preload_threshold and scroll_direction != 0:
		_start_preloading(scroll_direction)

func _start_preloading(direction: int):
	"""Start preloading items in the scroll direction."""
	if _is_loading:
		return  # Don't preload while actively loading current buffer
	
	# Calculate where we'll likely need to be based on scroll direction
	var current_scroll = _scroll_container.scroll_vertical
	var current_row = int(current_scroll / item_height)
	var predicted_start = current_row * grid_columns
	
	# Adjust prediction based on direction and preload_ahead rows
	if direction > 0:  # Scrolling down
		predicted_start += preload_ahead * grid_columns
	else:  # Scrolling up
		predicted_start -= preload_ahead * grid_columns
	
	# Clamp and align to column boundary
	predicted_start = clamp(predicted_start, 0, maxi(0, _total_items - buffer_size))
	predicted_start = (predicted_start / grid_columns) * grid_columns
	
	# Check if we already have this data or if it's the same as current buffer
	if predicted_start == _buffer_start or predicted_start == _preload_offset:
		return
	
	# Check if direction changed - if so, discard old preload and start fresh
	if _preload_direction != 0 and _preload_direction != direction:
		print("[VScrollGrid] Direction changed from %d to %d, discarding old preload" % [_preload_direction, direction])
		_preloaded_items.clear()
		_preload_offset = -1
	
	# Start preloading this position
	_preload_direction = direction
	print("[VScrollGrid] Starting preload at offset %d (direction: %d)" % [predicted_start, direction])
	
	# Request the items (but not through items_requested - we'll handle differently)
	# We'll use a separate preload request
	_request_preload_items(predicted_start, min(buffer_size, _total_items - predicted_start))

func _request_preload_items(offset: int, limit: int):
	"""Request items for preloading without affecting _is_loading state."""
	if limit <= 0 or offset >= _total_items:
		return
	
	limit = min(limit, _total_items - offset)
	
	# Store the offset we're preloading
	_preload_offset = offset
	
	# Emit preload request - the caller should use a different handler or flag
	# For now, we'll use the same signal but the response will check if it's a preload
	print("[VScrollGrid] Requesting preload: offset=%d, limit=%d" % [offset, limit])
	items_requested.emit(offset, limit, true)  # Third param indicates preload

func on_preload_items_loaded(items: Array[GameResource], offset: int):
	"""Callback when preloaded items arrive."""
	print("[VScrollGrid] Preloaded items received: %d items at offset %d" % [items.size(), offset])
	
	# Only store if this is still the preload we're expecting
	if offset == _preload_offset:
		_preloaded_items = items.duplicate()
		print("[VScrollGrid] Preload complete, stored %d items" % _preloaded_items.size())
	else:
		print("[VScrollGrid] Stale preload data, discarding")

func _on_scroll_stopped():
	"""Validate and correct position when scroll stops."""
	if _total_items == 0 or not _scroll_container:
		return
	
	# Reset velocity tracking
	_scroll_velocity = 0.0
	
	# Calculate where we SHOULD be based on scroll position
	var scroll_pos = _scroll_container.scroll_vertical
	var expected_row = int(scroll_pos / item_height)
	var expected_start = expected_row * grid_columns
	expected_start = clamp(expected_start, 0, maxi(0, _total_items - buffer_size))
	
	# Round to column boundary
	expected_start = (expected_start / grid_columns) * grid_columns
	
	print("[VScrollGrid] Scroll stopped. scroll_pos=%d, row=%d, Current: %d, Expected: %d" % [int(scroll_pos), expected_row, _buffer_start, expected_start])
	
	if expected_start != _buffer_start:
		print("[VScrollGrid] Correcting buffer position")
		_set_buffer_position(expected_start)
	
	# Update visible range for status
	var viewport_height = _scroll_container.size.y
	var visible_rows = ceili(viewport_height / item_height) + 1
	var visible_start = expected_start
	var visible_end = mini(visible_start + (visible_rows * grid_columns), _total_items)
	visible_range_changed.emit(visible_start, visible_end, _total_items)


func _set_buffer_position(new_start: int):
	"""Set buffer to new position - clear old cards, load new ones using object pool."""
	if _is_loading:
		# Queue this update for after current load completes
		call_deferred("_set_buffer_position", new_start)
		return
	
	_buffer_start = new_start
	_update_spacer()
	
	# Check if we have preloaded data for this position
	if _preload_offset == new_start and not _preloaded_items.is_empty():
		print("[VScrollGrid] Using preloaded data for offset %d" % new_start)
		_use_preloaded_data()
		return
	
	# Preload data is stale (different offset), discard it
	if _preload_offset != -1 and _preload_offset != new_start:
		print("[VScrollGrid] Discarding stale preload (expected %d, got %d)" % [_preload_offset, new_start])
		_preloaded_items.clear()
		_preload_offset = -1
		_preload_direction = 0
	
	# Recycle all real cards (keep spacer) back to pool
	while _grid_container.get_child_count() > 1:
		var child = _grid_container.get_child(1)
		_grid_container.remove_child(child)
		_recycle_card(child)
	
	# Load new cards from pool
	var limit = min(buffer_size, _total_items - _buffer_start)
	if limit > 0:
		_is_loading = true
		items_requested.emit(_buffer_start, limit)

func _use_preloaded_data():
	"""Use preloaded data to swap cards atomically - no blank period."""
	var old_cards: Array[Control] = []
	
	# Collect old cards (keep spacer)
	while _grid_container.get_child_count() > 1:
		var child = _grid_container.get_child(1)
		_grid_container.remove_child(child)
		old_cards.append(child)
	
	# Add new cards from preloaded data
	for i in range(_preloaded_items.size()):
		var game = _preloaded_items[i]
		var card = _acquire_card()
		if card:
			card.game = game
			var virtual_index = _buffer_start + i
			card.set_meta("virtual_index", virtual_index)
			_grid_container.add_child(card)
			item_created.emit(card, virtual_index)
	
	print("[VScrollGrid] Used preloaded data: added %d cards" % _preloaded_items.size())
	
	# Now recycle old cards (after new ones are visible)
	for card in old_cards:
		_recycle_card(card)
	
	# Clear preload state
	_preloaded_items.clear()
	_preload_offset = -1
	_preload_direction = 0

func _recycle_card(card: Control):
	"""Return a card to the pool, disconnecting signals first."""
	if not is_instance_valid(card):
		return
	
	# Disconnect signals to prevent "already connected" errors on reuse
	_disconnect_card_signals(card)
	
	# Reset card state
	card.visible = false
	card.set_meta("pooled", true)
	card.set_meta("virtual_index", -1)
	
	# Clear game reference if it exists
	if "game" in card:
		card.game = null
	
	# Clear any textures/data via reset method if available
	if card.has_method("reset"):
		card.reset()
	
	# Return to pool
	_card_pool.append(card)

func _disconnect_card_signals(card: Control):
	"""Disconnect common signals to prevent errors when reusing cards."""
	# Disconnect download_requested if it exists
	if card.has_signal("download_requested"):
		var connections = card.get_signal_connection_list("download_requested")
		for conn in connections:
			card.disconnect("download_requested", conn["callable"])
	
	# Disconnect any other common signals that might be connected
	if card.has_signal("pressed"):
		var connections = card.get_signal_connection_list("pressed")
		for conn in connections:
			card.disconnect("pressed", conn["callable"])
	
	if card.has_signal("button_down"):
		var connections = card.get_signal_connection_list("button_down")
		for conn in connections:
			card.disconnect("button_down", conn["callable"])
	
	if card.has_signal("button_up"):
		var connections = card.get_signal_connection_list("button_up")
		for conn in connections:
			card.disconnect("button_up", conn["callable"])

func _acquire_card() -> Control:
	"""Get a card from the pool."""
	# Try to get from pool
	while _card_pool.size() > 0:
		var card = _card_pool.pop_back()
		if is_instance_valid(card):
			card.set_meta("pooled", false)
			card.visible = true
			return card
	
	# Pool exhausted - instantiate new (shouldn't happen often)
	if _card_scene:
		var card = _card_scene.instantiate()
		card.set_meta("pooled", false)
		return card
	
	return null

func on_items_loaded(items: Array[GameResource], offset: int, is_preload: bool = false):
	"""Callback when items are loaded from database.
	
	Args:
		items: Array of GameResource objects loaded
		offset: The virtual index offset of the first item
		is_preload: True if this is preloaded data, False for regular load
	"""
	print("[VScrollGrid] Items loaded: %d items at offset %d (preload: %s)" % [items.size(), offset, is_preload])
	
	# Handle preload data
	if is_preload:
		on_preload_items_loaded(items, offset)
		return
	
	_is_loading = false
	
	# Only accept data if it matches our current buffer position
	if offset != _buffer_start:
		print("[VScrollGrid] Stale data (offset %d != buffer %d), discarding" % [offset, _buffer_start])
		return
	
	# Add cards from pool
	for i in range(items.size()):
		var game = items[i]
		var card = _acquire_card()
		if card:
			card.game = game
			var virtual_index = offset + i
			card.set_meta("virtual_index", virtual_index)
			_grid_container.add_child(card)
			item_created.emit(card, virtual_index)
	
	print("[VScrollGrid] Added %d cards, buffer now has %d total (including spacer)" % [items.size(), _grid_container.get_child_count()])

func _update_spacer():
	"""Update spacer height to position visible cards at correct virtual position."""
	if _spacer:
		var rows_before = _buffer_start / grid_columns
		var spacer_height = rows_before * item_height
		_spacer.custom_minimum_size.y = spacer_height
		print("[VScrollGrid] Spacer height: %d (for buffer_start=%d)" % [int(spacer_height), _buffer_start])

func _refresh_buffer():
	"""Clear and reload the buffer."""
	while _grid_container.get_child_count() > 1:
		var child = _grid_container.get_child(1)
		_grid_container.remove_child(child)
		_recycle_card(child)
	
	_spacer.custom_minimum_size.y = 0
	_buffer_start = 0
	_initial_load()

func get_visible_range() -> Dictionary:
	var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
	var viewport_height = _scroll_container.size.y if _scroll_container else 600
	var visible_rows = ceili(viewport_height / item_height) + 1
	var visible_start = int(scroll_pos / item_height) * grid_columns
	var visible_end = mini(visible_start + (visible_rows * grid_columns), _total_items)
	
	return {
		"start": visible_start,
		"end": visible_end,
		"total": _total_items,
		"buffer_start": _buffer_start,
		"buffer_size": buffer_size
	}

func get_card_at_index(index: int) -> Control:
	for i in range(1, _grid_container.get_child_count()):  # Skip spacer at 0
		var child = _grid_container.get_child(i)
		if child.get_meta("virtual_index", -1) == index:
			return child
	return null

func scroll_to_index(index: int):
	if _scroll_container:
		var row = index / grid_columns
		var target_y = row * item_height
		_scroll_container.scroll_vertical = target_y
