#indicator.gd
extends Control
class_name Indicator

enum StatusEnum { NOT_CONFIGURED, CONNECTED, DISCONNECTED, TESTING }

signal test_requested()

var _status_dot: ColorRect
var _status_label: Label
var _test_button: Button

func _ready() -> void:
	var hbox = HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(hbox)
	
	# Status dot
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(12, 12)
	_status_dot.color = Color.GRAY
	hbox.add_child(_status_dot)
	
	# Spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(8, 0)
	hbox.add_child(spacer)
	
	# Status label
	_status_label = Label.new()
	_status_label.text = "Not configured"
	hbox.add_child(_status_label)
	
	# Test button (hidden by default)
	_test_button = Button.new()
	_test_button.text = "Test"
	_test_button.pressed.connect(func():
		test_requested.emit()
	)
	_test_button.hide()
	hbox.add_child(_test_button)

func show_test_button(show: bool = true) -> void:
	if _test_button:
		_test_button.visible = show

func set_status(status: StatusEnum, message: String = "") -> void:
	if not is_node_ready():
		return
	match status:
		StatusEnum.NOT_CONFIGURED:
			_status_dot.color = Color.GRAY
			_status_label.text = message if not message.is_empty() else "Not configured"
		StatusEnum.CONNECTED:
			_status_dot.color = Color.GREEN
			_status_label.text = message if not message.is_empty() else "Connected"
		StatusEnum.DISCONNECTED:
			_status_dot.color = Color.RED
			_status_label.text = message if not message.is_empty() else "Disconnected"
		StatusEnum.TESTING:
			_status_dot.color = Color.YELLOW
			_status_label.text = message if not message.is_empty() else "Testing..."

func get_status_text() -> String:
	return _status_label.text

func set_status_text(text: String) -> void:
	_status_label.text = text
