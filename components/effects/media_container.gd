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
			changed.emit()

# --- Source texture ---
var texture: Texture2D:
	set(value):
		if texture != value:
			texture = value
			changed.emit()

# --- Visual properties (shared by all layers) ---
var corner_radius_ratio: float = 0.12
var border_inset_ratio: float = 0.0:
	set(value):
		if not is_equal_approx(border_inset_ratio, value):
			border_inset_ratio = value
			changed.emit()
var glass_inset_ratio: float = 0.0:
	set(value):
		if not is_equal_approx(glass_inset_ratio, value):
			glass_inset_ratio = value
			changed.emit()
var vertical_offset: float = 0.0:
	set(value):
		if not is_equal_approx(vertical_offset, value):
			vertical_offset = value
			changed.emit()
var zoom_level: float = 1.0
var edge_aa_enabled: bool = false

# --- Effect configuration (for saving/loading themes) ---
var effect_settings: Array = []
var focus_effect_settings: Array = []

# --- Pipeline cache (write-once per frame) ---
var pipeline_cache: Dictionary = {}

signal changed

func run_pipeline(layers: Array) -> void:
	"""Execute compute_pipeline() on all registered layers in order."""
	pipeline_cache.clear()
	for layer in layers:
		if layer is EffectBase and layer.visible and layer.enabled:
			layer.compute_pipeline(pipeline_cache)

# --- Convenience accessors ---
var size: Vector2:
	get: return bounds.size

var position: Vector2:
	get: return bounds.position

# --- Precomputed shape values ---
func get_corner_radius_pixels() -> float:
	return round(corner_radius_ratio * min(bounds.size.x, bounds.size.y) / 2.0)

func get_total_inset_pixels() -> float:
	return (border_inset_ratio + glass_inset_ratio) * bounds.size.x

func get_inner_corner_radius_pixels() -> float:
	var glass_px = glass_inset_ratio * bounds.size.x
	return max(0.0, get_corner_radius_pixels() - glass_px)

# --- Live UV transforms (don't rely on pipeline cache) ---
func get_uv_transforms() -> Dictionary:
	var result = {
		"uv_transform_scale": Vector2.ONE,
		"uv_transform_offset": Vector2.ZERO,
	}
	if not texture:
		return result
	
	var card_size = size
	var tex_size = Vector2(texture.get_width(), texture.get_height())
	
	if card_size.x <= 0 or card_size.y <= 0 or tex_size.x <= 0 or tex_size.y <= 0:
		return result
	
	var card_aspect = card_size.x / card_size.y
	var tex_aspect = tex_size.x / tex_size.y
	
	var tex_scale = Vector2(1.0, 1.0)
	if card_aspect > tex_aspect:
		tex_scale.y = tex_aspect / card_aspect
	else:
		tex_scale.x = card_aspect / tex_aspect
	
	var offset = (Vector2(1.0, 1.0) - tex_scale) * 0.5
	
	result["uv_transform_scale"] = tex_scale
	result["uv_transform_offset"] = offset
	return result
