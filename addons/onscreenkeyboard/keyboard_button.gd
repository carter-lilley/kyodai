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
	if event is InputEventMouseButton:
		if event.pressed and not _is_pressed:
			_is_pressed = true
			_on_button_down()
			accept_event()
		elif not event.pressed and _is_pressed:
			_is_pressed = false
			_on_button_up()
			accept_event()

func _on_button_up():
	released.emit(key_data)
	# Don't release focus - keep it for controller navigation


func _on_button_down():
	down.emit(key_data)
