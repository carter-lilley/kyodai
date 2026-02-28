class_name BorderEffect
extends CardEffect

var _gradient_texture: ImageTexture = null
var _inner_stroke_gradient_texture: ImageTexture = null
var _outer_stroke_gradient_texture: ImageTexture = null

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
	var border_gradient = _settings.get("border_gradient")
	var gradient_direction = _settings.get("gradient_direction", 0)
	var inner_stroke_width = _settings.get("inner_stroke_width", 0.0)
	var inner_stroke_gradient = _settings.get("inner_stroke_gradient")
	var outer_stroke_width = _settings.get("outer_stroke_width", 0.0)
	var outer_stroke_gradient = _settings.get("outer_stroke_gradient")
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_ratio", _card_state.corner_radius_ratio)
	_set_shader_param("border_width_ratio", border_size)
	_set_shader_param("border_fade_in_ratio", border_fade_in)
	_set_shader_param("gradient_direction", gradient_direction)
	
	if inner_stroke_gradient is Gradient:
		_inner_stroke_gradient_texture = _gradient_to_texture(inner_stroke_gradient)
		_set_shader_param("inner_stroke_gradient_texture", _inner_stroke_gradient_texture)
		_set_shader_param("use_inner_stroke_gradient", true)
	else:
		_set_shader_param("use_inner_stroke_gradient", false)
	_set_shader_param("inner_stroke_width_ratio", inner_stroke_width)
	
	if outer_stroke_gradient is Gradient:
		_outer_stroke_gradient_texture = _gradient_to_texture(outer_stroke_gradient)
		_set_shader_param("outer_stroke_gradient_texture", _outer_stroke_gradient_texture)
		_set_shader_param("use_outer_stroke_gradient", true)
	else:
		_set_shader_param("use_outer_stroke_gradient", false)
	_set_shader_param("outer_stroke_width_ratio", outer_stroke_width)
	
	if border_gradient is Gradient:
		_gradient_texture = _gradient_to_texture(border_gradient)
		_set_shader_param("gradient_texture", _gradient_texture)
		_set_shader_param("use_gradient", true)
	else:
		var border_color = _settings.get("border_color", Color.WHITE)
		_set_shader_param("border_color", border_color)
		_set_shader_param("use_gradient", false)

func set_border_size(size: float) -> void:
	_settings["border_size"] = size
	_update_shader_params()

func tween_border_size(target_size: float, duration: float = 0.15) -> Tween:
	var tween = create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_OUT)
	
	var start_size = _settings.get("border_size", 0.05)
	tween.tween_method(func(t): 
		var current_size = lerp(start_size, target_size, t)
		set_border_size(current_size)
	, 0.0, 1.0, duration)
	
	return tween

func _gradient_to_texture(gradient: Gradient) -> ImageTexture:
	var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	var debug_str = "[BorderEffect] Generating texture from gradient with " + str(gradient.get_point_count()) + " points: "
	for i in range(gradient.get_point_count()):
		debug_str += "(" + str(gradient.get_offset(i)) + ":" + str(gradient.get_color(i)) + ") "
	#print(debug_str)
	
	for i in range(256):
		var t = i / 255.0  # Sample at pixel edges: 0.0 to 1.0 inclusive
		var color = gradient.sample(t)
		image.set_pixel(i, 0, color)
	
	return ImageTexture.create_from_image(image)

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
	
	var gradient = Gradient.new()
	# Godot's Gradient.new() creates 2 default points (black@0.0, white@1.0)
	# We need to replace them with our own points by using direct array assignment
	# This bypasses Godot's auto-add behavior
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color.WHITE, Color.BLACK]
	#print("[BorderEffect] Created gradient with ", gradient.get_point_count(), " point(s): ", gradient.offsets)
	
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
