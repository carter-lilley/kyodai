class_name M3Sheet
extends M3Overlay

## Abstract base class for Material 3 Sheet components (side and bottom).
## Provides common header, content slot, close button, and slide animation.

enum Variant { STANDARD, MODAL }

# ============================================
# EXPORTS
# ============================================

@export var sheet_variant: Variant = Variant.MODAL:
	set(value):
		if value == sheet_variant:
			return
		sheet_variant = value
		if _ready_called:
			_update_appearance()

@export var headline_text: String = "":
	set(value):
		if value == headline_text:
			return
		headline_text = value
		if _ready_called:
			_update_text()

@export var show_close_button: bool = true:
	set(value):
		if value == show_close_button:
			return
		show_close_button = value
		if _ready_called:
			_update_header()

@export var dismissible: bool = true

# ============================================
# INTERNAL
# ============================================

var _scrim: ColorRect
var _sheet_container: PanelContainer
var _header: HBoxContainer
var _back_btn: M3IconButton
var _headline_label: Label
var _close_btn: M3IconButton
var _content_slot: VBoxContainer

var _ready_called: bool = false
var _tween: Tween
var _scrim_tween: Tween
var _back_callback: Callable = Callable()

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_layer = 85

func _ready():
	super._ready()
	_update_appearance()
	_update_text()
	_update_header()
	_ready_called = true

# ============================================
# LAYOUT BUILDING (override in subclasses)
# ============================================

func _build_sheet_layout():
	pass

func _build_header() -> HBoxContainer:
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", M3Units.dp(12))
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Back button (hidden by default)
	_back_btn = M3IconButton.new()
	_back_btn.icon_button_size = M3IconButton.IconSize.SMALL
	_back_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_back_btn.icon_name = "arrow-back"
	_back_btn.visible = false
	header.add_child(_back_btn)
	
	# Headline
	_headline_label = Label.new()
	_headline_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_headline_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_headline_label.add_theme_font_override("font", M3Theme.load_fonts()["regular"])
	_headline_label.add_theme_font_size_override("font_size", M3Units.dp(20))
	header.add_child(_headline_label)
	
	# Close button
	_close_btn = M3IconButton.new()
	_close_btn.icon_button_size = M3IconButton.IconSize.SMALL
	_close_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_close_btn.icon_name = "close"
	_close_btn.pressed.connect(dismiss)
	header.add_child(_close_btn)
	
	return header

# ============================================
# APPEARANCE
# ============================================

func _update_appearance():
	if not _sheet_container:
		return
	
	var style = _sheet_container.get_theme_stylebox("panel")
	if not style is StyleBoxFlat:
		style = StyleBoxFlat.new()
		style.anti_aliasing = true
		style.anti_aliasing_size = 1.0
		_sheet_container.add_theme_stylebox_override("panel", style)
	
	style.bg_color = M3Theme.get_surface_container_low()
	
	if sheet_variant == Variant.MODAL:
		style.shadow_color = M3Theme.ELEVATION_1["color"]
		style.shadow_size = M3Theme.ELEVATION_1["size"]
		style.shadow_offset = M3Theme.ELEVATION_1["offset"]
	else:
		style.shadow_color = Color.TRANSPARENT
		style.shadow_size = 0
		style.shadow_offset = Vector2.ZERO
	
	if _scrim:
		_scrim.visible = (sheet_variant == Variant.MODAL)

func _update_text():
	if _headline_label:
		_headline_label.text = headline_text
		_headline_label.add_theme_color_override("font_color", M3Theme.get_on_surface())

func _update_header():
	if _close_btn:
		_close_btn.visible = show_close_button

# ============================================
# ANIMATION
# ============================================

func _get_screen_size() -> Vector2:
	var viewport = get_viewport()
	return viewport.get_visible_rect().size if viewport else Vector2(1920, 1080)

func _animate_in():
	pass

func _animate_out(callback: Callable):
	pass

# ============================================
# INPUT
# ============================================

func _input(event: InputEvent):
	super._input(event)

func _on_scrim_input(event: InputEvent):
	if not dismissible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		dismiss()

# ============================================
# PUBLIC API
# ============================================

func set_back_visible(visible: bool, callback: Callable = Callable()):
	if _back_btn:
		_back_btn.visible = visible
		# Disconnect only our tracked callback
		if _back_callback.is_valid():
			_back_btn.pressed.disconnect(_back_callback)
			_back_callback = Callable()
		if visible and callback.is_valid():
			_back_btn.pressed.connect(callback)
			_back_callback = callback

func refresh_theme():
	if _ready_called:
		_update_appearance()
		_update_text()

func show_overlay():
	var parent = M3Overlay.get_overlay_parent()
	if parent and get_parent() == null:
		parent.add_child(self)
	super.show_overlay()
	_animate_in()

func dismiss():
	if _tween and _tween.is_valid():
		_tween.kill()
	_animate_out(func():
		super.dismiss()
	)
