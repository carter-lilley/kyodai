class_name PresentWrapEffect
extends EffectBase

## Internal overlay layer (not registered in EffectStack.EFFECT_REGISTRY, so it
## never appears in the Card Designer). Owned and driven directly by GameCard:
## visible only for downloaded-but-never-played games until first focus.

func _init():
	super._init()
	effect_id = "present_wrap"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	if mat:
		mat.shader = preload("res://shaders/card/present_wrap.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	_set_shader_param("inner_corner_radius_pixels", media_container.get_inner_corner_radius_pixels())
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

func set_unwrap_progress(value: float) -> void:
	_set_shader_param("unwrap_progress", value)
