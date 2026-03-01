class_name XmbBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "XMB Animated"
	effect_id = "xmb"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/library_background_xmb.gdshader")
	
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
	_set_shader_param("wave_intensity", _settings.get("wave_intensity", 1.0))
	_set_shader_param("star_threshold", _settings.get("star_threshold", 0.99))
	
	# Gradient colors (4 corners)
	_set_shader_param("color_top_left", _settings.get("color_top_left", Color(0.7, 0.2, 0.2, 1.0)))
	_set_shader_param("color_top_right", _settings.get("color_top_right", Color(0.4, 0.1, 0.1, 1.0)))
	_set_shader_param("color_bottom_left", _settings.get("color_bottom_left", Color(0.45, 0.1, 0.1, 1.0)))
	_set_shader_param("color_bottom_right", _settings.get("color_bottom_right", Color(0.8, 0.3, 0.5, 1.0)))
	
	# Wave blend color
	_set_shader_param("wave_blend_color", _settings.get("wave_blend_color", Color.WHITE))

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
	
	var wave_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Wave Intensity", "Strength of the wave animation", 0.0, 2.0, 0.1)
	wave_var.property_name = "wave_intensity"
	schema.append(wave_var)
	
	var star_var = SettingsVar.new(Type.FLOAT, 0.99, State.ENABLED, "Star Threshold", "Brightness threshold for stars", 0.9, 1.0, 0.01)
	star_var.property_name = "star_threshold"
	schema.append(star_var)
	
	# Gradient colors (4 corners of the background)
	var tl_var = SettingsVar.new(Type.COLOR, Color(0.7, 0.2, 0.2, 1.0), State.ENABLED, "Top Left Color", "Top-left corner gradient color")
	tl_var.property_name = "color_top_left"
	schema.append(tl_var)
	
	var tr_var = SettingsVar.new(Type.COLOR, Color(0.4, 0.1, 0.1, 1.0), State.ENABLED, "Top Right Color", "Top-right corner gradient color")
	tr_var.property_name = "color_top_right"
	schema.append(tr_var)
	
	var bl_var = SettingsVar.new(Type.COLOR, Color(0.45, 0.1, 0.1, 1.0), State.ENABLED, "Bottom Left Color", "Bottom-left corner gradient color")
	bl_var.property_name = "color_bottom_left"
	schema.append(bl_var)
	
	var br_var = SettingsVar.new(Type.COLOR, Color(0.8, 0.3, 0.5, 1.0), State.ENABLED, "Bottom Right Color", "Bottom-right corner gradient color")
	br_var.property_name = "color_bottom_right"
	schema.append(br_var)
	
	# Wave blend color
	var wave_color_var = SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Wave Blend Color", "Color the wave blends into")
	wave_color_var.property_name = "wave_blend_color"
	schema.append(wave_color_var)
	
	return schema
