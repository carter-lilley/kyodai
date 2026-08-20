class_name GradientOverlayEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["base_card", "focus_card"]

static func is_material_shareable() -> bool:
	return true

var _gradient_texture: ImageTexture = null
var _gradient_hash_cache: String = ""

func _init():
	super._init()
	effect_id = "gradient_overlay"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/gradient_overlay.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	_ensure_shared_material()

	var gradient = _settings.get("gradient")
	var gradient_angle = get_gradient_angle(_settings, "gradient_angle")
	var gradient_radial = _settings.get("gradient_radial", false)

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("gradient_angle", gradient_angle)
	_set_shader_param("gradient_radial", gradient_radial)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

	if gradient is Gradient:
		var key := gradient_content_hash(gradient)
		if key != _gradient_hash_cache:
			_gradient_hash_cache = key
			_gradient_texture = get_shared_gradient_texture(gradient)
		_set_shader_param("gradient_texture", _gradient_texture)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color.WHITE, Color.BLACK]

	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Gradient")
	gradient_var.property_name = "gradient"
	schema.append(gradient_var)

	var angle_var = SettingsVar.new(Type.ANGLE, 90.0, State.ENABLED, "Gradient Angle", "", 0.0, 360.0, 15.0)
	angle_var.property_name = "gradient_angle"
	schema.append(angle_var)

	var radial_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Radial (Vignette)")
	radial_var.property_name = "gradient_radial"
	schema.append(radial_var)

	return schema
