class_name BorderEffect
extends CardEffect

var _gradient_texture: ImageTexture = null

func _ready():
	super._ready()
	effect_name = "Border"
	effect_id = "border"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/border.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not _card_state:
		return
	
	var border_size = _settings.get("border_size", 0.05)
	var border_fade_in = _settings.get("border_fade_in", 0.0)
	var border_gradient = _settings.get("border_gradient")
	var gradient_direction = _settings.get("gradient_direction", 0)
	
	var border_pixels = border_size * _card_state.base_width * 2.0 * _card_state.zoom_level
	var fade_in_pixels = border_fade_in * _card_state.base_width * 2.0 * _card_state.zoom_level
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_pixels", _card_state.corner_radius * _card_state.zoom_level)
	_set_shader_param("border_width_pixels", border_pixels)
	_set_shader_param("border_fade_in_pixels", fade_in_pixels)
	_set_shader_param("gradient_direction", gradient_direction)
	
	if border_gradient is Gradient:
		_gradient_texture = _gradient_to_texture(border_gradient)
		_set_shader_param("gradient_texture", _gradient_texture)
		_set_shader_param("use_gradient", true)
	else:
		var border_color = _settings.get("border_color", Color.WHITE)
		_set_shader_param("border_color", border_color)
		_set_shader_param("use_gradient", false)

func _gradient_to_texture(gradient: Gradient) -> ImageTexture:
	var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in range(256):
		var color = gradient.sample(i / 255.0)
		image.set_pixel(i, 0, color)
	return ImageTexture.create_from_image(image)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var size_var = SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Border Size", "", 0.01, 0.5, 0.01)
	size_var.property_name = "border_size"
	schema.append(size_var)
	
	var fade_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Border Fade In", "", 0.0, 0.5, 0.01)
	fade_var.property_name = "border_fade_in"
	schema.append(fade_var)
	
	var gradient = Gradient.new()
	gradient.add_point(0.0, Color.WHITE)
	gradient.add_point(1.0, Color.WHITE)
	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Border Gradient")
	gradient_var.property_name = "border_gradient"
	schema.append(gradient_var)
	
	var direction_var = SettingsVar.new(Type.ENUM, 0, State.ENABLED, "Gradient Direction", "", 0.0, 0.0, 0.0, ["Horizontal", "Vertical", "Diagonal"])
	direction_var.property_name = "gradient_direction"
	schema.append(direction_var)
	
	return schema
