class_name VirtualScrollGridContainer
extends Control

# Global startup guard: suppresses all layout work until Main is ready for the
# single final settle. This prevents visible "jank" from layout passes before
# the saved window size and saved zoom are stable.
static var startup_layout_suppressed: bool = true

## Card capability probes, keyed by card scene path, shared across all grids
## so only the first grid pays the probe instantiation.
static var _capability_probe_cache: Dictionary = {}

# Libraries below this size load all cards at once to avoid partial-row recycling
# edge cases. Above this threshold only visible cards plus a buffer are created.
const SMALL_LIBRARY_THRESHOLD: int = 50

# Upper bound for a single data request. Legitimate batches cover one buffer
# window or a preload span (tens of items); anything larger indicates a
# pathological state and would stall the DB worker.
const MAX_DATA_REQUEST_ITEMS: int = 500

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
## Gates the high-frequency per-pass trace prints ([GridTrace] pass/pass-end)
## so diagnostics stop inflating frame time. Violation logs
## ([GridInv], [VisHole], [CardApply], [RsAudit], [LayerAudit]) always print.
var trace_verbose: bool = false
enum ViewMode { GRID, LIST, CAROUSEL }
enum FocusCentering { MARGIN, CENTER }

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
	# GRID mode with a trustworthy size: convert to the nearest stop silently
	# (batch contexts recalculate once at the end).
	if view_mode == ViewMode.GRID and not startup_layout_suppressed and _has_valid_available_size():
		return _set_grid_n_silent(_get_nearest_level_for_ratio(clamped))
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
	if new_mode == ViewMode.GRID:
		if state.card_zoom_level >= 0:
			zoom_changed = _apply_zoom_level(state.card_zoom_level)
		else:
			zoom_changed = _apply_zoom_ratio(state.card_zoom_ratio)
	else:
		# LIST/CAROUSEL have their own per-mode zoom ratio.
		zoom_changed = _apply_zoom_ratio(state.card_zoom_list_ratio)
	if debug_mode:
		print("[Grid] _batch_apply_layout_state after zoom: target_ratio=", target_card_width_ratio, " zoom_changed=", zoom_changed, " card_size=", card_size)
	var focus_changed: bool = _apply_focus_scale(1.0 + state.focus_scale_ratio)
	# Apply the flag (also converged in _refresh_cached_settings), but detect
	# changes against the layout-applied cache: it reflects what is actually
	# built (spacers, snap state), not what flag is set.
	_apply_pagination_enabled(state.pagination_enabled)
	_apply_staggered(state.grid_staggered)
	var pagination_changed: bool = pagination_enabled != _last_layout_pagination
	var staggered_changed: bool = staggered != _last_layout_staggered

	if not structure_changed and not zoom_changed and not padding_changed and not focus_changed and not pagination_changed and not staggered_changed:
		if debug_mode: print("[Grid] _batch_apply_layout_state: no changes (structure=", structure_changed, " zoom=", zoom_changed, " padding=", padding_changed, " focus=", focus_changed, " pagination=", pagination_changed, " staggered=", staggered_changed, ")")
		return

	if debug_mode:
		print("[Grid] _batch_apply_layout_state: structure=", structure_changed, " zoom=", zoom_changed, " padding=", padding_changed, " focus=", focus_changed, " pagination=", pagination_changed, " staggered=", staggered_changed)

	if structure_changed:
		# One rebuild path: configure flags then refresh buffer, which recalculates layout.
		_refresh_buffer(true)
		queue_redraw()
	else:
		# Non-structure changes share the same rebuild path to guarantee a single recalc.
		if focus_changed or padding_changed or pagination_changed or staggered_changed:
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

# Universal outer margin: insets the scroll container (and the effective
# viewport for all layout math) on all four sides. Internal for now.
const GRID_OUTER_MARGIN_DP := 22.0
var grid_outer_margin: int = 0

## When true (GRID mode only), the grid is split into viewport-sized pages
## separated by spacer lines in the flow; scrolling snaps between pages.
var pagination_enabled: bool = false

## When true (vertical GRID only), every other row is offset by half a card
## width (brick pattern); offset rows hold one fewer card via a leading
## half-cell spacer in the flow.
var staggered: bool = false

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
## Minimum cross-axis card size as a fraction of the base card dimension.
## Determines the most zoomed-out stop (N_max) for the current viewport.
const MIN_CARD_SIZE_FRACTION := 0.45
## Hard cap on the number of discrete zoom stops so the slider stays usable.
const MAX_ZOOM_STOPS := 12
## Zoom stops are whole items-per-line counts from 2 up to this many with
## single-step spacing; beyond it stops are spaced by 2 up to N_max.
const ZOOM_SINGLE_STEP_MAX := 6

# Source of truth for GRID-mode zoom: the exact number of items per line.
# 0 = unset; derived from target_card_width_ratio on the next valid layout.
var _grid_items_per_line: int = 0

# Scroll anchor snapshot (x = virtual index, y = intra-line fraction; x < 0 =
# unset). Captured by _set_grid_n_silent BEFORE items-per-line changes so
# _recalculate_layout can restore the view in index space; capturing after the
# N change would compute the anchor against the NEW items-per-line, which
# preserves the line number instead of the content (teleport on zoom).
var _scroll_anchor: Vector2 = Vector2(-1.0, 0.0)

# Target of a guarded scroll write made during a layout recalc (< 0 = none).
# The ScrollContainer's scrollbar range is stale mid-frame (it updates at the
# end-of-frame sort), so a write beyond the old range gets clamped; the clamp
# emits value_changed with the clamped value, which would rebuild the buffer
# window at the wrong offset. While this is set, the scroll handler ignores
# values that are clearly the clamp echo rather than the intended position.
var _guarded_scroll_target: float = -1.0
var _guarded_scroll_attempts: int = 0
const MAX_GUARDED_SCROLL_ATTEMPTS: int = 3
var _grid_trace_stuck_count: int = 0
var _last_pass_scroll: float = -1.0
var _last_pass_time_ms: int = 0
var _scroll_velocity: float = 0.0
var _last_pass_buffer_start: int = -1
var _last_pass_buffer_end: int = -1
var _last_stamp_scroll: float = -1.0
var _last_stamp_margin: int = -1
var _last_stamp_first: int = -1
var _last_stamp_count: int = -1
var _last_stamp_generation: int = -1
## Incremented on every completed full layout pass and every FlowContainer
## sort. Part of the pre-draw stamp gate so stamps always follow layout
## changes even when scroll/margin/window didn't move.
var _layout_generation: int = 0
var _layout_settled_with_valid_size: bool = false
## Forces the next _recalculate_layout past its input-cache early-exit (set
## when a valid size first arrives after an invalid settle).
var _force_layout_once: bool = false

# Zoom-stop caches (rebuilt when the cache key changes)
var _snap_levels_cache: Array[int] = []
var _snap_levels_key: String = ""

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
		# GRID mode with a trustworthy size: snap to the nearest items-per-line
		# stop and let N drive the layout exactly (recalculates internally).
		if view_mode == ViewMode.GRID and not startup_layout_suppressed and _has_valid_available_size():
			if not _set_grid_items_per_line(_get_nearest_level_for_ratio(clamped)):
				# N unchanged, but callers (e.g. refresh_dimensions) expect the
				# setter to run a layout pass; _recalculate_layout() early-exits
				# cheaply when nothing changed.
				_recalculate_layout()
			return
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

# Cached focus-centering mode (synced from CardSettingsState)
var _focus_centering_mode: int = FocusCentering.MARGIN

# Focus target for an in-flight programmatic scroll-and-focus sequence.
# Cleared (and the scroll container's follow-focus suppression lifted) once the
# scroll settles; polled in _process().
var _programmatic_focus_index: int = -1

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
# Real item count from the data source. _total_items is the geometry count:
# padded with placeholder slots (trailing) so pages/rows always fill evenly.
var _source_total_items: int = 0
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
var _card_has_sync_visual_offset: bool = false
var _card_has_mark_visuals_position_synced: bool = false
var _card_has_unmark_visuals_position_synced: bool = false
var _card_has_show_loading_skeleton: bool = false
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
var _last_layout_pagination: bool = false
var _last_layout_staggered: bool = false
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
# Guards _pending_loads: DB worker threads check is_load_pending() to skip
# stale queries superseded by jumps/refreshes while they were queued.
var _pending_loads_mutex: Mutex = Mutex.new()

# Deduplication tracking - prevents duplicate game entries
var _cached_game_ids: Dictionary = {}  # romm_id -> cache_key

const MAX_CACHE_SIZE: int = 5000
# Insertion-ordered LRU: front = least recently used, back = most recent.
var _cache_lru_tick: Dictionary[int, bool] = {}

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
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER if grid_vertical else ScrollContainer.SCROLL_MODE_DISABLED
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if grid_vertical else ScrollContainer.SCROLL_MODE_SHOW_NEVER
			_flow_container.vertical = not grid_vertical
		ViewMode.LIST:
			_scroll_container.vertical = true
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_flow_container.vertical = false
		ViewMode.CAROUSEL:
			_scroll_container.vertical = false
			_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
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
			# Inverted focus: focused_card_size == card_size, so this is zero;
			# unfocused cards shrink inward and never overflow.
			return Vector2(0.0, maxf(0.0, (focused_card_size.y - card_size.y) / 2.0))
		ViewMode.CAROUSEL:
			return Vector2(maxf(0.0, (focused_card_size.x - card_size.x) / 2.0), 0.0)
	return Vector2.ZERO

func _get_focus_scale_inverted() -> bool:
	# LIST/CAROUSEL: card starts at 1.0/focus_scale and grows to 1.0 when focused.
	# GRID: card starts at 1.0 and grows to focus_scale when focused.
	return view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL

func _get_available_size() -> Vector2:
	# The outer margin insets the effective viewport on all sides; every layout
	# consumer (zoom stops, exact-fill, centering, visible ranges, page groups)
	# computes against this inset size.
	var inset := Vector2(grid_outer_margin * 2.0, grid_outer_margin * 2.0)
	# During deterministic sizing, use the size supplied by Main/UIManager rather
	# than the grid's own size, which may not reflect the final container size yet.
	if _deterministic_available_size.x > 0.0 and _deterministic_available_size.y > 0.0:
		if debug_mode:
			print("[Grid] _get_available_size: using deterministic available size=", _deterministic_available_size)
		return Vector2(maxf(_deterministic_available_size.x - inset.x, 1.0), maxf(_deterministic_available_size.y - inset.y, 1.0))

	var result = Vector2(maxf(size.x - inset.x, 1.0), maxf(size.y - inset.y, 1.0))
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
	var line = _get_line_for_index(idx, items_per_line)
	var pos = line * stride
	if _is_pagination_active():
		# Page groups are separated by a spacer gap in the scroll direction;
		# the leading pad lets page 0 sit centered at scroll 0.
		pos += _get_page_leading_pad() + int(line / get_lines_per_page()) * _get_page_gap()
	return pos

func set_focused_card(virtual_index: int) -> void:
	if _focused_virtual_index == virtual_index:
		return
	_focused_virtual_index = virtual_index
	_update_layout()
	_update_margin()

## Captures the current scroll position as an index-space anchor:
## Vector2(x = anchor virtual index, y = intra-line fraction), or x = -1 when
## no valid anchor exists. The anchor is the focused card when there is one,
## else the first slot of the top visible line. MUST be called before any
## geometry change (items-per-line / card size) it is meant to survive.
func _capture_scroll_anchor(focus_index: int) -> Vector2:
	if not _scroll_container or _source_total_items <= 0:
		return Vector2(-1.0, 0.0)
	var scroll_pos: float = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
	var stride: float = _get_normal_stride()
	var items_per_line: int = _get_items_per_line()
	if stride <= 0.0 or items_per_line <= 0:
		return Vector2(-1.0, 0.0)
	if focus_index >= 0:
		var anchor_index = mini(focus_index, _source_total_items - 1)
		var frac = (scroll_pos - _get_slot_position_for_index(anchor_index, items_per_line, stride)) / stride
		return Vector2(anchor_index, frac)
	var top_line = int(floor(scroll_pos / stride))
	var anchor_index2 = clampi(_get_first_index_for_line(top_line, items_per_line), 0, _source_total_items - 1)
	var frac2 = (scroll_pos - top_line * stride) / stride
	return Vector2(anchor_index2, frac2)

func _ready():
	_setup_ui()

	if not RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
	# frame_post_draw (DrawAudit) connects in _update_debug_mode — debug-only.

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
	if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw_audit)
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
	_focus_centering_mode = clampi(state.focus_centering_mode, 0, 1)
	# Converge the pagination flag with the shared state. Grids otherwise only
	# learn it via the changed() signal, which fires before grids connect at
	# startup and never reaches lazily created views — leaving the member out
	# of sync with the persisted setting (double-click menu bug).
	_apply_pagination_enabled(state.pagination_enabled)
	_apply_staggered(state.grid_staggered)

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

func _gui_input(event: InputEvent) -> void:
	# Wheel over the grid's outer margin (the inset area around the scroll
	# container) should still scroll; forward to the scroll container's wheel
	# handler. Events over the scroll container itself are accepted there and
	# never propagate here.
	if _scroll_container and event is InputEventMouseButton and event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_scroll_container._on_gui_input(event)

func _process(_delta: float):
	if _is_processing_scroll:
		_is_processing_scroll = false
		push_warning("[Grid] _is_processing_scroll was left set between frames; force-cleared")

	if _resize_debounce_frames > 0:
		_resize_debounce_frames -= 1
		if _resize_debounce_frames == 0:
			_on_resize_debounced()

	# A programmatic scroll-and-focus sequence has settled (completed or was
	# interrupted): lift follow-focus suppression and focus the target card if
	# nothing inside the grid ended up focused (e.g. the card only entered the
	# buffer near the end of a long scroll).
	if _programmatic_focus_index >= 0 and _scroll_container and not _scroll_container.is_scrolling():
		var idx := _programmatic_focus_index
		_programmatic_focus_index = -1
		_scroll_container.follow_focus_suppressed = false
		_pending_focus_index = -1
		var focused_owner: Control = null
		var viewport := get_viewport()
		if viewport:
			focused_owner = viewport.gui_get_focus_owner()
		if not focused_owner or not is_ancestor_of(focused_owner):
			var card := get_card_at_index(idx)
			if card and is_instance_valid(card) and card.is_inside_tree():
				_apply_focus_to_card(card)

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
	# If the grid was settled before its size was valid (e.g. size-0 startup
	# settle), force the next layout past its input-cache early-exit now that
	# real geometry exists — the early-exit would otherwise stand forever.
	if _has_valid_available_size() and not _layout_settled_with_valid_size:
		_force_layout_once = true
		_recalculate_layout()
	if view_mode == ViewMode.GRID:
		# N is the source of truth: it survives resizes and is clamped to the
		# new viewport's stop range inside _recalculate_layout(). If N was never
		# derived (fresh grid), seed it from the saved zoom level.
		if _grid_items_per_line <= 0 and UIManager and UIManager.card_settings_state and UIManager.card_settings_state.card_zoom_level >= 0:
			_apply_zoom_level(UIManager.card_settings_state.card_zoom_level)
		_recalculate_layout()
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
		_apply_zoom_level(UIManager.card_settings_state.card_zoom_level)
		_recalculate_layout()
	elif view_mode == ViewMode.GRID:
		# No saved level: lock in N from the saved ratio now that the size is final.
		_set_grid_n_silent(_get_nearest_level_for_ratio(target_card_width_ratio))
		_recalculate_layout()
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
	while current_last < _buffer_target_end - 1 and current_last < _total_items - 1 and added < ASYNC_BUFFER_CARDS_PER_FRAME and WarmupBudget.try_spend(WarmupBudget.COST_CARD_INSTANTIATE_US):
		_add_card_at_end(current_last + 1)
		current_last = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
		added += 1

	current_first = _active_cards[0].get_meta("virtual_index", 0)
	while current_first > _buffer_target_start and current_first > 0 and added < ASYNC_BUFFER_CARDS_PER_FRAME and WarmupBudget.try_spend(WarmupBudget.COST_CARD_INSTANTIATE_US):
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
		call_deferred("_sync_and_mark_card_visual_transforms", "buffer-expansion")

	if current_first <= _buffer_target_start and current_last >= _buffer_target_end - 1:
		_pending_buffer_expansion = false
		if debug_mode:
			print("[Grid] async buffer expansion complete")

func _process_pending_visual_setup() -> void:
	if _pending_visual_setup.is_empty():
		return

	if debug_mode:
		print("[Grid] _process_pending_visual_setup: pending_size=", _pending_visual_setup.size())
	var processed: int = 0
	var keys := _pending_visual_setup.keys()
	# Not budget-gated: this drain services ACTIVE cards (a pending card has
	# no game assigned and renders invisible). Starving it hides rows.
	while processed < ASYNC_SETUP_CARDS_PER_FRAME and not keys.is_empty():
		var idx = keys[0]
		keys.remove_at(0)
		var card = _pending_visual_setup[idx]
		if not is_instance_valid(card) or not _active_cards.has(card):
			_pending_visual_setup.erase(idx)
			continue
		# Count ATTEMPTS toward the per-frame budget, not just successes:
		# cards whose data hasn't arrived yet stay pending, and without an
		# attempt cap the loop iterates the entire pending dict every frame
		# (livelock when many cards are waiting on the DB).
		processed += 1
		var setup_ok = _apply_card_visual_setup(card, idx)
		if debug_mode: print("[Grid] _process_pending_visual_setup: idx=", idx, " setup_ok=", setup_ok)
		if setup_ok:
			_pending_visual_setup.erase(idx)
		else:
			# Re-queue at the end (dicts iterate in insertion order) so a run
			# of data-starved cards at the front can't block the rest.
			_pending_visual_setup.erase(idx)
			_pending_visual_setup[idx] = card
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

func _snap_levels_cache_key(base_dims: Vector2, available: Vector2) -> String:
	return "%d|%d|%d|%d|%d|%d" % [int(base_dims.x), int(base_dims.y), int(available.x), int(available.y), grid_separation, 1 if vertical else 0]

## Ascending items-per-line stops for the current viewport (index = zoom level).
## Every stop exactly fills the viewport cross-axis with whole cards.
## Do not mutate the returned array (it is the cache).
func get_snap_levels() -> Array[int]:
	if view_mode != ViewMode.GRID or not _has_valid_available_size():
		return []
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var key := _snap_levels_cache_key(base_dims, available)
	if key == _snap_levels_key and not _snap_levels_cache.is_empty():
		return _snap_levels_cache
	_snap_levels_cache = _compute_snap_levels(base_dims, available)
	_snap_levels_key = key
	return _snap_levels_cache

func _compute_snap_levels(base_dims: Vector2, available: Vector2) -> Array[int]:
	# Largest N whose exact-fill card still meets the minimum size floor.
	var cross_axis := available.x if vertical else available.y
	var base_cross := base_dims.x if vertical else base_dims.y
	var min_card := base_cross * MIN_CARD_SIZE_FRACTION
	var n_max := maxi(2, int((cross_axis + grid_separation) / (min_card + grid_separation)))

	# Single-step stops for the common range, then coarser steps up to N_max
	# so huge viewports don't drown the slider in ticks. N_max is always a stop.
	var levels: Array[int] = []
	var n := 2
	while n <= mini(n_max, ZOOM_SINGLE_STEP_MAX):
		levels.append(n)
		n += 1
	n = ZOOM_SINGLE_STEP_MAX + 2
	while n < n_max:
		levels.append(n)
		n += 2
	if levels.is_empty() or levels[-1] != n_max:
		levels.append(n_max)
	# Keep the slider usable: trim stops adjacent to N_max first so both the
	# small-N range and the extreme zoom-out stop survive.
	while levels.size() > MAX_ZOOM_STOPS:
		levels.remove_at(levels.size() - 2)
	return levels

## Returns descending snap ratios (index 0 = largest cards) for the current
## viewport configuration — a legacy view over the items-per-line stops.
## Prefer get_snap_levels() for new code.
func get_snap_ratios() -> Array[float]:
	var ratios: Array[float] = []
	if view_mode != ViewMode.GRID or not _has_valid_available_size():
		return ratios
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var viewport_area = available.x * available.y
	var levels = get_snap_levels()
	for i in range(levels.size() - 1, -1, -1):
		ratios.append(_compute_ratio_for_items_per_line(levels[i], base_dims, available, viewport_area))
	if ratios.size() < 2:
		push_warning("[VirtualScrollGridContainer] Only %d snap ratio(s) for view_mode=%s, size=%s, base_dims=%s, available=%s" % [ratios.size(), view_mode, size, base_dims, available])
	return ratios

## Returns snap ratios sorted ascending (index 0 = most items per line).
## The slider index maps directly to a zoom level.
func get_snap_ratios_ascending() -> Array[float]:
	var snap_ratios := get_snap_ratios()
	snap_ratios.reverse()
	return snap_ratios

## Returns the snap ratio for the given zoom level using the current grid's
## available size. Used to apply the shared zoom level across views.
func _get_snap_ratio_for_level(level: int) -> float:
	var levels = get_snap_levels()
	if levels.is_empty():
		return target_card_width_ratio
	var available = _get_available_size()
	return _compute_ratio_for_items_per_line(levels[clampi(level, 0, levels.size() - 1)], _get_base_dimensions_for_mode(), available, available.x * available.y)

## Index of the current items-per-line within the stop list (0 = most zoomed out).
## Pass from_ratio to resolve a level for an arbitrary ratio (e.g. a saved one)
## instead of the grid's current zoom. Does not mutate zoom state.
func get_zoom_level(from_ratio: float = -1.0) -> int:
	var levels = get_snap_levels()
	if levels.is_empty():
		return -1
	var n = _grid_items_per_line
	if from_ratio >= 0.0:
		n = _get_nearest_level_for_ratio(from_ratio)
	elif n <= 0:
		n = _get_nearest_level_for_ratio(target_card_width_ratio)
	var best := 0
	for i in range(levels.size()):
		if absi(levels[i] - n) < absi(levels[best] - n):
			best = i
	return best

## Applies a zoom level (index into get_snap_levels()) and recalculates layout.
## Returns true if the items-per-line changed.
func set_zoom_level(level: int) -> bool:
	var levels = get_snap_levels()
	if levels.is_empty():
		return false
	return _set_grid_items_per_line(levels[clampi(level, 0, levels.size() - 1)])

## Stamps a zoom level without recalculating layout. Intended for hidden views:
## the layout settles when the view is next shown (View.on_view_show runs
## recalculate_layout_with_size). Returns true if N changed.
func stamp_zoom_level(level: int) -> bool:
	var levels = get_snap_levels()
	if levels.is_empty():
		return false
	return _set_grid_n_silent(levels[clampi(level, 0, levels.size() - 1)])

## Stamps a LIST/CAROUSEL zoom ratio without recalculating layout (hidden views
## settle on show).
func stamp_zoom_ratio(p_ratio: float) -> void:
	var max_ratio = _calculate_max_ratio()
	var clamped = clampf(p_ratio, 0.05, max_ratio)
	_batching_layout = true
	target_card_width_ratio = clamped
	_batching_layout = false

## Applies the given zoom level without triggering a layout recalculation
## (batch contexts recalculate once at the end). Returns true if N changed.
func _apply_zoom_level(p_level: int) -> bool:
	var levels = get_snap_levels()
	if levels.is_empty():
		return false
	return _set_grid_n_silent(levels[clampi(p_level, 0, levels.size() - 1)])

func _set_grid_items_per_line(n: int) -> bool:
	if not _set_grid_n_silent(maxi(2, n)):
		return false
	_recalculate_layout()
	return true

func _set_grid_n_silent(n: int) -> bool:
	if _grid_items_per_line == n:
		return false
	# Snapshot the scroll anchor BEFORE N changes (see _scroll_anchor).
	_scroll_anchor = _capture_scroll_anchor(_get_focused_virtual_index())
	_grid_items_per_line = n
	# Keep the derived ratio in sync for persistence/UI without re-entering
	# the snapping path.
	if _has_valid_available_size():
		var available = _get_available_size()
		_batching_layout = true
		target_card_width_ratio = _compute_ratio_for_items_per_line(n, _get_base_dimensions_for_mode(), available, available.x * available.y)
		_batching_layout = false
	return true

## Maps a viewport-area ratio to the nearest items-per-line stop.
func _get_nearest_level_for_ratio(p_ratio: float) -> int:
	var levels: Array[int] = get_snap_levels()
	if levels.is_empty():
		return 2
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var viewport_area = available.x * available.y
	var base_area = base_dims.x * base_dims.y
	var n: int = levels[levels.size() - 1]
	if viewport_area > 0.0 and base_area > 0.0:
		var card_area = viewport_area * p_ratio * p_ratio
		var desired_zoom = sqrt(card_area / base_area)
		var desired_cross = (base_dims.x if vertical else base_dims.y) * desired_zoom
		var cross_axis = available.x if vertical else available.y
		n = clampi(int(round((cross_axis + grid_separation) / maxf(1.0, desired_cross + grid_separation))), 2, levels[levels.size() - 1])
	# Snap to the nearest available stop.
	var best: int = levels[0]
	for l in levels:
		if absi(l - n) < absi(best - n):
			best = l
	return best

## The effective items-per-line for GRID layout. Derives from the legacy ratio
## once a trustworthy size is available; 0 means "stay on the ratio path".
func _get_effective_grid_n() -> int:
	if _grid_items_per_line > 0:
		return _grid_items_per_line
	# During startup suppression sizes can be transient — don't lock in an N yet.
	if not startup_layout_suppressed and _has_valid_available_size():
		_grid_items_per_line = _get_nearest_level_for_ratio(target_card_width_ratio)
	return _grid_items_per_line

## Whole lines (rows when vertical, columns when horizontal) that fit in the
## viewport on the scroll axis. Groundwork for paged scrolling.
func get_lines_per_page() -> int:
	var stride = _get_normal_stride()
	if stride <= 0.0:
		return 1
	var available = _get_available_size()
	var axis = available.y if vertical else available.x
	var lpp = maxi(1, int((axis + grid_separation) / stride))
	# Staggered pages must start on a full (even) row so every page has the
	# same composition: round down to an even line count.
	if _is_staggered_active() and lpp >= 2:
		lpp -= lpp % 2
	return lpp

# ---------------------------------------------------------------------------
# Pagination (GRID mode only)
# ---------------------------------------------------------------------------

func _is_pagination_active() -> bool:
	return pagination_enabled and view_mode == ViewMode.GRID

func _apply_pagination_enabled(p_enabled: bool) -> bool:
	if pagination_enabled == p_enabled:
		return false
	pagination_enabled = p_enabled
	return true

func _apply_staggered(p_staggered: bool) -> bool:
	if staggered == p_staggered:
		return false
	staggered = p_staggered
	return true

## Staggered brick layout only applies to the vertical grid.
func _is_staggered_active() -> bool:
	return staggered and view_mode == ViewMode.GRID and vertical

## Scroll-axis extent of one page's cards (no trailing separation).
func _get_page_content_size() -> float:
	return get_lines_per_page() * _get_normal_stride() - grid_separation

## Blank space between page groups in the scroll direction: the leftover slack
## plus one full stride, so the next page always starts beyond the viewport's
## far edge and neighbors are never visible at rest (no culling needed).
func _get_page_gap() -> float:
	if not _is_pagination_active():
		return 0.0
	var available = _get_available_size()
	var axis = available.y if vertical else available.x
	return (axis - _get_page_content_size()) + _get_normal_stride()

## Scroll-axis distance from one page start to the next (page + gap).
func _get_page_period() -> float:
	if not _is_pagination_active():
		return 0.0
	return get_lines_per_page() * _get_normal_stride() + _get_page_gap()

## Scroll offset subtracted from page-start targets so each page sits centered
## in the viewport (blank slack split into balanced gutters on both sides).
func _get_page_center_offset() -> float:
	if not _is_pagination_active():
		return 0.0
	var available = _get_available_size()
	var axis = available.y if vertical else available.x
	return maxf(0.0, (axis - _get_page_content_size()) / 2.0)

## Total line count (rows/columns) across all items.
func _get_total_lines() -> int:
	var items_per_line = _get_items_per_line()
	if items_per_line <= 0 or _total_items <= 0:
		return 0
	if _is_staggered_active():
		return _get_stagger_line_for_index(_total_items - 1) + 1
	return ceili(float(_total_items) / items_per_line)

func _get_page_count() -> int:
	var lpp = get_lines_per_page()
	var total_lines = _get_total_lines()
	if lpp <= 0 or total_lines <= 0:
		return 1
	return int((total_lines - 1) / lpp) + 1

## Leading blank pad before slot 0: equals the center offset so page 0's
## centered target lands exactly at scroll 0 instead of clamping flush-left.
func _get_page_leading_pad() -> float:
	return _get_page_center_offset()

## Trailing blank pad after the last line: enough for even a PARTIAL last page
## to reach its centered scroll target (its content plus this pad spans the
## same centered extent as a full page).
func _get_page_trailing_pad() -> float:
	if not _is_pagination_active():
		return 0.0
	var stride = _get_normal_stride()
	var lpp = get_lines_per_page()
	var total_lines = _get_total_lines()
	if stride <= 0.0 or lpp <= 0 or total_lines <= 0:
		return 0.0
	var last_page = int((total_lines - 1) / lpp)
	var lines_in_last = total_lines - last_page * lpp
	var last_content = lines_in_last * stride - grid_separation
	return (_get_page_content_size() - last_content) + _get_page_center_offset()

## Snapped scroll position for page `page` (centered, clamped to range).
## With the leading pad in the slot transform, targets are simply k * period.
func _get_page_scroll_target(page: int) -> float:
	page = clampi(page, 0, _get_page_count() - 1)
	return _clamp_scroll_to_range(page * _get_page_period())

## Page index containing slot `idx`.
func _get_page_for_index(idx: int) -> int:
	var items_per_line = _get_items_per_line()
	if items_per_line <= 0:
		return 0
	return int(float(_get_line_for_index(idx, items_per_line)) / get_lines_per_page())

# --- Staggered rows ---------------------------------------------------------
# In staggered mode (vertical GRID only) rows alternate capacities: even rows
# hold N cards, odd rows hold N-1 and start half a stride to the right via a
# leading half-cell spacer in the flow. All scroll-axis math stays line-based
# (uniform row stride); only the index<->line mapping changes.

## Items in one full two-row stagger unit (N even-row + N-1 odd-row).
func _get_stagger_pair_count() -> int:
	return maxi(1, 2 * _get_items_per_line() - 1)

func _get_stagger_line_for_index(idx: int) -> int:
	var n = _get_items_per_line()
	var pair = _get_stagger_pair_count()
	var unit = int(idx / pair)
	var rem = idx - unit * pair
	return unit * 2 + (0 if rem < n else 1)

## Cards on a staggered row (N on even rows, N-1 on offset/odd rows).
func _get_stagger_line_capacity(line: int) -> int:
	return _get_items_per_line() - (1 if line % 2 == 1 else 0)

func _get_stagger_first_index_for_line(line: int) -> int:
	var pair = _get_stagger_pair_count()
	var unit = int(line / 2)
	return unit * pair + (_get_items_per_line() if line % 2 == 1 else 0)

## Line an item sits on (uniform mapping unless staggered).
func _get_line_for_index(idx: int, items_per_line: int = -1) -> int:
	if _is_staggered_active():
		return _get_stagger_line_for_index(idx)
	if items_per_line < 0:
		items_per_line = _get_items_per_line()
	return int(float(idx) / items_per_line)

## First item index of a line (uniform mapping unless staggered).
func _get_first_index_for_line(line: int, items_per_line: int = -1) -> int:
	if _is_staggered_active():
		return _get_stagger_first_index_for_line(line)
	if items_per_line < 0:
		items_per_line = _get_items_per_line()
	return line * items_per_line

## Inverse of the (page-gapped) slot position transform.
func _get_line_for_scroll_pos(pos: float) -> int:
	var stride = _get_normal_stride()
	if stride <= 0.0:
		return 0
	if not _is_pagination_active():
		return int(pos / stride)
	var lpp = get_lines_per_page()
	var period = _get_page_period()
	if period <= 0.0:
		return int(pos / stride)
	var rel = pos - _get_page_leading_pad()
	if rel <= 0.0:
		return 0
	var page = int(rel / period)
	var rem = rel - page * period
	# A position inside the gap clamps to the last line of that page.
	var line_in_page = mini(int(rem / stride), lpp - 1)
	return page * lpp + maxi(0, line_in_page)

## Scroll-axis position of the end of the last line, including the trailing
## pad that lets partial last pages center (no trailing page gap).
func _get_content_end_position() -> float:
	if _total_items <= 0:
		return 0.0
	return _get_slot_position_for_index(_total_items - 1) + _get_normal_stride() + _get_page_trailing_pad()

## Nearest snapped page target to `pos`.
func _snap_to_page_target(pos: float) -> float:
	var period = _get_page_period()
	if period <= 0.0:
		return pos
	var page = clampi(int(round(pos / period)), 0, _get_page_count() - 1)
	return page * period

## Pushes the snap period/offset to the scroll container and re-aligns the
## current scroll to a page target. Called after layout recalcs so the view
## never rests mid-gap after zoom/resize/orientation changes.
func _update_page_snap_state() -> void:
	if not _scroll_container:
		return
	if not _is_pagination_active():
		if _scroll_container.page_snap_period != 0.0:
			_scroll_container.page_snap_period = 0.0
			_scroll_container.page_snap_offset = 0.0
			_scroll_container.page_snap_max_target = -1.0
		return
	_scroll_container.page_snap_period = _get_page_period()
	_scroll_container.page_snap_offset = 0.0
	_scroll_container.page_snap_max_target = (_get_page_count() - 1) * _get_page_period()
	if debug_mode:
		print("[Grid] _update_page_snap_state: period=", _get_page_period(), " max_target=", _scroll_container.page_snap_max_target, " pages=", _get_page_count(), " lpp=", get_lines_per_page(), " stride=", _get_normal_stride(), " axis=", (_get_available_size().y if vertical else _get_available_size().x))
	var current := _get_current_scroll_pos()
	var snapped := _clamp_scroll_to_range(_snap_to_page_target(current))
	if not is_equal_approx(snapped, current):
		# A page snap supersedes any pending guarded recalc write: without
		# clearing the guard, the snap's signal can be echo-skipped (buffer
		# never rebuilds at the snap) or the guard's deferred corrective can
		# yank the view back off the page target.
		_reset_transient_scroll_state("page_snap")
		_scroll_container.scroll_to(int(snapped), false)
	# Re-apply the snap after the ScrollContainer's end-of-frame sort, whose
	# clamp can otherwise undo it and leave the view between pages. The
	# generation guard coalesces zoom drags so only the last recalc applies.
	_page_snap_generation += 1
	call_deferred("_deferred_page_snap", _page_snap_generation)

var _page_snap_generation: int = 0

func _deferred_page_snap(generation: int) -> void:
	if generation != _page_snap_generation:
		return
	if not _scroll_container or not _is_pagination_active():
		return
	var current := _get_current_scroll_pos()
	var snapped := _clamp_scroll_to_range(_snap_to_page_target(current))
	if not is_equal_approx(snapped, current):
		_reset_transient_scroll_state("page_snap_deferred")
		_scroll_container.scroll_to(int(snapped), false)

## Wheel page-step target, resolved through the same target math as
## keyboard/controller navigation (single source of truth for page targets).
func _on_page_step_request(direction: int) -> float:
	if not _is_pagination_active() or not _scroll_container:
		return 0.0
	var period := _get_page_period()
	if period <= 0.0:
		return 0.0
	# Queue from the tween's destination so rapid ticks chain multiple pages.
	var base := _scroll_container.get_target_scroll()
	var page := int(round(base / period))
	var target := _get_page_scroll_target(page + direction)
	if debug_mode:
		print("[Grid] page step: base=", base, " period=", period, " page=", page, " dir=", direction, " target=", target)
	return target

# --- Page spacers -----------------------------------------------------------
# Spacers are real (visible, but non-rendering) Controls inside the flow that
# each own one whole line, forcing the FlowContainer wrap that creates the
# visual gap between pages. They never carry a virtual_index and are not part
# of _active_cards; the invariant is:
#   "a spacer sits between two consecutive card children iff their lines are
#    on different pages; no leading or trailing spacers."

func _make_page_spacer() -> Control:
	var spacer := Control.new()
	spacer.set_meta("page_spacer", true)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.focus_mode = Control.FOCUS_NONE
	spacer.custom_minimum_size = _get_page_spacer_size()
	return spacer

## Spacer dimensions: full line on the cross axis (forces the wrap). The
## scroll-axis extent is gap - separation because the FlowContainer adds its
## own line separation after the spacer line.
func _get_page_spacer_size() -> Vector2:
	var extent = maxf(1.0, _get_page_gap() - grid_separation)
	var items_per_line = maxi(1, _get_items_per_line())
	if vertical:
		var row_width = items_per_line * card_size.x + max(0, items_per_line - 1) * grid_separation
		return Vector2(row_width, extent)
	var col_height = items_per_line * card_size.y + max(0, items_per_line - 1) * grid_separation
	return Vector2(extent, col_height)

func _add_page_spacer(flow_index: int = -1) -> void:
	if not _flow_container:
		return
	var spacer = _make_page_spacer()
	_flow_container.add_child(spacer)
	if flow_index >= 0:
		_flow_container.move_child(spacer, flow_index)

func _free_page_spacer(spacer: Control) -> void:
	_flow_container.remove_child(spacer)
	spacer.queue_free()

## Removes any leading/trailing spacers (recycling is contiguous from the
## ends, so orphaned spacers can only ever appear at the edges).
func _prune_edge_spacers() -> void:
	if not _flow_container:
		return
	while _flow_container.get_child_count() > 0:
		var first = _flow_container.get_child(0)
		if first.has_meta("page_spacer"):
			_free_page_spacer(first)
			continue
		if first.has_meta("stagger_spacer"):
			# A leading stagger spacer stays LIVE while any card of its odd row
			# still follows it: partial rows keep their half-cell indent while
			# the window recycles through them. Only a spacer whose row is fully
			# gone (next child is a spacer, an even-row card, or nothing) dies.
			var next = _flow_container.get_child(1) if _flow_container.get_child_count() > 1 else null
			if next and not next.has_meta("page_spacer") and not next.has_meta("stagger_spacer"):
				var next_idx: int = next.get_meta("virtual_index", -1)
				if next_idx >= 0 and _is_staggered_active() and _get_stagger_line_for_index(next_idx) % 2 == 1:
					break
			_free_page_spacer(first)
			continue
		break
	while _flow_container.get_child_count() > 0:
		var last = _flow_container.get_child(_flow_container.get_child_count() - 1)
		if last.has_meta("page_spacer") or last.has_meta("stagger_spacer"):
			_free_page_spacer(last)
		else:
			break

func _clear_page_spacers() -> void:
	if not _flow_container:
		return
	for child in _flow_container.get_children():
		if child.has_meta("page_spacer") or child.has_meta("stagger_spacer"):
			_flow_container.remove_child(child)
			child.queue_free()

# --- Stagger spacers --------------------------------------------------------
# Half-cell spacers at the start of odd rows force the FlowContainer to wrap
# offset rows at N-1 cards and indent them half a stride. Invariant: "a
# stagger spacer immediately precedes the first card of every odd row present
# in the flow; none elsewhere."

func _make_stagger_spacer() -> Control:
	var spacer := Control.new()
	spacer.set_meta("stagger_spacer", true)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.focus_mode = Control.FOCUS_NONE
	spacer.custom_minimum_size = _get_stagger_spacer_size()
	return spacer

## Half a cell minus the separation the flow inserts after the spacer, so the
## odd row's first card lands exactly half a stride to the right.
func _get_stagger_spacer_size() -> Vector2:
	var w = maxf(1.0, (card_size.x - grid_separation) / 2.0)
	return Vector2(w, card_size.y)

func _add_stagger_spacer(flow_index: int = -1) -> void:
	if not _flow_container:
		return
	var spacer = _make_stagger_spacer()
	_flow_container.add_child(spacer)
	if flow_index >= 0:
		_flow_container.move_child(spacer, flow_index)

## True when idx is the first item of an odd (offset) row.
func _is_stagger_row_opener(idx: int) -> bool:
	if not _is_staggered_active() or idx < 0:
		return false
	var line := _get_stagger_line_for_index(idx)
	return line % 2 == 1 and idx == _get_stagger_first_index_for_line(line)

## Rebuilds spacer placement from scratch after a layout recalc. Zoom, resize,
## and orientation changes move every page boundary at once, so incremental
## spacer maintenance cannot keep up; this clears all spacers and re-inserts
## them wherever consecutive cards cross a boundary under the CURRENT page
## composition. Cheap (a handful of plain Controls) and idempotent.
func _reconcile_page_spacers() -> void:
	if not _flow_container:
		return
	_clear_page_spacers()
	var paginate := _is_pagination_active() and _active_cards.size() >= 2
	var stagger := _is_staggered_active() and not _active_cards.is_empty()
	if not paginate and not stagger:
		return
	# Flow children are now exactly _active_cards in order; walk the run and
	# insert spacers at page boundaries and odd-row openers (stagger). When a
	# card opens both (tiny pages), the page spacer comes FIRST: it owns a
	# whole line, and the stagger spacer must stay attached to its row's cards.
	var flow_pos := 0
	for i in range(_active_cards.size()):
		var idx: int = _active_cards[i].get_meta("virtual_index", -1)
		if i > 0 and paginate:
			var prev_idx: int = _active_cards[i - 1].get_meta("virtual_index", -1)
			if prev_idx >= 0 and idx >= 0 and _get_page_for_index(idx) != _get_page_for_index(prev_idx):
				_add_page_spacer(flow_pos)
				flow_pos += 1
		if idx >= 0 and stagger and _is_stagger_row_opener(idx):
			_add_stagger_spacer(flow_pos)
			flow_pos += 1
		flow_pos += 1

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

	# GRID: snap to the nearest items-per-line stop.
	var base_dims = _get_base_dimensions_for_mode()
	var available = _get_available_size()
	var viewport_area = available.x * available.y
	return _compute_ratio_for_items_per_line(_get_nearest_level_for_ratio(desired_ratio), base_dims, available, viewport_area)

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
	# (GRID mode with a derived N skips this: N is a count and survives base-dimension
	# changes; it is clamped to the new stop range in the layout pass below.)
	if UIManager and UIManager.card_settings_state:
		var layout_state = UIManager.card_settings_state
		if layout_state.display_mode != _last_layout_display_mode or layout_state.media_aspect_ratio != _last_layout_media_aspect_ratio:
			if view_mode != ViewMode.GRID or _grid_items_per_line <= 0:
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

	# Resolve the scroll anchor for this recalc. Prefer the snapshot taken by
	# _set_grid_n_silent BEFORE items-per-line changed (zoom path); otherwise
	# capture inline, which is correct because N is unchanged in that case.
	var anchor: Vector2 = _scroll_anchor
	_scroll_anchor = Vector2(-1.0, 0.0)
	if anchor.x < 0.0:
		anchor = _capture_scroll_anchor(saved_focus_index)
	var anchor_index: int = int(anchor.x)
	var anchor_frac: float = anchor.y

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
			var n = _get_effective_grid_n()
			if n > 0:
				# Clamp N to the stop range for the current viewport (window may
				# have shrunk, or base dimensions changed with display mode).
				var levels = get_snap_levels()
				if not levels.is_empty() and n > levels[-1]:
					n = levels[-1]
					_grid_items_per_line = n
				# Exact fill: N whole cards per line, sized directly from the
				# cross-axis space. No ratio/zoom round-trips.
				var grid_available = _get_available_size()
				var cross_axis = grid_available.x if vertical else grid_available.y
				var base_cross = base_dims.x if vertical else base_dims.y
				var other_base = base_dims.y if vertical else base_dims.x
				var card_cross = maxf((cross_axis - (n - 1) * grid_separation) / n, base_cross * 0.1)
				if vertical:
					card_size = Vector2(card_cross, card_cross * other_base / base_cross)
				else:
					card_size = Vector2(card_cross * other_base / base_cross, card_cross)
				# Keep the derived ratio in sync for persistence/UI.
				var vp_area = grid_available.x * grid_available.y
				if vp_area > 0.0:
					var derived_ratio = sqrt((card_size.x * card_size.y) / vp_area)
					if not is_equal_approx(derived_ratio, target_card_width_ratio):
						_batching_layout = true
						target_card_width_ratio = derived_ratio
						_batching_layout = false
			else:
				card_size = base_dims * current_zoom
			focused_card_size = card_size * focus_scale
		ViewMode.LIST:
			# LIST (inverted focus): the cell is the FOCUSED size, so focused width
			# fills the viewport exactly; unfocused cards shrink by 1/focus_scale
			# centered in their cells. Nothing exceeds the cell, so no overflow.
			var card_width = _get_available_size().x
			card_size = Vector2(card_width, base_dims.y * current_zoom)
			focused_card_size = card_size
		ViewMode.CAROUSEL:
			# CAROUSEL (inverted focus): the cell is the FOCUSED size, so focused
			# height fills the viewport exactly; unfocused cards shrink by
			# 1/focus_scale centered in their cells. No overflow is reserved.
			var card_height = _get_available_size().y
			card_size = Vector2(base_dims.x * current_zoom, card_height)
			focused_card_size = card_size

	var available = _get_available_size()

	# Invalidate scroll-math caches BEFORE the re-pad: card_size changed above,
	# and _pad_total_items/get_lines_per_page must compute against the fresh
	# stride rather than the stale cached one from the previous composition.
	_cached_items_per_line = -1
	_cached_normal_stride = -1.0

	# Re-pad the geometry item count for the current N/page composition
	# (placeholder slots fill the last page/row evenly).
	var old_total_items = _total_items
	_total_items = _pad_total_items(_source_total_items)
	if debug_mode and old_total_items != _total_items:
		print("[Grid] re-pad: source=", _source_total_items, " total ", old_total_items, " -> ", _total_items)

	# Determine which parts of the layout actually changed
	var structure_changed = view_mode != _last_layout_view_mode or grid_vertical != _last_layout_grid_vertical
	var focus_changed = not is_equal_approx(focus_scale, _last_layout_focus_scale)
	var card_geometry_changed = not card_size.is_equal_approx(_last_layout_card_size) or not focused_card_size.is_equal_approx(_last_layout_focused_card_size)
	var separation_changed = grid_separation != _last_layout_grid_separation
	var available_changed = not available.is_equal_approx(_last_layout_available_size)
	var total_items_changed = _total_items != _last_layout_total_items
	var pagination_changed = pagination_enabled != _last_layout_pagination
	var staggered_changed = staggered != _last_layout_staggered

	# Display mode and media aspect ratio affect base card dimensions, which
	# feed into card_geometry_changed. Cache them explicitly so a recalc that
	# runs after these settings change cannot be skipped incorrectly.
	var state = UIManager.card_settings_state if UIManager else null
	var current_display_mode = state.display_mode if state else _cached_card_display_mode
	var current_media_ratio = state.media_aspect_ratio if state else 0
	var display_or_ratio_changed = current_display_mode != _last_layout_display_mode or current_media_ratio != _last_layout_media_aspect_ratio

	if debug_mode:
		print("[Grid] _recalculate_layout changes: structure=", structure_changed, " focus=", focus_changed, " card_geom=", card_geometry_changed, " separation=", separation_changed, " available=", available_changed, " display_or_ratio=", display_or_ratio_changed, " total_items=", total_items_changed, " pagination=", pagination_changed)

	if not _force_layout_once and not structure_changed and not focus_changed and not card_geometry_changed and not separation_changed and not available_changed and not display_or_ratio_changed and not total_items_changed and not pagination_changed and not staggered_changed:
		# Resets (_refresh_buffer, refresh_dimensions) can zero the flow
		# container's min size outside a recalc, and the CenterContainer sizes
		# the flow to its minimum — skipping here would leave the grid wrapped
		# to one column. Both calls are idempotent and write-cached.
		_update_layout()
		_update_margin()
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
	_last_layout_pagination = pagination_enabled
	_last_layout_staggered = staggered

	# Pre-compute scroll math before downstream consumers read it (caches were
	# invalidated earlier, before the re-pad)
	_cached_items_per_line = _get_items_per_line()
	_cached_normal_stride = _get_normal_stride()

	if debug_mode:
		print("[Grid] _recalculate_layout: available=", available, " card_size=", card_size, " item_width=", item_width, " item_height=", item_height, " items_per_line=", _cached_items_per_line, " normal_stride=", _cached_normal_stride)

	# items_per_line is by design 1 for LIST/CAROUSEL; only GRID can collapse.
	if debug_mode and _cached_items_per_line == 1 and view_mode == ViewMode.GRID:
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
	_force_layout_once = false
	_layout_generation += 1
	_layout_settled_with_valid_size = true

	# Restore the scroll position from the pre-recalc anchor so a zoom change
	# keeps the same content in view instead of re-interpreting the old pixel
	# offset against the new stride (which teleports the buffer window and
	# forces a full card rebuild). The clamp uses computed content-end math,
	# never the live scrollbar range (which is stale until end-of-frame sort).
	var restored_scroll: float = -1.0
	if anchor_index >= 0:
		var new_stride: float = _cached_normal_stride
		var new_ipl: int = _cached_items_per_line
		if new_stride > 0.0 and new_ipl > 0:
			var new_scroll: float
			if _is_pagination_active():
				# Pages rest snapped: restore directly to the anchor's page
				# target so the window build, the guarded write, and the
				# page-snap state all aim at the same position. Restoring a
				# free slot+frac position and snapping afterwards raced: with a
				# large page gap (zoomed out) the snap could land >1 stride
				# from the guarded anchor write, get echo-skipped, or be yanked
				# back by the guard's deferred corrective — the page then
				# rested off-center.
				new_scroll = _get_page_scroll_target(_get_page_for_index(anchor_index))
			else:
				new_scroll = _get_slot_position_for_index(anchor_index, new_ipl, new_stride) + anchor_frac * new_stride
			var overflow_axis: float = _get_focus_overflow().y if vertical else _get_focus_overflow().x
			var viewport_axis: float = available.y if vertical else available.x
			var max_scroll: float = maxf(0.0, _get_content_end_position() + 2.0 * overflow_axis - viewport_axis)
			new_scroll = clampf(new_scroll, 0.0, max_scroll)
			# Keep the focused card inside the viewport in the NEW geometry. The
			# anchor preserves its scroll-relative position, which can strand it
			# fully offscreen when the stride grows past the viewport (zoom-in).
			# Computed math only — never the live scrollbar range. In paginated
			# mode the focus card shares the anchor page by construction.
			if not _is_pagination_active() and saved_focus_index >= 0 and saved_focus_index < _source_total_items:
				var focus_slot := _get_slot_position_for_index(saved_focus_index, new_ipl, new_stride)
				var edge_margin := float(grid_separation)
				if focus_slot - edge_margin < new_scroll:
					new_scroll = focus_slot - edge_margin
				elif focus_slot + new_stride + edge_margin > new_scroll + viewport_axis:
					new_scroll = focus_slot + new_stride + edge_margin - viewport_axis
				new_scroll = clampf(new_scroll, 0.0, max_scroll)
			restored_scroll = new_scroll
			var zb_cur: float = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
			if debug_mode:
				print("[Grid] anchor restore: idx=", anchor_index, " frac=", anchor_frac, " ipl=", new_ipl, " stride=", new_stride, " scroll ", zb_cur, " -> ", new_scroll, " max=", max_scroll)

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
	# recycling from that deferred signal. force_recycle=true bypasses the
	# suppression for this synchronous call only.
	#
	# IMPORTANT: the window is built against the COMPUTED anchor position, not
	# the scrollbar value. The scrollbar range is stale mid-frame and clamps
	# writes beyond the old max (zoom-in at deep positions), which previously
	# rebuilt the window at the clamped offset and recycled the focused card.
	var recycle_pos: float = restored_scroll
	if recycle_pos < 0.0:
		recycle_pos = _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal
	_on_scroll_value_changed(recycle_pos, true, true)
	var _active_after: int = _active_cards.size()
	var _first_after: int = -1
	var _last_after: int = -1
	if _active_cards.size() > 0:
		_first_after = _active_cards[0].get_meta("virtual_index", -1)
		_last_after = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)
	if debug_mode:
		print("[Grid] recalc recycle: active ", _active_before, " -> ", _active_after, " (", _first_before, "-", _last_before, " -> ", _first_after, "-", _last_after, ")")

	# Sync the scrollbar to the restored position via the guarded writer (the
	# window above was built from the computed position, so even if the stale
	# scrollbar range clamps this write, the view and focus stay correct; the
	# deferred corrective write repairs the scrollbar itself).
	if restored_scroll >= 0.0:
		_set_scroll_position_guarded(restored_scroll)

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
	# Rebuild spacer placement for the new page composition, then push the snap
	# period/offset to the scroll container and re-align the scroll to a page
	# target so the view never rests mid-gap after zoom/resize/orientation changes.
	_reconcile_page_spacers()
	_update_page_snap_state()
	# Sync and reveal visual items after the deferred FlowContainer sort has run.
	# Relying only on NOTIFICATION_TRANSFORM_CHANGED misses some rebuild paths.
	call_deferred("_sync_and_mark_card_visual_transforms", "recalc")

	# Restore focus to the card that was focused before layout recalculation.
	# The anchor restore above already placed it in view, so this must NOT
	# scroll (re-centering would fight the anchor and, worse, its clamp reads
	# the stale scrollbar range mid-frame, which could strand the target
	# offscreen and lose focus entirely on zoom-in).
	if saved_focus_index >= 0 and saved_focus_index < _source_total_items:
		call_deferred("_restore_focus_only", saved_focus_index)

func _get_items_per_line() -> int:
	if not _scroll_container:
		return 1
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL:
		return 1
	# GRID zoom is N-driven: the items-per-line count is the source of truth.
	if _grid_items_per_line > 0:
		return _grid_items_per_line
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
	# Universal outer margin: inset the scroll container on all sides. The
	# effective viewport for layout math is inset in _get_available_size().
	grid_outer_margin = int(M3Units.dp(GRID_OUTER_MARGIN_DP))
	_scroll_container.offset_left = grid_outer_margin
	_scroll_container.offset_top = grid_outer_margin
	_scroll_container.offset_right = -grid_outer_margin
	_scroll_container.offset_bottom = -grid_outer_margin
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
	_scroll_container.scroll_target_provider = _on_follow_focus_target_request
	_scroll_container.page_step_provider = _on_page_step_request

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
	_flow_container.sort_children.connect(_on_flow_sorted)
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

	# NOTE: do not zero _flow_container.custom_minimum_size here to "force" a
	# recalc — the CenterContainer sizes the flow to its minimum, and if the
	# recalc is skipped or the deferred sort runs first, a zeroed min size
	# collapses the grid to one column. The cache invalidation below is the
	# correct trigger; _update_layout/_update_margin own the min size.

	# Re-snap zoom to ensure it fits the new dimensions/margins
	var current_ratio = target_card_width_ratio
	var snapped_ratio = _calculate_snapped_ratio(current_ratio)
	# Force a full layout pass: the ratio setter no-ops when the snapped ratio
	# equals the current one, which would skip the recalc entirely.
	_last_layout_available_size = Vector2.ZERO
	_force_layout_once = true
	target_card_width_ratio = snapped_ratio
	_recalculate_layout()

	var current_zoom = _calculate_zoom()
	var zoom_changed = not is_equal_approx(current_zoom, _last_applied_zoom)
	if zoom_changed:
		_last_applied_zoom = current_zoom

	# _recalculate_layout() (triggered by the target_card_width_ratio setter above)
	# already loops through active cards and calls refresh_settings(), so the
	# manual refresh loop that used to live here was completely redundant.

func setup(card_scene_resource: PackedScene, total_items: int, initial_target_ratio: float = -1.0):
	_card_scene = card_scene_resource
	_source_total_items = total_items
	_total_items = _pad_total_items(total_items)

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

	# Instantiate only the first visible screen synchronously so startup paints
	# sooner; the rest of the pool is topped up a few per frame by
	# _process_pool_growth (off-screen buffer cards don't need to exist yet).
	# Hidden views have no valid size: skip both the seed and the pending
	# growth — they build their pool under the transition cover on first show
	# via _ensure_pool_capacity.
	var sync_count = POOL_STARTUP_SEED if _has_valid_available_size() else 0
	if _last_computed_visible_count > 0:
		sync_count = mini(_max_pool_size, _last_computed_visible_count)
	sync_count = mini(sync_count, _max_pool_size)
	for i in range(sync_count):
		var card = _card_scene.instantiate()
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		_card_pool.append(card)
	_pending_pool_growth = maxi(0, _max_pool_size - sync_count) if _has_valid_available_size() else 0

	# Cache card capability flags from the first instantiated card so we can
	# skip has_method() / string lookups in hot loops. Probed once per card
	# scene across ALL grids — previously every grid paid a full card
	# instantiate + queue_free just for these flags.
	var flags: Dictionary
	var scene_key := _card_scene.resource_path
	if _capability_probe_cache.has(scene_key):
		flags = _capability_probe_cache[scene_key]
	else:
		var probe = _card_scene.instantiate()
		probe.queue_free()
		flags = {
			"focus_scale_enabled": "focus_scale_enabled" in probe,
			"set_focus_scale": probe.has_method("set_focus_scale"),
			"set_game_with_priority": probe.has_method("set_game_with_priority"),
			"refresh_settings": probe.has_method("refresh_settings"),
			"reset": probe.has_method("reset"),
			"game_prop": "game" in probe,
			"update_media_panel_size": probe.has_method("_update_media_panel_size"),
			"update_display": probe.has_method("update_display"),
			"set_image_priority": probe.has_method("set_image_priority"),
			"set_content_alignment": probe.has_method("set_content_alignment"),
			"set_media_aspect_ratio": probe.has_method("set_media_aspect_ratio"),
			"refresh_effects": probe.has_method("refresh_effects"),
			"update_card_state_from_settings": probe.has_method("_update_card_state_from_settings"),
			"sync_visual_transform": probe.has_method("sync_visual_transform"),
			"sync_visual_offset": probe.has_method("sync_visual_transform_with_offset"),
			"mark_visuals_position_synced": probe.has_method("_mark_visuals_position_synced"),
			"unmark_visuals_position_synced": probe.has_method("_unmark_visuals_position_synced"),
			"show_loading_skeleton": probe.has_method("show_loading_skeleton"),
			"begin_bulk_layout": probe.has_method("begin_bulk_layout"),
			"end_bulk_layout": probe.has_method("end_bulk_layout"),
		}
		_capability_probe_cache[scene_key] = flags
	_card_has_focus_scale_enabled = flags["focus_scale_enabled"]
	_card_has_set_focus_scale = flags["set_focus_scale"]
	_card_has_set_game_with_priority = flags["set_game_with_priority"]
	_card_has_refresh_settings = flags["refresh_settings"]
	_card_has_reset = flags["reset"]
	_card_has_game_prop = flags["game_prop"]
	_card_has_update_media_panel_size = flags["update_media_panel_size"]
	_card_has_update_display = flags["update_display"]
	_card_has_set_image_priority = flags["set_image_priority"]
	_card_has_set_content_alignment = flags["set_content_alignment"]
	_card_has_set_media_aspect_ratio = flags["set_media_aspect_ratio"]
	_card_has_refresh_effects = flags["refresh_effects"]
	_card_has_update_card_state_from_settings = flags["update_card_state_from_settings"]
	_card_has_sync_visual_transform = flags["sync_visual_transform"]
	_card_has_sync_visual_offset = flags["sync_visual_offset"]
	_card_has_mark_visuals_position_synced = flags["mark_visuals_position_synced"]
	_card_has_unmark_visuals_position_synced = flags["unmark_visuals_position_synced"]
	_card_has_show_loading_skeleton = flags["show_loading_skeleton"]
	_card_has_begin_bulk_layout = flags["begin_bulk_layout"]
	_card_has_end_bulk_layout = flags["end_bulk_layout"]
	if debug_mode:
		print("[Grid] _instantiate_card_pool: pool_size=", _max_pool_size, " elapsed_us=", Time.get_ticks_usec() - start_us)

var _pending_pool_growth: int = 0
var _last_computed_visible_count: int = 0
const POOL_GROWTH_PER_FRAME: int = 4
## Cards built synchronously when no layout has computed a visible count yet
## (hidden views, pre-settle). The pool tops up via _process_pool_growth.
const POOL_STARTUP_SEED: int = 8

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
		if not WarmupBudget.try_spend(WarmupBudget.COST_CARD_INSTANTIATE_US):
			return
		var card = _card_scene.instantiate()
		card.visible = false
		card.set_meta("pooled", true)
		card.set_meta("virtual_index", -1)
		_card_pool.append(card)
		_pending_pool_growth -= 1

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
	_last_computed_visible_count = visible_count

	var buffer_count = visible_count + (visual_buffer_lines * 2 * items_per_line)

	if _source_total_items <= SMALL_LIBRARY_THRESHOLD:
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
			return Vector2(available.x, base_dims.y * current_zoom)
		ViewMode.CAROUSEL:
			return Vector2(base_dims.x * current_zoom, available.y)
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
	var padded = _pad_total_items(count)
	# Compare the SOURCE count as well: padding can mask a real add/remove
	# (N-1 pads back up to the same total), which would skip the rebuild and
	# leave a stale, index-shifted data cache.
	var count_changed = _source_total_items != count or _total_items != padded
	_source_total_items = count
	_total_items = padded
	_update_layout()

	# Clear cache if count changed (index-to-data mapping is now stale)
	# or if preserve_cache is explicitly false
	if count_changed or not preserve_cache:
		_refresh_buffer()

## Geometry item count: pads the source count with trailing placeholder slots
## so the last page (paginated) or last row/column (plain grid) fills evenly.
func _pad_total_items(count: int) -> int:
	if count <= 0 or view_mode != ViewMode.GRID:
		return count
	var items_per_line = _get_items_per_line()
	if items_per_line <= 1:
		return count
	var unit = items_per_line
	if _is_staggered_active():
		# Pad to whole two-row stagger units so the layout stays even.
		unit = 2 * items_per_line - 1
	if _is_pagination_active():
		unit = items_per_line * get_lines_per_page()
		if _is_staggered_active():
			# Pages start on even rows (lpp is even), so a page holds lpp/2 pairs.
			unit = (2 * items_per_line - 1) * maxi(1, get_lines_per_page() / 2)
	var padded = int(ceil(float(count) / unit) * unit)
	if debug_mode and padded != count:
		print("[Grid] _pad_total_items: source=", count, " ipl=", items_per_line, " lpp=", get_lines_per_page(), " unit=", unit, " padded=", padded)
	return padded

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
	var line = _get_line_for_scroll_pos(scroll_pos) if _is_pagination_active() else (int(scroll_pos / stride) if stride > 0 else 0)
	var visible_lines = ceili(viewport_size / stride) if stride > 0 else 1
	_visible_start_idx = _get_first_index_for_line(line, items_per_line)
	_visible_end_idx = min(_get_first_index_for_line(line + visible_lines, items_per_line), _total_items)

	var visible_count = _visible_end_idx - _visible_start_idx
	# When paginated, a page jump moves the visible window by a whole page;
	# keep the buffer at least one page deep in each direction.
	var buffer_lines = maxi(_current_buffer_lines, get_lines_per_page()) if _is_pagination_active() else _current_buffer_lines
	var total_card_count = visible_count + (buffer_lines * 2 * items_per_line)
	# For small libraries, just load everything to avoid edge-case recycling bugs
	# that can clip the last partial row in grid mode. (Compares the source
	# count so placeholder padding never flips a small library into recycling.)
	if _source_total_items <= SMALL_LIBRARY_THRESHOLD:
		total_card_count = _total_items
	var half_buffer = int((total_card_count - visible_count) / 2.0)
	_buffer_target_start = max(0, _visible_start_idx - half_buffer)
	_buffer_target_end = min(_total_items, _buffer_target_start + total_card_count)

	if _buffer_target_end == _total_items:
		_buffer_target_start = max(0, _total_items - total_card_count)

	# Align target_start to a row/column start so the first buffered card always
	# opens a row. Without this, FlowContainer misaligns cards when the buffer
	# starts mid-row after incremental recycling or zoom changes.
	_buffer_target_start = _get_first_index_for_line(_get_line_for_index(_buffer_target_start, items_per_line), items_per_line)

	# Recompute target_end after alignment so the buffer size stays consistent
	_buffer_target_end = min(_total_items, _buffer_target_start + total_card_count)

	# When we're near the end of the list, alignment can leave a partial row
	# outside the buffer (e.g. 98 items, buffer covers 56-97, missing index 97).
	# Extend target_end to always include the last partial row.
	if _buffer_target_end < _total_items and (_total_items - _buffer_target_end) < items_per_line:
		_buffer_target_end = _total_items

func _on_scroll_value_changed(value: float, allow_recycle: bool = true, force_recycle: bool = false):
	if _is_processing_scroll:
		_grid_trace_stuck_count += 1
		if trace_verbose and (_grid_trace_stuck_count <= 3 or _grid_trace_stuck_count % 100 == 0):
			print("[GridTrace] HANDLER BLOCKED (_is_processing_scroll stuck): value=", value, " count=", _grid_trace_stuck_count, " t=", Time.get_ticks_msec())
		return
	_grid_trace_stuck_count = 0
	# Ignore the clamp echo from a guarded recalc-time scroll write: the stale
	# scrollbar range can clamp the write, and acting on the clamped value
	# would rebuild the buffer window at the wrong offset. The deferred
	# corrective write restores the intended position.
	if _guarded_scroll_target >= 0.0 and not force_recycle:
		if absf(value - _guarded_scroll_target) > maxf(_get_normal_stride(), 1.0):
			if trace_verbose:
				print("[GridTrace] echo-skip: value=", value, " target=", _guarded_scroll_target, " t=", Time.get_ticks_msec())
			return
	_is_processing_scroll = true
	if trace_verbose:
		print("[GridTrace] pass: value=", value, " recycle=", allow_recycle, " force=", force_recycle, " guarded_target=", _guarded_scroll_target, " suppress_until=", _suppress_recycle_until_frame, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

	if _total_items == 0 or not _scroll_container:
		_is_processing_scroll = false
		return

	# Suppress recycling during the frame(s) after a layout recalculation.
	# ScrollContainer may clamp its scroll value at end-of-frame and emit a
	# signal that would otherwise recycle cards with allow_recycle=true.
	# force_recycle bypasses this for the explicit synchronous recycle call
	# inside _recalculate_layout() itself; without the bypass, zooming in
	# never trims the active set and cards accumulate across zoom ticks.
	if not force_recycle and Engine.get_process_frames() <= _suppress_recycle_until_frame:
		allow_recycle = false

	var scroll_pos = int(value)
	var items_per_line = _get_items_per_line()
	var stride = _get_normal_stride()

	var now_ms := Time.get_ticks_msec()
	if _last_pass_time_ms > 0:
		var dt: float = float(now_ms - _last_pass_time_ms) / 1000.0
		if dt > 0.0005:
			_scroll_velocity = lerpf(_scroll_velocity, (value - _last_pass_scroll) / dt, 0.3)
	_last_pass_scroll = value
	_last_pass_time_ms = now_ms

	var available := _get_available_size()
	var viewport_size = available.y if vertical else available.x
	_compute_visible_and_buffer_ranges(scroll_pos, items_per_line, stride, viewport_size)

	if not force_recycle and _active_cards.size() > 0 and _buffer_target_start == _last_pass_buffer_start and _buffer_target_end == _last_pass_buffer_end:
		# Light path: the buffer window didn't move, so no recycle/add, margin,
		# or data-request work is needed — just keep visuals and focus current.
		_prefetch_scroll_lead(stride, items_per_line)
		_flush_pending_effect_rebuilds_for_visible_zone()
		_flush_pending_visual_setup_for_visible_zone()
		_sync_and_mark_card_visual_transforms("pass-end", false)
		call_deferred("_sync_and_mark_card_visual_transforms", "deferred")
		visible_range_changed.emit(_visible_start_idx, _visible_end_idx, _total_items)
		_try_apply_pending_focus()
		if trace_verbose:
			print("[GridTrace] pass-end (light): scroll=", scroll_pos, " active=", _active_cards.size(), " buffer=", _buffer_target_start, "-", _buffer_target_end, " t=", Time.get_ticks_msec())
		_is_processing_scroll = false
		return

	var structure_changed := _stage_recycle_and_fill(allow_recycle)
	_last_pass_buffer_start = _buffer_target_start
	_last_pass_buffer_end = _buffer_target_end

	if _active_cards.size() > 0:
		_virtual_start = _active_cards[0].get_meta("virtual_index", 0)
		_virtual_end = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)

	_request_missing_data()
	_prefetch_scroll_lead(stride, items_per_line)

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
	_sync_and_mark_card_visual_transforms("pass-end", false)
	# Re-stamp visual transforms after the end-of-frame sort on EVERY pass, not
	# just structural ones: steady-state healing otherwise relies solely on
	# NOTIFICATION_TRANSFORM_CHANGED being armed and firing for every card.
	call_deferred("_sync_and_mark_card_visual_transforms", "deferred")
	if structure_changed:
		call_deferred("_audit_visual_holes")
	call_deferred("_audit_render_state", "post-pass")
	_update_visual_draw_order()
	_audit_structure("pass-end")

	visible_range_changed.emit(_visible_start_idx, _visible_end_idx, _total_items)

	# If a programmatic focus is waiting for this scroll rebuild, try to land it now.
	_try_apply_pending_focus()

	if debug_mode:
		_update_debug_visuals(_visible_start_idx, _visible_end_idx)

	if trace_verbose:
		var gt_first: int = _active_cards[0].get_meta("virtual_index", -1) if _active_cards.size() > 0 else -1
		var gt_last: int = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1) if _active_cards.size() > 0 else -1
		var gt_expected_pos := -float(_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal)
		var gt_actual_pos: float = _margin_container.position.y if vertical else _margin_container.position.x
		print("[GridTrace] pass-end: scroll=", scroll_pos, " active=", _active_cards.size(), " window=", gt_first, "-", gt_last, " buffer=", _buffer_target_start, "-", _buffer_target_end, " pending_setup=", _pending_visual_setup.size(), " margin_pos=", gt_actual_pos, " expected_pos=", gt_expected_pos, " margin_delta=", gt_actual_pos - gt_expected_pos, " t=", Time.get_ticks_msec())

	_is_processing_scroll = false

func _stage_recycle_and_fill(allow_recycle: bool) -> bool:
	"""Recycle cards outside the buffer window and add missing ones. Returns
	true when the active set changed. Isolated so a failure here can't skip
	margins, data requests, or visual sync downstream of the scroll pass."""
	var structure_changed := false
	# Teleport guard: if the new buffer window doesn't overlap the active
	# window at all, this is a jump (random-game button, focus restore), not a
	# small correction. The recycle suppression in the caller exists for tiny
	# end-of-frame clamp wiggles after a recalc — the windows still overlap in
	# that case. Applying it to a teleport would bridge the entire gap with
	# adds (thousands of cards), so force recycling and rebuild from scratch.
	if _active_cards.size() > 0:
		var active_first: int = _active_cards[0].get_meta("virtual_index", -1)
		var active_last: int = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)
		if active_last < _buffer_target_start or active_first >= _buffer_target_end:
			allow_recycle = true

	if allow_recycle:
		var recycle_top_count = 0
		for card in _active_cards:
			if not is_instance_valid(card):
				continue
			var idx = card.get_meta("virtual_index", -1)
			if idx < _buffer_target_start:
				recycle_top_count += 1
			else:
				break
		if recycle_top_count > 0:
			_batch_recycle_from_start(recycle_top_count)
			structure_changed = true

		while _active_cards.size() > 0:
			var last_card = _active_cards[_active_cards.size() - 1]
			if not is_instance_valid(last_card):
				_active_cards.remove_at(_active_cards.size() - 1)
				continue
			var last_idx = last_card.get_meta("virtual_index", -1)

			if last_idx >= _buffer_target_end:
				_recycle_card_at_index(_active_cards.size() - 1)
				structure_changed = true
			else:
				break

	# If buffer was fully recycled (e.g. scrolled to a completely different range),
	# populate the target range from scratch
	if _active_cards.size() == 0:
		# Full jump (e.g. random-game teleport): in-flight requests for the old
		# window are useless now. Prune them so stale DB results are ignored and
		# queued DB tasks can skip themselves via is_load_pending().
		_prune_pending_loads_outside(_buffer_target_start, _buffer_target_end)
		_pending_buffer_expansion = false
		structure_changed = true
		for i in range(_buffer_target_start, _buffer_target_end):
			_add_card_at_end(i)
	elif _active_cards.size() > 0:
		var back_card = _active_cards[_active_cards.size() - 1]
		if not is_instance_valid(back_card):
			_active_cards.remove_at(_active_cards.size() - 1)
		else:
			var current_last = back_card.get_meta("virtual_index", 0)
			while current_last < _buffer_target_end - 1 and current_last < _total_items - 1:
				_add_card_at_end(current_last + 1)
				structure_changed = true
				back_card = _active_cards[_active_cards.size() - 1]
				if not is_instance_valid(back_card):
					break
				current_last = back_card.get_meta("virtual_index", 0)

		if _active_cards.size() > 0 and is_instance_valid(_active_cards[0]):
			var current_first = _active_cards[0].get_meta("virtual_index", 0)
			if current_first > _buffer_target_start and current_first > 0:
				var add_start_count = mini(current_first - _buffer_target_start, current_first)
				_batch_add_at_start(_buffer_target_start, add_start_count)
				structure_changed = true

	return structure_changed

func _reset_transient_scroll_state(reason: String) -> void:
	"""Single reset point for transient scroll/jump state. Called from every
	entry point that moves the view programmatically so a stale guard, velocity
	or pending expansion from a previous operation can never fight the new one."""
	_guarded_scroll_target = -1.0
	_guarded_scroll_attempts = 0
	_scroll_velocity = 0.0
	_pending_buffer_expansion = false
	if trace_verbose:
		print("[GridTrace] reset-transient: reason=", reason, " t=", Time.get_ticks_msec())

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
		_prune_edge_spacers()

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

func _on_frame_pre_draw() -> void:
	# Stamp visual offsets at the last moment before render, from pure
	# container arithmetic. At pre-draw time the scroll value, margin cache and
	# window membership are all final for the frame, so the stamps are
	# render-fresh by construction — independent of sort/flush/deferred order.
	if not _card_has_sync_visual_offset or not _scroll_container or not _visual_layer:
		return
	if _active_cards.size() == 0:
		return
	# Skip the stamp loop entirely when nothing that feeds the offset math
	# changed since the last stamp (idle frames far outnumber scroll frames).
	var scroll_now: float = float(_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal)
	var margin_now: int = _last_margin_top if vertical else _last_margin_left
	var first_now: int = _active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_active_cards[0]) else -1
	if scroll_now == _last_stamp_scroll and margin_now == _last_stamp_margin and first_now == _last_stamp_first and _active_cards.size() == _last_stamp_count and _layout_generation == _last_stamp_generation:
		return
	_last_stamp_scroll = scroll_now
	_last_stamp_margin = margin_now
	_last_stamp_first = first_now
	_last_stamp_count = _active_cards.size()
	_last_stamp_generation = _layout_generation
	for card in _active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		card.sync_visual_transform_with_offset(_compute_visual_layer_offset(card))

func _on_frame_post_draw_audit() -> void:
	# Render-time truth check: after the frame was drawn, the stamped origins
	# must equal the arithmetic offsets computed from the final frame state.
	if not debug_mode:
		return
	if not _card_has_sync_visual_offset or not _scroll_container or not _visual_layer:
		return
	if _active_cards.size() == 0:
		return
	var worst := 0.0
	var worst_idx := -1
	var worst_stamp := Vector2.ZERO
	var worst_exp := Vector2.ZERO
	for card in _active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		var lt_v = card.get("_last_visual_transform")
		if not lt_v is Transform2D:
			continue
		var stamp: Vector2 = lt_v.origin
		var exp: Vector2 = _compute_visual_layer_offset(card)
		var cs_v = card.get("content_scale")
		var cs: Vector2 = cs_v if cs_v is Vector2 else Vector2.ONE
		if not cs.is_equal_approx(Vector2.ONE):
			var pivot: Vector2 = card._get_content_scale_pivot() if card.has_method("_get_content_scale_pivot") else card.size * 0.5
			exp += pivot - cs * pivot
		var d := stamp.distance_to(exp)
		if d > worst:
			worst = d
			worst_idx = card.get_meta("virtual_index", -1)
			worst_stamp = stamp
			worst_exp = exp
	if worst > 2.0:
		# De-spam: report a card only when its delta changes materially; a static
		# layout-vs-model constant is printed once, oscillation prints per change.
		var delta_key := int(round(worst * 2.0))
		var last_delta: int = _drawaudit_last_deltas.get(worst_idx, -1000)
		if delta_key != last_delta:
			_drawaudit_last_deltas[worst_idx] = delta_key
			print("[DrawAudit] MISMATCH: worst=", worst, " idx=", worst_idx, " stamp=", worst_stamp, " exp=", worst_exp, " scroll=", _scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal, " margin=", _last_margin_top if vertical else _last_margin_left, " first=", _active_cards[0].get_meta("virtual_index", -1) if is_instance_valid(_active_cards[0]) else -1, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

var _drawaudit_last_deltas: Dictionary = {}

func _compute_visual_layer_offset(card: Control) -> Vector2:
	"""Layer-space offset for a card computed from container math: the scroll
	container's origin (stable during scroll) minus the live scroll value, plus
	the margin overrides, plus the card's position. The scroll axis uses slot
	math anchored to the first active card instead of card.position: flow-local
	positions only update at the end-of-frame sort, so during a recycle the
	margin cache (already new) and card.position (still old) disagree by one
	row and the stamp flashes a row off for a frame. Slot deltas are the
	post-sort truth at every instant."""
	var sc_origin := _scroll_container.get_global_rect().position
	var scroll_vec := Vector2(float(_scroll_container.scroll_horizontal), float(_scroll_container.scroll_vertical))
	var margin_vec := Vector2(float(_last_margin_left), float(_last_margin_top))
	var offset := sc_origin - scroll_vec + margin_vec + card.position - _visual_layer.global_position
	var vidx: int = card.get_meta("virtual_index", -1)
	if vidx >= 0 and _active_cards.size() > 0 and is_instance_valid(_active_cards[0]):
		var first_idx: int = _active_cards[0].get_meta("virtual_index", -1)
		if first_idx >= 0:
			var slot_delta := _get_slot_position_for_index(vidx) - _get_slot_position_for_index(first_idx)
			if vertical:
				offset.y = sc_origin.y - scroll_vec.y + margin_vec.y + slot_delta - _visual_layer.global_position.y
			else:
				offset.x = sc_origin.x - scroll_vec.x + margin_vec.x + slot_delta - _visual_layer.global_position.x
	return offset

func _sync_and_mark_card_visual_transforms(tag: String = "", mark: bool = true) -> void:
	var use_offsets: bool = _card_has_sync_visual_offset and _scroll_container and _visual_layer
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		# Don't mark cards before _ready() has run; _setup_rs_items() resets the
		# synced flag, so marking earlier would be silently undone.
		if not card.is_node_ready():
			continue
		if use_offsets:
			card.sync_visual_transform_with_offset(_compute_visual_layer_offset(card))
		elif _card_has_sync_visual_transform:
			card.sync_visual_transform()
		# When mark=false (pre-sort passes), newly added cards keep their RS
		# items hidden until the deferred post-sort mark, so a stale pooled
		# position can never reach the screen even if the heal slips a frame.
		if mark and _card_has_mark_visuals_position_synced:
			card._mark_visuals_position_synced()

func _on_flow_sorted() -> void:
	_layout_generation += 1

func _audit_structure(tag: String) -> void:
	if not debug_mode:
		return
	var prev_idx := -2
	var dup := -1
	var nonmono := -1
	var seen := {}
	for c in _active_cards:
		if not is_instance_valid(c):
			continue
		var m: int = c.get_meta("virtual_index", -1)
		if seen.has(m):
			dup = m
			break
		seen[m] = true
		if m <= prev_idx:
			nonmono = m
			break
		prev_idx = m
	var flow_cards := 0
	var spacers := 0
	for ch in _flow_container.get_children():
		if ch.has_meta("page_spacer") or ch.has_meta("stagger_spacer"):
			spacers += 1
		else:
			flow_cards += 1
	if dup >= 0 or nonmono >= 0 or flow_cards != _active_cards.size():
		var first: int = _active_cards[0].get_meta("virtual_index", -1) if _active_cards.size() > 0 else -1
		print("[GridInv] VIOLATION tag=", tag, " dup=", dup, " nonmono=", nonmono, " active=", _active_cards.size(), " flow_cards=", flow_cards, " spacers=", spacers, " first=", first, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

func _audit_visual_holes() -> void:
	if not debug_mode:
		return
	var unsynced: Array = []
	var invisible: Array = []
	for card in _active_cards:
		if not is_instance_valid(card):
			continue
		var vidx: int = card.get_meta("virtual_index", -1)
		if not card.visible:
			invisible.append(vidx)
		if _card_has_mark_visuals_position_synced and card.get("_visuals_position_synced") == false:
			unsynced.append(vidx)
	if unsynced.size() > 0 or invisible.size() > 0:
		print("[VisHole] unsynced=", unsynced, " invisible=", invisible, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

func soak_test(iterations: int = 20) -> void:
	"""Debug stress test: random teleports + scroll bursts with all violation
	audits active. Any [GridInv]/[VisHole]/[RsAudit]/[DrawAudit] output during
	the run indicates a broken invariant. Call from the debugger or a hotkey."""
	print("[SoakTest] starting: iterations=", iterations, " items=", _source_total_items, " mode=", view_mode)
	for i in iterations:
		if _source_total_items <= 0 or not _scroll_container:
			break
		scroll_to_index_and_focus(randi() % _source_total_items, false)
		await get_tree().process_frame
		await get_tree().process_frame
		for j in 4:
			var dir := 1.0 if j % 2 == 0 else -1.0
			_scroll_container.scroll_to(_get_current_scroll_pos() + dir * _get_normal_stride() * 2.5, false)
			await get_tree().process_frame
		_audit_structure("soak")
	print("[SoakTest] complete: iterations=", iterations, " mode=", view_mode)

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

func _audit_render_state(tag: String) -> void:
	"""Compare what is actually rendered (RS canvas item transforms, visual
	layer state, scroll content offset) against the layout truth. Runs deferred
	(post-sort, post-sync) so any divergence here is a genuine render bug."""
	if not debug_mode:
		return
	if not _visual_layer or not _scroll_container:
		return
	var layer_pos := _visual_layer.global_position
	if _visual_layer.position != Vector2.ZERO or not _visual_layer.top_level or not _visual_layer.visible:
		print("[LayerAudit] tag=", tag, " pos=", _visual_layer.position, " global=", layer_pos, " top_level=", _visual_layer.top_level, " visible=", _visual_layer.visible, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())
	var mc_pos: float = _margin_container.position.y if vertical else _margin_container.position.x
	var scroll_now: float = float(_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal)
	var mc_delta: float = absf(mc_pos + scroll_now)
	var worst := 0.0
	var worst_idx := -1
	var worst_rs := Vector2.ZERO
	var worst_exp := Vector2.ZERO
	var worst_cs := Vector2.ONE
	for card in _active_cards:
		if not is_instance_valid(card) or not card.is_node_ready():
			continue
		var lt_v = card.get("_last_visual_transform")
		if not lt_v is Transform2D:
			continue
		var rs_origin: Vector2 = lt_v.origin
		var exp_origin: Vector2 = _compute_visual_layer_offset(card)
		var cs_v = card.get("content_scale")
		var cs: Vector2 = cs_v if cs_v is Vector2 else Vector2.ONE
		if not cs.is_equal_approx(Vector2.ONE):
			var pivot: Vector2 = card._get_content_scale_pivot() if card.has_method("_get_content_scale_pivot") else card.size * 0.5
			exp_origin += pivot - cs * pivot
		var d: float = rs_origin.distance_to(exp_origin)
		if d > worst:
			worst = d
			worst_idx = card.get_meta("virtual_index", -1)
			worst_rs = rs_origin
			worst_exp = exp_origin
			worst_cs = cs
	if worst > 2.0 or mc_delta > 2.0:
		print("[RsAudit] tag=", tag, " worst=", worst, " idx=", worst_idx, " rs=", worst_rs, " exp=", worst_exp, " cs=", worst_cs, " margin_lag=", mc_delta, " scroll=", scroll_now, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())

func _show_skeleton_if_unloaded(card: Control, virtual_index: int) -> void:
	# Cards entering the flow before their data is cached would render blank
	# until setup lands; show the shimmer skeleton in the meantime.
	if not _card_has_show_loading_skeleton:
		return
	if virtual_index >= _source_total_items:
		return  # Placeholder slots render a blank panel, not shimmer.
	if _data_cache.has(virtual_index):
		return  # Data ready; setup applies it this pass.
	card.show_loading_skeleton()

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
	if _is_pagination_active() and _active_cards.size() > 0:
		# Page boundary between the last buffered card and this one: the spacer
		# owns a whole flow line, creating the visual gap between pages.
		var last_idx: int = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", -1)
		if last_idx >= 0 and _get_page_for_index(virtual_index) != _get_page_for_index(last_idx):
			_add_page_spacer()
	if _is_stagger_row_opener(virtual_index):
		# Odd-row opener: half-cell spacer indents the row and wraps it at N-1.
		_add_stagger_spacer()
	_active_cards.append(card)
	_active_cards_by_index[virtual_index] = card
	_flow_container.add_child(card)

	card.set_meta("needs_visual_setup", true)
	_pending_visual_setup[virtual_index] = card
	_show_skeleton_if_unloaded(card, virtual_index)

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
	if _is_pagination_active() and _active_cards.size() > 1:
		# Page boundary between the new first card and the previous first card.
		var next_idx: int = _active_cards[1].get_meta("virtual_index", -1)
		if next_idx >= 0 and _get_page_for_index(virtual_index) != _get_page_for_index(next_idx):
			_add_page_spacer(1)
	if _is_stagger_row_opener(virtual_index):
		# Odd-row opener prepended: its half-cell spacer goes before it. If the
		# row's partial run kept its spacer (edge-prune keeps live spacers),
		# move that one up instead of inserting a duplicate.
		if _flow_container.get_child_count() > 1 and _flow_container.get_child(1).has_meta("stagger_spacer"):
			_flow_container.move_child(_flow_container.get_child(1), 0)
		else:
			_add_stagger_spacer(0)
	_configure_card_size_flags(card)
	if _card_has_set_focus_scale:
		card.set_focus_scale(focus_scale)

	card.set_meta("needs_visual_setup", true)
	_pending_visual_setup[virtual_index] = card
	_show_skeleton_if_unloaded(card, virtual_index)

	item_created.emit(card, virtual_index)

func _apply_card_visual_setup(card: Control, virtual_index: int) -> bool:
	if not card.has_meta("needs_visual_setup"):
		if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " no meta, skipping")
		return true
	if not card.is_node_ready():
		if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " not ready, keeping pending")
		return false
	var actual_idx: int = card.get_meta("virtual_index", -1)
	if actual_idx != virtual_index:
		# Stale pending entry: the card was recycled and now shows a different
		# index. Never apply the wrong game's data; re-queue under the card's
		# current index so it still gets set up.
		print("[CardApply] MISMATCH: card_meta=", actual_idx, " arg=", virtual_index, " frame=", Engine.get_process_frames(), " t=", Time.get_ticks_msec())
		if actual_idx >= 0 and _active_cards_by_index.get(actual_idx) == card:
			_pending_visual_setup[actual_idx] = card
		else:
			card.remove_meta("needs_visual_setup")
		return true
	# Placeholder slots (index beyond the source count): no data to apply;
	# render as a blank, non-interactive card shape.
	if virtual_index >= _source_total_items:
		card.remove_meta("needs_visual_setup")
		if card.has_method("set_placeholder"):
			card.set_placeholder(true)
		return true
	if not _data_cache.has(virtual_index):
		# Data not loaded yet; keep the card pending so it gets finished once
		# the items_requested callback populates the cache.
		if debug_mode: print("[Grid] _apply_card_visual_setup: idx=", virtual_index, " data missing, keeping pending")
		_show_skeleton_if_unloaded(card, virtual_index)
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
	if _card_has_sync_visual_offset and _scroll_container and _visual_layer:
		card.sync_visual_transform_with_offset(_compute_visual_layer_offset(card))
	elif _card_has_sync_visual_transform:
		card.sync_visual_transform()
	# When called from inside a scroll pass the FlowContainer hasn't sorted yet,
	# so marking here would reveal the card at a stale position; the deferred
	# post-sort mark handles those. Outside a pass the layout is settled and
	# marking immediately is both safe and required (async data arrivals).
	if not _is_processing_scroll and _card_has_mark_visuals_position_synced:
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
			if _pending_effect_rebuild_set.has(card):
				_pending_effect_rebuilds.erase(card)
				_pending_effect_rebuild_set.erase(card)
			if _card_has_reset:
				card.reset(true)
			elif _card_has_game_prop:
				card.game = null
			card.remove_meta("needs_visual_setup")
			if card.get_parent() == _flow_container:
				_flow_container.remove_child(card)
			_add_to_pool(card)
	_active_cards = _active_cards.slice(count)
	_prune_edge_spacers()

func _batch_add_at_start(target_start: int, count: int) -> void:
	if count <= 0:
		return
	var new_cards: Array[Control] = []
	var flow_pos := 0
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
		if _is_pagination_active() and i > 0:
			# Page boundary within the prepended range.
			if _get_page_for_index(virtual_index) != _get_page_for_index(virtual_index - 1):
				_add_page_spacer(flow_pos)
				flow_pos += 1
		if _is_stagger_row_opener(virtual_index):
			_add_stagger_spacer(flow_pos)
			flow_pos += 1
		_flow_container.add_child(card)
		_flow_container.move_child(card, flow_pos)
		flow_pos += 1
		_configure_card_size_flags(card)
		if _card_has_set_focus_scale:
			card.set_focus_scale(focus_scale)
		card.set_meta("needs_visual_setup", true)
		_pending_visual_setup[virtual_index] = card
		_show_skeleton_if_unloaded(card, virtual_index)
		item_created.emit(card, virtual_index)
		_active_cards_by_index[virtual_index] = card
		new_cards.append(card)
	if _is_pagination_active() and new_cards.size() > 0 and _active_cards.size() > 0:
		# Page boundary between the last prepended card and the previous first card.
		var last_new_idx: int = new_cards[new_cards.size() - 1].get_meta("virtual_index", -1)
		var old_first_idx: int = _active_cards[0].get_meta("virtual_index", -1)
		if last_new_idx >= 0 and old_first_idx >= 0 and _get_page_for_index(last_new_idx) != _get_page_for_index(old_first_idx):
			_add_page_spacer(flow_pos)
	_active_cards = new_cards + _active_cards

func _get_visible_range() -> void:
	var items_per_line = _get_items_per_line()
	var eff = _get_normal_stride()
	var available := _get_available_size()

	if vertical:
		var scroll_pos = _scroll_container.scroll_vertical if _scroll_container else 0
		var viewport_height = available.y
		var visible_rows = ceili(viewport_height / eff) if eff > 0 else 1
		var first_line = int(scroll_pos / eff) if eff > 0 else 0
		_visible_start_idx = _get_first_index_for_line(first_line, items_per_line)
		_visible_end_idx = min(_get_first_index_for_line(first_line + visible_rows, items_per_line), _total_items)
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
			if _card_has_unmark_visuals_position_synced:
				card._unmark_visuals_position_synced()
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
		# Never touch the cross-axis min size here: _update_layout owns it, and
		# zeroing it collapses the grid to one line when the flow sorts before
		# cards are re-added (every recycle-all refresh passes through this
		# branch with zero active cards). Only a genuinely empty grid gets its
		# stale scroll-axis extent cleared.
		if _total_items == 0:
			if vertical:
				if _last_flow_height != 0:
					_flow_container.custom_minimum_size.y = 0
					_last_flow_height = 0
			else:
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
		# When paginated this also excludes any trailing page gap.
		var total_end = _get_content_end_position()
		var margin_top = first_pos + focus_overflow.y
		var margin_bottom = total_end - after_last_pos + focus_overflow.y
		var flow_height = after_last_pos - first_pos

		if int(margin_top) != _last_margin_top or int(margin_bottom) != _last_margin_bottom:
			_margin_container.add_theme_constant_override("margin_top", int(margin_top))
			_margin_container.add_theme_constant_override("margin_bottom", int(margin_bottom))
			_last_margin_top = int(margin_top)
			_last_margin_bottom = int(margin_bottom)
			if trace_verbose:
				print("[GridTrace] margin: top=", _last_margin_top, " bottom=", _last_margin_bottom, " flow_h=", flow_height, " first=", first_idx, " last=", last_idx, " t=", Time.get_ticks_msec())

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
		# NOTE: custom_minimum_size.x is owned by _update_layout() (row width for
		# centering). This pass must NOT zero it — the CenterContainer sizes the
		# flow to its minimum, so zeroing here wraps the grid to one column.
		_last_flow_width = 0
	else:
		var first_pos = _get_slot_position_for_index(first_idx, items_per_line, stride)
		var after_last_pos = _get_slot_position_for_index(last_idx + 1, items_per_line, stride)
		# END of the last (possibly partial) column; excludes any trailing page gap.
		var total_end = _get_content_end_position()
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
		# NOTE: custom_minimum_size.y is owned by _update_layout() for GRID
		# horizontal (column height for centering); see the vertical branch.
		_last_flow_height = 0

func _is_index_pending(idx: int) -> bool:
	_pending_loads_mutex.lock()
	for offset in _pending_loads.keys():
		var limit = _pending_loads[offset]
		if idx >= offset and idx < offset + limit:
			_pending_loads_mutex.unlock()
			return true
	_pending_loads_mutex.unlock()
	return false

## Thread-safe check used by DB worker tasks to skip queries whose results
## would be discarded anyway (superseded by a jump or buffer refresh).
func is_load_pending(offset: int) -> bool:
	_pending_loads_mutex.lock()
	var pending := _pending_loads.has(offset)
	_pending_loads_mutex.unlock()
	return pending

func _prune_pending_loads_outside(range_start: int, range_end: int) -> void:
	_pending_loads_mutex.lock()
	var gt_pruned: int = 0
	for offset in _pending_loads.keys():
		var limit: int = _pending_loads[offset]
		# Keep requests that still overlap the new buffer window.
		if offset + limit <= range_start or offset >= range_end:
			_pending_loads.erase(offset)
			gt_pruned += 1
	var gt_remaining: int = _pending_loads.size()
	_pending_loads_mutex.unlock()
	if trace_verbose:
		print("[GridTrace] prune-loads: pruned=", gt_pruned, " remaining=", gt_remaining, " window=", range_start, "-", range_end, " t=", Time.get_ticks_msec())

func _request_missing_data():
	if _active_cards.size() == 0:
		return

	var missing_indices: Array[int] = []
	for card in _active_cards:
		var idx = card.get_meta("virtual_index", -1)
		# Placeholder slots (idx >= source count) need no data.
		if idx >= 0 and idx < _source_total_items and not _data_cache.has(idx) and not _is_index_pending(idx):
			missing_indices.append(idx)

	if missing_indices.size() == 0:
		return
	if trace_verbose:
		print("[GridTrace] missing-data: count=", missing_indices.size(), " first=", missing_indices[0], " t=", Time.get_ticks_msec())

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

func _prefetch_scroll_lead(stride: float, items_per_line: int) -> void:
	"""Prefetch data beyond the buffer edge in the current scroll direction so
	incoming rows already have data when they enter the viewport (~150ms lead).
	Without this, every window shift leaves the entering rows blank for the
	~100ms DB round-trip, visible as flickering/disappearing rows."""
	if stride <= 0.0 or _total_items <= 0 or absf(_scroll_velocity) < stride * 2.0:
		return
	var lead_px: float = clampf(absf(_scroll_velocity) * 0.15, stride * 2.0, stride * 8.0)
	var lead_items: int = int(ceil(lead_px / stride)) * items_per_line
	var start: int
	var end: int
	if _scroll_velocity > 0.0:
		start = _buffer_target_end
		end = mini(_total_items, start + lead_items)
	else:
		end = _buffer_target_start
		start = maxi(0, end - lead_items)
	if end <= start:
		return
	var missing: Array[int] = []
	for idx in range(start, end):
		if idx < _source_total_items and not _data_cache.has(idx) and not _is_index_pending(idx):
			missing.append(idx)
	if missing.size() == 0:
		return
	if trace_verbose:
		print("[GridTrace] prefetch-lead: count=", missing.size(), " first=", missing[0], " vel=", _scroll_velocity, " t=", Time.get_ticks_msec())
	_request_data(missing[0], missing.size())

func _check_preload_needed():
	var visible_count = _get_visible_count()
	var preload_distance = visible_count * data_preload_multiplier
	var buffer_size = visible_count * data_buffer_multiplier

	if _virtual_end < _source_total_items - 1:
		var distance_to_end = _source_total_items - 1 - _virtual_end
		if distance_to_end > 0 and distance_to_end <= preload_distance:
			var next_batch_start = _virtual_end + 1
			if not is_load_pending(next_batch_start) and not _data_cache.has(next_batch_start):
				_request_data(next_batch_start, min(buffer_size, _source_total_items - next_batch_start))

	if _virtual_start > 0:
		var distance_to_start = _virtual_start
		if distance_to_start > 0 and distance_to_start <= preload_distance:
			var prev_batch_start = max(0, _virtual_start - buffer_size)
			if not is_load_pending(prev_batch_start) and not _data_cache.has(prev_batch_start):
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

	# Route visible and offscreen targets through the same scroll-and-focus path
	# so behavior is consistent; the centering mode decides whether a visible
	# target triggers any scroll at all.
	scroll_to_index_and_focus(target_idx, true)
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
	if _source_total_items <= 0 or current_idx < 0 or current_idx >= _source_total_items:
		return -1

	var items_per_line := _get_items_per_line()
	if items_per_line <= 0:
		items_per_line = 1

	# LIST/CAROUSEL: simple linear movement.
	if view_mode == ViewMode.LIST or view_mode == ViewMode.CAROUSEL or items_per_line == 1:
		var target := current_idx + row_delta + col_delta
		return clamp(target, 0, _source_total_items - 1)

	if _is_staggered_active():
		var line := _get_stagger_line_for_index(current_idx)
		var col := current_idx - _get_stagger_first_index_for_line(line)
		var total_lines := _get_stagger_line_for_index(_source_total_items - 1) + 1
		# Horizontal moves stay on the current row, bounded by its capacity.
		if row_delta == 0 and col_delta != 0:
			var target_col_h := col + col_delta
			if target_col_h < 0 or target_col_h >= _get_stagger_line_capacity(line):
				return -1
			var target_idx_h := _get_stagger_first_index_for_line(line) + target_col_h
			if target_idx_h >= _source_total_items:
				return -1
			return target_idx_h
		var target_line := line + row_delta
		if target_line < 0 or target_line >= total_lines:
			return -1
		# Vertical moves keep the column index, clamped to the target row's
		# capacity (offset rows hold one fewer card).
		var target_col := mini(col, _get_stagger_line_capacity(target_line) - 1)
		var target_idx := _get_stagger_first_index_for_line(target_line) + target_col
		# Placeholder slots (idx >= source count) are not navigation targets.
		if target_idx >= _source_total_items:
			return -1
		return target_idx

	var line := int(current_idx / float(items_per_line))
	var col := current_idx % items_per_line
	var total_lines := ceili(float(_source_total_items) / items_per_line)

	var target_line := line + row_delta
	var target_col := col + col_delta

	if target_line < 0 or target_line >= total_lines:
		return -1
	if target_col < 0 or target_col >= items_per_line:
		return -1

	var target_idx := target_line * items_per_line + target_col
	# Placeholder slots (idx >= source count) are not navigation targets.
	if target_idx >= _source_total_items:
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
		# gui_focus_changed ignores the null owner, so the lock taken when the
		# card was focused would persist with no focus owner (swallowing input)
		# if the deferred focus restore fails. Release it; the restore re-locks.
		if UIManager:
			UIManager.exit_focus_lock(self)

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

	# Cap batch size: legitimate requests cover one buffer window (a few dozen
	# items) or a preload span. Multi-thousand-item queries only ever come from
	# a pathological active-set state and can stall the DB worker for seconds.
	limit = mini(limit, MAX_DATA_REQUEST_ITEMS)
	limit = min(limit, _total_items - offset)
	if trace_verbose:
		print("[GridTrace] request-data: offset=", offset, " limit=", limit, " t=", Time.get_ticks_msec())
	_pending_loads_mutex.lock()
	_pending_loads[offset] = limit
	_pending_loads_mutex.unlock()

	items_requested.emit(offset, limit)

func on_items_loaded(items: Array[GameResource], offset: int, _is_preload: bool = false):
	if trace_verbose:
		print("[GridTrace] items-loaded: offset=", offset, " count=", items.size(), " t=", Time.get_ticks_msec())
	if debug_mode:
		print("[Grid] on_items_loaded: offset=", offset, " count=", items.size(), " pending=", _pending_visual_setup.size(), " cache_size_before=", _data_cache.size())
	_pending_loads_mutex.lock()
	var was_pending := _pending_loads.has(offset)
	_pending_loads.erase(offset)
	_pending_loads_mutex.unlock()

	# Stale result: the request was superseded by a jump or buffer refresh
	# while its DB task was in flight. Applying it would refill the cache with
	# windows nobody is looking at and re-trigger pointless cover loads.
	if not was_pending:
		return

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
		# Warm the texture cache as data lands (covers both window and prefetch
		# loads) so cover art is decoded before its row scrolls into view.
		CardMediaLoader.preload_cover(game)

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
	# Only a live in-grid focus may trigger a focus restore after the rebuild;
	# the _last_focused fallback below is memory only, and must not let a
	# background rebuild steal focus back from the nav rail or other views.
	var focus_was_in_grid: bool = saved_focus_index >= 0
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
	_clear_page_spacers()

	_data_cache.clear()
	_cached_game_ids.clear()
	_cache_lru_tick.clear()
	_pending_loads_mutex.lock()
	_pending_loads.clear()
	_pending_loads_mutex.unlock()
	_active_cards_by_index.clear()
	_pending_effect_rebuilds.clear()
	_pending_effect_rebuild_set.clear()
	_pending_effects_refresh_after_layout = false
	_margin_container.add_theme_constant_override("margin_top", 0)
	_margin_container.add_theme_constant_override("margin_bottom", 0)
	_margin_container.add_theme_constant_override("margin_left", 0)
	_margin_container.add_theme_constant_override("margin_right", 0)
	# Do NOT zero _flow_container.custom_minimum_size here: the CenterContainer
	# sizes the flow to its minimum, and if the restoring recalc below is
	# skipped (guards) or the flow sorts first, a zeroed min size collapses the
	# grid to one column. _update_layout/_update_margin own the min size; the
	# cache invalidations below already force the recalc that rewrites it.
	# Reset the write-caches to the sentinel so the next _update_margin() cannot
	# skip a write while the real overrides sit at zero (cache/actual desync).
	_last_margin_top = -1
	_last_margin_bottom = -1
	_last_margin_left = -1
	_last_margin_right = -1
	_last_flow_height = -1.0
	_last_flow_width = -1.0
	_last_margin_virtual_start = -1
	_last_margin_virtual_end = -1
	# Invalidate the layout input cache so the following _recalculate_layout()
	# cannot early-exit. This matters when a buffer refresh happens while total
	# count and geometry are unchanged (e.g. after sync completes).
	_last_layout_available_size = Vector2.ZERO
	_last_layout_total_items = -1
	_last_layout_card_size = Vector2.ZERO
	_last_layout_focused_card_size = Vector2.ZERO
	_virtual_start = 0
	_virtual_end = 0

	# Only zero the scroll when not preserving it. View-mode switches remember
	# the focused item (or raw offset) and restore it after the rebuild.
	if not preserve_scroll and _scroll_container:
		_reset_transient_scroll_state("refresh_buffer")
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
	# Never grab card focus while an overlay (e.g. the settings dialog) is
	# showing: the steal would fight the overlay's focus pull-back.
	if preserve_scroll:
		if saved_focus_index >= 0 and M3Overlay._get_topmost_overlay() == null:
			call_deferred("scroll_to_index_and_focus", saved_focus_index, false)
		elif _scroll_container:
			_reset_transient_scroll_state("refresh_buffer_restore")
			# Clamp to valid range after the new layout is known.
			var scrollbar = (_scroll_container.get_v_scroll_bar() as ScrollBar) if vertical else (_scroll_container.get_h_scroll_bar() as ScrollBar)
			var max_scroll: float = scrollbar.max_value - scrollbar.page if scrollbar else 0.0
			var clamped_offset: int = int(clampf(saved_scroll_offset, 0.0, max_scroll))
			if vertical:
				_scroll_container.scroll_vertical = clamped_offset
			else:
				_scroll_container.scroll_horizontal = clamped_offset
			_scroll_container._target_scroll = clamped_offset
	elif focus_was_in_grid and M3Overlay._get_topmost_overlay() == null:
		# Non-preserve rebuilds (e.g. GameNative adds, post-sync reload) recycle
		# the focused card; restore focus to it so controller users aren't
		# stranded. Scroll position still resets as before.
		call_deferred("scroll_to_index_and_focus", saved_focus_index, false)

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
		var first_line = int(scroll_pos / eff) if eff > 0 else 0
		var visible_start = _get_first_index_for_line(first_line, items_per_line)
		var visible_end = min(_get_first_index_for_line(first_line + visible_rows, items_per_line), _total_items)

		return {
			"start": visible_start,
			"end": visible_end,
			"total": _total_items,
			"source_total": _source_total_items,
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
			"source_total": _source_total_items,
			"buffer_start": _virtual_start,
			"buffer_size": _active_cards.size(),
			"active_cards_count": _active_cards.size()
		}

func get_card_at_index(index: int) -> Control:
	return _active_cards_by_index.get(index, null)

func _clamp_scroll_to_range(offset: float) -> float:
	if not _scroll_container:
		return offset
	if _is_pagination_active():
		# Clamp against the page composition instead of the live scrollbar range:
		# the scrollbar's max is stale while a layout recalc's margin changes are
		# still propagating, which let zoom snaps clamp to (or get undone to)
		# positions between pages.
		return clampf(offset, 0.0, (_get_page_count() - 1) * _get_page_period())
	var scrollbar: ScrollBar = _scroll_container.get_v_scroll_bar() if vertical else _scroll_container.get_h_scroll_bar()
	if not scrollbar:
		return offset
	return clampf(offset, scrollbar.min_value, maxf(scrollbar.min_value, scrollbar.max_value - scrollbar.page))

func _get_current_scroll_pos() -> float:
	if not _scroll_container:
		return 0.0
	return float(_scroll_container.scroll_vertical if vertical else _scroll_container.scroll_horizontal)

## Writes a scroll position during a layout recalc. Use this for ALL scroll
## writes issued while the layout is mid-recalculation: the scrollbar's
## max_value is stale until the end-of-frame sort, so a plain write beyond the
## old range is clamped and the clamp's value_changed rebuilds the buffer
## window at the wrong offset (previously: zoom-in at deep scroll positions
## teleported the view and recycled the focused card).
##
## Strategy: pre-raise max_value (to what the sort will compute anyway), guard
## the scroll handler against the clamp echo, write, then queue a deferred
## corrective write. The corrective RE-ARMS the guard (a plain write there
## clamped again and destroyed the window) and is attempt-capped.
func _set_scroll_position_guarded(pos: float) -> void:
	if not _scroll_container:
		return
	_guarded_scroll_attempts = 0
	_apply_guarded_scroll(pos)

func _apply_guarded_scroll(pos: float) -> void:
	var scrollbar: ScrollBar = _scroll_container.get_v_scroll_bar() if vertical else _scroll_container.get_h_scroll_bar()
	var viewport_axis: float = _get_available_size().y if vertical else _get_available_size().x
	if scrollbar:
		# scrollbar.page is 0 before the first sort; fall back to the viewport.
		var page: float = maxf(scrollbar.page, viewport_axis)
		if pos > scrollbar.max_value - page:
			scrollbar.max_value = pos + page
	_guarded_scroll_target = pos
	_scroll_container.scroll_to(int(pos), false)
	if trace_verbose:
		print("[GridTrace] guarded-write: pos=", pos, " actual_after=", _get_current_scroll_pos(), " sb_max=", scrollbar.max_value if scrollbar else -1.0, " page=", scrollbar.page if scrollbar else -1.0, " t=", Time.get_ticks_msec())
	call_deferred("_correct_guarded_scroll")

func _correct_guarded_scroll() -> void:
	if _guarded_scroll_target < 0.0:
		return
	var target := _guarded_scroll_target
	if not is_inside_tree() or not _scroll_container:
		if trace_verbose:
			print("[GridTrace] corrective: guard cleared (not in tree) target=", target, " t=", Time.get_ticks_msec())
		_guarded_scroll_target = -1.0
		return
	var current := _get_current_scroll_pos()
	if trace_verbose:
		print("[GridTrace] corrective: current=", current, " target=", target, " attempt=", _guarded_scroll_attempts, " t=", Time.get_ticks_msec())
	if absf(current - target) <= 1.0:
		# Write stuck (Range emits nothing when the value doesn't change).
		if trace_verbose:
			print("[GridTrace] corrective: guard cleared (stuck ok) target=", target, " t=", Time.get_ticks_msec())
		_guarded_scroll_target = -1.0
		return
	_guarded_scroll_attempts += 1
	if _guarded_scroll_attempts >= MAX_GUARDED_SCROLL_ATTEMPTS:
		# The range persistently rejects the target (our computed max was wrong
		# or the sort hasn't run). Accept the engine's position rather than
		# loop; subsequent scroll signals process normally with the guard clear.
		push_warning("[Grid] guarded scroll write did not stick after %d attempts (target=%f)" % [MAX_GUARDED_SCROLL_ATTEMPTS, target])
		_guarded_scroll_target = -1.0
		return
	_apply_guarded_scroll(target)

func get_centered_scroll_for_index(idx: int) -> float:
	"""Scroll position that places the center of slot `idx` at the viewport
	center (clamped to the scrollable range). Cards grow around their center
	when focused, so the unfocused card_size is the correct centering basis."""
	if _is_pagination_active():
		# Page alignment wins over centering when paginated.
		return _get_page_scroll_target(_get_page_for_index(idx))
	var slot_pos := _get_slot_position_for_index(idx)
	var focus_overflow := _get_focus_overflow()
	var available := _get_available_size()
	var offset: float
	if vertical:
		offset = slot_pos + focus_overflow.y + card_size.y / 2.0 - available.y / 2.0
	else:
		offset = slot_pos + focus_overflow.x + card_size.x / 2.0 - available.x / 2.0
	return _clamp_scroll_to_range(offset)

func get_follow_focus_scroll_target(idx: int) -> float:
	"""Where to scroll when card `idx` gains focus, honoring the centering mode.
	Both modes are edge-triggered: no scroll happens until the focused card's
	visual bounds (including its focus scale-up) cross a thin margin at a
	viewport edge. Returns the current scroll position when no scroll is needed."""
	if _is_pagination_active():
		# Page alignment wins over centering: focus moves within the current
		# page need no scroll; crossing a boundary jumps to the new page.
		return _get_page_scroll_target(_get_page_for_index(idx))
	var current := _get_current_scroll_pos()
	var slot_pos := _get_slot_position_for_index(idx)
	var focus_overflow := _get_focus_overflow()
	var available := _get_available_size()

	var card_start: float
	var card_end: float
	var viewport_axis: float
	var overflow_axis: float
	if vertical:
		card_start = slot_pos + focus_overflow.y
		card_end = card_start + card_size.y
		viewport_axis = available.y
		overflow_axis = focus_overflow.y
	else:
		card_start = slot_pos + focus_overflow.x
		card_end = card_start + card_size.x
		viewport_axis = available.x
		overflow_axis = focus_overflow.x

	# Visual bounds of the focused card (it grows around its center).
	var visual_start := card_start - overflow_axis
	var visual_end := card_end + overflow_axis

	# Thin trigger margin: flush-plus-grid_separation from each viewport edge.
	var margin := float(grid_separation)
	var view_start := current + margin
	var view_end := current + viewport_axis - margin

	if visual_start >= view_start and visual_end <= view_end:
		return current

	if _focus_centering_mode == FocusCentering.CENTER:
		return get_centered_scroll_for_index(idx)

	# MARGIN: minimal scroll — slide the card just back inside the margin.
	var target := current
	if visual_start < view_start:
		target = visual_start - margin
	elif visual_end > view_end:
		target = visual_end + margin - viewport_axis
	return _clamp_scroll_to_range(target)

func _on_follow_focus_target_request(control: Control) -> float:
	"""Provider callback for SmoothScrollContainer follow-focus scrolling.
	Maps the focused control to its virtual index and uses layout math rather
	than measuring global rects (which can be stale right after recycling)."""
	var node := control
	while node and node != self:
		if node.has_meta("virtual_index"):
			return get_follow_focus_scroll_target(node.get_meta("virtual_index", -1))
		node = node.get_parent()
	return _get_current_scroll_pos()

func scroll_to_index(index: int, animate: bool = false, duration_multiplier: float = 1.0, focus_callback: Callable = Callable()):
	if _scroll_container:
		_reset_transient_scroll_state("scroll_to_index")
		_scroll_container.scroll_to(int(get_centered_scroll_for_index(index)), animate, duration_multiplier, focus_callback)

func scroll_to_index_and_focus(index: int, animate: bool = false, duration_multiplier: float = 1.0) -> void:
	"""Scroll to an item and focus it, honoring the focus-centering mode."""
	if not _scroll_container:
		return
	_focus_request_id += 1
	var request_id := _focus_request_id
	# Defocus the grid before scrolling so the currently focused card is not
	# recycled mid-jump, which would hand focus to a temporary card and trigger
	# a competing smooth-scroll back toward the top.
	_release_focus_inside_grid()
	_pending_focus_index = index
	_programmatic_focus_index = -1
	_scroll_container.follow_focus_suppressed = false
	_reset_transient_scroll_state("jump")

	var target := get_follow_focus_scroll_target(index)
	var current := _get_current_scroll_pos()
	var needs_scroll := not is_equal_approx(target, current)

	if not needs_scroll or not animate:
		# Inside the trigger margin (or instant jump): no animation, focus immediately.
		if needs_scroll:
			_scroll_container.scroll_to(int(target), false)
		var card := get_card_at_index(index)
		if card and is_instance_valid(card) and card.is_inside_tree():
			_apply_focus_to_card(card)
		else:
			_deferred_focus_index(index, request_id, 0)
		return

	# Animated: suppress follow-focus for the duration of the scroll so no
	# competing tween starts; the suppression is lifted in _process() once the
	# scroll settles (_programmatic_focus_index poll).
	_programmatic_focus_index = index
	_scroll_container.follow_focus_suppressed = true
	_scroll_container.scroll_to(int(target), true, duration_multiplier)
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

func _restore_focus_only(index: int) -> void:
	"""Re-grab focus on the card for `index` without changing the scroll
	position. Used after layout recalcs, where the scroll anchor already
	positioned the focused card. Falls back to the pending-focus path (applied
	by the next scroll rebuild) if the card hasn't been created yet."""
	if not is_inside_tree():
		return
	var card := get_card_at_index(index)
	if card and is_instance_valid(card) and card.is_inside_tree():
		_apply_focus_to_card(card)
	else:
		_pending_focus_index = index

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
		if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
			RenderingServer.frame_post_draw.connect(_on_frame_post_draw_audit)
		if _active_cards.size() > 0:
			var first_idx = _active_cards[0].get_meta("virtual_index", 0)
			var last_idx = _active_cards[_active_cards.size() - 1].get_meta("virtual_index", 0)
			_update_debug_visuals(first_idx, last_idx)
	else:
		if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw_audit):
			RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw_audit)
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
	# Not budget-gated: pending effect rebuilds belong to active cards;
	# starving the queue leaves stale/missing effect stacks on screen.
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
	# Dictionary preserves insertion order: erase + re-insert moves the key to
	# the back (most recently used), keeping eviction O(1).
	_cache_lru_tick.erase(cache_key)
	_cache_lru_tick[cache_key] = true

func _evict_oldest_cache_entries(count: int):
	var to_evict = mini(count, _data_cache.size())
	if to_evict <= 0:
		return

	# Front of the insertion-ordered LRU is the least recently used entry.
	var evicted := 0
	for oldest_key in _cache_lru_tick.keys():
		if evicted >= to_evict:
			break
		_cache_lru_tick.erase(oldest_key)
		if _data_cache.has(oldest_key):
			var game = _data_cache[oldest_key]
			if game and game.romm_id != 0:
				_cached_game_ids.erase(game.romm_id)
			_data_cache.erase(oldest_key)
		evicted += 1
