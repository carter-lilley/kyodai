class_name BadgeEffect
extends CardEffect

var _border_width: float = 0.0
var _badge_width: float = 0.0
var _badge_height: float = 0.0
var _safe_zone: Vector4 = Vector4(0, 0, 0, 0)
var _show_safe_zone: bool = false

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
	var badge_inner_radius = _settings.get("badge_inner_radius", 0.0)
	var badge_color = _settings.get("badge_color", Color.WHITE)
	var badge_aspect = _settings.get("badge_aspect", Vector2(1.0, 1.0))
	var badge_type = _settings.get("badge_type", 0)
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_ratio", _card_state.corner_radius_ratio)
	_set_shader_param("hide_background", hide_background)
	_set_shader_param("badge_type", badge_type)
	# Calculate proper shader params
	var card_width = _card_state.card_size.x
	if _badge_width > 0 and _badge_height > 0:
		if badge_type == 1:
			# Top bar mode: width is card width, height is the bar height
			# Pass height directly as ratio
			_set_shader_param("badge_size_ratio", _badge_height / card_width)
			_set_shader_param("badge_aspect_ratio", Vector2(_badge_width / _badge_height, 1.0))
		else:
			# Corner badge: based on MAX dimension to match GameCard logic
			var max_dim = max(_badge_width, _badge_height)
			_set_shader_param("badge_size_ratio", max_dim / card_width)
			# aspect_ratio should be actual dimensions normalized by max
			_set_shader_param("badge_aspect_ratio", Vector2(_badge_width / max_dim, _badge_height / max_dim))
	else:
		# Fallback: square badge
		var badge_size = _settings.get("badge_size", 1.0)
		_set_shader_param("badge_size_ratio", badge_size * 0.16)
		_set_shader_param("badge_aspect_ratio", Vector2(1.0, 1.0))
	_set_shader_param("badge_inner_radius", badge_inner_radius)
	_set_shader_param("badge_color", badge_color)
	_set_shader_param("border_width_ratio", _border_width)
	_set_shader_param("show_safe_zone", _show_safe_zone)
	_set_shader_param("safe_zone", Vector4(_safe_zone.x, _safe_zone.y, _safe_zone.z, _safe_zone.w))

func set_border_width(width: float) -> void:
	_border_width = width
	_update_shader_params()

func set_badge_dimensions(dimensions: Vector2) -> void:
	# Store actual dimensions passed from GameCard
	_badge_width = dimensions.x
	_badge_height = dimensions.y
	
	# Convert dimensions to aspect ratio
	var max_dim = max(dimensions.x, dimensions.y)
	if max_dim > 0:
		_settings["badge_aspect"] = Vector2(dimensions.x / max_dim, dimensions.y / max_dim)
		_update_shader_params()

func set_safe_zone(safe_x: float, safe_y: float, safe_width: float, safe_height: float, show_debug: bool = false) -> void:
	_safe_zone = Vector4(safe_x, safe_y, safe_width, safe_height)
	_show_safe_zone = show_debug
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
