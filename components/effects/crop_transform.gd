class_name CropTransform
extends RefCounted

## Shared crop-UV math for cover images. Computes the (scale, offset) UV
## transform that cover-crops a texture of aspect `tex_aspect` into a panel of
## aspect `panel_aspect`, adjusted around the detected logo box when present.
##
## Used by MediaContainer at runtime and by the logo-box worker to precompute
## per-(ratio, mode) transforms stored in the DB. Single source of truth so
## cached entries and runtime results are provably identical.

const LOGO_MODE_INCLUDE := 0
const LOGO_MODE_EXCLUDE := 1
const LOGO_MARGIN := 0.02

## card_media_aspect_ratio index -> panel aspect (index 0 = Fill, not cacheable).
const RATIO_BY_INDEX := {
	1: 2.0 / 3.0,
	2: 3.0 / 4.0,
	3: 1.0,
	4: 16.0 / 11.0,
}

## Maps a ratio float to its index (1-4), or 0 for Fill/unknown.
static func index_for_ratio(ratio: float) -> int:
	for idx in RATIO_BY_INDEX:
		if is_equal_approx(ratio, RATIO_BY_INDEX[idx]):
			return idx
	return 0

## Computes the UV transform. Returns {"scale": Vector2, "offset": Vector2}.
static func compute(tex_aspect: float, panel_aspect: float, p_logo_rect: Vector4, mode: int) -> Dictionary:
	var scale := Vector2.ONE
	if tex_aspect <= 0.0 or panel_aspect <= 0.0:
		return {"scale": scale, "offset": Vector2.ZERO}
	if panel_aspect > tex_aspect:
		scale.y = tex_aspect / panel_aspect
	else:
		scale.x = panel_aspect / tex_aspect
	var offset := (Vector2.ONE - scale) * 0.5

	if p_logo_rect.z > 0.0 and p_logo_rect.w > 0.0:
		var result := _apply_logo_transform(scale, offset, p_logo_rect, mode)
		scale = result.scale
		offset = result.offset
	return {"scale": scale, "offset": offset}

static func _apply_logo_transform(base_scale: Vector2, base_offset: Vector2, rect: Vector4, mode: int) -> Dictionary:
	var inflated := _inflate_logo_rect(rect, LOGO_MARGIN)
	if mode == LOGO_MODE_INCLUDE:
		return _include_logo_transform(base_scale, base_offset, inflated)
	return _exclude_logo_transform(base_scale, base_offset, inflated)

static func _inflate_logo_rect(rect: Vector4, margin: float) -> Vector4:
	var x1: float = max(0.0, rect.x - margin)
	var y1: float = max(0.0, rect.y - margin)
	var x2: float = min(1.0, rect.x + rect.z + margin)
	var y2: float = min(1.0, rect.y + rect.w + margin)
	return Vector4(x1, y1, x2 - x1, y2 - y1)

static func _include_logo_transform(base_scale: Vector2, base_offset: Vector2, rect: Vector4) -> Dictionary:
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

static func _exclude_logo_transform(base_scale: Vector2, base_offset: Vector2, rect: Vector4) -> Dictionary:
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
