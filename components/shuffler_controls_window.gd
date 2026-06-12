class_name ShufflerControlsWindow
extends Window

signal pause_requested()
signal resume_requested()
signal skip_requested()
signal restart_requested()
signal remove_requested()
signal stop_requested()

@onready var _pause_btn: M3IconButton = $Root/M3ButtonGroup/PauseButton
@onready var _button_group: M3ButtonGroup = $Root/M3ButtonGroup

var _is_paused: bool = false

func _ready():
	# Size the window to exactly fit the connected button column.
	var count := _button_group.get_child_count()
	if count > 0:
		var btn := _button_group.get_child(0) as Control
		var sep := _button_group.get_theme_constant("separation")
		var width := int(btn.custom_minimum_size.x)
		var height := int(btn.custom_minimum_size.y) * count + sep * (count - 1)
		size = Vector2i(width, height)
	
	# Position the palette in the bottom-left of the desktop.
	var screen_size := DisplayServer.screen_get_size()
	position = Vector2i(16, screen_size.y - size.y - 16)
	
	# Connect button signals via the button group
	for i in range(count):
		var btn = _button_group.get_child(i)
		if btn is Button:
			btn.pressed.connect(_on_button_pressed.bind(i))

	# Focus the first button once the window is shown.
	visibility_changed.connect(_on_visibility_changed)
	_focus_first_button.call_deferred()

func _on_visibility_changed() -> void:
	if visible:
		_focus_first_button()

func _focus_first_button() -> void:
	if _button_group.get_child_count() == 0:
		return
	var first := _button_group.get_child(0) as Control
	if first and first.is_visible_in_tree() and not first.has_focus():
		first.grab_focus()

func _on_button_pressed(index: int):
	match index:
		0:  # Pause/Resume
			_is_paused = not _is_paused
			_pause_btn.icon_name = "play" if _is_paused else "pause"
			if _is_paused:
				pause_requested.emit()
			else:
				resume_requested.emit()
		1:  # Skip
			skip_requested.emit()
		2:  # Restart
			restart_requested.emit()
		3:  # Reroll
			remove_requested.emit()
		4:  # Stop
			stop_requested.emit()
