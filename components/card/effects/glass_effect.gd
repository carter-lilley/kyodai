class_name GlassEffect
extends CardEffect

func _ready():
	super._ready()
	effect_name = "Glass"
	effect_id = "glass"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/glass.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not _card_state:
		return
	
	var distortion = _settings.get("distortion", 0.5)
	var glass_color = _settings.get("glass_color", Color(0.2, 0.4, 1.0, 0.3))
	var texture_opacity = _settings.get("texture_opacity", 1.0)
	
	# Specular parameters
	var specular_power = _settings.get("specular_power", 32.0)
	var specular_intensity = _settings.get("specular_intensity", 0.8)
	var light_angle = _settings.get("light_angle", 45.0)
	var light_height = _settings.get("light_height", 0.5)
	
	# Bounce parameters
	var bounce_intensity = _settings.get("bounce_intensity", 0.4)
	var bounce_softness = _settings.get("bounce_softness", 3.0)
	
	# Rim parameters
	var rim_intensity = _settings.get("rim_intensity", 1.0)
	var rim_sharpness = _settings.get("rim_sharpness", 5.0)
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_ratio", _card_state.corner_radius_ratio)
	_set_shader_param("distortion", distortion)
	_set_shader_param("glass_color", glass_color)
	_set_shader_param("texture_opacity", texture_opacity)
	_set_shader_param("game_texture", _card_state.game_texture)
	
	# Specular uniforms
	_set_shader_param("specular_power", specular_power)
	_set_shader_param("specular_intensity", specular_intensity)
	_set_shader_param("light_angle", light_angle)
	_set_shader_param("light_height", light_height)
	
	# Bounce uniforms
	_set_shader_param("bounce_intensity", bounce_intensity)
	_set_shader_param("bounce_softness", bounce_softness)
	
	# Rim uniforms
	_set_shader_param("rim_intensity", rim_intensity)
	_set_shader_param("rim_sharpness", rim_sharpness)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	# Distortion slider: 0.0 (pinch in) to 1.0 (bulge out), default 0.5 (nothing)
	var distortion_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Distortion", "", 0.0, 1.0, 0.01)
	distortion_var.property_name = "distortion"
	schema.append(distortion_var)
	
	# Color picker
	var color_var = SettingsVar.new(Type.COLOR, Color(0.2, 0.4, 1.0, 0.3), State.ENABLED, "Glass Color")
	color_var.property_name = "glass_color"
	schema.append(color_var)
	
	# Texture opacity slider
	var texture_opacity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Texture Opacity", "", 0.0, 1.0, 0.01)
	texture_opacity_var.property_name = "texture_opacity"
	schema.append(texture_opacity_var)
	
	# --- Specular Lighting Parameters ---
	
	# Specular power
	var specular_power_var = SettingsVar.new(Type.FLOAT, 32.0, State.ENABLED, "Specular Power", "", 1.0, 128.0, 1.0)
	specular_power_var.property_name = "specular_power"
	schema.append(specular_power_var)
	
	# Specular intensity
	var specular_intensity_var = SettingsVar.new(Type.FLOAT, 0.8, State.ENABLED, "Specular Intensity", "", 0.0, 2.0, 0.01)
	specular_intensity_var.property_name = "specular_intensity"
	schema.append(specular_intensity_var)
	
	# Light angle (0-360 degrees)
	var light_angle_var = SettingsVar.new(Type.FLOAT, 45.0, State.ENABLED, "Light Angle", "", 0.0, 360.0, 1.0)
	light_angle_var.property_name = "light_angle"
	schema.append(light_angle_var)
	
	# Light height (0-1, where 0=horizon, 1=overhead)
	var light_height_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Light Height", "", 0.0, 1.0, 0.01)
	light_height_var.property_name = "light_height"
	schema.append(light_height_var)
	
	# --- Bounce Light Parameters ---
	
	# Bounce intensity
	var bounce_intensity_var = SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Bounce Intensity", "", 0.0, 1.0, 0.01)
	bounce_intensity_var.property_name = "bounce_intensity"
	schema.append(bounce_intensity_var)
	
	# Bounce softness
	var bounce_softness_var = SettingsVar.new(Type.FLOAT, 3.0, State.ENABLED, "Bounce Softness", "", 1.0, 8.0, 0.1)
	bounce_softness_var.property_name = "bounce_softness"
	schema.append(bounce_softness_var)
	
	# --- Rim Light Parameters ---
	
	# Rim intensity
	var rim_intensity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Rim Intensity", "", 0.0, 2.0, 0.01)
	rim_intensity_var.property_name = "rim_intensity"
	schema.append(rim_intensity_var)
	
	# Rim sharpness (thinner rim = higher value)
	var rim_sharpness_var = SettingsVar.new(Type.FLOAT, 5.0, State.ENABLED, "Rim Sharpness", "", 2.0, 10.0, 0.1)
	rim_sharpness_var.property_name = "rim_sharpness"
	schema.append(rim_sharpness_var)
	
	return schema
