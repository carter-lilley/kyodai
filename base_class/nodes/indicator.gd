#indicator.gd
extends Control
class_name Indicator

## A generic status indicator with a colored dot and optional text label
## Can be configured for various use cases (network, downloads, emulator status, etc.)

enum Status { NEUTRAL, SUCCESS, ERROR, WARNING }

@export var dot_size: Vector2 = Vector2(12, 12):
	set(value):
		dot_size = value
		if _status_dot:
			_status_dot.custom_minimum_size = dot_size

@export var show_text: bool = true:
	set(value):
		show_text = value
		if _status_label:
			_status_label.visible = show_text

@export var text_prefix: String = ""

var _status_dot: ColorRect
var _status_label: Label
var _spacer: Control

func _ready() -> void:
	_build_ui()
	set_status(Status.NEUTRAL)

func _build_ui() -> void:
	var hbox = HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(hbox)
	
	# Status dot
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = dot_size
	_status_dot.color = Color.GRAY
	hbox.add_child(_status_dot)
	
	# Spacer
	_spacer = Control.new()
	_spacer.custom_minimum_size = Vector2(8, 0)
	hbox.add_child(_spacer)
	
	# Status label
	_status_label = Label.new()
	_status_label.visible = show_text
	var fonts = M3Theme.load_fonts()
	_status_label.add_theme_font_override("font", fonts["regular"])
	_status_label.add_theme_color_override("font_color", M3Theme.get_on_surface())
	hbox.add_child(_status_label)

func set_status(status: Status, message: String = "", tooltip: String = "") -> void:
	if not is_node_ready():
		return
	
	match status:
		Status.NEUTRAL:
			_status_dot.color = M3Theme.get_on_surface_variant()
			_status_label.text = text_prefix + (message if not message.is_empty() else "Not configured")
		Status.SUCCESS:
			_status_dot.color = Color(0.2, 0.7, 0.3)
			_status_label.text = text_prefix + (message if not message.is_empty() else "Ready")
		Status.ERROR:
			_status_dot.color = M3Theme.get_error()
			_status_label.text = text_prefix + (message if not message.is_empty() else "Error")
		Status.WARNING:
			_status_dot.color = Color(0.9, 0.6, 0.1)
			_status_label.text = text_prefix + (message if not message.is_empty() else "Warning")
	
	if not tooltip.is_empty():
		_tooltip_text = tooltip
		_status_dot.tooltip_text = tooltip
		_status_label.tooltip_text = tooltip

func set_custom_color(color: Color) -> void:
	if _status_dot:
		_status_dot.color = color

func set_status_text(text: String) -> void:
	if _status_label:
		_status_label.text = text_prefix + text

func get_status_text() -> String:
	return _status_label.text if _status_label else ""

func set_tooltip(tooltip: String) -> void:
	_tooltip_text = tooltip
	if _status_dot:
		_status_dot.tooltip_text = tooltip
	if _status_label:
		_status_label.tooltip_text = tooltip

func refresh_theme() -> void:
	if _status_label:
		_status_label.add_theme_color_override("font_color", M3Theme.get_on_surface())

var _tooltip_text: String = ""
