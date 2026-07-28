class_name MediaContainer
extends RefCounted

const _LOGO_MODE_INCLUDE: int = 0
const _LOGO_MODE_EXCLUDE: int = 1
const _LOGO_MARGIN: float = 0.02

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

var logo_rect: Vector4 = Vector4.ZERO:
	set(value):
		if logo_rect != value:
			logo_rect = value
			_uv_cache_valid = false
			changed.emit()

var logo_mode: int = 0:
	set(value):
		if logo_mode != value:
			logo_mode = value
			_uv_cache_valid = false
			changed.emit()

# --- Effect configuration (for saving/loading themes) ---
var effect_settings: Array = []
var focus_effect_settings: Array = []

signal changed

func run_pipeline(layers: Array) -> void:
	"""Execute compute_pipeline() on all registered layers in order."""
	for layer in layers:
		if layer is EffectBase and layer.enabled:
			layer.compute_pipeline({})

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

# --- Cached UV transforms (invalidated on bounds/texture/logo change) ---
var _uv_scale: Vector2 = Vector2.ONE
var _uv_offset: Vector2 = Vector2.ZERO
var _uv_cache_valid: bool = false

func _recompute_uv_cache() -> void:
	_uv_scale = Vector2.ONE
	_uv_offset = Vector2.ZERO
	if not texture:
		_uv_cache_valid = true
		return
	var card_size = size
	var tex_size = Vector2(texture.get_width(), texture.get_height())
	if card_size.x <= 0 or card_size.y <= 0 or tex_size.x <= 0 or tex_size.y <= 0:
		_uv_cache_valid = true
		return
	var card_aspect = card_size.x / card_size.y
	var tex_aspect = tex_size.x / tex_size.y
	if card_aspect > tex_aspect:
		_uv_scale.y = tex_aspect / card_aspect
	else:
		_uv_scale.x = card_aspect / tex_aspect
	_uv_offset = (Vector2(1.0, 1.0) - _uv_scale) * 0.5

	if logo_rect.z > 0.0 and logo_rect.w > 0.0:
		var result := _apply_logo_transform(_uv_scale, _uv_offset, logo_rect, logo_mode)
		_uv_scale = result.scale
		_uv_offset = result.offset

	_uv_cache_valid = true

func _apply_logo_transform(base_scale: Vector2, base_offset: Vector2, rect: Vector4, mode: int) -> Dictionary:
	var inflated := _inflate_logo_rect(rect, _LOGO_MARGIN)
	if mode == _LOGO_MODE_INCLUDE:
		return _include_logo_transform(base_scale, base_offset, inflated)
	return _exclude_logo_transform(base_scale, base_offset, inflated)

func _inflate_logo_rect(rect: Vector4, margin: float) -> Vector4:
	var x1: float = max(0.0, rect.x - margin)
	var y1: float = max(0.0, rect.y - margin)
	var x2: float = min(1.0, rect.x + rect.z + margin)
	var y2: float = min(1.0, rect.y + rect.w + margin)
	return Vector4(x1, y1, x2 - x1, y2 - y1)

func _include_logo_transform(base_scale: Vector2, base_offset: Vector2, rect: Vector4) -> Dictionary:
	var base_x1: float = base_offset.x
	var base_y1: float = base_offset.y
	var base_x2: float = base_x1 + base_scale.x
	var base_y2: float = base_y1 + base_scale.y
	if rect.x >= base_x1 and rect.y >= base_y1 and rect.x + rect.z <= base_x2 and rect.y + rect.w <= base_y2:
		return {"scale": base_scale, "offset": base_offset}

	var aspect: float = base_scale.x / base_scale.y
	var w: float = max(rect.z, rect.w * aspect)
	var h: float = w / aspect
	w = max(w, base_scale.x)
	h = max(h, base_scale.y)
	if w > 1.0 or h > 1.0:
		return {"scale": base_scale, "offset": base_offset}

	var cx: float = rect.x + rect.z * 0.5
	var cy: float = rect.y + rect.w * 0.5
	var ox: float = clamp(cx - w * 0.5, 0.0, 1.0 - w)
	var oy: float = clamp(cy - h * 0.5, 0.0, 1.0 - h)
	return {"scale": Vector2(w, h), "offset": Vector2(ox, oy)}

func _exclude_logo_transform(base_scale: Vector2, base_offset: Vector2, rect: Vector4) -> Dictionary:
	var aspect: float = base_scale.x / base_scale.y
	var best_scale := base_scale
	var best_offset := base_offset
	var best_area: float = -1.0

	var avail_w: float = rect.x
	if avail_w > 0.0:
		var w: float = min(avail_w, aspect)
		var h: float = w / aspect
		var area: float = w * h
		if area > best_area:
			best_area = area
			best_scale = Vector2(w, h)
			best_offset = Vector2(0.0, (1.0 - h) * 0.5)

	avail_w = 1.0 - (rect.x + rect.z)
	if avail_w > 0.0:
		var w: float = min(avail_w, aspect)
		var h: float = w / aspect
		var area: float = w * h
		if area > best_area:
			best_area = area
			best_scale = Vector2(w, h)
			best_offset = Vector2(1.0 - w, (1.0 - h) * 0.5)

	var avail_h: float = rect.y
	if avail_h > 0.0:
		var h: float = min(avail_h, 1.0 / aspect)
		var w: float = h * aspect
		var area: float = w * h
		if area > best_area:
			best_area = area
			best_scale = Vector2(w, h)
			best_offset = Vector2((1.0 - w) * 0.5, 0.0)

	avail_h = 1.0 - (rect.y + rect.w)
	if avail_h > 0.0:
		var h: float = min(avail_h, 1.0 / aspect)
		var w: float = h * aspect
		var area: float = w * h
		if area > best_area:
			best_area = area
			best_scale = Vector2(w, h)
			best_offset = Vector2((1.0 - w) * 0.5, 1.0 - h)

	var base_area: float = base_scale.x * base_scale.y
	if best_area < base_area * 0.1:
		return {"scale": base_scale, "offset": base_offset}
	return {"scale": best_scale, "offset": best_offset}

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
