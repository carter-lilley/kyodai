#range_slider.gd
extends Control
class_name RangeSlider

# Internal sliders
var min : HSlider = HSlider.new()
var max : HSlider = HSlider.new()

signal value_changed(value: Vector2)

# Called when the node enters the scene tree for the first time.
func _init(range_start: float = 0.25, range_end: float = 0.75, _step: float = 0.1, min_range: float = 0.0, max_range: float = 1.0) -> void:
	#min.focus_mode = 2
	min.min_value = min_range
	min.max_value = max_range
	min.step = _step
	min.value = range_start
	#max.focus_mode = 2
	max.min_value = min_range
	max.max_value = max_range
	max.step = _step
	max.value = range_end
	min.connect("value_changed", _on_min_changed)
	max.connect("value_changed", _on_max_changed)

func _on_min_changed(value: float) -> void:
	if value > max.value:
		value = max.value
		min.value = value
	emit_signal("value_changed", Vector2(value, max.value))

func _on_max_changed(value: float) -> void:
	if value < min.value:
		value = min.value
		max.value = value
	emit_signal("value_changed", Vector2(min.value, value))
