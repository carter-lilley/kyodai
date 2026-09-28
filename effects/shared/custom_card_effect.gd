class_name CustomCardEffect
extends EffectBase

## Generic card effect driven entirely by a user-provided shader. Settings map
## 1:1 onto the shader's introspected uniforms; reserved uniforms
## (game_texture, card_size, corner radii) are fed from the MediaContainer
## exactly as built-in effects feed them.
##
## Constraints (by design): pure shader-param effects only — no media_container
## hooks, no draw-rect growth, no shared-material optimization.

var _descriptor: Dictionary = {}

func setup(descriptor: Dictionary) -> void:
	_descriptor = descriptor
	effect_id = descriptor.get("id", "")

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	if mat and _descriptor.get("shader") is Shader:
		mat.shader = _descriptor["shader"]

func _update_shader_params() -> void:
	if not media_container:
		return
	for sv in _descriptor.get("schema", []):
		_set_shader_param(sv.property_name, _settings.get(sv.property_name, sv.value))
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("game_texture", media_container.texture)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	schema.assign(_descriptor.get("schema", []))
	return schema
