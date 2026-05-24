@tool
class_name M3Chip
extends M3Button

## Material 3 Chip Component
## Compact action/filter/input elements.
## Extends M3Button with chip-specific sizing, variants, and multi-icon support.

enum ChipVariant { ASSIST, FILTER, INPUT, SUGGESTION }

# ============================================
# CHIP SPECS (single size, all in dp)
# ============================================

const CHIP_SPEC = {
	"height": 32,
	"padding_h": 12,
	"icon_size": 18,
	"icon_gap": 4,
	"radius": 8,
	"font_size": 12,
}

# ============================================
# EXPORTS
# ============================================

@export var chip_variant: ChipVariant = ChipVariant.SUGGESTION:
	set(value):
		if value == chip_variant:
			return
		chip_variant = value
		# Auto-configure checkable for FILTER chips
		# button_type setter handles _update_theme() and queue_redraw()
		if chip_variant == ChipVariant.FILTER:
			button_type = Type.TOGGLE
		elif button_type == Type.TOGGLE:
			button_type = Type.NORMAL
		_update_focus_connections()

@export var checked: bool = false:
	get:
		return button_pressed
	set(value):
		if value == button_pressed:
			return
		# button_pressed emits toggled signal → _on_toggled() handles theme update
		button_pressed = value

@export var elevated: bool = false:
	set(value):
		if value == elevated:
			return
		elevated = value
		_update_theme()

@export var leading_icon: String = "":
	set(value):
		if value == leading_icon:
			return
		leading_icon = value
		# icon_name setter handles _update_icon() and _update_theme()
		icon_name = value  # sync with parent

@export var close_icon_name: String = "close":
	set(value):
		if value == close_icon_name:
			return
		close_icon_name = value
		_update_close_icon()

@export var checked_icon_name: String = "check":
	set(value):
		if value == checked_icon_name:
			return
		checked_icon_name = value
		_update_checked_icon()

## Trailing icon shown on the right side (FILTER chips only). Clicking it emits menu_requested.
@export var trailing_icon: String = "":
	set(value):
		if value == trailing_icon:
			return
		trailing_icon = value
		_update_trailing_icon()
		_update_focus_connections()
		_update_theme()

# ============================================
# SIGNALS
# ============================================

signal checked_changed(is_checked: bool)
signal close_requested()
signal menu_requested()

# ============================================
# INTERNAL
# ============================================

var _checked_icon_node: FontIcon
var _close_icon_node: FontIcon
var _trailing_icon_node: FontIcon
var _close_pressing: bool = false
var _trailing_pressing: bool = false

# Menu auto-open (FILTER chips with trailing_icon only)
var _menu_open_timer: SceneTreeTimer = null
var _menu_auto_open_delay: float = 0.15  # 150ms
var _menu_opened_this_session: bool = false  # Track whether menu was opened during current focus session
var _just_opened_menu: bool = false  # Set when we emit menu_requested so focus_exited knows not to reset the session

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	super._ready()
	_create_checked_icon()
	_create_close_icon()
	_create_trailing_icon()
	_update_checked_icon()
	_update_close_icon()
	_update_trailing_icon()
	call_deferred("_update_icon_positions")
	
	_update_focus_connections()

func _exit_tree():
	# Clean up SceneTreeTimer if node is removed while timer is running
	if _menu_open_timer != null and _menu_open_timer.timeout.is_connected(_open_menu):
		_menu_open_timer.timeout.disconnect(_open_menu)
		_menu_open_timer = null
	super._exit_tree()

func _update_focus_connections():
	var should_connect = (chip_variant == ChipVariant.FILTER and not trailing_icon.is_empty())
	var has_focus_entered = focus_entered.is_connected(_on_focus_entered)
	
	if should_connect and not has_focus_entered:
		focus_entered.connect(_on_focus_entered)
		focus_exited.connect(_on_focus_exited)
	elif not should_connect and has_focus_entered:
		focus_entered.disconnect(_on_focus_entered)
		focus_exited.disconnect(_on_focus_exited)
		# Clean up any pending timer
		if _menu_open_timer != null:
			if _menu_open_timer.timeout.is_connected(_open_menu):
				_menu_open_timer.timeout.disconnect(_open_menu)
			_menu_open_timer = null

func _create_checked_icon():
	_checked_icon_node = FontIcon.new()
	_checked_icon_node.visible = false
	_checked_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_checked_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_checked_icon_node.add_theme_font_size_override("font_size", 1)
	_checked_icon_node.icon_settings = FontIconSettings.new()
	_checked_icon_node.icon_settings.icon_size = 1.0
	_checked_icon_node.icon_settings.outline_color = Color.TRANSPARENT
	_checked_icon_node.icon_settings.shadow_color = Color.TRANSPARENT
	add_child(_checked_icon_node)

func _create_close_icon():
	_close_icon_node = FontIcon.new()
	_close_icon_node.visible = false
	_close_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_close_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_close_icon_node.add_theme_font_size_override("font_size", 1)
	_close_icon_node.icon_settings = FontIconSettings.new()
	_close_icon_node.icon_settings.icon_size = 1.0
	_close_icon_node.icon_settings.outline_color = Color.TRANSPARENT
	_close_icon_node.icon_settings.shadow_color = Color.TRANSPARENT
	_close_icon_node.mouse_filter = Control.MOUSE_FILTER_PASS
	_close_icon_node.gui_input.connect(_on_close_icon_input)
	add_child(_close_icon_node)

func _create_trailing_icon():
	_trailing_icon_node = FontIcon.new()
	_trailing_icon_node.visible = false
	_trailing_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_trailing_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_trailing_icon_node.add_theme_font_size_override("font_size", 1)
	_trailing_icon_node.icon_settings = FontIconSettings.new()
	_trailing_icon_node.icon_settings.icon_size = 1.0
	_trailing_icon_node.icon_settings.outline_color = Color.TRANSPARENT
	_trailing_icon_node.icon_settings.shadow_color = Color.TRANSPARENT
	_trailing_icon_node.mouse_filter = Control.MOUSE_FILTER_PASS
	_trailing_icon_node.gui_input.connect(_on_trailing_icon_input)
	add_child(_trailing_icon_node)

func _on_focus_entered():
	if _menu_opened_this_session:
		return
	if chip_variant == ChipVariant.FILTER and not trailing_icon.is_empty():
		# Start timer to auto-open menu after delay
		_menu_open_timer = get_tree().create_timer(_menu_auto_open_delay)
		_menu_open_timer.timeout.connect(_open_menu)

func _on_focus_exited():
	# Cancel pending menu open
	if _menu_open_timer != null:
		if _menu_open_timer.timeout.is_connected(_open_menu):
			_menu_open_timer.timeout.disconnect(_open_menu)
		_menu_open_timer = null
		_menu_opened_this_session = false
		return
	
	# If we just opened a menu, focus moved into it — don't reset session
	if _just_opened_menu:
		_just_opened_menu = false
		return
	
	# User navigated away to another control — reset session
	_menu_opened_this_session = false

func _open_menu():
	_menu_open_timer = null
	if not has_focus():
		return
	_menu_opened_this_session = true
	_just_opened_menu = true
	menu_requested.emit()

func _on_trailing_icon_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_trailing_pressing = true
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _trailing_pressing:
			_trailing_pressing = false
			menu_requested.emit()
			get_viewport().set_input_as_handled()

func _on_close_icon_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_close_pressing = true
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _close_pressing:
			_close_pressing = false
			close_requested.emit()
			get_viewport().set_input_as_handled()

# ============================================
# OVERRIDES
# ============================================

func _get_size_spec() -> Dictionary:
	return CHIP_SPEC

func _compute_variant_colors(_selected: bool) -> Dictionary:
	var result = {}
	
	match chip_variant:
		ChipVariant.ASSIST:
			result.bg = Color.TRANSPARENT
			result.text = M3Theme.get_on_surface_variant()
			result.border_c = M3Theme.get_outline()
			result.border_w = 1
		
		ChipVariant.FILTER:
			if _selected or button_pressed:
				result.bg = M3Theme.get_secondary_container()
				result.text = M3Theme.get_on_secondary_container()
				result.border_c = Color.TRANSPARENT
				result.border_w = 0
			else:
				result.bg = Color.TRANSPARENT
				result.text = M3Theme.get_on_surface_variant()
				result.border_c = M3Theme.get_outline()
				result.border_w = 1
		
		ChipVariant.INPUT:
			result.bg = Color.TRANSPARENT
			result.text = M3Theme.get_on_surface_variant()
			result.border_c = M3Theme.get_outline()
			result.border_w = 1
		
		ChipVariant.SUGGESTION:
			if elevated:
				result.bg = M3Theme.get_surface_container_low()
				result.text = M3Theme.get_on_surface_variant()
				result.border_c = Color.TRANSPARENT
				result.border_w = 0
			else:
				result.bg = Color.TRANSPARENT
				result.text = M3Theme.get_on_surface_variant()
				result.border_c = M3Theme.get_outline()
				result.border_w = 1
	
	# Common properties for all variants
	result.hover_bg = M3Theme.state_overlay(M3Theme.get_surface(), result.text, M3Theme.OPACITY_HOVER)
	result.pressed_bg = M3Theme.state_overlay(M3Theme.get_surface(), result.text, M3Theme.OPACITY_PRESSED)
	result.disabled_bg = Color.TRANSPARENT
	result.disabled_text = M3Theme.disabled_color(M3Theme.get_on_surface())
	result.focus_border = result.text
	
	return result

func _get_variant_colors(selected: bool) -> Dictionary:
	var state = hash([chip_variant, button_type, disabled, elevated])
	if _cached_colors_hash != state:
		_cached_colors_hash = state
		_cached_colors_normal = _compute_variant_colors(false)
		_cached_colors_selected = _compute_variant_colors(true)
	return _cached_colors_selected if selected else _cached_colors_normal

func _update_theme():
	if not _cached_style_normal:
		return
	
	var spec = _get_size_spec()
	var radius = M3Units.dp(spec["radius"])
	var pad_h = M3Units.dp(spec["padding_h"])
	var font_size = M3Units.dp(spec["font_size"])
	
	var colors = _get_variant_colors(false)
	
	var bg: Color = colors.bg
	var text: Color = colors.text
	var hover_bg: Color = colors.hover_bg
	var pressed_bg: Color = colors.pressed_bg
	var disabled_bg: Color = colors.disabled_bg
	var disabled_text: Color = colors.disabled_text
	var focus_border: Color = colors.focus_border
	var border_c: Color = colors.border_c
	var border_w: int = colors.border_w
	
	var shadow_size: int = 0
	var shadow_off: Vector2 = Vector2.ZERO
	var shadow_col: Color = Color.TRANSPARENT
	if elevated and chip_variant == ChipVariant.SUGGESTION:
		shadow_size = M3Theme.ELEVATION_1["size"]
		shadow_off = M3Theme.ELEVATION_1["offset"]
		shadow_col = M3Theme.ELEVATION_1["color"]
	
	var margins = _compute_content_margins(pad_h)
	
	_configure_chip_stylebox(_cached_style_normal, bg, radius, margins.left, margins.right, border_w, border_c, shadow_size, shadow_off, shadow_col)
	
	_configure_chip_stylebox(_cached_style_hover, hover_bg, radius, margins.left, margins.right, border_w, border_c, shadow_size, shadow_off, shadow_col)
	
	_configure_chip_stylebox(_cached_style_pressed, pressed_bg, radius, margins.left, margins.right, border_w, border_c, 0, shadow_off, shadow_col)
	
	_configure_chip_stylebox(_cached_style_disabled, disabled_bg, radius, margins.left, margins.right, border_w, border_c)
	
	_configure_chip_stylebox(_cached_style_focus, bg, radius, margins.left, margins.right, 2, focus_border)
	add_theme_stylebox_override("focus", _cached_style_focus)
	
	add_theme_color_override("font_color", text)
	add_theme_color_override("font_hover_color", text)
	add_theme_color_override("font_pressed_color", text)
	add_theme_color_override("font_focus_color", text)
	add_theme_color_override("font_disabled_color", disabled_text)
	
	var fonts = M3Theme.load_fonts()
	add_theme_font_override("font", fonts["medium"])
	add_theme_font_size_override("font_size", font_size)
	alignment = HORIZONTAL_ALIGNMENT_CENTER
	
	_update_all_icon_colors(text)

func _compute_content_margins(pad_h: int) -> Dictionary:
	var spec = _get_size_spec()
	var icon_gap = M3Units.dp(spec["icon_gap"])
	var icon_size = M3Units.dp(spec["icon_size"])
	
	var left_margin = pad_h
	var right_margin = pad_h
	
	if _checked_icon_node and _checked_icon_node.visible:
		left_margin += icon_size + icon_gap
	elif _icon_node and _icon_node.visible:
		left_margin += icon_size + icon_gap
	
	if _close_icon_node and _close_icon_node.visible:
		right_margin += icon_size + icon_gap
	
	if _trailing_icon_node and _trailing_icon_node.visible:
		right_margin += icon_size + icon_gap
	
	return {"left": left_margin, "right": right_margin}

func _configure_chip_stylebox(style: StyleBoxFlat, bg: Color, radius: int, left_margin: int, right_margin: int, border_w: int = 0, border_c: Color = Color.TRANSPARENT, shadow_size: int = 0, shadow_off: Vector2 = Vector2.ZERO, shadow_col: Color = Color.TRANSPARENT):
	if not style:
		return
	
	style.bg_color = bg
	style.set_corner_radius_all(radius)
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	style.shadow_size = shadow_size
	style.shadow_offset = shadow_off
	style.shadow_color = shadow_col
	
	style.content_margin_left = left_margin
	style.content_margin_right = right_margin
	
	if border_w > 0:
		style.border_color = border_c
		style.set_border_width_all(border_w)
	else:
		style.set_border_width_all(0)

func _update_icon():
	if not _icon_node:
		return
	var spec = _get_size_spec()
	var was_visible = _icon_node.visible
	if leading_icon and chip_variant != ChipVariant.FILTER:
		_icon_node.icon_settings.icon_size = max(1.0, M3Units.dp(spec["icon_size"]))
		_icon_node.icon_settings.icon_name = leading_icon
		_icon_node.visible = true
	else:
		_icon_node.visible = false
	if was_visible != _icon_node.visible:
		_update_theme()

func _update_checked_icon():
	if not _checked_icon_node:
		return
	var spec = _get_size_spec()
	var was_visible = _checked_icon_node.visible
	if chip_variant == ChipVariant.FILTER and button_pressed:
		_checked_icon_node.icon_settings.icon_size = max(1.0, M3Units.dp(spec["icon_size"]))
		_checked_icon_node.icon_settings.icon_name = checked_icon_name
		_checked_icon_node.visible = true
	else:
		_checked_icon_node.visible = false
	if was_visible != _checked_icon_node.visible:
		_update_theme()

func _update_close_icon():
	if not _close_icon_node:
		return
	var spec = _get_size_spec()
	var was_visible = _close_icon_node.visible
	if chip_variant == ChipVariant.INPUT:
		_close_icon_node.icon_settings.icon_size = max(1.0, M3Units.dp(spec["icon_size"]))
		_close_icon_node.icon_settings.icon_name = close_icon_name
		_close_icon_node.visible = true
	else:
		_close_icon_node.visible = false
	if was_visible != _close_icon_node.visible:
		_update_theme()

func _update_trailing_icon():
	if not _trailing_icon_node:
		return
	var spec = _get_size_spec()
	var was_visible = _trailing_icon_node.visible
	if chip_variant == ChipVariant.FILTER and not trailing_icon.is_empty():
		_trailing_icon_node.icon_settings.icon_size = max(1.0, M3Units.dp(spec["icon_size"]))
		_trailing_icon_node.icon_settings.icon_name = trailing_icon
		_trailing_icon_node.visible = true
	else:
		_trailing_icon_node.visible = false
	if was_visible != _trailing_icon_node.visible:
		_update_theme()

func _update_all_icon_colors(text_color: Color):
	if _icon_node and _icon_node.visible:
		_icon_node.icon_settings.icon_color = text_color
	if _checked_icon_node and _checked_icon_node.visible:
		_checked_icon_node.icon_settings.icon_color = text_color
	if _close_icon_node and _close_icon_node.visible:
		_close_icon_node.icon_settings.icon_color = text_color
	if _trailing_icon_node and _trailing_icon_node.visible:
		_trailing_icon_node.icon_settings.icon_color = text_color

func _update_icon_color(_colors: Dictionary = {}, _selected_colors: Dictionary = {}):
	# Override parent to use our unified icon color update
	var colors = _get_variant_colors(false)
	var text_color = colors.text
	if disabled:
		text_color = colors.disabled_text
	_update_all_icon_colors(text_color)

func _notification(what: int):
	if what == NOTIFICATION_RESIZED:
		_update_icon_positions()

func _update_icon_positions():
	if not _icon_node:
		return
	
	var spec = _get_size_spec()
	var pad_h = M3Units.dp(spec["padding_h"])
	var icon_size = M3Units.dp(spec["icon_size"])
	var y_pos = size.y / 2.0 - icon_size / 2.0
	
	if _icon_node.visible:
		_icon_node.position = Vector2(pad_h, y_pos)
		_icon_node.custom_minimum_size = Vector2(icon_size, icon_size)
		_icon_node.size = Vector2(icon_size, icon_size)
	
	if _checked_icon_node and _checked_icon_node.visible:
		_checked_icon_node.position = Vector2(pad_h, y_pos)
		_checked_icon_node.custom_minimum_size = Vector2(icon_size, icon_size)
		_checked_icon_node.size = Vector2(icon_size, icon_size)
	
	if _close_icon_node and _close_icon_node.visible:
		_close_icon_node.position = Vector2(size.x - pad_h - icon_size, y_pos)
		_close_icon_node.custom_minimum_size = Vector2(icon_size, icon_size)
		_close_icon_node.size = Vector2(icon_size, icon_size)
	
	if _trailing_icon_node and _trailing_icon_node.visible:
		_trailing_icon_node.position = Vector2(size.x - pad_h - icon_size, y_pos)
		_trailing_icon_node.custom_minimum_size = Vector2(icon_size, icon_size)
		_trailing_icon_node.size = Vector2(icon_size, icon_size)

func _on_toggled(_pressed: bool):
	_update_checked_icon()
	_update_trailing_icon()
	_update_theme()
	queue_redraw()
	checked_changed.emit(_pressed)

func refresh_theme():
	_cached_colors_hash = -1
	_update_theme()
