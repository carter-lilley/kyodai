extends Control

signal zoom_changed(value: float)
signal zoom_changed_finished(value: float)

var _slider: HSlider
var _l2_icon: TextureRect
var _r2_icon: TextureRect

func _ready():
	# Anchor to bottom-right with some margin
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	
	# Use top_level so we're positioned in screen space, unaffected by parent layout
	top_level = true
	
	# Build UI
	var container = HBoxContainer.new()
	container.name = "ZoomContainer"
	container.alignment = BoxContainer.ALIGNMENT_END
	container.add_theme_constant_override("separation", 8)
	
	# L2 icon
	_l2_icon = TextureRect.new()
	_l2_icon.name = "L2Icon"
	_l2_icon.custom_minimum_size = Vector2(24, 24)
	_l2_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_l2_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var l2_tex = load("res://assets/icons/buttonL2.png")
	if l2_tex:
		_l2_icon.texture = l2_tex
	container.add_child(_l2_icon)
	
	# Slider
	_slider = HSlider.new()
	_slider.name = "ZoomSlider"
	_slider.custom_minimum_size = Vector2(150, 0)
	_slider.min_value = 0.15
	_slider.max_value = 0.5
	_slider.step = 0.01
	_slider.value = 0.15
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.value_changed.connect(_on_slider_value_changed)
	_slider.drag_ended.connect(_on_slider_drag_ended)
	container.add_child(_slider)
	
	# R2 icon
	_r2_icon = TextureRect.new()
	_r2_icon.name = "R2Icon"
	_r2_icon.custom_minimum_size = Vector2(24, 24)
	_r2_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_r2_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var r2_tex = load("res://assets/icons/buttonR2.png")
	if r2_tex:
		_r2_icon.texture = r2_tex
	container.add_child(_r2_icon)
	
	add_child(container)
	container.set_anchors_preset(Control.PRESET_FULL_RECT)

func _on_slider_value_changed(value: float) -> void:
	zoom_changed.emit(value)

func _on_slider_drag_ended(_value_changed: bool) -> void:
	zoom_changed_finished.emit(_slider.value)

func set_zoom_value(value: float) -> void:
	if _slider:
		_slider.set_value_no_signal(value)

func get_zoom_value() -> float:
	return _slider.value if _slider else 0.0

func set_zoom_range(min_val: float, max_val: float, step: float) -> void:
	if _slider:
		_slider.min_value = min_val
		_slider.max_value = max_val
		_slider.step = step
