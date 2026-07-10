extends Button

var key_data

signal released
signal down

var icon_tex_rect

func _enter_tree():
	pass

func _ready():
	pass # Replace with function body.

func _init(_key_data):
	key_data = _key_data
	item_rect_changed.connect(_on_item_rect_changed)

	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL

	focus_mode = FOCUS_ALL

	if key_data.has("display"):
		text = key_data.get("display")

	if key_data.has("stretch-ratio"):
		size_flags_stretch_ratio = key_data.get("stretch-ratio")


func set_icon_color(color):
	if icon_tex_rect != null:
		icon_tex_rect.modulate = color


func set_icon(texture):
	icon_tex_rect = TextureRect.new()
	icon_tex_rect.ignore_texture_size = true
	icon_tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_tex_rect.texture = texture
	add_child(icon_tex_rect)


func change_uppercase(value):
	if value:
		if key_data.has("display-uppercase"):
			text = key_data.get("display-uppercase")
	else:
		if key_data.has("display"):
			text = key_data.get("display")


func _on_item_rect_changed():
	if icon_tex_rect != null:
		icon_tex_rect.size = size


var _is_pressed: bool = false

func _gui_input(event):
	if event.is_action_pressed("ui_accept"):
		_on_button_down(true)
		_on_button_up()
		accept_event()
	elif event is InputEventScreenTouch:
		# If touch is being emulated as mouse, let the emulated mouse event handle it
		# to avoid double-triggering feedback.
		if ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch"):
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

func _on_button_up():
	released.emit(key_data)
	# Don't release focus - keep it for controller navigation


func _on_button_down(trigger_feedback: bool = false):
	down.emit(key_data)
	if trigger_feedback:
		_trigger_haptic_feedback()


func _trigger_haptic_feedback() -> void:
	if SystemManager.platform.is_android():
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin:
			plugin.call("vibrateDevice", 30)
	elif Input.get_connected_joypads().size() > 0:
		Input.start_joy_vibration(0, 0.1, 0.05, 0.08)
