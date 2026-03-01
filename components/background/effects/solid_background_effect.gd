class_name SolidBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Solid Color"
	effect_id = "solid"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/library_background.gdshader")

func _apply_settings() -> void:
	var color = _settings.get("background_color", Color(0.1, 0.1, 0.1, 1.0))
	_set_shader_param("background_color", color)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var color_var = SettingsVar.new(Type.COLOR, Color(0.1, 0.1, 0.1, 1.0), State.ENABLED, "Background Color")
	color_var.property_name = "background_color"
	schema.append(color_var)
	
	return schema
