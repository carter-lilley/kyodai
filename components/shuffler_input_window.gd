class_name ShufflerInputWindow
extends Window

## Persistent, invisible input listener for the shuffler's summon chord
## (LT+Select). Joypad input only reaches viewports backed by a MAPPED OS
## window: the minimized main window is excluded, and the controls palette is
## created on summon and destroyed on dismiss, so neither can hear the chord.
## This tiny window stays mapped for the whole session purely as an input
## receiver; it has no visible content and ignores the mouse.

signal chord_pressed()

const TRIGGER_THRESHOLD := 0.5
var _select_held: bool = false
var _l_trigger_held: bool = false
var _chord_was_held: bool = false

func _ready() -> void:
	transparent = true
	transparent_bg = true
	theme = Theme.new()
	size = Vector2i(16, 16)
	# Same OS-window creation dance as the other shuffler windows: popup()
	# tries to make the window transient, which X11 rejects for always-on-top
	# windows.
	always_on_top = false
	popup()
	transient = false
	always_on_top = true
	unfocusable = true
	# Clicks fall straight through; the window is input-only for the pad.
	mouse_passthrough_polygon = PackedVector2Array()
	position = DisplayServer.screen_get_position()
	print("[ShufflerInputWindow] created: window_id=" + str(get_window_id()) + " visible=" + str(visible))

func _input(event: InputEvent) -> void:
	var chord_changed := false
	if event is InputEventJoypadButton:
		if event.button_index == JOY_BUTTON_BACK:
			_select_held = event.pressed
			chord_changed = true
	elif event is InputEventJoypadMotion:
		if event.axis == JOY_AXIS_TRIGGER_LEFT:
			var now_held: bool = event.axis_value >= TRIGGER_THRESHOLD
			if now_held != _l_trigger_held:
				_l_trigger_held = now_held
				chord_changed = true

	if chord_changed:
		var chord_now := _select_held and _l_trigger_held
		if chord_now and not _chord_was_held:
			_chord_was_held = true
			chord_pressed.emit()
		elif not chord_now and _chord_was_held:
			_chord_was_held = false
