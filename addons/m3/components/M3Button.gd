@tool
class_name M3Button
extends Button

# M3Units and M3Theme are global classes, no preload needed

## Material 3 Button Component
## Extends native Button with M3 sizing, shapes, and variants

enum Size { EXTRA_SMALL, SMALL, MEDIUM, LARGE, EXTRA_LARGE }
enum Shape { ROUNDED, PILL }
enum Type { NORMAL, TOGGLE }
enum Variant { ELEVATED, FILLED, TONAL, OUTLINED, TEXT }

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const SIZE_SPECS = {
	Size.EXTRA_SMALL: {
		"height": 32,
		"padding_h": 12,
		"icon_size": 20,
		"icon_gap": 4,
		"radius": 8,
		"font_size": 11,
	},
	Size.SMALL: {
		"height": 40,
		"padding_h": 16,
		"icon_size": 20,
		"icon_gap": 8,
		"radius": 8,
		"font_size": 12,
	},
	Size.MEDIUM: {
		"height": 56,
		"padding_h": 24,
		"icon_size": 24,
		"icon_gap": 8,
		"radius": 12,
		"font_size": 14,
	},
	Size.LARGE: {
		"height": 96,
		"padding_h": 48,
		"icon_size": 32,
		"icon_gap": 12,
		"radius": 16,
		"font_size": 16,
	},
	Size.EXTRA_LARGE: {
		"height": 136,
		"padding_h": 64,
		"icon_size": 40,
		"icon_gap": 16,
		"radius": 16,
		"font_size": 22,
	},
}

# ============================================
# EXPORTS
# ============================================

@export var button_variant: Variant = Variant.FILLED:
	set(value):
		if value == button_variant:
			return
		button_variant = value
		_update_theme()
		queue_redraw()

@export var button_size: Size = Size.MEDIUM:
	set(value):
		if value == button_size:
			return
		button_size = value
		_update_size()
		_update_theme()
		queue_redraw()

@export var button_shape: Shape = Shape.ROUNDED:
	set(value):
		if value == button_shape:
			return
		button_shape = value
		_update_theme()
		queue_redraw()

@export var button_type: Type = Type.NORMAL:
	set(value):
		if value == button_type:
			return
		button_type = value
		toggle_mode = (button_type == Type.TOGGLE)
		_update_theme()
		queue_redraw()

@export var icon_name: String = "":
	set(value):
		if value == icon_name:
			return
		icon_name = value
		_update_icon()
		# _update_theme() is called by _update_icon() if visibility changes

@export var m3_tooltip_text: String = ""
@export var m3_tooltip_variant: M3Tooltip.Variant = M3Tooltip.Variant.PLAIN

# ============================================
# INTERNAL
# ============================================

var _icon_node: FontIcon
var _is_pressing: bool = false
var _menu_active: bool = false

# Cached StyleBoxFlat instances (allocated once, mutated per state)
var _cached_style_normal: StyleBoxFlat
var _cached_style_hover: StyleBoxFlat
var _cached_style_pressed: StyleBoxFlat
var _cached_style_disabled: StyleBoxFlat
var _cached_style_focus: StyleBoxFlat
var _cached_style_hover_pressed: StyleBoxFlat

# Cached variant colors (invalidated when variant/type/disabled change)
var _cached_colors_hash: int = -1
var _cached_colors_normal: Dictionary = {}
var _cached_colors_selected: Dictionary = {}
var _cached_pad_h_px: int = 0
var _cached_icon_size_px: int = 0

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_initialize_caches()
	_create_icon()
	_update_icon()  # Set icon visibility first
	size_flags_vertical = 0  # Don't expand vertically in containers
	_update_size()
	_initialize_theme_overrides()
	_update_theme()  # Then configure styleboxes with correct visibility
	# Position icon once layout is stable
	call_deferred("_update_icon_position")
	# Connect signals
	if not toggled.is_connected(_on_toggled):
		toggled.connect(_on_toggled)
	if not button_down.is_connected(_on_button_down):
		button_down.connect(_on_button_down)
	if not button_up.is_connected(_on_button_up):
		button_up.connect(_on_button_up)
	
	# Setup tooltip
	M3Tooltip.bind(self, m3_tooltip_text, m3_tooltip_variant)

func _exit_tree():
	M3Tooltip.unbind(self)

func _on_button_down():
	_is_pressing = true
	_update_colors()
	queue_redraw()

func _on_button_up():
	_is_pressing = false
	_update_colors()
	queue_redraw()

func set_menu_active(active: bool):
	_menu_active = active
	_update_theme()
	_update_colors()
	queue_redraw()

func _initialize_caches():
	_cached_style_normal = StyleBoxFlat.new()
	_cached_style_hover = StyleBoxFlat.new()
	_cached_style_pressed = StyleBoxFlat.new()
	_cached_style_disabled = StyleBoxFlat.new()
	_cached_style_focus = StyleBoxFlat.new()
	_cached_style_hover_pressed = StyleBoxFlat.new()
	for sb in [_cached_style_normal, _cached_style_hover, _cached_style_pressed, _cached_style_disabled, _cached_style_focus, _cached_style_hover_pressed]:
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 1.0

func _initialize_theme_overrides():
	# Apply theme overrides once; subsequent _update_theme() calls only mutate the cached objects
	add_theme_stylebox_override("normal", _cached_style_normal)
	add_theme_stylebox_override("hover", _cached_style_hover)
	add_theme_stylebox_override("pressed", _cached_style_pressed)
	add_theme_stylebox_override("disabled", _cached_style_disabled)
	add_theme_stylebox_override("focus", _cached_style_focus)
	add_theme_stylebox_override("hover_pressed", _cached_style_hover_pressed)
	add_theme_stylebox_override("normal_mirrored", _cached_style_normal)
	add_theme_stylebox_override("hover_mirrored", _cached_style_hover)
	add_theme_stylebox_override("pressed_mirrored", _cached_style_pressed)
	add_theme_stylebox_override("hover_pressed_mirrored", _cached_style_hover_pressed)

func _create_icon():
	if is_instance_valid(_icon_node):
		return
	_icon_node = FontIcon.new()
	_icon_node.visible = false
	_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Prevent 0-size font caching errors by setting minimum font size before any rendering
	_icon_node.add_theme_font_size_override("font_size", 1)
	_icon_node.icon_settings = FontIconSettings.new()
	_icon_node.icon_settings.icon_size = 1.0
	_icon_node.icon_settings.outline_color = Color.TRANSPARENT
	_icon_node.icon_settings.shadow_color = Color.TRANSPARENT
	add_child(_icon_node)

func _get_size_spec() -> Dictionary:
	return SIZE_SPECS[button_size]

func _update_size():
	if not _cached_style_normal:
		return
	var spec = _get_size_spec()
	var height_px = M3Units.dp(spec["height"])
	_cached_icon_size_px = max(1.0, M3Units.dp(spec["icon_size"]))
	_cached_pad_h_px = M3Units.dp(spec["padding_h"])
	custom_minimum_size = Vector2(custom_minimum_size.x, height_px)
	if _icon_node:
		_icon_node.icon_settings.icon_size = _cached_icon_size_px
		# Force icon node to exact icon_size so glyph is centered within fixed bounds
		_icon_node.custom_minimum_size = Vector2(_cached_icon_size_px, _cached_icon_size_px)
		_icon_node.size = Vector2(_cached_icon_size_px, _cached_icon_size_px)

func _update_icon():
	if not _icon_node:
		return
	
	var was_visible = _icon_node.visible
	if icon_name:
		_icon_node.icon_settings.icon_name = icon_name
		_icon_node.visible = true
	else:
		_icon_node.visible = false
	
	# Trigger theme update when icon visibility changes (affects content margins)
	if was_visible != _icon_node.visible:
		_update_theme()

func _on_toggled(_pressed: bool):
	_update_colors()
	queue_redraw()

func _get_variant_colors(selected: bool) -> Dictionary:
	"""Get cached colors for a variant in either selected (on) or unselected (off) toggle state."""
	var state: int = (button_variant << 3) | (button_type << 1) | int(disabled)
	if _cached_colors_hash != state:
		_cached_colors_hash = state
		_cached_colors_normal = _compute_variant_colors(false)
		_cached_colors_selected = _compute_variant_colors(true)
	return _cached_colors_selected if selected else _cached_colors_normal

func _compute_variant_colors(selected: bool) -> Dictionary:
	"""Compute colors for a variant (uncached)."""
	var result = {}
	
	match button_variant:
		Variant.ELEVATED:
			if selected:
				result.bg = M3Theme.get_primary()
				result.text = M3Theme.get_on_primary()
			else:
				result.bg = M3Theme.get_surface_container_low()
				result.text = M3Theme.get_primary()
			result.hover_bg = M3Theme.state_overlay(result.bg, result.text, M3Theme.OPACITY_HOVER)
			result.pressed_bg = M3Theme.state_overlay(result.bg, result.text, M3Theme.OPACITY_PRESSED)
			result.disabled_bg = Color(M3Theme.get_surface().r, M3Theme.get_surface().g, M3Theme.get_surface().b, M3Theme.OPACITY_DISABLED)
			result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
			result.focus_border = result.text
			result.border_c = Color.TRANSPARENT
			result.border_w = 0
		Variant.FILLED:
			if selected:
				result.bg = M3Theme.get_primary()
				result.text = M3Theme.get_on_primary()
			else:
				result.bg = M3Theme.get_primary_container()
				result.text = M3Theme.get_on_primary_container()
			result.hover_bg = M3Theme.state_overlay(result.bg, result.text, M3Theme.OPACITY_HOVER)
			result.pressed_bg = M3Theme.state_overlay(result.bg, result.text, M3Theme.OPACITY_PRESSED)
			result.disabled_bg = M3Theme.disabled_color(M3Theme.get_on_surface_variant())
			result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
			result.focus_border = result.text
			result.border_c = Color.TRANSPARENT
			result.border_w = 0
		Variant.TONAL:
			if selected:
				result.bg = M3Theme.get_secondary()
				result.text = M3Theme.get_on_secondary()
			else:
				result.bg = M3Theme.get_secondary_container()
				result.text = M3Theme.get_on_secondary_container()
			result.hover_bg = M3Theme.state_overlay(result.bg, result.text, M3Theme.OPACITY_HOVER)
			result.pressed_bg = M3Theme.state_overlay(result.bg, result.text, M3Theme.OPACITY_PRESSED)
			result.disabled_bg = M3Theme.disabled_color(M3Theme.get_on_surface_variant())
			result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
			result.focus_border = result.text
			result.border_c = Color.TRANSPARENT
			result.border_w = 0
		Variant.OUTLINED:
			if selected:
				result.bg = M3Theme.get_inverse_surface()
				result.text = M3Theme.get_inverse_on_surface()
				result.border_c = Color.TRANSPARENT
				# Hover/press overlays on the actual selected bg (inverse_surface)
				result.hover_bg = M3Theme.state_overlay(M3Theme.get_inverse_surface(), result.text, M3Theme.OPACITY_HOVER)
				result.pressed_bg = M3Theme.state_overlay(M3Theme.get_inverse_surface(), result.text, M3Theme.OPACITY_PRESSED)
			else:
				result.bg = Color.TRANSPARENT
				result.text = M3Theme.get_on_surface_variant()
				result.border_c = M3Theme.get_outline_variant()
				# Hover/press overlays on surface for unselected
				result.hover_bg = M3Theme.state_overlay(M3Theme.get_surface(), result.text, M3Theme.OPACITY_HOVER)
				result.pressed_bg = M3Theme.state_overlay(M3Theme.get_surface(), result.text, M3Theme.OPACITY_PRESSED)
			result.disabled_bg = Color.TRANSPARENT
			result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
			result.focus_border = result.text
			result.border_w = 1
		Variant.TEXT:
			if selected:
				result.bg = M3Theme.get_primary_container()
				result.text = M3Theme.get_on_primary_container()
				# Hover/press overlays on the actual selected bg (primary_container)
				result.hover_bg = M3Theme.state_overlay(M3Theme.get_primary_container(), result.text, M3Theme.OPACITY_HOVER)
				result.pressed_bg = M3Theme.state_overlay(M3Theme.get_primary_container(), result.text, M3Theme.OPACITY_PRESSED)
			else:
				result.bg = Color.TRANSPARENT
				result.text = M3Theme.get_on_surface_variant()
				# Hover/press overlays on surface for unselected
				result.hover_bg = M3Theme.state_overlay(M3Theme.get_surface(), result.text, M3Theme.OPACITY_HOVER)
				result.pressed_bg = M3Theme.state_overlay(M3Theme.get_surface(), result.text, M3Theme.OPACITY_PRESSED)
			result.disabled_bg = Color.TRANSPARENT
			result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
			result.focus_border = result.text
			result.border_c = Color.TRANSPARENT
			result.border_w = 0
	
	return result

func _update_theme():
	if not _cached_style_normal:
		return
	var spec = _get_size_spec()
	var radius = _get_radius()
	var pad_h = M3Units.dp(spec["padding_h"])
	var font_size = M3Units.dp(spec["font_size"])
	
	# Determine colors based on variant and toggle state
	var colors: Dictionary
	var selected_colors: Dictionary
	
	if button_type == Type.TOGGLE:
		colors = _get_variant_colors(false)  # Unselected (normal) colors
		selected_colors = _get_variant_colors(true)  # Selected (pressed) colors
	else:
		colors = _get_variant_colors(false)
		selected_colors = colors  # Same for normal buttons
	
	var bg: Color = colors.bg
	var text: Color = colors.text
	var hover_bg: Color = colors.hover_bg
	var pressed_bg: Color = colors.pressed_bg
	var disabled_bg: Color = colors.disabled_bg
	var disabled_text: Color = colors.disabled_text
	var focus_border: Color = colors.focus_border
	var border_c: Color = colors.border_c
	var border_w: int = colors.border_w
	
	var icon_gap = M3Units.dp(spec["icon_gap"])
	var has_icon = _icon_node and _icon_node.visible
	
	var sel_bg: Color = selected_colors.bg
	var sel_text: Color = selected_colors.text
	var sel_hover_bg: Color = selected_colors.hover_bg
	var sel_pressed_bg: Color = selected_colors.pressed_bg
	
	# Shadow for elevated variant
	var shadow_size: int = 0
	var shadow_off: Vector2 = Vector2.ZERO
	var shadow_col: Color = Color.TRANSPARENT
	if button_variant == Variant.ELEVATED:
		shadow_size = M3Theme.ELEVATION_1["size"]
		shadow_off = M3Theme.ELEVATION_1["offset"]
		shadow_col = M3Theme.ELEVATION_1["color"]
	
	# Menu active override: show pressed state on normal/hover/focus
	var display_bg = pressed_bg if _menu_active else bg
	var display_hover = pressed_bg if _menu_active else hover_bg
	var display_focus = pressed_bg if _menu_active else bg
	
	# Normal state
	_configure_stylebox(_cached_style_normal, display_bg, radius, pad_h, icon_gap, has_icon, border_w, border_c, shadow_size, shadow_off, shadow_col)
	
	# Hover state
	_configure_stylebox(_cached_style_hover, display_hover, radius, pad_h, icon_gap, has_icon, border_w, border_c, shadow_size, shadow_off, shadow_col)
	
	# Pressed state (shadow drops on press; always 0 for pressed state)
	_configure_stylebox(_cached_style_pressed, pressed_bg, radius, pad_h, icon_gap, has_icon, border_w, border_c, 0, shadow_off, shadow_col)
	
	# Disabled state
	_configure_stylebox(_cached_style_disabled, disabled_bg, radius, pad_h, icon_gap, has_icon, border_w, border_c)
	
	# Focus state
	_configure_stylebox(_cached_style_focus, display_focus, radius, pad_h, icon_gap, has_icon, 3, focus_border)
	
	# Hover pressed state (checked hover for toggles)
	if button_type == Type.TOGGLE:
		var sel_border_w = selected_colors.border_w
		var sel_border_c = selected_colors.border_c
		_configure_stylebox(_cached_style_hover_pressed, sel_hover_bg, radius, pad_h, icon_gap, has_icon, sel_border_w, sel_border_c, shadow_size, shadow_off, shadow_col)
		# Override pressed with selected colors for toggle mode
		_configure_stylebox(_cached_style_pressed, sel_bg, radius, pad_h, icon_gap, has_icon, sel_border_w, sel_border_c, 0, shadow_off, shadow_col)
	
	# Text colors - for toggles, compute the *visual target* color so text and icon
	# flip immediately on press (before button_pressed changes on release).
	# XOR: pressing an unselected button -> selected; pressing a selected button -> unselected.
	var current_text: Color
	if disabled:
		current_text = disabled_text
	elif _menu_active:
		# Menu open: show pressed/selected state
		current_text = sel_text
	elif button_type == Type.TOGGLE:
		var target_selected: bool = button_pressed != _is_pressing
		current_text = sel_text if target_selected else text
	else:
		current_text = text
	
	add_theme_color_override("font_color", current_text)
	add_theme_color_override("font_hover_color", current_text)
	add_theme_color_override("font_pressed_color", current_text)
	add_theme_color_override("font_hover_pressed_color", current_text)
	add_theme_color_override("font_focus_color", current_text)
	add_theme_color_override("font_disabled_color", disabled_text)
	
	# Font
	var fonts = M3Theme.load_fonts()
	add_theme_font_override("font", fonts["medium"])
	add_theme_font_size_override("font_size", font_size)
	
	# Text alignment
	alignment = _get_text_alignment()
	
	# Sync icon color to match text color (pass cached colors to avoid recomputation)
	_update_icon_color(colors, selected_colors)

func _configure_stylebox(style: StyleBoxFlat, bg: Color, radius: int, pad_h: int, icon_gap: int = -1, has_icon: bool = false, border_w: int = 0, border_c: Color = Color.TRANSPARENT, shadow_size: int = 0, shadow_off: Vector2 = Vector2.ZERO, shadow_col: Color = Color.TRANSPARENT):
	if not style:
		return
	
	style.bg_color = bg
	if _custom_corner_radii.is_empty():
		style.set_corner_radius_all(radius)
	else:
		style.corner_radius_top_left = _custom_corner_radii[0]
		style.corner_radius_top_right = _custom_corner_radii[1]
		style.corner_radius_bottom_left = _custom_corner_radii[2]
		style.corner_radius_bottom_right = _custom_corner_radii[3]
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	style.shadow_size = shadow_size
	style.shadow_offset = shadow_off
	style.shadow_color = shadow_col
	
	if has_icon:
		# Icon area is exactly icon_size wide, glyph centered within
		style.content_margin_left = pad_h + _cached_icon_size_px + icon_gap
		style.content_margin_right = pad_h
	else:
		style.content_margin_left = pad_h
		style.content_margin_right = pad_h
	
	if border_w > 0:
		style.border_color = border_c
		style.set_border_width_all(border_w)
	else:
		style.set_border_width_all(0)

func _get_radius(spec: Dictionary = _get_size_spec()) -> int:
	if button_shape == Shape.PILL:
		return int(M3Units.dp(spec["height"]) / 2.0)
	return M3Units.dp(spec["radius"])

func _get_text_alignment() -> HorizontalAlignment:
	if _icon_node and _icon_node.visible:
		return HORIZONTAL_ALIGNMENT_LEFT
	else:
		return HORIZONTAL_ALIGNMENT_CENTER

func _update_colors():
	"""Update only color overrides without rebuilding styleboxes.
	Called on press/release for performance."""
	var colors = _get_variant_colors(false)
	var selected_colors = _get_variant_colors(true)
	
	var current_text: Color
	var disabled_text: Color
	if disabled:
		current_text = colors.disabled_text
		disabled_text = colors.disabled_text
	elif button_type == Type.TOGGLE:
		var target_selected = button_pressed != _is_pressing
		current_text = selected_colors.text if target_selected else colors.text
		disabled_text = selected_colors.disabled_text
	else:
		current_text = colors.text
		disabled_text = colors.disabled_text
	
	add_theme_color_override("font_color", current_text)
	add_theme_color_override("font_hover_color", current_text)
	add_theme_color_override("font_pressed_color", current_text)
	add_theme_color_override("font_hover_pressed_color", current_text)
	add_theme_color_override("font_focus_color", current_text)
	add_theme_color_override("font_disabled_color", disabled_text)
	
	_update_icon_color(colors, selected_colors)

func refresh_theme():
	"""Refresh theme when dark mode changes. Called by parent."""
	_cached_colors_hash = -1
	_update_theme()

func _update_icon_color(colors: Dictionary = {}, selected_colors: Dictionary = {}):
	if not _icon_node or not _icon_node.visible:
		return
	
	# Use cached colors if provided (avoids redundant _get_variant_colors calls)
	if colors.is_empty():
		colors = _get_variant_colors(false)
	if selected_colors.is_empty():
		selected_colors = _get_variant_colors(true)
	
	var current_text: Color
	if disabled:
		current_text = colors.disabled_text
	elif button_type == Type.TOGGLE:
		var target_selected: bool = button_pressed != _is_pressing
		current_text = selected_colors.text if target_selected else colors.text
	else:
		current_text = colors.text
	
	if _icon_node.icon_settings.icon_color != current_text:
		_icon_node.icon_settings.icon_color = current_text
		# FontIconSettings.icon_color setter emits changed signal;
		# FontIcon auto-updates via that signal. No direct call needed.

func _notification(what: int):
	if what == NOTIFICATION_RESIZED:
		_update_icon_position()

func _update_icon_position():
	if not _icon_node or not _icon_node.visible:
		return
	
	var icon_x: float
	if text.is_empty():
		# Center icon horizontally when no text
		icon_x = size.x / 2.0 - _cached_icon_size_px / 2.0
	else:
		icon_x = _cached_pad_h_px
	
	_icon_node.position = Vector2(
		icon_x,
		size.y / 2.0 - _cached_icon_size_px / 2.0
	)

var _custom_corner_radii: Array[int] = []

func set_corner_radii(tl: int, tr: int, bl: int, br: int) -> void:
	"""Override corner radii on all cached styleboxes and future updates."""
	_custom_corner_radii = [tl, tr, bl, br]
	for sb in [_cached_style_normal, _cached_style_hover, _cached_style_pressed, _cached_style_disabled, _cached_style_focus, _cached_style_hover_pressed]:
		if sb:
			sb.corner_radius_top_left = tl
			sb.corner_radius_top_right = tr
			sb.corner_radius_bottom_left = bl
			sb.corner_radius_bottom_right = br
	queue_redraw()
