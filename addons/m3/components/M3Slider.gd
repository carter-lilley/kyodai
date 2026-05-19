@tool
class_name M3Slider
extends Control

const M3Units = preload("res://addons/m3/M3Units.gd")

## Material 3 Expressive Slider Component
## Uses native HSlider for input, custom rendering for M3 styling
##
## Architecture:
##   - HSlider: handles all input (dragging, clicking, stepping, focus)
##   - Overlay: custom draws everything M3-specific on top
##   - Range hitbox: captures input for range slider's second handle

enum Variant { STANDARD, CENTERED, RANGE }
enum Size { EXTRA_SMALL, SMALL, MEDIUM, LARGE, EXTRA_LARGE }
enum LabelBehavior { ALWAYS, WHILE_DRAGGING, NEVER }
enum SliderOrientation { HORIZONTAL, VERTICAL }

# ============================================
# EXPORTS
# ============================================

@export var slider_variant: Variant = Variant.STANDARD:
	set(value):
		if value == slider_variant:
			return
		slider_variant = value
		_update_theme()
		var is_range = slider_variant == Variant.RANGE
		if _range_hitbox:
			_range_hitbox.mouse_filter = Control.MOUSE_FILTER_PASS if is_range else Control.MOUSE_FILTER_IGNORE
		_request_redraw()
		_invalidate_stop_cache()

@export var orientation: SliderOrientation = SliderOrientation.HORIZONTAL:
	set(value):
		if value == orientation:
			return
		orientation = value
		# Recreate slider with correct type (HSlider vs VSlider)
		if _slider:
			_slider.queue_free()
			_slider = null
		_create_slider()
		_update_size()
		_request_redraw()
		_invalidate_stop_cache()

@export var slider_size: Size = Size.MEDIUM:
	set(value):
		if value == slider_size:
			return
		slider_size = value
		_update_size()
		_update_theme()
		_request_redraw()
		_invalidate_stop_cache()

@export var label_behavior: LabelBehavior = LabelBehavior.WHILE_DRAGGING:
	set(value):
		if value == label_behavior:
			return
		label_behavior = value
		_update_bubble()

@export var label_formatter: String = "%.0f"

@export var show_stops: bool = true:
	set(value):
		if value == show_stops:
			return
		show_stops = value
		_request_redraw()
		_invalidate_stop_cache()

## Custom stop values override the uniform step-based stops.
## When set, the slider snaps to these exact values and draws stops at them.
@export var custom_stop_values: Array[float] = []:
	set(value):
		if value == custom_stop_values:
			return
		custom_stop_values = value
		_request_redraw()
		_invalidate_stop_cache()

@export var start_icon_name: String = "":
	set(value):
		if value == start_icon_name:
			return
		start_icon_name = value
		_update_icons()

@export var end_icon_name: String = "":
	set(value):
		if value == end_icon_name:
			return
		end_icon_name = value
		_update_icons()

@export var range_value: float = 0.0:
	set(v):
		if v == range_value:
			return
		# Prevent crossing: range_value can never exceed value in RANGE mode
		var max_val = _effective_max
		if slider_variant == Variant.RANGE:
			max_val = min(max_val, value)
		range_value = clamp(v, _effective_min, max_val)
		_update_range_hitbox_position()
		_request_redraw()

@export var editable: bool = true:
	get: return _slider.editable if _slider else _cached_editable
	set(v):
		if v == _cached_editable:
			return
		_cached_editable = v
		if _slider:
			_slider.editable = v
			_invalidate_color_cache()
			_request_redraw()

# Proxy properties
@export var min_value: float = 0.0:
	get: return _slider.min_value if _slider else _effective_min
	set(v):
		if v == _effective_min:
			return
		_effective_min = v
		if _slider:
			_slider.min_value = v
			_request_redraw()
			_invalidate_stop_cache()

@export var max_value: float = 100.0:
	get: return _slider.max_value if _slider else _effective_max
	set(v):
		if v == _effective_max:
			return
		_effective_max = v
		if _slider:
			_slider.max_value = v
			_request_redraw()
			_invalidate_stop_cache()

@export var step: float = 0.0:
	get: return _slider.step if _slider else _effective_step
	set(v):
		if v == _effective_step:
			return
		_effective_step = v
		if _slider:
			_slider.step = v
			_request_redraw()
			_invalidate_stop_cache()

@export var value: float = 0.0:
	get: return _slider.value if _slider else _cached_value
	set(v):
		_cached_value = v
		if not _slider:
			return
		# Prevent crossing: value can never go below range_value in RANGE mode
		if slider_variant == Variant.RANGE:
			v = max(v, range_value)
		if v == _slider.value:
			return
		_slider.value = v
		_request_redraw()

@export var m3_tooltip_text: String = ""
@export var m3_tooltip_variant: M3Tooltip.Variant = M3Tooltip.Variant.PLAIN

# ============================================
# INTERNAL
# ============================================

var _slider: Slider
var _overlay: Control
var _range_hitbox: Control
var _bubble: PanelContainer
var _bubble_label: Label
var _start_icon: FontIcon
var _end_icon: FontIcon
var _is_dragging: bool = false
var _is_dragging_range: bool = false
var _is_dragging_primary: bool = false
var _is_focused: bool = false
var _prev_value: float = 0.0  # Value before current drag/click interaction

var _effective_min: float = 0.0
var _effective_max: float = 100.0
var _effective_step: float = 1.0
var _cached_value: float = 0.0
var _cached_editable: bool = true

# Cached StyleBoxFlat instances (allocated once, mutated each frame)
var _cached_style_rect: StyleBoxFlat
var _cached_style_circle: StyleBoxFlat
var _cached_style_focus: StyleBoxFlat

# Cached theme resources
var _cached_font: Font
var _cached_colors: Dictionary = {}
var _cached_disabled_editable: bool = true

# Cached geometry (invalidated each draw)
var _cached_track_rect: Rect2
var _cached_handle_axis: float
var _cached_perp_center: float

# Cached stop positions
var _cached_stops: Array[float] = []
var _cached_stops_valid: bool = false
var _font_icon_template: FontIconSettings = null
var _focus_entered_callable: Callable
var _focus_exited_callable: Callable

# ============================================
# M3 EXPRESSIVE SIZE SPECS (all values in dp)
# ============================================

const SIZE_SPECS = {
	Size.EXTRA_SMALL: {
		"track_h": 16,
		"handle_w": 4,
		"handle_h": 44,
		"track_radius": 8,
		"stop_size": 8,
		"icon_size": 0,  # No inset icons for XS
	},
	Size.SMALL: {
		"track_h": 24,
		"handle_w": 4,
		"handle_h": 44,
		"track_radius": 8,
		"stop_size": 8,
		"icon_size": 0,  # No inset icons for S
	},
	Size.MEDIUM: {
		"track_h": 40,
		"handle_w": 4,
		"handle_h": 52,
		"track_radius": 12,
		"stop_size": 12,
		"icon_size": 24,
	},
	Size.LARGE: {
		"track_h": 56,
		"handle_w": 4,
		"handle_h": 68,
		"track_radius": 16,
		"stop_size": 16,
		"icon_size": 24,
	},
	Size.EXTRA_LARGE: {
		"track_h": 96,
		"handle_w": 4,
		"handle_h": 108,
		"track_radius": 28,
		"stop_size": 28,
		"icon_size": 32,
	},
}

const THUMB_TRACK_GAP := 6.0  # dp
const INSIDE_CORNER_SIZE := 2.0  # dp

const LABEL_WIDTH := 48
const LABEL_HEIGHT := 44

signal value_changed(value: float)
signal range_value_changed(value: float)
signal drag_started
signal drag_ended(value_changed: bool)

func _request_redraw():
	if _overlay:
		_overlay.queue_redraw()

func _invalidate_stop_cache():
	_cached_stops_valid = false

func _invalidate_color_cache():
	_cached_colors.clear()
	_cached_disabled_editable = _slider.editable if _slider else true

## Get the current range as a Vector2 (x=min, y=max)
func get_range() -> Vector2:
	if slider_variant == Variant.RANGE:
		return Vector2(min(value, range_value), max(value, range_value))
	return Vector2(value, value)

## Set the slider value without emitting value_changed signal.
func set_value_no_signal(new_value: float) -> void:
	_cached_value = new_value
	if not _slider:
		return
	if is_equal_approx(new_value, _slider.value):
		return
	_slider.set_block_signals(true)
	_slider.value = new_value
	_slider.set_block_signals(false)
	_request_redraw()



# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_initialize_caches()
	_create_all_children()
	_update_size()
	_update_theme()
	_connect_signals()
	
	# Apply initial values that were set before _slider existed
	if _slider:
		_slider.min_value = _effective_min
		_slider.max_value = _effective_max
		_slider.step = _effective_step
		_slider.value = _cached_value
		_slider.editable = _cached_editable
		_prev_value = _cached_value
	
	# Size children to fill initial parent size
	if _slider:
		_slider.size = size
	if _overlay:
		_overlay.size = size
	
	_update_range_hitbox_position()
	_request_redraw()
	M3Tooltip.bind(self, m3_tooltip_text, m3_tooltip_variant)

func _exit_tree():
	M3Tooltip.unbind(self)

func _initialize_caches():
	# Pre-allocate StyleBoxFlat instances for reuse
	_cached_style_rect = StyleBoxFlat.new()
	_cached_style_circle = StyleBoxFlat.new()
	_cached_style_focus = StyleBoxFlat.new()
	for sb in [_cached_style_rect, _cached_style_circle, _cached_style_focus]:
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 1.0
	
	# Cache font reference (avoid reloading on every theme refresh)
	_cached_font = M3Theme.load_fonts()["bold"]
	
	# Initialize color cache
	_invalidate_color_cache()
	
	# Pre-create bound callables for signal management
	_focus_entered_callable = _on_focus_changed.bind(true)
	_focus_exited_callable = _on_focus_changed.bind(false)

func _get_font_icon_settings() -> FontIconSettings:
	if _font_icon_template == null:
		_font_icon_template = FontIconSettings.new()
		_font_icon_template.outline_color = Color.TRANSPARENT
		_font_icon_template.shadow_color = Color.TRANSPARENT
	return _font_icon_template.duplicate()

func _create_all_children():
	# Create all nodes
	_overlay = Control.new()
	_range_hitbox = Control.new()
	_bubble = PanelContainer.new()
	_bubble_label = Label.new()
	_start_icon = FontIcon.new()
	_end_icon = FontIcon.new()
	
	_create_slider()
	
	# ============================================
	# Configure shared nodes
	# ============================================
	
	# Overlay - draws custom visuals on top. IGNORE input.
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.z_index = 1
	_overlay.draw.connect(_on_overlay_draw)
	
	# Range hitbox - small control that follows the range handle
	# Only captures input when hovering over the range handle area
	_range_hitbox.mouse_filter = Control.MOUSE_FILTER_PASS if slider_variant == Variant.RANGE else Control.MOUSE_FILTER_IGNORE
	_range_hitbox.z_index = 2
	_range_hitbox.gui_input.connect(_on_range_hitbox_input)
	
	# Bubble - M3 value label
	_bubble.visible = false
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.z_index = 10
	
	_bubble_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bubble_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bubble_label.add_theme_font_override("font", _cached_font)
	_bubble_label.add_theme_font_size_override("font_size", M3Theme.TYPE_LABEL_MEDIUM)
	
	_bubble.add_child(_bubble_label)
	
	_update_label_theme()
	
	# Icons
	_start_icon.visible = false
	_start_icon.icon_settings = _get_font_icon_settings()
	_start_icon.z_index = 3
	
	_end_icon.visible = false
	_end_icon.icon_settings = _get_font_icon_settings()
	_end_icon.z_index = 3
	
	# ============================================
	# Add children in render/input order
	# ============================================
	
	add_child(_overlay)      # Draws on top, ignores input
	add_child(_slider)       # Handles all input
	add_child(_range_hitbox) # Handles range second handle input
	add_child(_bubble)       # Label tooltip
	add_child(_start_icon)   # Start icon
	add_child(_end_icon)     # End icon
	
	_update_icons()

func _create_slider():
	"""Create HSlider or VSlider based on orientation."""
	if _slider:
		_slider.queue_free()
	
	if orientation == SliderOrientation.VERTICAL:
		_slider = VSlider.new()
	else:
		_slider = HSlider.new()
	
	# Restore cached values
	_slider.min_value = _effective_min
	_slider.max_value = _effective_max
	_slider.step = _effective_step
	_slider.value = value
	
	# Slider handles all native input including keyboard/controller
	# It's visually hidden but must be focusable for input
	_slider.modulate = Color.TRANSPARENT
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Note: Signals are connected in _connect_signals() which is called from _ready()
	# Do not connect here to avoid duplicates when _create_slider() is called from setters

func _notification(what: int):
	if what == NOTIFICATION_RESIZED:
		if _slider:
			_slider.size = size
		if _overlay:
			_overlay.size = size
		_update_range_hitbox_position()
		_update_bubble()

# ============================================
# UPDATES
# ============================================

func _update_icons():
	if not _start_icon or not _end_icon:
		return
	
	var icon_size_dp = SIZE_SPECS[slider_size]["icon_size"]
	var icon_size_px = M3Units.dp(icon_size_dp)
	
	if icon_size_dp > 0 and start_icon_name:
		_start_icon.visible = true
		_start_icon.icon_settings.icon_name = start_icon_name
		_start_icon.icon_settings.icon_size = icon_size_px
		_start_icon.icon_settings.outline_color = Color.TRANSPARENT
		_start_icon.icon_settings.shadow_color = Color.TRANSPARENT
		_update_icon_color(_start_icon, true)
	else:
		_start_icon.visible = false
	
	if icon_size_dp > 0 and end_icon_name:
		_end_icon.visible = true
		_end_icon.icon_settings.icon_name = end_icon_name
		_end_icon.icon_settings.icon_size = icon_size_px
		_end_icon.icon_settings.outline_color = Color.TRANSPARENT
		_end_icon.icon_settings.shadow_color = Color.TRANSPARENT
		_update_icon_color(_end_icon, false)
	else:
		_end_icon.visible = false

func _update_icon_color(icon: FontIcon, is_start: bool):
	"""Update icon color based on whether it's in active or inactive track area."""
	if not icon or not icon.visible:
		return
	
	var handle_axis_pos = _get_axis_position(value)
	var track_rect = _get_track_rect()
	var padding = M3Units.dp(8)
	
	# Calculate icon center position along the slider axis
	var icon_axis_pos: float
	if _is_vertical():
		# For vertical: start icon is at bottom, end icon is at top
		if is_start:
			icon_axis_pos = track_rect.end.y - padding - icon.size.y / 2
		else:
			icon_axis_pos = track_rect.position.y + padding + icon.size.y / 2
	else:
		# For horizontal: start icon is at left, end icon is at right
		if is_start:
			icon_axis_pos = track_rect.position.x + padding + icon.size.x / 2
		else:
			icon_axis_pos = track_rect.end.x - padding - icon.size.x / 2
	
	# Determine if icon is in active or inactive track
	# For vertical: active is below handle (higher axis value)
	# For horizontal: active is left of handle (lower axis value)
	var is_active: bool
	if _is_vertical():
		is_active = icon_axis_pos > handle_axis_pos
	else:
		is_active = icon_axis_pos < handle_axis_pos
	
	# Set color based on track state (with disabled state support)
	var new_color
	if is_active:
		new_color = _get_disabled_color(M3Theme.get_on_primary())
	else:
		new_color = _get_disabled_color(M3Theme.get_on_surface())
	if icon.icon_settings.icon_color != new_color:
		icon.icon_settings.icon_color = new_color
		# Force FontIcon to refresh
		icon._on_icon_settings_changed()

func _update_size():
	if not _slider:
		return
	
	var spec = SIZE_SPECS[slider_size]
	if _is_vertical():
		# Component width = handle height (handle extends left/right of track)
		var min_w = M3Units.dp(spec["handle_h"])
		custom_minimum_size.x = max(custom_minimum_size.x, min_w)
	else:
		# Component height = handle height (handle extends above/below track)
		var min_h = M3Units.dp(spec["handle_h"])
		custom_minimum_size.y = max(custom_minimum_size.y, min_h)
	_update_icons()

func refresh_theme():
	"""Refresh all theme-dependent styling. Called by parent when dark mode changes."""
	_invalidate_color_cache()
	_update_label_theme()
	_update_icons()
	_request_redraw()

func _update_range_hitbox_position():
	if slider_variant != Variant.RANGE:
		return
	if not _range_hitbox:
		return
	
	var handle_pos = _get_handle_position(range_value)
	var hit_w: float
	var hit_h: float
	if _is_vertical():
		hit_w = _get_handle_h() * 2
		hit_h = _get_handle_w() * 4
	else:
		hit_w = _get_handle_w() * 4
		hit_h = _get_handle_h() * 2
	
	_range_hitbox.position = Vector2(
		handle_pos.x - hit_w / 2,
		handle_pos.y - hit_h / 2
	)
	_range_hitbox.size = Vector2(hit_w, hit_h)

func _update_label_theme():
	if not _bubble:
		return
	
	# M3 value label: dark surface background, light text, fully rounded
	var label_style = M3Theme.make_flat(
		M3Theme.get_on_surface(),
		int(M3Units.dp(22)),
		0, Color.TRANSPARENT,
		int(M3Units.dp(12)), int(M3Units.dp(12))
	)
	_bubble.add_theme_stylebox_override("panel", label_style)
	
	if _bubble_label:
		_bubble_label.add_theme_color_override("font_color", M3Theme.get_surface())

func _update_theme():
	if not _slider:
		return
	
	# HSlider needs to be visible but not draw anything native
	# We handle all rendering in the overlay
	pass

func _connect_signals():
	# Disconnect first to prevent duplicates if called multiple times
	if _slider.value_changed.is_connected(_on_value_changed):
		_slider.value_changed.disconnect(_on_value_changed)
	if _slider.drag_started.is_connected(_on_drag_started):
		_slider.drag_started.disconnect(_on_drag_started)
	if _slider.drag_ended.is_connected(_on_drag_ended):
		_slider.drag_ended.disconnect(_on_drag_ended)
	if _slider.focus_entered.is_connected(_focus_entered_callable):
		_slider.focus_entered.disconnect(_focus_entered_callable)
	if _slider.focus_exited.is_connected(_focus_exited_callable):
		_slider.focus_exited.disconnect(_focus_exited_callable)
	
	_slider.value_changed.connect(_on_value_changed)
	_slider.drag_started.connect(_on_drag_started)
	_slider.drag_ended.connect(_on_drag_ended)
	_slider.focus_entered.connect(_focus_entered_callable)
	_slider.focus_exited.connect(_focus_exited_callable)

func _on_focus_changed(has_focus: bool):
	_is_focused = has_focus
	_request_redraw()

# ============================================
# SIGNAL HANDLERS
# ============================================

func _on_value_changed(new_value: float):
	# Snap to custom stops or step if needed
	var snapped_value = _snap_to_nearest_stop(new_value)
	if not is_equal_approx(snapped_value, new_value) and _slider:
		_slider.set_block_signals(true)
		_slider.value = snapped_value
		_slider.set_block_signals(false)
		new_value = snapped_value
		_request_redraw()
	
	if slider_variant == Variant.RANGE:
		if _is_dragging_primary:
			# Primary handle drag: just constrain range_value
			if range_value > new_value:
				range_value = new_value
			value_changed.emit(new_value)
		else:
			# Track click (jump): move nearest handle using PRE-click positions
			var dist_to_primary = abs(new_value - _prev_value)
			var dist_to_range = abs(new_value - range_value)
			if dist_to_range < dist_to_primary:
				# Range handle is closer: move it, restore primary
				range_value = new_value
				# Restore HSlider to primary handle's pre-click position
				if _slider:
					_slider.set_block_signals(true)
					_slider.value = _prev_value
					_slider.set_block_signals(false)
				range_value_changed.emit(range_value)
			else:
				# Primary handle is closer or equal: move it, constrain range
				if range_value > new_value:
					range_value = new_value
				value_changed.emit(new_value)
	else:
		value_changed.emit(new_value)
	
	# Update icon colors based on new handle position
	_update_icon_color(_start_icon, true)
	_update_icon_color(_end_icon, false)
	
	_request_redraw()
	_update_bubble()

func _on_drag_started():
	_prev_value = value
	
	if _slider:
		_slider.grab_focus()
	
	var mouse_local = get_global_mouse_position() - global_position
	var primary_axis = _cached_handle_axis if _overlay else _get_axis_position(value)
	var hit_radius = _get_handle_w() * 3
	var is_on_handle: bool
	if _is_vertical():
		is_on_handle = abs(mouse_local.y - primary_axis) <= hit_radius
	else:
		is_on_handle = abs(mouse_local.x - primary_axis) <= hit_radius
	
	_is_dragging = true
	_is_dragging_primary = is_on_handle
	drag_started.emit()
	_request_redraw()
	_update_bubble()

func _on_drag_ended(_value_changed: bool):
	_is_dragging = false
	_is_dragging_primary = false
	_prev_value = value
	drag_ended.emit(_value_changed)
	_request_redraw()
	_update_bubble()

# ============================================
# BUBBLE / LABEL
# ============================================

func _update_bubble():
	if not _bubble or not _bubble_label:
		return
	
	var should_show = false
	match label_behavior:
		LabelBehavior.ALWAYS:
			should_show = true
		LabelBehavior.WHILE_DRAGGING:
			should_show = _is_dragging
		LabelBehavior.NEVER:
			should_show = false
	
	if not should_show:
		_bubble.visible = false
		return
	
	_bubble.visible = true
	_bubble_label.text = label_formatter % value
	_position_bubble.call_deferred()

func _position_bubble():
	if not _bubble:
		return
	var handle_pos = _get_handle_position(value)
	var handle_w = _get_handle_w()
	var handle_h = _get_handle_h()
	var bubble_w = M3Units.dp(LABEL_WIDTH)
	var bubble_h = M3Units.dp(LABEL_HEIGHT)
	
	if _is_vertical():
		# Position 4dp to the left of the handle (centered vertically on handle)
		_bubble.position = Vector2(
			handle_pos.x - handle_h / 2 - bubble_w - M3Units.dp(4),
			handle_pos.y - bubble_h / 2
		)
	else:
		# Position 4dp above the handle (centered horizontally on handle)
		_bubble.position = Vector2(
			handle_pos.x - bubble_w / 2,
			handle_pos.y - handle_h / 2 - bubble_h - M3Units.dp(4)
		)
	_bubble.size = Vector2(bubble_w, bubble_h)

# ============================================
# ORIENTATION HELPERS
# ============================================

func _is_vertical() -> bool:
	return orientation == SliderOrientation.VERTICAL

## Get slider axis size (width for horizontal, height for vertical)
func _get_slider_axis_size() -> float:
	if _is_vertical():
		return size.y
	return size.x

## Get the center position on the perpendicular axis
func _get_perp_center() -> float:
	if _is_vertical():
		return size.x / 2.0
	return size.y / 2.0

## Get position along slider axis for a given value
func _get_axis_position(for_value: float) -> float:
	var handle_size = _get_handle_w()
	var area_size = _get_slider_axis_size() - handle_size
	var ratio = (for_value - min_value) / (max_value - min_value)
	
	if _is_vertical():
		# VSlider: 0 at top, max at bottom (inverted)
		return (1.0 - ratio) * area_size + handle_size / 2.0
	else:
		# HSlider: 0 at left, max at right
		return ratio * area_size + handle_size / 2.0

## Convert a position along the axis back to a value
func _get_value_at_axis_position(pos: float) -> float:
	var handle_size = _get_handle_w()
	var area_size = _get_slider_axis_size() - handle_size
	if area_size <= 0:
		return min_value
	
	var ratio: float
	if _is_vertical():
		# Invert for vertical (top is max)
		ratio = 1.0 - (pos - handle_size / 2.0) / area_size
	else:
		ratio = (pos - handle_size / 2.0) / area_size
	
	return clamp(lerpf(min_value, max_value, ratio), min_value, max_value)

## Build a point from axis position and perpendicular center
func _make_point(axis_pos: float, perp_offset: float = 0.0) -> Vector2:
	if _is_vertical():
		return Vector2(_get_perp_center() + perp_offset, axis_pos)
	return Vector2(axis_pos, _get_perp_center() + perp_offset)

# ============================================
# GEOMETRY HELPERS
# ============================================

func _get_handle_w() -> float:
	# When dragging or focused, use thin line (2dp) for cleaner interaction
	if _is_dragging or _is_dragging_range or _is_focused:
		return M3Units.dp(2)
	return M3Units.dp(SIZE_SPECS[slider_size]["handle_w"])

func _get_handle_h() -> float:
	return M3Units.dp(SIZE_SPECS[slider_size]["handle_h"])

func _get_track_h() -> float:
	return M3Units.dp(SIZE_SPECS[slider_size]["track_h"])

func _get_track_radius() -> float:
	return M3Units.dp(SIZE_SPECS[slider_size]["track_radius"])

func _get_stop_size() -> float:
	return M3Units.dp(4)

func _get_handle_position(for_value: float) -> Vector2:
	var axis_pos = _get_axis_position(for_value)
	return _make_point(axis_pos)

func _get_track_rect() -> Rect2:
	var track_thickness = _get_track_h()
	var perp_center = _get_perp_center()
	var axis_size = _get_slider_axis_size()
	
	if _is_vertical():
		# Vertical track: spans full height, centered horizontally
		var x = perp_center - track_thickness / 2.0
		return Rect2(
			Vector2(x, 0),
			Vector2(track_thickness, axis_size)
		)
	else:
		# Horizontal track: spans full width, centered vertically
		var y = perp_center - track_thickness / 2.0
		return Rect2(
			Vector2(0, y),
			Vector2(axis_size, track_thickness)
		)

func _get_disabled_color(normal_color: Color) -> Color:
	var color_key = str(normal_color)
	if _cached_colors.has(color_key):
		return _cached_colors[color_key]
	
	var result: Color
	if not _slider or _slider.editable:
		result = normal_color
	else:
		result = M3Theme.disabled_color(normal_color)
	
	_cached_colors[color_key] = result
	return result

func _get_stop_positions() -> Array[float]:
	if _cached_stops_valid:
		return _cached_stops
	
	_cached_stops.clear()
	
	if not show_stops:
		_cached_stops_valid = true
		return _cached_stops
	
	# Use custom stops if provided
	if custom_stop_values.size() > 0:
		for stop in custom_stop_values:
			if stop >= min_value and stop <= max_value:
				# Deduplicate visually identical stops
				var is_duplicate = false
				for existing in _cached_stops:
					if is_equal_approx(stop, existing):
						is_duplicate = true
						break
				if not is_duplicate:
					_cached_stops.append(stop)
		_cached_stops_valid = true
		return _cached_stops
	
	# Fall back to uniform step-based stops
	if step <= 0:
		_cached_stops_valid = true
		return _cached_stops
	
	var range_val = max_value - min_value
	if range_val <= 0:
		_cached_stops_valid = true
		return _cached_stops
	
	var count = roundi(range_val / step)
	if count <= 1:
		_cached_stops_valid = true
		return _cached_stops
	if count > 50:
		_cached_stops_valid = true
		return _cached_stops  # Too many stops
	
	_cached_stops.resize(count - 1)
	for i in range(1, count):
		_cached_stops[i - 1] = min_value + i * step
	
	_cached_stops_valid = true
	return _cached_stops

func _snap_to_nearest_stop(raw_value: float) -> float:
	"""Snap a raw value to the nearest custom stop, or to step if no custom stops."""
	if custom_stop_values.size() > 0:
		var nearest = custom_stop_values[0]
		var nearest_dist = abs(raw_value - nearest)
		for stop in custom_stop_values:
			var dist = abs(raw_value - stop)
			if dist < nearest_dist:
				nearest_dist = dist
				nearest = stop
		return clampf(nearest, min_value, max_value)
	elif step > 0:
		return clampf(snappedf(raw_value, step), min_value, max_value)
	return clampf(raw_value, min_value, max_value)

# ============================================
# CUSTOM DRAWING
# ============================================

func _on_overlay_draw():
	if not _slider:
		return
	
	# Cache geometry once per draw
	_cached_track_rect = _get_track_rect()
	_cached_handle_axis = _get_axis_position(value)
	_cached_perp_center = _get_perp_center()
	
	_draw_track()
	
	if slider_variant == Variant.STANDARD:
		_draw_standard_active_track()
	elif slider_variant == Variant.CENTERED:
		_draw_centered_active_track()
		_draw_zero_mark()
	elif slider_variant == Variant.RANGE:
		_draw_range_active_track()
		_draw_range_handle()
	
	_draw_stops()
	_draw_end_indicator()
	_draw_primary_handle()
	_draw_icons()
	
	if _is_focused:
		_draw_focus_ring()

func _draw_track():
	var track_rect = _cached_track_rect
	var out_radius = _get_track_radius()
	var in_radius = M3Units.dp(INSIDE_CORNER_SIZE)
	var gap = M3Units.dp(THUMB_TRACK_GAP)
	var color = _get_disabled_color(M3Theme.get_surface_variant())
	var handle_axis = _cached_handle_axis
	
	if _is_vertical():
		# Vertical: top and bottom inactive segments
		var top_h = handle_axis - gap - track_rect.position.y
		if top_h > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(track_rect.position.x, track_rect.position.y),
				Vector2(track_rect.size.x, top_h)
			), color, out_radius, out_radius, in_radius, in_radius)
		
		var bottom_start = handle_axis + gap
		var bottom_h = track_rect.end.y - bottom_start
		if bottom_h > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(track_rect.position.x, bottom_start),
				Vector2(track_rect.size.x, bottom_h)
			), color, in_radius, in_radius, out_radius, out_radius)
	else:
		# Horizontal: left and right inactive segments
		var left_w = handle_axis - gap - track_rect.position.x
		if left_w > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(track_rect.position.x, track_rect.position.y),
				Vector2(left_w, track_rect.size.y)
			), color, out_radius, in_radius, out_radius, in_radius)
		
		var right_start = handle_axis + gap
		var right_w = track_rect.end.x - right_start
		if right_w > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(right_start, track_rect.position.y),
				Vector2(right_w, track_rect.size.y)
			), color, in_radius, out_radius, in_radius, out_radius)

func _draw_standard_active_track():
	var track_rect = _cached_track_rect
	var out_radius = _get_track_radius()
	var in_radius = M3Units.dp(INSIDE_CORNER_SIZE)
	var gap = M3Units.dp(THUMB_TRACK_GAP)
	var color = _get_disabled_color(M3Theme.get_primary())
	var handle_axis = _cached_handle_axis
	
	if _is_vertical():
		var active_h = track_rect.end.y - handle_axis - gap
		if active_h > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(track_rect.position.x, handle_axis + gap),
				Vector2(track_rect.size.x, active_h)
			), color, in_radius, in_radius, out_radius, out_radius)
	else:
		var active_w = handle_axis - gap - track_rect.position.x
		if active_w > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(track_rect.position.x, track_rect.position.y),
				Vector2(active_w, track_rect.size.y)
			), color, out_radius, in_radius, out_radius, in_radius)

func _draw_centered_active_track():
	var track_rect = _cached_track_rect
	var in_radius = M3Units.dp(INSIDE_CORNER_SIZE)
	var gap = M3Units.dp(THUMB_TRACK_GAP)
	var color = _get_disabled_color(M3Theme.get_primary())
	var zero_axis = _get_axis_position(0.0)
	var handle_axis = _cached_handle_axis
	
	var start_axis = min(zero_axis, handle_axis) + gap
	var end_axis = max(zero_axis, handle_axis) - gap
	
	if _is_vertical():
		var active_h = end_axis - start_axis
		if active_h > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(track_rect.position.x, start_axis),
				Vector2(track_rect.size.x, active_h)
			), color, in_radius, in_radius, in_radius, in_radius)
	else:
		var active_w = end_axis - start_axis
		if active_w > 0:
			_draw_rounded_rect_asymmetric(Rect2(
				Vector2(start_axis, track_rect.position.y),
				Vector2(active_w, track_rect.size.y)
			), color, in_radius, in_radius, in_radius, in_radius)

func _draw_zero_mark():
	var zero_value = 0.0
	if zero_value < min_value or zero_value > max_value:
		return
	
	var pos = _get_axis_position(zero_value)
	var stop_size = _get_stop_size()
	var center = _cached_perp_center
	var color = _get_disabled_color(M3Theme.get_on_surface())
	
	if _is_vertical():
		_draw_smooth_circle(Rect2(
			Vector2(center - stop_size / 2.0, pos - stop_size / 2.0),
			Vector2(stop_size, stop_size)
		), color)
	else:
		_draw_smooth_circle(Rect2(
			Vector2(pos - stop_size / 2.0, center - stop_size / 2.0),
			Vector2(stop_size, stop_size)
		), color)

func _draw_range_active_track():
	var track_rect = _cached_track_rect
	var in_radius = M3Units.dp(INSIDE_CORNER_SIZE)
	var gap = M3Units.dp(THUMB_TRACK_GAP)
	var color = _get_disabled_color(M3Theme.get_primary())
	
	var val1 = _cached_handle_axis
	var val2 = _get_axis_position(range_value)
	
	var start_axis = min(val1, val2) + gap
	var end_axis = max(val1, val2) - gap
	
	if _is_vertical():
		var active_h = end_axis - start_axis
		if active_h > 0:
			var active_rect = Rect2(
				Vector2(track_rect.position.x, start_axis),
				Vector2(track_rect.size.x, active_h)
			)
			_draw_rounded_rect_asymmetric(active_rect, color, in_radius, in_radius, in_radius, in_radius)
	else:
		var active_w = end_axis - start_axis
		if active_w > 0:
			var active_rect = Rect2(
				Vector2(start_axis, track_rect.position.y),
				Vector2(active_w, track_rect.size.y)
			)
			_draw_rounded_rect_asymmetric(active_rect, color, in_radius, in_radius, in_radius, in_radius)

func _draw_stops():
	if not show_stops:
		return
	
	var stops = _get_stop_positions()
	if stops.size() == 0:
		return
	
	var stop_size = _get_stop_size()
	var active_color = _get_disabled_color(M3Theme.get_on_primary())
	var inactive_color = _get_disabled_color(M3Theme.get_on_surface_variant())
	var center = _cached_perp_center
	
	for stop in stops:
		var pos = _get_axis_position(stop)
		var is_active = false
		
		if slider_variant == Variant.CENTERED:
			is_active = (stop >= min(value, 0.0) and stop <= max(value, 0.0))
		elif slider_variant == Variant.RANGE:
			is_active = (stop >= min(value, range_value) and stop <= max(value, range_value))
		else:
			is_active = stop <= value
		
		var color = active_color if is_active else inactive_color
		if _is_vertical():
			_draw_smooth_circle(Rect2(
				Vector2(center - stop_size / 2.0, pos - stop_size / 2.0),
				Vector2(stop_size, stop_size)
			), color)
		else:
			_draw_smooth_circle(Rect2(
				Vector2(pos - stop_size / 2.0, center - stop_size / 2.0),
				Vector2(stop_size, stop_size)
			), color)

func _draw_end_indicator():
	"""Draw end-of-track indicator dot at max value position."""
	# Only skip if a stop is already drawn at the exact end
	for stop in _get_stop_positions():
		if is_equal_approx(stop, max_value):
			return
	
	var track_rect = _cached_track_rect
	var stop_size = _get_stop_size()
	var gap = M3Units.dp(4)
	var center = _cached_perp_center
	var end_value = max_value
	
	var is_active = false
	if slider_variant == Variant.CENTERED:
		is_active = (end_value >= min(value, 0.0) and end_value <= max(value, 0.0))
	elif slider_variant == Variant.RANGE:
		is_active = (end_value >= min(value, range_value) and end_value <= max(value, range_value))
	else:
		is_active = end_value <= value
	
	var color = _get_disabled_color(M3Theme.get_on_primary() if is_active else M3Theme.get_on_surface_variant())
	
	if _is_vertical():
		_draw_smooth_circle(Rect2(
			Vector2(center - stop_size / 2.0, track_rect.position.y + gap),
			Vector2(stop_size, stop_size)
		), color)
	else:
		_draw_smooth_circle(Rect2(
			Vector2(track_rect.end.x - gap - stop_size, center - stop_size / 2.0),
			Vector2(stop_size, stop_size)
		), color)

func _draw_smooth_circle(rect: Rect2, color: Color):
	"""Draw anti-aliased circle using cached StyleBoxFlat for smooth edges."""
	var radius = int(min(rect.size.x, rect.size.y) / 2.0)
	var style = _cached_style_circle
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	_overlay.draw_style_box(style, rect)

func _draw_primary_handle():
	var handle_pos = _get_handle_position(value)
	var handle_w = _get_handle_w()
	var handle_h = _get_handle_h()
	var color = _get_disabled_color(M3Theme.get_primary())
	
	if _is_vertical():
		# Vertical: thin horizontal bar
		var rect = Rect2(
			Vector2(handle_pos.x - handle_h / 2, handle_pos.y - handle_w / 2),
			Vector2(handle_h, handle_w)
		)
		var radius = handle_w / 2.0
		_draw_rounded_rect(rect, color, radius)
	else:
		# Horizontal: thin vertical bar
		var rect = Rect2(
			Vector2(handle_pos.x - handle_w / 2, handle_pos.y - handle_h / 2),
			Vector2(handle_w, handle_h)
		)
		var radius = handle_w / 2.0
		_draw_rounded_rect(rect, color, radius)

func _draw_range_handle():
	var handle_pos = _get_handle_position(range_value)
	var handle_w = _get_handle_w()
	var handle_h = _get_handle_h()
	var prim = _get_disabled_color(M3Theme.get_primary())
	var surf = _get_disabled_color(M3Theme.get_surface())
	
	if _is_vertical():
		# Vertical: thin horizontal bar with hollow center
		var rect = Rect2(
			Vector2(handle_pos.x - handle_h / 2, handle_pos.y - handle_w / 2),
			Vector2(handle_h, handle_w)
		)
		var radius = handle_w / 2.0
		_draw_rounded_rect(rect, prim, radius)
		
		var inner_h = max(1, handle_w - 2)
		var inner_rect = Rect2(
			Vector2(handle_pos.x - handle_h / 2 + 2, handle_pos.y - inner_h / 2),
			Vector2(handle_h - 4, inner_h)
		)
		_draw_rounded_rect(inner_rect, surf, inner_h / 2.0)
	else:
		# Horizontal: thin vertical bar with hollow center
		var rect = Rect2(
			Vector2(handle_pos.x - handle_w / 2, handle_pos.y - handle_h / 2),
			Vector2(handle_w, handle_h)
		)
		var radius = handle_w / 2.0
		_draw_rounded_rect(rect, prim, radius)
		
		var inner_w = max(1, handle_w - 2)
		var inner_rect = Rect2(
			Vector2(handle_pos.x - inner_w / 2, handle_pos.y - handle_h / 2 + 2),
			Vector2(inner_w, handle_h - 4)
		)
		_draw_rounded_rect(inner_rect, surf, inner_w / 2.0)

func _draw_focus_ring():
	"""Draw a hollow pill-shaped focus ring around the primary handle."""
	var handle_pos = _get_handle_position(value)
	var handle_w = _get_handle_w()
	var handle_h = _get_handle_h()
	var ring_color = _get_disabled_color(M3Theme.get_on_surface())
	var border_w = M3Units.dp(2)  # 2dp border width
	
	var style = _cached_style_focus
	style.bg_color = Color.TRANSPARENT
	style.border_color = ring_color
	style.border_width_left = int(border_w)
	style.border_width_top = int(border_w)
	style.border_width_right = int(border_w)
	style.border_width_bottom = int(border_w)
	
	if _is_vertical():
		# Vertical: horizontal pill
		var ring_w = handle_h + M3Units.dp(8)
		var ring_h = M3Units.dp(12)
		style.corner_radius_top_left = int(ring_h / 2.0)
		style.corner_radius_top_right = int(ring_h / 2.0)
		style.corner_radius_bottom_left = int(ring_h / 2.0)
		style.corner_radius_bottom_right = int(ring_h / 2.0)
		_overlay.draw_style_box(style, Rect2(
			Vector2(handle_pos.x - ring_w / 2, handle_pos.y - ring_h / 2),
			Vector2(ring_w, ring_h)
		))
	else:
		# Horizontal: vertical pill
		var ring_w = M3Units.dp(12)
		var ring_h = handle_h + M3Units.dp(8)
		style.corner_radius_top_left = int(ring_w / 2.0)
		style.corner_radius_top_right = int(ring_w / 2.0)
		style.corner_radius_bottom_left = int(ring_w / 2.0)
		style.corner_radius_bottom_right = int(ring_w / 2.0)
		_overlay.draw_style_box(style, Rect2(
			Vector2(handle_pos.x - ring_w / 2, handle_pos.y - ring_h / 2),
			Vector2(ring_w, ring_h)
		))

func _draw_rounded_rect(rect: Rect2, color: Color, radius: float):
	"""Draw a rounded rectangle with uniform corner radius."""
	_draw_rounded_rect_asymmetric(rect, color, radius, radius, radius, radius)

func _draw_rounded_rect_asymmetric(rect: Rect2, color: Color,
								   tl: float, tr: float, bl: float, br: float):
	"""Draw a rounded rectangle with per-corner radius control using cached StyleBox."""
	var style = _cached_style_rect
	style.bg_color = color
	style.corner_radius_top_left = int(tl)
	style.corner_radius_top_right = int(tr)
	style.corner_radius_bottom_left = int(bl)
	style.corner_radius_bottom_right = int(br)
	_overlay.draw_style_box(style, rect)

func _draw_icons():
	if not _start_icon or not _end_icon:
		return
	
	var track_rect = _cached_track_rect
	var padding = M3Units.dp(8)
	var center = _cached_perp_center
	
	if _is_vertical():
		if _start_icon.visible:
			_start_icon.position = Vector2(
				center - _start_icon.size.x / 2,
				track_rect.end.y - _start_icon.size.y - padding
			)
		
		if _end_icon.visible:
			_end_icon.position = Vector2(
				center - _end_icon.size.x / 2,
				track_rect.position.y + padding
			)
	else:
		if _start_icon.visible:
			_start_icon.position = Vector2(
				track_rect.position.x + padding,
				center - _start_icon.size.y / 2
			)
		
		if _end_icon.visible:
			_end_icon.position = Vector2(
				track_rect.end.x - _end_icon.size.x - padding,
				center - _end_icon.size.y / 2
			)

# ============================================
# RANGE INPUT HANDLING
# ============================================

func _on_range_hitbox_input(event: InputEvent):
	if slider_variant != Variant.RANGE:
		return
	
	# Convert event position from hitbox-local to parent-local (M3Slider space)
	var local_pos = event.position + _range_hitbox.position
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var range_handle_pos = _get_handle_position(range_value)
				var hit_w: float
				var hit_h: float
				if _is_vertical():
					hit_w = _get_handle_h() * 2
					hit_h = _get_handle_w() * 4
				else:
					hit_w = _get_handle_w() * 4
					hit_h = _get_handle_h() * 2
				var hit_rect = Rect2(
					Vector2(range_handle_pos.x - hit_w / 2, range_handle_pos.y - hit_h / 2),
					Vector2(hit_w, hit_h)
				)
				if hit_rect.has_point(local_pos):
					_is_dragging_range = true
					accept_event()
			else:
				if _is_dragging_range:
					_is_dragging_range = false
					accept_event()
	
	elif event is InputEventMouseMotion:
		if _is_dragging_range:
			var track = _get_track_rect()
			var ratio: float
			if _is_vertical():
				ratio = clamp((local_pos.y - track.position.y) / track.size.y, 0.0, 1.0)
				# Invert for vertical (top is max)
				ratio = 1.0 - ratio
			else:
				ratio = clamp((local_pos.x - track.position.x) / track.size.x, 0.0, 1.0)
			var new_val = lerpf(min_value, max_value, ratio)
			if step > 0:
				new_val = snappedf(new_val, step)
			# Prevent range handle from crossing above primary handle
			new_val = min(new_val, value)
			range_value = clamp(new_val, min_value, max_value)
			range_value_changed.emit(range_value)
			_update_icon_color(_start_icon, true)
			_update_icon_color(_end_icon, false)
			_request_redraw()
			accept_event()
