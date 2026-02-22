class_name CardState
extends RefCounted

var card_size: Vector2 = Vector2(202, 270)
var corner_radius: float = 12.0
var game_texture: Texture2D = null
var zoom_level: float = 1.0
var base_width: float = 202.0
var base_height: float = 270.0
var orientation: int = 0  # 0=vertical, 1=horizontal, 2=square

var effect_settings: Array = []

func get_orientation_dimensions() -> Vector2:
	match orientation:
		1: return Vector2(270, 202)  # Horizontal
		2: return Vector2(256, 256)  # Square
		_: return Vector2(202, 270)  # Vertical (default)

func update_from_zoom(zoom: float) -> void:
	zoom_level = zoom
	var base = get_orientation_dimensions()
	base_width = base.x
	base_height = base.y
	card_size = Vector2(base_width * zoom, base_height * zoom)

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
	new_state.card_size = card_size
	new_state.corner_radius = corner_radius
	new_state.game_texture = game_texture
	new_state.zoom_level = zoom_level
	new_state.base_width = base_width
	new_state.base_height = base_height
	new_state.orientation = orientation
	new_state.effect_settings = effect_settings.duplicate(true)
	return new_state
