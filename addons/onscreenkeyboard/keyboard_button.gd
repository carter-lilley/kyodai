extends M3Button

## On-screen keyboard key. M3Button-based: variant styling, font icons and
## badges (e.g. controller glyphs) come from the M3 button system.

var key_data

signal released
signal down

func _init(_key_data):
	key_data = _key_data

	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	# Rows control key heights, not the button size spec
	auto_size_vertical = false

	focus_mode = FOCUS_ALL

	if key_data.has("display"):
		text = key_data.get("display")

	if key_data.has("stretch-ratio"):
		size_flags_stretch_ratio = key_data.get("stretch-ratio")


func change_uppercase(value):
	if value:
		if key_data.has("display-uppercase"):
			text = key_data.get("display-uppercase")
		else:
			if key_data.has("display"):
				text = key_data.get("display")


var _is_pressed: bool = false

# The same physical tap can arrive as two complete press/release pairs on some
# Android devices (touchscreen driver events plus emulated mouse / second-screen
# plugin forwarding). _is_pressed only collapses interleaved duplicates, not
# sequential pairs, so without a time guard one tap can emit `released` twice
# and type the character twice. 100ms is far faster than a human can
# deliberately double-tap one key.
const RELEASE_DEBOUNCE_MSEC := 100
var _last_release_msec: int = -1

func _gui_input(event):
	if event.is_action_pressed("ui_accept"):
		_on_button_down(true)
		_on_button_up()
		accept_event()
	elif event is InputEventScreenTouch:
		# If touch is being emulated as mouse, let the emulated mouse event handle it
		# to avoid double-triggering feedback.
		if ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch"):
			# Still consume the raw touch so it can't fall through to controls
			# underneath (e.g. a duplicate stacked keyboard after a reparent).
			accept_event()
			return
		if event.pressed and not _is_pressed:
			_is_pressed = true
			_on_button_down(true)
			accept_event()
		elif not event.pressed and _is_pressed:
			_is_pressed = false
			_on_button_up()
			accept_event()
	elif event is InputEventMouseButton:
		var is_touch_emulated: bool = event.device == InputEvent.DEVICE_ID_EMULATION
		if event.pressed and not _is_pressed:
			_is_pressed = true
			_on_button_down(is_touch_emulated)
			accept_event()
		elif not event.pressed and _is_pressed:
			_is_pressed = false
			_on_button_up()
			accept_event()
		# Keep M3Button's SubViewport press visuals working (dual-screen keyboard)
		super._gui_input(event)

func _on_button_up():
	var now_msec := Time.get_ticks_msec()
	if _last_release_msec >= 0 and now_msec - _last_release_msec < RELEASE_DEBOUNCE_MSEC:
		# Sequential duplicate pair from the same physical tap — swallow it.
		return
	_last_release_msec = now_msec
	released.emit(key_data)
	# Don't release focus - keep it for controller navigation


func _on_button_down(trigger_feedback: bool = false):
	down.emit(key_data)
	if trigger_feedback:
		_trigger_haptic_feedback()


func _trigger_haptic_feedback() -> void:
	if SystemManager.platform.is_android():
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin:
			plugin.call("vibrateDevice", 30)
	elif Input.get_connected_joypads().size() > 0:
		Input.start_joy_vibration(0, 0.1, 0.05, 0.08)
