@tool
extends PanelContainer

###########################
## SETTINGS
###########################

@export var auto_show:bool = true
@export var animate:bool = true

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
@export_group("Font")
@export var font:FontFile
@export var font_size:int = 20
@export var font_color_normal:Color = Color(1,1,1)
@export var font_color_hover:Color = Color(1,1,1)
@export var font_color_pressed:Color = Color(1,1,1)

###########################
## SIGNALS
###########################

signal layout_changed

###########################
## PANEL 
###########################

func _enter_tree():
	if not get_tree().get_root().size_changed.is_connected(size_changed):
		get_tree().get_root().size_changed.connect(size_changed)
	_init_keyboard()

func reconnect_viewport() -> void:
	"""Reconnect the keyboard to the current viewport's focus system.
	Call this after reparenting the keyboard to a different viewport."""
	print("[KEYBOARD DEBUG] reconnect_viewport called")
	# Reset focus tracking to ensure keyboard detects focus in new viewport
	reset_focus_tracking()
	# Force a re-check of current focus owner in case something is already focused
	if auto_show:
		var current_focus = get_viewport().gui_get_focus_owner()
		if current_focus != null and is_keyboard_focus_object(current_focus):
			print("[KEYBOARD DEBUG] Found focused LineEdit after reconnect: ", current_focus)
			_previous_focus_object = current_focus
			_active_line_edit = current_focus
			_show_keyboard()

#func _exit_tree():
#    pass

#func _process(delta):
#    pass

func _input(event):
	_update_auto_display_on_input(event)


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


###########################
## HIDE/SHOW
###########################

var focus_object = null
var _active_line_edit: LineEdit = null

func show():
	_show_keyboard()

func hide():
	_hide_keyboard()

func reset_focus_tracking():
	"""Reset focus tracking so keyboard will reopen on next LineEdit focus."""
	print("[KEYBOARD DEBUG] reset_focus_tracking called")
	_previous_focus_object = null
	_active_line_edit = null

var released = true
var _previous_focus_object = null

func _update_auto_display_on_input(event):
	if auto_show == false:
		return

	# Only open keyboard when LineEdit/TextEdit gets focused
	# Keyboard stays open until manually dismissed
	var focus_object = get_viewport().gui_get_focus_owner()
	if focus_object != _previous_focus_object:
		print("[KEYBOARD DEBUG] Focus changed from ", _previous_focus_object, " to ", focus_object)
		_previous_focus_object = focus_object
		if focus_object != null and is_keyboard_focus_object(focus_object):
			print("[KEYBOARD DEBUG] Opening keyboard for LineEdit: ", focus_object)
			_active_line_edit = focus_object
			_show_keyboard()

	# Hide keyboard on Enter key (completes input)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER:
			_active_line_edit = null
			_hide_keyboard()
	
	# Hide keyboard on ui_cancel action (controller B button)
	if event.is_action_pressed("ui_cancel"):
		# Return focus to the LineEdit before hiding
		if _active_line_edit != null:
			_active_line_edit.grab_focus()
		_hide_keyboard()
	
	# Handle ui_start (Start/Enter button) same as virtual keyboard Enter
	if event.is_action_pressed("ui_start"):
		print("[KEYBOARD DEBUG] ui_start pressed")
		if _active_line_edit is LineEdit:
			print("[KEYBOARD DEBUG] Emitting text_submitted for: ", _active_line_edit)
			_active_line_edit.text_submitted.emit(_active_line_edit.text)
		# Return focus and hide keyboard
		if _active_line_edit != null:
			print("[KEYBOARD DEBUG] Returning focus to LineEdit")
			_active_line_edit.grab_focus()
		_hide_keyboard()


func _hide_keyboard(key_data=null):
	# Don't hide if already hidden - prevents animation toggling visibility
	if not visible:
		return
	
	print("[KEYBOARD DEBUG] Hiding keyboard, was active_line_edit: ", _active_line_edit)
	# Set _previous_focus_object to the LineEdit before clearing so auto-show
	# doesn't reopen keyboard when focus returns to it
	if _active_line_edit != null:
		_previous_focus_object = _active_line_edit
	_active_line_edit = null
	if animate:
		var new_y_pos = get_viewport().get_visible_rect().size.y + 10
		animate_position(Vector2(position.x, new_y_pos), true)
	else:
		change_visibility(false)
	print("[KEYBOARD DEBUG] Keyboard hidden, visible: ", visible)


func _on_hide_keyboard_clicked(key_data=null):
	"""Handle click on hide keyboard button - return focus and hide."""
	var line_edit_to_focus = _active_line_edit
	_hide_keyboard()
	# Defer focus grab to ensure it happens after keyboard starts hiding
	if line_edit_to_focus != null:
		call_deferred("_deferred_focus_grab", line_edit_to_focus)


func _deferred_focus_grab(control: Control):
	"""Grab focus on a control after a frame delay."""
	if is_instance_valid(control):
		control.grab_focus()


func _show_keyboard(key_data=null):
	print("[KEYBOARD DEBUG] _show_keyboard called, visible: ", visible)
	var was_hidden = not visible
	change_visibility(true)
	if animate:
		var new_y_pos = get_viewport().get_visible_rect().size.y - size.y
		animate_position(Vector2(position.x, new_y_pos))
	# Always grab focus on first key when showing keyboard
	if keys.size() > 0:
		print("[KEYBOARD DEBUG] Grabbing focus on first key")
		keys[0].grab_focus()
	print("[KEYBOARD DEBUG] _show_keyboard complete, visible: ", visible)


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
				print("[KEYBOARD DEBUG] Virtual Enter key pressed")
				# Trigger submit/confirmation on the LineEdit
				if _active_line_edit is LineEdit:
					print("[KEYBOARD DEBUG] Emitting text_submitted for: ", _active_line_edit)
					_active_line_edit.text_submitted.emit(_active_line_edit.text)
				# Return focus and hide keyboard
				if _active_line_edit != null:
					print("[KEYBOARD DEBUG] Returning focus to LineEdit")
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


func _create_keyboard(layout_data):
	if layout_data == null:
		print("ERROR. No layout file found")
		return

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

				new_key.set('theme_override_font_sizes/font_size', font_size)
				if font != null:
					new_key.set('theme_override_fonts/font', font)
				if font_color_normal != null:
					new_key.set('theme_override_colors/font_color', font_color_normal)
					new_key.set('theme_override_colors/font_hover_color', font_color_hover)
					new_key.set('theme_override_colors/font_pressed_color', font_color_pressed)
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
		print("JSON Parse Error: ", json.get_error_message(), " in ", json_string, " at line ", json.get_error_line())
		return {"msg":json.get_error_message()}


func _load_file(file_path):
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		print("Error loading File. Error: ")

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
