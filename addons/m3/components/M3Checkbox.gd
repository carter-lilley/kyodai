@tool
class_name M3Checkbox
extends CheckBox

## Material 3 Checkbox Component
## Custom-drawn checkbox with precise M3 spec compliance.
## Supports checked, unchecked, and indeterminate states.

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const BOX_SIZE := 18.0
const CORNER_RADIUS := 2.0
const BORDER_WIDTH := 2.0
const CHECK_STROKE := 2.0
const TOUCH_TARGET := 40.0

# ============================================
# EXPORTS
# ============================================

@export var indeterminate: bool = false:
	set(value):
		if value == indeterminate:
			return
		indeterminate = value
		queue_redraw()

@export var error: bool = false:
	set(value):
		if value == error:
			return
		error = value
		queue_redraw()

@export var m3_tooltip_text: String = ""
@export var m3_tooltip_variant: M3Tooltip.Variant = M3Tooltip.Variant.PLAIN

# ============================================
# INTERNAL
# ============================================

var _hovered: bool = false
var _pressed: bool = false

# Cached StyleBoxFlats (allocated once, mutated per draw)
var _cached_box_sb: StyleBoxFlat
var _cached_overlay_sb: StyleBoxFlat

# ============================================
# LIFECYCLE
# ============================================

func _enter_tree():
	# Hide native CheckBox visuals
	flat = true
	M3Theme.hide_native_check_icons(self)
	
	# Suppress native focus stylebox - we draw our own ring
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	
	# Text styling - use on_surface for proper contrast
	var fonts = M3Theme.load_fonts()
	add_theme_font_override("font", fonts["regular"])
	add_theme_font_size_override("font_size", M3Units.dp(14))
	add_theme_color_override("font_color", M3Theme.get_on_surface())
	add_theme_color_override("font_pressed_color", M3Theme.get_on_surface())
	add_theme_color_override("font_hover_color", M3Theme.get_on_surface())
	add_theme_color_override("font_hover_pressed_color", M3Theme.get_on_surface())
	add_theme_color_override("font_focus_color", M3Theme.get_on_surface())
	add_theme_color_override("font_disabled_color", M3Theme.disabled_color(M3Theme.get_on_surface()))
	
	# Push text to the right of our custom checkbox (40dp touch target)
	add_theme_constant_override("h_separation", M3Units.dp(TOUCH_TARGET))

func _ready():
	clip_contents = false
	
	# Fixed size: touch target on both axes (bounds match touch target, never expand)
	var touch_px = M3Units.dp(TOUCH_TARGET)
	custom_minimum_size = Vector2(touch_px, touch_px)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	# Connect signals
	button_down.connect(func(): _pressed = true; queue_redraw())
	button_up.connect(func(): _pressed = false; queue_redraw())
	toggled.connect(func(_v): queue_redraw())
	mouse_entered.connect(func(): _hovered = true; queue_redraw())
	mouse_exited.connect(func(): _hovered = false; queue_redraw())
	
	_initialize_styleboxes()
	M3Tooltip.bind(self, m3_tooltip_text, m3_tooltip_variant)

func _exit_tree():
	M3Tooltip.unbind(self)

# ============================================
# DRAW
# ============================================

func _initialize_styleboxes():
	_cached_box_sb = StyleBoxFlat.new()
	_cached_box_sb.anti_aliasing = true
	_cached_box_sb.anti_aliasing_size = 1.0
	
	_cached_overlay_sb = StyleBoxFlat.new()
	_cached_overlay_sb.anti_aliasing = true
	_cached_overlay_sb.anti_aliasing_size = 1.0

func _draw():
	if not _cached_box_sb:
		_initialize_styleboxes()
	
	var is_checked = button_pressed
	var is_disabled = disabled
	
	# Calculate box rect (centered in touch target area on the left)
	var box_size_px = M3Units.dp(BOX_SIZE)
	var box_pos = Vector2(
		M3Units.dp((TOUCH_TARGET - BOX_SIZE) / 2.0),
		(size.y - box_size_px) / 2.0
	)
	var box_rect = Rect2(box_pos, Vector2(box_size_px, box_size_px))
	
	var box_center = box_rect.position + box_rect.size / 2.0
	
	# Draw hover/pressed overlay (40dp circle behind everything)
	if _hovered and not is_disabled:
		_draw_state_overlay(box_center, is_checked)
	
	# Draw focus ring if focused (40dp circle outline)
	if has_focus() and not is_disabled:
		_draw_focus_ring(box_center)
	
	# Draw box background and border
	_draw_box(box_rect, is_checked, is_disabled)
	
	# Draw checkmark or indeterminate line
	if is_checked:
		if indeterminate:
			_draw_indeterminate(box_rect, is_disabled)
		else:
			_draw_checkmark(box_rect, is_disabled)

func _draw_box(rect: Rect2, is_checked: bool, is_disabled: bool):
	var sb = _cached_box_sb
	sb.set_corner_radius_all(M3Units.dpi(CORNER_RADIUS))
	
	var alpha = 0.38 if is_disabled else 1.0
	
	if is_checked:
		var fill_color = M3Theme.get_error() if error else M3Theme.get_primary()
		fill_color.a *= alpha
		sb.bg_color = fill_color
		sb.set_border_width_all(0)
	else:
		var border_color = M3Theme.get_error() if error else M3Theme.get_outline()
		sb.bg_color = Color.TRANSPARENT
		border_color.a *= alpha
		sb.border_color = border_color
		sb.set_border_width_all(M3Units.dp(BORDER_WIDTH))
	
	draw_style_box(sb, rect)

func _draw_checkmark(rect: Rect2, is_disabled: bool):
	var check_color = M3Theme.get_on_primary()
	if error:
		check_color = M3Theme.get_on_error()
	
	if is_disabled:
		check_color.a *= 0.38
	var stroke = M3Units.dp(CHECK_STROKE)
	
	# Checkmark points within the box
	var p1 = rect.position + Vector2(rect.size.x * 0.22, rect.size.y * 0.55)
	var p2 = rect.position + Vector2(rect.size.x * 0.42, rect.size.y * 0.72)
	var p3 = rect.position + Vector2(rect.size.x * 0.78, rect.size.y * 0.28)
	
	draw_line(p1, p2, check_color, stroke, true)
	draw_line(p2, p3, check_color, stroke, true)

func _draw_indeterminate(rect: Rect2, is_disabled: bool):
	var line_color = M3Theme.get_on_primary()
	if error:
		line_color = M3Theme.get_on_error()
	
	if is_disabled:
		line_color.a *= 0.38
	var stroke = M3Units.dp(CHECK_STROKE)
	
	var start = rect.position + Vector2(rect.size.x * 0.22, rect.size.y * 0.5)
	var end = rect.position + Vector2(rect.size.x * 0.78, rect.size.y * 0.5)
	
	draw_line(start, end, line_color, stroke, true)

func _draw_focus_ring(center: Vector2):
	var radius = M3Units.dp(TOUCH_TARGET) / 2.0
	var color = M3Theme.get_on_surface()
	draw_arc(center, radius, 0, TAU, 64, color, M3Units.dp(1), true)

func _draw_state_overlay(center: Vector2, is_checked: bool):
	var radius = M3Units.dp(TOUCH_TARGET) / 2.0
	
	# M3 spec: hover overlay uses on-surface color at state layer opacity
	var overlay_color = M3Theme.get_on_surface()
	overlay_color.a = 0.12 if _pressed else 0.08
	
	var sb = _cached_overlay_sb
	sb.bg_color = overlay_color
	sb.set_corner_radius_all(int(radius))
	var rect = Rect2(center - Vector2(radius, radius), Vector2(radius * 2, radius * 2))
	draw_style_box(sb, rect)

# ============================================
# PUBLIC
# ============================================

func get_tooltip_anchor_rect() -> Rect2:
	# Return only the touch target area (40dp box), not the full expanded width
	# The checkbox box itself is the visual anchor for the tooltip
	var touch_px = M3Units.dp(TOUCH_TARGET)
	return Rect2(Vector2.ZERO, Vector2(touch_px, touch_px))

func refresh_theme():
	queue_redraw()
