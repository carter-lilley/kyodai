class_name CardState
extends RefCounted

signal zoom_changed(new_zoom: float)
signal orientation_changed(new_orientation: int)
signal corner_radius_changed(new_ratio: float)
signal border_inset_changed(new_ratio: float)

# Base dimensions (unscaled reference sizes)
const VERTICAL_SIZE: Vector2 = Vector2(202.0, 270.0)
const HORIZONTAL_SIZE: Vector2 = Vector2(270.0, 202.0)
const SQUARE_SIZE: Vector2 = Vector2(256.0, 256.0)

# Card properties - reactive
var zoom_level: float = 1.0:
	set(value):
		if not is_equal_approx(zoom_level, value):
			zoom_level = value
			_update_dimensions()
			zoom_changed.emit(value)

var orientation: int = 0:  # 0=vertical, 1=horizontal, 2=square
	set(value):
		if orientation != value:
			orientation = value
			_update_dimensions()
			orientation_changed.emit(value)

# Corner radius as ratio of card width (0.0 - 1.0)
var corner_radius_ratio: float = 0.06:  # ~12px at default zoom
	set(value):
		var clamped = clampf(value, 0.0, 0.5)
		if not is_equal_approx(corner_radius_ratio, clamped):
			corner_radius_ratio = clamped
			corner_radius_changed.emit(clamped)

# Border inset as ratio of card width (0.0 - 1.0)  
var border_inset_ratio: float = 0.0:
	set(value):
		var clamped = clampf(value, 0.0, 0.5)
		if not is_equal_approx(border_inset_ratio, clamped):
			border_inset_ratio = clamped
			border_inset_changed.emit(clamped)

# Computed dimensions (derived from zoom + orientation)
var card_size: Vector2 = VERTICAL_SIZE
var game_texture: Texture2D = null
var effect_settings: Array = []

func _init() -> void:
	_update_dimensions()

func _update_dimensions() -> void:
	var base = _get_base_dimensions()
	card_size = base * zoom_level

func _get_base_dimensions() -> Vector2:
	match orientation:
		1: return HORIZONTAL_SIZE
		2: return SQUARE_SIZE
		_: return VERTICAL_SIZE

# Helper to get corner radius in pixels (for internal calculations)
func get_corner_radius_pixels() -> float:
	return card_size.x * corner_radius_ratio

# Helper to get border inset in pixels (for internal calculations)
func get_border_inset_pixels() -> float:
	return card_size.x * border_inset_ratio

# Helper to set border inset from pixels
func set_border_inset_pixels(pixels: float) -> void:
	if card_size.x > 0:
		border_inset_ratio = pixels / card_size.x
	else:
		border_inset_ratio = 0.0

func get_effect_config(effect_id: String) -> Dictionary:
	for effect_data in effect_settings:
		if effect_data is Dictionary and effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}

func set_effect_config(effect_id: String, config: Dictionary) -> void:
	for i in range(effect_settings.size()):
		if effect_settings[i] is Dictionary and effect_settings[i].get("effect_id") == effect_id:
			effect_settings[i] = config.duplicate()
			return
	effect_settings.append(config.duplicate())

func duplicate() -> CardState:
	var new_state = CardState.new()
	new_state.zoom_level = zoom_level
	new_state.orientation = orientation
	new_state.corner_radius_ratio = corner_radius_ratio
	new_state.border_inset_ratio = border_inset_ratio
	new_state.game_texture = game_texture
	new_state.effect_settings = effect_settings.duplicate(true)
	# _update_dimensions will be called in _init, but card_size will be recalculated
	new_state.card_size = card_size
	return new_state
