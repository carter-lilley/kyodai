class_name XmbBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "XMB Animated"
	effect_id = "xmb"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_xmb.gdshader")
	
	# Set up noise texture for XMB shader
	var noise = FastNoiseLite.new()
	var noise_texture = NoiseTexture2D.new()
	noise_texture.width = 1024
	noise_texture.height = 1024
	noise_texture.noise = noise
	_set_shader_param("noise_texture", noise_texture)

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 1.0))
	_set_shader_param("show_dust", _settings.get("show_dust", true))
	_set_shader_param("wave_intensity", _settings.get("wave_intensity", 0.812))
	_set_shader_param("star_threshold", _settings.get("star_threshold", 1.0))
	
	# Wave color (drives background gradient and dust)
	_set_shader_param("wave_color", _settings.get("wave_color", Color(0.04, 0.69, 0.87, 1.0)))
	
	# Wave settings
	_set_shader_param("wave_thickness", _settings.get("wave_thickness", 0.5))
	_set_shader_param("wave_amplitude", _settings.get("wave_amplitude", 0.324))
	_set_shader_param("wave_vertical_offset", _settings.get("wave_vertical_offset", -0.2))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var time_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Time Scale", "Animation speed multiplier", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)
	
	var dust_var = SettingsVar.new(Type.BOOL, true, State.ENABLED, "Show Dust", "Toggle particle dust effect")
	dust_var.property_name = "show_dust"
	schema.append(dust_var)
	
	var wave_var = SettingsVar.new(Type.FLOAT, 0.812, State.ENABLED, "Wave Intensity", "Strength of the wave animation", 0.0, 5.0, 0.1)
	wave_var.property_name = "wave_intensity"
	schema.append(wave_var)
	
	var thickness_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Wave Thickness", "How thick/broad the waves are", 0.5, 5.0, 0.1)
	thickness_var.property_name = "wave_thickness"
	schema.append(thickness_var)
	
	var amplitude_var = SettingsVar.new(Type.FLOAT, 0.324, State.ENABLED, "Wave Amplitude", "How tall/deep the waves are", 0.0, 3.0, 0.1)
	amplitude_var.property_name = "wave_amplitude"
	schema.append(amplitude_var)
	
	var offset_var = SettingsVar.new(Type.FLOAT, -0.2, State.ENABLED, "Wave Vertical Offset", "Shift wave up or down", -1.0, 1.0, 0.05)
	offset_var.property_name = "wave_vertical_offset"
	schema.append(offset_var)
	
	# Wave color (drives background gradient and dust)
	var wave_color_var = SettingsVar.new(Type.COLOR, Color(0.04, 0.69, 0.87, 1.0), State.ENABLED, "Wave Color", "Base color for background gradient")
	wave_color_var.property_name = "wave_color"
	schema.append(wave_color_var)
	
	return schema
