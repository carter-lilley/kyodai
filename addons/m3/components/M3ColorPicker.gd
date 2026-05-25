@tool
class_name M3ColorPicker
extends M3Button

## Material 3 Color Picker Component
## A styled color swatch button that opens a ColorPicker popup.
## Drop-in replacement for ColorPickerButton with M3 styling.

# ============================================
# EXPORTS
# ============================================

@export var color: Color = Color.WHITE:
	set(value):
		if value == color:
			return
		color = value
		_update_theme()
		queue_redraw()
		if _picker and not _updating_from_picker:
			_updating_from_picker = true
			_picker.color = value
			_updating_from_picker = false

@export var edit_alpha: bool = true:
	set(value):
		if value == edit_alpha:
			return
		edit_alpha = value
		if _picker:
			_picker.edit_alpha = value

# ============================================
# SIGNALS
# ============================================

signal color_changed(color: Color)
signal popup_closed()

# ============================================
# INTERNAL
# ============================================

var _popup: PopupPanel
var _picker: ColorPicker
var _updating_from_picker: bool = false

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	super._ready()
	text = ""
	alignment = HORIZONTAL_ALIGNMENT_CENTER
	size_flags_horizontal = 0
	size_flags_vertical = 0
	custom_minimum_size = Vector2(M3Units.dp(80), M3Units.dp(40))
	
	if not pressed.is_connected(_on_pressed):
		pressed.connect(_on_pressed)

func _exit_tree():
	if _popup:
		_popup.queue_free()

# ============================================
# OVERRIDE SIZE & ICON
# ============================================

func _update_size():
	if not _cached_style_normal:
		return
	_cached_icon_size_px = 0
	_cached_pad_h_px = 0
	custom_minimum_size = Vector2(M3Units.dp(80), M3Units.dp(40))

func _update_icon():
	# Hide icon entirely
	if _icon_node:
		_icon_node.visible = false

# ============================================
# COLOR & THEME OVERRIDES
# ============================================

func _compute_variant_colors(_selected: bool) -> Dictionary:
	var result = {}
	result.bg = color
	result.text = M3Theme.get_on_surface()
	result.hover_bg = M3Theme.state_overlay(color, M3Theme.get_on_surface(), M3Theme.OPACITY_HOVER)
	result.pressed_bg = M3Theme.state_overlay(color, M3Theme.get_on_surface(), M3Theme.OPACITY_PRESSED)
	result.disabled_bg = M3Theme.disabled_color(color)
	result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
	result.focus_border = M3Theme.get_primary()
	result.border_c = M3Theme.get_outline()
	result.border_w = 1
	return result

func _get_variant_colors(_selected: bool) -> Dictionary:
	return _compute_variant_colors(false)

func _update_theme():
	if not _cached_style_normal:
		return
	
	var radius = M3Units.dp(8)
	var colors = _compute_variant_colors(false)
	
	var bg: Color = colors.bg
	var hover_bg: Color = colors.hover_bg
	var pressed_bg: Color = colors.pressed_bg
	var disabled_bg: Color = colors.disabled_bg
	var focus_border: Color = colors.focus_border
	var border_c: Color = colors.border_c
	var border_w: int = colors.border_w
	
	# Normal state
	_configure_stylebox(_cached_style_normal, bg, radius, 0, 0, false, border_w, border_c)
	
	# Hover state
	_configure_stylebox(_cached_style_hover, hover_bg, radius, 0, 0, false, border_w, border_c)
	
	# Pressed state
	_configure_stylebox(_cached_style_pressed, pressed_bg, radius, 0, 0, false, border_w, border_c)
	
	# Disabled state
	_configure_stylebox(_cached_style_disabled, disabled_bg, radius, 0, 0, false, border_w, border_c)
	
	# Focus state
	_configure_stylebox(_cached_style_focus, bg, radius, 0, 0, false, 3, focus_border)
	
	# Hide text colors (no text in color picker)
	add_theme_color_override("font_color", Color.TRANSPARENT)
	add_theme_color_override("font_hover_color", Color.TRANSPARENT)
	add_theme_color_override("font_pressed_color", Color.TRANSPARENT)
	add_theme_color_override("font_focus_color", Color.TRANSPARENT)
	add_theme_color_override("font_disabled_color", Color.TRANSPARENT)
	
	add_theme_font_size_override("font_size", 1)

func _configure_stylebox(style: StyleBoxFlat, bg: Color, radius: int, pad_h: int, icon_gap: int = -1, has_icon: bool = false, border_w: int = 0, border_c: Color = Color.TRANSPARENT, shadow_size: int = 0, shadow_off: Vector2 = Vector2.ZERO, shadow_col: Color = Color.TRANSPARENT):
	if not style:
		return
	style.bg_color = bg
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(0)
	style.shadow_size = shadow_size
	style.shadow_offset = shadow_off
	style.shadow_color = shadow_col
	if border_w > 0:
		style.border_color = border_c
		style.set_border_width_all(border_w)
	else:
		style.set_border_width_all(0)

func _update_colors():
	# No text/icon colors to update for color-only button
	pass

func refresh_theme():
	_update_theme()

# ============================================
# POPUP MANAGEMENT
# ============================================

func _on_pressed():
	_show_popup()

func _show_popup():
	if disabled:
		return
	
	if not _popup:
		_create_popup()
	
	var popup_pos = Vector2i(
		int(global_position.x),
		int(global_position.y + size.y + M3Units.dp(4))
	)
	
	# Adjust if going off screen
	var viewport_rect = get_viewport_rect()
	var popup_size = _popup.get_contents_minimum_size()
	
	if popup_pos.x + popup_size.x > viewport_rect.size.x:
		popup_pos.x = int(viewport_rect.size.x - popup_size.x)
	if popup_pos.y + popup_size.y > viewport_rect.size.y:
		popup_pos.y = int(global_position.y - popup_size.y - M3Units.dp(4))
	
	_popup.popup(Rect2i(popup_pos, Vector2i(0, 0)))

func _create_popup():
	_popup = PopupPanel.new()
	
	_picker = ColorPicker.new()
	_picker.color = color
	_picker.edit_alpha = edit_alpha
	_picker.color_changed.connect(_on_picker_color_changed)
	
	_popup.add_child(_picker)
	_popup.popup_hide.connect(_on_popup_closed)
	add_child(_popup)

func _on_picker_color_changed(new_color: Color):
	if _updating_from_picker:
		return
	if new_color != color:
		color = new_color
		color_changed.emit(new_color)

func _on_popup_closed():
	popup_closed.emit()
