class_name M3SideSheet
extends M3Sheet

## Material 3 Side Sheet Component
## Slides in from the right edge with optional modal scrim.

const SHEET_WIDTH := 360.0
const CORNER_RADIUS := 28.0
const CONTENT_MARGIN_TOP := 24.0
const CONTENT_MARGIN_LEFT := 16.0
const CONTENT_MARGIN_RIGHT := 24.0

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_type = "side_sheet"

func _build_sheet_layout():
	# Scrim
	_scrim = ColorRect.new()
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	var on_surf = M3Theme.get_on_surface()
	_scrim.color = Color(on_surf.r, on_surf.g, on_surf.b, 0.32)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_input)
	_scrim.visible = false
	add_child(_scrim)
	
	# Sheet container
	_sheet_container = PanelContainer.new()
	add_child(_sheet_container)
	
	# Margin container for content padding
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", M3Units.dp(CONTENT_MARGIN_TOP))
	margin.add_theme_constant_override("margin_left", M3Units.dp(CONTENT_MARGIN_LEFT))
	margin.add_theme_constant_override("margin_right", M3Units.dp(CONTENT_MARGIN_RIGHT))
	margin.add_theme_constant_override("margin_bottom", 0)
	_sheet_container.add_child(margin)
	
	# Root VBox
	var root = VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	margin.add_child(root)
	
	# Header
	_header = _build_header()
	root.add_child(_header)
	
	# Content slot
	_content_slot = VBoxContainer.new()
	_content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_content_slot)

func _ready():
	if not _sheet_container:
		_build_sheet_layout()
	super._ready()
	_position_sheet()

func _position_sheet():
	if not _sheet_container:
		return
	
	var screen_size = _get_screen_size()
	var width_px = M3Units.dp(SHEET_WIDTH)
	
	# Position off-screen to the right initially
	_sheet_container.position = Vector2(screen_size.x, 0)
	_sheet_container.size = Vector2(width_px, screen_size.y)
	
	if sheet_variant == Variant.MODAL:
		_update_corner_radii()

func _update_appearance():
	super._update_appearance()
	if sheet_variant == Variant.MODAL and _sheet_container:
		_update_corner_radii()

func _update_corner_radii():
	var style = _sheet_container.get_theme_stylebox("panel")
	if style is StyleBoxFlat:
		style.corner_radius_top_left = M3Units.dp(CORNER_RADIUS)
		style.corner_radius_bottom_left = M3Units.dp(CORNER_RADIUS)
		style.corner_radius_top_right = 0
		style.corner_radius_bottom_right = 0

# ============================================
# ANIMATION
# ============================================

func _animate_in():
	if not _sheet_container:
		return
	
	var screen_size = _get_screen_size()
	var width_px = M3Units.dp(SHEET_WIDTH)
	var start_x = screen_size.x
	var end_x = screen_size.x - width_px
	
	_sheet_container.position.x = start_x
	
	if _scrim and sheet_variant == Variant.MODAL:
		_scrim.modulate.a = 0
		_scrim.visible = true
		if _scrim_tween and _scrim_tween.is_valid():
			_scrim_tween.kill()
		_scrim_tween = create_tween()
		_scrim_tween.tween_property(_scrim, "modulate:a", 1.0, 0.3)
	
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_sheet_container, "position:x", end_x, 0.3)

func _animate_out(callback: Callable):
	if not _sheet_container:
		callback.call()
		return
	
	var screen_size = _get_screen_size()
	var end_x = screen_size.x
	
	if _scrim and sheet_variant == Variant.MODAL:
		if _scrim_tween and _scrim_tween.is_valid():
			_scrim_tween.kill()
		_scrim_tween = create_tween()
		_scrim_tween.tween_property(_scrim, "modulate:a", 0.0, 0.3)
	
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_sheet_container, "position:x", end_x, 0.3)
	_tween.finished.connect(callback, CONNECT_ONE_SHOT)

# ============================================
# PUBLIC API
# ============================================

static func show_side_sheet(headline: String = "", variant: Variant = Variant.MODAL) -> M3SideSheet:
	var sheet = M3SideSheet.new()
	sheet.headline_text = headline
	sheet.sheet_variant = variant
	sheet.show_overlay()
	return sheet
