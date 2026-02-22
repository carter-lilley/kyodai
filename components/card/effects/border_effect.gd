class_name BorderEffect
extends CardEffect

func _ready():
	super._ready()
	effect_name = "Border"
	effect_id = "border"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/border.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not _card_state:
		return
	
	var border_size = _settings.get("border_size", 0.05)
	var border_fade_in = _settings.get("border_fade_in", 0.0)
	var border_color = _settings.get("border_color", Color.WHITE)
	
	var border_pixels = border_size * _card_state.base_width * 2.0 * _card_state.zoom_level
	var fade_in_pixels = border_fade_in * _card_state.base_width * 2.0 * _card_state.zoom_level
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_pixels", _card_state.corner_radius)
	_set_shader_param("border_width_pixels", border_pixels)
	_set_shader_param("border_fade_in_pixels", fade_in_pixels)
	_set_shader_param("border_color", border_color)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var size_var = SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Border Size", "", 0.01, 0.5, 0.01)
	size_var.property_name = "border_size"
	schema.append(size_var)
	
	var fade_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Border Fade In", "", 0.0, 0.5, 0.01)
	fade_var.property_name = "border_fade_in"
	schema.append(fade_var)
	
	var color_var = SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Border Color")
	color_var.property_name = "border_color"
	schema.append(color_var)
	
	return schema
