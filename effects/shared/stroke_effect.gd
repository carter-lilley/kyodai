class_name StrokeEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

static func is_material_shareable() -> bool:
	return true

var _gradient_texture: ImageTexture = null
var _gradient_hash_cache: String = ""

func _init() -> void:
	super._init()
	effect_id = "stroke"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/stroke.gdshader")

func get_stroke_width_pixels(card_size: Vector2) -> float:
	return maxf(0.0, float(_settings.get("stroke_width_ratio", 0.02)) * card_size.x)

func advances_content_edge() -> bool:
	return bool(_settings.get("advance", true))

func get_depth_offset_pixels(card_size: Vector2) -> float:
	return float(_settings.get("depth_offset_ratio", 0.0)) * card_size.x

func _update_shader_params() -> void:
	if not media_container:
		return
	_ensure_shared_material()
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("stroke_offset_pixels", stroke_offset_pixels)
	_set_shader_param("stroke_width_pixels", stroke_width_pixels)
	_set_shader_param("stroke_color", _settings.get("stroke_color", Color.WHITE))
	_set_shader_param("gradient_angle", get_gradient_angle(_settings, "gradient_angle", _settings.get("gradient_direction")))
	_set_shader_param("gradient_radial", _settings.get("gradient_radial", false))
	_set_shader_param("fade_in", _settings.get("fade_in", false))
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

	var gradient = _settings.get("stroke_gradient")
	if gradient is Gradient:
		var key := gradient_content_hash(gradient)
		if key != _gradient_hash_cache:
			_gradient_hash_cache = key
			_gradient_texture = get_shared_gradient_texture(gradient)
		_set_shader_param("gradient_texture", _gradient_texture)
		_set_shader_param("use_gradient", true)
	else:
		_set_shader_param("use_gradient", false)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var width_var = SettingsVar.new(Type.FLOAT, 0.02, State.ENABLED, "Stroke Width", "Ratio of card width", 0.0, 0.5, 0.001)
	width_var.property_name = "stroke_width_ratio"
	schema.append(width_var)

	var color_var = SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Stroke Color")
	color_var.property_name = "stroke_color"
	schema.append(color_var)

	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color.WHITE, Color.BLACK]
	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Stroke Gradient")
	gradient_var.property_name = "stroke_gradient"
	schema.append(gradient_var)

	var angle_var = SettingsVar.new(Type.ANGLE, 180.0, State.ENABLED, "Gradient Angle", "Degrees", 0.0, 360.0, 15.0)
	angle_var.property_name = "gradient_angle"
	schema.append(angle_var)

	var radial_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Radial Gradient")
	radial_var.property_name = "gradient_radial"
	schema.append(radial_var)

	var fade_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Fade Inward", "Fade from opaque at the outer edge to transparent at the inner edge")
	fade_var.property_name = "fade_in"
	schema.append(fade_var)

	var offset_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Depth Offset", "Additional offset from the layer's inherited depth; negative values move outward", -0.5, 0.5, 0.001)
	offset_var.property_name = "depth_offset_ratio"
	schema.append(offset_var)

	var advance_var = SettingsVar.new(Type.BOOL, true, State.ENABLED, "Advance Content Edge", "Start later strokes and media inside this stroke")
	advance_var.property_name = "advance"
	schema.append(advance_var)
	return schema
