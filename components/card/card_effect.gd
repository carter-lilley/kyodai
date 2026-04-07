class_name CardEffect
extends EffectBase

# Override initialize to accept CardState for backward compatibility
func initialize(container_state, settings: Dictionary) -> void:
	if container_state is CardState:
		_container_state = _convert_from_card_state(container_state)
	else:
		_container_state = container_state
	_settings = settings.duplicate()
	_setup_shader()
	_apply_settings()
	_connect_container_state_signals()

# Override update_state to accept CardState for backward compatibility
func update_state(container_state) -> void:
	_disconnect_container_state_signals()
	if container_state is CardState:
		_container_state = _convert_from_card_state(container_state)
	else:
		_container_state = container_state
	_connect_container_state_signals()
	# Manually trigger size update since the signal may have fired before we reconnected
	if _container_state:
		_on_size_changed(_container_state.container_size)
	_update_shader_params()

func _convert_from_card_state(card_state: CardState) -> EffectContainerState:
	var state = EffectContainerState.new()
	state.zoom_level = card_state.zoom_level
	state.orientation = card_state.orientation
	state.corner_radius_ratio = card_state.corner_radius_ratio
	state.border_inset_ratio = card_state.border_inset_ratio
	state.glass_inset_ratio = card_state.glass_inset_ratio
	state.container_size = card_state.card_size
	state.game_texture = card_state.game_texture
	state.effect_settings = card_state.effect_settings
	state.focus_effect_settings = card_state.focus_effect_settings if card_state.has("focus_effect_settings") else []
	state._recalculate_shape()
	return state
