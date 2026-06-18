#range_slider.gd
extends Control
class_name RangeSlider

# Internal M3Slider used in RANGE mode
var _slider: M3Slider

signal value_changed(value: Vector2)

var _step: float = 0.1
var _min_value: float = 0.0
var _max_value: float = 1.0

var range_start: float = 0.25:
	set(v):
		range_start = v
		if _slider:
			_slider.value = v

var range_end: float = 0.75:
	set(v):
		range_end = v
		if _slider:
			_slider.range_value = v

var editable: bool = true:
	set(v):
		editable = v
		if _slider:
			_slider.editable = v

func _init(p_range_start: float = 0.25, p_range_end: float = 0.75, p_step: float = 0.1, p_min_value: float = 0.0, p_max_value: float = 1.0) -> void:
	_step = p_step
	_min_value = p_min_value
	_max_value = p_max_value
	range_start = p_range_start
	range_end = p_range_end

func _ready() -> void:
	_slider = M3Slider.new()
	_slider.slider_variant = M3Slider.Variant.RANGE
	_slider.min_value = _min_value
	_slider.max_value = _max_value
	_slider.step = _step
	_slider.value = range_start
	_slider.range_value = range_end
	_slider.editable = editable
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_slider)
	_slider.value_changed.connect(_on_value_changed)
	_slider.range_value_changed.connect(_on_range_value_changed)

func _on_value_changed(_value: float) -> void:
	_emit()

func _on_range_value_changed(_value: float) -> void:
	_emit()

func _emit() -> void:
	range_start = _slider.value
	range_end = _slider.range_value
	value_changed.emit(Vector2(range_start, range_end))

func set_range(p_start: float, p_end: float) -> void:
	range_start = p_start
	range_end = p_end
