class_name GradientFlowBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Gradient Flow"
	effect_id = "gradient_flow"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_gradient_flow.gdshader")

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 1.0))
	_set_shader_param("rotation_speed", _settings.get("rotation_speed", 0.1))
	_set_shader_param("rotation_amount", _settings.get("rotation_amount", 720.0))
	_set_shader_param("wave_frequency", _settings.get("wave_frequency", 5.0))
	_set_shader_param("wave_amplitude", _settings.get("wave_amplitude", 30.0))
	_set_shader_param("wave_speed", _settings.get("wave_speed", 2.0))
	_set_shader_param("layer1_color_a", _settings.get("layer1_color_a", Color(0.957, 0.804, 0.623, 1.0)))
	_set_shader_param("layer1_color_b", _settings.get("layer1_color_b", Color(0.192, 0.384, 0.933, 1.0)))
	_set_shader_param("layer2_color_a", _settings.get("layer2_color_a", Color(0.910, 0.510, 0.800, 1.0)))
	_set_shader_param("layer2_color_b", _settings.get("layer2_color_b", Color(0.350, 0.710, 0.953, 1.0)))
	_set_shader_param("opacity", _settings.get("opacity", 1.0))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var time_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Time Scale", "Animation speed multiplier", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)

	var rot_speed_var = SettingsVar.new(Type.FLOAT, 0.1, State.ENABLED, "Rotation Speed", "How fast the noise-driven rotation evolves", 0.0, 1.0, 0.01)
	rot_speed_var.property_name = "rotation_speed"
	schema.append(rot_speed_var)

	var rot_amount_var = SettingsVar.new(Type.FLOAT, 720.0, State.ENABLED, "Rotation Amount", "Maximum rotation applied by the noise field (degrees)", 0.0, 1440.0, 10.0)
	rot_amount_var.property_name = "rotation_amount"
	schema.append(rot_amount_var)

	var freq_var = SettingsVar.new(Type.FLOAT, 5.0, State.ENABLED, "Wave Frequency", "Density of the sine warp", 0.5, 20.0, 0.1)
	freq_var.property_name = "wave_frequency"
	schema.append(freq_var)

	var amp_var = SettingsVar.new(Type.FLOAT, 30.0, State.ENABLED, "Wave Amplitude", "Strength of the sine warp (higher = subtler)", 1.0, 100.0, 1.0)
	amp_var.property_name = "wave_amplitude"
	schema.append(amp_var)

	var speed_var = SettingsVar.new(Type.FLOAT, 2.0, State.ENABLED, "Wave Speed", "Scroll speed of the sine warp", 0.0, 10.0, 0.1)
	speed_var.property_name = "wave_speed"
	schema.append(speed_var)

	var l1a_var = SettingsVar.new(Type.COLOR, Color(0.957, 0.804, 0.623, 1.0), State.ENABLED, "Layer 1 Color A", "First color of the primary gradient layer")
	l1a_var.property_name = "layer1_color_a"
	schema.append(l1a_var)

	var l1b_var = SettingsVar.new(Type.COLOR, Color(0.192, 0.384, 0.933, 1.0), State.ENABLED, "Layer 1 Color B", "Second color of the primary gradient layer")
	l1b_var.property_name = "layer1_color_b"
	schema.append(l1b_var)

	var l2a_var = SettingsVar.new(Type.COLOR, Color(0.910, 0.510, 0.800, 1.0), State.ENABLED, "Layer 2 Color A", "First color of the secondary gradient layer")
	l2a_var.property_name = "layer2_color_a"
	schema.append(l2a_var)

	var l2b_var = SettingsVar.new(Type.COLOR, Color(0.350, 0.710, 0.953, 1.0), State.ENABLED, "Layer 2 Color B", "Second color of the secondary gradient layer")
	l2b_var.property_name = "layer2_color_b"
	schema.append(l2b_var)

	var opacity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Opacity", "Below 1.0 the base gradient and layers underneath show through", 0.0, 1.0, 0.05)
	opacity_var.property_name = "opacity"
	schema.append(opacity_var)

	return schema
