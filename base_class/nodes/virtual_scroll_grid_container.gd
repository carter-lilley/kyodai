class_name VirtualScrollGridContainer
extends Control

# Global startup guard: suppresses all layout work until Main is ready for the
# single final settle. This prevents visible "jank" from layout passes before
# the saved window size and saved zoom are stable.
static var startup_layout_suppressed: bool = true

# Libraries below this size load all cards at once to avoid partial-row recycling
# edge cases. Above this threshold only visible cards plus a buffer are created.
const SMALL_LIBRARY_THRESHOLD: int = 50

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
		if _batching_layout:
			view_mode = value
			return
		if view_mode != value:
			view_mode = value
			_update_view_mode()

# Grid orientation toggle. Only affects GRID mode; LIST is always vertical, CAROUSEL always horizontal.
var grid_vertical: bool = true:
	set(value):
		if _batching_layout:
			grid_vertical = value
			return
		if value == grid_vertical:
			return
		grid_vertical = value
		if _ready_called and view_mode == ViewMode.GRID:
			_update_view_mode()
			refresh_dimensions()
			queue_redraw()

## Batch-apply grid orientation settings to avoid redundant rebuilds.
## Call this instead of setting view_mode/grid_vertical/focus_scale individually.
func set_grid_orientation(p_view_mode: ViewMode, p_grid_vertical: bool, p_focus_scale: float) -> void:
	var _old_focused: int = _last_focused_virtual_index
	var needs_refresh: bool = _apply_view_mode_and_vertical(p_view_mode, p_grid_vertical)
	needs_refresh = _apply_focus_scale(p_focus_scale) or needs_refresh

	if needs_refresh:
		_refresh_buffer(true)
		refresh_dimensions()
		queue_redraw()

# Layout-application helpers: mutate state without emitting side effects, returning true if changed.
# Used by set_grid_orientation and _batch_apply_layout_state to coalesce layout recalculations.
func _apply_view_mode_and_vertical(p_view_mode: ViewMode, p_grid_vertical: bool) -> bool:
	var changed: bool = false
	if view_mode != p_view_mode:
		_batching_layout = true
		view_mode = p_view_mode
		_batching_layout = false
		_configure_view_mode()
		changed = true
	if grid_vertical != p_grid_vertical:
		_batching_layout = true
		grid_vertical = p_grid_vertical
		_batching_layout = false
		if view_mode == ViewMode.GRID:
			_configure_view_mode()
		changed = true
	return changed

func _apply_focus_scale(p_focus_scale: float) -> bool:
	var clamped_scale: float = maxf(p_focus_scale, 1.0)
	if is_equal_approx(focus_scale, clamped_scale):
		return false
	_batching_layout = true
	focus_scale = clamped_scale
	_batching_layout = false
	return true

func _apply_zoom_ratio(p_ratio: float) -> bool:
	var max_ratio = _calculate_max_ratio()
	var clamped = clampf(p_ratio, 0.05, max_ratio)
	# During startup suppression we do NOT snap the saved zoom to the current
	# container size, because non-active grids can have a temporary small size
	# and would snap to the wrong stop. The final snap happens once when the
	# grid is explicitly settled after the window size is stable.
	var new_ratio = clamped if startup_layout_suppressed else _calculate_snapped_ratio(clamped)
	if debug_mode:
		print("[Grid] _apply_zoom_ratio: p_ratio=", p_ratio, " max_ratio=", max_ratio, " clamped=", clamped, " new_ratio=", new_ratio, " current_target=", target_card_width_ratio, " suppressed=", startup_layout_suppressed)
	if is_equal_approx(target_card_width_ratio, new_ratio):
		return false
	_batching_layout = true
	target_card_width_ratio = new_ratio
	_batching_layout = false
	return true

func _apply_grid_padding(p_padding: int) -> bool:
	var new_separation: int = int(M3Units.dp(float(p_padding)))
	if grid_separation != new_separation:
		grid_separation = new_separation
		if _flow_container:
			_flow_container.add_theme_constant_override("h_separation", grid_separation)
			_flow_container.add_theme_constant_override("v_separation", grid_separation)
		return true
	return false

func _batch_apply_layout_state() -> void:
	"""Apply all LAYOUT-affecting CardSettingsState fields in one pass.
	For structure changes this results in exactly one _recalculate_layout() call."""
	if not UIManager or not UIManager.card_settings_state:
		return
	var state = UIManager.card_settings_state

	var new_mode: ViewMode
	match state.layout_mode:
		0: new_mode = ViewMode.GRID
		1: new_mode = ViewMode.LIST
		2: new_mode = ViewMode.CAROUSEL
		_: new_mode = ViewMode.GRID

	# Apply structure first so zoom/padding math uses the correct geometry.
	# Then apply padding before zoom because separation affects available space.
	var _old_focused: int = _last_focused_virtual_index

	var structure_changed: bool = _apply_view_mode_and_vertical(new_mode, state.grid_vertical)
	var padding_changed: bool = _apply_grid_padding(state.grid_padding)
	if debug_mode:
		print("[Grid] _batch_apply_layout_state before zoom: target_ratio=", target_card_width_ratio, " base_size=", base_card_size, " card_size=", card_size, " state.zoom=", state.card_zoom_ratio, " state.level=", state.card_zoom_level)
	var zoom_changed: bool
	if new_mode == ViewMode.GRID and state.card_zoom_level >= 0:
		zoom_changed = _apply_zoom_level(state.card_zoom_level)
	else:
		zoom_changed = _apply_zoom_ratio(state.card_zoom_ratio)
	if debug_mode:
		print("[Grid] _batch_apply_layout_state after zoom: target_ratio=", target_card_width_ratio, " zoom_changed=", zoom_changed, " card_size=", card_size)
	var focus_changed: bool = _apply_focus_scale(1.0 + state.focus_scale_ratio)

	if not structure_changed and not zoom_changed and not padding_changed and not focus_changed:
		if debug_mode: print("[Grid] _batch_apply_layout_state: no changes (structure=", structure_changed, " zoom=", zoom_changed, " padding=", padding_changed, " focus=", focus_changed, ")")
		return

	if debug_mode:
		print("[Grid] _batch_apply_layout_state: structure=", structure_changed, " zoom=", zoom_changed, " padding=", padding_changed, " focus=", focus_changed)

	if structure_changed:
		# One rebuild path: configure flags then refresh buffer, which recalculates layout.
		_refresh_buffer(true)
		queue_redraw()
	else:
		# Non-structure changes share the same rebuild path to guarantee a single recalc.
		if focus_changed or padding_changed:
			_refresh_buffer(true)
		elif zoom_changed:
			_recalculate_layout()

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

# Track the last focused card's virtual index so we can restore it after layout recalculations.
var _last_focused_virtual_index: int = -1
var _viewport_focus_connection: Viewport = null

# Monotonically-increasing ID used to cancel stale deferred-focus requests.
var _focus_request_id: int = 0

# Pending focus target set by scroll_to_index_and_focus; applied as soon as the
# card is created by _on_scroll_value_changed.
var _pending_focus_index: int = -1

func is_focus_locked_and_active() -> bool:
	"""Returns true if UIManager has locked focus to this grid."""
	return UIManager and UIManager.is_focus_lock_active()

# Scale factor applied when a card is focused. Cards scale UP from their normal size
# by this amount. Edge overflow is prevented by focus-safe container margins.
var focus_scale: float = 1.08:
	set(value):
		if _batching_layout:
			focus_scale = value
			return
		var clamped_scale = maxf(value, 1.0)
		if not is_equal_approx(focus_scale, clamped_scale):
			focus_scale = clamped_scale
			_recalculate_layout()
			_refresh_buffer(true)

# Target card width as ratio of viewport (e.g., 0.15 = 15% of viewport width)
# This is the user-requested ratio, actual ratio may be snapped to fit whole cards
var target_card_width_ratio: float = 0.15:
	set(value):
		if _batching_layout:
			target_card_width_ratio = value
			return
		# Ensure cached display/ratio settings are fresh before snapping; direct
		# assignments from views can otherwise use stale base dimensions.
		_refresh_cached_settings()
		# Calculate dynamic max zoom (one card fills available space)
		var max_ratio = _calculate_max_ratio()
		var clamped = clampf(value, 0.05, max_ratio)
		# Calculate snapped ratio to ensure whole cards fit per row/column
		var snapped_ratio = _calculate_snapped_ratio(clamped)
		if debug_mode:
			print("[Grid] setter target_card_width_ratio: input=", value, " max_ratio=", max_ratio, " clamped=", clamped, " snapped=", snapped_ratio, " suppressed=", startup_layout_suppressed)
		# Always update ratio and recalculate - _recalculate_layout handles optimization
		target_card_width_ratio = snapped_ratio
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

# When true, public setters suppress their side effects so _batch_apply_layout_state()
# can apply multiple inputs and recalculate exactly once.
var _batching_layout: bool = false

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
var _visual_layer: Control
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

# Async buffer expansion: load only a small synchronous buffer at startup, then
# fill the rest of the visual buffer over subsequent frames to avoid a startup
# hitch while keeping the full scroll buffer.
const ASYNC_BUFFER_CARDS_PER_FRAME: int = 10
const STARTUP_BUFFER_LINES: int = 1
var _current_buffer_lines: int = visual_buffer_lines
var _pending_buffer_expansion: bool = false

# Async visual setup for off-screen cards: skip expensive refresh_settings/set_game
# during the synchronous layout, then finish setup a few cards per frame.
const ASYNC_SETUP_CARDS_PER_FRAME: int = 8
var _pending_visual_setup: Dictionary = {}

# Cached card capability flags — set once in _instantiate_card_pool() to avoid
# repeated has_method() and string lookups in hot loops.
var _card_has_focus_scale_enabled: bool = false
var _card_has_set_focus_scale: bool = false
var _card_has_set_game_with_priority: bool = false
var _card_has_refresh_settings: bool = false
var _card_has_reset: bool = false
var _card_has_game_prop: bool = false
var _card_has_update_media_panel_size: bool = false
var _card_has_update_display: bool = false
var _card_has_set_image_priority: bool = false
var _card_has_set_content_alignment: bool = false
var _card_has_set_media_aspect_ratio: bool = false
var _card_has_refresh_effects: bool = false
var _card_has_update_card_state_from_settings: bool = false
var _card_has_sync_visual_transform: bool = false
var _card_has_mark_visuals_position_synced: bool = false
var _card_has_begin_bulk_layout: bool = false
var _card_has_end_bulk_layout: bool = false

var _last_applied_zoom: float = 0.0  # Track last zoom to avoid unnecessary updates

# Layout input cache — used to skip redundant _recalculate_layout() work
var _last_layout_view_mode: ViewMode = ViewMode.GRID
var _last_layout_grid_vertical: bool = true
var _last_layout_focus_scale: float = 1.08
var _last_layout_card_size: Vector2 = Vector2.ZERO
var _last_layout_focused_card_size: Vector2 = Vector2.ZERO
var _last_layout_grid_separation: int = -1
var _last_layout_available_size: Vector2 = Vector2.ZERO

# Deterministic available size: when set, _get_available_size() returns this value
# instead of grid.size so layout can be computed before Godot propagates
# container sizes through the scene tree. Main, UIManager, and views set this
# explicitly at startup and at every layout-affecting transition.
var _deterministic_available_size: Vector2 = Vector2.ZERO

func _has_valid_available_size() -> bool:
	return (_deterministic_available_size.x > 0.0 and _deterministic_available_size.y > 0.0) or (size.x > 0 and size.y > 0)

var _last_layout_display_mode: int = -1
var _last_layout_media_aspect_ratio: int = -1
var _last_layout_total_items: int = -1

# Deferred layout recalc guard — coalesces multiple settings-driven recalc
# requests into a single call at the end of the frame.
var _layout_recalc_scheduled: bool = false

# Resize debounce timer — prevents rapid-fire recalculations during window resize
var _resize_debounce_timer: Timer = null
const RESIZE_DEBOUNCE_SECONDS: float = 0.05

# Scroll math cache — invalidated and recomputed inside _recalculate_layout()
var _cached_items_per_line: int = -1
var _cached_normal_stride: float = -1.0

# Margin caching - only update when margins actually change
var _last_margin_top: int = -1
var _last_margin_bottom: int = -1
var _last_margin_left: int = -1
var _last_margin_right: int = -1
var _last_flow_width: float = 0.0
var _last_flow_height: float = 0.0

# Cached settings — refreshed only when settings change (settings_saved signal)
var _cached_media_aspect_ratio: float = -1.0
var _cached_card_display_mode: int = 0
var _cached_content_alignment: M3Card.ContentAlignment = M3Card.ContentAlignment.START

# Cached visible/buffer range — updated in-place to avoid Dictionary allocations
var _visible_start_idx: int = 0
var _visible_end_idx: int = 0
var _buffer_target_start: int = 0
var _buffer_target_end: int = 0

# Incremental effect rebuild queue — populated when effect configs change.
# Cards in the visible zone rebuild immediately; the rest are drained over frames.
const EFFECT_REBUILD_BUFFER_LINES: int = 2
const EFFECT_REBUILD_CARDS_PER_FRAME: int = 2
var _pending_effect_rebuilds: Array[Control] = []
var _pending_effect_rebuild_force_full: bool = false
var _pending_effect_rebuild_set: Dictionary = {}

# Flow-container separation caching - only override when value changes
var _last_h_separation: int = -1
var _last_v_separation: int = -1

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

# When settings change, layout must settle before effect rebuilds run against
# final card bounds. This flag defers refresh_all_card_effects until after the
# scheduled layout recalc completes.
var _pending_effects_refresh_after_layout: bool = false
var _pending_effects_refresh_force_full: bool = false

func _configure_view_mode() -> void:
	"""Update scroll/flow container flags for the current view_mode/grid_vertical without rebuilding cards."""
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

func _update_view_mode() -> void:
	"""Apply view-mode configuration and rebuild the card buffer."""
	_configure_view_mode()
	_refresh_buffer(true)

func _update_flow_container_flags() -> void:
	if not _flow_container:
		return
	match view_mode:
		ViewMode.GRID:
			# GRID: FlowContainer fills the scroll direction to prevent side gaps
			if vertical:
				_flow_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				_flow_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			else:
				_flow_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				_flow_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
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

func _get_focus_scale_inverted() -> bool:
	# LIST/CAROUSEL: card starts at 1.0/focus_scale and grows to 1.0 when focused.
	# GRID: card starts at 1.0 and grows to focus_scale when focused.
	return view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL

func _get_available_size() -> Vector2:
	# During deterministic sizing, use the size supplied by Main/UIManager rather
	# than the grid's own size, which may not reflect the final container size yet.
	if _deterministic_available_size.x > 0.0 and _deterministic_available_size.y > 0.0:
		if debug_mode:
			print("[Grid] _get_available_size: using deterministic available size=", _deterministic_available_size)
		return _deterministic_available_size

	var result = Vector2(maxf(size.x, 1.0), maxf(size.y, 1.0))
	if debug_mode:
		print("[Grid] _get_available_size: vertical=", vertical, " size=", size, " result=", result)
	return result

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
	var line = int(float(idx) / items_per_line)
	return line * stride

func set_focused_card(virtual_index: int) -> void:
	if _focused_virtual_index == virtual_index:
		return
	_focused_virtual_index = virtual_index
	_update_layout()
	_update_margin()

func _ready():
	_setup_ui()

	# Use SystemManager.display as the single source of resize truth when available.
	# It debounces viewport changes so we don't recalculate layout on every pixel.
	if SystemManager.display:
		SystemManager.display.viewport_size_changed.connect(_on_display_size_changed)
	else:
		resized.connect(_on_resized)
		_setup_internal_resize_debounce()

	# Load initial grid separation and focus scale from settings
	# Use call_deferred to ensure DataManager is fully initialized
	call_deferred("_update_grid_separation_from_settings")
	call_deferred("_update_focus_scale_from_settings")
	call_deferred("_refresh_cached_settings")
	call_deferred("_connect_focus_lock_viewport")
	_ready_called = true

func _setup_internal_resize_debounce():
	_resize_debounce_timer = Timer.new()
	_resize_debounce_timer.one_shot = true
	_resize_debounce_timer.wait_time = RESIZE_DEBOUNCE_SECONDS
	_resize_debounce_timer.timeout.connect(_on_resize_debounced)
	add_child(_resize_debounce_timer)

func _on_resized():
	# Keep the top-level visual layer pinned to the viewport so it can draw
	# outside the grid's bounds without being clipped by margins or scroll.
	if _visual_layer and _visual_layer.top_level:
		_visual_layer.position = Vector2.ZERO
		_visual_layer.size = get_viewport_rect().size

	# Ignore resize events that don't actually change size (sub-pixel or duplicate)
	var new_size = Vector2(size.x, size.y)
	if is_equal_approx(new_size.x, _last_resized_size.x) and is_equal_approx(new_size.y, _last_resized_size.y):
		return

	# Ignore tiny size jitters that don't meaningfully affect layout.
	if abs(new_size.x - _last_resized_size.x) < RESIZE_IGNORE_DELTA and abs(new_size.y - _last_resized_size.y) < RESIZE_IGNORE_DELTA:
		return

	_last_resized_size = new_size

	# Debounce rapid resize events (e.g. during window resize or layout transitions)
	if _resize_debounce_timer:
		_resize_debounce_timer.start()

func _on_display_size_changed(_new_size: Vector2):
	"""Handler for SystemManager.display's debounced viewport_size_changed signal."""
	if startup_layout_suppressed:
		return

	# Keep the top-level visual layer pinned to the viewport.
	if _visual_layer and _visual_layer.top_level:
		_visual_layer.position = Vector2.ZERO
		_visual_layer.size = get_viewport_rect().size

	# Ignore resize events that don't actually change this container's size.
	var new_size = Vector2(size.x, size.y)
	if is_equal_approx(new_size.x, _last_resized_size.x) and is_equal_approx(new_size.y, _last_resized_size.y):
		return

	# Ignore tiny size jitters that don't meaningfully affect layout.
	if abs(new_size.x - _last_resized_size.x) < RESIZE_IGNORE_DELTA and abs(new_size.y - _last_resized_size.y) < RESIZE_IGNORE_DELTA:
		return

	_last_resized_size = new_size

	# Run the same debounced logic the internal timer used to trigger.
	_on_resize_debounced()

func _enter_tree():
	# Connect to centralized card settings state (idempotent via is_connected guards)
	if UIManager and UIManager.card_settings_state:
		var state = UIManager.card_settings_state
		if not state.changed.is_connected(_on_card_settings_state_changed):
			state.changed.connect(_on_card_settings_state_changed)
	# If the grid was reparented, the pool was freed in _exit_tree().
	# Recreate it so cards can be reused again. On initial entry _card_scene is
	# still null, so this is a no-op.
	if _card_scene and _card_pool.is_empty():
		_instantiate_card_pool()

	# Reset cached size so the next display resize check will recalculate layout
	# (the current parent may give us a different size than before reparenting).
	_last_resized_size = Vector2.ZERO
	if SystemManager.display:
		_on_display_size_changed(SystemManager.display.get_viewport_size())
	# Ensure focus-lock viewport signal is active after reparenting.
	_reconnect_focus_lock_viewport()

func _exit_tree():
	if UIManager and UIManager.card_settings_state:
		var state = UIManager.card_settings_state
		if state.changed.is_connected(_on_card_settings_state_changed):
			state.changed.disconnect(_on_card_settings_state_changed)
	_disconnect_focus_lock_viewport()
	# Release scene-wide focus lock if this grid held it.
	if UIManager:
		UIManager.exit_focus_lock(self)
	# Always free the pooled cards when leaving the tree. Pooled nodes are not in
	# the tree, so they would not be cleaned up automatically. Use free() because
	# queue_free() may not flush during process exit.
	for card in _card_pool:
		if is_instance_valid(card):
			card.free()
	_card_pool.clear()

	# Only clear active-card tracking when the grid is being destroyed. When the
	# grid is reparented (e.g. nav type change), the active cards stay in the
	# FlowContainer and _active_cards keeps pointing to them so the next
	# _recalculate_layout can recycle/update them. Clearing this while leaving the
	# cards in the tree produces stale blank cards that are not tracked.
	if is_queued_for_deletion():
		_active_cards.clear()
		_active_cards_by_index.clear()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		if UIManager:
			UIManager.exit_focus_lock(self)

func _free_card_pool() -> void:
	"""Release pooled card references.
	Pooled nodes are not in the tree, so they must be freed explicitly.
	Use free() because these nodes are not displayed and queue_free() may not
	process before the rendering server shuts down at engine exit."""
	var _freed_count: int = 0
	for card in _card_pool:
		if is_instance_valid(card):
			card.free()
			_freed_count += 1
	_card_pool.clear()

func clear_pool() -> void:
	"""Public hook to free pooled cards before the grid leaves the tree.

	Useful during app shutdown to release heavy card resources early.
	"""
	_free_card_pool()

func _on_card_settings_state_changed(mask: int) -> void:
	if not UIManager or not UIManager.card_settings_state:
		return

	var state = UIManager.card_settings_state

	if debug_mode:
		print("[Grid] settings changed mask=", mask, " display_mode=", state.display_mode, " media_ratio=", state.media_aspect_ratio, " cached_display=", _cached_card_display_mode, " cached_ratio=", _cached_media_aspect_ratio)

	# Refresh cached media/display settings before any layout work so that
	# _batch_apply_layout_state() snaps target_card_width_ratio against the
	# correct base dimensions.
	_refresh_cached_settings()

	if debug_mode:
		print("[Grid] after refresh cached display=", _cached_card_display_mode, " cached_ratio=", _cached_media_aspect_ratio)

	# Layout-affecting settings: orientation, zoom, padding, focus scale
	if mask & CardSettingsState.ChangeMask.LAYOUT:
		if debug_mode: print("[Grid] applying LAYOUT batch, target_ratio before=", target_card_width_ratio)
		_batch_apply_layout_state()
		if debug_mode:
			print("[Grid] after LAYOUT batch, target_ratio=", target_card_width_ratio, " card_size=", card_size, " base_card_size=", base_card_size)

	# Display mode / content alignment / media aspect ratio
	if mask & (CardSettingsState.ChangeMask.DISPLAY | CardSettingsState.ChangeMask.MEDIA_SHAPE):
		refresh_all_card_configs()
		# Queue effect rebuilds for the whole grid so cards outside the visible
		# buffer pick up new effects/geometry when they scroll back in.
		refresh_all_card_effects(true)
		_schedule_layout_recalc()

	# Card effect configuration changed. Defer the effect refresh until after the
	# layout recalc so cards are rebuilt against final bounds and newly added cards
	# are included in the refresh snapshot.
	if mask & CardSettingsState.ChangeMask.EFFECTS:
		_pending_effects_refresh_after_layout = true
		_pending_effects_refresh_force_full = true
		_schedule_layout_recalc()

func _schedule_layout_recalc() -> void:
	"""Queue a single deferred layout recalc. Multiple calls in one frame collapse."""
	if _layout_recalc_scheduled:
		return
	_layout_recalc_scheduled = true
	call_deferred("_do_scheduled_layout_recalc")

func _do_scheduled_layout_recalc() -> void:
	_layout_recalc_scheduled = false
	_recalculate_layout()
	
	# Now that layout has settled, apply any deferred effect refresh. This ensures
	# effect rebuilds use final card bounds and include cards added during recalc.
	if _pending_effects_refresh_after_layout:
		_pending_effects_refresh_after_layout = false
		refresh_all_card_effects(_pending_effects_refresh_force_full)

func _refresh_cached_settings() -> void:
	if not UIManager or not UIManager.card_settings_state:
		return

	var state = UIManager.card_settings_state
	var idx = clampi(state.media_aspect_ratio, 0, _RATIO_LOOKUP.size() - 1)
	_cached_media_aspect_ratio = _RATIO_LOOKUP[idx]
	_cached_card_display_mode = clampi(state.display_mode, 0, 2)
	_cached_content_alignment = clampi(state.content_alignment, 0, 2) as M3Card.ContentAlignment

	# Initialize last-layout tracking on the first cache so the first real
	# layout doesn't treat the initial state as a "change" and re-snap the
	# saved zoom to a different stop.
	if _last_layout_display_mode < 0:
		_last_layout_display_mode = _cached_card_display_mode
	if _last_layout_media_aspect_ratio < 0:
		_last_layout_media_aspect_ratio = state.media_aspect_ratio

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

# Throttle window resize: ignore tiny size jitters and avoid duplicate back-to-back
# recalculations caused by scrollbar visibility toggling.
var _resize_debounce_frames: int = 0
const RESIZE_IGNORE_DELTA: float = 2.0
const RESIZE_FRAME_DELAY: int = 1

func _process(_delta: float):
	if _resize_debounce_frames > 0:
		_resize_debounce_frames -= 1
		if _resize_debounce_frames == 0:
			_on_resize_debounced()

	# Add off-screen buffer cards a few at a time so startup isn't blocked by
	# creating the entire visual buffer in one frame.
	_process_buffer_expansion()

	# Top up the card pool a few per frame after zoom-out/resize grew the layout.
	_process_pool_growth()

	# Finish deferred visual setup for off-screen buffer cards.
	_process_pending_visual_setup()

	# Drain any queued off-screen effect rebuilds a few cards per frame.
	_drain_pending_effect_rebuilds()

func _on_resize_debounced():
	if debug_mode:
		print("[Grid] _on_resize_debounced: size=", size, " target_ratio=", target_card_width_ratio, " suppressed=", startup_layout_suppressed)
	if size.y > 0:
		if debug_mode:
			_log_parent_chain_sizes()
	if startup_layout_suppressed:
		return
	# Prevent re-entrant layout recalculations.
	if _is_recalculating_layout:
		return

	# Update the cached size so later viewport_size_changed events can de-duplicate.
	_last_resized_size = Vector2(size.x, size.y)

	# Re-snap zoom ratio to a valid stop for the new available size and recalculate once.
	# Use the deterministic available size when possible so the snap is based on
	# the viewport and chrome, not on the grid's possibly-stale local size.
	# Keep it set so later layout passes do not fall back to a transient size.
	var available := Vector2.ZERO
	if UIManager:
		available = UIManager.compute_grid_available_size(self, null)
	set_deterministic_available_size(available if available.x > 0 and available.y > 0 else _get_available_size())
	if view_mode == ViewMode.GRID and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
		target_card_width_ratio = _get_snap_ratio_for_level(UIManager.card_settings_state.card_zoom_level)
	else:
		target_card_width_ratio = _calculate_snapped_ratio(target_card_width_ratio)

	# If we have items but no active cards (e.g., view was hidden during setup), load them now
	if _active_cards.size() == 0 and _total_items > 0 and _has_valid_available_size():
		_initial_load()
		_recalculate_layout()

func _log_parent_chain_sizes() -> void:
	var labels = ["grid", "vbox", "margin", "view", "tab_page", "tab_container", "main_vbox", "outer_margin", "content_wrapper"]
	var current: Node = self
	var i := 0
	while current != null and i < labels.size():
		print("[Grid] layout chain ", labels[i], " size=", current.size)
		current = current.get_parent()
		i += 1

func settle_startup() -> void:
	"""Run the single startup layout and snap the saved zoom to a valid stop.
	
	Main calls this once after the final window size is known so the grid
	settles at a valid internal snap stop for the current viewport, while the
	slider and saved zoom stay consistent."""
	print("[Grid] settle_startup: size=", size, " target_ratio=", target_card_width_ratio)
	if _is_recalculating_layout:
		return

	# Update the cached size so later viewport_size_changed events can de-duplicate.
	_last_resized_size = Vector2(size.x, size.y)

	# Snap the saved zoom to a valid stop for the final available size. In grid
	# mode use the current level so all views settle at the same zoom level.
	if view_mode == ViewMode.GRID and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
		target_card_width_ratio = _get_snap_ratio_for_level(UIManager.card_settings_state.card_zoom_level)
	else:
		target_card_width_ratio = _calculate_snapped_ratio(target_card_width_ratio)

	# If we have items but no active cards (e.g., view was hidden during setup), load them now.
	if _active_cards.size() == 0 and _total_items > 0 and _has_valid_available_size():
		_initial_load()
		_recalculate_layout()

func settle_startup_with_buffer(startup_buffer_lines: int) -> void:
	"""Run the startup layout with a smaller buffer, then expand asynchronously.

	This creates only the visible cards plus a small synchronous buffer at
	startup, then fills the rest of the visual buffer over subsequent frames
	so the initial frame is not blocked by dozens of off-screen cards."""
	print("[Grid] settle_startup_with_buffer: startup_buffer_lines=", startup_buffer_lines, " final_buffer_lines=", visual_buffer_lines)
	var previous_buffer_lines: int = _current_buffer_lines
	_current_buffer_lines = startup_buffer_lines
	settle_startup()
	_current_buffer_lines = previous_buffer_lines
	_expand_buffer_async()

func _expand_buffer_async() -> void:
	"""Schedule the remaining off-screen buffer cards to be added over frames."""
	_pending_buffer_expansion = true

func _process_buffer_expansion() -> void:
	if not _pending_buffer_expansion:
		return
	if _active_cards.size() == 0 or _total_items == 0:
		_pending_buffer_expansion = false
		return
	if not _scroll_container:
		_pending_buffer_expansion = false
		return

	var scroll_pos = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()
	var available = _get_available_size()
	var viewport_size = available.y if vertical else available.x
	_compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
	var current_first = _active_cards[0].get_meta("virtual_index", 0)

	if debug_mode:
		print("[Grid] _process_buffer_expansion: target_start=", _buffer_target_start, " target_end=", _buffer_target_end, " current_first=", current_first, " current_last=", current_last)

	var added: int = 0
	while current_last < _buffer_target_end - 1 and current_last < _total_items - 1 and added < ASYNC_BUFFER_CARDS_PER_FRAME:
		_add_card_at_end(current_last + 1)
		current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		added += 1

	current_first = _active_cards[0].get_meta("virtual_index", 0)
	while current_first > _buffer_target_start and current_first > 0 and added < ASYNC_BUFFER_CARDS_PER_FRAME:
		_add_card_at_start(current_first - 1)
		current_first = _active_cards[0].get_meta("virtual_index", 0)
		added += 1

	if debug_mode:
		print("[Grid] _process_buffer_expansion: added=", added, " current_first=", current_first, " current_last=", current_last)

	# Keep the internal virtual range consistent with the active card list so
	# later scroll/recycle math and preload checks don't use stale bounds.
	if _active_cards.size() > 0:
		_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
		_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)

	if added > 0:
		_request_missing_data()
		_update_margin()
		_check_preload_needed()
		_update_card_priorities(_visible_start_idx, _visible_end_idx)
		_update_visual_draw_order()
		_flush_pending_visual_setup_for_visible_zone()
		# Newly added off-screen cards need their visual-layer positions synced
		# after the FlowContainer sort runs, otherwise the visual layer stays at
		# the origin until a scroll/recycle forces a sync.
		call_deferred("_sync_and_mark_card_visual_transforms")

	if current_first <= _buffer_target_start and current_last >= _buffer_target_end - 1:
		_pending_buffer_expansion = false
		print("[Grid] async buffer expansion complete")

func _process_pending_visual_setup() -> void:
	if _pending_visual_setup.is_empty():
		return

	if debug_mode:
		print("[Grid] _process_pending_visual_setup: pending_size=", _pending_visual_setup.size())
	var processed: int = 0
	var keys := _pending_visual_setup.keys()
	while processed < ASYNC_SETUP_CARDS_PER_FRAME and not keys.is_empty():
		var idx = keys[0]
		keys.remove_at(0)
		var card = _pending_visual_setup[idx]
		if not is_instance_valid(card) or not _active_cards.has(card):
			_pending_visual_setup.erase(idx)
			continue
		var setup_ok = _apply_card_visual_setup(card, idx)
		if debug_mode: print("[Grid] _process_pending_visual_setup: idx=", idx, " setup_ok=", setup_ok)
		if setup_ok:
			_pending_visual_setup.erase(idx)
			processed += 1
	if debug_mode:
		print("[Grid] _process_pending_visual_setup: processed=", processed, " remaining=", _pending_visual_setup.size())

func _flush_pending_visual_setup_for_visible_zone() -> void:
	if _pending_visual_setup.is_empty():
		return

	_get_visible_range()
	var items_per_line: int = _get_items_per_line()
	var sync_start: int = maxi(0, _visible_start_idx - items_per_line)
	var sync_end: int = mini(_visible_end_idx + items_per_line, _total_items)

	var completed: Array = []
	for idx in _pending_visual_setup:
		if idx >= sync_start and idx < sync_end:
			var card = _pending_visual_setup[idx]
			if is_instance_valid(card) and _active_cards.has(card):
				if _apply_card_visual_setup(card, idx):
					completed.append(idx)
			else:
				completed.append(idx)
	for idx in completed:
		_pending_visual_setup.erase(idx)

func _update_grid_separation_from_settings() -> void:
	var padding: int = UIManager.card_settings_state.grid_padding if UIManager and UIManager.card_settings_state else 10
	_apply_grid_padding(padding)

func _update_focus_scale_from_settings() -> void:
	if UIManager and UIManager.card_settings_state:
		focus_scale = 1.0 + UIManager.card_settings_state.focus_scale_ratio
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
	if not _has_valid_available_size():
		return 0.5

	var base_dims = _get_base_dimensions_for_mode()

	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return 0.5

	var available = _get_available_size()
	var viewport_area = available.x * available.y

	# Cap at 2 cards per line — never allow a single card to fill the viewport.
	var ratio = _compute_ratio_for_items_per_line(2, base_dims, available, viewport_area)

	return max(ratio, 0.05)

## Returns all possible snap ratios for the current viewport configuration.
## Each ratio corresponds to a whole number of cards per line.
## Used to populate discrete slider stops that match grid snap behavior.
func get_snap_ratios() -> Array[float]:
	if not _has_valid_available_size():
		return []

	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		# No discrete snapping in these modes
		return []

	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var viewport_area = available.x * available.y

	# Determine max items per line based on minimum card size (15% of base)
	var max_items_per_line: int
	if vertical:
		var min_item_width = base_dims.x * 0.15 + grid_separation
		max_items_per_line = max(1, int(available.x / min_item_width))
	else:
		var min_item_height = base_dims.y * 0.15 + grid_separation
		max_items_per_line = max(1, int(available.y / min_item_height))

	var ratios: Array[float] = []

	# Cap at a reasonable number so the slider doesn't have too many stops,
	# but ensure at least 2 distinct ratios for a usable zoom range.
	# If the viewport can only fit 1-2 items, don't artificially cap — let
	# the natural limits determine the range.
	var max_stops: int = 6
	if max_items_per_line <= 2:
		# Very small viewport: allow all natural stops so user has some range
		max_stops = max_items_per_line
	# Ensure at least 2 items per line so the loop always produces ratios.
	# On very small viewports, max_items_per_line can be 1, which would make
	# range(2, 2) empty and return zero ratios.
	var capped_max = max(2, min(max_items_per_line, max_stops))

	for items_per_line in range(2, capped_max + 1):
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

## Returns snap ratios sorted ascending (index 0 = most items per line).
## get_snap_ratios() returns descending ratios; this helper reverses them so
## the slider index maps directly to a zoom level.
func _get_snap_ratios_ascending() -> Array[float]:
	var snap_ratios := get_snap_ratios()
	snap_ratios.reverse()
	return snap_ratios

## Returns the snap ratio for the given zoom level using the current grid's
## available size. Used to apply the shared zoom level across views.
func _get_snap_ratio_for_level(level: int) -> float:
	var snap_ratios := _get_snap_ratios_ascending()
	if snap_ratios.is_empty():
		return target_card_width_ratio
	return snap_ratios[clampi(level, 0, snap_ratios.size() - 1)]

## Applies the given zoom level by setting target_card_width_ratio to the
## corresponding snap ratio. Returns true if the ratio changed.
func _apply_zoom_level(p_level: int) -> bool:
	var snap_ratios := _get_snap_ratios_ascending()
	if snap_ratios.is_empty():
		return false
	var new_ratio := snap_ratios[clampi(p_level, 0, snap_ratios.size() - 1)]
	if is_equal_approx(target_card_width_ratio, new_ratio):
		return false
	_batching_layout = true
	target_card_width_ratio = new_ratio
	_batching_layout = false
	return true

## Compute the exact snap ratio for a given number of items per line.
func _compute_ratio_for_items_per_line(items_per_line: int, base_dims: Vector2, available: Vector2, viewport_area: float) -> float:
	# Compute card dimensions that exactly fill the available space for the
	# given items_per_line. No focus-overflow subtraction here so cards fill
	# the viewport edge-to-edge. Focused edge cards may clip slightly.
	var final_card_width: float
	var final_card_height: float

	if vertical:
		var target_item_width = (available.x - (items_per_line - 1) * grid_separation) / items_per_line
		final_card_width = target_item_width
		final_card_height = final_card_width * (base_dims.y / base_dims.x)
	else:
		var target_item_height = (available.y - (items_per_line - 1) * grid_separation) / items_per_line
		final_card_height = target_item_height
		final_card_width = final_card_height * (base_dims.x / base_dims.y)

	final_card_width = max(final_card_width, base_dims.x * 0.1)
	final_card_height = max(final_card_height, base_dims.y * 0.1)

	var target_card_area = final_card_width * final_card_height
	var ratio = sqrt(target_card_area / viewport_area)

	return max(ratio, 0.05)

func _calculate_snapped_ratio(desired_ratio: float) -> float:
	if not _has_valid_available_size():
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

	# Use same formula as _get_items_per_line() for consistency
	var effective_width = maxf(1.0, available.x + grid_separation)
	var effective_height = maxf(1.0, available.y + grid_separation)

	var desired_item_width = desired_card_width + grid_separation
	var desired_item_height = desired_card_height + grid_separation

	var desired_items_per_line: int
	if vertical:
		desired_items_per_line = max(2, int(effective_width / desired_item_width + 0.0001))
	else:
		desired_items_per_line = max(2, int(effective_height / desired_item_height + 0.0001))

	# Use the exact same helper for consistency
	return _compute_ratio_for_items_per_line(desired_items_per_line, base_dims, available, viewport_area)

func _recalculate_layout():
	var start_us := Time.get_ticks_usec()
	if startup_layout_suppressed:
		return
	if _is_recalculating_layout:
		return
	if not _flow_container or not _scroll_container:
		return
	if not _has_valid_available_size():
		return

	# Ensure cached settings are fresh before any layout math
	_refresh_cached_settings()

	# Defensive: if display mode or media aspect ratio changed, re-snap the target
	# ratio so layout uses a valid stop for the new base dimensions.
	if UIManager and UIManager.card_settings_state:
		var layout_state = UIManager.card_settings_state
		if layout_state.display_mode != _last_layout_display_mode or layout_state.media_aspect_ratio != _last_layout_media_aspect_ratio:
			var max_ratio = _calculate_max_ratio()
			var clamped = clampf(target_card_width_ratio, 0.05, max_ratio)
			var snapped_ratio = _calculate_snapped_ratio(clamped)
			if not is_equal_approx(target_card_width_ratio, snapped_ratio):
				_batching_layout = true
				target_card_width_ratio = snapped_ratio
				_batching_layout = false

	_is_recalculating_layout = true
	_suppress_recycle_until_frame = Engine.get_process_frames() + 1

	# Save focus state before layout recalculation so we can restore it after
	# cards are recycled and recreated.
	var saved_focus_index: int = _get_focused_virtual_index()

	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions_for_mode()

	if debug_mode:
		print("[Grid] _recalculate_layout: zoom=", current_zoom, " target_ratio=", target_card_width_ratio, " base_dims=", base_dims, " view_mode=", view_mode, " vertical=", vertical, " available=", _get_available_size(), " elapsed_us=", Time.get_ticks_usec() - start_us)

	if current_zoom <= 0:
		push_warning("[VirtualScrollGridContainer] Invalid zoom value: %f, skipping layout" % current_zoom)
		_is_recalculating_layout = false
		return

	base_card_size = base_dims

	match view_mode:
		ViewMode.GRID:
			card_size = base_dims * current_zoom
			focused_card_size = card_size * focus_scale
		ViewMode.LIST:
			# LIST: normal card is smaller so focused card fills viewport exactly.
			# Focus overflow = (focused - normal) / 2, and focused width = available.x.
			var card_width = _get_available_size().x / focus_scale
			card_size = Vector2(card_width, base_dims.y * current_zoom)
			focused_card_size = card_size * focus_scale
		ViewMode.CAROUSEL:
			# CAROUSEL: normal card is smaller so focused card fills viewport exactly.
			# Focus overflow = (focused - normal) / 2, and focused height = available.y.
			var card_height = _get_available_size().y / focus_scale
			card_size = Vector2(base_dims.x * current_zoom, card_height)
			focused_card_size = card_size * focus_scale

	var available = _get_available_size()

	# Determine which parts of the layout actually changed
	var structure_changed = view_mode != _last_layout_view_mode or grid_vertical != _last_layout_grid_vertical
	var focus_changed = not is_equal_approx(focus_scale, _last_layout_focus_scale)
	var card_geometry_changed = not card_size.is_equal_approx(_last_layout_card_size) or not focused_card_size.is_equal_approx(_last_layout_focused_card_size)
	var separation_changed = grid_separation != _last_layout_grid_separation
	var available_changed = not available.is_equal_approx(_last_layout_available_size)
	var total_items_changed = _total_items != _last_layout_total_items

	# Display mode and media aspect ratio affect base card dimensions, which
	# feed into card_geometry_changed. Cache them explicitly so a recalc that
	# runs after these settings change cannot be skipped incorrectly.
	var state = UIManager.card_settings_state if UIManager else null
	var current_display_mode = state.display_mode if state else _cached_card_display_mode
	var current_media_ratio = state.media_aspect_ratio if state else 0
	var display_or_ratio_changed = current_display_mode != _last_layout_display_mode or current_media_ratio != _last_layout_media_aspect_ratio

	if debug_mode:
		print("[Grid] _recalculate_layout changes: structure=", structure_changed, " focus=", focus_changed, " card_geom=", card_geometry_changed, " separation=", separation_changed, " available=", available_changed, " display_or_ratio=", display_or_ratio_changed, " total_items=", total_items_changed)

	if not structure_changed and not focus_changed and not card_geometry_changed and not separation_changed and not available_changed and not display_or_ratio_changed and not total_items_changed:
		_is_recalculating_layout = false
		return

	# Update the input cache now that we know work is required
	_last_layout_view_mode = view_mode
	_last_layout_grid_vertical = grid_vertical
	_last_layout_focus_scale = focus_scale
	_last_layout_card_size = card_size
	_last_layout_focused_card_size = focused_card_size
	_last_layout_grid_separation = grid_separation
	_last_layout_available_size = available
	_last_layout_display_mode = current_display_mode
	_last_layout_media_aspect_ratio = current_media_ratio
	_last_layout_total_items = _total_items

	# Invalidate then pre-compute scroll math before downstream consumers read it
	_cached_items_per_line = -1
	_cached_normal_stride = -1.0
	_cached_items_per_line = _get_items_per_line()
	_cached_normal_stride = _get_normal_stride()

	if debug_mode:
		print("[Grid] _recalculate_layout: available=", available, " card_size=", card_size, " item_width=", item_width, " item_height=", item_height, " items_per_line=", _cached_items_per_line, " normal_stride=", _cached_normal_stride)

	if _cached_items_per_line == 1:
		push_warning("[Grid] COLLAPSE DETECTED: items_per_line=1, available=%s, card_size=%s, item_width=%s, item_height=%s" % [available, card_size, item_width, item_height])

	# Only override separation theme constants when the value actually changed
	if grid_separation != _last_h_separation:
		_flow_container.add_theme_constant_override("h_separation", grid_separation)
		_last_h_separation = grid_separation
	if grid_separation != _last_v_separation:
		_flow_container.add_theme_constant_override("v_separation", grid_separation)
		_last_v_separation = grid_separation

	_update_layout()
	_update_margin()
	_flow_container.queue_sort()
	var _active_before: int = _active_cards.size()
	var _first_before: int = -1
	var _last_before: int = -1
	if _active_cards.size() > 0:
		_first_before = _active_cards[0].get_meta("virtual_index", -1)
		_last_before = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)
	# Always recycle cards that fall outside the new buffer target during a layout
	# recalculation. A preset can reset the scroll position while the active cards
	# still hold indices from the previous scroll offset; without recycling, the
	# grid prepends a large range of stale blank cards instead of rebuilding the
	# correct visible range. The end-of-frame ScrollContainer clamp signal is still
	# suppressed by _suppress_recycle_until_frame, so this does not cause extra
	# recycling from that deferred signal.
	if vertical:
		_on_scroll_value_changed(_scroll_container.scroll_vertical, true)
	else:
		_on_scroll_value_changed(_scroll_container.scroll_horizontal, true)
	var _active_after: int = _active_cards.size()
	var _first_after: int = -1
	var _last_after: int = -1
	if _active_cards.size() > 0:
		_first_after = _active_cards[0].get_meta("virtual_index", -1)
		_last_after = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)

	if not is_equal_approx(current_zoom, _last_applied_zoom):
		_last_applied_zoom = current_zoom

	var update_card_geometry = card_geometry_changed or structure_changed
	var update_focus = focus_changed

	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		if _card_has_focus_scale_enabled:
			card.focus_scale_enabled = true
			card.focus_scale_inverted = _get_focus_scale_inverted()
		if update_focus and _card_has_set_focus_scale:
			card.set_focus_scale(focus_scale)
		if update_card_geometry:
			_configure_card_size_flags(card)
			# Force immediate media-panel refresh so the effect stack picks up the
			# new bounds without waiting for Godot's deferred layout pass.
			if _card_has_update_media_panel_size:
				card._update_media_panel_size(true)

	_is_recalculating_layout = false
	_update_visual_draw_order()
	_ensure_pool_capacity()
	# Sync and reveal visual items after the deferred FlowContainer sort has run.
	# Relying only on NOTIFICATION_TRANSFORM_CHANGED misses some rebuild paths.
	call_deferred("_sync_and_mark_card_visual_transforms")

	# Restore focus to the card that was focused before layout recalculation.
	# scroll_to_index_and_focus waits for the target card to exist and suppresses
	# the smooth-scroll response, avoiding focus loss during long centering tweens.
	if saved_focus_index >= 0:
		call_deferred("scroll_to_index_and_focus", saved_focus_index, false)

func _get_items_per_line() -> int:
	if not _scroll_container:
		return 1
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return 1
	if _cached_items_per_line > 0:
		return _cached_items_per_line

	var available = _get_available_size()
	if vertical:
		var effective_width = maxf(1.0, available.x + grid_separation)
		var result = max(1, int(effective_width / item_width + 0.0001))
		if debug_mode:
			print("[Grid] _get_items_per_line: vertical effective_width=", effective_width, " item_width=", item_width, " result=", result)
		return result
	else:
		var effective_height = maxf(1.0, available.y + grid_separation)
		var result = max(1, int(effective_height / item_height + 0.0001))
		if debug_mode:
			print("[Grid] _get_items_per_line: horizontal effective_height=", effective_height, " item_height=", item_height, " result=", result)
		return result

func _get_media_aspect_ratio() -> float:
	return _cached_media_aspect_ratio

func _get_card_display_mode() -> int:
	return _cached_card_display_mode

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
	return _cached_content_alignment

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
	var available := _get_available_size()
	if vertical:
		var viewport_height = available.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		return (visible_rows * items_per_line) + 1
	else:
		var viewport_width = available.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		return (visible_cols * items_per_line) + 1

## Returns the number of items that fit in the current viewport
func get_visible_count() -> int:
	return _get_visible_count()

func _setup_ui():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	z_index = -1

	_scroll_container = SmoothScrollContainer.new()
	_scroll_container.vertical = vertical
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.scroll_vertical = 0
	_scroll_container.clip_contents = true
	# Scrollbar is not needed; navigation uses mouse wheel, keyboard, or controller.
	# Hiding it removes the scrollbar-width feedback loop from the layout math.
	_scroll_container.vertical_scroll_mode = ScrollContainer.ScrollMode.SCROLL_MODE_SHOW_NEVER
	_scroll_container.horizontal_scroll_mode = ScrollContainer.ScrollMode.SCROLL_MODE_SHOW_NEVER

	_visual_layer = Control.new()
	_visual_layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_visual_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_visual_layer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_visual_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_visual_layer.clip_contents = false
	_visual_layer.z_index = -1
	_visual_layer.top_level = true
	add_child(_visual_layer)
	_visual_layer.position = Vector2.ZERO
	_visual_layer.size = get_viewport_rect().size

	add_child(_scroll_container)

	# Make the scroll container panel transparent so the visual layer behind it is visible.
	_scroll_container.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

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

func get_visual_layer_rid() -> RID:
	if _visual_layer and _visual_layer.is_inside_tree():
		return _visual_layer.get_canvas_item()
	return RID()

func _get_base_dimensions() -> Vector2:
	return Vector2(BASE_CARD_WIDTH_DP, BASE_CARD_HEIGHT_DP)

func refresh_dimensions() -> void:
	"""Recalculate dimensions and refresh layout (call after orientation change or margin change)."""
	# Ensure cached settings are fresh before any layout math
	_refresh_cached_settings()

	# Update grid separation from settings
	_update_grid_separation_from_settings()

	# Reset FlowContainer's custom_minimum_size to force recalculation with current viewport size
	# This fixes issues where layout was calculated while view was hidden (size=0)
	if _flow_container:
		_flow_container.custom_minimum_size = Vector2(0, 0)
		# Also reset the cached flow dimensions so _update_margin() restores the
		# correct custom_minimum_size instead of skipping because the old value matches.
		_last_flow_width = 0.0
		_last_flow_height = 0.0

	# Re-snap zoom to ensure it fits the new dimensions/margins
	var current_ratio = target_card_width_ratio
	var snapped_ratio = _calculate_snapped_ratio(current_ratio)
	# Force a full layout pass. The layout cache in _recalculate_layout() can
	# otherwise skip _update_layout() if visible geometry hasn't changed, leaving
	# the FlowContainer's custom_minimum_size at the zero we just set above.
	_last_layout_available_size = Vector2.ZERO
	# Always update ratio - the setter will handle recalculation
	target_card_width_ratio = snapped_ratio

	var current_zoom = _calculate_zoom()
	var zoom_changed = not is_equal_approx(current_zoom, _last_applied_zoom)
	if zoom_changed:
		_last_applied_zoom = current_zoom

	# _recalculate_layout() (triggered by the target_card_width_ratio setter above)
	# already loops through active cards and calls refresh_settings(), so the
	# manual refresh loop that used to live here was completely redundant.

func setup(card_scene_resource: PackedScene, total_items: int, initial_target_ratio: float = -1.0):
	_card_scene = card_scene_resource
	_total_items = total_items

	# If a caller supplies an initial zoom ratio, apply it directly without
	# snapping so the grid starts at the saved user zoom. The final snap to a
	# valid stop happens once when the window size is stable and the grid is
	# explicitly settled.
	if initial_target_ratio >= 0.0:
		var max_ratio = _calculate_max_ratio()
		var clamped = clampf(initial_target_ratio, 0.05, max_ratio)
		print("[Grid] setup initial_target_ratio=", initial_target_ratio, " clamped=", clamped)
		_batching_layout = true
		target_card_width_ratio = clamped
		_batching_layout = false

	# When startup is orchestrated by Main, defer pool creation until the final
	# available size is known so the pool is sized for the real viewport instead
	# of the grid's pre-layout size. Main will call _instantiate_card_pool()
	# explicitly during the single settle pass.
	if not startup_layout_suppressed:
		_instantiate_card_pool()

	# Wait for container sizing before initial load only when startup is not being
	# orchestrated. Main suppresses layout and settles explicitly with a known
	# available size, so the awaits would just add blank frames.
	if not startup_layout_suppressed:
		await get_tree().process_frame
		await get_tree().process_frame

	# If startup is being orchestrated by Main, skip the automatic layout
	# so we can perform a single explicit settle after the window size is stable.
	if startup_layout_suppressed:
		return

	if _has_valid_available_size():
		_recalculate_layout()
	if _active_cards.size() == 0:
		_initial_load()

func _instantiate_card_pool():
	var start_us := Time.get_ticks_usec()
	if not _card_scene:
		return

	# Compute a conservative pool size for the current viewport and library size
	# instead of always allocating the hardcoded maximum. This avoids paying for
	# dozens of unused cards during startup, especially on smaller libraries.
	var available = _get_available_size()
	if _has_valid_available_size():
		_max_pool_size = _compute_pool_size(available)
		print("[Grid] _instantiate_card_pool dynamic max_pool_size=", _max_pool_size, " available=", available, " total_items=", _total_items)

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

	# Cache card capability flags from the first instantiated card so we can
	# skip has_method() / string lookups in hot loops.
	var probe = _card_scene.instantiate()
	probe.queue_free()
	_card_has_focus_scale_enabled = "focus_scale_enabled" in probe
	_card_has_set_focus_scale = probe.has_method("set_focus_scale")
	_card_has_set_game_with_priority = probe.has_method("set_game_with_priority")
	_card_has_refresh_settings = probe.has_method("refresh_settings")
	_card_has_reset = probe.has_method("reset")
	_card_has_game_prop = "game" in probe
	_card_has_update_media_panel_size = probe.has_method("_update_media_panel_size")
	_card_has_update_display = probe.has_method("update_display")
	_card_has_set_image_priority = probe.has_method("set_image_priority")
	_card_has_set_content_alignment = probe.has_method("set_content_alignment")
	_card_has_set_media_aspect_ratio = probe.has_method("set_media_aspect_ratio")
	_card_has_refresh_effects = probe.has_method("refresh_effects")
	_card_has_update_card_state_from_settings = probe.has_method("_update_card_state_from_settings")
	_card_has_sync_visual_transform = probe.has_method("sync_visual_transform")
	_card_has_mark_visuals_position_synced = probe.has_method("_mark_visuals_position_synced")
	_card_has_begin_bulk_layout = probe.has_method("begin_bulk_layout")
	_card_has_end_bulk_layout = probe.has_method("end_bulk_layout")
	print("[Grid] _instantiate_card_pool: pool_size=", _max_pool_size, " elapsed_us=", Time.get_ticks_usec() - start_us)

var _pending_pool_growth: int = 0
const POOL_GROWTH_PER_FRAME: int = 4

## Recomputes the required pool size for the current layout. Grows _max_pool_size
## immediately (so buffer math sees the new cap) and queues frame-spread card
## instantiation; shrinking is handled passively by _add_to_pool overflow.
func _ensure_pool_capacity() -> void:
	if not _card_scene or _total_items <= 0 or not _scroll_container:
		return
	if not _has_valid_available_size():
		return
	var required = _compute_pool_size(_get_available_size())
	if required <= 0:
		return
	if required > _max_pool_size:
		var live_cards = _card_pool.size() + _active_cards.size()
		_pending_pool_growth = max(_pending_pool_growth, required - live_cards)
	_max_pool_size = required

func _process_pool_growth() -> void:
	if _pending_pool_growth <= 0 or not _card_scene:
		return
	var count = mini(POOL_GROWTH_PER_FRAME, _pending_pool_growth)
	for i in range(count):
		var card = _card_scene.instantiate()
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		_card_pool.append(card)
	_pending_pool_growth -= count

func _compute_pool_size(available: Vector2) -> int:
	if _total_items <= 0 or not _scroll_container:
		return 0

	# Use the expected card size for the current ratio/available size instead of
	# the default card_size, so the pool is sized for the real layout.
	var expected_card_size = _compute_expected_card_size(available)
	var expected_item_width = expected_card_size.x + grid_separation
	var expected_item_height = expected_card_size.y + grid_separation

	var items_per_line: int
	if vertical:
		items_per_line = max(1, int((available.x + grid_separation) / expected_item_width + 0.0001))
	else:
		items_per_line = max(1, int((available.y + grid_separation) / expected_item_height + 0.0001))

	var stride: float
	var viewport_size: float
	if vertical:
		stride = expected_item_height
		viewport_size = available.y
	else:
		stride = expected_item_width
		viewport_size = available.x

	var visible_lines = max(1, ceili(viewport_size / stride)) if stride > 0 else 1
	var visible_count = visible_lines * items_per_line
	var buffer_count = visible_count + (visual_buffer_lines * 2 * items_per_line)

	if _total_items <= SMALL_LIBRARY_THRESHOLD:
		return max(_total_items, buffer_count)
	return buffer_count

func _compute_expected_card_size(available: Vector2) -> Vector2:
	var current_zoom = _calculate_zoom()
	var base_dims = _get_base_dimensions_for_mode()
	if current_zoom <= 0:
		return base_dims

	match view_mode:
		ViewMode.GRID:
			return base_dims * current_zoom
		ViewMode.LIST:
			return Vector2(available.x / focus_scale, base_dims.y * current_zoom)
		ViewMode.CAROUSEL:
			return Vector2(base_dims.x * current_zoom, available.y / focus_scale)
	return base_dims

# Deterministic sizing: callers (Main, UIManager, views) compute the expected
# available rect from the viewport and container constants, then pass it here so
# layout can run in a single pass without waiting for Godot's deferred size
# propagation.
func set_deterministic_available_size(available: Vector2) -> void:
	# Degenerate sizes (e.g. headless 0x0 window) should not be kept; otherwise
	# every layout pass would collapse to one item per line. Fall back to the
	# grid's own size in those cases.
	if available.x < 2.0 or available.y < 2.0:
		clear_deterministic_available_size()
		return
	_deterministic_available_size = Vector2(maxf(available.x, 1.0), maxf(available.y, 1.0))
	if debug_mode: print("[Grid] set_deterministic_available_size: ", _deterministic_available_size)

func clear_deterministic_available_size() -> void:
	_deterministic_available_size = Vector2.ZERO

func recalculate_layout_with_size(available: Vector2) -> void:
	"""Run a single deterministic layout pass using the supplied available size.

	The deterministic size is kept set so later layout passes (e.g. from
	set_total_count or resize) continue to use the expected viewport rect instead
	of the grid's transient local size. A minimum-size guard prevents degenerate
	headless / tiny-window cases from locking the grid at a 1x1 rect."""
	set_deterministic_available_size(available)
	# Hidden/lazy views can arrive here with a stale target ratio (e.g. the
	# Home-settled ratio) while their own grid size is still zero. Resolve the
	# shared zoom level to this view's snap ratio for the computed available
	# size before snapping, so the final items-per-line matches Home.
	if view_mode == ViewMode.GRID and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
		_apply_zoom_level(UIManager.card_settings_state.card_zoom_level)
	refresh_dimensions()

func set_total_count_with_available_size(count: int, available: Vector2, preserve_cache: bool = false) -> void:
	"""Set the total item count using a deterministic available size.

	Use this instead of set_total_count() when the grid's own size may not yet
	reflect the final container rect (e.g. after a tab change or data reload). The
	deterministic size stays active so subsequent layout recalculations keep
	using the expected viewport rect."""
	set_deterministic_available_size(available)
	set_total_count(count, preserve_cache)

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
				_flow_container.update_minimum_size()
			else:
				var col_height = items_per_line * card_size.y
				if items_per_line > 1:
					col_height += (items_per_line - 1) * grid_separation
				_flow_container.custom_minimum_size.y = max(col_height, 0.0)
				_flow_container.update_minimum_size()
		ViewMode.LIST:
			_flow_container.custom_minimum_size.x = 0
			_flow_container.update_minimum_size()
		ViewMode.CAROUSEL:
			_flow_container.custom_minimum_size.y = 0
			_flow_container.update_minimum_size()

func _initial_load():
	var start_us := Time.get_ticks_usec()
	if startup_layout_suppressed:
		return
	if _active_cards.size() > 0:
		return
	if _total_items <= 0:
		return
	var available := _get_available_size()
	if available.x <= 0 or available.y <= 0:
		return

	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()
	var viewport_size = available.y if vertical else available.x
	var scroll_pos := 0
	if _scroll_container:
		scroll_pos = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal

	_compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	for i in range(_buffer_target_start, _buffer_target_end):
		_add_card_at_end(i)

	_virtual_start = _buffer_target_start
	_virtual_end = _buffer_target_end - 1

	_update_margin()
	_update_visual_draw_order()
	_request_missing_data()
	_flush_pending_visual_setup_for_visible_zone()
	print("[Grid] _initial_load: card_count=", _buffer_target_end - _buffer_target_start, " elapsed_us=", Time.get_ticks_usec() - start_us)

func _compute_visible_and_buffer_ranges(scroll_pos: int, items_per_line: int, stride: float, viewport_size: float) -> void:
	"""Compute visible range and buffer target range for the current scroll position.
	Writes directly to member variables to avoid Dictionary allocation."""
	var line = int(scroll_pos / stride) if stride > 0 else 0
	var visible_lines = ceili(viewport_size / stride) if stride > 0 else 1
	_visible_start_idx = line * items_per_line
	_visible_end_idx = min(_visible_start_idx + visible_lines * items_per_line, _total_items)

	var visible_count = _visible_end_idx - _visible_start_idx
	var total_card_count = visible_count + (_current_buffer_lines * 2 * items_per_line)
	# For small libraries, just load everything to avoid edge-case recycling bugs
	# that can clip the last partial row in grid mode.
	if _total_items <= SMALL_LIBRARY_THRESHOLD:
		total_card_count = _total_items
	var half_buffer = int((total_card_count - visible_count) / 2.0)
	_buffer_target_start = max(0, _visible_start_idx - half_buffer)
	_buffer_target_end = min(_total_items, _buffer_target_start + total_card_count)

	if _buffer_target_end == _total_items:
		_buffer_target_start = max(0, _total_items - total_card_count)

	# Align target_start to items_per_line so the first buffered card always starts
	# at the beginning of a row/column. Without this, FlowContainer misaligns cards
	# when the buffer starts mid-row after incremental recycling or zoom changes.
	_buffer_target_start = int(_buffer_target_start / float(items_per_line)) * items_per_line

	# Recompute target_end after alignment so the buffer size stays consistent
	_buffer_target_end = min(_total_items, _buffer_target_start + total_card_count)

	# When we're near the end of the list, alignment can leave a partial row
	# outside the buffer (e.g. 98 items, buffer covers 56-97, missing index 97).
	# Extend target_end to always include the last partial row.
	if _buffer_target_end < _total_items and (_total_items - _buffer_target_end) < items_per_line:
		_buffer_target_end = _total_items

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
	if Engine.get_process_frames() <= _suppress_recycle_until_frame:
		allow_recycle = false

	var scroll_pos = int(value)
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()

	var available := _get_available_size()
	var viewport_size = available.y if vertical else available.x
	_compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	# Batch recycle from top — skip during layout recalculations (zoom changes)
	# so cards are not reset and their images stay loaded.
	if allow_recycle:
		var recycle_top_count = 0
		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx < _buffer_target_start:
				recycle_top_count += 1
			else:
				break
		if recycle_top_count > 0:
			_batch_recycle_from_start(recycle_top_count)

		while _active_cards.size() > 0:
			var last_card = _active_cards[_active_cards.size() - 1]
			var last_idx = last_card.get_meta("virtual_index", -1)

			if last_idx >= _buffer_target_end:
				_recycle_card_at_index(_active_cards.size() - 1)
			else:
				break

	# If buffer was fully recycled (e.g. scrolled to a completely different range),
	# populate the target range from scratch
	if _active_cards.size() == 0:
		for i in range(_buffer_target_start, _buffer_target_end):
			_add_card_at_end(i)
	elif _active_cards.size() > 0:
		var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		while current_last < _buffer_target_end - 1 and current_last < _total_items - 1:
			_add_card_at_end(current_last + 1)
			current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)

		if _active_cards.size() > 0:
			var current_first = _active_cards[0].get_meta("virtual_index", 0)
			if current_first > _buffer_target_start and current_first > 0:
				var add_start_count = mini(current_first - _buffer_target_start, current_first)
				_batch_add_at_start(_buffer_target_start, add_start_count)

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
	_update_card_priorities(_visible_start_idx, _visible_end_idx)
	
	# Scrolling may bring queued effect-rebuild or visual-setup cards into the
	# visible zone; finish them immediately so the user doesn't see blanks.
	_flush_pending_effect_rebuilds_for_visible_zone()
	_flush_pending_visual_setup_for_visible_zone()
	_sync_and_mark_card_visual_transforms()
	_update_visual_draw_order()

	visible_range_changed.emit(_visible_start_idx, _visible_end_idx, _total_items)

	# If a programmatic focus is waiting for this scroll rebuild, try to land it now.
	_try_apply_pending_focus()

	if debug_mode:
		_update_debug_visuals(_visible_start_idx, _visible_end_idx)

	_is_processing_scroll = false

func _recycle_card_at_index(index: int):
	if index < 0 or index >= _active_cards.size():
		return

	var card = _active_cards[index]
	_release_focus_if_inside(card)
	_active_cards.remove_at(index)
	var vidx = card.get_meta("virtual_index", -1)
	if vidx >= 0:
		_active_cards_by_index.erase(vidx)
		_pending_visual_setup.erase(vidx)

	if is_instance_valid(card):
		_disconnect_card_signals(card)
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)

		# Remove from pending effect rebuild queue so recycled cards don't
		# rebuild after they're returned to the pool.
		if _pending_effect_rebuild_set.has(card):
			_pending_effect_rebuilds.erase(card)
			_pending_effect_rebuild_set.erase(card)

		card.remove_meta("needs_visual_setup")

		if _card_has_reset:
			card.reset(true)
		elif _card_has_game_prop:
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

	if _card_has_begin_bulk_layout:
		card.begin_bulk_layout()

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

	# Render cards one z-level above the grid's visual layer so the visual layer
	# (drawn at the grid's z-index) sits behind the cards while still covering the
	# scroll container background.
	card.z_index = 1

	# Apply content alignment for all modes (GRID also supports START/CENTER/END)
	if _card_has_set_content_alignment:
		var alignment = _get_content_alignment()
		card.set_content_alignment(alignment)

	if _card_has_set_media_aspect_ratio:
		card.set_media_aspect_ratio(_get_media_aspect_ratio())

	# Re-sync focus visuals so a recycled card does not carry a stale focused
	# content_scale into the grid after a layout/theme change.
	if _card_has_set_focus_scale:
		card.set_focus_scale(focus_scale)

	if _card_has_end_bulk_layout:
		card.end_bulk_layout()

func _configure_card_visual_layer(card: Control) -> void:
	if card.has_method("set_visual_layer"):
		card.set_visual_layer(_visual_layer)

func _sync_card_visual_transforms() -> void:
	if not _card_has_sync_visual_transform:
		return
	for card in _active_cards:
		card.sync_visual_transform()

func _sync_and_mark_card_visual_transforms() -> void:
	var marked: int = 0
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		# Don't mark cards before _ready() has run; _setup_rs_items() resets the
		# synced flag, so marking earlier would be silently undone.
		if not card.is_node_ready():
			continue
		if _card_has_sync_visual_transform:
			card.sync_visual_transform()
		if _card_has_mark_visuals_position_synced:
			card._mark_visuals_position_synced()
			marked += 1
	if debug_mode:
		print("[Grid] _sync_and_mark_card_visual_transforms: marked=", marked, " active=", _active_cards.size())

func _update_visual_draw_order() -> void:
	var focused_idx = _get_focused_virtual_index()
	for card in _active_cards:
		if not card.has_method("set_visual_draw_index"):
			continue
		var idx = card.get_meta("virtual_index", 0)
		var base_index = idx * 10
		if idx == focused_idx:
			base_index += 1000000
		card.set_visual_draw_index(base_index)

func _add_card_at_end(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return

	card.set_meta("virtual_index", virtual_index)
	if _card_has_focus_scale_enabled:
		card.focus_scale_enabled = true
		card.focus_scale_inverted = _get_focus_scale_inverted()
	_configure_card_visual_layer(card)
	_configure_card_size_flags(card)
	if _card_has_set_focus_scale:
		card.set_focus_scale(focus_scale)
	_active_cards.append(card)
	_active_cards_by_index[virtual_index] = card
	_flow_container.add_child(card)

	card.set_meta("needs_visual_setup", true)
	_pending_visual_setup[virtual_index] = card

	item_created.emit(card, virtual_index)

func _add_card_at_start(virtual_index: int):
	var card = _acquire_card()
	if not card:
		return

	card.set_meta("virtual_index", virtual_index)
	if _card_has_focus_scale_enabled:
		card.focus_scale_enabled = true
		card.focus_scale_inverted = _get_focus_scale_inverted()
	_configure_card_visual_layer(card)
	_active_cards.insert(0, card)
	_active_cards_by_index[virtual_index] = card
	_flow_container.add_child(card)
	_flow_container.move_child(card, 0)
	_configure_card_size_flags(card)
	if _card_has_set_focus_scale:
		card.set_focus_scale(focus_scale)

	card.set_meta("needs_visual_setup", true)
	_pending_visual_setup[virtual_index] = card

	item_created.emit(card, virtual_index)

func _apply_card_visual_setup(card: Control, virtual_index: int) -> bool:
	if not card.has_meta("needs_visual_setup"):
		if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " no meta, skipping")
		return true
	if not card.is_node_ready():
		if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " not ready, keeping pending")
		return false
	if not _data_cache.has(virtual_index):
		# Data not loaded yet; keep the card pending so it gets finished once
		# the items_requested callback populates the cache.
		if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " data missing, keeping pending")
		return false
	card.remove_meta("needs_visual_setup")

	if _card_has_refresh_settings:
		card.refresh_settings()

	# Recompute content bounds before applying data. Cards created before the
	# FlowContainer has sized them can have zero text/media bounds from _ready(),
	# which causes _update_text() and _update_media() to draw nothing.
	if _card_has_update_media_panel_size:
		if debug_mode:
			print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " updating media panel size, size=", card.size, " min=", card.custom_minimum_size)
		card._update_media_panel_size(true)

	var card_visible = _is_index_visible(virtual_index)
	if _card_has_set_game_with_priority:
		card.set_game_with_priority(_data_cache[virtual_index], card_visible)
	else:
		card.game = _data_cache[virtual_index]
	_update_cache_access_order(virtual_index)
	if debug_mode:
		print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " data applied, size=", card.size, " min=", card.custom_minimum_size)
	# The card may have been marked as position-synced before its data was
	# applied, in which case its visual items were hidden because headline was
	# empty. Re-evaluate visibility now that the game/title is set.
	if card.has_method("_update_visual_items_visibility"):
		card._update_visual_items_visibility()
	# Ensure the card's visual layer is positioned and marked visible now that
	# data is applied. In some paths (async startup, scroll recycling) the
	# global sync runs before the card is ready or before data is available,
	# leaving the card invisible until it is recycled.
	if _card_has_sync_visual_transform:
		card.sync_visual_transform()
	if _card_has_mark_visuals_position_synced:
		card._mark_visuals_position_synced()
	if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " applied")
	return true

func _batch_recycle_from_start(count: int) -> void:
	if count <= 0 or count > _active_cards.size():
		return

	# Release focus once if any card being recycled (or a descendant) owns it.
	var viewport := get_viewport()
	var focused = viewport.gui_get_focus_owner() if is_instance_valid(viewport) else null
	if focused:
		for i in range(count):
			var card = _active_cards[i]
			if is_instance_valid(card) and card.is_ancestor_of(focused):
				viewport.gui_release_focus()
				break

	# Recycle in-place to avoid array allocation from slice().
	for i in range(count - 1, -1, -1):
		var card = _active_cards[i]
		var vidx = card.get_meta("virtual_index", -1)
		if vidx >= 0:
			_active_cards_by_index.erase(vidx)
			_pending_visual_setup.erase(vidx)
		if is_instance_valid(card):
			_disconnect_card_signals(card)
			card.visible = false
			card.set_meta("pooled", true)
			card.set_meta("virtual_index", -1)
			if _card_has_reset:
				card.reset(true)
			elif _card_has_game_prop:
				card.game = null
			card.remove_meta("needs_visual_setup")
			if card.get_parent() == _flow_container:
				_flow_container.remove_child(card)
			_add_to_pool(card)
	_active_cards = _active_cards.slice(count)

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
		if _card_has_focus_scale_enabled:
			card.focus_scale_enabled = true
			card.focus_scale_inverted = _get_focus_scale_inverted()
		_configure_card_visual_layer(card)
		_flow_container.add_child(card)
		_flow_container.move_child(card, i)
		_configure_card_size_flags(card)
		if _card_has_set_focus_scale:
			card.set_focus_scale(focus_scale)
		card.set_meta("needs_visual_setup", true)
		_pending_visual_setup[virtual_index] = card
		item_created.emit(card, virtual_index)
		_active_cards_by_index[virtual_index] = card
		new_cards.append(card)
	_active_cards = new_cards + _active_cards

func _get_visible_range() -> void:
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var available := _get_available_size()

	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = available.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		_visible_start_idx = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
		_visible_end_idx = min(_visible_start_idx + visible_rows * items_per_line, _total_items)
	else:
		var scroll_pos = _scroll_container.scroll_horizontal if _scroll_container else 0
		var viewport_width = available.x
		var visible_cols = ceili(viewport_width / eff) if eff > 0 else 1
		_visible_start_idx = int(scroll_pos / eff) * items_per_line if eff > 0 else 0
		_visible_end_idx = min(_visible_start_idx + visible_cols * items_per_line, _total_items)

func _is_index_visible(idx: int) -> bool:
	return idx >= _visible_start_idx and idx < _visible_end_idx

func _acquire_card() -> Control:
	while _card_pool.size() > 0:
		var card = _card_pool.pop_back()
		if is_instance_valid(card):
			card.set_meta("pooled", false)
			# Ensure a recycled card can always receive focus; some paths (preview,
			# manual disabling) may leave these in a non-focusable state.
			card.disabled = false
			card.focus_mode = Control.FOCUS_ALL
			card.visible = true
			return card

	if _card_scene:
		var card = _card_scene.instantiate()
		card.set_meta("pooled", false)
		card.focus_mode = Control.FOCUS_ALL
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
	var _num_active = last_idx - first_idx + 1
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()
	var focus_overflow = _get_focus_overflow()

	if vertical:
		# Add focus overflow padding to top/bottom so edge rows have room to scale.
		var first_pos = _get_slot_position_for_index(first_idx, items_per_line, stride)
		var after_last_pos = _get_slot_position_for_index(last_idx + 1, items_per_line, stride)
		# _get_slot_position_for_index uses floor division, returning the START of a row.
		# For the total content end, we need the END of the last (possibly partial) row,
		# otherwise the last row gets clipped in grid mode where items_per_line > 1.
		var total_lines = ceili(float(_total_items) / items_per_line)
		var total_end = total_lines * stride
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

		# No horizontal margins — cards fill the viewport edge-to-edge.
		# Focused cards in edge columns may clip slightly; this is preferred
		# over leaving visible gaps on either side of the grid.
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

		# No vertical margins — cards fill the viewport edge-to-edge.
		# Focused cards in edge rows may clip slightly; this is preferred
		# over leaving visible gaps above and below the grid.
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

		var card_visible = idx >= visible_start_idx and idx < visible_end_idx

		if _card_has_set_image_priority:
			card.set_image_priority(card_visible)

func _connect_focus_lock_viewport() -> void:
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	if viewport.gui_focus_changed.is_connected(_on_viewport_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_viewport_focus_changed)
	viewport.gui_focus_changed.connect(_on_viewport_focus_changed)
	_viewport_focus_connection = viewport

func _disconnect_focus_lock_viewport() -> void:
	if _viewport_focus_connection and is_instance_valid(_viewport_focus_connection):
		if _viewport_focus_connection.gui_focus_changed.is_connected(_on_viewport_focus_changed):
			_viewport_focus_connection.gui_focus_changed.disconnect(_on_viewport_focus_changed)
	_viewport_focus_connection = null

func _reconnect_focus_lock_viewport() -> void:
	_disconnect_focus_lock_viewport()
	_connect_focus_lock_viewport()

func refresh_focus_lock() -> void:
	"""Re-sync focus-lock state and ensure the viewport signal is connected.
	Call after reparenting or when the setting may have changed outside the
	normal change event flow."""
	_reconnect_focus_lock_viewport()

func _on_viewport_focus_changed(control: Control) -> void:
	if not control:
		return

	# Check if focus moved to a card inside this grid.
	if is_ancestor_of(control):
		var node = control
		while node != self:
			if node.has_meta("virtual_index"):
				_last_focused_virtual_index = node.get_meta("virtual_index", -1)
				break
			node = node.get_parent()
		# Tell UIManager to lock focus to this grid.
		if UIManager:
			UIManager.enter_focus_lock(self)
		return

	# Focus is outside this grid.
	if UIManager:
		UIManager.exit_focus_lock(self)

func navigate_direction(dir: String, from_index: int = -1) -> bool:
	"""Move focus one step in the given direction. Returns true if the event was consumed."""
	if not visible or not is_inside_tree():
		return false
	if not UIManager or not UIManager.controller_has_priority():
		return false

	var row_delta := 0
	var col_delta := 0
	match dir:
		"ui_up":
			row_delta = -1
		"ui_down":
			row_delta = 1
		"ui_left":
			col_delta = -1
		"ui_right":
			col_delta = 1
		_:
			return false

	# For horizontal grids the "line" runs top-to-bottom, so swap axis meaning
	# so left/right always move along the line and up/down move between lines.
	if not vertical:
		var tmp := row_delta
		row_delta = col_delta
		col_delta = tmp

	var current_idx := from_index if from_index >= 0 else _get_focused_virtual_index()
	if current_idx < 0:
		return false

	var target_idx := _compute_target_index(current_idx, row_delta, col_delta)
	if target_idx < 0 or target_idx == current_idx:
		# Boundary: consume the event so focus cannot leave the grid.
		return true

	# If the target is already visible, move focus directly to it instead of
	# falling through to spatial navigation, which can leak focus out of the grid.
	if target_idx >= _visible_start_idx and target_idx < _visible_end_idx:
		var card = get_card_at_index(target_idx)
		if card and is_instance_valid(card) and card.is_inside_tree():
			card.grab_focus()
			return true

	# The target is offscreen. Scroll to it and focus it.
	scroll_to_index_and_focus(target_idx, true, 0.6)
	return true

func _get_focused_virtual_index() -> int:
	var viewport := get_viewport()
	if not is_instance_valid(viewport):
		return -1
	var focused := viewport.gui_get_focus_owner()
	if not focused or not is_ancestor_of(focused):
		return -1
	var node := focused
	while node != self:
		if node.has_meta("virtual_index"):
			return node.get_meta("virtual_index", -1)
		node = node.get_parent()
	return -1

func _compute_target_index(current_idx: int, row_delta: int, col_delta: int) -> int:
	"""Compute the target virtual index from a 2D row/column delta.

	For vertical grids a "row" is a horizontal line and the column is the
	intra-line index. For horizontal grids a "row" is a vertical line and the
	column is the intra-line index. This lets left/right navigate within a
	line and up/down navigate between lines regardless of orientation."""
	if _total_items <= 0 or current_idx < 0 or current_idx >= _total_items:
		return -1

	var items_per_line := _get_items_per_line()
	if items_per_line <= 0:
		items_per_line = 1

	# LIST/CAROUSEL: simple linear movement.
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL or items_per_line == 1:
		var target := current_idx + row_delta + col_delta
		return clamp(target, 0, _total_items - 1)

	var line := int(current_idx / float(items_per_line))
	var col := current_idx % items_per_line
	var total_lines := ceili(float(_total_items) / items_per_line)

	var target_line := line + row_delta
	var target_col := col + col_delta

	if target_line < 0 or target_line >= total_lines:
		return -1
	if target_col < 0 or target_col >= items_per_line:
		return -1

	var target_idx := target_line * items_per_line + target_col
	if target_idx >= _total_items:
		return -1
	return target_idx

func _release_focus_if_inside(card: Control) -> void:
	"""Release focus if the current focus owner is inside the given card."""
	var viewport := get_viewport()
	if not is_instance_valid(viewport):
		return
	var focused := viewport.gui_get_focus_owner()
	if focused and (focused == card or card.is_ancestor_of(focused)):
		viewport.gui_release_focus()

func _release_focus_inside_grid() -> void:
	"""Release focus if it currently belongs to any card inside this grid."""
	var viewport := get_viewport()
	if not is_instance_valid(viewport):
		return
	var focused := viewport.gui_get_focus_owner()
	if focused and is_ancestor_of(focused):
		viewport.gui_release_focus()

func _try_apply_pending_focus() -> void:
	"""Focus the pending card if it has been created by the latest scroll."""
	if _pending_focus_index < 0:
		return
	var card := get_card_at_index(_pending_focus_index)
	if card and is_instance_valid(card) and card.is_inside_tree():
		_apply_focus_to_card(card)

func _request_data(offset: int, limit: int):
	if limit <= 0 or offset < 0 or offset >= _total_items:
		return

	limit = min(limit, _total_items - offset)
	_pending_loads[offset] = limit

	items_requested.emit(offset, limit)

func on_items_loaded(items: Array[GameResource], offset: int, _is_preload: bool = false):
	if debug_mode:
		print("[Grid] on_items_loaded: offset=", offset, " count=", items.size(), " pending=", _pending_visual_setup.size(), " cache_size_before=", _data_cache.size())
	_pending_loads.erase(offset)

	if items.is_empty():
		return

	# Clear deduplication tracking for each batch to avoid false positives
	# when scrolling causes overlapping ranges from the parent view
	_cached_game_ids.clear()

	var duplicates_found: int = 0

	for i in range(items.size()):
		var cache_key = offset + i
		var game = items[i]

		# Deduplication check: warn if this game ID is already cached at a different index
		# but still cache it at the new index so cards get their data
		if game and game.romm_id != 0:
			if _cached_game_ids.has(game.romm_id):
				var existing_key = _cached_game_ids[game.romm_id]
				# Stale mapping check: evicted or replaced game at existing_key
				if not _data_cache.has(existing_key) or _data_cache[existing_key] != game:
					_cached_game_ids.erase(game.romm_id)
				elif existing_key != cache_key:
					duplicates_found += 1
					push_warning("[VirtualScrollGridContainer] Duplicate game detected: '%s' (romm_id: %d) at indices %d and %d" % [game.title, game.romm_id, existing_key, cache_key])
			else:
				_cached_game_ids[game.romm_id] = cache_key

		if _data_cache.size() >= MAX_CACHE_SIZE and not _data_cache.has(cache_key):
			_evict_oldest_cache_entries(items.size())

		_data_cache[cache_key] = game
		_update_cache_access_order(cache_key)

	if duplicates_found > 0:
		push_warning("[VirtualScrollGridContainer] Found %d duplicate game(s) in batch starting at offset %d" % [duplicates_found, offset])

	_get_visible_range()
	var visible_start_idx: int = _visible_start_idx
	var visible_end_idx: int = _visible_end_idx

	var _assigned_count = 0
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		if idx >= offset and idx < offset + items.size():
			# Off-screen buffer cards may have their visual setup deferred; leave
			# them for _process_pending_visual_setup() so we don't pay the cost now.
			if card.has_meta("needs_visual_setup"):
				continue
			var data_idx = idx - offset
			if data_idx < items.size():
				var card_visible = idx >= visible_start_idx and idx < visible_end_idx
				if _card_has_set_game_with_priority:
					card.set_game_with_priority(items[data_idx], card_visible)
				else:
					card.game = items[data_idx]
				_update_cache_access_order(idx)
				_assigned_count += 1

	_update_card_priorities(visible_start_idx, visible_end_idx)
	_flush_pending_visual_setup_for_visible_zone()

func _refresh_buffer(preserve_scroll: bool = false):
	# Capture live focus state before recycling so we can restore it after rebuild.
	var saved_focus_index: int = _get_focused_virtual_index()
	# Remember the last focused index for fallback restoration even if focus is
	# not currently owned by this grid.
	if saved_focus_index < 0 and _last_focused_virtual_index >= 0:
		saved_focus_index = _last_focused_virtual_index
	# Capture the raw scroll offset when requested so we can restore position for
	# non-focused cards (e.g. mouse users) across view-mode switches.
	var saved_scroll_offset: float = 0.0
	if preserve_scroll and _scroll_container:
		saved_scroll_offset = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal

	while _active_cards.size() > 0:
		_recycle_card_at_index(0)

	_data_cache.clear()
	_cached_game_ids.clear()
	_cache_lru_tick.clear()
	_pending_loads.clear()
	_active_cards_by_index.clear()
	_pending_effect_rebuilds.clear()
	_pending_effect_rebuild_set.clear()
	_pending_effects_refresh_after_layout = false
	_margin_container.add_theme_constant_override("margin_top", 0)
	_margin_container.add_theme_constant_override("margin_bottom", 0)
	_margin_container.add_theme_constant_override("margin_left", 0)
	_margin_container.add_theme_constant_override("margin_right", 0)
	_flow_container.custom_minimum_size = Vector2(0, 0)
	# Invalidate the layout input cache so the following _recalculate_layout()
	# cannot early-exit and leave the FlowContainer at zero size. This matters
	# when a buffer refresh happens while total count and geometry are unchanged
	# (e.g. after sync completes), because the cache check would otherwise skip
	# the pass that restores custom_minimum_size.
	_last_layout_available_size = Vector2.ZERO
	_last_layout_total_items = -1
	_last_layout_card_size = Vector2.ZERO
	_last_layout_focused_card_size = Vector2.ZERO
	_virtual_start = 0
	_virtual_end = 0

	# Only zero the scroll when not preserving it. View-mode switches remember
	# the focused item (or raw offset) and restore it after the rebuild.
	if not preserve_scroll and _scroll_container:
		_scroll_container.scroll_vertical = 0
		_scroll_container.scroll_horizontal = 0
		_scroll_container._target_scroll = 0.0

	_recalculate_layout()
	if _active_cards.size() == 0:
		_initial_load()
		_recalculate_layout()
	_update_visual_draw_order()

	# Restore focus to the card that owned it before recycle; fall back to the
	# saved raw scroll offset if no focus target exists. scroll_to_index_and_focus
	# waits for the target card to exist and suppresses the smooth-scroll
	# response, so the jump is instantaneous.
	if preserve_scroll:
		if saved_focus_index >= 0:
			call_deferred("scroll_to_index_and_focus", saved_focus_index, false)
		elif _scroll_container:
			# Clamp to valid range after the new layout is known.
			var scrollbar = (_scroll_container.get_v_scroll_bar() as ScrollBar) if vertical else (_scroll_container.get_h_scroll_bar() as ScrollBar)
			var max_scroll: float = scrollbar.max_value - scrollbar.page if scrollbar else 0.0
			var clamped_offset: int = int(clampf(saved_scroll_offset, 0.0, max_scroll))
			if vertical:
				_scroll_container.scroll_vertical = clamped_offset
			else:
				_scroll_container.scroll_horizontal = clamped_offset
			_scroll_container._target_scroll = clamped_offset

func get_target_scroll() -> float:
	return _scroll_container.get_target_scroll() if _scroll_container else 0.0

func get_visible_range() -> Dictionary:
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var available := _get_available_size()

	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = available.y
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
		var viewport_width = available.x
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
		var _items_per_line = _get_items_per_line()
		var target_pos = _get_slot_position_for_index(index)
		var focus_overflow = _get_focus_overflow()
		var available := _get_available_size()

		if vertical:
			var viewport_height = available.y
			# The card's content coordinate is target_pos + top overflow; center it in viewport.
			var card_offset = target_pos + focus_overflow.y + (card_size.y / 2.0) - (viewport_height / 2.0)
			_scroll_container.scroll_to(int(card_offset), animate, duration_multiplier, focus_callback)
		else:
			var viewport_width = available.x
			var card_offset = target_pos + focus_overflow.x + (card_size.x / 2.0) - (viewport_width / 2.0)
			_scroll_container.scroll_to(int(card_offset), animate, duration_multiplier, focus_callback)

func scroll_to_index_and_focus(index: int, animate: bool = false, duration_multiplier: float = 1.0) -> void:
	"""Scroll to an item and focus it once the virtual grid has rebuilt the window."""
	_focus_request_id += 1
	var request_id := _focus_request_id
	# Defocus the grid before scrolling so the currently focused card is not
	# recycled mid-jump, which would hand focus to a temporary card and trigger
	# a competing smooth-scroll back toward the top.
	_release_focus_inside_grid()
	_pending_focus_index = index
	scroll_to_index(index, animate, duration_multiplier)
	_deferred_focus_index(index, request_id, 0)

func _deferred_focus_index(index: int, request_id: int, attempt: int) -> void:
	"""Wait until the card for `index` exists, then grab focus."""
	if request_id != _focus_request_id:
		return

	var card := get_card_at_index(index)
	if card and is_instance_valid(card) and card.is_inside_tree():
		_apply_focus_to_card(card)
		return

	# The card may not exist until the scroll value change is processed; retry briefly.
	if attempt < 5:
		await get_tree().process_frame
		_deferred_focus_index(index, request_id, attempt + 1)
	else:
		_pending_focus_index = -1

func _apply_focus_to_card(card: Control) -> void:
	"""Focus a card and suppress the container's follow-focus auto-scroll.
	We intentionally do NOT stop an in-flight smooth scroll here: this helper is
	used by scroll-to-focus paths that already started a centered scroll, and
	interrupting it leaves offscreen targets sitting at the viewport edge."""
	card.set_meta("_suppress_smooth_scroll", true)
	card.grab_focus()
	_pending_focus_index = -1

func focus_last_or_first_card() -> void:
	"""Focus the last focused card, or the first card if none was focused."""
	var card = get_card_at_index(_last_focused_virtual_index)
	if not card or not is_instance_valid(card) or not card.is_inside_tree():
		card = get_card_at_index(0)
	if card and is_instance_valid(card) and card.is_inside_tree():
		card.grab_focus()

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

		var card_visible = idx >= visible_start_idx and idx <= visible_end_idx
		var has_data = _data_cache.has(idx)

		# Use cached metadata reference instead of tree traversal for performance
		var debug_panel = card.get_meta("_debug_panel_ref", null)
		if not debug_panel or not is_instance_valid(debug_panel):
			debug_panel = Panel.new()
			debug_panel.name = "_debug_panel"
			debug_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

			var label = M3Label.new()
			label.name = "_debug_label"
			label.set_anchors_preset(Control.PRESET_TOP_LEFT)
			label.position = Vector2(M3Units.dp(5), M3Units.dp(5))
			label.label_style = M3Label.Style.BODY_SMALL
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			debug_panel.add_child(label)

			card.add_child(debug_panel)
			card.move_child(debug_panel, 0)
			card.set_meta("_debug_panel_ref", debug_panel)

		var style: StyleBoxFlat
		if card_visible:
			style = _debug_style_visible_data if has_data else _debug_style_visible_loading
		else:
			style = _debug_style_buffer_data if has_data else _debug_style_buffer_loading
		debug_panel.add_theme_stylebox_override("panel", style)

		var debug_label = debug_panel.get_node("_debug_label")
		if debug_label:
			var status = "DATA" if has_data else "LOADING"
			var location = "VISIBLE" if card_visible else "BUFFER"
			debug_label.text = "#%d\n%s\n%s" % [idx, status, location]

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
		# Clean debug panels from both active cards and pool cards
		for card in _active_cards:
			var debug_panel = card.get_meta("_debug_panel_ref", null)
			if debug_panel and is_instance_valid(debug_panel):
				debug_panel.queue_free()
			card.remove_meta("_debug_panel_ref")
		for card in _card_pool:
			var debug_panel = card.get_meta("_debug_panel_ref", null)
			if debug_panel and is_instance_valid(debug_panel):
				debug_panel.queue_free()
			card.remove_meta("_debug_panel_ref")
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
	var available := _get_available_size()

	if vertical:
		var viewport_height = available.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		visible_count = visible_rows * items_per_line
	else:
		var viewport_width = available.x
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
			if _card_has_focus_scale_enabled:
				card.focus_scale_enabled = true
				card.focus_scale_inverted = _get_focus_scale_inverted()
			_configure_card_visual_layer(card)
			_configure_card_size_flags(card)
			_active_cards.append(card)
			_active_cards_by_index[i] = card
			_flow_container.add_child(card)

			if _data_cache.has(i):
				var card_visible = i < visible_count
				if _card_has_set_game_with_priority:
					card.set_game_with_priority(_data_cache[i], card_visible)
				else:
					card.game = _data_cache[i]
				if _card_has_update_display:
					card.update_display()

			item_created.emit(card, i)

	_update_margin()
	_update_visual_draw_order()

func cache_items_at_offset(items: Array[GameResource], offset: int):
	for i in range(items.size()):
		if offset + i < _total_items:
			var cache_key = offset + i
			var game = items[i]

			# Deduplication check
			if game and game.romm_id != 0:
				if _cached_game_ids.has(game.romm_id):
					var existing_key = _cached_game_ids[game.romm_id]
					# Stale mapping check: evicted or replaced game at existing_key
					if not _data_cache.has(existing_key) or _data_cache[existing_key] != game:
						_cached_game_ids.erase(game.romm_id)
					elif existing_key != cache_key:
						continue

				_cached_game_ids[game.romm_id] = cache_key

			# Actually cache the game so it can be assigned to cards.
			_data_cache[cache_key] = game
			_update_cache_access_order(cache_key)

	if items.size() > 0:
		_get_visible_range()
		var visible_start_idx: int = _visible_start_idx
		var visible_end_idx: int = _visible_end_idx

		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx >= offset and idx < offset + items.size():
				if _data_cache.has(idx):
					var card_visible = idx >= visible_start_idx and idx < visible_end_idx
					if _card_has_set_game_with_priority:
						card.set_game_with_priority(_data_cache[idx], card_visible)
					else:
						card.game = _data_cache[idx]
					_update_cache_access_order(idx)
					if _card_has_update_display:
						card.update_display()

func refresh_if_visible(start_index: int, end_index: int):
	if _active_cards.size() == 0:
		return

	var current_first = _active_cards[0].get_meta("virtual_index", 0)
	var current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)

	var overlap_start = max(start_index, current_first)
	var overlap_end = min(end_index, current_last)

	if overlap_start <= overlap_end:
		_get_visible_range()
		var visible_start_idx: int = _visible_start_idx
		var visible_end_idx: int = _visible_end_idx

		for card in _active_cards:
			var idx = card.get_meta("virtual_index", -1)
			if idx >= overlap_start and idx <= overlap_end and _data_cache.has(idx):
				var card_visible = idx >= visible_start_idx and idx < visible_end_idx
				if _card_has_set_game_with_priority:
					card.set_game_with_priority(_data_cache[idx], card_visible)
				else:
					card.game = _data_cache[idx]
				_update_cache_access_order(idx)
				if _card_has_update_display:
					card.update_display()

func refresh_all_card_effects(force_full_rebuild: bool = false) -> void:
	"""Refresh effects on active cards. Cards in the visible zone plus a small
	buffer are rebuilt immediately; the rest are queued and drained over frames
	to avoid stalling on large grids."""
	# A new full-grid refresh supersedes any still-pending queue.
	_pending_effect_rebuilds.clear()
	_pending_effect_rebuild_set.clear()
	_pending_effect_rebuild_force_full = force_full_rebuild

	_get_visible_range()

	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var stride_cards: int = items_per_line
	if eff > 0:
		var row_size: int = maxi(items_per_line, 1)
		stride_cards = row_size * EFFECT_REBUILD_BUFFER_LINES

	var sync_start: int = maxi(0, _visible_start_idx - stride_cards)
	var sync_end: int = mini(_visible_end_idx + stride_cards, _total_items)

	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		var idx = card.get_meta("virtual_index", -1)
		var in_sync_zone = idx >= sync_start and idx < sync_end
		if in_sync_zone:
			if _card_has_update_media_panel_size:
				card._update_media_panel_size(true)
			if _card_has_refresh_effects:
				card.refresh_effects(force_full_rebuild)
			elif _card_has_refresh_settings:
				card.refresh_settings()
		else:
			if not _pending_effect_rebuild_set.has(card):
				_pending_effect_rebuilds.append(card)
				_pending_effect_rebuild_set[card] = true

func _drain_pending_effect_rebuilds() -> void:
	if _pending_effect_rebuilds.is_empty():
		return

	var force_full_rebuild: bool = _pending_effect_rebuild_force_full
	var processed: int = 0
	while processed < EFFECT_REBUILD_CARDS_PER_FRAME and not _pending_effect_rebuilds.is_empty():
		var card = _pending_effect_rebuilds[0]
		_pending_effect_rebuilds.remove_at(0)
		_pending_effect_rebuild_set.erase(card)
		if not is_instance_valid(card):
			continue
		# Skip cards that are no longer active.
		if not _active_cards.has(card):
			continue
		# Make sure bounds and stack parenting are current before rebuilding;
		# cards that were queued during a layout change can otherwise rebuild
		# against stale/zero media bounds and stay blank.
		if _card_has_update_media_panel_size:
			card._update_media_panel_size(true)
		if _card_has_refresh_effects:
			card.refresh_effects(force_full_rebuild)
		elif _card_has_refresh_settings:
			card.refresh_settings()
		processed += 1

func _flush_pending_effect_rebuilds_for_visible_zone() -> void:
	if _pending_effect_rebuilds.is_empty():
		return

	_get_visible_range()

	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var stride_cards: int = items_per_line
	if eff > 0:
		var row_size: int = maxi(items_per_line, 1)
		stride_cards = row_size * EFFECT_REBUILD_BUFFER_LINES

	var sync_start: int = maxi(0, _visible_start_idx - stride_cards)
	var sync_end: int = mini(_visible_end_idx + stride_cards, _total_items)

	var i: int = 0
	while i < _pending_effect_rebuilds.size():
		var card = _pending_effect_rebuilds[i]
		if not is_instance_valid(card):
			_pending_effect_rebuilds.remove_at(i)
			_pending_effect_rebuild_set.erase(card)
			continue
		if not _active_cards.has(card):
			_pending_effect_rebuilds.remove_at(i)
			_pending_effect_rebuild_set.erase(card)
			continue
		var idx = card.get_meta("virtual_index", -1)
		if idx >= sync_start and idx < sync_end:
			_pending_effect_rebuilds.remove_at(i)
			_pending_effect_rebuild_set.erase(card)
			if _card_has_update_media_panel_size:
				card._update_media_panel_size(true)
			if _card_has_refresh_effects:
				card.refresh_effects(_pending_effect_rebuild_force_full)
			elif _card_has_refresh_settings:
				card.refresh_settings()
			continue
		i += 1

func refresh_all_card_configs() -> void:
	"""Re-apply size flags, alignment, aspect ratio, and display mode to all active cards.
	Call when cached settings (alignment, ratio, display mode) change so that
	cards already in the viewport pick up the new values immediately."""
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		_configure_card_size_flags(card)
		if _card_has_update_media_panel_size:
			card._update_media_panel_size(true)
		# Display mode affects text/background visibility and card geometry, so
		# re-apply card state whenever cached config changes.
		if _card_has_update_card_state_from_settings:
			card._update_card_state_from_settings()

func refresh_all_card_displays() -> void:
	"""Refresh text/display state on all active cards without rebuilding effects.
	Used for settings like library_show_title_mode."""
	for card in _active_cards:
		if is_instance_valid(card) and _card_has_update_display:
			card.update_display()

func _update_cache_access_order(cache_key: int):
	_lru_counter += 1
	_cache_lru_tick[cache_key] = _lru_counter

func _evict_oldest_cache_entries(count: int):
	var to_evict = mini(count, _data_cache.size())
	if to_evict <= 0:
		return

	# Linear scan for oldest entry, repeated to_evict times.
	# Avoids allocating an Array[Array] of all entries (~5000 sub-arrays).
	for i in range(to_evict):
		var oldest_key = -1
		var oldest_tick = INF

		for key in _cache_lru_tick.keys():
			var tick = _cache_lru_tick[key]
			if tick < oldest_tick:
				oldest_tick = tick
				oldest_key = key

		if oldest_key < 0:
			break

		_cache_lru_tick.erase(oldest_key)
		if _data_cache.has(oldest_key):
			var game = _data_cache[oldest_key]
			if game and game.romm_id != 0:
				_cached_game_ids.erase(game.romm_id)
			_data_cache.erase(oldest_key)
