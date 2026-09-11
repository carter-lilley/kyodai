extends Button

var key_data

signal released
signal down

var icon_tex_rect
var badge: M3Badge

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


func set_badge(icon_name: String):
	if badge == null:
		badge = M3Badge.new()
		badge.icon_font = "ControllerIcons"
		add_child(badge)
	badge.icon_name = icon_name
	_position_badge()


func _position_badge():
	if badge == null:
		return
	# Anchor to the icon's drawn rect when there is one (TextureRect with
	# STRETCH_KEEP_ASPECT_CENTERED fills the button but the texture inside
	# is smaller and centered); fall back to the button corner otherwise.
	var anchor_size := size
	var anchor_origin := Vector2.ZERO
	if icon_tex_rect != null and icon_tex_rect.texture != null:
		var tex_size: Vector2 = icon_tex_rect.texture.get_size()
		if tex_size.x > 0 and tex_size.y > 0:
			var tex_scale := min(size.x / tex_size.x, size.y / tex_size.y)
			anchor_size = tex_size * tex_scale
			anchor_origin = (size - anchor_size) / 2.0

	# Badge scales with the anchor (about half the icon height, clamped)
	var s: float = clamp(anchor_size.y * 0.55, M3Units.dp(14), M3Units.dp(22))
	badge.custom_minimum_size = Vector2(s, s)
	badge.size = Vector2(s, s)
	badge.refresh()
	# Mostly inside the icon rect (0.9) so the badge hugs the visible glyph
	# ink instead of hanging off the button's bottom edge
	badge.position = anchor_origin + anchor_size - Vector2(s, s) * 0.9


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
	_position_badge()


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
