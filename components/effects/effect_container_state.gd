class_name EffectContainerState
extends RefCounted

signal zoom_changed(new_zoom: float)
signal size_changed(new_size: Vector2)
signal orientation_changed(new_orientation: int)
signal corner_radius_changed(new_ratio: float)
signal border_inset_changed(new_ratio: float)
signal shape_changed()

# Base dimensions (unscaled reference sizes)
var base_size: Vector2 = Vector2(202.0, 270.0)

# Container properties - reactive
var zoom_level: float = 1.0:
	set(value):
		if not is_equal_approx(zoom_level, value):
			zoom_level = value
			_recalculate_dimensions()
			zoom_changed.emit(value)

var container_size: Vector2 = base_size:
	set(value):
		if container_size != value:
			container_size = value
			size_changed.emit(value)
			_recalculate_shape()

var orientation: int = 0:  # 0=vertical, 1=horizontal, 2=square
	set(value):
		if orientation != value:
			orientation = value
			_recalculate_dimensions()
			orientation_changed.emit(value)

# Corner radius as ratio where 0.0 = square, 1.0 = corners touch (pill/circle)
var corner_radius_ratio: float = 0.06:
	set(value):
		var clamped = clampf(value, 0.0, 1.0)
		if not is_equal_approx(corner_radius_ratio, clamped):
			corner_radius_ratio = clamped
			_recalculate_shape()
			corner_radius_changed.emit(clamped)

# Border inset as ratio of width (0.0 - 1.0)
var border_inset_ratio: float = 0.0:
	set(value):
		var clamped = clampf(value, 0.0, 0.5)
		if not is_equal_approx(border_inset_ratio, clamped):
			border_inset_ratio = clamped
			_recalculate_shape()
			border_inset_changed.emit(clamped)

# Glass inset as ratio of width (0.0 - 1.0) - additional inset from glass effect
var glass_inset_ratio: float = 0.0:
	set(value):
		var clamped = clampf(value, 0.0, 0.5)
		if not is_equal_approx(glass_inset_ratio, clamped):
			glass_inset_ratio = clamped
			_recalculate_shape()

# Computed dimensions
var game_texture: Texture2D = null
var effect_settings: Array = []
var focus_effect_settings: Array = []

# Shared shape parameters for SDF calculations (calculated once, used by all effects)
var corner_radius_pixels: float = 0.0
var total_inset_pixels: float = 0.0
var inner_corner_radius_pixels: float = 0.0  # Radius after glass inset

# UV transform parameters for effects that sample game_texture
# Calculated by base_card_effect and used by other effects to match base card's sampling
var uv_transform_scale: Vector2 = Vector2(1.0, 1.0)
var uv_transform_offset: Vector2 = Vector2(0.0, 0.0)
var vertical_offset: float = 0.0

# Backward compatibility alias: card_size → container_size
func _get(property: StringName):
	if property == &"card_size":
		return container_size
	return null

func _set(property: StringName, value: Variant) -> bool:
	if property == &"card_size":
		container_size = value
		return true
	return false

func _init(p_base_size: Vector2 = Vector2(202.0, 270.0)) -> void:
	base_size = p_base_size
	container_size = base_size
	_recalculate_dimensions()
	_recalculate_shape()

func _recalculate_dimensions() -> void:
	var base = _get_base_dimensions()
	container_size = base * zoom_level

func _get_base_dimensions() -> Vector2:
	match orientation:
		1: return Vector2(base_size.y, base_size.x)  # Horizontal swap
		2: return Vector2(base_size.x, base_size.x)  # Square
		_: return base_size  # Vertical

# Recalculates shape parameters that all shaders use
func _recalculate_shape() -> void:
	# Corner radius in pixels (using min dimension like border shader)
	corner_radius_pixels = corner_radius_ratio * min(container_size.x, container_size.y) / 2.0
	
	# Total inset combines border and glass
	total_inset_pixels = (border_inset_ratio + glass_inset_ratio) * container_size.x
	
	# Inner corner radius after glass inset (for badge clipping)
	var glass_inset_pixels = glass_inset_ratio * container_size.x
	inner_corner_radius_pixels = max(0.0, corner_radius_pixels - glass_inset_pixels)
	
	shape_changed.emit()

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

func get_focus_effect_config(effect_id: String) -> Dictionary:
	for effect_data in focus_effect_settings:
		if effect_data is Dictionary and effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}

func set_focus_effect_config(effect_id: String, config: Dictionary) -> void:
	for i in range(focus_effect_settings.size()):
		if focus_effect_settings[i] is Dictionary and focus_effect_settings[i].get("effect_id") == effect_id:
			focus_effect_settings[i] = config.duplicate()
			return
	focus_effect_settings.append(config.duplicate())

func duplicate() -> EffectContainerState:
	var new_state = EffectContainerState.new(base_size)
	new_state.zoom_level = zoom_level
	new_state.orientation = orientation
	new_state.corner_radius_ratio = corner_radius_ratio
	new_state.border_inset_ratio = border_inset_ratio
	new_state.glass_inset_ratio = glass_inset_ratio
	new_state.game_texture = game_texture
	new_state.effect_settings = effect_settings.duplicate(true)
	new_state.focus_effect_settings = focus_effect_settings.duplicate(true)
	# _recalculate_dimensions will be called in _init, but container_size will be recalculated
	new_state.container_size = container_size
	return new_state

# Static factory methods for common use cases
static func for_card() -> EffectContainerState:
	return EffectContainerState.new(Vector2(202.0, 270.0))

static func for_hero() -> EffectContainerState:
	return EffectContainerState.new(Vector2(1920.0, 640.0))
