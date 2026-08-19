class_name MediaContainer
extends RefCounted

## Single source of truth for effect rendering bounds and shared state.
## Owned by EffectStack. Cards/heroes/transitions set bounds to where
## media lives; effects fill that rectangle and nothing else.

# --- Core bounds (where effects render) ---
var bounds: Rect2:
	set(value):
		if bounds != value:
			bounds = value
			_shape_cache_valid = false
			_uv_cache_valid = false
			changed.emit()

# --- Source texture ---
var texture: Texture2D:
	set(value):
		if texture != value:
			texture = value
			_uv_cache_valid = false
			changed.emit()

# --- Visual properties (shared by all layers) ---
var corner_radius_ratio: float = 0.12:
	set(value):
		if not is_equal_approx(corner_radius_ratio, value):
			corner_radius_ratio = value
			_shape_cache_valid = false
var border_inset_ratio: float = 0.0:
	set(value):
		if not is_equal_approx(border_inset_ratio, value):
			border_inset_ratio = value
			_shape_cache_valid = false
			changed.emit()
var glass_inset_ratio: float = 0.0:
	set(value):
		if not is_equal_approx(glass_inset_ratio, value):
			glass_inset_ratio = value
			_shape_cache_valid = false
			changed.emit()
var vertical_offset: float = 0.0:
	set(value):
		if not is_equal_approx(vertical_offset, value):
			vertical_offset = value
			changed.emit()
var edge_aa_enabled: bool = false

## When true, the base card shader renders an animated skeleton shimmer
## instead of the source texture (used while cover art is loading).
var loading_active: bool = false:
	set(value):
		if loading_active != value:
			loading_active = value
			changed.emit()

# --- Effect configuration (for saving/loading themes) ---
var effect_settings: Array = []
var focus_effect_settings: Array = []

signal changed

func run_pipeline(layers: Array) -> void:
	"""Execute compute_pipeline() on all registered layers in order."""
	for layer in layers:
		if layer is EffectBase and layer.enabled:
			layer.compute_pipeline()

# --- Convenience accessors ---
var size: Vector2:
	get: return bounds.size

var position: Vector2:
	get: return bounds.position

# --- Cached shape values (invalidated on property change) ---
var _corner_radius_px: float = 0.0
var _total_inset_px: float = 0.0
var _inner_corner_radius_px: float = 0.0
var _shape_cache_valid: bool = false

func _recompute_shape_cache() -> void:
	var w = bounds.size.x
	var h = bounds.size.y
	_corner_radius_px = round(corner_radius_ratio * min(w, h) / 2.0)
	_total_inset_px = (border_inset_ratio + glass_inset_ratio) * w
	_inner_corner_radius_px = max(0.0, _corner_radius_px - _total_inset_px)
	_shape_cache_valid = true

func get_corner_radius_pixels() -> float:
	if not _shape_cache_valid:
		_recompute_shape_cache()
	return _corner_radius_px

func get_total_inset_pixels() -> float:
	if not _shape_cache_valid:
		_recompute_shape_cache()
	return _total_inset_px

func get_inner_corner_radius_pixels() -> float:
	if not _shape_cache_valid:
		_recompute_shape_cache()
	return _inner_corner_radius_px

# --- Cached UV transforms (invalidated on bounds/texture change) ---
var _uv_scale: Vector2 = Vector2.ONE
var _uv_offset: Vector2 = Vector2.ZERO
var _uv_cache_valid: bool = false

func _recompute_uv_cache() -> void:
	_uv_scale = Vector2.ONE
	_uv_offset = Vector2.ZERO
	if not texture:
		# Identity is a safe default, but do NOT validate it: once a texture
		# arrives the next read must recompute the real crop. (Baking identity
		# here was the media-ratio stretch bug.)
		return
	var card_size = size
	var tex_size = Vector2(texture.get_width(), texture.get_height())
	if card_size.x <= 0 or card_size.y <= 0 or tex_size.x <= 0 or tex_size.y <= 0:
		# Same: leave the cache invalid so a later valid state recomputes.
		return

	var card_aspect = card_size.x / card_size.y
	var tex_aspect = tex_size.x / tex_size.y

	# Plain center crop: scale so the texture covers the panel, center it.
	if card_aspect > tex_aspect:
		_uv_scale.y = tex_aspect / card_aspect
	else:
		_uv_scale.x = card_aspect / tex_aspect
	_uv_offset = (Vector2.ONE - _uv_scale) * 0.5

	_uv_cache_valid = true

func get_uv_scale() -> Vector2:
	if not _uv_cache_valid:
		_recompute_uv_cache()
	return _uv_scale

func get_uv_offset() -> Vector2:
	if not _uv_cache_valid:
		_recompute_uv_cache()
	return _uv_offset

func get_uv_transforms() -> Dictionary:
	return {
		"uv_transform_scale": get_uv_scale(),
		"uv_transform_offset": get_uv_offset(),
	}
