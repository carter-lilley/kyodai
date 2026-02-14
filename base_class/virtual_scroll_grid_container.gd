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
	
	_update_layout()
	_initial_load()

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
	_last_scroll_value = value
	_scroll_debounce_timer.stop()
	_scroll_debounce_timer.start(debounce_time)

func _on_scroll_stopped():
	"""Validate and correct position when scroll stops."""
	if _total_items == 0 or not _scroll_container:
		return
	
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
	"""Set buffer to new position - clear old cards, load new ones."""
	if _is_loading:
		# Queue this update for after current load completes
		call_deferred("_set_buffer_position", new_start)
		return
	
	_buffer_start = new_start
	_update_spacer()
	
	# Clear all real cards (keep spacer)
	while _grid_container.get_child_count() > 1:
		var child = _grid_container.get_child(1)
		_grid_container.remove_child(child)
		child.queue_free()
	
	# Load new cards
	var limit = min(buffer_size, _total_items - _buffer_start)
	if limit > 0:
		_is_loading = true
		items_requested.emit(_buffer_start, limit)

func on_items_loaded(items: Array[GameResource], offset: int):
	"""Callback when items are loaded from database."""
	print("[VScrollGrid] Items loaded: %d items at offset %d" % [items.size(), offset])
	_is_loading = false
	
	# Only accept data if it matches our current buffer position
	if offset != _buffer_start:
		print("[VScrollGrid] Stale data (offset %d != buffer %d), discarding" % [offset, _buffer_start])
		return
	
	# Add cards
	for i in range(items.size()):
		var game = items[i]
		var card = _card_scene.instantiate()
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
		child.queue_free()
	
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
