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
# Set once dismiss begins: the window frees itself, so every subsequent call
# (re-summon chord, auto-dismiss, cleanup) is a no-op.
var _dismissing := false

# GameMode (gamescope) layout: the palette is a plain top-level fullscreen
# menu window (gamescope presents one focused app window at a time), while on
# desktop it is a compact always-on-top overlay sized to the button column.
var _gamemode := false
var _column_size := Vector2.ZERO

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

## Initializes the pause/play button from the manager's authoritative pause
## state. The window is recreated on every summon, so this must be re-applied
## each time or a paused session would show the wrong icon.
func set_paused(paused: bool) -> void:
	_is_paused = paused
	if _pause_btn and is_instance_valid(_pause_btn):
		_pause_btn.icon_name = "play" if _is_paused else "pause"

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
	size = screen_size if _gamemode else Vector2i(_column_size)

	if _gamemode:
		# In gamescope the palette is simply a new top-level fullscreen window:
		# gamescope presents one focused app window at a time and does not
		# alpha-blend between windows, so transparency and always-on-top are
		# meaningless there — opaque window, grab focus, done.
		transparent = false
		transparent_bg = false
		always_on_top = false
		position = DisplayServer.screen_get_position()
		# The scene anchors the button group full-rect (correct for the compact
		# desktop window, where window == column). Here it is a menu screen, so
		# re-anchor the group as a fixed column centered on the screen.
		_button_group.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_button_group.size = _column_size
		_button_group.position = (Vector2(screen_size) - _column_size) / 2.0
		# Draw our own scrim so the menu screen has an intentional background.
		var scrim := ColorRect.new()
		scrim.color = Color(0.02, 0.02, 0.04, 0.92)
		scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
		scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(scrim)
		move_child(scrim, 0)
	else:
		# Desktop: compact always-on-top overlay window. popup() will try to
		# make the window transient, but X11 rejects always-on-top windows
		# becoming transient. Disable always_on_top temporarily, popup to
		# create the OS window, clear transient, then restore always_on_top.
		always_on_top = false
		popup()
		transient = false
		always_on_top = true
		position = Vector2i(16, screen_size.y - size.y - 16)

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

	# Created per summon: play the entrance immediately.
	_input_locked_until_msec = Time.get_ticks_msec() + SUMMON_INPUT_LOCKOUT_MSEC
	SystemManager.audio.play_sfx("click_04")
	# Brief haptic blip so the summon has physical feedback on the pad.
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, 0.45, 0.55, 0.12)
	if _gamemode:
		# Gamescope only presents the focused app window; a mapped window that
		# never takes focus stays invisible. Steal focus on every summon.
		grab_focus()
	else:
		move_to_foreground()
	var top_btn := _button_group.get_child(0) as Control
	if top_btn:
		top_btn.grab_focus()
	_warp_cursor_to_bottom_button()



func _input(event: InputEvent) -> void:
	if _dismissing:
		return

	# Summon lockout: swallow events so they can't reach the freshly-focused
	# button through the viewport's GUI router either. A held or queued press
	# (chord release, game input already in flight) must not instantly
	# activate the freshly-focused Pause button and vanish the panel.
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
	if _dismissing:
		return
	visible = true
	always_on_top = true
	if _gamemode:
		grab_focus()
	else:
		move_to_foreground()

## Dismisses the palette by freeing the window. The manager recreates the
## window on the next summon (create-on-summon), so there is no hidden state
## to return to; in gamemode the manager re-raises the game on tree exit.
func hide_controls() -> void:
	if _dismissing:
		return
	# Reject input immediately; freeing is deferred to end of frame, so
	# without the guard late events could still reach the buttons.
	_dismissing = true
	# Drop focus NOW. If a button keeps focus into the teardown, the
	# viewport's GUI layer keeps delivering ui_accept to it through the
	# fallback path even while _input ignores it -> restarts loop forever.
	var focused := get_viewport().gui_get_focus_owner()
	if focused and focused.is_inside_tree() and is_ancestor_of(focused):
		focused.release_focus()
	queue_free()

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
