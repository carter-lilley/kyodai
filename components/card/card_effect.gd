class_name CardEffect
extends ColorRect

@export var effect_name: String = "Effect"
@export var effect_id: String = ""

var _settings: Dictionary = {}
var _card_state: CardState

signal effect_enabled_changed(enabled: bool)
signal settings_changed(setting_name: String, value: Variant)

func _ready():
	material = ShaderMaterial.new()
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func initialize(card_state: CardState, settings: Dictionary) -> void:
	_card_state = card_state
	_settings = settings.duplicate()
	_setup_shader()
	_apply_settings()

func update_state(card_state: CardState) -> void:
	_card_state = card_state
	_update_shader_params()

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_apply_settings()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _update_shader_params() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	var mat = material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(param, value)
