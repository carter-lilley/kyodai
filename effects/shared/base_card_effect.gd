class_name BaseCardEffect
extends EffectBase

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

func _update_shader_params() -> void:
	if not _container_state:
		return
	
	_set_shader_param("card_size", _container_state.container_size)
	_set_shader_param("corner_radius_ratio", _container_state.corner_radius_ratio)
	_set_shader_param("border_inset_ratio", _container_state.border_inset_ratio)
	_set_shader_param("glass_inset_ratio", _container_state.glass_inset_ratio)
	_set_shader_param("game_texture", _container_state.game_texture)
	# Pass shared shape parameters for consistent SDF calculations
	_set_shader_param("corner_radius_pixels", _container_state.corner_radius_pixels)
	_set_shader_param("total_inset_pixels", _container_state.total_inset_pixels)
	
	# Calculate and store UV transforms for other effects
	_update_uv_transforms()

func _update_uv_transforms() -> void:
	if not _container_state or not _container_state.game_texture:
		return
	
	var card_size = _container_state.container_size
	var tex_size = Vector2(_container_state.game_texture.get_width(), _container_state.game_texture.get_height())
	
	var card_aspect = card_size.x / card_size.y
	var tex_aspect = tex_size.x / tex_size.y
	
	var scale = Vector2(1.0, 1.0)
	if card_aspect > tex_aspect:
		scale.y = tex_aspect / card_aspect
	else:
		scale.x = card_aspect / tex_aspect
	
	# Calculate offset to center the scaled texture
	var offset = (Vector2(1.0, 1.0) - scale) * 0.5
	
	_container_state.uv_transform_scale = scale
	_container_state.uv_transform_offset = offset
	# Note: vertical_offset from smart crop stays 0 for now
	# (smart crop calculation requires Sobel edge detection, done in shader)

func set_game_texture(texture: Texture2D) -> void:
	_current_texture = texture
	if _container_state:
		_container_state.game_texture = texture
		_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func set_alpha(value: float) -> void:
	_set_shader_param("alpha", value)
