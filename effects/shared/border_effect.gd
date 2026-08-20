class_name BorderEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

static func is_material_shareable() -> bool:
	return true

var _gradient_texture: ImageTexture = null
var _gradient_hash_cache: String = ""
var _inner_stroke_gradient_texture: ImageTexture = null
var _inner_stroke_hash: String = ""
var _outer_stroke_gradient_texture: ImageTexture = null
var _outer_stroke_hash: String = ""

func _init():
	super._init()
	effect_id = "border"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/border.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	_ensure_shared_material()

	var border_size = _settings.get("border_size", 0.0)
	var border_fade_in = _settings.get("border_fade_in", 0.0)
	var border_gradient = _settings.get("border_gradient")
	var legacy_direction = _settings.get("gradient_direction")
	var inner_stroke_width = _settings.get("inner_stroke_width", 0.0)
	var inner_stroke_gradient = _settings.get("inner_stroke_gradient")
	var outer_stroke_width = _settings.get("outer_stroke_width", 0.0)
	var outer_stroke_gradient = _settings.get("outer_stroke_gradient")

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("border_width_ratio", border_size)
	_set_shader_param("border_fade_in_ratio", border_fade_in)
	_set_shader_param("border_gradient_angle", get_gradient_angle(_settings, "border_gradient_angle", legacy_direction))
	_set_shader_param("border_gradient_radial", _settings.get("border_gradient_radial", false))
	_set_shader_param("inner_stroke_gradient_angle", get_gradient_angle(_settings, "inner_stroke_gradient_angle", legacy_direction))
	_set_shader_param("inner_stroke_gradient_radial", _settings.get("inner_stroke_gradient_radial", false))
	_set_shader_param("outer_stroke_gradient_angle", get_gradient_angle(_settings, "outer_stroke_gradient_angle", legacy_direction))
	_set_shader_param("outer_stroke_gradient_radial", _settings.get("outer_stroke_gradient_radial", false))

	if inner_stroke_gradient is Gradient:
		var inner_key = gradient_content_hash(inner_stroke_gradient)
		if inner_key != _inner_stroke_hash:
			_inner_stroke_hash = inner_key
			_inner_stroke_gradient_texture = get_shared_gradient_texture(inner_stroke_gradient)
		_set_shader_param("inner_stroke_gradient_texture", _inner_stroke_gradient_texture)
		_set_shader_param("use_inner_stroke_gradient", true)
	else:
		_set_shader_param("use_inner_stroke_gradient", false)
	_set_shader_param("inner_stroke_width_ratio", inner_stroke_width)

	if outer_stroke_gradient is Gradient:
		var outer_key = gradient_content_hash(outer_stroke_gradient)
		if outer_key != _outer_stroke_hash:
			_outer_stroke_hash = outer_key
			_outer_stroke_gradient_texture = get_shared_gradient_texture(outer_stroke_gradient)
		_set_shader_param("outer_stroke_gradient_texture", _outer_stroke_gradient_texture)
		_set_shader_param("use_outer_stroke_gradient", true)
	else:
		_set_shader_param("use_outer_stroke_gradient", false)
	_set_shader_param("outer_stroke_width_ratio", outer_stroke_width)

	if border_gradient is Gradient:
		var border_key = gradient_content_hash(border_gradient)
		if border_key != _gradient_hash_cache:
			_gradient_hash_cache = border_key
			_gradient_texture = get_shared_gradient_texture(border_gradient)
		_set_shader_param("gradient_texture", _gradient_texture)
		_set_shader_param("use_gradient", true)
	else:
		var border_color = _settings.get("border_color", Color.WHITE)
		_set_shader_param("border_color", border_color)
		_set_shader_param("use_gradient", false)

	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var size_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Border Size", "", 0.0, 0.5, 0.01)
	size_var.property_name = "border_size"
	schema.append(size_var)

	var fade_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Border Fade In", "", 0.0, 0.5, 0.01)
	fade_var.property_name = "border_fade_in"
	schema.append(fade_var)

	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color.WHITE, Color.BLACK]

	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Border Gradient")
	gradient_var.property_name = "border_gradient"
	schema.append(gradient_var)

	var angle_var = SettingsVar.new(Type.ANGLE, 90.0, State.ENABLED, "Gradient Angle", "", 0.0, 360.0, 15.0)
	angle_var.property_name = "border_gradient_angle"
	schema.append(angle_var)

	var radial_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Radial (Vignette)")
	radial_var.property_name = "border_gradient_radial"
	schema.append(radial_var)

	var inner_stroke_width_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Inner Stroke Width", "", 0.0, 0.1, 0.001)
	inner_stroke_width_var.property_name = "inner_stroke_width"
	schema.append(inner_stroke_width_var)

	var inner_stroke_gradient = Gradient.new()
	inner_stroke_gradient.offsets = [0.0, 1.0]
	inner_stroke_gradient.colors = [Color.WHITE, Color.BLACK]
	var inner_stroke_gradient_var = SettingsVar.new(Type.GRADIENT, inner_stroke_gradient, State.ENABLED, "Inner Stroke Gradient")
	inner_stroke_gradient_var.property_name = "inner_stroke_gradient"
	schema.append(inner_stroke_gradient_var)

	var inner_angle_var = SettingsVar.new(Type.ANGLE, 90.0, State.ENABLED, "Inner Stroke Angle", "", 0.0, 360.0, 15.0)
	inner_angle_var.property_name = "inner_stroke_gradient_angle"
	schema.append(inner_angle_var)

	var inner_radial_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Inner Stroke Radial")
	inner_radial_var.property_name = "inner_stroke_gradient_radial"
	schema.append(inner_radial_var)

	var outer_stroke_width_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Outer Stroke Width", "", 0.0, 0.1, 0.001)
	outer_stroke_width_var.property_name = "outer_stroke_width"
	schema.append(outer_stroke_width_var)

	var outer_stroke_gradient = Gradient.new()
	outer_stroke_gradient.offsets = [0.0, 1.0]
	outer_stroke_gradient.colors = [Color.WHITE, Color.BLACK]
	var outer_stroke_gradient_var = SettingsVar.new(Type.GRADIENT, outer_stroke_gradient, State.ENABLED, "Outer Stroke Gradient")
	outer_stroke_gradient_var.property_name = "outer_stroke_gradient"
	schema.append(outer_stroke_gradient_var)

	var outer_angle_var = SettingsVar.new(Type.ANGLE, 90.0, State.ENABLED, "Outer Stroke Angle", "", 0.0, 360.0, 15.0)
	outer_angle_var.property_name = "outer_stroke_gradient_angle"
	schema.append(outer_angle_var)

	var outer_radial_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Outer Stroke Radial")
	outer_radial_var.property_name = "outer_stroke_gradient_radial"
	schema.append(outer_radial_var)

	return schema
