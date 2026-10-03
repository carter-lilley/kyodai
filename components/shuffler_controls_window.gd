class_name ShufflerControlsWindow
extends Window

signal pause_requested()
signal resume_requested()
signal skip_requested()
signal restart_requested()
signal remove_requested()
signal stop_requested()

const CURSOR_PATH := "res://assets/Cursor.png"

@onready var _pause_btn: M3IconButton = $Root/M3ButtonGroup/PauseButton
@onready var _button_group: M3ButtonGroup = $Root/M3ButtonGroup
@onready var _shuffle_btn: M3IconButton = $Root/M3ButtonGroup/ShuffleButton

var _is_paused: bool = false
var _is_visible: bool = false
var _active_tween: Tween = null

# GameMode (gamescope) layout: gamescope only presents fullscreen windows, so
# the controls window spans the screen like the intro window and the button
# column slides in/out inside it. _hidden_x/_shown_x are the column's x in
# window-local coordinates.
var _gamemode := false
var _hidden_x := 0.0
var _shown_x := 0.0
var _column_size := Vector2.ZERO

# Chord state for toggling the palette. Tracked here because this Window
# needs to be a real OS window (and stay alive) to receive controller input
# while the main Kyodai window is unfocused/minimized.
var _select_held: bool = false
var _l_trigger_held: bool = false
var _chord_was_held: bool = false
const TRIGGER_THRESHOLD := 0.5

# Controller-accept dedup state. The same physical press can arrive multiple
# times: some pads register with SDL twice (two device indices), and Godot
# delivers both the raw joypad event AND the mapped InputEventAction. Without
# dedup, one A press emits several Button.pressed and e.g. Restart loops.
const ACCEPT_DEBOUNCE_MSEC := 250
var _last_accept_msec: int = -1
var _replayed_accept: InputEventAction = null

# Input lockout after summon: events in this window are swallowed so a held
# or queued press (chord release, game input already in flight) can't
# instantly activate the freshly-focused Pause button and vanish the panel.
const SUMMON_INPUT_LOCKOUT_MSEC := 200
var _input_locked_until_msec: int = -1

func set_reroll_enabled(enabled: bool) -> void:
	if _shuffle_btn and is_instance_valid(_shuffle_btn):
		_shuffle_btn.disabled = not enabled

func _ready():
	# Ensure the OS window is fully transparent and doesn't inherit any theme
	# background styleboxes from the main UI.
	transparent = true
	transparent_bg = true
	theme = Theme.new()

	# Size the window to fit the connected button column exactly.
	var count := _button_group.get_child_count()
	if count > 0:
		var btn := _button_group.get_child(0) as Control
		var sep := _button_group.get_theme_constant("separation")
		_column_size = Vector2(int(btn.custom_minimum_size.x), int(btn.custom_minimum_size.y) * count + sep * (count - 1))

	_gamemode = SystemManager.platform.is_gamemode()
	print("[ShufflerControlsWindow] gamemode=", _gamemode)
	var screen_size := DisplayServer.screen_get_size()
	# GameScope presents fullscreen transparent windows as the active layer
	# (same pattern as the intro window); desktop keeps the compact window.
	size = screen_size if _gamemode else Vector2i(_column_size)

	# Create the real OS window immediately and keep it alive for the whole
	# session. A hidden Godot Window node has no OS window and cannot receive
	# controller input, so we popup() and then park it off-screen. popup()
	# sets transient, so clear it and restore always_on_top afterwards.
	# popup() will try to make the window transient, but X11 rejects
	# always-on-top windows becoming transient. Disable always_on_top
	# temporarily, popup to create the OS window, clear transient, then
	# restore always_on_top and park just off-screen.
	always_on_top = false
	popup()
	transient = false
	always_on_top = true
	if _gamemode:
		# Unfocusable so the emulator keeps input focus; navigation is
		# handled manually in _input.
		position = DisplayServer.screen_get_position()
		unfocusable = true
		_shown_x = 16.0
		_hidden_x = -_column_size.x
		_button_group.position = Vector2(_hidden_x, screen_size.y - _column_size.y - 16)
		# Clicks fall through to the game while the panel is hidden; the
		# passthrough region is toggled to the button column on summon.
		mouse_passthrough_polygon = PackedVector2Array()
	else:
		_shown_x = 0.0
		_hidden_x = -_column_size.x
		# Keep the window at the final on-screen position at all times; we animate
		# the button column inside it so the window manager never has to place the
		# OS window at negative/clamped coordinates.
		position = Vector2i(16, screen_size.y - size.y - 16)
		# Park the button column off-screen left inside the window.
		_button_group.position.x = _hidden_x

	# Connect button signals via the button group and set explicit vertical
	# focus neighbors so controller navigation reliably moves up/down.
	for i in range(count):
		var btn = _button_group.get_child(i)
		if btn is Button:
			btn.pressed.connect(_on_button_pressed.bind(i))
		if btn is Control:
			btn.focus_mode = Control.FOCUS_ALL
			var prev_idx := (i - 1 + count) % count
			var next_idx := (i + 1) % count
			btn.focus_neighbor_top = btn.get_path_to(_button_group.get_child(prev_idx))
			btn.focus_neighbor_bottom = btn.get_path_to(_button_group.get_child(next_idx))
		if btn is M3Button:
			# M3Button hides its own focus border by default because the main UI
			# uses FocusSubManager's global ring. The controls window is a separate
			# viewport without that ring, so enable the local focus border.
			btn.show_focus_border = true

	# Allow controller UI navigation while the chord is held.
	var root := $Root as Control
	if root:
		root.focus_mode = Control.FOCUS_ALL

	# Use the custom cursor inside the controls window. The AHK overlay handles
	# rendering the same cursor everywhere else during a shuffler session.
	_apply_custom_cursor()
	tree_exiting.connect(_restore_default_cursor)



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
			toggle_controls()
		elif not chord_now and _chord_was_held:
			_chord_was_held = false

	# Hidden panel: swallow EVERY controller event this viewport receives.
	# An unhandled ui_accept that falls through to the viewport's GUI layer
	# re-triggers whichever button still holds focus (focus release used to
	# wait for the slide-out tween, leaking presses meant for the game). The
	# chord above already ran, so summoning still works. The emulator is a
	# separate OS process, so consuming here never starves the game of input.
	if not _is_visible:
		if event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventAction:
			get_viewport().set_input_as_handled()
		return

	# Summon lockout: swallow events so they can't reach the freshly-focused
	# button through the viewport's GUI router either. The chord state above
	# already updated, so releasing the chord during the lockout is safe.
	if Time.get_ticks_msec() < _input_locked_until_msec:
		if event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventAction:
			get_viewport().set_input_as_handled()
		return

	# Manual controller UI navigation: the controls window viewport is not the
	# active OS-focused viewport, so Godot's default ui_* action handling does
	# not run here. Handle the raw events ourselves while the panel is visible.
	if event is InputEventJoypadButton and event.pressed:
		if event.is_action_pressed("ui_down"):
			var focused := get_viewport().gui_get_focus_owner() as Control
			var next := focused.find_next_valid_focus() if focused else _button_group.get_child(0)
			if next:
				next.grab_focus()
				get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_up"):
			var focused := get_viewport().gui_get_focus_owner() as Control
			var prev := focused.find_prev_valid_focus() if focused else _button_group.get_child(0)
			if prev:
				prev.grab_focus()
				get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel"):
			hide_controls()
			get_viewport().set_input_as_handled()
		# ui_accept is intentionally NOT handled here on raw joypad events:
		# the same press also arrives as a mapped InputEventAction, and pads
		# registered twice with SDL deliver the raw event twice. Handling the
		# mapped action once below dedups all of those paths.
	elif event is InputEventAction and event.action == "ui_accept" and event.pressed and event != _replayed_accept:
		var now := Time.get_ticks_msec()
		if now - _last_accept_msec < ACCEPT_DEBOUNCE_MSEC:
			# Duplicate delivery of a press we already handled (double-registered
			# pad or extra mapped action). Swallow it so the button fires once.
			get_viewport().set_input_as_handled()
		else:
			var focused := get_viewport().gui_get_focus_owner() as Control
			if focused and focused is Button:
				_last_accept_msec = now
				# Consume the mapped action so it can't ALSO reach the focused
				# button through the GUI router, then replay one fresh copy:
				# BaseButton's press animation only responds to real input
				# events, not signal.emit(). The replayed press carries
				# _replayed_accept identity so it passes this branch untouched
				# and lands on the button as the single press.
				get_viewport().set_input_as_handled()
				_press_focused_button(focused)

## Pushes a synthesized ui_accept press/release into this window's viewport so
## the focused button's own state machine plays the press animation. The
## release comes shortly after so the pressed visual is perceptible. The press
## is tagged in _replayed_accept so this handler lets it through (and doesn't
## mistake it for a new physical press to dedup).
func _press_focused_button(btn: Button) -> void:
	var press := InputEventAction.new()
	press.action = "ui_accept"
	press.pressed = true
	_replayed_accept = press
	get_viewport().push_input(press)
	await get_tree().create_timer(0.12).timeout
	var release := InputEventAction.new()
	release.action = "ui_accept"
	release.pressed = false
	get_viewport().push_input(release)

## Reasserts the window stacking after something else (a newly launched
## emulator window, a skip/restart raise) has taken foreground.
func ensure_on_top() -> void:
	if not _is_visible:
		return
	visible = true
	always_on_top = true
	move_to_foreground()

func toggle_controls() -> void:
	if _is_visible:
		hide_controls()
	else:
		show_controls()

func show_controls() -> void:
	if _is_visible:
		return
	_is_visible = true
	_input_locked_until_msec = Time.get_ticks_msec() + SUMMON_INPUT_LOCKOUT_MSEC
	SystemManager.audio.play_sfx("click_04")
	# Brief haptic blip so the summon has physical feedback on the pad.
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, 0.45, 0.55, 0.12)
	if _active_tween and is_instance_valid(_active_tween):
		_active_tween.kill()
		_active_tween = null
	# Make sure the button column starts fully off-screen left inside the window.
	_button_group.position.x = _hidden_x
	visible = true
	# Ensure the palette is actually stacked above the emulator after being
	# parked off-screen; always_on_top is not always enough on its own.
	always_on_top = true
	move_to_foreground()
	if _gamemode:
		# While summoned, mouse clicks land on the button column only;
		# everything else still passes through to the emulator.
		var r := Rect2(Vector2(_shown_x, _button_group.position.y), _column_size)
		mouse_passthrough_polygon = PackedVector2Array([
			r.position, r.position + Vector2(r.size.x, 0),
			r.position + r.size, r.position + Vector2(0, r.size.y)
		])
	_active_tween = create_tween()
	_active_tween.set_ease(Tween.EASE_OUT)
	_active_tween.set_trans(Tween.TRANS_LINEAR)
	_active_tween.tween_property(_button_group, "position:x", _shown_x, 0.3)
	_active_tween.tween_callback(func():
		var top_btn := _button_group.get_child(0) as Control
		if top_btn:
			top_btn.grab_focus()
		_warp_cursor_to_bottom_button()
	)

func hide_controls() -> void:
	if not _is_visible:
		return
	# Reject input immediately; the tween below is only the visual slide-out.
	# Waiting for the tween end would leave a ~0.3 s window where the panel
	# still accepted input while visually leaving.
	_is_visible = false
	# Drop focus NOW. If a button keeps focus into the hidden state, the
	# viewport's GUI layer keeps delivering ui_accept to it through the
	# fallback path even while _input ignores it -> restarts loop forever.
	var focused := get_viewport().gui_get_focus_owner()
	if focused and focused.is_inside_tree() and is_ancestor_of(focused):
		focused.release_focus()
	if _gamemode:
		# Back to full click-through so the emulator owns the mouse again.
		mouse_passthrough_polygon = PackedVector2Array()
	if _active_tween and is_instance_valid(_active_tween):
		_active_tween.kill()
		_active_tween = null
	_active_tween = create_tween()
	_active_tween.set_ease(Tween.EASE_IN)
	_active_tween.set_trans(Tween.TRANS_LINEAR)
	_active_tween.tween_property(_button_group, "position:x", _hidden_x, 0.3)
	_active_tween.tween_callback(func():
		_is_visible = false
	)

func _warp_cursor_to_bottom_button() -> void:
	var btn_size := _pause_btn.size
	if btn_size == Vector2.ZERO:
		btn_size = _pause_btn.custom_minimum_size
	if btn_size == Vector2.ZERO:
		btn_size = Vector2(40, 40)

	# DisplayServer.warp_mouse() on a sub-Window interprets coordinates as
	# window-relative, not screen-relative, so pass the button center in this
	# window's canvas coordinates (global_position includes the button
	# column's offset, which is nonzero in the fullscreen GameMode layout).
	var target := Vector2i(_pause_btn.get_global_position() + btn_size / 2.0)
	DisplayServer.warp_mouse(target)

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
	# Auto-hide after every action: this is a summonable quick panel, not a
	# persistent dock. If it stayed visible, game input (A/cross presses, mouse
	# clicks) would keep landing on this always-on-top window and re-trigger
	# the focused button, restarting/killing the game in a loop.
	hide_controls()
