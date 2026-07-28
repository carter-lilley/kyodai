class_name LogoBoxEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

var _logo_rect: Vector4 = Vector4.ZERO

func _init():
	super._init()
	effect_id = "logo_box"

func set_logo_rect(rect: Vector4) -> void:
	if _logo_rect == rect:
		return
	_logo_rect = rect
	_mark_shader_params_dirty()

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/logo_box.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	var card_size := media_container.size
	var total_inset := media_container.get_total_inset_pixels()

	# Use the exact UV transform the base card shader is using. The base shader
	# maps inner_uv -> texture_uv as texture_uv = inner_uv * scale + offset, so
	# we invert that to turn the detected texture-space logo rect into inner
	# media coordinates for the outline.
	var uv := media_container.get_uv_transforms()
	var scale: Vector2 = uv["uv_transform_scale"]
	var offset: Vector2 = uv["uv_transform_offset"]

	_set_shader_param("card_size", card_size)
	_set_shader_param("total_inset_pixels", total_inset)
	_set_shader_param("uv_inner_scale", scale)
	_set_shader_param("uv_inner_offset", offset)
	_set_shader_param("logo_rect", _logo_rect)

func get_settings_schema() -> Array[SettingsVar]:
	# No user-facing settings; the rect is supplied programmatically.
	return []
