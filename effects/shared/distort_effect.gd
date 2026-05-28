class_name DistortEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _ready():
	super._ready()
	effect_name = "Distort"
	effect_id = "distort"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/distort.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var distortion = _settings.get("distortion", 0.5)
	var opacity = _settings.get("opacity", 1.0)
	
	var cache = media_container.pipeline_cache
	
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("border_inset_ratio", media_container.border_inset_ratio)
	_set_shader_param("distortion", distortion)
	_set_shader_param("opacity", opacity)
	_set_shader_param("uv_transform_scale", cache.get("uv_transform_scale", Vector2.ONE))
	_set_shader_param("uv_transform_offset", cache.get("uv_transform_offset", Vector2.ZERO))
	_set_shader_param("game_texture", media_container.texture)

func set_game_texture(texture: Texture2D) -> void:
	_set_shader_param("game_texture", texture)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var distortion_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Distortion", "", 0.0, 1.0, 0.01)
	distortion_var.property_name = "distortion"
	schema.append(distortion_var)
	
	var opacity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Opacity", "", 0.0, 1.0, 0.01)
	opacity_var.property_name = "opacity"
	schema.append(opacity_var)
	
	return schema
