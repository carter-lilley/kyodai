class_name BorderEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

var _gradient_texture: ImageTexture = null
var _gradient_hash_cache: Array = []
var _inner_stroke_gradient_texture: ImageTexture = null
var _inner_stroke_hash: Array = []
var _outer_stroke_gradient_texture: ImageTexture = null
var _outer_stroke_hash: Array = []

func _init():
	super._init()
	effect_id = "border"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/border.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	var border_size = _settings.get("border_size", 0.0)
	var border_fade_in = _settings.get("border_fade_in", 0.0)
	var border_gradient = _settings.get("border_gradient")
	var gradient_direction = _settings.get("gradient_direction", 0)
	var inner_stroke_width = _settings.get("inner_stroke_width", 0.0)
	var inner_stroke_gradient = _settings.get("inner_stroke_gradient")
	var outer_stroke_width = _settings.get("outer_stroke_width", 0.0)
	var outer_stroke_gradient = _settings.get("outer_stroke_gradient")

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("border_width_ratio", border_size)
	_set_shader_param("border_fade_in_ratio", border_fade_in)
	_set_shader_param("gradient_direction", gradient_direction)

	if inner_stroke_gradient is Gradient:
		var inner_hash = _gradient_hash(inner_stroke_gradient)
		if inner_hash != _inner_stroke_hash:
			_inner_stroke_hash = inner_hash
			_inner_stroke_gradient_texture = _gradient_to_texture(inner_stroke_gradient)
		_set_shader_param("inner_stroke_gradient_texture", _inner_stroke_gradient_texture)
		_set_shader_param("use_inner_stroke_gradient", true)
	else:
		_set_shader_param("use_inner_stroke_gradient", false)
	_set_shader_param("inner_stroke_width_ratio", inner_stroke_width)

	if outer_stroke_gradient is Gradient:
		var outer_hash = _gradient_hash(outer_stroke_gradient)
		if outer_hash != _outer_stroke_hash:
			_outer_stroke_hash = outer_hash
			_outer_stroke_gradient_texture = _gradient_to_texture(outer_stroke_gradient)
		_set_shader_param("outer_stroke_gradient_texture", _outer_stroke_gradient_texture)
		_set_shader_param("use_outer_stroke_gradient", true)
	else:
		_set_shader_param("use_outer_stroke_gradient", false)
	_set_shader_param("outer_stroke_width_ratio", outer_stroke_width)

	if border_gradient is Gradient:
		var border_hash = _gradient_hash(border_gradient)
		if border_hash != _gradient_hash_cache:
			_gradient_hash_cache = border_hash
			_gradient_texture = _gradient_to_texture(border_gradient)
		_set_shader_param("gradient_texture", _gradient_texture)
		_set_shader_param("use_gradient", true)
	else:
		var border_color = _settings.get("border_color", Color.WHITE)
		_set_shader_param("border_color", border_color)
		_set_shader_param("use_gradient", false)

	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

func _gradient_to_texture(gradient: Gradient) -> ImageTexture:
	var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in range(256):
		var t = i / 255.0
		image.set_pixel(i, 0, gradient.sample(t))
	return ImageTexture.create_from_image(image)

func _gradient_hash(gradient: Gradient) -> Array:
	var h: Array = []
	for i in range(gradient.get_point_count()):
		h.append(gradient.get_offset(i))
		h.append(gradient.get_color(i))
	return h

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

	var direction_var = SettingsVar.new(Type.ENUM, 0, State.ENABLED, "Gradient Direction", "", 0.0, 0.0, 0.0, ["Horizontal", "Vertical", "Diagonal"])
	direction_var.property_name = "gradient_direction"
	schema.append(direction_var)

	var inner_stroke_width_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Inner Stroke Width", "", 0.0, 0.1, 0.001)
	inner_stroke_width_var.property_name = "inner_stroke_width"
	schema.append(inner_stroke_width_var)

	var inner_stroke_gradient = Gradient.new()
	inner_stroke_gradient.offsets = [0.0, 1.0]
	inner_stroke_gradient.colors = [Color.WHITE, Color.BLACK]
	var inner_stroke_gradient_var = SettingsVar.new(Type.GRADIENT, inner_stroke_gradient, State.ENABLED, "Inner Stroke Gradient")
	inner_stroke_gradient_var.property_name = "inner_stroke_gradient"
	schema.append(inner_stroke_gradient_var)

	var outer_stroke_width_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Outer Stroke Width", "", 0.0, 0.1, 0.001)
	outer_stroke_width_var.property_name = "outer_stroke_width"
	schema.append(outer_stroke_width_var)

	var outer_stroke_gradient = Gradient.new()
	outer_stroke_gradient.offsets = [0.0, 1.0]
	outer_stroke_gradient.colors = [Color.WHITE, Color.BLACK]
	var outer_stroke_gradient_var = SettingsVar.new(Type.GRADIENT, outer_stroke_gradient, State.ENABLED, "Outer Stroke Gradient")
	outer_stroke_gradient_var.property_name = "outer_stroke_gradient"
	schema.append(outer_stroke_gradient_var)

	return schema
