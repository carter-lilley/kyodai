class_name DotGridBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Dot Grid"
	effect_id = "dotgrid"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_dotgrid.gdshader")

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 1.0))
	_set_shader_param("dot_spacing", _settings.get("dot_spacing", 30.0))
	_set_shader_param("dot_size", _settings.get("dot_size", 0.15))
	_set_shader_param("noise_scale", _settings.get("noise_scale", 1.0))
	_set_shader_param("size_modulation", _settings.get("size_modulation", 0.35))
	_set_shader_param("opacity_modulation", _settings.get("opacity_modulation", 0.9))
	_set_shader_param("color_a", _settings.get("color_a", Color(1.0, 0.082, 0.621, 1.0)))
	_set_shader_param("color_b", _settings.get("color_b", Color(1.0, 0.152, 0.009, 1.0)))
	_set_shader_param("background_color", _settings.get("background_color", Color(0.05, 0.05, 0.08, 1.0)))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var time_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Time Scale", "Animation speed multiplier", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)

	var spacing_var = SettingsVar.new(Type.FLOAT, 30.0, State.ENABLED, "Dot Spacing", "Number of grid divisions across the screen", 5.0, 100.0, 1.0)
	spacing_var.property_name = "dot_spacing"
	schema.append(spacing_var)

	var size_var = SettingsVar.new(Type.FLOAT, 0.15, State.ENABLED, "Dot Size", "Base dot radius within each cell", 0.02, 0.3, 0.005)
	size_var.property_name = "dot_size"
	schema.append(size_var)

	var noise_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Noise Scale", "Spatial scale of the modulation field", 0.1, 5.0, 0.1)
	noise_var.property_name = "noise_scale"
	schema.append(noise_var)

	var size_mod_var = SettingsVar.new(Type.FLOAT, 0.35, State.ENABLED, "Size Modulation", "How much the noise affects dot size", 0.0, 1.0, 0.05)
	size_mod_var.property_name = "size_modulation"
	schema.append(size_mod_var)

	var opacity_mod_var = SettingsVar.new(Type.FLOAT, 0.9, State.ENABLED, "Opacity Modulation", "How much the noise affects dot opacity", 0.0, 1.0, 0.05)
	opacity_mod_var.property_name = "opacity_modulation"
	schema.append(opacity_mod_var)

	var color_a_var = SettingsVar.new(Type.COLOR, Color(1.0, 0.082, 0.621, 1.0), State.ENABLED, "Color A", "Dot color on the left side")
	color_a_var.property_name = "color_a"
	schema.append(color_a_var)

	var color_b_var = SettingsVar.new(Type.COLOR, Color(1.0, 0.152, 0.009, 1.0), State.ENABLED, "Color B", "Dot color on the right side")
	color_b_var.property_name = "color_b"
	schema.append(color_b_var)

	var bg_color_var = SettingsVar.new(Type.COLOR, Color(0.05, 0.05, 0.08, 1.0), State.ENABLED, "Background Color", "Color behind the dots")
	bg_color_var.property_name = "background_color"
	schema.append(bg_color_var)

	return schema
