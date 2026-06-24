class_name BadgeEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

var _border_width: float = 0.0
var _border_inset_pixels: float = 0.0
var _badge_width: float = 0.0
var _badge_height: float = 0.0
var _safe_zone: Vector4 = Vector4(0, 0, 0, 0)
var _safe_zone_top_bar: Vector4 = Vector4(0, 0, 0, 0)
var _show_safe_zone: bool = false
var _icon_texture: Texture2D = null

func _init():
	super._init()
	effect_id = "badge"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/badge.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	var hide_background = _settings.get("hide_background", false)
	var badge_inner_radius = _settings.get("badge_inner_radius", 0.0)
	var badge_color = _settings.get("badge_color", Color.WHITE)
	var badge_type = _settings.get("badge_type", 0)
	var icon_padding = _settings.get("icon_padding", 0.5)
	var icon_color = _settings.get("icon_color", Color.WHITE)

	var card_width = media_container.size.x

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	_set_shader_param("inner_corner_radius_pixels", media_container.get_inner_corner_radius_pixels())
	_set_shader_param("glass_inset_ratio", media_container.glass_inset_ratio)
	_set_shader_param("hide_background", hide_background)
	_set_shader_param("badge_type", badge_type)

	if _badge_width > 0 and _badge_height > 0:
		if badge_type == 1:
			_set_shader_param("badge_size_ratio", _badge_height / card_width)
			_set_shader_param("badge_aspect_ratio", Vector2(_badge_width / _badge_height, 1.0))
		else:
			var max_dim = max(_badge_width, _badge_height)
			_set_shader_param("badge_size_ratio", max_dim / card_width)
			_set_shader_param("badge_aspect_ratio", Vector2(_badge_width / max_dim, _badge_height / max_dim))
	else:
		var badge_size = _settings.get("badge_size", 1.0)
		_set_shader_param("badge_size_ratio", badge_size * 0.16)
		_set_shader_param("badge_aspect_ratio", Vector2(1.0, 1.0))

	_set_shader_param("badge_inner_radius", badge_inner_radius)
	_set_shader_param("badge_color", badge_color)
	_set_shader_param("border_width_ratio", _border_width)
	_set_shader_param("border_inset_pixels", _border_inset_pixels)
	_set_shader_param("show_safe_zone", _show_safe_zone)
	_set_shader_param("safe_zone", Vector4(_safe_zone.x, _safe_zone.y, _safe_zone.z, _safe_zone.w))
	_set_shader_param("safe_zone_top_bar", Vector4(_safe_zone_top_bar.x, _safe_zone_top_bar.y, _safe_zone_top_bar.z, _safe_zone_top_bar.w))
	_set_shader_param("icon_texture", _icon_texture)
	_set_shader_param("has_icon_texture", _icon_texture != null)
	_set_shader_param("icon_padding", icon_padding)
	_set_shader_param("icon_color", icon_color)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

func set_border_width(width: float) -> void:
	_border_width = width
	_update_shader_params()

func set_border_inset_pixels(pixels: float) -> void:
	_border_inset_pixels = pixels
	_update_shader_params()

func set_badge_dimensions(dimensions: Vector2) -> void:
	_badge_width = dimensions.x
	_badge_height = dimensions.y

	var max_dim = max(dimensions.x, dimensions.y)
	if max_dim > 0:
		_settings["badge_aspect"] = Vector2(dimensions.x / max_dim, dimensions.y / max_dim)
	_update_shader_params()

func set_safe_zone(safe_x: float, safe_y: float, safe_width: float, safe_height: float, show_debug: bool = false) -> void:
	_safe_zone = Vector4(safe_x, safe_y, safe_width, safe_height)
	_show_safe_zone = show_debug
	_update_shader_params()

func set_safe_zone_top_bar(safe_x: float, safe_y: float, safe_width: float, safe_height: float, show_debug: bool = false) -> void:
	_safe_zone_top_bar = Vector4(safe_x, safe_y, safe_width, safe_height)
	_show_safe_zone = show_debug
	_update_shader_params()

func set_icon_texture(texture: Texture2D) -> void:
	_icon_texture = texture
	_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var badge_type_var = SettingsVar.new(Type.ENUM, 0, State.ENABLED, "Badge Type", "", 0, 0, 0, ["Corner Badge", "Top Bar"])
	badge_type_var.property_name = "badge_type"
	schema.append(badge_type_var)

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
