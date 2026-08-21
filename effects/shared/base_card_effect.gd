class_name BaseCardEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

func _init():
	super._init()
	effect_id = "base"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/base_card.gdshader")

func _update_shader_params() -> void:
	if not media_container:
		return

	var uv = media_container.get_uv_transforms()

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("border_inset_ratio", media_container.border_inset_ratio)
	_set_shader_param("glass_inset_ratio", media_container.glass_inset_ratio)
	_set_shader_param("game_texture", media_container.texture)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	_set_shader_param("wrap_inset_top_pixels", media_container.get_wrap_inset_top_pixels())
	_set_shader_param("wrap_inset_left_pixels", media_container.get_wrap_inset_left_pixels())

	_set_shader_param("uv_transform_scale", uv["uv_transform_scale"])
	_set_shader_param("uv_transform_offset", uv["uv_transform_offset"])

	_set_shader_param("vertical_offset", media_container.vertical_offset)

	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

	# Skeleton shimmer state + theme-driven colors (re-pushed on every refresh
	# so theme changes are picked up).
	_set_shader_param("loading_active", 1.0 if media_container.loading_active else 0.0)
	var shimmer_base := M3Theme.get_elevation_surface(5)
	_set_shader_param("loading_base_color", shimmer_base)
	_set_shader_param("loading_shimmer_color", shimmer_base.lightened(0.18))

func get_settings_schema() -> Array[SettingsVar]:
	return []
