class_name GlassEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

var _swoop_layer: ColorRect = null

func _ready():
	super._ready()
	effect_name = "Glass"
	effect_id = "glass"
	
	_swoop_layer = ColorRect.new()
	_swoop_layer.name = "GlassSwoop"
	_swoop_layer.anchor_right = 1.0
	_swoop_layer.anchor_bottom = 1.0
	_swoop_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var swoop_mat = ShaderMaterial.new()
	swoop_mat.shader = preload("res://shaders/card/glass_swoop.gdshader")
	_swoop_layer.material = swoop_mat
	add_child(_swoop_layer)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/glass.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var glass_color = _settings.get("glass_color", Color(0.2, 0.4, 1.0, 0.3))
	var specular_power = _settings.get("specular_power", 32.0)
	var specular_intensity = _settings.get("specular_intensity", 0.8)
	var light_angle = _settings.get("light_angle", 45.0)
	var light_height = _settings.get("light_height", 0.5)
	var bounce_intensity = _settings.get("bounce_intensity", 0.4)
	var bounce_softness = _settings.get("bounce_softness", 3.0)
	var rim_intensity = _settings.get("rim_intensity", 1.0)
	var rim_sharpness = _settings.get("rim_sharpness", 5.0)
	var additional_inset = _settings.get("additional_inset_ratio", 0.0)
	var swoop_intensity = _settings.get("swoop_intensity", 0.3)
	var swoop_height = _settings.get("swoop_height", 0.25)
	var swoop_curve = _settings.get("swoop_curve", 0.5)
	var swoop_tilt = _settings.get("swoop_tilt", 0.0)
	
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("border_inset_ratio", media_container.border_inset_ratio)
	_set_shader_param("glass_color", glass_color)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)
	_set_shader_param("specular_power", specular_power)
	_set_shader_param("specular_intensity", specular_intensity)
	_set_shader_param("light_angle", light_angle)
	_set_shader_param("light_height", light_height)
	_set_shader_param("bounce_intensity", bounce_intensity)
	_set_shader_param("bounce_softness", bounce_softness)
	_set_shader_param("rim_intensity", rim_intensity)
	_set_shader_param("rim_sharpness", rim_sharpness)
	_set_shader_param("additional_inset_ratio", additional_inset)
	
	if _swoop_layer and _swoop_layer.material:
		var swoop_mat = _swoop_layer.material as ShaderMaterial
		swoop_mat.set_shader_parameter("card_size", media_container.size)
		swoop_mat.set_shader_parameter("corner_radius_ratio", media_container.corner_radius_ratio)
		swoop_mat.set_shader_parameter("border_inset_ratio", media_container.border_inset_ratio)
		swoop_mat.set_shader_parameter("glass_color", glass_color)
		swoop_mat.set_shader_parameter("swoop_intensity", swoop_intensity)
		swoop_mat.set_shader_parameter("swoop_height", swoop_height)
		swoop_mat.set_shader_parameter("swoop_curve", swoop_curve)
		swoop_mat.set_shader_parameter("swoop_tilt", swoop_tilt)
		swoop_mat.set_shader_parameter("display_mode", 1 if media_container.edge_aa_enabled else 0)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var color_var = SettingsVar.new(Type.COLOR, Color(0.2, 0.4, 1.0, 0.3), State.ENABLED, "Glass Color")
	color_var.property_name = "glass_color"
	schema.append(color_var)
	
	var additional_inset_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Additional Inset", "Push underlying image inward", 0.0, 0.5, 0.01)
	additional_inset_var.property_name = "additional_inset_ratio"
	schema.append(additional_inset_var)
	
	var swoop_intensity_var = SettingsVar.new(Type.FLOAT, 0.3, State.ENABLED, "Swoop Intensity", "Darkness of the curved swoop", 0.0, 1.0, 0.01)
	swoop_intensity_var.property_name = "swoop_intensity"
	schema.append(swoop_intensity_var)
	
	var swoop_height_var = SettingsVar.new(Type.FLOAT, 0.25, State.ENABLED, "Swoop Height", "How far up the swoop extends", 0.0, 0.5, 0.01)
	swoop_height_var.property_name = "swoop_height"
	schema.append(swoop_height_var)
	
	var swoop_curve_var = SettingsVar.new(Type.FLOAT, 0.3, State.ENABLED, "Swoop Curve", "How pronounced the curve is", 0.0, 1.0, 0.01)
	swoop_curve_var.property_name = "swoop_curve"
	schema.append(swoop_curve_var)
	
	var swoop_tilt_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Swoop Tilt", "Tilt the curve to raise one side", -1.0, 1.0, 0.01)
	swoop_tilt_var.property_name = "swoop_tilt"
	schema.append(swoop_tilt_var)
	
	var specular_power_var = SettingsVar.new(Type.FLOAT, 32.0, State.ENABLED, "Specular Power", "", 1.0, 128.0, 1.0)
	specular_power_var.property_name = "specular_power"
	schema.append(specular_power_var)
	
	var specular_intensity_var = SettingsVar.new(Type.FLOAT, 0.8, State.ENABLED, "Specular Intensity", "", 0.0, 2.0, 0.01)
	specular_intensity_var.property_name = "specular_intensity"
	schema.append(specular_intensity_var)
	
	var light_angle_var = SettingsVar.new(Type.FLOAT, 45.0, State.ENABLED, "Light Angle", "", 0.0, 360.0, 1.0)
	light_angle_var.property_name = "light_angle"
	schema.append(light_angle_var)
	
	var light_height_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Light Height", "", -0.5, 1.0, 0.01)
	light_height_var.property_name = "light_height"
	schema.append(light_height_var)
	
	var bounce_intensity_var = SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Bounce Intensity", "", 0.0, 1.0, 0.01)
	bounce_intensity_var.property_name = "bounce_intensity"
	schema.append(bounce_intensity_var)
	
	var bounce_softness_var = SettingsVar.new(Type.FLOAT, 3.0, State.ENABLED, "Bounce Softness", "", 1.0, 8.0, 0.1)
	bounce_softness_var.property_name = "bounce_softness"
	schema.append(bounce_softness_var)
	
	var rim_intensity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Rim Intensity", "", 0.0, 2.0, 0.01)
	rim_intensity_var.property_name = "rim_intensity"
	schema.append(rim_intensity_var)
	
	var rim_sharpness_var = SettingsVar.new(Type.FLOAT, 5.0, State.ENABLED, "Rim Sharpness", "", 2.0, 10.0, 0.1)
	rim_sharpness_var.property_name = "rim_sharpness"
	schema.append(rim_sharpness_var)
	
	return schema
