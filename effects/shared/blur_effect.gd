class_name BlurEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _ready():
	super._ready()
	effect_name = "Blur"
	effect_id = "blur"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/blur.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var blur_strength = _settings.get("blur_strength", 4.0)
	var blur_samples = _settings.get("blur_samples", 8)
	
	var cache = media_container.pipeline_cache
	
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	_set_shader_param("uv_transform_scale", cache.get("uv_transform_scale", Vector2.ONE))
	_set_shader_param("uv_transform_offset", cache.get("uv_transform_offset", Vector2.ZERO))
	_set_shader_param("blur_strength", blur_strength)
	_set_shader_param("blur_samples", float(blur_samples))
	_set_shader_param("game_texture", media_container.texture)

func set_game_texture(texture: Texture2D) -> void:
	if media_container:
		media_container.texture = texture
		_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var strength_var = SettingsVar.new(Type.FLOAT, 4.0, State.ENABLED, "Blur Strength", "Texel step size for blur", 0.0, 32.0, 0.5)
	strength_var.property_name = "blur_strength"
	schema.append(strength_var)
	
	var samples_var = SettingsVar.new(Type.INT, 8, State.ENABLED, "Blur Quality", "Sample steps per axis (higher = smoother but slower)", 1, 24, 1)
	samples_var.property_name = "blur_samples"
	schema.append(samples_var)
	
	return schema
