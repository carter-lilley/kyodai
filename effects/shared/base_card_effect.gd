class_name BaseCardEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

var _current_texture: Texture2D = null

func _ready():
	super._ready()
	effect_name = "Base"
	effect_id = "base"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/base_card.gdshader")

func _apply_settings() -> void:
	pass

func compute_pipeline(cache: Dictionary) -> void:
	"""Compute UV transforms and write to pipeline cache for downstream effects."""
	if not media_container or not media_container.texture:
		return
	
	var card_size = media_container.size
	var tex_size = Vector2(media_container.texture.get_width(), media_container.texture.get_height())
	
	if card_size.x <= 0 or card_size.y <= 0 or tex_size.x <= 0 or tex_size.y <= 0:
		return
	
	var card_aspect = card_size.x / card_size.y
	var tex_aspect = tex_size.x / tex_size.y
	
	var tex_scale = Vector2(1.0, 1.0)
	if card_aspect > tex_aspect:
		tex_scale.y = tex_aspect / card_aspect
	else:
		tex_scale.x = card_aspect / tex_aspect
	
	var offset = (Vector2(1.0, 1.0) - tex_scale) * 0.5
	
	cache["uv_transform_scale"] = tex_scale
	cache["uv_transform_offset"] = offset
	cache["card_aspect"] = card_aspect
	cache["tex_aspect"] = tex_aspect

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var cache = media_container.pipeline_cache
	
	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("border_inset_ratio", media_container.border_inset_ratio)
	_set_shader_param("glass_inset_ratio", media_container.glass_inset_ratio)
	_set_shader_param("game_texture", media_container.texture)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("total_inset_pixels", media_container.get_total_inset_pixels())
	
	# Read UV transforms from pipeline cache
	_set_shader_param("uv_transform_scale", cache.get("uv_transform_scale", Vector2.ONE))
	_set_shader_param("uv_transform_offset", cache.get("uv_transform_offset", Vector2.ZERO))

func set_game_texture(texture: Texture2D) -> void:
	_current_texture = texture
	if media_container:
		media_container.texture = texture
		_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func set_alpha(value: float) -> void:
	_set_shader_param("alpha", value)
