class_name VirtualScrollGridContainer
extends Control

signal items_requested
signal visible_range_changed
signal item_created

# Configuration
@export var card_scene: PackedScene
@export var grid_columns: int = 5
@export var item_height: float = 240.0
@export var buffer_page_count: int = 3
@export var min_scroll_threshold: float = 60.0

# Internal nodes
var _scroll_container: ScrollContainer
var _grid_container: GridContainer
var _spacer: Control  # Spacer to position cards correctly in virtual space

# State
var _total_items: int = 0
var _buffer_start: int = 0  # Virtual index of first card in buffer
var _visible_start: int = 0
var _visible_end: int = 0
var _buffer_size: int = 0
var _card_scene: PackedScene
var _is_updating: bool = false
var _last_scroll_value: float = 0.0

func _ready():
	print("[VScrollGrid] _ready called")
	_setup_ui()
	print("[VScrollGrid] UI setup complete")

func _setup_ui():
	# Make this control fill its parent
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Create ScrollContainer
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_scroll_container)
	
	# Create GridContainer inside ScrollContainer
	_grid_container = GridContainer.new()
	_grid_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_container.add_theme_constant_override("h_separation", 10)
	_grid_container.add_theme_constant_override("v_separation", 10)
	_grid_container.columns = grid_columns
	_scroll_container.add_child(_grid_container)
	
	# Create spacer for virtual positioning
	_spacer = Control.new()
	_spacer.custom_minimum_size = Vector2(1, 0)
	_grid_container.add_child(_spacer)
	
	# Connect scroll signal
	_scroll_container.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)
	_scroll_container.resized.connect(_on_resized)

func setup(card_scene_resource: PackedScene, total_items: int, columns: int = 5):
	print("[VScrollGrid] setup() called")
	_card_scene = card_scene_resource
	grid_columns = columns
	
	if _grid_container == null:
		print("[VScrollGrid] ERROR: _grid_container is null! _ready() may not have been called yet.")
		return
	
	_grid_container.columns = grid_columns
	_total_items = total_items
	
	# Calculate buffer size (3x visible items)
	var viewport_height = _scroll_container.size.y if _scroll_container else 600
	var visible_rows = maxi(1, ceili(viewport_height / item_height))
	var visible_items = visible_rows * grid_columns
	_buffer_size = visible_items * buffer_page_count
	
	print("[VScrollGrid] Setup: total=%d, columns=%d, buffer_size=%d, viewport_height=%d" % [_total_items, grid_columns, _buffer_size, int(viewport_height)])
	
	_update_layout()
	_initial_load()

func set_total_count(count: int):
	_total_items = count
	print("[VScrollGrid] Total count: %d" % count)
	_update_layout()
	_refresh_buffer()

func _update_layout():
	if _grid_container == null:
		print("[VScrollGrid] ERROR: _grid_container is null in _update_layout")
		return
	
	# Set virtual height for scrolling
	var rows = ceili(float(_total_items) / grid_columns) if grid_columns > 0 else 0
	var total_height = rows * item_height
	_grid_container.custom_minimum_size.y = total_height
	print("[VScrollGrid] Layout: rows=%d, height=%d, _total_items=%d" % [rows, int(total_height), _total_items])

func _initial_load():
	print("[VScrollGrid] _initial_load called: _total_items=%d, _buffer_size=%d" % [_total_items, _buffer_size])
	_buffer_start = 0
	_visible_start = 0
	_visible_end = min(_buffer_size, _total_items)
	print("[VScrollGrid] Emitting items_requested: offset=0, limit=%d" % _buffer_size)
	items_requested.emit(0, _buffer_size)
	visible_range_changed.emit(_visible_start, _visible_end, _total_items)

func _on_scroll_changed(value: float):
	var delta = abs(value - _last_scroll_value)
	if delta < min_scroll_threshold:
		return
	
	_last_scroll_value = value
	_update_buffer_if_needed()

func _on_resized():
	# Recalculate buffer size based on new viewport
	if _scroll_container:
		var viewport_height = _scroll_container.size.y
		var visible_rows = maxi(1, ceili(viewport_height / item_height))
		var visible_items = visible_rows * grid_columns
		_buffer_size = visible_items * buffer_page_count
		print("[VScrollGrid] Resized: viewport_height=%d, visible_items=%d, buffer_size=%d" % [int(viewport_height), visible_items, _buffer_size])

func _update_buffer_if_needed():
	if _total_items == 0 or not _scroll_container:
		return
	
	var scroll_pos = _scroll_container.scroll_vertical
	var viewport_height = _scroll_container.size.y
	
	# Calculate current visible range
	var first_visible_row = int(scroll_pos / item_height)
	var visible_rows = ceili(viewport_height / item_height) + 1
	var new_visible_start = first_visible_row * grid_columns
	var new_visible_end = mini(new_visible_start + (visible_rows * grid_columns), _total_items)
	
	# Calculate ideal buffer position (centered on visible area)
	var visible_count = new_visible_end - new_visible_start
	var buffer_start_offset = int(visible_count * (buffer_page_count - 1) / 2.0)
	var new_buffer_start = maxi(0, new_visible_start - buffer_start_offset)
	new_buffer_start = mini(new_buffer_start, maxi(0, _total_items - _buffer_size))
	
	# Round to grid column boundary for clean scrolling
	new_buffer_start = (new_buffer_start / grid_columns) * grid_columns
	
	# Check if we need to shift the buffer
	if new_buffer_start == _buffer_start:
		# Just update visible range for status
		_visible_start = new_visible_start
		_visible_end = new_visible_end
		visible_range_changed.emit(_visible_start, _visible_end, _total_items)
		return
	
	print("[VScrollGrid] Shifting buffer: %d -> %d" % [_buffer_start, new_buffer_start])
	_shift_buffer(new_buffer_start)

func _shift_buffer(new_buffer_start: int):
	var old_buffer_start = _buffer_start
	var shift_amount = new_buffer_start - old_buffer_start
	
	if shift_amount == 0:
		return
	
	# Update _buffer_start BEFORE calculating what to add
	_buffer_start = new_buffer_start
	
	# Update spacer height to position cards correctly
	_update_spacer()
	
	if shift_amount > 0:
		# Scrolling down: remove from front, add to back
		_items_shift_down(shift_amount)
	else:
		# Scrolling up: remove from back, add to front
		_items_shift_up(-shift_amount)

func _update_spacer():
	"""Update spacer height to position visible cards at correct virtual position."""
	if _spacer:
		var rows_before = _buffer_start / grid_columns
		var spacer_height = rows_before * item_height
		_spacer.custom_minimum_size.y = spacer_height
		print("[VScrollGrid] Spacer updated: height=%d (rows_before=%d)" % [int(spacer_height), rows_before])
	
	# Update visible range
	var scroll_pos = _scroll_container.scroll_vertical
	var viewport_height = _scroll_container.size.y
	var first_visible_row = int(scroll_pos / item_height)
	var visible_rows = ceili(viewport_height / item_height) + 1
	_visible_start = first_visible_row * grid_columns
	_visible_end = mini(_visible_start + (visible_rows * grid_columns), _total_items)
	
	visible_range_changed.emit(_visible_start, _visible_end, _total_items)

func _items_shift_down(count: int):
	"""Remove 'count' cards from front, add 'count' new cards to back."""
	print("[VScrollGrid] Shift down: removing %d from front" % count)
	
	# Remove cards from front (skip spacer at index 0)
	var cards_in_grid = _grid_container.get_child_count() - 1  # Exclude spacer
	for i in range(min(count, cards_in_grid)):
		var card = _grid_container.get_child(1)  # Index 1, after spacer
		_grid_container.remove_child(card)
		card.queue_free()
	
	# Calculate what new cards to add
	# After removal, we have cards from _buffer_start to some end
	# We want to fill up to _buffer_start + _buffer_size
	var current_end = _buffer_start + (_grid_container.get_child_count() - 1)  # Exclude spacer
	var target_end = min(_buffer_start + _buffer_size, _total_items)
	var cards_to_add = target_end - current_end
	
	print("[VScrollGrid] Buffer now has %d cards, need %d more to reach %d" % [_grid_container.get_child_count() - 1, cards_to_add, target_end])
	
	if cards_to_add > 0:
		# Request items from database
		_is_updating = true
		items_requested.emit(current_end, cards_to_add)

func _items_shift_up(count: int):
	"""Remove 'count' cards from back, add 'count' new cards to front."""
	print("[VScrollGrid] Shift up: removing %d from back" % count)
	
	# Remove cards from back (never remove spacer at index 0)
	var cards_in_grid = _grid_container.get_child_count() - 1  # Exclude spacer
	for i in range(min(count, cards_in_grid)):
		var idx = _grid_container.get_child_count() - 1  # Last child
		var card = _grid_container.get_child(idx)
		_grid_container.remove_child(card)
		card.queue_free()
	
	# Calculate what new cards to add
	# We removed 'count' cards from back, need to add 'count' cards to front
	var cards_to_add = count
	var offset = _buffer_start
	
	print("[VScrollGrid] Buffer now has %d cards, adding %d at front starting from %d" % [_grid_container.get_child_count() - 1, cards_to_add, offset])
	
	if cards_to_add > 0:
		# Request items from database
		_is_updating = true
		items_requested.emit(offset, cards_to_add)

func on_items_loaded(items: Array[GameResource], offset: int):
	"""Callback when items are loaded from database."""
	print("[VScrollGrid] Items loaded: %d items at offset %d, _buffer_start=%d" % [items.size(), offset, _buffer_start])
	
	_is_updating = false
	
	# Determine if this is for front or back of buffer
	if offset < _buffer_start:
		# Adding to front (scrolling up)
		_add_items_to_front(items, offset)
	else:
		# Adding to back (scrolling down)
		_add_items_to_back(items, offset)
	
	print("[VScrollGrid] Buffer now has %d cards" % _grid_container.get_child_count())

func _add_items_to_front(items: Array[GameResource], offset: int):
	"""Add items to the front of the buffer (prepend)."""
	print("[VScrollGrid] Adding %d items to front at offset %d" % [items.size(), offset])
	for i in range(items.size() - 1, -1, -1):
		var game = items[i]
		var card = _card_scene.instantiate()
		card.game = game
		var virtual_index = offset + i
		card.set_meta("virtual_index", virtual_index)
		_grid_container.add_child(card)
		_grid_container.move_child(card, 1)  # Move after spacer at index 0
		item_created.emit(card, virtual_index)
		print("[VScrollGrid] Added card at virtual_index=%d to front" % virtual_index)

func _add_items_to_back(items: Array[GameResource], offset: int):
	"""Add items to the back of the buffer (append)."""
	print("[VScrollGrid] Adding %d items to back at offset %d" % [items.size(), offset])
	for i in range(items.size()):
		var game = items[i]
		var card = _card_scene.instantiate()
		card.game = game
		var virtual_index = offset + i
		card.set_meta("virtual_index", virtual_index)
		_grid_container.add_child(card)
		item_created.emit(card, virtual_index)
		print("[VScrollGrid] Added card at virtual_index=%d to back" % virtual_index)

func _refresh_buffer():
	"""Clear and reload the buffer."""
	print("[VScrollGrid] Refreshing buffer")
	
	# Clear existing cards (skip spacer at index 0)
	while _grid_container.get_child_count() > 1:
		var child = _grid_container.get_child(1)
		_grid_container.remove_child(child)
		child.queue_free()
	
	# Reset spacer
	_update_spacer()
	
	_buffer_start = 0
	_initial_load()

func get_visible_range() -> Dictionary:
	return {
		"start": _visible_start,
		"end": _visible_end,
		"total": _total_items,
		"buffer_start": _buffer_start,
		"buffer_size": _buffer_size
	}

func get_card_at_index(index: int) -> Control:
	for child in _grid_container.get_children():
		if child.get_meta("virtual_index", -1) == index:
			return child
	return null

func scroll_to_index(index: int):
	"""Scroll to make a specific index visible."""
	if _scroll_container:
		var row = index / grid_columns
		var target_y = row * item_height
		_scroll_container.scroll_vertical = target_y
