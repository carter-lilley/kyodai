class_name BadgeEffect
extends CardEffect

var _border_width: float = 0.0

func _ready():
	super._ready()
	effect_name = "Platform Badge"
	effect_id = "badge"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/badge.gdshader")

func _apply_settings() -> void:
	_update_shader_params()

func _update_shader_params() -> void:
	if not _card_state:
		return
	
	var hide_background = _settings.get("hide_background", false)
	var badge_size = _settings.get("badge_size", 1.0)
	var badge_inner_radius = _settings.get("badge_inner_radius", 0.0)
	var badge_color = _settings.get("badge_color", Color.WHITE)
	var badge_dimensions = _settings.get("badge_dimensions", Vector2(32.0, 32.0))
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_pixels", _card_state.corner_radius)
	_set_shader_param("hide_background", hide_background)
	_set_shader_param("badge_size", badge_size * _card_state.zoom_level)
	_set_shader_param("badge_dimensions", badge_dimensions)
	_set_shader_param("badge_inner_radius", badge_inner_radius)
	_set_shader_param("badge_color", badge_color)
	_set_shader_param("border_width", _border_width)

func set_border_width(width: float) -> void:
	_border_width = width
	_update_shader_params()

func set_badge_dimensions(dimensions: Vector2) -> void:
	_settings["badge_dimensions"] = dimensions
	_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var hide_bg_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Hide Background")
	hide_bg_var.property_name = "hide_background"
	schema.append(hide_bg_var)
	
	var size_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Badge Size", "", 0.5, 2.0, 0.1)
	size_var.property_name = "badge_size"
	schema.append(size_var)
	
	var radius_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Badge Corner Radius", "", 0.0, 1.0, 0.1)
	radius_var.property_name = "badge_inner_radius"
	schema.append(radius_var)
	
	var badge_color_var = SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Badge Background Color")
	badge_color_var.property_name = "badge_color"
	schema.append(badge_color_var)
	
	var icon_padding_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Icon Padding", "", 0.0, 1.0, 0.1)
	icon_padding_var.property_name = "icon_padding"
	schema.append(icon_padding_var)
	
	var icon_color_var = SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Icon Color")
	icon_color_var.property_name = "icon_color"
	schema.append(icon_color_var)
	
	return schema
