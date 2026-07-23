@tool
extends PanelContainer

###########################
## SETTINGS
###########################

@export var auto_show:bool = true
@export var animate:bool = true
@export var use_m3_theme:bool = false

# Track controller connection state - keyboard only auto-shows when controller is connected
var _controller_connected: bool = false

@export_file var custom_layout_file
@export var set_tool_tip := true
@export_group("Style")
@export var separation:Vector2i = Vector2i(0,0)
var style_background:StyleBoxFlat = null
@export var background:StyleBoxFlat = null:
	set(new_val):
		style_background = new_val
		background = new_val
	get:
		return style_background
var style_normal:StyleBoxFlat = null
@export var normal:StyleBoxFlat = null:
	set(new_val):
		style_normal = new_val
		normal = new_val
	get:
		return style_normal
var style_hover:StyleBoxFlat = null
@export var hover:StyleBoxFlat = null:
	set(new_val):
		style_hover = new_val
		hover = new_val
	get:
		return style_hover
var style_pressed:StyleBoxFlat = null
@export var pressed:StyleBoxFlat = null:
	set(new_val):
		style_pressed = new_val
		pressed = new_val
	get:
		return style_pressed
var style_special_keys:StyleBoxFlat = null
@export var special_keys:StyleBoxFlat = null:
	set(new_val):
		style_special_keys = new_val
		special_keys = new_val
	get:
		return style_special_keys
var style_focus:StyleBoxFlat = null
@export var focus:StyleBoxFlat = null:
	set(new_val):
		style_focus = new_val
		focus = new_val
	get:
		return style_focus
@export_group("Font")
@export var font:FontFile
@export var font_size:int = 20
@export var font_color_normal:Color = Color(1,1,1)
@export var font_color_hover:Color = Color(1,1,1)
@export var font_color_pressed:Color = Color(1,1,1)
@export var font_color_focus:Color = Color(1,1,1)

###########################
## SIGNALS
###########################

signal layout_changed
signal keyboard_opened(active_line_edit: LineEdit)
signal keyboard_closed()

###########################
## PANEL 
###########################

func _enter_tree():
	if not get_tree().get_root().size_changed.is_connected(size_changed):
		get_tree().get_root().size_changed.connect(size_changed)
	
	# Set up controller detection for keyboard auto-show behavior
	_controller_connected = Input.get_connected_joypads().size() > 0
	if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.connect(_on_joy_connection_changed)
	
	# Connect to viewport focus changes to catch deferred focus (e.g. TabContainer -> LineEdit)
	var viewport = get_viewport()
	if viewport != null:
		if viewport.gui_focus_changed.is_connected(_on_viewport_focus_changed):
			viewport.gui_focus_changed.disconnect(_on_viewport_focus_changed)
		viewport.gui_focus_changed.connect(_on_viewport_focus_changed)
	
	# Ensure keyboard always renders on top of other UI elements
	z_index = 4096
	
	_init_keyboard()
	_apply_keyboard_size()
	call_deferred("refresh_theme")


func _on_joy_connection_changed(device_id: int, connected: bool) -> void:
	_controller_connected = Input.get_connected_joypads().size() > 0

func _on_viewport_focus_changed(control: Control) -> void:
	"""Handle focus changes from the viewport - catches deferred focus (e.g. TabContainer -> LineEdit)."""
	if auto_show == false:
		return
	
	if not _controller_connected:
		return
	
	if control == null:
		return
	
	# Ignore focus changes within the keyboard itself
	if is_focus_within_keyboard(control):
		return
	
	# If focus landed on a new LineEdit/TextEdit, open keyboard for it
	if is_keyboard_focus_object(control):
		# Don't reopen if focus is returning to the LineEdit we just dismissed from
		if control == _dismissed_line_edit:
			return
		
		# If keyboard is already open and focus moved to a different LineEdit, switch to it
		if visible and _active_line_edit != null and control != _active_line_edit:
			_active_line_edit = control
			_previous_focus_object = control
			_passthrough_caret_column = control.caret_column
			keyboard_opened.emit(control)
			return
		
		# If keyboard is visible but has no active LineEdit (e.g. after reset_focus_tracking
		# while animating out), re-associate with the newly focused control
		if visible and _active_line_edit == null:
			_active_line_edit = control
			_previous_focus_object = control
			_passthrough_caret_column = control.caret_column
			_show_keyboard()
			return
		
		# If keyboard is hidden, open it for the newly focused LineEdit
		if not visible:
			_previous_focus_object = control
			_active_line_edit = control
			_passthrough_caret_column = control.caret_column
			_show_keyboard()
			return

	# Focus containment: if the keyboard is visible and focus escaped to a control
	# that is neither inside the keyboard nor a text field we're editing, pull it
	# back so controller/mouse focus cannot leak behind the keyboard.
	if visible and control != null and not is_focus_within_keyboard(control) and not is_keyboard_focus_object(control):
		call_deferred("_pull_focus_back_to_keyboard")

func reconnect_viewport() -> void:
	"""Reconnect the keyboard to the current viewport's focus system.
	Call this after reparenting the keyboard to a different viewport."""
	# Disconnect from old viewport's focus signal
	var old_viewport = get_viewport()
	if old_viewport != null and old_viewport.gui_focus_changed.is_connected(_on_viewport_focus_changed):
		old_viewport.gui_focus_changed.disconnect(_on_viewport_focus_changed)
	
	# Reset focus tracking to ensure keyboard detects focus in new viewport
	reset_focus_tracking()
	# Force a re-check of current focus owner in case something is already focused
	if auto_show:
		var viewport = get_viewport()
		if viewport != null:
			var current_focus = viewport.gui_get_focus_owner()
			if current_focus != null and is_keyboard_focus_object(current_focus):
				_previous_focus_object = current_focus
	
	# Connect to new viewport's focus signal
	var new_viewport = get_viewport()
	if new_viewport != null and not new_viewport.gui_focus_changed.is_connected(_on_viewport_focus_changed):
		new_viewport.gui_focus_changed.connect(_on_viewport_focus_changed)


func _input(event):
	# If keyboard is hidden and user taps/clicks anywhere, clear the dismissal
	# so that if the tap lands on a LineEdit it can reopen. We defer the actual
	# check because _gui_input() (where LineEdit grabs focus) runs AFTER _input().
	if not visible and _dismissed_line_edit != null:
		if (event is InputEventMouseButton and event.pressed) or \
		   (event is InputEventScreenTouch and event.pressed):
			_dismissed_line_edit = null
			_previous_focus_object = null
			call_deferred("_deferred_show_keyboard_check")
			return

	_update_auto_display_on_input(event)
	
	# Dismiss keyboard when clicking or touching outside of it.
	# Use the keyboard's intended (target) position for the check, because
	# during a slide-in animation get_global_rect() is still off-screen.
	if visible and not _is_hiding:
		var click_pos = null
		if event is InputEventMouseButton and event.pressed:
			click_pos = event.position
		elif event is InputEventScreenTouch and event.pressed:
			click_pos = event.position
		
		if click_pos != null:
			var keyboard_top = get_viewport().get_visible_rect().size.y - size.y
			# 1. Touch is inside the keyboard's intended area -> keep open
			if click_pos.y >= keyboard_top:
				return
			
			# 2. Touch is on the active LineEdit -> keep open (tapping the
			#    text field while editing should not dismiss)
			if _active_line_edit != null and _active_line_edit.get_global_rect().has_point(click_pos):
				return
			
			# 3. Check if touch is on a DIFFERENT LineEdit -> switch to it
			var clicked_line_edit = _find_line_edit_at_position(click_pos)
			if clicked_line_edit != null and clicked_line_edit != _active_line_edit:
				# Switch to the new LineEdit without dismissing keyboard
				_active_line_edit = clicked_line_edit
				_previous_focus_object = clicked_line_edit
				_passthrough_caret_column = clicked_line_edit.caret_column
				_dismissed_line_edit = null
				# Emit signal so FocusIndicator updates
				keyboard_opened.emit(clicked_line_edit)
				return
			
			# 4. Otherwise dismiss
			# Don't grab focus back - let the click naturally focus whatever was clicked
			_hide_keyboard()


func size_changed():
	if auto_show and visible:
		_hide_keyboard()


###########################
## INIT
###########################
var KeyboardButton
var KeyListHandler

var layouts = []
var keys = []
var capslock_keys = []
var uppercase = false

var tween_position
var tween_speed = .2

var hide_position = Vector2()

func _init_keyboard():
	if custom_layout_file == null:
		var default_layout = preload("default_layout.gd").new()
		_create_keyboard(default_layout.data)
	else:
		_create_keyboard(_load_json(custom_layout_file))

	# init positioning without animation
	var tmp_anim = animate
	animate = false
	if visible:
		_hide_keyboard()
	elif visible:
		_show_keyboard()
	animate = tmp_anim


func _apply_keyboard_size() -> void:
	"""Scale keyboard height to DP units so it matches the rest of the UI."""
	var keyboard_height := M3Units.dp(300.0)
	offset_top = -keyboard_height
	offset_bottom = 0


###########################
## HIDE/SHOW
###########################

var focus_object = null
var _active_line_edit: LineEdit = null
var _passthrough_caret_column: int = 0

func show():
	_show_keyboard()

func hide():
	_hide_keyboard()

func reset_focus_tracking():
	"""Reset focus tracking so keyboard will reopen on next LineEdit focus."""
	_previous_focus_object = null
	_active_line_edit = null
	_passthrough_caret_column = 0
	_dismissed_line_edit = null
	_is_hiding = false

var released = true
var _previous_focus_object = null

# Track which LineEdit was active when keyboard was dismissed.
# Prevents the keyboard from immediately reopening when focus returns
# to that LineEdit after a deferred focus grab or controller navigation.
var _dismissed_line_edit: Control = null

# True while a hide animation is in progress to prevent duplicate hide calls.
var _is_hiding: bool = false

func _update_auto_display_on_input(event):
	if auto_show == false:
		return
	
	# Only show on-screen keyboard when a controller is connected
	# Desktop users without controllers should use native OS keyboard
	if not _controller_connected:
		return

	# Only open keyboard when LineEdit/TextEdit gets focused
	# Keyboard stays open until manually dismissed
	var focus_object = get_viewport().gui_get_focus_owner()
	if focus_object != _previous_focus_object:
		_previous_focus_object = focus_object
		
		if focus_object != null and is_keyboard_focus_object(focus_object):
			# Don't reopen if focus is returning to the LineEdit we just dismissed from.
			if focus_object == _dismissed_line_edit:
				return
			
			_active_line_edit = focus_object
			_passthrough_caret_column = _active_line_edit.caret_column
			_show_keyboard()

	# Pass-through typing from physical keyboard while virtual keyboard is open
	if visible and _active_line_edit != null and event is InputEventKey and event.pressed:
		if event.keycode == KEY_BACKSPACE:
			if _passthrough_caret_column > 0:
				_active_line_edit.text = _active_line_edit.text.erase(_passthrough_caret_column - 1, 1)
				_passthrough_caret_column -= 1
				_active_line_edit.caret_column = _passthrough_caret_column
				_active_line_edit.text_changed.emit(_active_line_edit.text)
			get_viewport().set_input_as_handled()
			return
		elif event.unicode != 0 and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed:
			var ch = char(event.unicode)
			_active_line_edit.text = _active_line_edit.text.insert(_passthrough_caret_column, ch)
			_passthrough_caret_column += 1
			_active_line_edit.caret_column = _passthrough_caret_column
			_active_line_edit.text_changed.emit(_active_line_edit.text)
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_LEFT:
			_passthrough_caret_column = max(0, _passthrough_caret_column - 1)
			_active_line_edit.caret_column = _passthrough_caret_column
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_RIGHT:
			_passthrough_caret_column = min(_active_line_edit.text.length(), _passthrough_caret_column + 1)
			_active_line_edit.caret_column = _passthrough_caret_column
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_HOME:
			_passthrough_caret_column = 0
			_active_line_edit.caret_column = 0
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_END:
			_passthrough_caret_column = _active_line_edit.text.length()
			_active_line_edit.caret_column = _passthrough_caret_column
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if _active_line_edit is LineEdit:
				_active_line_edit.text_submitted.emit(_active_line_edit.text)
			_dismissed_line_edit = _active_line_edit
			_active_line_edit = null
			_passthrough_caret_column = 0
			_hide_keyboard()
			get_viewport().set_input_as_handled()
			return
	
	# Hide keyboard on ui_cancel action (controller B button)
	# Only consume if the keyboard is actually visible; otherwise let the event propagate
	if visible and event.is_action_pressed("ui_cancel"):
		# Mark as dismissed so auto-show won't reopen when focus returns
		if _active_line_edit != null:
			_dismissed_line_edit = _active_line_edit
		# Return focus to the LineEdit before hiding
		if _active_line_edit != null:
			_active_line_edit.grab_focus()
		_hide_keyboard()
		get_viewport().set_input_as_handled()
	
	# Handle ui_start (Start/Enter button) same as virtual keyboard Enter
	if event.is_action_pressed("ui_start"):
		if _active_line_edit is LineEdit:
			_active_line_edit.text_submitted.emit(_active_line_edit.text)
		# Mark as dismissed so auto-show won't reopen when focus returns
		if _active_line_edit != null:
			_dismissed_line_edit = _active_line_edit
		# Return focus and hide keyboard
		if _active_line_edit != null:
			_active_line_edit.grab_focus()
		_hide_keyboard()


func _hide_keyboard(key_data=null):
	# Don't hide if already hidden or already hiding - prevents animation toggling visibility
	if not visible or _is_hiding:
		return
	
	_is_hiding = true
	
	# Emit signal BEFORE clearing active line edit so listeners know which control to return to
	keyboard_closed.emit()
	
	# Remember which LineEdit was active so we can suppress auto-reopen when
	# focus returns to it after dismissal.
	if _active_line_edit != null:
		_dismissed_line_edit = _active_line_edit
	_active_line_edit = null
	if animate:
		var viewport = get_viewport()
		if viewport != null:
			var new_y_pos = viewport.get_visible_rect().size.y + 10
			animate_position(Vector2(position.x, new_y_pos), true)
		else:
			change_visibility(false)
	else:
		change_visibility(false)


func _on_hide_keyboard_clicked(key_data=null):
	"""Handle click on hide keyboard button - return focus and hide."""
	var line_edit_to_focus = _active_line_edit
	_hide_keyboard()
	# Defer focus grab to ensure it happens after keyboard starts hiding
	if line_edit_to_focus != null:
		call_deferred("_deferred_focus_grab", line_edit_to_focus)


func _deferred_focus_grab(control: Control):
	"""Grab focus on a control after a frame delay.
	Only steals focus if nothing else has taken it (e.g. empty-space click).
	If another interactive element grabbed focus from the click, respect it."""
	if not is_instance_valid(control):
		return
	var current_focus = get_viewport().gui_get_focus_owner()
	# Only grab focus if nothing currently has focus, or focus is still
	# stuck on a hidden keyboard key (not a real UI element)
	if current_focus == null or is_focus_within_keyboard(current_focus):
		control.grab_focus()


func _pull_focus_back_to_keyboard() -> void:
	"""Pull focus back to the keyboard if it leaked while the keyboard is open."""
	if not visible or _is_hiding or keys.size() == 0:
		return
	var current_focus = get_viewport().gui_get_focus_owner()
	if current_focus == null or (not is_focus_within_keyboard(current_focus) and not is_keyboard_focus_object(current_focus)):
		keys[0].grab_focus()


func _deferred_show_keyboard_check():
	"""Check if a LineEdit has focus after a touch/click event and open keyboard.
	Called deferred so LineEdit's _gui_input() has already grabbed focus."""
	var focus_object = get_viewport().gui_get_focus_owner()
	if focus_object != null and is_keyboard_focus_object(focus_object):
		_active_line_edit = focus_object
		_passthrough_caret_column = _active_line_edit.caret_column
		_show_keyboard()


func _show_keyboard(key_data=null):
	var viewport = get_viewport()
	if viewport == null:
		# Keyboard is not in the scene tree yet (e.g. during dual-screen reparenting)
		return
	
	_is_hiding = false
	_dismissed_line_edit = null
	var was_hidden = not visible
	# Ensure keyboard renders on top of other UI elements
	move_to_front()
	refresh_theme()
	change_visibility(true)
	# Emit signal BEFORE grabbing focus on keys so listeners can prepare
	if _active_line_edit != null:
		keyboard_opened.emit(_active_line_edit)
	if animate:
		var new_y_pos = viewport.get_visible_rect().size.y - size.y
		animate_position(Vector2(position.x, new_y_pos))
	# Always grab focus on first key when showing keyboard
	if keys.size() > 0:
		keys[0].grab_focus()


func animate_position(new_position, trigger_visibility:bool=false):
	# Kill any existing position tween to prevent conflicting visibility changes
	if tween_position and tween_position.is_valid():
		tween_position.kill()
	
	tween_position = get_tree().create_tween()
	if trigger_visibility:
		# Use a callable that evaluates visibility at finish time, not connect time
		tween_position.finished.connect(func(): change_visibility(not visible))
	tween_position.tween_property(
		self,"position",
		Vector2(new_position),
		tween_speed
	).set_trans(Tween.TRANS_SINE)


func change_visibility(value):
	if value:
		super.show()
	else:
		_set_caps_lock(false)
		super.hide()
	visibility_changed.emit()


###########################
##  KEY LAYOUT
###########################

var prev_prev_layout = null
var previous_layout = null
var current_layout = null

func set_active_layout_by_name(name):
	for layout in layouts:
		if layout.get_meta("layout_name") == str(name):
			_show_layout(layout)
		else:
			_hide_layout(layout)


func _show_layout(layout):
	layout.show()
	current_layout = layout


func _hide_layout(layout):
	layout.hide()


func _switch_layout(key_data):
	prev_prev_layout = previous_layout
	previous_layout = current_layout
	layout_changed.emit(key_data.get("layout-name"))

	for layout in layouts:
		_hide_layout(layout)

	if key_data.get("layout-name") == "PREVIOUS-LAYOUT":
		if prev_prev_layout != null:
			_show_layout(prev_prev_layout)
			return

	for layout in layouts:
		if layout.get_meta("layout_name") == key_data.get("layout-name"):
			_show_layout(layout)
			return

	_set_caps_lock(false)


###########################
## KEY EVENTS
###########################

func _set_caps_lock(value: bool):
	uppercase = value
	for key in capslock_keys:
		if value:
			if key.get_draw_mode() != BaseButton.DRAW_PRESSED:
				key.button_pressed = !key.button_pressed
		else:
			if key.get_draw_mode() == BaseButton.DRAW_PRESSED:
				key.button_pressed = !key.button_pressed

	for key in keys:
		key.change_uppercase(value)


func _trigger_uppercase(key_data):
	uppercase = !uppercase
	_set_caps_lock(uppercase)


func _key_released(key_data):
	if key_data.has("output"):
		var key_value = key_data.get("output")

		###########################
		## SEND TEXT TO ACTIVE LINEEDIT
		###########################
		
		if _active_line_edit != null:
			# Handle special keys
			if key_value == "Backspace":
				var text = _active_line_edit.text
				if text.length() > 0:
					_active_line_edit.text = text.substr(0, text.length() - 1)
					_active_line_edit.caret_column = _active_line_edit.text.length()
					_active_line_edit.text_changed.emit(_active_line_edit.text)
			elif key_value == "Return" or key_value == "Enter":
				# Trigger submit/confirmation on the LineEdit
				if _active_line_edit is LineEdit:
					_active_line_edit.text_submitted.emit(_active_line_edit.text)
				# Mark as dismissed so auto-show won't reopen when focus returns
				if _active_line_edit != null:
					_dismissed_line_edit = _active_line_edit
				# Return focus and hide keyboard
				if _active_line_edit != null:
					_active_line_edit.grab_focus()
				_hide_keyboard()
				return  # Don't process caps lock after hiding
			elif key_value == "Space":
				_active_line_edit.text += " "
				_active_line_edit.caret_column = _active_line_edit.text.length()
				_active_line_edit.text_changed.emit(_active_line_edit.text)
			else:
				# Regular character - convert to lowercase if not uppercase
				if !uppercase and KeyListHandler.has_lowercase(key_value):
					key_value = key_value.to_lower()
				_active_line_edit.text += key_value
				_active_line_edit.caret_column = _active_line_edit.text.length()
				_active_line_edit.text_changed.emit(_active_line_edit.text)

		###########################
		## DISABLE CAPSLOCK AFTER 
		###########################
		_set_caps_lock(false)


###########################
## CONSTRUCT KEYBOARD
###########################

func _set_key_style(style_name:String, key: Control, style:StyleBoxFlat):
	if style != null:
		key.add_theme_stylebox_override(style_name, style)


func _build_m3_styles() -> void:
	if not use_m3_theme:
		print("[OnscreenKeyboard] _build_m3_styles skipped: use_m3_theme is false")
		return
	if not ResourceLoader.exists("res://addons/m3/m3_theme.gd"):
		push_warning("M3Theme not found; cannot apply M3 styles to keyboard")
		return

	var surf = M3Theme.get_surface()
	var surf_var = M3Theme.get_surface_variant()
	var on_surf = M3Theme.get_on_surface()
	var prim = M3Theme.get_primary()
	var on_prim = M3Theme.get_on_primary()
	var prim_cont = M3Theme.get_primary_container()
	var on_prim_cont = M3Theme.get_on_primary_container()
	var outl = M3Theme.get_outline()
	var radius = M3Theme.RADIUS_SMALL
	var hover_opacity := 0.24

	style_background = M3Theme.make_flat(surf, radius)
	style_normal = M3Theme.make_flat(surf_var, radius, 1, outl)
	style_hover = M3Theme.make_flat(M3Theme.state_overlay(surf_var, on_surf, hover_opacity), radius, 1, outl)
	style_focus = M3Theme.make_flat(prim_cont, radius, 4, prim)
	style_pressed = M3Theme.make_flat(prim, radius, 0, Color.TRANSPARENT)
	style_special_keys = M3Theme.make_flat(M3Theme.state_overlay(surf_var, on_surf, hover_opacity), radius, 1, outl)

	font_color_normal = on_surf
	font_color_hover = on_surf
	font_color_pressed = on_prim
	font_color_focus = on_prim_cont

	print("[OnscreenKeyboard] M3 styles rebuilt. dark_mode=", M3Theme.is_dark_mode, " primary=", prim, " focus_border=4")


func refresh_theme() -> void:
	_build_m3_styles()

	if style_background != null:
		add_theme_stylebox_override('panel', style_background)
		for layout in layouts:
			if is_instance_valid(layout):
				layout.add_theme_stylebox_override('panel', style_background)

	for key in keys:
		if not is_instance_valid(key):
			continue
		var key_type = key.key_data.get("type", "")
		var is_special: bool = key_type in ["switch-layout", "special", "special-shift", "special-hide-keyboard"]
		var normal_style = style_special_keys if is_special else style_normal
		_set_key_style("normal", key, normal_style)
		_set_key_style("hover", key, style_hover)
		_set_key_style("pressed", key, style_pressed)
		_set_key_style("focus", key, style_focus)
		if font_color_normal != null:
			key.set('theme_override_colors/font_color', font_color_normal)
			key.set('theme_override_colors/font_hover_color', font_color_hover)
			key.set('theme_override_colors/font_pressed_color', font_color_pressed)
			key.set('theme_override_colors/font_focus_color', font_color_focus)
			key.set('theme_override_colors/font_disabled_color', font_color_normal)
		key.set('theme_override_font_sizes/font_size', M3Units.dpi(font_size))


func _create_keyboard(layout_data):
	if layout_data == null:
		push_error("ERROR. No layout file found")
		return

	_build_m3_styles()

	KeyListHandler = preload("keylist.gd").new()
	KeyboardButton = preload("keyboard_button.gd")

	var ICON_DELETE = preload("icons/delete.png")
	var ICON_SHIFT = preload("icons/shift.png")
	var ICON_LEFT = preload("icons/left.png")
	var ICON_RIGHT = preload("icons/right.png")
	var ICON_HIDE = preload("icons/hide.png")
	var ICON_ENTER = preload("icons/enter.png")

	var data = layout_data

	if style_background != null:
		add_theme_stylebox_override('panel', style_background)

	var index = 0
	for layout in data.get("layouts"):

		var layout_container = PanelContainer.new()

		if style_background != null:
			layout_container.add_theme_stylebox_override('panel', style_background)

		# SHOW FIRST LAYOUT ON DEFAULT
		if index > 0:
			layout_container.hide()
		else:
			current_layout = layout_container

		var layout_name = layout.get("name")
		layout_container.set_meta("layout_name", layout_name)
		if set_tool_tip:
			layout_container.tooltip_text = layout_name
		layouts.push_back(layout_container)
		add_child(layout_container)

		var base_vbox = VBoxContainer.new()
		base_vbox.size_flags_horizontal = SIZE_EXPAND_FILL
		base_vbox.size_flags_vertical = SIZE_EXPAND_FILL
		# theme override for spacing
		base_vbox.add_theme_constant_override("separation", separation.y)

		for row in layout.get("rows"):

			var key_row = HBoxContainer.new()
			key_row.size_flags_horizontal = SIZE_EXPAND_FILL
			key_row.size_flags_vertical = SIZE_EXPAND_FILL
			key_row.add_theme_constant_override("separation", separation.x)

			for key in row.get("keys"):
				var new_key = KeyboardButton.new(key)

				_set_key_style("normal",new_key, style_normal)
				_set_key_style("hover",new_key, style_hover)
				_set_key_style("pressed",new_key, style_pressed)
				_set_key_style("focus",new_key, style_focus)

				new_key.set('theme_override_font_sizes/font_size', M3Units.dpi(font_size))
				if font != null:
					new_key.set('theme_override_fonts/font', font)
				if font_color_normal != null:
					new_key.set('theme_override_colors/font_color', font_color_normal)
					new_key.set('theme_override_colors/font_hover_color', font_color_hover)
					new_key.set('theme_override_colors/font_pressed_color', font_color_pressed)
					new_key.set('theme_override_colors/font_focus_color', font_color_focus)
					new_key.set('theme_override_colors/font_disabled_color', font_color_normal)

				new_key.released.connect(_key_released)

				if key.has("type"):
					if key.get("type") == "switch-layout":
						new_key.released.connect(_switch_layout)
						_set_key_style("normal",new_key, style_special_keys)
					elif key.get("type") == "special":
						_set_key_style("normal",new_key, style_special_keys)
					elif key.get("type") == "special-shift":
						new_key.released.connect(_trigger_uppercase)
						new_key.toggle_mode = true
						capslock_keys.push_back(new_key)
						_set_key_style("normal",new_key, style_special_keys)
					elif key.get("type") == "special-hide-keyboard":
						new_key.released.connect(_on_hide_keyboard_clicked)
						_set_key_style("normal",new_key, style_special_keys)

				# SET ICONS
				if key.has("display-icon"):
					var icon_data = str(key.get("display-icon")).split(":")
					# PREDEFINED
					if str(icon_data[0])=="PREDEFINED":
						if str(icon_data[1])=="DELETE":
							new_key.set_icon(ICON_DELETE)
						elif str(icon_data[1])=="SHIFT":
							new_key.set_icon(ICON_SHIFT)
						elif str(icon_data[1])=="LEFT":
							new_key.set_icon(ICON_LEFT)
						elif str(icon_data[1])=="RIGHT":
							new_key.set_icon(ICON_RIGHT)
						elif str(icon_data[1])=="HIDE":
							new_key.set_icon(ICON_HIDE)
						elif str(icon_data[1])=="ENTER":
							new_key.set_icon(ICON_ENTER)
					# CUSTOM
					if str(icon_data[0])=="res":
						var texture = load(key.get("display-icon"))
						new_key.set_icon(texture)

					if font_color_normal != null:
						new_key.set_icon_color(font_color_normal)

				key_row.add_child(new_key)
				keys.push_back(new_key)

			base_vbox.add_child(key_row)

		layout_container.add_child(base_vbox)
		index+=1


###########################
## LOAD SETTINGS
###########################

func _load_json(file_path) -> Variant:
	var json = JSON.new()
	var json_string = _load_file(file_path)
	var error = json.parse(json_string)
	if error == OK:
		var data_received = json.data
		#        print(data_received)
		if typeof(data_received) == TYPE_DICTIONARY:
			return data_received
		else:
			return {"msg": "unexpected data => expected DICTIONARY"}
	else:
		push_error("JSON Parse Error: " + json.get_error_message() + " in " + json_string + " at line " + str(json.get_error_line()))
		return {"msg":json.get_error_message()}


func _load_file(file_path):
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Error loading File: " + file_path)

	var content = file.get_as_text()
	file.close()
	return content


###########################
## HELPER
###########################

func is_keyboard_focus_object_complete_on_enter(focus_object):
	if focus_object is LineEdit:
		return true
	return false

func is_keyboard_focus_object(focus_object):
	if focus_object is LineEdit or focus_object is TextEdit:
		if focus_object.has_method("is_virtual_keyboard_enabled"):
			return focus_object.is_virtual_keyboard_enabled()
		return true
	return false

func is_focus_within_keyboard(focus_object):
	# Check if the focused object is a child of this keyboard
	if focus_object == null:
		return false
	var parent = focus_object.get_parent()
	while parent != null:
		if parent == self:
			return true
		parent = parent.get_parent()
	return false

## Public getter for the LineEdit this keyboard is currently editing.
func get_active_line_edit() -> LineEdit:
	return _active_line_edit

## Public getter for the control that had focus before this keyboard opened.
func get_previous_focus_object() -> Control:
	return _previous_focus_object

func _find_line_edit_at_position(pos: Vector2) -> LineEdit:
	"""Find a LineEdit at the given screen position."""
	# Search all LineEdits in the scene tree
	return _find_line_edit_recursive(get_tree().root, pos)

func _find_line_edit_recursive(node: Node, pos: Vector2) -> LineEdit:
	"""Recursively search for a LineEdit at the given position."""
	if node == null:
		return null
	
	# Skip the keyboard itself and its children
	if node == self:
		return null
	
	# Check if this node is a LineEdit and contains the point
	if node is LineEdit:
		var control = node as Control
		if control.get_global_rect().has_point(pos) and control.visible:
			if not node.has_method("is_virtual_keyboard_enabled") or node.is_virtual_keyboard_enabled():
				return control
	
	# Check children recursively
	for child in node.get_children():
		var result = _find_line_edit_recursive(child, pos)
		if result != null:
			return result
	
	return null
