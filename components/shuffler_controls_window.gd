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
const WARP_TRIGGER_THRESHOLD := 0.5

@onready var _pause_btn: M3IconButton = $Root/M3ButtonGroup/PauseButton
@onready var _button_group: M3ButtonGroup = $Root/M3ButtonGroup
@onready var _shuffle_btn: M3IconButton = $Root/M3ButtonGroup/ShuffleButton

var _is_paused: bool = false
var _warp_cooldown: float = 0.0
var _select_held: bool = false
var _l_trigger_held: bool = false

func set_reroll_enabled(enabled: bool) -> void:
	if _shuffle_btn and is_instance_valid(_shuffle_btn):
		_shuffle_btn.disabled = not enabled

func _ready():
	# Keep the palette visible even when the main launcher window is minimized.
	transient = false

	# Ensure the OS window is fully transparent and doesn't inherit any theme
	# background styleboxes from the main UI.
	transparent = true
	transparent_bg = true
	theme = Theme.new()

	# Size the window to fit the connected button column, plus a margin so the
	# pause button's hotkey badge (which overhangs the button's left edge) is
	# not clipped by the window bounds.
	var margin := int(M3Units.dp(10))
	var count := _button_group.get_child_count()
	if count > 0:
		var btn := _button_group.get_child(0) as Control
		var sep := _button_group.get_theme_constant("separation")
		var width := int(btn.custom_minimum_size.x)
		var height := int(btn.custom_minimum_size.y) * count + sep * (count - 1)
		size = Vector2i(width + margin * 2, height + margin * 2)
	_button_group.offset_left = margin
	_button_group.offset_top = margin
	_button_group.offset_right = -margin
	_button_group.offset_bottom = -margin

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

	# Use the custom cursor inside the controls window. The AHK overlay handles
	# rendering the same cursor everywhere else during a shuffler session.
	_apply_custom_cursor()
	tree_exiting.connect(_restore_default_cursor)

	# Hint the cursor-warp chord (hold LT + View/Select) on the pause button.
	# Smaller badge than the default so it doesn't dominate the palette button.
	_pause_btn.badge_size_dp = 14
	_pause_btn.badge_icon_font = "ControllerIcons"
	_pause_btn.badge_icon_name = "xbox-left-trigger+xbox-view"

func _process(delta: float) -> void:
	_warp_cooldown = maxf(0.0, _warp_cooldown - delta)

func _input(event: InputEvent) -> void:
	_update_chord_state(event)

	if _select_held and _l_trigger_held and _warp_cooldown <= 0.0:
		_warp_cooldown = WARP_COOLDOWN_SECONDS
		_warp_cursor_to_bottom_button()
		get_viewport().set_input_as_handled()

func _update_chord_state(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if event.button_index == JOY_BUTTON_BACK:
			_select_held = event.pressed
	elif event is InputEventJoypadMotion:
		if event.axis == JOY_AXIS_TRIGGER_LEFT:
			var now_held: bool = event.axis_value >= WARP_TRIGGER_THRESHOLD
			_l_trigger_held = now_held

func _warp_cursor_to_bottom_button() -> void:
	var btn_size := _pause_btn.size
	if btn_size == Vector2.ZERO:
		btn_size = _pause_btn.custom_minimum_size
	if btn_size == Vector2.ZERO:
		btn_size = Vector2(40, 40)

	# DisplayServer.warp_mouse() on a sub-Window interprets coordinates as
	# window-relative, not screen-relative, so pass local button center.
	var target := Vector2i(_pause_btn.position + btn_size / 2.0)
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
		var cursor_size := cursor_tex.get_size()
		var hotspot := Vector2(cursor_size.x * 0.35, cursor_size.y * 0.175)
		DisplayServer.cursor_set_custom_image(cursor_tex, DisplayServer.CURSOR_ARROW, hotspot)

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
