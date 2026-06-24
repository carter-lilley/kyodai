class_name ShufflerControlsWindow
extends Window

signal pause_requested()
signal resume_requested()
signal skip_requested()
signal restart_requested()
signal remove_requested()
signal stop_requested()

const CURSOR_PATH := "res://assets/Cursor.png"
const WARP_COOLDOWN_SECONDS := 0.3

@onready var _pause_btn: M3IconButton = $Root/M3ButtonGroup/PauseButton
@onready var _button_group: M3ButtonGroup = $Root/M3ButtonGroup

var _is_paused: bool = false
var _warp_cooldown: float = 0.0

func _ready():
	# Keep the palette visible even when the main launcher window is minimized.
	transient = false

	# Ensure the OS window is fully transparent and doesn't inherit any theme
	# background styleboxes from the main UI.
	transparent = true
	transparent_bg = true
	theme = Theme.new()

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

	_apply_custom_cursor()
	tree_exiting.connect(_restore_default_cursor)

func _process(delta: float) -> void:
	_warp_cooldown = maxf(0.0, _warp_cooldown - delta)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("shuffler_warp_cursor") and _warp_cooldown <= 0.0:
		_warp_cooldown = WARP_COOLDOWN_SECONDS
		_warp_cursor_to_bottom_button()
		get_viewport().set_input_as_handled()

func _warp_cursor_to_bottom_button() -> void:
	var window_id := get_window_id()
	if window_id == DisplayServer.INVALID_WINDOW_ID:
		return

	var bottom_btn := _get_bottom_button()
	if not bottom_btn:
		return

	var window_pos := DisplayServer.window_get_position(window_id)
	var btn_center := bottom_btn.global_position + (bottom_btn.size / 2.0)
	var target := Vector2i(window_pos) + Vector2i(btn_center)
	DisplayServer.warp_mouse(target)

func _get_bottom_button() -> Control:
	if not _button_group or not is_instance_valid(_button_group):
		return null
	var count := _button_group.get_child_count()
	if count == 0:
		return null
	return _button_group.get_child(count - 1) as Control

func _apply_custom_cursor() -> void:
	var cursor_tex := load(CURSOR_PATH) as Texture2D
	if cursor_tex:
		DisplayServer.cursor_set_custom_image(cursor_tex, DisplayServer.CURSOR_ARROW, Vector2.ZERO)

func _restore_default_cursor() -> void:
	DisplayServer.cursor_set_custom_image(null, DisplayServer.CURSOR_ARROW)

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
