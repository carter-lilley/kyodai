class_name BaseCardEffect
extends CardEffect

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
	if not _card_state:
		return
	
	_set_shader_param("card_size", _card_state.card_size)
	_set_shader_param("corner_radius_ratio", _card_state.corner_radius_ratio)
	_set_shader_param("border_inset_ratio", _card_state.border_inset_ratio)
	_set_shader_param("game_texture", _card_state.game_texture)

func set_game_texture(texture: Texture2D) -> void:
	_current_texture = texture
	if _card_state:
		_card_state.game_texture = texture
		_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	return []
