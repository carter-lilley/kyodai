class_name HSLEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _ready():
	super._ready()
	effect_name = "HSL"
	effect_id = "hsl"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/hsl.gdshader")

func _apply_settings() -> void:
	pass  # Offsets: compute_pipeline(). Shader params: _run_pipeline().

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var hue_shift = _settings.get("hue_shift", 0.0)
	var saturation_scale = _settings.get("saturation_scale", 1.0)
	var lightness_scale = _settings.get("lightness_scale", 1.0)
	
	_set_shader_param("hue_shift", hue_shift)
	_set_shader_param("saturation_scale", saturation_scale)
	_set_shader_param("lightness_scale", lightness_scale)
	
	var uv = media_container.get_uv_transforms()
	
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	_set_shader_param("uv_transform_scale", uv["uv_transform_scale"])
	_set_shader_param("uv_transform_offset", uv["uv_transform_offset"])
	_set_shader_param("game_texture", media_container.texture)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)
	_set_shader_param("vertical_offset", media_container.vertical_offset)

func set_game_texture(texture: Texture2D) -> void:
	pass  # EffectStack handles this via media_container.texture + _update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var hue_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Hue Shift", "Rotate hue (-180 to +180 degrees)", -1.0, 1.0, 0.01)
	hue_var.property_name = "hue_shift"
	schema.append(hue_var)
	
	var sat_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Saturation", "Scale saturation (0 = grayscale, 1 = normal, 2 = double)", 0.0, 2.0, 0.01)
	sat_var.property_name = "saturation_scale"
	schema.append(sat_var)
	
	var light_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Lightness", "Scale lightness (0 = black, 1 = normal, 2 = white)", 0.0, 2.0, 0.01)
	light_var.property_name = "lightness_scale"
	schema.append(light_var)
	
	return schema
