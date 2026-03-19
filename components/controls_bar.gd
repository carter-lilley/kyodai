class_name ControlsBar
extends MarginContainer

signal control_pressed(action: String)
signal mode_changed(mode: DisplayMode)

enum DisplayMode { FLOATING, DOCKED }

var _display_mode: DisplayMode = DisplayMode.FLOATING
var _background_panel: Panel
var _horizontal_container: HBoxContainer
var _test_labels: Array[Label] = []

const CORNER_RADIUS = 6

func _ready():
	_create_background_panel()
	_build_horizontal_layout()
	_update_mode_appearance()

func _create_background_panel() -> void:
	_background_panel = Panel.new()
	_background_panel.name = "BackgroundPanel"
	_background_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_background_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Create base style with 85% opacity
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.85)
	style.set_corner_radius_all(0)
	_background_panel.add_theme_stylebox_override("panel", style)
	
	add_child(_background_panel)
	move_child(_background_panel, 0)

func _build_horizontal_layout() -> void:
	_horizontal_container = HBoxContainer.new()
	_horizontal_container.name = "HorizontalContainer"
	_horizontal_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_horizontal_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_horizontal_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_horizontal_container.add_theme_constant_override("separation", 20)
	
	# Create three test labels spaced evenly
	for i in range(3):
		var label = Label.new()
		label.name = "TestLabel%d" % (i + 1)
		label.text = "Control %d" % (i + 1)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 16)
		_test_labels.append(label)
		_horizontal_container.add_child(label)
	
	add_child(_horizontal_container)

func set_display_mode(mode: DisplayMode) -> void:
	if _display_mode == mode:
		return
	
	_display_mode = mode
	_update_mode_appearance()
	mode_changed.emit(mode)

func _update_mode_appearance() -> void:
	var style = _background_panel.get_theme_stylebox("panel")
	if not style is StyleBoxFlat:
		return
	
	var flat_style = style as StyleBoxFlat
	
	match _display_mode:
		DisplayMode.FLOATING:
			# Floating mode: 85% opacity with rounded top-left and bottom-left corners
			flat_style.bg_color = Color(0, 0, 0, 0.85)
			flat_style.corner_radius_top_left = CORNER_RADIUS
			flat_style.corner_radius_top_right = 0
			flat_style.corner_radius_bottom_left = CORNER_RADIUS
			flat_style.corner_radius_bottom_right = 0
		DisplayMode.DOCKED:
			# Docked mode: 85% opacity with no rounded corners
			flat_style.bg_color = Color(0, 0, 0, 0.85)
			flat_style.set_corner_radius_all(0)

func get_display_mode() -> DisplayMode:
	return _display_mode

func set_bar_opacity(opacity: float) -> void:
	if _background_panel:
		var style = _background_panel.get_theme_stylebox("panel")
		if style is StyleBoxFlat:
			style.bg_color = Color(0, 0, 0, opacity)

func set_bar_color(color: Color) -> void:
	if _background_panel:
		var style = _background_panel.get_theme_stylebox("panel")
		if style is StyleBoxFlat:
			style.bg_color = color
