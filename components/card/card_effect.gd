class_name CardEffect
extends EffectBase

# Backward compatibility - CardEffect now inherits from EffectBase
# The _card_state property is kept for compatibility but internally uses _container_state

var _card_state: CardState:
	get:
		# Return a CardState-compatible wrapper around _container_state
		if _container_state:
			return _convert_to_card_state(_container_state)
		return null
	set(value):
		# Convert CardState to EffectContainerState
		if value:
			_container_state = _convert_from_card_state(value)

func _convert_to_card_state(state: EffectContainerState) -> CardState:
	var card_state = CardState.new()
	card_state.zoom_level = state.zoom_level
	card_state.orientation = state.orientation
	card_state.corner_radius_ratio = state.corner_radius_ratio
	card_state.border_inset_ratio = state.border_inset_ratio
	card_state.glass_inset_ratio = state.glass_inset_ratio
	card_state.card_size = state.container_size
	card_state.corner_radius_pixels = state.corner_radius_pixels
	card_state.total_inset_pixels = state.total_inset_pixels
	card_state.inner_corner_radius_pixels = state.inner_corner_radius_pixels
	card_state.game_texture = state.game_texture
	card_state.effect_settings = state.effect_settings
	return card_state

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
	# Recalculate derived values
	state._recalculate_shape()
	return state

# Override initialize to accept CardState for backward compatibility
func initialize(container_state, settings: Dictionary) -> void:
	# Accept either CardState or EffectContainerState
	if container_state is CardState:
		_card_state = container_state
	else:
		_container_state = container_state
	_settings = settings.duplicate()
	_setup_shader()
	_apply_settings()
	_connect_card_state_signals()

# Override update_state to accept CardState for backward compatibility
func update_state(container_state) -> void:
	_disconnect_container_state_signals()
	# Accept either CardState or EffectContainerState
	if container_state is CardState:
		_card_state = container_state
	else:
		_container_state = container_state
	_connect_card_state_signals()
	_update_shader_params()

# Keep old methods for compatibility (deprecated)
func initialize_card(card_state: CardState, settings: Dictionary) -> void:
	initialize(card_state, settings)

func update_card_state(card_state: CardState) -> void:
	update_state(card_state)

# Keep old signal handler names for compatibility
func _connect_card_state_signals() -> void:
	if not _container_state:
		return
	# CardState uses different signal names, so we connect to our handlers
	_container_state.zoom_changed.connect(_on_zoom_changed)
	_container_state.size_changed.connect(_on_size_changed)
	_container_state.orientation_changed.connect(_on_orientation_changed)
	_container_state.corner_radius_changed.connect(_on_corner_radius_changed)
	_container_state.border_inset_changed.connect(_on_border_inset_changed)
	_container_state.shape_changed.connect(_on_shape_changed)

func _disconnect_card_state_signals() -> void:
	if not _container_state:
		return
	if _container_state.zoom_changed.is_connected(_on_zoom_changed):
		_container_state.zoom_changed.disconnect(_on_zoom_changed)
	if _container_state.size_changed.is_connected(_on_size_changed):
		_container_state.size_changed.disconnect(_on_size_changed)
	if _container_state.orientation_changed.is_connected(_on_orientation_changed):
		_container_state.orientation_changed.disconnect(_on_orientation_changed)
	if _container_state.corner_radius_changed.is_connected(_on_corner_radius_changed):
		_container_state.corner_radius_changed.disconnect(_on_corner_radius_changed)
	if _container_state.border_inset_changed.is_connected(_on_border_inset_changed):
		_container_state.border_inset_changed.disconnect(_on_border_inset_changed)
	if _container_state.shape_changed.is_connected(_on_shape_changed):
		_container_state.shape_changed.disconnect(_on_shape_changed)

# Fix: Override to handle both CardState and EffectContainerState signals
func _on_zoom_changed(new_zoom: float) -> void:
	_update_shader_params()

func _on_size_changed(new_size: Vector2) -> void:
	_update_shader_params()

func _on_orientation_changed(new_orientation: int) -> void:
	_update_shader_params()

func _on_corner_radius_changed(new_ratio: float) -> void:
	_update_shader_params()

func _on_border_inset_changed(new_ratio: float) -> void:
	_update_shader_params()

func _on_shape_changed() -> void:
	_update_shader_params()
