class_name GradientOverlayEffect
extends EffectBase

var _gradient_texture: ImageTexture = null

func _ready():
	super._ready()
	effect_name = "Gradient Overlay"
	effect_id = "gradient_overlay"

func update_settings(settings: Dictionary) -> void:
	visible = true
	queue_redraw()
	super.update_settings(settings)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/gradient_overlay.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not _container_state:
		return
	
	var gradient = _settings.get("gradient")
	var gradient_direction = _settings.get("gradient_direction", 0)
	
	# Pass card dimensions and shape parameters for SDF clipping
	_set_shader_param("card_size", _container_state.container_size)
	_set_shader_param("corner_radius_pixels", _container_state.corner_radius_pixels)
	_set_shader_param("gradient_direction", gradient_direction)
	
	if gradient is Gradient:
		_gradient_texture = _gradient_to_texture(gradient)
		_set_shader_param("gradient_texture", _gradient_texture)

func _gradient_to_texture(gradient: Gradient) -> ImageTexture:
	var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	
	for i in range(256):
		var t = i / 255.0
		var color = gradient.sample(t)
		image.set_pixel(i, 0, color)
	
	return ImageTexture.create_from_image(image)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color.WHITE, Color.BLACK]
	
	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Gradient")
	gradient_var.property_name = "gradient"
	schema.append(gradient_var)
	
	var direction_var = SettingsVar.new(Type.ENUM, 0, State.ENABLED, "Gradient Direction", "", 0.0, 0.0, 0.0, ["Horizontal", "Vertical", "Diagonal"])
	direction_var.property_name = "gradient_direction"
	schema.append(direction_var)
	
	return schema
