class_name VirtualGridContainer
extends GridContainer

signal virtual_item_created(item: Control, index: int)
signal virtual_item_recycled(item: Control, old_index: int, new_index: int)
signal virtual_item_destroyed(item: Control, index: int)
signal visible_range_changed(start_index: int, end_index: int, total_count: int)

# Configuration
@export var card_scene: PackedScene
@export var item_height: float = 200.0  # Approximate height of each row
@export var grid_columns: int = 5:
	set(value):
		grid_columns = value
		self.columns = value
		_update_layout()

# Buffer configuration (3 pages total: 1 visible + 1 above + 1 below)
@export var buffer_page_multiplier: float = 3.0
@export var min_scroll_threshold: float = 50.0  # Minimum scroll delta before updating (pixels)
@export var update_interval_ms: float = 16.67   # 60 FPS = ~16.67ms

# Internal state
var _scroll_container: ScrollContainer = null
var _total_items: int = 0
var _visible_start: int = 0
var _visible_end: int = 0
var _buffer_start: int = 0
var _buffer_end: int = 0
var _card_pool: Array[Control] = []
var _active_cards: Dictionary = {}  # virtual_index -> Control

# Performance tracking
var _last_scroll_value: float = 0.0
var _last_update_time: float = 0.0
var _is_updating: bool = false
var _items_data: Array[Dictionary] = []  # Lightweight data refs (id, title, etc.)
var _sort_field: String = "title"
var _sort_ascending: bool = true

# Async query state
var _pending_query: bool = false
var _query_callback: Callable = Callable()
var _db_offset: int = 0
var _db_limit: int = 0

func _ready():
	print("[VirtualGrid] _ready called")
	# Find parent ScrollContainer
	var parent = get_parent()
	while parent:
		if parent is ScrollContainer:
			_scroll_container = parent
			print("[VirtualGrid] Found ScrollContainer")
			break
		parent = parent.get_parent()
	
	if _scroll_container:
		# Only connect if not already connected
		var v_scroll = _scroll_container.get_v_scroll_bar()
		if not v_scroll.value_changed.is_connected(_on_scroll_changed):
			v_scroll.value_changed.connect(_on_scroll_changed)
		if not _scroll_container.resized.is_connected(_on_container_resized):
			_scroll_container.resized.connect(_on_container_resized)

func setup(scroll_container: ScrollContainer, card_scene_resource: PackedScene, total_count: int = 0):
	print("[VirtualGrid] setup called")
	_scroll_container = scroll_container
	card_scene = card_scene_resource
	_total_items = total_count
	
	print("[VirtualGrid] Scroll container: %s" % ("found" if _scroll_container else "null"))
	
	if _scroll_container:
		# Only connect if not already connected
		var v_scroll = _scroll_container.get_v_scroll_bar()
		if not v_scroll.value_changed.is_connected(_on_scroll_changed):
			v_scroll.value_changed.connect(_on_scroll_changed)
		if not _scroll_container.resized.is_connected(_on_container_resized):
			_scroll_container.resized.connect(_on_container_resized)
	
	_update_layout()
	_update_visible_range()

func set_total_count(count: int):
	print("[VirtualGrid] set_total_count: %d" % count)
	_total_items = count
	_update_layout()
	_update_visible_range()
	print("[VirtualGrid] Layout updated, min_height=%d" % int(custom_minimum_size.y))

func set_items_data(data: Array[Dictionary]):
	_items_data = data
	_total_items = data.size()
	_update_layout()
	_update_visible_range()

func sort_by(field: String, ascending: bool = true):
	_sort_field = field
	_sort_ascending = ascending
	# Mark for re-sort and refresh
	_refresh_all()

func _on_scroll_changed(value: float):
	var delta = abs(value - _last_scroll_value)
	print("[VirtualGrid] Scroll changed: value=%d, delta=%d" % [int(value), int(delta)])
	
	if delta < min_scroll_threshold:
		return
	
	_last_scroll_value = value
	_force_update()

func _on_container_resized():
	_update_layout()
	_update_visible_range()

func _update_layout():
	# Set GridContainer columns
	self.columns = grid_columns
	
	# Calculate virtual height based on total items
	var rows = ceili(float(_total_items) / grid_columns)
	var total_height = rows * item_height
	
	# Set custom minimum size to enable scrolling
	custom_minimum_size.y = total_height

func _update_visible_range():
	if _total_items == 0 or not _scroll_container:
		return
	
	# Calculate visible range based on scroll position
	var scroll_pos = _scroll_container.scroll_vertical
	var viewport_height = _scroll_container.size.y
	
	# Calculate row indices
	var first_visible_row = int(scroll_pos / item_height)
	var visible_rows = ceili(viewport_height / item_height) + 1  # +1 for partial row
	var last_visible_row = first_visible_row + visible_rows
	
	# Convert to item indices
	var new_visible_start = first_visible_row * grid_columns
	var new_visible_end = mini((last_visible_row + 1) * grid_columns, _total_items)
	
	# Calculate buffer range (3x visible area)
	var visible_count = new_visible_end - new_visible_start
	var buffer_count = int(visible_count * (buffer_page_multiplier - 1.0) / 2.0)
	
	var new_buffer_start = maxi(0, new_visible_start - buffer_count)
	var new_buffer_end = mini(_total_items, new_visible_end + buffer_count)
	
	# Check if update is needed (but always update if we have no active cards yet)
	if _active_cards.size() > 0 and new_buffer_start == _buffer_start and new_buffer_end == _buffer_end:
		return
	
	# Update ranges
	_buffer_start = new_buffer_start
	_buffer_end = new_buffer_end
	_visible_start = new_visible_start
	_visible_end = new_visible_end
	
	print("[VirtualGrid] Buffer range updated: visible=%d-%d, buffer=%d-%d" % [_visible_start, _visible_end, _buffer_start, _buffer_end])
	
	# Emit signal for status updates
	visible_range_changed.emit(_visible_start, _visible_end, _total_items)
	
	# Update cards asynchronously
	_schedule_update()

func _force_update():
	"""Force an update of the visible range, bypassing the buffer range check."""
	_update_visible_range()

func _schedule_update():
	if _is_updating:
		return
	
	_is_updating = true
	call_deferred("_perform_update")

func _perform_update():
	# Query database for items in buffer range
	_query_items(_buffer_start, _buffer_end - _buffer_start)

func _query_items(offset: int, limit: int):
	_pending_query = true
	_db_offset = offset
	_db_limit = limit
	
	print("[VirtualGrid] Querying items: offset=%d, limit=%d" % [offset, limit])
	
	# Query will be handled by the view using DataManager
	if _query_callback.is_valid():
		_query_callback.call(offset, limit)
	else:
		print("[VirtualGrid] ERROR: No query callback set!")
		_is_updating = false

func on_items_loaded(items: Array[GameResource], offset: int):
	_pending_query = false
	_is_updating = false
	
	print("[VirtualGrid] Items loaded: count=%d, offset=%d" % [items.size(), offset])
	
	# Update card pool with new data
	_update_cards(items, offset)

func _update_cards(items: Array[GameResource], offset: int):
	print("[VirtualGrid] Updating cards: items=%d, offset=%d, active_cards=%d, buffer=%d-%d" % [items.size(), offset, _active_cards.size(), _buffer_start, _buffer_end])
	
	# Process items from the data
	# Only add cards that will be in the current buffer
	print("[VirtualGrid] Processing %d items from offset %d" % [items.size(), offset])
	var added_count = 0
	var updated_count = 0
	var skipped_count = 0
	
	for i in range(items.size()):
		var virtual_index = offset + i
		var game = items[i]
		
		# Skip cards that are outside the current buffer (will be removed anyway)
		if virtual_index < _buffer_start or virtual_index >= _buffer_end:
			skipped_count += 1
			continue
		
		if _active_cards.has(virtual_index):
			# Update existing card
			var card = _active_cards[virtual_index]
			card.game = game
			updated_count += 1
		else:
			# Create or recycle card
			_add_card(game, virtual_index)
			added_count += 1
	
	# Remove cards that are out of buffer range
	var indices_to_remove = []
	for index in _active_cards.keys():
		if index < _buffer_start or index >= _buffer_end:
			indices_to_remove.append(index)
	
	print("[VirtualGrid] Removing %d cards out of buffer range: %s" % [indices_to_remove.size(), indices_to_remove])
	
	for index in indices_to_remove:
		var card = _active_cards[index]
		_remove_card(card, index)
	
	print("[VirtualGrid] Cards updated: %d updated, %d added, %d skipped (out of buffer), %d removed, now %d active cards" % [updated_count, added_count, skipped_count, indices_to_remove.size(), _active_cards.size()])

func _add_card(game: GameResource, virtual_index: int):
	var card: Control
	
	# Try to recycle from pool
	if _card_pool.size() > 0:
		card = _card_pool.pop_back()
		virtual_item_recycled.emit(card, -1, virtual_index)
		print("[VirtualGrid] Recycling card from pool for index %d" % virtual_index)
	else:
		# Create new card
		if not card_scene:
			print("[VirtualGrid] ERROR: No card_scene set!")
			return
		card = card_scene.instantiate()
		virtual_item_created.emit(card, virtual_index)
		print("[VirtualGrid] Created new card for index %d" % virtual_index)
	
	# Safety check - ensure card has no parent
	if card.get_parent():
		print("[VirtualGrid] WARNING: Card still has parent, removing...")
		card.get_parent().remove_child(card)
	
	# Setup card
	if card.has_method("set"):
		card.set("game", game)
	else:
		card.game = game
	
	# Add to grid at correct position
	_insert_card_at_index(card, virtual_index)
	
	_active_cards[virtual_index] = card
	print("[VirtualGrid] Added card at virtual_index=%d, active_cards=%d" % [virtual_index, _active_cards.size()])

func _insert_card_at_index(card: Control, virtual_index: int):
	# Find the correct position in the GridContainer based on virtual index
	var target_child_index = _get_child_index_for_virtual_index(virtual_index)
	
	if target_child_index >= get_child_count():
		add_child(card)
	else:
		add_child(card)
		move_child(card, target_child_index)

func _get_child_index_for_virtual_index(virtual_index: int) -> int:
	# Map virtual index to child index based on current buffer
	# This ensures cards maintain proper order in the GridContainer
	var sorted_indices = _active_cards.keys()
	sorted_indices.sort()
	
	var child_index = 0
	for idx in sorted_indices:
		if idx < virtual_index:
			child_index += 1
		else:
			break
	
	return child_index

func _remove_card(card: Control, virtual_index: int):
	_active_cards.erase(virtual_index)
	
	# Don't destroy, add to pool for recycling
	card.get_parent().remove_child(card)
	_card_pool.append(card)
	virtual_item_destroyed.emit(card, virtual_index)

func _refresh_all():
	# Clear all cards and refresh
	for index in _active_cards.keys():
		var card = _active_cards[index]
		card.get_parent().remove_child(card)
		_card_pool.append(card)
	
	_active_cards.clear()
	_update_visible_range()

func get_visible_range() -> Dictionary:
	return {
		"start": _visible_start,
		"end": _visible_end,
		"total": _total_items,
		"buffer_start": _buffer_start,
		"buffer_end": _buffer_end
	}

func get_card_at_index(index: int) -> Control:
	return _active_cards.get(index, null)

func set_query_callback(callback: Callable):
	_query_callback = callback

func clear():
	for index in _active_cards.keys():
		var card = _active_cards[index]
		card.queue_free()
	_active_cards.clear()
	
	for card in _card_pool:
		card.queue_free()
	_card_pool.clear()
	
	_total_items = 0
	_items_data.clear()
