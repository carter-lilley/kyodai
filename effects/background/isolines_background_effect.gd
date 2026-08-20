class_name IsolinesBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Isolines"
	effect_id = "isolines"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_isolines.gdshader")

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 1.0))
	_set_shader_param("zoom", _settings.get("zoom", 0.3))
	_set_shader_param("line_width", _settings.get("line_width", 0.6))
	_set_shader_param("lighting_strength", _settings.get("lighting_strength", 0.35))
	_set_shader_param("line_color", _settings.get("line_color", Color(1.0, 1.0, 1.0, 1.0)))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var time_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Time Scale", "Animation speed multiplier", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)

	var zoom_var = SettingsVar.new(Type.FLOAT, 0.3, State.ENABLED, "Zoom", "Scale of the terrain features", 0.05, 1.0, 0.05)
	zoom_var.property_name = "zoom"
	schema.append(zoom_var)

	var width_var = SettingsVar.new(Type.FLOAT, 0.6, State.ENABLED, "Line Width", "Thickness of the contour lines", 0.1, 2.0, 0.05)
	width_var.property_name = "line_width"
	schema.append(width_var)

	var light_var = SettingsVar.new(Type.FLOAT, 0.35, State.ENABLED, "Lighting Strength", "Intensity of the cloud-like lighting modulation", 0.0, 1.0, 0.05)
	light_var.property_name = "lighting_strength"
	schema.append(light_var)

	var line_color_var = SettingsVar.new(Type.COLOR, Color(1.0, 1.0, 1.0, 1.0), State.ENABLED, "Line Color", "Color of the contour lines")
	line_color_var.property_name = "line_color"
	schema.append(line_color_var)

	return schema
