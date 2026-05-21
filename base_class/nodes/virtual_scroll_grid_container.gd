class_name VirtualScrollGridContainer
extends Control

signal items_requested(offset, limit)
signal visible_range_changed(start, end, total)
signal item_created(item, index)

@export var card_scene: PackedScene
@export var data_buffer_multiplier: int = 5
@export var data_preload_multiplier: int = 3
@export var visual_buffer_lines: int = 4
@export var debug_mode: bool = false:
	set(value):
		if debug_mode != value:
			debug_mode = value
			_update_debug_mode()
enum ViewMode { GRID, LIST, CAROUSEL }

@export var view_mode: ViewMode = ViewMode.GRID:
	set(value):
		if view_mode != value:
			var old_focused = _focused_virtual_index
			view_mode = value
			_update_view_mode()
			if old_focused >= 0:
				call_deferred("scroll_to_index", old_focused, false)

# Grid orientation toggle. Only affects GRID mode; LIST is always vertical, CAROUSEL always horizontal.
var grid_vertical: bool = true:
	set(value):
		if value == grid_vertical:
			return
		var old_focused = _focused_virtual_index
		grid_vertical = value
		if _ready_called and view_mode == ViewMode.GRID:
			_update_view_mode()
			refresh_dimensions()
			queue_redraw()
			if old_focused >= 0:
				call_deferred("scroll_to_index", old_focused, false)

# Computed scroll axis: GRID respects grid_vertical; LIST is vertical; CAROUSEL is horizontal.
var vertical: bool:
	get:
		match view_mode:
			ViewMode.GRID:
				return grid_vertical
			ViewMode.LIST:
				return true
			ViewMode.CAROUSEL:
				return false
		return true

const BASE_CARD_WIDTH_DP: float = 202.0
const BASE_CARD_HEIGHT_DP: float = 270.0
const BASE_LIST_HEIGHT_DP: float = 120.0
const BASE_CAROUSEL_WIDTH_DP: float = 280.0

const _MEDIA_BASE_WIDTH_DP: float = 200.0
const _TEXT_AREA_RATIO: float = 0.20

const _RATIO_LOOKUP: Array[float] = [
	-1.0,        # 0 = Fill
	2.0 / 3.0,   # 1 = 2:3  (width/height)
	3.0 / 4.0,   # 2 = 3:4
	1.0,         # 3 = 1:1
	16.0 / 11.0, # 4 = 16:11
]

# Grid separation (padding) - loaded from settings, defaults to 10 DP
var grid_separation: int = int(M3Units.dp(10))

# Scale factor applied when a card is focused. Cards scale UP from their normal size
# by this amount. Edge overflow is prevented by focus-safe container margins.
var focus_scale: float = 1.08:
	set(value):
		if not is_equal_approx(focus_scale, value):
			focus_scale = maxf(value, 1.0)
			_recalculate_layout()
			_refresh_buffer()

# Target card width as ratio of viewport (e.g., 0.15 = 15% of viewport width)
# This is the user-requested ratio, actual ratio may be snapped to fit whole cards
var target_card_width_ratio: float = 0.15:
	set(value):
		# Calculate dynamic max zoom (one card fills available space)
		var max_ratio = _calculate_max_ratio()
		var clamped = clampf(value, 0.05, max_ratio)
		# Calculate snapped ratio to ensure whole cards fit per row/column
		var snapped = _calculate_snapped_ratio(clamped)
		# Always update ratio and recalculate - _recalculate_layout handles optimization
		target_card_width_ratio = snapped
		_recalculate_layout()

# Computed zoom based on viewport size
var zoom: float = 1.0:
	get:
		return _calculate_zoom()
	set(value):
		push_warning("VirtualScrollGridContainer: Cannot set zoom directly. Set target_card_width_ratio instead.")

# Unified size vocabulary - single source of truth
var base_card_size: Vector2 = Vector2(BASE_CARD_WIDTH_DP, BASE_CARD_HEIGHT_DP)
var card_size: Vector2 = Vector2(212.0, 280.0)
var focused_card_size: Vector2 = Vector2(228.96, 302.4)

# Currently focused virtual index for dynamic stride math
var _focused_virtual_index: int = -1

# Backward compatibility - still compute these from card_size
var item_height: float = 280.0:
	get:
		return card_size.y + grid_separation
var item_width: float = 212.0:
	get:
		return card_size.x + grid_separation

var _scroll_container: SmoothScrollContainer
var _margin_container: MarginContainer
var _center_container: CenterContainer
var _flow_container: FlowContainer
var _debug_camera: Camera2D
var _debug_flow_panel: Panel

# Cached debug style boxes to avoid allocating every frame
var _debug_style_visible_data: StyleBoxFlat
var _debug_style_visible_loading: StyleBoxFlat
var _debug_style_buffer_data: StyleBoxFlat
var _debug_style_buffer_loading: StyleBoxFlat

var _total_items: int = 0
var _virtual_start: int = 0
var _virtual_end: int = 0
var _card_scene: PackedScene
var _ready_called: bool = false

var _card_pool: Array[Control] = []
var _active_cards: Array[Control] = []
var _active_cards_by_index: Dictionary[int, Control] = {}
var _max_pool_size: int = 120

var _last_applied_zoom: float = 0.0  # Track last zoom to avoid unnecessary updates
var _last_refreshed_card_size: Vector2 = Vector2.ZERO
var _last_refreshed_view_mode: ViewMode = ViewMode.GRID

# Scroll math cache — invalidated and recomputed inside _recalculate_layout()
var _cached_items_per_line: int = -1
var _cached_normal_stride: float = -1.0

# Margin caching - only update when margins actually change
var _last_margin_top: int = -1
var _last_margin_bottom: int = -1
var _last_margin_left: int = -1
var _last_margin_right: int = -1
var _last_flow_width: float = -1.0
var _last_flow_height: float = -1.0

# Margin virtual-range cache — margins only change when the active card range changes
var _last_margin_virtual_start: int = -1
var _last_margin_virtual_end: int = -1

var _data_cache: Dictionary = {}
var _pending_loads: Dictionary = {}

# Deduplication tracking - prevents duplicate game entries
var _cached_game_ids: Dictionary = {}  # romm_id -> cache_key

const MAX_CACHE_SIZE: int = 5000
var _cache_lru_tick: Dictionary[int, int] = {}
var _lru_counter: int = 0

func _update_view_mode() -> void:
	if not _flow_container or not _scroll_container:
		return
	match view_mode:
		ViewMode.GRID:
			_scroll_container.vertical = grid_vertical
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if grid_vertical else ScrollContainer.SCROLL_MODE_DISABLED
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if grid_vertical else ScrollContainer.SCROLL_MODE_AUTO
			_flow_container.vertical = not grid_vertical
		ViewMode.LIST:
			_scroll_container.vertical = true
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_flow_container.vertical = false
		ViewMode.CAROUSEL:
			_scroll_container.vertical = false
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			_flow_container.vertical = true
	_update_center_container_flags()
	_update_flow_container_flags()
	_recalculate_layout()
	_refresh_buffer()

func _update_flow_container_flags() -> void:
	if not _flow_container:
		return
	match view_mode:
		ViewMode.GRID:
			_flow_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_flow_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ViewMode.LIST:
			_flow_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_flow_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ViewMode.CAROUSEL:
			_flow_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_flow_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _update_center_container_flags() -> void:
	if not _center_container:
		return
	if vertical:
		_center_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_center_container.size_flags_vertical = Control.SIZE_FILL
	else:
		_center_container.size_flags_horizontal = Control.SIZE_FILL
		_center_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _get_focus_overflow() -> Vector2:
	# How many pixels a focused card extends beyond its normal bounds on each side.
	match view_mode:
		ViewMode.GRID:
			return Vector2(
				maxf(0.0, (focused_card_size.x - card_size.x) / 2.0),
				maxf(0.0, (focused_card_size.y - card_size.y) / 2.0)
			)
		ViewMode.LIST:
			return Vector2(0.0, maxf(0.0, (focused_card_size.y - card_size.y) / 2.0))
		ViewMode.CAROUSEL:
			return Vector2(maxf(0.0, (focused_card_size.x - card_size.x) / 2.0), 0.0)
	return Vector2.ZERO

func _get_available_size() -> Vector2:
	var scrollbar_x = 0.0
	var scrollbar_y = 0.0
	if _scroll_container:
		var v_scroll = _scroll_container.get_v_scroll_bar()
		if v_scroll:
			scrollbar_x = v_scroll.get_combined_minimum_size().x
		var h_scroll = _scroll_container.get_h_scroll_bar()
		if h_scroll:
			scrollbar_y = h_scroll.get_combined_minimum_size().y
	
	if vertical:
		return Vector2(maxf(size.x - scrollbar_x, 1.0), maxf(size.y, 1.0))
	else:
		return Vector2(maxf(size.x, 1.0), maxf(size.y - scrollbar_y, 1.0))

func _get_normal_stride() -> float:
	if _cached_normal_stride > 0:
		return _cached_normal_stride
	# Stride is based on normal card size so cards can touch at grid_separation = 0.
	# Focused cards scale up and overlap; inner padding prevents clipping at content edges.
	match view_mode:
		ViewMode.GRID:
			return (card_size.y + grid_separation) if vertical else (card_size.x + grid_separation)
		ViewMode.LIST:
			return card_size.y + grid_separation
		ViewMode.CAROUSEL:
			return card_size.x + grid_separation
	return (card_size.y + grid_separation) if vertical else (card_size.x + grid_separation)

func _get_slot_position_for_index(idx: int, items_per_line: int = -1, stride: float = -1.0) -> float:
	"""Returns the scroll-axis pixel position where slot `idx` begins."""
	if items_per_line < 0:
		items_per_line = _get_items_per_line()
	if stride < 0.0:
		stride = _get_normal_stride()
	var line = idx / items_per_line
	return line * stride

func set_focused_card(virtual_index: int) -> void:
	if _focused_virtual_index == virtual_index:
		return
	_focused_virtual_index = virtual_index
	_update_layout()
	_update_margin()

func _ready():
	_setup_ui()
	resized.connect(_on_resized)
	# Load initial grid separation and focus scale from settings
	# Use call_deferred to ensure SettingsManager is fully initialized
	call_deferred("_update_grid_separation_from_settings")
	call_deferred("_update_focus_scale_from_settings")
	call_deferred("_recalculate_layout")
	_ready_called = true
	
	# Connect to settings saved signal to refresh layout when card orientation changes
	if SettingsManager:
		SettingsManager.settings_saved.connect(_on_settings_saved)

func _exit_tree():
	if SettingsManager:
		SettingsManager.settings_saved.disconnect(_on_settings_saved)

func _on_settings_saved():
	_update_focus_scale_from_settings()

var _last_resized_size: Vector2 = Vector2.ZERO
var _is_recalculating_layout: bool = false

# During zoom/layout transitions, ScrollContainer may clamp its scroll value and
# emit a signal that reaches _on_scroll_value_changed() *after* _recalculate_layout()
# has returned. Without suppression that signal carries allow_recycle=true and
# recycles cards that were just preserved, causing a visible flash.
var _suppress_recycle_until_frame: int = -1

# Guard against recursive scroll_value_changed signals that can fire during
# container sorts triggered by add_child() inside _on_scroll_value_changed().
var _is_processing_scroll: bool = false

func _on_resized():
	# Ignore resize events that don't actually change size (sub-pixel or duplicate)
	var new_size = Vector2(size.x, size.y)
	if is_equal_approx(new_size.x, _last_resized_size.x) and is_equal_approx(new_size.y, _last_resized_size.y):
		return
	_last_resized_size = new_size
	# Prevent re-entrant layout recalculations (e.g. scrollbar visibility toggles
	# during a zoom-driven layout pass can fire _on_resized() mid-flight).
	if _is_recalculating_layout:
		return
	# Recalculate layout with current snapped zoom
	_recalculate_layout()
	# If we have items but no active cards (e.g., view was hidden during setup), load them now
	if _active_cards.size() == 0 and _total_items > 0 and size.x > 0 and size.y > 0:
		_initial_load()

func _update_grid_separation_from_settings() -> void:
	if not SettingsManager:
		return
	var setting = SettingsManager.get_setting("library_grid_padding")
	if setting and (setting.value is int or setting.value is float):
		grid_separation = int(M3Units.dp(float(setting.value)))
	else:
		grid_separation = int(M3Units.dp(10))
	
	# Apply to FlowContainer if it exists
	if _flow_container:
		if _flow_container.get_theme_constant("h_separation") != grid_separation:
			_flow_container.add_theme_constant_override("h_separation", grid_separation)
		if _flow_container.get_theme_constant("v_separation") != grid_separation:
			_flow_container.add_theme_constant_override("v_separation", grid_separation)

func _update_focus_scale_from_settings() -> void:
	if not SettingsManager:
		return
	var setting = SettingsManager.get_setting("library_focus_scale")
	if setting and (setting.value is int or setting.value is float):
		focus_scale = 1.0 + float(setting.value)
	else:
		focus_scale = 1.08



func _calculate_zoom() -> float:
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var ratio = clampf(target_card_width_ratio, 0.05, _calculate_max_ratio())
	
	match view_mode:
		ViewMode.GRID:
			var viewport_area = available.x * available.y
			var base_area = base_dims.x * base_dims.y
			var target_card_area = viewport_area * ratio * ratio
			return sqrt(target_card_area / base_area)
		ViewMode.LIST:
			return (available.y * ratio) / base_dims.y
		ViewMode.CAROUSEL:
			return (available.x * ratio) / base_dims.x
	return 1.0

func _calculate_max_ratio() -> float:
	if size.x <= 0 or size.y <= 0:
		return 0.5
	
	var base_dims = _get_base_dimensions_for_mode()
	
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return 0.5
	
	var available = _get_available_size()
	
	var zoom_width = available.x / base_dims.x
	var zoom_height = available.y / base_dims.y
	var zoom = min(zoom_width, zoom_height)
	var viewport_area = available.x * available.y
	var card_area = (base_dims.x * zoom) * (base_dims.y * zoom)
	var ratio = sqrt(card_area / viewport_area)
	
	return max(ratio / 2.0, 0.25)

## Returns all possible snap ratios for the current viewport configuration.
## Each ratio corresponds to a whole number of cards per line.
## Used to populate discrete slider stops that match grid snap behavior.
func get_snap_ratios() -> Array[float]:
	if size.x <= 0 or size.y <= 0:
		return []
	
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		# No discrete snapping in these modes
		return []
	
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var viewport_area = available.x * available.y
	
	# Determine max items per line based on minimum card size (10% of base)
	var max_items_per_line: int
	if vertical:
		var min_item_width = base_dims.x * 0.1 + grid_separation
		max_items_per_line = max(1, int(available.x / min_item_width))
	else:
		var min_item_height = base_dims.y * 0.1 + grid_separation
		max_items_per_line = max(1, int(available.y / min_item_height))
	
	var ratios: Array[float] = []
	
	# Cap at 6 visible items per line — matches List/Carousel minimum zoom parity
	const MAX_VISIBLE_ITEMS: int = 6
	var capped_max = min(max_items_per_line, MAX_VISIBLE_ITEMS)
	
	for items_per_line in range(1, capped_max + 1):
		var ratio = _compute_ratio_for_items_per_line(items_per_line, base_dims, available, viewport_area)
		if ratio > 0:
			var is_duplicate = false
			for existing in ratios:
				if is_equal_approx(ratio, existing):
					is_duplicate = true
					break
			if not is_duplicate:
				ratios.append(ratio)
	
	# Sort descending so largest cards (fewest per line) come first
	ratios.sort_custom(func(a, b): return a > b)
	
	# Defensive: log when we have fewer than 2 ratios for debugging
	if ratios.size() < 2:
		push_warning("[VirtualScrollGridContainer] Only %d snap ratio(s) for view_mode=%s, size=%s, base_dims=%s, available=%s" % [ratios.size(), view_mode, size, base_dims, available])
	
	return ratios

## Compute the exact snap ratio for a given number of items per line.
func _compute_ratio_for_items_per_line(items_per_line: int, base_dims: Vector2, available: Vector2, viewport_area: float) -> float:
	var effective_width = available.x
	var effective_height = available.y
	
	# Iterate a few times to converge focus overflow
	for i in range(3):
		var prev_effective_width = effective_width
		var prev_effective_height = effective_height
		var target_card_width: float
		var target_card_height: float
		
		if vertical:
			var target_item_width = effective_width / items_per_line
			target_card_width = target_item_width - grid_separation
			target_card_height = target_card_width * (base_dims.y / base_dims.x)
		else:
			var target_item_height = effective_height / items_per_line
			target_card_height = target_item_height - grid_separation
			target_card_width = target_card_height * (base_dims.x / base_dims.y)
		
		target_card_width = max(target_card_width, base_dims.x * 0.1)
		target_card_height = max(target_card_height, base_dims.y * 0.1)
		
		var focus_overflow_x = maxf(0.0, target_card_width * (focus_scale - 1.0) / 2.0)
		var focus_overflow_y = maxf(0.0, target_card_height * (focus_scale - 1.0) / 2.0)
		
		effective_width = maxf(1.0, available.x - focus_overflow_x * 2.0)
		effective_height = maxf(1.0, available.y - focus_overflow_y * 2.0)
		
		# Convergence check: if effective dimensions stabilized, stop iterating
		if is_equal_approx(effective_width, prev_effective_width) and is_equal_approx(effective_height, prev_effective_height):
			break
	
	# Final computation
	var final_card_width: float
	var final_card_height: float
	
	if vertical:
		var target_item_width = effective_width / items_per_line
		final_card_width = target_item_width - grid_separation
		final_card_height = final_card_width * (base_dims.y / base_dims.x)
	else:
		var target_item_height = effective_height / items_per_line
		final_card_height = target_item_height - grid_separation
		final_card_width = final_card_height * (base_dims.x / base_dims.y)
	
	final_card_width = max(final_card_width, base_dims.x * 0.1)
	final_card_height = max(final_card_height, base_dims.y * 0.1)
	
	var target_card_area = final_card_width * final_card_height
	var ratio = sqrt(target_card_area / viewport_area)
	
	return clampf(ratio, 0.05, _calculate_max_ratio())

func _calculate_snapped_ratio(desired_ratio: float) -> float:
	if size.x <= 0 or size.y <= 0:
		return desired_ratio
	
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return clampf(desired_ratio, 0.05, _calculate_max_ratio())
	
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	
	var viewport_area = available.x * available.y
	var target_card_area = viewport_area * desired_ratio * desired_ratio
	var desired_zoom = sqrt(target_card_area / (base_dims.x * base_dims.y))
	var desired_card_width = base_dims.x * desired_zoom
	var desired_card_height = base_dims.y * desired_zoom
	
	# Account for focus overflow so snapping matches _get_items_per_line()
	var desired_focus_overflow_x = maxf(0.0, desired_card_width * (focus_scale - 1.0) / 2.0)
	var desired_focus_overflow_y = maxf(0.0, desired_card_height * (focus_scale - 1.0) / 2.0)
	
	# Use same formula as _get_items_per_line() for consistency
	var effective_width = maxf(1.0, available.x + grid_separation - desired_focus_overflow_x * 2.0)
	var effective_height = maxf(1.0, available.y + grid_separation - desired_focus_overflow_y * 2.0)
	
	var desired_item_width = desired_card_width + grid_separation
	var desired_item_height = desired_card_height + grid_separation
	
	var desired_items_per_line: int
	if vertical:
		desired_items_per_line = max(1, int(effective_width / desired_item_width + 0.0001))
	else:
		desired_items_per_line = max(1, int(effective_height / desired_item_height + 0.0001))
	
	# Use the exact same helper for consistency
	return _compute_ratio_for_items_per_line(desired_items_per_line, base_dims, available, viewport_area)

func _recalculate_layout():
	if _is_recalculating_layout:
		return
	if not _flow_container or not _scroll_container:
		return
	if size.x <= 0 or size.y <= 0:
		return
	
	_is_recalculating_layout = true
	_suppress_recycle_until_frame = Engine.get_process_frames() + 1
	
	var current_zoom = _calculate_zoom()
	
	if current_zoom <= 0:
		push_warning("[VirtualScrollGridContainer] Invalid zoom value: %f, skipping layout" % current_zoom)
		_is_recalculating_layout = false
		return
	
	var base_dims = _get_base_dimensions_for_mode()
	base_card_size = base_dims
	
	match view_mode:
		ViewMode.GRID:
			card_size = base_dims * current_zoom
			focused_card_size = card_size * focus_scale
		ViewMode.LIST:
			var card_width = _get_available_size().x / focus_scale
			card_size = Vector2(card_width, base_dims.y * current_zoom)
			focused_card_size = card_size * focus_scale
		ViewMode.CAROUSEL:
			var card_height = _get_available_size().y / focus_scale
			card_size = Vector2(base_dims.x * current_zoom, card_height)
			focused_card_size = card_size * focus_scale
	
	# Invalidate then pre-compute scroll math before downstream consumers read it
	_cached_items_per_line = -1
	_cached_normal_stride = -1.0
	_cached_items_per_line = _get_items_per_line()
	_cached_normal_stride = _get_normal_stride()
	
	_flow_container.add_theme_constant_override("h_separation", grid_separation)
	_flow_container.add_theme_constant_override("v_separation", grid_separation)
	
	_update_layout()
	_update_margin()
	_flow_container.queue_sort()
	if vertical:
		_on_scroll_value_changed(_scroll_container.scroll_vertical, false)
	else:
		_on_scroll_value_changed(_scroll_container.scroll_horizontal, false)
	
	if not is_equal_approx(current_zoom, _last_applied_zoom):
		_last_applied_zoom = current_zoom
	
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		if "focus_scale_enabled" in card:
			card.focus_scale_enabled = true
			card.focus_scale_inverted = false
		if card.has_method("set_focus_scale"):
			card.set_focus_scale(focus_scale)
		_configure_card_size_flags(card)
	
	_is_recalculating_layout = false

func _get_items_per_line() -> int:
	if not _scroll_container:
		return 1
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return 1
	if _cached_items_per_line > 0:
		return _cached_items_per_line
	
	var available = _get_available_size()
	var focus_overflow = _get_focus_overflow()
	if vertical:
		# Subtract 2× overflow so centered flow leaves room on both sides
		# for focused cards to expand without clipping the viewport edge.
		var effective_width = maxf(1.0, available.x + grid_separation - focus_overflow.x * 2.0)
		return max(1, int(effective_width / item_width + 0.0001))
	else:
		var effective_height = maxf(1.0, available.y + grid_separation - focus_overflow.y * 2.0)
		return max(1, int(effective_height / item_height + 0.0001))

func _get_media_aspect_ratio() -> float:
	if not SettingsManager:
		return -1.0
	var setting = SettingsManager.get_setting("card_media_aspect_ratio")
	if setting and setting.value is int:
		var idx = clampi(setting.value, 0, _RATIO_LOOKUP.size() - 1)
		return _RATIO_LOOKUP[idx]
	return -1.0

func _get_card_display_mode() -> int:
	if not SettingsManager:
		return 0
	var setting = SettingsManager.get_setting("library_card_display_mode")
	if setting and setting.value is int:
		return clampi(setting.value, 0, 2)
	return 0

func _get_base_card_height_for_ratio(media_h: float) -> float:
	"""Compute card height that guarantees M3Card's text area fits.
	
	Delegates to M3Card.get_min_text_height_dp() so the threshold logic
	lives in one place and never drifts out of sync."""
	var card_h = media_h + 500.0  # start well above any threshold
	for i in range(3):
		var text_h = M3Card.get_min_text_height_dp(card_h)
		card_h = media_h + text_h
	return card_h

func _get_content_alignment() -> M3Card.ContentAlignment:
	if not SettingsManager:
		return M3Card.ContentAlignment.START
	var setting = SettingsManager.get_setting("library_card_content_alignment")
	if setting and setting.value is int:
		var idx = clampi(setting.value, 0, 2)
		return idx as M3Card.ContentAlignment
	return M3Card.ContentAlignment.START

func _get_base_dimensions_for_mode() -> Vector2:
	var ratio = _get_media_aspect_ratio()
	var display_mode = _get_card_display_mode()
	if ratio < 0.0:
		# Fill mode — legacy behavior
		match view_mode:
			ViewMode.GRID:
				return _get_base_dimensions()
			ViewMode.LIST:
				return Vector2(0.0, BASE_LIST_HEIGHT_DP)
			ViewMode.CAROUSEL:
				return Vector2(BASE_CAROUSEL_WIDTH_DP, 0.0)
		return _get_base_dimensions()
	
	# Ratio mode
	match view_mode:
		ViewMode.GRID:
			var media_h = _MEDIA_BASE_WIDTH_DP / ratio
			if display_mode == 2:
				# Media Only: no text area
				return Vector2(_MEDIA_BASE_WIDTH_DP, media_h)
			var card_h = _get_base_card_height_for_ratio(media_h)
			return Vector2(_MEDIA_BASE_WIDTH_DP, card_h)
		ViewMode.LIST:
			# Horizontal layout: base height = media height
			return Vector2(0.0, _MEDIA_BASE_WIDTH_DP / ratio)
		ViewMode.CAROUSEL:
			# Vertical layout: base width = media width
			return Vector2(_MEDIA_BASE_WIDTH_DP, 0.0)
	return _get_base_dimensions()

func _get_visible_count() -> int:
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	if vertical:
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		return (visible_rows * items_per_line) + 1
	else:
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		return (visible_cols * items_per_line) + 1

## Returns the number of items that fit in the current viewport
func get_visible_count() -> int:
	return _get_visible_count()

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
	_update_flow_container_flags()
	_flow_container.add_theme_constant_override("h_separation", grid_separation)
	_flow_container.add_theme_constant_override("v_separation", grid_separation)
	_center_container.add_child(_flow_container)
	
	if debug_mode:
		_setup_debug_camera()
	
	_recalculate_dimensions()

func _get_base_dimensions() -> Vector2:
	return Vector2(BASE_CARD_WIDTH_DP, BASE_CARD_HEIGHT_DP)

func _recalculate_dimensions():
	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions()
	base_card_size = base_dims
	card_size = base_dims * current_zoom
	focused_card_size = card_size * focus_scale

func refresh_dimensions() -> void:
	"""Recalculate dimensions and refresh layout (call after orientation change or margin change)."""
	# Update grid separation from settings
	_update_grid_separation_from_settings()
	
	# Reset FlowContainer's custom_minimum_size to force recalculation with current viewport size
	# This fixes issues where layout was calculated while view was hidden (size=0)
	if _flow_container:
		_flow_container.custom_minimum_size = Vector2(0, 0)
	
	# Re-snap zoom to ensure it fits the new dimensions/margins
	var current_ratio = target_card_width_ratio
	var snapped_ratio = _calculate_snapped_ratio(current_ratio)
	# Always update ratio - the setter will handle recalculation
	target_card_width_ratio = snapped_ratio
	
	var current_zoom = _calculate_zoom()
	var zoom_changed = not is_equal_approx(current_zoom, _last_applied_zoom)
	if zoom_changed:
		_last_applied_zoom = current_zoom
	
	var should_refresh_cards = not is_equal_approx(card_size.x, _last_refreshed_card_size.x) or not is_equal_approx(card_size.y, _last_refreshed_card_size.y) or view_mode != _last_refreshed_view_mode
	if should_refresh_cards:
		_last_refreshed_card_size = card_size
		_last_refreshed_view_mode = view_mode
		for card in _active_cards:
			if is_instance_valid(card) and card.has_method("refresh_settings"):
				card.refresh_settings()
	# _update_margin() is already called by _recalculate_layout() via the target_card_width_ratio setter above

func setup(card_scene_resource: PackedScene, total_items: int):
	_card_scene = card_scene_resource
	_total_items = total_items
	
	_instantiate_card_pool()
	
	# Wait for container sizing before initial load
	await get_tree().process_frame
	await get_tree().process_frame
	if size.x > 0 and size.y > 0:
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
	var count_changed = _total_items != count
	_total_items = count
	_update_layout()
	
	# Clear cache if count changed (index-to-data mapping is now stale)
	# or if preserve_cache is explicitly false
	if count_changed or not preserve_cache:
		_refresh_buffer()

func _update_layout():
	var items_per_line = _get_items_per_line()
	
	match view_mode:
		ViewMode.GRID:
			if vertical:
				var row_width = items_per_line * card_size.x
				if items_per_line > 1:
					row_width += (items_per_line - 1) * grid_separation
				_flow_container.custom_minimum_size.x = max(row_width, 0.0)
			else:
				var col_height = items_per_line * card_size.y
				if items_per_line > 1:
					col_height += (items_per_line - 1) * grid_separation
				_flow_container.custom_minimum_size.y = max(col_height, 0.0)
		ViewMode.LIST:
			_flow_container.custom_minimum_size.x = 0
		ViewMode.CAROUSEL:
			_flow_container.custom_minimum_size.y = 0

func _initial_load():
	if _active_cards.size() > 0:
		return
	if size.x <= 0 or size.y <= 0:
		return
	
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var visible_count: int
	if vertical:
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		visible_count = visible_rows * items_per_line
	else:
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		visible_count = visible_cols * items_per_line
	
	var total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
	var card_count = min(total_card_count, _total_items, _max_pool_size)
	
	_virtual_start = 0
	_virtual_end = card_count - 1
	
	for i in range(card_count):
		var card = _acquire_card()
		if card:
			card.set_meta("virtual_index", i)
			if "focus_scale_enabled" in card:
				card.focus_scale_enabled = true
				card.focus_scale_inverted = false
			_active_cards.append(card)
			_active_cards_by_index[i] = card
			_flow_container.add_child(card)
			_configure_card_size_flags(card)
			if card.has_method("set_focus_scale"):
				card.set_focus_scale(focus_scale)
			if card.has_method("refresh_settings"):
				card.refresh_settings()
			item_created.emit(card, i)
	
	_update_margin()
	_request_data(0, card_count)

func _compute_visible_and_buffer_ranges(scroll_pos: int, items_per_line: int, stride: float, viewport_size: float) -> Dictionary:
	"""Compute visible range and buffer target range for the current scroll position."""
	var line = int(scroll_pos / stride) if stride > 0 else 0
	var visible_lines = ceili(viewport_size / stride) if stride > 0 else 1
	var visible_start_idx = line * items_per_line
	var visible_end_idx = min(visible_start_idx + visible_lines * items_per_line, _total_items) - 1
	
	var visible_count = _get_visible_count()
	var total_card_count = visible_count + (visual_buffer_lines * 2 * items_per_line)
	var half_buffer = (total_card_count - visible_count) / 2
	var target_start = max(0, visible_start_idx - half_buffer)
	var target_end = min(_total_items, target_start + total_card_count)
	
	if target_end == _total_items:
		target_start = max(0, _total_items - total_card_count)
	
	# Align target_start to items_per_line so the first buffered card always starts
	# at the beginning of a row/column. Without this, FlowContainer misaligns cards
	# when the buffer starts mid-row after incremental recycling or zoom changes.
	target_start = (target_start / items_per_line) * items_per_line
	
	# Recompute target_end after alignment so the buffer size stays consistent
	target_end = min(_total_items, target_start + total_card_count)
	
	return {
		"visible_start": visible_start_idx,
		"visible_end": visible_end_idx,
		"target_start": target_start,
		"target_end": target_end,
		"total_card_count": total_card_count,
	}

func _on_scroll_value_changed(value: float, allow_recycle: bool = true):
	if _is_processing_scroll:
		return
	_is_processing_scroll = true
	
	if _total_items == 0 or not _scroll_container:
		_is_processing_scroll = false
		return
	
	# Suppress recycling during the frame(s) after a layout recalculation.
	# ScrollContainer may clamp its scroll value at end-of-frame and emit a
	# signal that would otherwise recycle cards with allow_recycle=true.
	var was_allowed = allow_recycle
	if Engine.get_process_frames() <= _suppress_recycle_until_frame:
		allow_recycle = false
	
	var scroll_pos = int(value)
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()
	
	var viewport_size = size.y if vertical else size.x
	var ranges = _compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)
	
	var visible_start_idx: int = ranges.visible_start
	var visible_end_idx: int = ranges.visible_end
	var target_start: int = ranges.target_start
	var target_end: int = ranges.target_end
	var total_card_count: int = ranges.total_card_count
	
	var changes_made = false
	var recycled_top = 0
	var recycled_bottom = 0
	
	# Batch recycle from top — skip during layout recalculations (zoom changes)
	# so cards are not reset and their images stay loaded.
	if allow_recycle:
		var recycle_top_count = 0
		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx < target_start:
				recycle_top_count += 1
			else:
				break
		if recycle_top_count > 0:
			_batch_recycle_from_start(recycle_top_count)
			recycled_top += recycle_top_count
			changes_made = true
		
		while _active_cards.size() > 0:
			var last_card = _active_cards[_active_cards.size() - 1]
			var last_idx = last_card.get_meta("virtual_index", -1)
			
			if last_idx >= target_end:
				_recycle_card_at_index(_active_cards.size() - 1)
				recycled_bottom += 1
				changes_made = true
			else:
				break
	
	# If buffer was fully recycled (e.g. scrolled to a completely different range),
	# populate the target range from scratch
	if _active_cards.size() == 0:
		for i in range(target_start, target_end):
			_add_card_at_end(i)
			changes_made = true
	elif _active_cards.size() > 0:
		var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		while current_last < target_end - 1 and current_last < _total_items - 1:
			_add_card_at_end(current_last + 1)
			changes_made = true
			current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	
		if _active_cards.size() > 0:
			var current_first = _active_cards[0].get_meta("virtual_index", 0)
			if current_first > target_start and current_first > 0:
				var add_start_count = mini(current_first - target_start, current_first)
				_batch_add_at_start(target_start, add_start_count)
				changes_made = true
	
	if _active_cards.size() > 0:
		_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
		_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	
	_request_missing_data()
	
	var should_update_margin = true
	if _active_cards.size() > 0:
		var current_first = _active_cards[0].get_meta("virtual_index", 0)
		var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		should_update_margin = (current_first != _last_margin_virtual_start) or (current_last != _last_margin_virtual_end)
	if should_update_margin:
		_update_margin()
	_check_preload_needed()
	_update_card_priorities(visible_start_idx, visible_end_idx)
	
	visible_range_changed.emit(visible_start_idx, min(visible_end_idx, _total_items), _total_items)
	
	if vertical:
		var batch_rows = 1
		var batch_height_pixels = batch_rows * item_height

	if debug_mode:
		_update_debug_visuals(visible_start_idx, visible_end_idx)
	
	_is_processing_scroll = false

func _recycle_card_at_index(index: int):
	if index < 0 or index >= _active_cards.size():
		return
	
	var card = _active_cards[index]
	var old_game_title = ""
	if "game" in card and card.game:
		old_game_title = card.game.title
	_active_cards.remove_at(index)
	var vidx = card.get_meta("virtual_index", -1)
	if vidx >= 0:
		_active_cards_by_index.erase(vidx)
	
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
		
		_add_to_pool(card)
func _add_to_pool(card: Control) -> void:
	if _card_pool.size() >= _max_pool_size:
		card.queue_free()
	else:
		_card_pool.append(card)


func _configure_card_size_flags(card: Control) -> void:
	if not card is M3Card:
		return
	
	match view_mode:
		ViewMode.GRID:
			card.card_layout_mode = M3Card.LayoutMode.VERTICAL
			card.custom_minimum_size = card_size
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ViewMode.LIST:
			card.card_layout_mode = M3Card.LayoutMode.HORIZONTAL
			card.custom_minimum_size = card_size
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ViewMode.CAROUSEL:
			card.card_layout_mode = M3Card.LayoutMode.VERTICAL
			card.custom_minimum_size = card_size
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	# Apply content alignment for list and carousel modes
	if view_mode != ViewMode.GRID and card.has_method("set_content_alignment"):
		var alignment = _get_content_alignment()
		card.set_content_alignment(alignment)

	if card.has_method("set_media_aspect_ratio"):
		card.set_media_aspect_ratio(_get_media_aspect_ratio())

func _add_card_at_end(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return
	
	card.set_meta("virtual_index", virtual_index)
	if "focus_scale_enabled" in card:
		card.focus_scale_enabled = true
		card.focus_scale_inverted = false
	_configure_card_size_flags(card)
	if card.has_method("set_focus_scale"):
		card.set_focus_scale(focus_scale)
	_active_cards.append(card)
	_active_cards_by_index[virtual_index] = card
	_flow_container.add_child(card)
	
	# Refresh settings (orientation, etc.) - will only rebuild effects if orientation changed
	if card.has_method("refresh_settings"):
		card.refresh_settings()
	
	if _data_cache.has(virtual_index):
		var is_visible = _is_index_visible(virtual_index)
		if card.has_method("set_game_with_priority"):
			card.set_game_with_priority(_data_cache[virtual_index], is_visible)
		else:
			card.game = _data_cache[virtual_index]
		_update_cache_access_order(virtual_index)
	
	item_created.emit(card, virtual_index)

func _add_card_at_start(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return
	
	card.set_meta("virtual_index", virtual_index)
	if "focus_scale_enabled" in card:
		card.focus_scale_enabled = true
		card.focus_scale_inverted = false
	_active_cards.insert(0, card)
	_active_cards_by_index[virtual_index] = card
	_flow_container.add_child(card)
	_flow_container.move_child(card, 0)
	_configure_card_size_flags(card)
	if card.has_method("set_focus_scale"):
		card.set_focus_scale(focus_scale)
	
	# Refresh settings (orientation, etc.) - will only rebuild effects if orientation changed
	if card.has_method("refresh_settings"):
		card.refresh_settings()
	
	if _data_cache.has(virtual_index):
		var is_visible = _is_index_visible(virtual_index)
		if card.has_method("set_game_with_priority"):
			card.set_game_with_priority(_data_cache[virtual_index], is_visible)
		else:
			card.game = _data_cache[virtual_index]
		_update_cache_access_order(virtual_index)
	
	item_created.emit(card, virtual_index)

func _batch_recycle_from_start(count: int) -> void:
	if count <= 0 or count > _active_cards.size():
		return
	var to_recycle = _active_cards.slice(0, count)
	_active_cards = _active_cards.slice(count)
	for card in to_recycle:
		var vidx = card.get_meta("virtual_index", -1)
		if vidx >= 0:
			_active_cards_by_index.erase(vidx)
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

func _batch_add_at_start(target_start: int, count: int) -> void:
	if count <= 0:
		return
	var new_cards: Array[Control] = []
	for i in range(count):
		var virtual_index = target_start + i
		var card = _acquire_card()
		if not card:
			break
		card.set_meta("virtual_index", virtual_index)
		if "focus_scale_enabled" in card:
			card.focus_scale_enabled = true
			card.focus_scale_inverted = false
		_flow_container.add_child(card)
		_flow_container.move_child(card, i)
		_configure_card_size_flags(card)
		if card.has_method("set_focus_scale"):
			card.set_focus_scale(focus_scale)
		if card.has_method("refresh_settings"):
			card.refresh_settings()
		if _data_cache.has(virtual_index):
			var is_visible = _is_index_visible(virtual_index)
			if card.has_method("set_game_with_priority"):
				card.set_game_with_priority(_data_cache[virtual_index], is_visible)
			else:
				card.game = _data_cache[virtual_index]
			_update_cache_access_order(virtual_index)
		item_created.emit(card, virtual_index)
		_active_cards_by_index[virtual_index] = card
		new_cards.append(card)
	_active_cards = new_cards + _active_cards

func _get_visible_range() -> Dictionary:
	var items_per_line = _get_items_per_line()
	var visible_start_idx: int
	var visible_end_idx: int
	var eff = _get_normal_stride()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		visible_start_idx = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
		visible_end_idx = min(visible_start_idx + visible_rows * items_per_line, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		visible_start_idx = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
		visible_end_idx = min(visible_start_idx + visible_cols * items_per_line, _total_items)
	
	return {"start": visible_start_idx, "end": visible_end_idx}

func _is_index_visible(idx: int) -> bool:
	var range_info = _get_visible_range()
	return idx >= range_info.start and idx < range_info.end

func _acquire_card() -> Control:
	while _card_pool.size() > 0:
		var card = _card_pool.pop_back()
		if is_instance_valid(card):
			card.set_meta("pooled", false)
			if card.has_method("reset"):
				card.reset()
			card.visible = true
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
		_last_margin_virtual_start = -1
		_last_margin_virtual_end = -1
		if _last_margin_top != 0 or _last_margin_bottom != 0 or _last_margin_left != 0 or _last_margin_right != 0:
			_margin_container.add_theme_constant_override("margin_top", 0)
			_margin_container.add_theme_constant_override("margin_bottom", 0)
			_margin_container.add_theme_constant_override("margin_left", 0)
			_margin_container.add_theme_constant_override("margin_right", 0)
			_last_margin_top = 0
			_last_margin_bottom = 0
			_last_margin_left = 0
			_last_margin_right = 0
		if _last_flow_height != 0:
			_flow_container.custom_minimum_size.y = 0
			_last_flow_height = 0
		if _last_flow_width != 0:
			_flow_container.custom_minimum_size.x = 0
			_last_flow_width = 0
		return
	
	var first_idx = _active_cards[0].get_meta("virtual_index", 0)
	var last_idx = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	_last_margin_virtual_start = first_idx
	_last_margin_virtual_end = last_idx
	var num_active = last_idx - first_idx + 1
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()
	var focus_overflow = _get_focus_overflow()
	
	if vertical:
		# Add focus overflow padding to top/bottom so edge rows have room to scale.
		var first_pos = _get_slot_position_for_index(first_idx, items_per_line, stride)
		var after_last_pos = _get_slot_position_for_index(last_idx + 1, items_per_line, stride)
		var total_end = _get_slot_position_for_index(_total_items, items_per_line, stride)
		var margin_top = first_pos + focus_overflow.y
		var margin_bottom = total_end - after_last_pos + focus_overflow.y
		var flow_height = after_last_pos - first_pos
		
		if int(margin_top) != _last_margin_top or int(margin_bottom) != _last_margin_bottom:
			_margin_container.add_theme_constant_override("margin_top", int(margin_top))
			_margin_container.add_theme_constant_override("margin_bottom", int(margin_bottom))
			_last_margin_top = int(margin_top)
			_last_margin_bottom = int(margin_bottom)
		
		if not is_equal_approx(flow_height, _last_flow_height):
			_flow_container.custom_minimum_size.y = flow_height
			_last_flow_height = flow_height
		
		# Clear orthogonal margins/flow-sizes so switching between vertical
		# and horizontal modes doesn't leave stale values.
		if _last_margin_left != 0 or _last_margin_right != 0:
			_margin_container.add_theme_constant_override("margin_left", 0)
			_margin_container.add_theme_constant_override("margin_right", 0)
			_last_margin_left = 0
			_last_margin_right = 0
		if _last_flow_width != 0:
			_flow_container.custom_minimum_size.x = 0
			_last_flow_width = 0
	else:
		var first_pos = _get_slot_position_for_index(first_idx, items_per_line, stride)
		var after_last_pos = _get_slot_position_for_index(last_idx + 1, items_per_line, stride)
		var total_end = _get_slot_position_for_index(_total_items, items_per_line, stride)
		var margin_left = first_pos + focus_overflow.x
		var margin_right = total_end - after_last_pos + focus_overflow.x
		var flow_width = after_last_pos - first_pos
		
		if int(margin_left) != _last_margin_left or int(margin_right) != _last_margin_right:
			_margin_container.add_theme_constant_override("margin_left", int(margin_left))
			_margin_container.add_theme_constant_override("margin_right", int(margin_right))
			_last_margin_left = int(margin_left)
			_last_margin_right = int(margin_right)
		
		if not is_equal_approx(flow_width, _last_flow_width):
			_flow_container.custom_minimum_size.x = flow_width
			_last_flow_width = flow_width
		
		# Clear orthogonal margins/flow-sizes so switching between vertical
		# and horizontal modes doesn't leave stale values.
		if _last_margin_top != 0 or _last_margin_bottom != 0:
			_margin_container.add_theme_constant_override("margin_top", 0)
			_margin_container.add_theme_constant_override("margin_bottom", 0)
			_last_margin_top = 0
			_last_margin_bottom = 0
		if _last_flow_height != 0:
			_flow_container.custom_minimum_size.y = 0
			_last_flow_height = 0

func _is_index_pending(idx: int) -> bool:
	for offset in _pending_loads.keys():
		var limit = _pending_loads[offset]
		if idx >= offset and idx < offset + limit:
			return true
	return false

func _request_missing_data():
	if _active_cards.size() == 0:
		return
	
	var missing_indices: Array[int] = []
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= 0 and not _data_cache.has(idx) and not _is_index_pending(idx):
			missing_indices.append(idx)
	
	if missing_indices.size() == 0:
		return
	
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
	_pending_loads[offset] = limit
	
	items_requested.emit(offset, limit)

func on_items_loaded(items: Array[GameResource], offset: int, _is_preload: bool = false):
	_pending_loads.erase(offset)
	
	if items.is_empty():
		return
	
	var duplicates_found: int = 0
	
	for i in range(items.size()):
		var cache_key = offset + i
		var game = items[i]
		
		# Deduplication check: skip if this game ID is already cached at a different index
		if game and game.romm_id != 0:
			if _cached_game_ids.has(game.romm_id):
				var existing_key = _cached_game_ids[game.romm_id]
				if existing_key != cache_key:
					# Duplicate detected - skip this entry
					duplicates_found += 1
					push_warning("[VirtualScrollGridContainer] Duplicate game detected: '%s' (romm_id: %d) at indices %d and %d - skipping duplicate" % [game.title, game.romm_id, existing_key, cache_key])
					continue
			
		if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
			_evict_oldest_cache_entries(items.size())
		
		_data_cache[cache_key] = game
		_cached_game_ids[game.romm_id] = cache_key
		_update_cache_access_order(cache_key)
	
	if duplicates_found > 0:
		push_warning("[VirtualScrollGridContainer] Found and skipped %d duplicate game(s) in batch starting at offset %d" % [duplicates_found, offset])
	
	var range_info = _get_visible_range()
	var visible_start_idx: int = range_info.start
	var visible_end_idx: int = range_info.end
	
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
				updated_count += 1
	
	_update_card_priorities(visible_start_idx, visible_end_idx)

func _refresh_buffer():
	while _active_cards.size() > 0:
		_recycle_card_at_index(0)
	
	_data_cache.clear()
	_cached_game_ids.clear()
	_cache_lru_tick.clear()
	_pending_loads.clear()
	_active_cards_by_index.clear()
	_margin_container.add_theme_constant_override("margin_top", 0)
	_margin_container.add_theme_constant_override("margin_bottom", 0)
	_margin_container.add_theme_constant_override("margin_left", 0)
	_margin_container.add_theme_constant_override("margin_right", 0)
	_flow_container.custom_minimum_size = Vector2(0, 0)
	_virtual_start = 0
	_virtual_end = 0
	_recalculate_layout()
	if _active_cards.size() == 0:
		_initial_load()

func get_target_scroll() -> float:
	return _scroll_container.get_target_scroll() if _scroll_container else 0.0

func get_visible_range() -> Dictionary:
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		var visible_start = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
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
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		var visible_start = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
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
	return _active_cards_by_index.get(index, null)

func scroll_to_index(index: int, animate: bool = false, duration_multiplier: float = 1.0, focus_callback: Callable = Callable()):
	if _scroll_container:
		var items_per_line = _get_items_per_line()
		var target_pos = _get_slot_position_for_index(index)
		
		if vertical:
			var viewport_height = size.y
			var card_offset = target_pos + (card_size.y / 2.0) - (viewport_height / 2.0)
			_scroll_container.scroll_to(int(card_offset), animate, duration_multiplier, focus_callback)
		else:
			var viewport_width = size.x
			var card_offset = target_pos + (card_size.x / 2.0) - (viewport_width / 2.0)
			_scroll_container.scroll_to(int(card_offset), animate, duration_multiplier, focus_callback)

func _update_debug_visuals(visible_start_idx: int, visible_end_idx: int):
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
	
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx < 0:
			continue
		
		var is_visible = idx >= visible_start_idx and idx <= visible_end_idx
		var has_data = _data_cache.has(idx)
		
		# Use cached metadata reference instead of tree traversal for performance
		var debug_panel = card.get_meta("_debug_panel_ref", null)
		if not debug_panel or not is_instance_valid(debug_panel):
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
			card.set_meta("_debug_panel_ref", debug_panel)
		
		var style: StyleBoxFlat
		if is_visible:
			style = _debug_style_visible_data if has_data else _debug_style_visible_loading
		else:
			style = _debug_style_buffer_data if has_data else _debug_style_buffer_loading
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
	
	if debug_mode:
		_setup_debug_camera()
		_setup_debug_flow_panel()
		if _active_cards.size() > 0:
			var first_idx = _active_cards[0].get_meta("virtual_index", 0)
			var last_idx = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			_update_debug_visuals(first_idx, last_idx)
	else:
		if _debug_camera:
			_debug_camera.queue_free()
			_debug_camera = null
		if _debug_flow_panel:
			_debug_flow_panel.queue_free()
			_debug_flow_panel = null
		for card in _active_cards:
			var debug_panel = card.get_meta("_debug_panel_ref", null)
			if debug_panel and is_instance_valid(debug_panel):
				debug_panel.queue_free()
			card.set_meta("_debug_panel_ref", null)
		_debug_style_visible_data = null
		_debug_style_visible_loading = null
		_debug_style_buffer_data = null
		_debug_style_buffer_loading = null

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
	var eff = _get_normal_stride()
	
	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = size.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		var visible_start = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
		var visible_end = min(visible_start + (visible_rows * items_per_line), _total_items)
		
		visible_range_changed.emit(visible_start, visible_end, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = size.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		var visible_start = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
		var visible_end = min(visible_start + (visible_cols * items_per_line), _total_items)
		
		visible_range_changed.emit(visible_start, visible_end, _total_items)
	
	return start_index

func _initial_load_from_increment():
	var items_per_line = _get_items_per_line()
	var visible_count: int
	var eff = _get_normal_stride()
	
	if vertical:
		var viewport_height = size.y if size.y > 0 else 600
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		visible_count = visible_rows * items_per_line
	else:
		var viewport_width = size.x if size.x > 0 else 800
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
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
			if "focus_scale_enabled" in card:
				card.focus_scale_enabled = true
				card.focus_scale_inverted = false
			_configure_card_size_flags(card)
			_active_cards.append(card)
			_active_cards_by_index[i] = card
			_flow_container.add_child(card)
			
			if _data_cache.has(i):
				var is_visible = i < visible_count
				if card.has_method("set_game_with_priority"):
					card.set_game_with_priority(_data_cache[i], is_visible)
				else:
					card.game = _data_cache[i]
				if card.has_method("update_display"):
					card.update_display()
			
			item_created.emit(card, i)
	
	_update_margin()

func cache_items_at_offset(items: Array[GameResource], offset: int):
	var duplicates_found: int = 0
	
	for i in range(items.size()):
		if offset + i < _total_items:
			var cache_key = offset + i
			var game = items[i]
			
			# Deduplication check
			if game and game.romm_id != 0:
				if _cached_game_ids.has(game.romm_id):
					var existing_key = _cached_game_ids[game.romm_id]
					if existing_key != cache_key:
						duplicates_found += 1
						continue
			
			if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
				_evict_oldest_cache_entries(items.size())
			
			_data_cache[cache_key] = game
			_cached_game_ids[game.romm_id] = cache_key
			_update_cache_access_order(cache_key)
	
	if items.size() > 0:
		var range_info = _get_visible_range()
		var visible_start_idx: int = range_info.start
		var visible_end_idx: int = range_info.end
		
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
		var range_info = _get_visible_range()
		var visible_start_idx: int = range_info.start
		var visible_end_idx: int = range_info.end
		
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
				if card.has_method("update_display"):
					card.update_display()
				updated_count += 1

func refresh_all_card_effects() -> void:
	"""Refresh effects on all active cards (call when card settings change)."""
	for card in _active_cards:
		if is_instance_valid(card) and card.has_method("refresh_settings"):
			card.refresh_settings()

func _update_cache_access_order(cache_key: int):
	_lru_counter += 1
	_cache_lru_tick[cache_key] = _lru_counter

func _evict_oldest_cache_entries(count: int):
	var to_evict = mini(count, _data_cache.size())
	if to_evict <= 0:
		return
	
	# Single-pass: collect all entries, sort by tick (ascending), then remove oldest
	# O(n log n) instead of O(n²) — for 5000 entries this is ~60k ops vs 25M
	var entries: Array[Array] = []
	for key in _cache_lru_tick.keys():
		entries.append([_cache_lru_tick[key], key])
	
	entries.sort_custom(func(a, b): return a[0] < b[0])
	
	for i in range(to_evict):
		var key = entries[i][1]
		_cache_lru_tick.erase(key)
		if _data_cache.has(key):
			var game = _data_cache[key]
			if game and game.romm_id != 0:
				_cached_game_ids.erase(game.romm_id)
			_data_cache.erase(key)
