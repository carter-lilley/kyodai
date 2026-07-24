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
	var inner_size := card_size - Vector2(total_inset * 2.0, total_inset * 2.0)

	# Inverse aspect-cover transform for the inner media area. The base card
	# shader maps inner_uv -> texture_uv as texture_uv = inner_uv * scale + offset.
	# We need the inverse so we can turn the detected texture-space logo rect
	# back into inner media coordinates and then into card pixels.
	var scale := Vector2.ONE
	var offset := Vector2.ZERO
	if media_container.texture and inner_size.x > 0.0 and inner_size.y > 0.0:
		var tex_size := Vector2(media_container.texture.get_width(), media_container.texture.get_height())
		if tex_size.x > 0.0 and tex_size.y > 0.0:
			var inner_aspect := inner_size.x / inner_size.y
			var tex_aspect := tex_size.x / tex_size.y
			if inner_aspect > tex_aspect:
				scale.y = tex_aspect / inner_aspect
			else:
				scale.x = inner_aspect / tex_aspect
			offset = (Vector2.ONE - scale) * 0.5

	_set_shader_param("card_size", card_size)
	_set_shader_param("total_inset_pixels", total_inset)
	_set_shader_param("uv_inner_scale", scale)
	_set_shader_param("uv_inner_offset", offset)
	_set_shader_param("logo_rect", _logo_rect)

func get_settings_schema() -> Array[SettingsVar]:
	# No user-facing settings; the rect is supplied programmatically.
	return []
