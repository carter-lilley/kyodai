class_name GradientBackgroundEffect
extends BackgroundEffect

var _gradient_texture: ImageTexture = null

func _ready():
	super._ready()
	effect_name = "Gradient"
	effect_id = "gradient"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_gradient.gdshader")

func _apply_settings() -> void:
	var gradient = _settings.get("background_gradient", null)
	if gradient is Gradient:
		_update_gradient_texture(gradient)
		var mat = material as ShaderMaterial
		mat.set_shader_parameter("gradient_texture", _gradient_texture)
		mat.set_shader_parameter("gradient_angle", EffectBase.get_gradient_angle(_settings, "gradient_angle"))
		mat.set_shader_parameter("gradient_radial", _settings.get("gradient_radial", false))

func _update_gradient_texture(gradient: Gradient) -> void:
	_gradient_texture = EffectBase.get_shared_gradient_texture(gradient)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Background Gradient")
	gradient_var.property_name = "background_gradient"
	schema.append(gradient_var)

	var angle_var = SettingsVar.new(Type.ANGLE, 90.0, State.ENABLED, "Gradient Angle", "", 0.0, 360.0, 15.0)
	angle_var.property_name = "gradient_angle"
	schema.append(angle_var)

	var radial_var = SettingsVar.new(Type.BOOL, false, State.ENABLED, "Radial (Vignette)")
	radial_var.property_name = "gradient_radial"
	schema.append(radial_var)

	return schema
