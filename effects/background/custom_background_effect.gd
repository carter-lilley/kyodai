class_name CustomBackgroundEffect
extends BackgroundEffect

## Generic background effect driven entirely by a user-provided shader. The
## descriptor (from EffectRegistry) carries the compiled shader and the
## introspected settings schema; settings map 1:1 onto shader uniforms.

var _descriptor: Dictionary = {}

func setup(descriptor: Dictionary) -> void:
	_descriptor = descriptor
	effect_id = descriptor.get("id", "")
	effect_name = descriptor.get("display_name", "Custom")
	render_scale = descriptor.get("render_scale", 1.0)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	if mat and _descriptor.get("shader") is Shader:
		mat.shader = _descriptor["shader"]

func _apply_settings() -> void:
	for sv in _descriptor.get("schema", []):
		_set_shader_param(sv.property_name, _settings.get(sv.property_name, sv.value))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	schema.assign(_descriptor.get("schema", []))
	return schema
