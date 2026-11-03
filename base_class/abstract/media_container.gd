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
## Final content aperture computed by EffectStack's ordered geometry pass.
var content_inset_pixels: float = 0.0:
	set(value):
		var clamped := maxf(0.0, value)
		if not is_equal_approx(content_inset_pixels, clamped):
			content_inset_pixels = clamped
			_shape_cache_valid = false
			_uv_cache_valid = false
var wrap_inset_top_ratio: float = 0.0:
	set(value):
		if not is_equal_approx(wrap_inset_top_ratio, value):
			wrap_inset_top_ratio = value
			_shape_cache_valid = false
			_uv_cache_valid = false
			changed.emit()
var wrap_inset_left_ratio: float = 0.0:
	set(value):
		if not is_equal_approx(wrap_inset_left_ratio, value):
			wrap_inset_left_ratio = value
			_shape_cache_valid = false
			_uv_cache_valid = false
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

# --- Convenience accessors ---
var size: Vector2:
	get: return bounds.size

var position: Vector2:
	get: return bounds.position

# --- Cached shape values (invalidated on property change) ---
var _corner_radius_px: float = 0.0
var _total_inset_px: float = 0.0
var _inner_corner_radius_px: float = 0.0
var _wrap_inset_top_px: float = 0.0
var _wrap_inset_left_px: float = 0.0
var _shape_cache_valid: bool = false

func _recompute_shape_cache() -> void:
	var w = bounds.size.x
	var h = bounds.size.y
	_corner_radius_px = round(corner_radius_ratio * min(w, h) / 2.0)
	_total_inset_px = content_inset_pixels
	_inner_corner_radius_px = max(0.0, _corner_radius_px - _total_inset_px)
	_wrap_inset_top_px = wrap_inset_top_ratio * h
	_wrap_inset_left_px = wrap_inset_left_ratio * w
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

func get_wrap_inset_top_pixels() -> float:
	if not _shape_cache_valid:
		_recompute_shape_cache()
	return _wrap_inset_top_px

func get_wrap_inset_left_pixels() -> float:
	if not _shape_cache_valid:
		_recompute_shape_cache()
	return _wrap_inset_left_px

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

	# Always crop against the final content aperture. Symmetric depth applies
	# on every side; directional wrap claims reduce only their own axes.
	var total_inset := get_total_inset_pixels()
	var panel_size: Vector2 = card_size - Vector2(
		total_inset * 2.0 + get_wrap_inset_left_pixels(),
		total_inset * 2.0 + get_wrap_inset_top_pixels()
	)
	if panel_size.x <= 0 or panel_size.y <= 0:
		return

	var uv := compute_cover_uv(panel_size, tex_size)
	_uv_scale = uv.scale
	_uv_offset = uv.offset
	_uv_offset.y -= vertical_offset

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

## Shared center-cover calculation for both EffectStack media and the simple
## M3Card fast path. Input is always the actual visible content aperture.
static func compute_cover_uv(target_size: Vector2, tex_size: Vector2) -> Dictionary:
	var scale := Vector2.ONE
	var offset := Vector2.ZERO
	if target_size.x <= 0.0 or target_size.y <= 0.0 or tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return {"scale": scale, "offset": offset}
	var card_aspect := target_size.x / target_size.y
	var tex_aspect := tex_size.x / tex_size.y
	if card_aspect > tex_aspect:
		scale.y = tex_aspect / card_aspect
	else:
		scale.x = card_aspect / tex_aspect
	offset = (Vector2.ONE - scale) * 0.5
	return {"scale": scale, "offset": offset}
