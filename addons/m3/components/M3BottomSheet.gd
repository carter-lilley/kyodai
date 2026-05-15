class_name M3BottomSheet
extends M3Sheet

## Material 3 Bottom Sheet Component
## Slides up from the bottom edge with optional modal scrim and drag handle.

const CORNER_RADIUS := 28.0
const MAX_WIDTH := 640.0
const CONTENT_MARGIN_TOP := 16.0
const CONTENT_MARGIN_LEFT := 16.0
const CONTENT_MARGIN_RIGHT := 24.0
const DRAG_HANDLE_WIDTH := 32.0
const DRAG_HANDLE_HEIGHT := 4.0

# ============================================
# EXPORTS
# ============================================

@export var show_drag_handle: bool = true:
	set(value):
		if value == show_drag_handle:
			return
		show_drag_handle = value
		if _ready_called:
			_update_drag_handle()

@export var peek_height: float = 300.0:
	set(value):
		if value == peek_height:
			return
		peek_height = value
		if _ready_called:
			_update_height()

# ============================================
# INTERNAL
# ============================================

var _drag_handle: Panel

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_type = "bottom_sheet"

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
	root.alignment = BoxContainer.ALIGNMENT_BEGIN
	margin.add_child(root)
	
	# Drag handle
	_drag_handle = Panel.new()
	_drag_handle.custom_minimum_size = Vector2(M3Units.dp(DRAG_HANDLE_WIDTH), M3Units.dp(DRAG_HANDLE_HEIGHT))
	_drag_handle.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var drag_margin = Control.new()
	drag_margin.custom_minimum_size = Vector2(0, M3Units.dp(16))
	root.add_child(drag_margin)
	root.add_child(_drag_handle)
	
	# Header padding
	var header_pad = Control.new()
	header_pad.custom_minimum_size = Vector2(0, M3Units.dp(8))
	root.add_child(header_pad)
	
	# Header
	_header = _build_header()
	root.add_child(_header)
	
	# Content
	_content_slot = VBoxContainer.new()
	_content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_content_slot)

func _ready():
	if not _sheet_container:
		_build_sheet_layout()
	super._ready()
	_position_sheet()
	_update_drag_handle()

func _get_sheet_width(screen_width: float) -> float:
	return min(screen_width, M3Units.dp(MAX_WIDTH))

func _position_sheet():
	if not _sheet_container:
		return
	
	var screen_size = _get_screen_size()
	var height_px = M3Units.dp(peek_height)
	var width_px = _get_sheet_width(screen_size.x)
	var x_pos = (screen_size.x - width_px) / 2.0
	
	# Position off-screen below initially
	_sheet_container.position = Vector2(x_pos, screen_size.y)
	_sheet_container.size = Vector2(width_px, height_px)
	
	# Modal variant: rounded top corners
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
		style.corner_radius_top_right = M3Units.dp(CORNER_RADIUS)
		style.corner_radius_bottom_left = 0
		style.corner_radius_bottom_right = 0

func _update_drag_handle():
	if not _drag_handle:
		return
	_drag_handle.visible = show_drag_handle
	if show_drag_handle:
		var style = _drag_handle.get_theme_stylebox("panel")
		if not style is StyleBoxFlat:
			style = StyleBoxFlat.new()
			style.set_corner_radius_all(int(M3Units.dp(DRAG_HANDLE_HEIGHT) / 2.0))
			_drag_handle.add_theme_stylebox_override("panel", style)
		style.bg_color = M3Theme.get_on_surface_variant()

func _update_height():
	if _sheet_container:
		var height_px = M3Units.dp(peek_height)
		_sheet_container.size.y = height_px
		_position_sheet()

# ============================================
# ANIMATION
# ============================================

func _animate_in():
	if not _sheet_container:
		return
	
	var screen_size = _get_screen_size()
	var height_px = _sheet_container.size.y
	var start_y = screen_size.y
	var end_y = screen_size.y - height_px
	var width_px = _get_sheet_width(screen_size.x)
	var x_pos = (screen_size.x - width_px) / 2.0
	
	_sheet_container.position = Vector2(x_pos, start_y)
	
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
	_tween.tween_property(_sheet_container, "position:y", end_y, 0.3)

func _animate_out(callback: Callable):
	if not _sheet_container:
		callback.call()
		return
	
	var screen_size = _get_screen_size()
	var end_y = screen_size.y
	var width_px = _get_sheet_width(screen_size.x)
	var x_pos = (screen_size.x - width_px) / 2.0
	
	if _scrim and sheet_variant == Variant.MODAL:
		if _scrim_tween and _scrim_tween.is_valid():
			_scrim_tween.kill()
		_scrim_tween = create_tween()
		_scrim_tween.tween_property(_scrim, "modulate:a", 0.0, 0.3)
	
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_sheet_container, "position:y", end_y, 0.3)
	_tween.finished.connect(callback, CONNECT_ONE_SHOT)

# ============================================
# PUBLIC API
# ============================================

static func show_bottom_sheet(headline: String = "", variant: Variant = Variant.MODAL) -> M3BottomSheet:
	var sheet = M3BottomSheet.new()
	sheet.headline_text = headline
	sheet.sheet_variant = variant
	sheet.show_overlay()
	return sheet
