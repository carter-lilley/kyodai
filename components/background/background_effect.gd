class_name BackgroundEffect
extends ColorRect

@export var effect_name: String = "Effect"
@export var effect_id: String = ""

var _settings: Dictionary = {}

func _ready():
	material = ShaderMaterial.new()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_setup_shader()

func initialize(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	# Defer to ensure shader material is fully ready
	call_deferred("_apply_settings")

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_apply_settings()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	var mat = material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(param, value)
