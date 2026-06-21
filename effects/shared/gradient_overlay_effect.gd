class_name GradientOverlayEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["base_card", "focus_card"]

var _gradient_texture: ImageTexture = null
var _gradient_hash_cache: Array = []

func _ready():
	super._ready()
	effect_name = "Gradient Overlay"
	effect_id = "gradient_overlay"

func update_settings(settings: Dictionary) -> void:
	super.update_settings(settings)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/gradient_overlay.gdshader")

func _apply_settings() -> void:
	pass  # Offsets: compute_pipeline(). Shader params: _run_pipeline().

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var gradient = _settings.get("gradient")
	var gradient_direction = _settings.get("gradient_direction", 0)
	
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("gradient_direction", gradient_direction)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)
	
	if gradient is Gradient:
		var h: Array = []
		for i in range(gradient.get_point_count()):
			h.append(gradient.get_offset(i))
			h.append(gradient.get_color(i))
		if h != _gradient_hash_cache:
			_gradient_hash_cache = h
			var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
			for i in range(256):
				image.set_pixel(i, 0, gradient.sample(i / 255.0))
			_gradient_texture = ImageTexture.create_from_image(image)
		_set_shader_param("gradient_texture", _gradient_texture)

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
