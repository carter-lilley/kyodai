class_name VirtualScrollGridContainer
extends Control

signal items_requested(offset, limit)
signal visible_range_changed(start, end, total)
signal item_created(item, index)
signal batch_progress_changed(progress: float)

@export var card_scene: PackedScene
@export var data_buffer_multiplier: int = 5
@export var data_preload_multiplier: int = 3
@export var visual_buffer_lines: int = 4
@export var debug_mode: bool = false:
	set(value):
		if debug_mode != value:
			debug_mode = value
			_update_debug_mode()
@export var vertical: bool = true:
	set(value):
		if vertical != value:
			vertical = value
			if _flow_container:
				_flow_container.vertical = not vertical
			if _scroll_container:
				_scroll_container.vertical = vertical
			_recalculate_layout()
			_refresh_buffer()

const BASE_CARD_WIDTH: float = 202.0
const BASE_CARD_HEIGHT: float = 270.0

# Grid separation (padding) - loaded from settings, defaults to 10
var grid_separation: int = 10

# Target card width as ratio of viewport (e.g., 0.15 = 15% of viewport width)
var target_card_width_ratio: float = 0.15:
	set(value):
		var clamped = clampf(value, 0.05, 0.5)
		if not is_equal_approx(target_card_width_ratio, clamped):
			target_card_width_ratio = clamped
			_recalculate_layout()

# Computed zoom based on viewport size
var zoom: float = 1.0:
	get:
		return _calculate_zoom()
	set(value):
		push_warning("VirtualScrollGridContainer: Cannot set zoom directly. Set target_card_width_ratio instead.")

var item_height: float = 280.0
var item_width: float = 212.0

var _scroll_container: SmoothScrollContainer
var _margin_container: MarginContainer
var _center_container: CenterContainer
var _flow_container: FlowContainer
var _debug_camera: Camera2D
var _debug_flow_panel: Panel

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

const MAX_CACHE_SIZE: int = 5000
var _cache_access_order: Array[int] = []

func _ready():
	_setup_ui()
	resized.connect(_on_resized)
	# Load initial grid separation from settings
	# Use call_deferred to ensure SettingsManager is fully initialized
	call_deferred("_update_grid_separation_from_settings")
	call_deferred("_recalculate_layout")

func _on_resized():
	_recalculate_layout()
	# If we have items but no active cards (e.g., view was hidden during setup), load them now
	if _active_cards.size() == 0 and _total_items > 0 and size.x > 0 and size.y > 0:
		_initial_load()

func _update_grid_separation_from_settings() -> void:
	if not SettingsManager:
		return
	var setting = SettingsManager.get_setting("library_grid_padding")
	if setting and (setting.value is int or setting.value is float):
		grid_separation = int(setting.value)
	else:
		grid_separation = 10
	
	# Apply to FlowContainer if it exists
	if _flow_container:
		_flow_container.add_theme_constant_override("h_separation", grid_separation)
		_flow_container.add_theme_constant_override("v_separation", grid_separation)

func _calculate_zoom() -> float:
	var base_dims = _get_base_dimensions()
	var base_area = base_dims.x * base_dims.y
	var viewport_area = size.x * size.y
	
	# target_card_width_ratio represents "fraction of viewport area occupied by one card"
	# For example, 0.15 = card takes up ~2.25% of viewport area (0.15^2)
	var target_card_area = viewport_area * target_card_width_ratio * target_card_width_ratio
	
	# Solve: (base_width * zoom) * (base_height * zoom) = target_card_area
	# zoom^2 = target_card_area / base_area
	return sqrt(target_card_area / base_area)

func _recalculate_layout():
	if not _flow_container or not _scroll_container:
		return
	
	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions()
	item_width = (base_dims.x * current_zoom) + grid_separation
	item_height = (base_dims.y * current_zoom) + grid_separation
	
	# Guard against zero or negative item dimensions
	if item_width <= 0 or item_height <= 0:
		item_width = max(item_width, base_dims.x * 0.1 + grid_separation)
		item_height = max(item_height, base_dims.y * 0.1 + grid_separation)
	
	# Ensure FlowContainer separation is up to date
	_flow_container.add_theme_constant_override("h_separation", grid_separation)
	_flow_container.add_theme_constant_override("v_separation", grid_separation)
	_flow_container.queue_sort()
	
	_update_layout()
	_update_margin()
	if _scroll_container:
		if vertical:
			_on_scroll_value_changed(_scroll_container.scroll_vertical)
		else:
			_on_scroll_value_changed(_scroll_container.scroll_horizontal)
	
	# Update zoom on all active cards
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(current_zoom)

func _get_items_per_line() -> int:
	if not _scroll_container:
		return 1
	
	var result: int
	if vertical:
		result = max(1, int(size.x / item_width))
	else:
		result = max(1, int(size.y / item_height))
	return result

func _get_visible_count() -> int:
	var items_per_line = _get_items_per_line()
	if vertical:
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		return (visible_rows * items_per_line)+1
	else:
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		return (visible_cols * items_per_line)+1

func _setup_ui():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_scroll_container = SmoothScrollContainer.new()
	_scroll_container.vertical = vertical
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
	
	_center_container = CenterContainer.new()
	if vertical:
		_center_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_center_container.size_flags_vertical = Control.SIZE_FILL
	else:
		_center_container.size_flags_horizontal = Control.SIZE_FILL
		_center_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_margin_container.add_child(_center_container)
	
	_flow_container = FlowContainer.new()
	_flow_container.vertical = not vertical
	# FlowContainer shrinks to fit its content (active cards only)
	_flow_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_flow_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_flow_container.add_theme_constant_override("h_separation", grid_separation)
	_flow_container.add_theme_constant_override("v_separation", grid_separation)
	_center_container.add_child(_flow_container)
	
	if debug_mode:
		_setup_debug_camera()
		_scroll_container.clip_contents = false
	else:
		_scroll_container.clip_contents = true
	
	_recalculate_dimensions()

func _get_base_dimensions() -> Vector2:
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			var orientation_idx = config_setting.value.get("card_orientation", 0)
			match orientation_idx:
				1: # Horizontal
					return Vector2(270.0, 202.0)
				2: # Square
					return Vector2(256.0, 256.0)
				_: # 0 = Vertical (default)
					return Vector2(202.0, 270.0)
	return Vector2(202.0, 270.0)

func _recalculate_dimensions():
	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions()
	item_width = (base_dims.x * current_zoom) + grid_separation
	item_height = (base_dims.y * current_zoom) + grid_separation

func refresh_dimensions() -> void:
	"""Recalculate dimensions and refresh layout (call after orientation change)."""
	# Update grid separation from settings
	_update_grid_separation_from_settings()
	
	# Reset FlowContainer's custom_minimum_size to force recalculation with current viewport size
	# This fixes issues where layout was calculated while view was hidden (size=0)
	if _flow_container:
		_flow_container.custom_minimum_size = Vector2(0, 0)
	
	var current_zoom = _calculate_zoom()
	_recalculate_dimensions()
	_recalculate_layout()
	
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(current_zoom)
	
	_update_margin()

func _on_zoom_changed():
	var current_zoom = _calculate_zoom()
	_recalculate_dimensions()
	_recalculate_layout()
	
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(current_zoom)
	
	_update_margin()

func setup(card_scene_resource: PackedScene, total_items: int):
	_card_scene = card_scene_resource
	_total_items = total_items
	
	_instantiate_card_pool()
	
	# Wait for container sizing before initial load
	await get_tree().process_frame
	await get_tree().process_frame
	_recalculate_layout()
	if _active_cards.size() == 0:
		_initial_load()

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
	
	if vertical:
		var card_width = item_width - grid_separation
		var row_width = items_per_line * card_width + max(0, items_per_line - 1) * grid_separation
		_flow_container.custom_minimum_size.x = row_width
	else:
		var card_height = item_height - grid_separation
		var col_height = items_per_line * card_height + max(0, items_per_line - 1) * grid_separation
		_flow_container.custom_minimum_size.y = col_height

func _initial_load():
	# Guard against invalid size - don't load cards when view is not ready
	# The resized signal will trigger recalculation when view becomes visible
	if size.x <= 0 or size.y <= 0:
		return
	
	# Guard against invalid item dimensions (would happen if zoom calculation failed)
	if item_width <= 0 or item_height <= 0:
		var base_dims = _get_base_dimensions()
		item_width = max(item_width, base_dims.x * 0.1 + grid_separation)
		item_height = max(item_height, base_dims.y * 0.1 + grid_separation)
	
	var items_per_line = _get_items_per_line()
	var visible_count: int
	if vertical:
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		visible_count = visible_rows * items_per_line
	else:
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		visible_count = visible_cols * items_per_line
	
	var total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
	# Cap card count to pool size to prevent creating too many cards
	var card_count = min(total_card_count, _total_items, _max_pool_size)
	
	print("[VirtualScrollGridContainer] _initial_load: total_items=%d, card_count=%d" % [_total_items, card_count])
	
	_virtual_start = 0
	_virtual_end = card_count - 1
	
	for i in range(card_count):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			_active_cards.append(card)
			_flow_container.add_child(card)
			if card.has_method("refresh_settings"):
				card.refresh_settings()
			item_created.emit(card, i)
	
	# Apply current zoom to all newly created cards
	var current_zoom = _calculate_zoom()
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(current_zoom)
	
	_update_margin()
	_request_data(0, card_count)

func _on_scroll_value_changed(value: float):
	if _total_items == 0 or not _scroll_container:
		return
	
	var scroll_pos = int(value)
	var items_per_line = _get_items_per_line()
	
	var visible_start_idx: int
	var visible_end_idx: int
	var target_start: int
	var target_end: int
	var total_card_count: int
	
	if vertical:
		var viewport_height = size.y
		var top_row = int(scroll_pos / item_height)
		var visible_rows = ceili(viewport_height / item_height)
		visible_start_idx = top_row * items_per_line
		visible_end_idx = min(visible_start_idx + (visible_rows) * items_per_line, _total_items)-1
		
		var visible_count = _get_visible_count()
		total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
		
		var half_buffer = (total_card_count - visible_count) / 2
		target_start = max(0, visible_start_idx - half_buffer)
		target_end = min(_total_items, target_start + total_card_count)
		
		if target_end == _total_items:
			target_start = max(0, _total_items - total_card_count)
	else:
		var viewport_width = size.x
		var left_col = int(scroll_pos / item_width)
		var visible_cols = ceili(viewport_width / item_width)
		visible_start_idx = left_col * items_per_line
		visible_end_idx = min(visible_start_idx + (visible_cols) * items_per_line, _total_items)-1
		
		var visible_count = _get_visible_count()
		total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
		
		var half_buffer = (total_card_count - visible_count) / 2
		target_start = max(0, visible_start_idx - half_buffer)
		target_end = min(_total_items, target_start + total_card_count)
		
		if target_end == _total_items:
			target_start = max(0, _total_items - total_card_count)
	
	var changes_made = false
	var recycled_top = 0
	var recycled_bottom = 0
	
	var buffer_overlaps = false
	if _active_cards.size() > 0:
		var current_first = _active_cards[0].get_meta("virtual_index", 0)
		var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		
		buffer_overlaps = (current_first < target_end) and (current_last >= target_start)
		
		if not buffer_overlaps:
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
			
			if last_idx >= target_end:
				_recycle_card_at_index(_active_cards.size() - 1)
				recycled_bottom += 1
				changes_made = true
			else:
				break
		
		if _active_cards.size() > 0:
			var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			while current_last < target_end - 1 and current_last < _total_items - 1:
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
	_update_card_priorities(visible_start_idx, visible_end_idx)
	
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
		
		if card.has_method("reset"):
			card.reset()
		elif "game" in card:
			card.game = null
		
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
	
	# Ensure card has correct zoom immediately
	if card.has_method("set_card_zoom"):
		card.set_card_zoom(_calculate_zoom())
	
	if card.has_method("refresh_settings"):
		card.refresh_settings()
	
	if _data_cache.has(virtual_index):
		var is_visible = _is_index_visible(virtual_index)
		if card.has_method("set_game_with_priority"):
			card.set_game_with_priority(_data_cache[virtual_index], is_visible)
		else:
			card.game = _data_cache[virtual_index]
		_update_cache_access_order(virtual_index)
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
	
	# Ensure card has correct zoom immediately
	if card.has_method("set_card_zoom"):
		card.set_card_zoom(_calculate_zoom())
	
	if card.has_method("refresh_settings"):
		card.refresh_settings()
	
	if _data_cache.has(virtual_index):
		var is_visible = _is_index_visible(virtual_index)
		if card.has_method("set_game_with_priority"):
			card.set_game_with_priority(_data_cache[virtual_index], is_visible)
		else:
			card.game = _data_cache[virtual_index]
		_update_cache_access_order(virtual_index)
	else:
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
	
	item_created.emit(card, virtual_index)

func _is_index_visible(idx: int) -> bool:
	var items_per_line = _get_items_per_line()
	var visible_start_idx: int
	var visible_end_idx: int
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		visible_start_idx = int(scroll_pos / item_height) * items_per_line
		visible_end_idx = min(visible_start_idx + visible_rows * items_per_line, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		visible_start_idx = int(scroll_pos / item_width) * items_per_line
		visible_end_idx = min(visible_start_idx + visible_cols * items_per_line, _total_items)
	
	return idx >= visible_start_idx and idx < visible_end_idx

func _acquire_card() -> Control:
	while _card_pool.size() > 0:
		var card = _card_pool.pop_back()
		if is_instance_valid(card):
			card.set_meta("pooled", false)
			card.visible = true
			if card.has_method("reset"):
				card.reset()
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
			_margin_container.add_theme_constant_override("margin_bottom", 0)
			_flow_container.custom_minimum_size.y = 0
		else:
			_margin_container.add_theme_constant_override("margin_left", 0)
			_margin_container.add_theme_constant_override("margin_right", 0)
			_flow_container.custom_minimum_size.x = 0
		return
	
	var first_idx = _active_cards[0].get_meta("virtual_index", 0)
	var last_idx = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	var items_per_line = _get_items_per_line()
	
	if vertical:
		var card_height = item_height - grid_separation
		
		# Calculate virtual space before first card
		var lines_before = first_idx / items_per_line
		var margin_top = lines_before * card_height + max(0, lines_before - 1) * grid_separation
		
		# Calculate space for active cards
		var active_lines = ceili(float(_active_cards.size()) / items_per_line)
		var flow_height = active_lines * card_height + max(0, active_lines - 1) * grid_separation
		
		# Calculate virtual space after last card
		var lines_after = ceili(float(_total_items - last_idx - 1) / items_per_line) if items_per_line > 0 else 0
		var margin_bottom = lines_after * card_height + max(0, lines_after - 1) * grid_separation
		
		_margin_container.add_theme_constant_override("margin_top", int(margin_top))
		_margin_container.add_theme_constant_override("margin_bottom", int(margin_bottom))
		_flow_container.custom_minimum_size.y = flow_height
		
		if debug_mode:
			print("[VScrollGrid] _update_margin: margin_top=%d, flow_height=%d, margin_bottom=%d, total=%d" % [margin_top, flow_height, margin_bottom, margin_top + flow_height + margin_bottom])
	else:
		var card_width = item_width - grid_separation
		
		# Calculate virtual space before first card
		var lines_before = first_idx / items_per_line
		var margin_left = lines_before * card_width + max(0, lines_before - 1) * grid_separation
		
		# Calculate space for active cards
		var active_lines = ceili(float(_active_cards.size()) / items_per_line)
		var flow_width = active_lines * card_width + max(0, active_lines - 1) * grid_separation
		
		# Calculate virtual space after last card
		var lines_after = ceili(float(_total_items - last_idx - 1) / items_per_line) if items_per_line > 0 else 0
		var margin_right = lines_after * card_width + max(0, lines_after - 1) * grid_separation
		
		_margin_container.add_theme_constant_override("margin_left", int(margin_left))
		_margin_container.add_theme_constant_override("margin_right", int(margin_right))
		_flow_container.custom_minimum_size.x = flow_width

func _request_missing_data():
	if _active_cards.size() == 0:
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
	var visible_count = _get_visible_count()
	var preload_distance = visible_count * data_preload_multiplier
	var buffer_size = visible_count * data_buffer_multiplier
	
	if _virtual_end < _total_items - 1:
		var distance_to_end = _total_items - 1 - _virtual_end
		if distance_to_end > 0 and distance_to_end <= preload_distance:
			var next_batch_start = _virtual_end + 1
			if not _pending_loads.has(next_batch_start) and not _data_cache.has(next_batch_start):
				_request_data(next_batch_start, min(buffer_size, _total_items - next_batch_start))
	
	if _virtual_start > 0:
		var distance_to_start = _virtual_start
		if distance_to_start > 0 and distance_to_start <= preload_distance:
			var prev_batch_start = max(0, _virtual_start - buffer_size)
			if not _pending_loads.has(prev_batch_start) and not _data_cache.has(prev_batch_start):
				_request_data(prev_batch_start, min(buffer_size, _virtual_start - prev_batch_start))

func _update_card_priorities(visible_start_idx: int, visible_end_idx: int):
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx < 0:
			continue
		
		var is_visible = idx >= visible_start_idx and idx < visible_end_idx
		
		if card.has_method("set_image_priority"):
			card.set_image_priority(is_visible)

func _request_data(offset: int, limit: int):
	if limit <= 0 or offset < 0 or offset >= _total_items:
		return
	
	limit = min(limit, _total_items - offset)
	_pending_loads[offset] = true
	
	items_requested.emit(offset, limit)

func on_items_loaded(items: Array[GameResource], offset: int, _is_preload: bool = false):
	print("[VirtualScrollGridContainer] on_items_loaded called: items=%d, offset=%d" % [items.size(), offset])
	_pending_loads.erase(offset)
	
	if items.is_empty():
		print("[VirtualScrollGridContainer] on_items_loaded: items is empty, returning")
		return
	
	for i in range(items.size()):
		var cache_key = offset + i
		
		if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
			_evict_oldest_cache_entries(items.size())
		
		_data_cache[cache_key] = items[i]
		_update_cache_access_order(cache_key)
	
	var items_per_line = _get_items_per_line()
	var visible_start_idx: int
	var visible_end_idx: int
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		visible_start_idx = int(scroll_pos / item_height) * items_per_line
		visible_end_idx = min(visible_start_idx + visible_rows * items_per_line, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		visible_start_idx = int(scroll_pos / item_width) * items_per_line
		visible_end_idx = min(visible_start_idx + visible_cols * items_per_line, _total_items)
	
	var updated_count = 0
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= offset and idx < offset + items.size():
			var data_idx = idx - offset
			if data_idx < items.size():
				var is_visible = idx >= visible_start_idx and idx < visible_end_idx
				if card.has_method("set_game_with_priority"):
					card.set_game_with_priority(items[data_idx], is_visible)
				else:
					card.game = items[data_idx]
				_update_cache_access_order(idx)
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				updated_count += 1
	
	_update_card_priorities(visible_start_idx, visible_end_idx)

func _refresh_buffer():
	print("[VirtualScrollGridContainer] _refresh_buffer called, total_items=%d" % _total_items)
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	_data_cache.clear()
	_cache_access_order.clear()
	_pending_loads.clear()
	_margin_container.add_theme_constant_override("margin_top", 0)
	_margin_container.add_theme_constant_override("margin_bottom", 0)
	_margin_container.add_theme_constant_override("margin_left", 0)
	_margin_container.add_theme_constant_override("margin_right", 0)
	_flow_container.custom_minimum_size = Vector2(0, 0)
	_virtual_start = 0
	_virtual_end = 0
	print("[VirtualScrollGridContainer] Calling _initial_load from _refresh_buffer")
	_initial_load()

func _reload_buffer_around_target(visible_start: int, visible_end: int):
	var items_per_line = _get_items_per_line()
	var visible_count = visible_end - visible_start
	var total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
	
	var half_buffer = (total_card_count - visible_count) / 2
	var new_start = max(0, visible_start - half_buffer)
	var new_end = min(_total_items, new_start + total_card_count)
	
	if new_end == _total_items:
		new_start = max(0, _total_items - total_card_count)
	
	new_start = (new_start / items_per_line) * items_per_line
	
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	for i in range(new_start, new_end):
		_add_card_at_end(i)
	
	_virtual_start = new_start
	_virtual_end = new_end - 1
	_update_margin()
	
	_request_data(new_start, new_end - new_start)

func get_target_scroll() -> float:
	return _scroll_container.get_target_scroll() if _scroll_container else 0.0

func get_visible_range() -> Dictionary:
	var items_per_line = _get_items_per_line()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		var visible_start = int(scroll_pos / item_height) * items_per_line
		var visible_end = min(visible_start + (visible_rows * items_per_line), _total_items)
		
		return {
			"start": visible_start,
			"end": visible_end,
			"total": _total_items,
			"buffer_start": _virtual_start,
			"buffer_size": _active_cards.size(),
			"active_cards_count": _active_cards.size()
		}
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		var visible_start = int(scroll_pos / item_width) * items_per_line
		var visible_end = min(visible_start + (visible_cols * items_per_line), _total_items)
		
		return {
			"start": visible_start,
			"end": visible_end,
			"total": _total_items,
			"buffer_start": _virtual_start,
			"buffer_size": _active_cards.size(),
			"active_cards_count": _active_cards.size()
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
	
	_update_debug_flow_panel_position()

func _update_debug_mode():
	if not is_inside_tree():
		return
	
	print("[VScrollGrid] Debug mode: %s, scroll_pos=%d, virtual_start=%d, active_cards=%d" % [debug_mode, _scroll_container.scroll_vertical if _scroll_container else 0, _virtual_start, _active_cards.size()])
	
	if debug_mode:
		_scroll_container.clip_contents = false
		_setup_debug_camera()
		_setup_debug_flow_panel()
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
		if _debug_flow_panel:
			_debug_flow_panel.queue_free()
			_debug_flow_panel = null
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

func _setup_debug_flow_panel():
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
	_margin_container.add_child(_debug_flow_panel)
	_update_debug_flow_panel_position()

func _update_debug_flow_panel_position():
	if not _debug_flow_panel or not _flow_container:
		return
	var flow_pos = _flow_container.global_position
	var parent_pos = _margin_container.global_position
	_debug_flow_panel.position = flow_pos - parent_pos
	_debug_flow_panel.size = _flow_container.size

func increment_total_count(amount: int = 1) -> int:
	if amount <= 0:
		return _total_items
	
	var start_index = _total_items
	_total_items += amount
	
	_update_layout()
	
	if start_index == 0 and _active_cards.size() == 0 and _total_items > 0:
		_initial_load_from_increment()
		return start_index
	
	var items_per_line = _get_items_per_line()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / item_height)
		var visible_start = int(scroll_pos / item_height) * items_per_line
		var visible_end = min(visible_start + (visible_rows * items_per_line), _total_items)
		
		visible_range_changed.emit(visible_start, visible_end, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / item_width)
		var visible_start = int(scroll_pos / item_width) * items_per_line
		var visible_end = min(visible_start + (visible_cols * items_per_line), _total_items)
		
		visible_range_changed.emit(visible_start, visible_end, _total_items)
	
	return start_index

func _initial_load_from_increment():
	# Guard against invalid item dimensions (would happen if zoom calculation failed)
	if item_width <= 0 or item_height <= 0:
		var base_dims = _get_base_dimensions()
		item_width = max(item_width, base_dims.x * 0.1 + grid_separation)
		item_height = max(item_height, base_dims.y * 0.1 + grid_separation)
	
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
	
	var total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
	# Cap card count to pool size to prevent creating too many cards
	var card_count = min(total_card_count, _total_items, _max_pool_size)
	
	_virtual_start = 0
	_virtual_end = card_count - 1
	
	for i in range(card_count):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			_active_cards.append(card)
			_flow_container.add_child(card)
			
			if _data_cache.has(i):
				var is_visible = i < visible_count
				if card.has_method("set_game_with_priority"):
					card.set_game_with_priority(_data_cache[i], is_visible)
				else:
					card.game = _data_cache[i]
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()
			elif card.has_method("set_placeholder"):
				card.set_placeholder(true)
			
			item_created.emit(card, i)
	
	# Apply current zoom to all newly created cards
	var current_zoom = _calculate_zoom()
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("set_card_zoom"):
			card.set_card_zoom(current_zoom)
	
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
		var items_per_line = _get_items_per_line()
		var visible_start_idx: int
		var visible_end_idx: int
		
		if vertical:
			var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
			var viewport_height = size.y
			var visible_rows = ceili(viewport_height / item_height)
			visible_start_idx = int(scroll_pos / item_height) * items_per_line
			visible_end_idx = min(visible_start_idx + visible_rows * items_per_line, _total_items)
		else:
			var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
			var viewport_width = size.x
			var visible_cols = ceili(viewport_width / item_width)
			visible_start_idx = int(scroll_pos / item_width) * items_per_line
			visible_end_idx = min(visible_start_idx + visible_cols * items_per_line, _total_items)
		
		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx >= offset and idx < offset + items.size():
				if _data_cache.has(idx):
					var is_visible = idx >= visible_start_idx and idx < visible_end_idx
					if card.has_method("set_game_with_priority"):
						card.set_game_with_priority(_data_cache[idx], is_visible)
					else:
						card.game = _data_cache[idx]
					_update_cache_access_order(idx)
					if card.has_method("set_placeholder"):
						card.set_placeholder(false)
					if card.has_method("update_display"):
						card.update_display()

func refresh_if_visible(start_index: int, end_index: int):
	if _active_cards.size() == 0:
		return
	
	var current_first = _active_cards[0].get_meta("virtual_index", 0)
	var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	
	var overlap_start = max(start_index, current_first)
	var overlap_end = min(end_index, current_last)
	
	if overlap_start <= overlap_end:
		var items_per_line = _get_items_per_line()
		var visible_start_idx: int
		var visible_end_idx: int
		
		if vertical:
			var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
			var viewport_height = size.y
			var visible_rows = ceili(viewport_height / item_height)
			visible_start_idx = int(scroll_pos / item_height) * items_per_line
			visible_end_idx = min(visible_start_idx + visible_rows * items_per_line, _total_items)
		else:
			var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
			var viewport_width = size.x
			var visible_cols = ceili(viewport_width / item_width)
			visible_start_idx = int(scroll_pos / item_width) * items_per_line
			visible_end_idx = min(visible_start_idx + visible_cols * items_per_line, _total_items)
		
		var updated_count = 0
		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx >= overlap_start and idx <= overlap_end and _data_cache.has(idx):
				var is_visible = idx >= visible_start_idx and idx < visible_end_idx
				if card.has_method("set_game_with_priority"):
					card.set_game_with_priority(_data_cache[idx], is_visible)
				else:
					card.game = _data_cache[idx]
				_update_cache_access_order(idx)
				if card.has_method("set_placeholder"):
					card.set_placeholder(false)
				if card.has_method("update_display"):
					card.update_display()
				updated_count += 1

func refresh_all_card_effects() -> void:
	"""Refresh effects on all active cards (call when card settings change)."""
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("refresh_settings"):
			card.refresh_settings()

func _update_cache_access_order(cache_key: int):
	var idx = _cache_access_order.find(cache_key)
	if idx != -1:
		_cache_access_order.remove_at(idx)
	_cache_access_order.append(cache_key)

func _evict_oldest_cache_entries(count: int):
	var to_evict = mini(count, _cache_access_order.size())
	if to_evict <= 0:
		return
	
	for i in range(to_evict):
		var oldest_key = _cache_access_order.pop_front()
		if _data_cache.has(oldest_key):
			_data_cache.erase(oldest_key)
