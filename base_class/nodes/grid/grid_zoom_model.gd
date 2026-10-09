class_name GridZoomModel
extends RefCounted

## Pure zoom-state model for VirtualScrollGridContainer: the SINGLE owner of
## zoom structure. State is an items-per-line count N (GRID) or a scroll-axis
## line count k (LIST/CAROUSEL); every ratio/zoom/card-size figure is DERIVED
## from that structure plus the inputs below. No other component may store a
## second copy — the grid's target_card_width_ratio facade and the toolbar
## slider read get_ratio(), and external ratio writes funnel through
## set_ratio(), which resolves structure immediately (GRID) or on next layout
## (LIST/CAROUSEL).
##
## Pure: no scene-tree access. All inputs are pushed via configure() /
## set_available_size(); internal stop caches invalidate themselves.

enum Mode { GRID, LIST, CAROUSEL }

const MIN_CARD_SIZE_FRACTION := 0.45
const MAX_ZOOM_STOPS := 12
const ZOOM_SINGLE_STEP_MAX := 6
const MIN_RATIO := 0.05

# --- Inputs (pushed by the grid) ---
var _mode: int = Mode.GRID
var _vertical: bool = true
var _separation: int = 0
var _base_dims: Vector2 = Vector2.ZERO
var _available: Vector2 = Vector2.ZERO
## False while the grid's startup layout is suppressed: no structure is
## resolved and external ratio writes are stored unsnapped, because transient
## startup sizes would snap to the wrong stop.
var resolution_enabled: bool = true

# --- Structure (the owned truth; 0 = unresolved, derive from pending ratio) ---
var _n_grid: int = 0
var _k_lines: int = 0
## Ratio remembered while structure is unresolved (startup, stamps). Once N/k
## resolves, the ratio derives from structure and this is only a seed.
var _pending_ratio: float = 0.15

# --- Self-invalidating stop caches ---
var _stops_cache: Array[int] = []
var _stops_key: String = ""


## Push structural inputs. Returns true when the stop list changed as a result.
func configure(p_mode: int, p_vertical: bool, p_separation: int, p_base_dims: Vector2) -> bool:
	var before := _stops_key
	_mode = p_mode
	_vertical = p_vertical
	_separation = p_separation
	_base_dims = p_base_dims
	_recompute_if_needed()
	return _stops_key != before


func set_available_size(avail: Vector2) -> bool:
	var before := _stops_key
	_available = avail
	_recompute_if_needed()
	return _stops_key != before


func has_valid_size() -> bool:
	return _available.x > 0.0 and _available.y > 0.0


func _key() -> String:
	return "%d|%d|%d|%d|%d|%d|%d" % [_mode, int(_base_dims.x), int(_base_dims.y), int(_available.x), int(_available.y), _separation, 1 if _vertical else 0]


func _recompute_if_needed() -> void:
	if not has_valid_size():
		_stops_cache = []
		_stops_key = ""
		return
	var k := _key()
	if k == _stops_key:
		return
	_stops_key = k
	_stops_cache = _compute_stops()


## Ascending stops for the current inputs. GRID: items-per-line levels (every
## stop exactly fills the cross axis AND fits the scroll axis). LIST/CAROUSEL:
## cards along the scroll axis (every stop fills the cross axis exactly).
## Do not mutate the returned array (it is the cache).
func get_stops() -> Array[int]:
	_recompute_if_needed()
	return _stops_cache


func _compute_stops() -> Array[int]:
	if _mode == Mode.GRID:
		return _compute_grid_stops()
	var scroll_axis: float = _available.y if _vertical else _available.x
	var base_scroll: float = _base_dims.y if _vertical else _base_dims.x
	var min_card := base_scroll * MIN_CARD_SIZE_FRACTION
	var k_max := maxi(1, int((scroll_axis + _separation) / (min_card + _separation)))
	return _build_stop_levels(1, k_max)


func _compute_grid_stops() -> Array[int]:
	# Largest N whose exact-fill card still meets the minimum size floor.
	var cross_axis := _available.x if _vertical else _available.y
	var base_cross := _base_dims.x if _vertical else _base_dims.y
	var min_card := base_cross * MIN_CARD_SIZE_FRACTION
	var n_max := maxi(2, int((cross_axis + _separation) / (min_card + _separation)))

	# Scroll-axis fit floor: the exact-fill card derived from N must show its
	# WHOLE row/column within the viewport — the largest zoom never extends a
	# card past the grid bounds (e.g. portrait art on a landscape screen).
	var n_min := 2
	if _base_dims.x > 0.0 and _base_dims.y > 0.0:
		var aspect := (_base_dims.y / _base_dims.x) if _vertical else (_base_dims.x / _base_dims.y)
		var scroll_axis := _available.y if _vertical else _available.x
		if aspect > 0.0 and scroll_axis > 0.0:
			var denom := scroll_axis / aspect + _separation
			if denom > 0.0:
				n_min = maxi(2, int(ceil((cross_axis + _separation) / denom)))
	n_min = mini(n_min, n_max)
	return _build_stop_levels(n_min, n_max)


## Builds an ascending stop list in [n_min, n_max]: single steps through
## ZOOM_SINGLE_STEP_MAX, then coarse steps, N_max always included, trimmed to
## MAX_ZOOM_STOPS.
func _build_stop_levels(n_min: int, n_max: int) -> Array[int]:
	var levels: Array[int] = []
	var n := n_min
	while n <= mini(n_max, ZOOM_SINGLE_STEP_MAX):
		levels.append(n)
		n += 1
	n = maxi(n_min, ZOOM_SINGLE_STEP_MAX + 2)
	while n < n_max:
		levels.append(n)
		n += 2
	if levels.is_empty() or levels[-1] != n_max:
		levels.append(n_max)
	# Keep the slider usable: trim stops adjacent to N_max first so both the
	# small-N range and the extreme zoom-out stop survive.
	while levels.size() > MAX_ZOOM_STOPS:
		levels.remove_at(levels.size() - 2)
	return levels


## Direct GRID items-per-line write (the grid captures its scroll anchor
## around this call). Returns true if N changed.
func set_grid_n(n: int) -> bool:
	if _n_grid == n:
		return false
	_n_grid = n
	return true


func has_grid_n() -> bool:
	return _n_grid > 0


func has_lines() -> bool:
	return _k_lines > 0


# --- Structure accessors -----------------------------------------------------

## Effective items-per-line for GRID. Lazily derives N from the pending ratio
## once resolution is allowed; 0 means "stay on the ratio path" (startup).
func get_grid_n() -> int:
	if _n_grid > 0:
		return _n_grid
	if resolution_enabled and has_valid_size():
		_n_grid = nearest_grid_stop(_pending_ratio)
	return _n_grid


## Effective scroll-axis stop k for LIST/CAROUSEL. Lazily resolves from the
## pending ratio once resolution is allowed.
func get_lines_visible() -> int:
	if _k_lines > 0:
		return _k_lines
	if resolution_enabled and has_valid_size():
		_k_lines = resolve_lines_for_ratio(_pending_ratio)
	return maxi(1, _k_lines)


## Clamp resolved structure into the current stop range (viewport shrunk or
## base dims changed). Called by the grid's layout pass. Returns true if the
## structure changed.
func clamp_structure_to_stops() -> bool:
	var stops := get_stops()
	if stops.is_empty():
		return false
	if _mode == Mode.GRID:
		if _n_grid > 0 and (_n_grid < stops[0] or _n_grid > stops[-1]):
			_n_grid = clampi(_n_grid, stops[0], stops[-1])
			return true
	else:
		if _k_lines > 0 and (_k_lines < stops[0] or _k_lines > stops[-1]):
			_k_lines = clampi(_k_lines, stops[0], stops[-1])
			return true
	return false


# --- Level mapping (index into the stop list, 0 = largest cards) -------------

func get_level() -> int:
	var stops := get_stops()
	if stops.is_empty():
		return -1
	if _mode == Mode.GRID:
		var n := _n_grid if _n_grid > 0 else nearest_grid_stop(_pending_ratio)
		var best := 0
		for i in range(stops.size()):
			if absi(stops[i] - n) < absi(stops[best] - n):
				best = i
		return best
	var k := _k_lines
	if k <= 0:
		k = resolve_lines_for_ratio(_pending_ratio)
	return stops.find(k)


## Apply a zoom level. Returns true if the effective zoom structure changed.
func set_level(level: int) -> bool:
	var stops := get_stops()
	if stops.is_empty():
		return false
	var unit: int = stops[clampi(level, 0, stops.size() - 1)]
	if _mode == Mode.GRID:
		if _n_grid == unit:
			return false
		_n_grid = unit
		return true
	# LIST/CAROUSEL: a resolved identical k is a no-op (matches the legacy
	# "k == current and already resolved" early-out).
	if unit == get_lines_visible() and _k_lines > 0:
		return false
	_k_lines = unit
	_pending_ratio = scroll_stop_fraction(unit)
	return true


# --- Ratio mapping ------------------------------------------------------------

## The current zoom ratio, DERIVED from structure when possible.
func get_ratio() -> float:
	if has_valid_size():
		if _mode == Mode.GRID:
			if _n_grid > 0:
				return ratio_for_grid_n(_n_grid)
		else:
			if _k_lines > 0:
				return scroll_stop_fraction(_k_lines)
	return _pending_ratio


## External ratio write (toolbar fallback, saved-ratio restore). GRID resolves
## structure immediately when sizes are trustworthy; LIST/CAROUSEL stores the
## fraction and re-resolves k on next layout. Returns true if anything changed.
func set_ratio(ratio: float) -> bool:
	var clamped := clampf(ratio, MIN_RATIO, get_max_ratio())
	if _mode == Mode.GRID and resolution_enabled and has_valid_size():
		var n := nearest_grid_stop(clamped)
		if _n_grid == n:
			return false
		_n_grid = n
		return true
	var changed := not is_equal_approx(_pending_ratio, clamped) or _k_lines != 0
	_pending_ratio = clamped
	# External writes re-resolve the LIST/CAROUSEL stop on next read — this is
	# the fix for the stale _scroll_axis_lines cache regression.
	_k_lines = 0
	return changed


## Stamp a ratio without resolving structure (hidden views settle on show).
func stamp_ratio(ratio: float) -> void:
	_pending_ratio = clampf(ratio, MIN_RATIO, get_max_ratio())
	_k_lines = 0


## Internal sync from the layout pass: records the derived ratio without
## touching structure. With get_ratio() deriving from structure this is only
## meaningful while structure is unresolved (startup), but harmless always.
func sync_ratio(ratio: float) -> void:
	_pending_ratio = ratio


func get_max_ratio() -> float:
	if not has_valid_size():
		return 0.5
	if _mode == Mode.LIST or _mode == Mode.CAROUSEL:
		# Ratio IS the scroll-axis fill fraction; the largest stop (k=1) fills
		# it exactly.
		return 1.0
	# Cap at the largest FIT-AWARE stop (stops[0] = smallest legal N): never
	# allow a zoom whose cards extend past the viewport on the scroll axis.
	var stops := get_stops()
	var cap_n := stops[0] if not stops.is_empty() else 2
	return maxf(ratio_for_grid_n(cap_n), MIN_RATIO)


## Ratio for a GRID items-per-line count: exact-fill card area / viewport area.
func ratio_for_grid_n(n: int) -> float:
	var viewport_area := _available.x * _available.y
	if viewport_area <= 0.0 or _base_dims.x <= 0.0 or _base_dims.y <= 0.0:
		return _pending_ratio
	var card := grid_card_size_for_n(n)
	return maxf(sqrt((card.x * card.y) / viewport_area), MIN_RATIO)


## Exact-fill GRID card size for N items per line: N whole cards share the
## cross axis; the scroll axis follows the base aspect.
func grid_card_size_for_n(n: int) -> Vector2:
	var cross_axis := _available.x if _vertical else _available.y
	var base_cross := _base_dims.x if _vertical else _base_dims.y
	var other_base := _base_dims.y if _vertical else _base_dims.x
	var card_cross := maxf((cross_axis - (n - 1) * _separation) / n, base_cross * 0.1)
	if _vertical:
		return Vector2(card_cross, card_cross * other_base / base_cross)
	return Vector2(card_cross * other_base / base_cross, card_cross)


## Card size for LIST/CAROUSEL stop k: cross axis fills exactly, scroll axis
## is (scroll_axis − (k−1)·sep) / k.
func scroll_stop_size(k: int) -> Vector2:
	var scroll_axis: float = _available.y if _vertical else _available.x
	var cross_axis: float = _available.x if _vertical else _available.y
	var cell := maxf(1.0, (scroll_axis - (k - 1) * _separation) / float(k))
	return Vector2(cross_axis, cell) if _vertical else Vector2(cell, cross_axis)


## The stop's zoom fraction (card scroll dim / viewport scroll dim) — the
## value persisted as card_zoom_list_ratio.
func scroll_stop_fraction(k: int) -> float:
	var scroll_axis: float = _available.y if _vertical else _available.x
	if scroll_axis <= 0.0:
		return 0.25
	var s := scroll_stop_size(k)
	return (s.y if _vertical else s.x) / scroll_axis


## Maps a scroll-fill fraction to the nearest LIST/CAROUSEL stop's k.
func resolve_lines_for_ratio(ratio: float) -> int:
	var stops := get_stops()
	if stops.is_empty():
		return 2
	var scroll_axis: float = _available.y if _vertical else _available.x
	var ideal: float = scroll_axis * clampf(ratio, MIN_RATIO, 1.0)
	var k := clampi(int(round((scroll_axis + _separation) / maxf(1.0, ideal + _separation))), 1, stops[stops.size() - 1])
	var best: int = stops[0]
	for s in stops:
		if absi(s - k) < absi(best - k):
			best = s
	return best


## Maps a viewport-area ratio to the nearest GRID items-per-line stop.
func nearest_grid_stop(ratio: float) -> int:
	var stops := get_stops()
	if stops.is_empty():
		return 2
	var n: int = stops[stops.size() - 1]
	var viewport_area := _available.x * _available.y
	var base_area := _base_dims.x * _base_dims.y
	if viewport_area > 0.0 and base_area > 0.0:
		var card_area := viewport_area * ratio * ratio
		var desired_zoom := sqrt(card_area / base_area)
		var desired_cross := (_base_dims.x if _vertical else _base_dims.y) * desired_zoom
		var cross_axis := _available.x if _vertical else _available.y
		n = clampi(int(round((cross_axis + _separation) / maxf(1.0, desired_cross + _separation))), 2, stops[stops.size() - 1])
	var best: int = stops[0]
	for l in stops:
		if absi(l - n) < absi(best - n):
			best = l
	return best


# --- Slider views --------------------------------------------------------------

## Snap ratios ordered most-zoomed-out first (index 0 = smallest ratio), one
## per stop, for ALL modes — the unified view the zoom slider consumes.
func get_snap_ratios_desc() -> Array[float]:
	var ratios: Array[float] = []
	if not has_valid_size():
		return ratios
	var stops := get_stops()
	for i in range(stops.size() - 1, -1, -1):
		if _mode == Mode.GRID:
			ratios.append(ratio_for_grid_n(stops[i]))
		else:
			ratios.append(scroll_stop_fraction(stops[i]))
	return ratios


## Snap ratios ascending (index 0 = most items per line); slider index maps
## directly to a zoom level.
func get_snap_ratios_ascending() -> Array[float]:
	var ratios := get_snap_ratios_desc()
	ratios.reverse()
	return ratios


func ratio_for_level(level: int) -> float:
	var stops := get_stops()
	if stops.is_empty():
		return _pending_ratio
	var unit: int = stops[clampi(level, 0, stops.size() - 1)]
	if _mode == Mode.GRID:
		return ratio_for_grid_n(unit)
	return scroll_stop_fraction(unit)
