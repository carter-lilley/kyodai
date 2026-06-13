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
	# Keep the palette visible even when the main launcher window is minimized.
	transient = false

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
		if btn is Control:
			btn.focus_mode = Control.FOCUS_NONE

	# The palette is mouse-only so it doesn't steal controller input from the game.
	var root := $Root as Control
	if root:
		root.focus_mode = Control.FOCUS_NONE

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
		3:  # Shuffle / New game
			remove_requested.emit()
		4:  # Stop
			stop_requested.emit()
