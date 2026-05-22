#range_slider.gd
extends Control
class_name RangeSlider

# Internal sliders
var min_slider : HSlider = HSlider.new()
var max_slider : HSlider = HSlider.new()

signal value_changed(value: Vector2)

# Called when the node enters the scene tree for the first time.
func _init(range_start: float = 0.25, range_end: float = 0.75, _step: float = 0.1, min_range: float = 0.0, max_range: float = 1.0) -> void:
	#min_slider.focus_mode = 2
	min_slider.min_value = min_range
	min_slider.max_value = max_range
	min_slider.step = _step
	min_slider.value = range_start
	#max_slider.focus_mode = 2
	max_slider.min_value = min_range
	max_slider.max_value = max_range
	max_slider.step = _step
	max_slider.value = range_end
	min_slider.connect("value_changed", _on_min_changed)
	max_slider.connect("value_changed", _on_max_changed)

func _on_min_changed(value: float) -> void:
	if value > max_slider.value:
		value = max_slider.value
		min_slider.value = value
	emit_signal("value_changed", Vector2(value, max_slider.value))

func _on_max_changed(value: float) -> void:
	if value < min_slider.value:
		value = min_slider.value
		max_slider.value = value
	emit_signal("value_changed", Vector2(min_slider.value, value))
