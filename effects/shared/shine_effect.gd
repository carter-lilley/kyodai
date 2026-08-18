class_name ShineEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["base_card", "focus_card", "hero"]

static func is_material_shareable() -> bool:
	return true

func _init():
	super._init()
	effect_id = "shine"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/shine.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	_ensure_shared_material()

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)
	_set_shader_param("speed", _settings.get("speed", 1.0))
	_set_shader_param("line_width", _settings.get("line_width", 0.15))
	_set_shader_param("line_color", _settings.get("line_color", Color(1.0, 1.0, 1.0, 0.6)))
	_set_shader_param("pause_duration", _settings.get("pause_duration", 0.5))
	_set_shader_param("angle_degrees", _settings.get("angle_degrees", 45.0))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var speed_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Speed", "Sweep speed", 0.0, 5.0, 0.1)
	speed_var.property_name = "speed"
	schema.append(speed_var)

	var width_var = SettingsVar.new(Type.FLOAT, 0.15, State.ENABLED, "Width", "Width of the shine band", 0.0, 0.5, 0.01)
	width_var.property_name = "line_width"
	schema.append(width_var)

	var color_var = SettingsVar.new(Type.COLOR, Color(1.0, 1.0, 1.0, 0.6), State.ENABLED, "Color", "Shine color (alpha controls intensity)")
	color_var.property_name = "line_color"
	schema.append(color_var)

	var pause_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Pause", "Pause between sweeps in seconds", 0.0, 5.0, 0.1)
	pause_var.property_name = "pause_duration"
	schema.append(pause_var)

	var angle_var = SettingsVar.new(Type.FLOAT, 45.0, State.ENABLED, "Angle", "Sweep direction in degrees", 0.0, 180.0, 5.0)
	angle_var.property_name = "angle_degrees"
	schema.append(angle_var)

	return schema
