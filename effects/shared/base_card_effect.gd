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

func set_game_texture(texture: Texture2D) -> void:
	_current_texture = texture
	if _container_state:
		_container_state.game_texture = texture
		_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func set_alpha(value: float) -> void:
	_set_shader_param("alpha", value)
