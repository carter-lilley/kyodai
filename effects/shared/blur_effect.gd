class_name BlurEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _init():
	super._init()
	effect_id = "blur"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/blur.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	var blur_strength = _settings.get("blur_strength", 4.0)
	var blur_samples = _settings.get("blur_samples", 8)

	var uv = media_container.get_uv_transforms()

	var screen_height = SystemManager.display.get_viewport_size().y
	var quality_scale = clamp(1080.0 / screen_height, 0.4, 1.0)

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	_set_shader_param("uv_transform_scale", uv["uv_transform_scale"])
	_set_shader_param("uv_transform_offset", uv["uv_transform_offset"])
	_set_shader_param("blur_strength", blur_strength)
	_set_shader_param("blur_samples", float(blur_samples))
	_set_shader_param("game_texture", media_container.texture)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)
	_set_shader_param("vertical_offset", media_container.vertical_offset)
	_set_shader_param("quality_scale", quality_scale)

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
