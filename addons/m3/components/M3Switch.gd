@tool
class_name M3Switch
extends CheckButton

## Material 3 Switch
## Custom-drawn toggle switch with optional thumb icon.
## Extends CheckButton for native input/behavior.
## NOTE: This component does NOT support text. Use an M3Label alongside the switch instead.

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const TRACK_WIDTH := 52
const TRACK_HEIGHT := 32
const THUMB_OFF_SIZE := 16
const THUMB_ON_SIZE := 24
const THUMB_PRESSED_SIZE := 28
const ICON_SIZE := 16
const THUMB_PADDING := 4.0  # Minimum padding from track edge (dp)

# ============================================
# EXPORTS
# ============================================

@export var icon_name: String = "":
	set(value):
		if value == icon_name:
			return
		icon_name = value
		_update_icon()
		queue_redraw()

@export var m3_tooltip_text: String = ""
@export var m3_tooltip_variant: M3Tooltip.Variant = M3Tooltip.Variant.PLAIN

# ============================================
# INTERNAL
# ============================================

var _is_pressing: bool = false
var _hovered: bool = false
var _track_sb: StyleBoxFlat
var _thumb_sb: StyleBoxFlat
var _focus_sb: StyleBoxFlat
var _icon_node: FontIcon
var _font_icon_template: FontIconSettings = null

# ============================================
# LIFECYCLE
# ============================================

func _enter_tree():
	# Completely disable native Button/CheckButton drawing
	flat = true
	M3Theme.hide_native_checkbutton_styleboxes(self)
	M3Theme.hide_native_check_icons(self)

func _set(property: StringName, value: Variant) -> bool:
	if property == &"text":
		if value is String and not value.is_empty():
			push_warning("M3Switch does not support text. Use an M3Label alongside the switch instead.")
		# Reject text by returning true without setting the property
		return true
	return false

func _ready():
	var track_width_px = M3Units.dp(TRACK_WIDTH)
	var track_height_px = M3Units.dp(TRACK_HEIGHT)
	custom_minimum_size = Vector2(track_width_px, track_height_px)
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	# Track press state for visual sizing
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	toggled.connect(_on_toggled)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	
	_initialize_styleboxes()
	_initialize_icon()
	M3Tooltip.bind(self, m3_tooltip_text, m3_tooltip_variant)

func _exit_tree():
	M3Tooltip.unbind(self)

func _get_minimum_size() -> Vector2:
	return Vector2(M3Units.dp(TRACK_WIDTH), M3Units.dp(TRACK_HEIGHT))

func _on_button_down():
	_is_pressing = true
	queue_redraw()

func _on_button_up():
	_is_pressing = false
	queue_redraw()

func _on_toggled(_v: bool):
	queue_redraw()

func _on_mouse_entered():
	_hovered = true
	queue_redraw()

func _on_mouse_exited():
	_hovered = false
	queue_redraw()

func _get_font_icon_settings() -> FontIconSettings:
	if _font_icon_template == null:
		_font_icon_template = FontIconSettings.new()
		_font_icon_template.icon_size = M3Units.dp(ICON_SIZE)
		_font_icon_template.icon_font = "MaterialIcons"
	return _font_icon_template.duplicate()

func _initialize_styleboxes():
	_track_sb = StyleBoxFlat.new()
	_track_sb.set_border_width_all(0)
	_track_sb.content_margin_left = 0
	_track_sb.content_margin_top = 0
	_track_sb.content_margin_right = 0
	_track_sb.content_margin_bottom = 0
	_track_sb.anti_aliasing = true
	_track_sb.anti_aliasing_size = 1.0
	
	_thumb_sb = StyleBoxFlat.new()
	_thumb_sb.set_border_width_all(0)
	_thumb_sb.content_margin_left = 0
	_thumb_sb.content_margin_top = 0
	_thumb_sb.content_margin_right = 0
	_thumb_sb.content_margin_bottom = 0
	_thumb_sb.anti_aliasing = true
	_thumb_sb.anti_aliasing_size = 1.0
	
	_focus_sb = StyleBoxFlat.new()
	_focus_sb.set_border_width_all(0)
	_focus_sb.content_margin_left = 0
	_focus_sb.content_margin_top = 0
	_focus_sb.content_margin_right = 0
	_focus_sb.content_margin_bottom = 0
	_focus_sb.anti_aliasing = true
	_focus_sb.anti_aliasing_size = 1.0

func _initialize_icon():
	_icon_node = FontIcon.new()
	_icon_node.name = "Icon"
	_icon_node.icon_settings = _get_font_icon_settings()
	_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_icon_node.visible = false
	add_child(_icon_node)
	_update_icon()

func _update_icon():
	if not _icon_node:
		return
	if not icon_name.is_empty():
		_icon_node.icon_settings.icon_name = icon_name
	_icon_node.visible = not icon_name.is_empty()

# ============================================
# DRAW
# ============================================

func _draw():
	var track_width_px = M3Units.dp(TRACK_WIDTH)
	var track_height_px = M3Units.dp(TRACK_HEIGHT)
	var track_rect = Rect2(
		Vector2((size.x - track_width_px) / 2.0, (size.y - track_height_px) / 2.0),
		Vector2(track_width_px, track_height_px)
	)
	var is_on = button_pressed
	var is_disabled = disabled
	
	# Determine thumb size
	var thumb_size_dp: int
	if _is_pressing:
		thumb_size_dp = THUMB_PRESSED_SIZE
	elif is_on:
		thumb_size_dp = THUMB_ON_SIZE
	else:
		thumb_size_dp = THUMB_OFF_SIZE
	
	var thumb_size_px = M3Units.dp(thumb_size_dp)
	
	# Draw focus ring first (behind everything)
	if has_focus() and not is_disabled:
		_draw_focus_ring(track_rect)
	
	# Draw track
	_draw_track(track_rect, is_on, is_disabled)
	
	# Draw thumb
	var thumb_center = _draw_thumb(track_rect, thumb_size_px, is_on, is_disabled)
	
	# Update icon position and color
	if _icon_node and _icon_node.visible:
		_update_icon_position(thumb_center, thumb_size_px, is_on, is_disabled)

func _draw_focus_ring(rect: Rect2):
	var focus_rect = rect.grow(M3Units.dp(6))
	var radius = int(focus_rect.size.y / 2.0)
	
	_focus_sb.bg_color = Color.TRANSPARENT
	_focus_sb.border_color = M3Theme.get_on_surface()
	_focus_sb.set_border_width_all(3)
	_focus_sb.set_corner_radius_all(radius)
	draw_style_box(_focus_sb, focus_rect)

func _draw_track(rect: Rect2, is_on: bool, is_disabled: bool):
	var radius = int(rect.size.y / 2.0)
	
	if is_disabled:
		if is_on:
			# Disabled ON: very subtle primary
			var prim = M3Theme.get_primary()
			_track_sb.bg_color = Color(prim.r, prim.g, prim.b, 0.12)
			_track_sb.set_border_width_all(0)
		else:
			# Disabled OFF: very subtle surface with outline
			var surf = M3Theme.get_surface_container()
			var outl = M3Theme.get_outline()
			_track_sb.bg_color = Color(surf.r, surf.g, surf.b, 0.12)
			_track_sb.border_color = Color(outl.r, outl.g, outl.b, 0.12)
			_track_sb.set_border_width_all(1)
	elif is_on:
		_track_sb.bg_color = M3Theme.get_primary()
		_track_sb.set_border_width_all(0)
	else:
		_track_sb.bg_color = M3Theme.get_surface_container()
		_track_sb.border_color = M3Theme.get_outline()
		_track_sb.set_border_width_all(1)
	
	_track_sb.set_corner_radius_all(radius)
	draw_style_box(_track_sb, rect)

func _draw_thumb(rect: Rect2, thumb_size_px: float, is_on: bool, is_disabled: bool) -> Vector2:
	var thumb_radius = thumb_size_px / 2.0
	var pad_px = M3Units.dp(THUMB_PADDING)
	
	# Calculate thumb position in control-local coordinates
	var min_x = rect.position.x + pad_px + thumb_radius
	var max_x = rect.position.x + rect.size.x - pad_px - thumb_radius
	var center_y = rect.position.y + rect.size.y / 2.0
	
	var center_x: float
	if is_on:
		center_x = max_x
	else:
		center_x = min_x
	
	var thumb_rect = Rect2(
		Vector2(center_x - thumb_radius, center_y - thumb_radius),
		Vector2(thumb_size_px, thumb_size_px)
	)
	
	# Thumb color with hover overlay
	var base_color: Color
	if is_disabled:
		var on_surf = M3Theme.get_on_surface()
		base_color = Color(on_surf.r, on_surf.g, on_surf.b, 0.12)
	elif is_on:
		base_color = M3Theme.get_on_primary()
	else:
		base_color = M3Theme.get_surface()
	
	# Apply hover state layer
	if _hovered and not is_disabled:
		var overlay_color: Color
		if is_on:
			overlay_color = M3Theme.get_primary()
		else:
			overlay_color = M3Theme.get_on_surface()
		base_color = M3Theme.state_overlay(base_color, overlay_color, M3Theme.OPACITY_HOVER)
	
	_thumb_sb.bg_color = base_color
	_thumb_sb.set_corner_radius_all(int(thumb_radius))
	draw_style_box(_thumb_sb, thumb_rect)
	
	return Vector2(center_x, center_y)

func _update_icon_position(thumb_center: Vector2, thumb_size_px: float, is_on: bool, is_disabled: bool):
	if not _icon_node:
		return
	
	# Position icon node at thumb center
	_icon_node.position = Vector2(
		thumb_center.x - _icon_node.size.x / 2.0,
		thumb_center.y - _icon_node.size.y / 2.0
	)
	
	# Update icon color
	var icon_color: Color
	if is_disabled:
		var on_surf_var = M3Theme.get_on_surface_variant()
		icon_color = Color(on_surf_var.r, on_surf_var.g, on_surf_var.b, 0.38)
	elif is_on:
		icon_color = M3Theme.get_primary()
	else:
		icon_color = M3Theme.get_on_surface_variant()
	
	_icon_node.icon_settings.icon_color = icon_color

# ============================================
# THEME
# ============================================

func refresh_theme():
	queue_redraw()
