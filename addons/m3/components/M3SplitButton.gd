@tool
class_name M3SplitButton
extends HBoxContainer

## Material 3 Split Button Component
## Two M3Buttons side by side with a 2dp gap, forming a split pill shape.
## The left half is the main action; the right half opens a menu.

const DROPDOWN_ICON := "triangle-small-down"
const DROPDOWN_ICON_OPEN := "triangle-small-up"

# ============================================
# EXPORTS
# ============================================

@export var text: String = "":
	set(value):
		if value == text:
			return
		text = value
		if _main_btn:
			_main_btn.text = value
			_update_corner_radii()

@export var icon_name: String = "":
	set(value):
		if value == icon_name:
			return
		icon_name = value
		if _main_btn:
			_main_btn.icon_name = value
			_update_corner_radii()

@export var button_size: M3Button.Size = M3Button.Size.MEDIUM:
	set(value):
		if value == button_size:
			return
		button_size = value
		if _main_btn:
			_main_btn.button_size = value
			_dropdown_btn.button_size = value
			_update_corner_radii()

@export var button_variant: M3Button.Variant = M3Button.Variant.FILLED:
	set(value):
		if value == button_variant:
			return
		button_variant = value
		if _main_btn:
			_main_btn.button_variant = value
			_dropdown_btn.button_variant = value
			_update_corner_radii()

@export var disabled: bool = false:
	set(value):
		if value == disabled:
			return
		disabled = value
		if _main_btn:
			_main_btn.disabled = value
			_dropdown_btn.disabled = value

@export var menu: M3Menu

# ============================================
# SIGNALS
# ============================================

signal pressed
signal menu_requested

# ============================================
# INTERNAL
# ============================================

var _main_btn: M3Button
var _dropdown_btn: M3Button
var _menu_active: bool = false

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	# 2dp gap between halves
	add_theme_constant_override("separation", M3Units.dp(2))
	
	_main_btn = M3Button.new()
	_main_btn.button_size = button_size
	_main_btn.button_variant = button_variant
	_main_btn.text = text
	_main_btn.icon_name = icon_name
	_main_btn.disabled = disabled
	_main_btn.pressed.connect(func(): pressed.emit())
	add_child(_main_btn)
	
	_dropdown_btn = M3Button.new()
	_dropdown_btn.button_size = button_size
	_dropdown_btn.button_variant = button_variant
	_dropdown_btn.text = ""
	_dropdown_btn.icon_name = DROPDOWN_ICON
	_dropdown_btn.disabled = disabled
	_dropdown_btn.pressed.connect(_on_dropdown_pressed)
	add_child(_dropdown_btn)
	
	_update_corner_radii()

# ============================================
# CORNER RADIUS
# ============================================

func _update_corner_radii():
	if not _main_btn or not _dropdown_btn:
		return
	
	var spec = M3Button.SIZE_SPECS[button_size]
	var height_px = M3Units.dp(spec["height"])
	var outer = int(height_px / 2.0)
	var inner = _get_inner_radius()
	
	_main_btn.set_corner_radii(outer, inner, outer, inner)
	_dropdown_btn.set_corner_radii(inner, outer, inner, outer)

func _get_inner_radius() -> int:
	match button_size:
		M3Button.Size.EXTRA_SMALL, M3Button.Size.SMALL, M3Button.Size.MEDIUM:
			return M3Units.dp(4)
		M3Button.Size.LARGE:
			return M3Units.dp(8)
		M3Button.Size.EXTRA_LARGE:
			return M3Units.dp(12)
	return M3Units.dp(4)

# ============================================
# MENU INTEGRATION
# ============================================

func set_menu_active(active: bool):
	_menu_active = active
	if _dropdown_btn:
		_dropdown_btn.set_menu_active(active)
		_dropdown_btn.icon_name = DROPDOWN_ICON_OPEN if active else DROPDOWN_ICON

func _on_dropdown_pressed():
	menu_requested.emit()
	if menu and not _menu_active:
		set_menu_active(true)
		menu.popup(self, 0, true, size.x)
		if not menu.dismissed.is_connected(_on_menu_dismissed):
			menu.dismissed.connect(_on_menu_dismissed)

func _on_menu_dismissed():
	set_menu_active(false)
	if _dropdown_btn:
		_dropdown_btn.grab_focus()

# ============================================
# THEME
# ============================================

func refresh_theme():
	if _main_btn:
		_main_btn.refresh_theme()
	if _dropdown_btn:
		_dropdown_btn.refresh_theme()
	_update_corner_radii()
