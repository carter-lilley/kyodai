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
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_ratio", _card_state.corner_radius_ratio)
	_set_shader_param("distortion", distortion)
	_set_shader_param("glass_color", glass_color)
	_set_shader_param("game_texture", _card_state.game_texture)

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
	
	return schema
