class_name XmbClassicBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "XMB (Classic)"
	effect_id = "xmb_classic"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_xmb_classic.gdshader")

func _apply_settings() -> void:
	_set_shader_param("wave_color", _settings.get("wave_color", Color(0.04, 0.69, 0.87, 1.0)))
	_set_shader_param("time_scale", _settings.get("time_scale", 1.0))
	_set_shader_param("frequency", _settings.get("frequency", 4.29))
	_set_shader_param("outer_amplitude", _settings.get("outer_amplitude", 0.5))
	_set_shader_param("inner_amplitude", _settings.get("inner_amplitude", 0.18))
	_set_shader_param("outer_speed", _settings.get("outer_speed", 0.044))
	_set_shader_param("inner_speed", _settings.get("inner_speed", 0.064))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var color_var = SettingsVar.new(Type.COLOR, Color(0.04, 0.69, 0.87, 1.0), State.ENABLED, "Wave Color", "Base color for the gradient and waves")
	color_var.property_name = "wave_color"
	schema.append(color_var)
	
	var time_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Time Scale", "Animation speed", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)
	
	var freq_var = SettingsVar.new(Type.FLOAT, 4.29, State.ENABLED, "Frequency", "Wave frequency", 1.0, 10.0, 0.1)
	freq_var.property_name = "frequency"
	schema.append(freq_var)
	
	var outer_amp_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Outer Amplitude", "Height of outer waves", 0.0, 2.0, 0.05)
	outer_amp_var.property_name = "outer_amplitude"
	schema.append(outer_amp_var)
	
	var inner_amp_var = SettingsVar.new(Type.FLOAT, 0.18, State.ENABLED, "Inner Amplitude", "Height of inner waves", 0.0, 1.0, 0.05)
	inner_amp_var.property_name = "inner_amplitude"
	schema.append(inner_amp_var)
	
	var outer_speed_var = SettingsVar.new(Type.FLOAT, 0.044, State.ENABLED, "Outer Speed", "Speed of outer waves", 0.0, 0.2, 0.005)
	outer_speed_var.property_name = "outer_speed"
	schema.append(outer_speed_var)
	
	var inner_speed_var = SettingsVar.new(Type.FLOAT, 0.064, State.ENABLED, "Inner Speed", "Speed of inner waves", 0.0, 0.2, 0.005)
	inner_speed_var.property_name = "inner_speed"
	schema.append(inner_speed_var)
	
	return schema
