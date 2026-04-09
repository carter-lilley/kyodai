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
	_update_shader_params()

func _update_shader_params() -> void:
	if not _container_state:
		return
	
	var hue_shift = _settings.get("hue_shift", 0.0)
	var saturation_scale = _settings.get("saturation_scale", 1.0)
	var lightness_scale = _settings.get("lightness_scale", 1.0)
	
	# DEBUG: Print HSL values when they change significantly or during focus
	# This will help diagnose the flickering issue during scroll
	var card = get_parent()
	if card and card.get_parent() and card.get_parent().name == "FocusEffects":
		# Only print for focus effects to avoid spam
		print("[HSL DEBUG] Focus effect - saturation_scale: %.3f, hue_shift: %.3f, lightness: %.3f" % [saturation_scale, hue_shift, lightness_scale])
	
	# HSL parameters
	_set_shader_param("hue_shift", hue_shift)
	_set_shader_param("saturation_scale", saturation_scale)
	_set_shader_param("lightness_scale", lightness_scale)
	
	# Shape parameters for clipping
	_set_shader_param("card_size", _container_state.container_size)
	_set_shader_param("corner_radius_pixels", _container_state.corner_radius_pixels)
	_set_shader_param("total_inset_pixels", _container_state.total_inset_pixels)
	
	# UV transform parameters from base_card
	_set_shader_param("uv_transform_scale", _container_state.uv_transform_scale)
	_set_shader_param("uv_transform_offset", _container_state.uv_transform_offset)
	_set_shader_param("vertical_offset", _container_state.vertical_offset)
	
	# Texture
	_set_shader_param("game_texture", _container_state.game_texture)

func set_game_texture(texture: Texture2D) -> void:
	if _container_state:
		_container_state.game_texture = texture
		_update_shader_params()

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
