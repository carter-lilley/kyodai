@tool
class_name M3Progress
extends Control

## Material 3 Progress Indicator
## Linear or circular determinate progress.

enum Mode { LINEAR, CIRCULAR }
enum Size { SMALL, LARGE }

# ============================================
# EXPORTS
# ============================================

@export var mode: Mode = Mode.LINEAR:
	set(value):
		if value == mode:
			return
		mode = value
		_invalidate_min_size()
		queue_redraw()

@export var progress_size: Size = Size.SMALL:
	set(value):
		if value == progress_size:
			return
		progress_size = value
		_invalidate_min_size()
		queue_redraw()

@export var value: float = 0.0:
	set(p_value):
		var clamped = clampf(p_value, 0.0, max_value)
		if clamped == value:
			return
		value = clamped
		queue_redraw()

@export var max_value: float = 100.0:
	set(p_value):
		if p_value == max_value:
			return
		max_value = maxf(p_value, 0.001)
		value = clampf(value, 0.0, max_value)
		queue_redraw()

@export var indeterminate: bool = false:
	set(p_value):
		if p_value == indeterminate:
			return
		indeterminate = p_value
		set_process(indeterminate)
		queue_redraw()

# ============================================
# INTERNAL
# ============================================

var _track_color: Color
var _indicator_color: Color
var _endpoint_color: Color
var _indet_start: float = 0.0
var _indet_end: float = 0.0

var _cached_min_size: Vector2 = Vector2.ZERO
var _cached_min_size_dirty: bool = true

var _cap_stylebox: StyleBoxFlat
var _endpoint_stylebox: StyleBoxFlat

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_cap_stylebox = StyleBoxFlat.new()
	_cap_stylebox.set_corner_radius_all(999)
	_cap_stylebox.anti_aliasing = true
	_cap_stylebox.anti_aliasing_size = 1.0
	_cap_stylebox.set_border_width_all(0)
	
	_endpoint_stylebox = StyleBoxFlat.new()
	_endpoint_stylebox.set_corner_radius_all(999)
	_endpoint_stylebox.anti_aliasing = true
	_endpoint_stylebox.anti_aliasing_size = 1.0
	_endpoint_stylebox.set_border_width_all(0)
	
	refresh_theme()
	set_process(indeterminate)

func _process(_delta: float):
	if indeterminate:
		var t = Time.get_ticks_msec() / 1000.0
		var cycle = fmod(t, 2.0) / 2.0
		if cycle < 0.5:
			_indet_start = 0.0
			_indet_end = (cycle / 0.5)
		else:
			_indet_start = ((cycle - 0.5) / 0.5)
			_indet_end = 1.0
		queue_redraw()

func _draw():
	if mode == Mode.LINEAR:
		_draw_linear()
	else:
		_draw_circular()

# ============================================
# DRAWING
# ============================================

func _draw_linear():
	var track_height: float
	match progress_size:
		Size.LARGE:
			track_height = M3Units.dp(8)
		_:
			track_height = M3Units.dp(4)
	
	var radius = track_height / 2.0
	var rect_size_x = size.x
	var rect_size_y = size.y
	var track_y = rect_size_y / 2.0 - track_height / 2.0
	var track_center_y = track_y + radius
	
	var start_x: float
	var end_x: float
	
	if indeterminate:
		start_x = rect_size_x * _indet_start
		end_x = rect_size_x * _indet_end
	else:
		var fraction = value / max_value
		start_x = 0.0
		end_x = rect_size_x * fraction
	
	var fill_width = end_x - start_x
	
	# Draw full track behind everything
	draw_rect(Rect2(Vector2(radius, track_y), Vector2(rect_size_x - track_height, track_height)), _track_color, true)
	var cap_radius = radius * 1.0
	var left_cap_pos = Vector2(radius, track_center_y)
	var right_cap_pos = Vector2(rect_size_x - radius, track_center_y)
	_cap_stylebox.bg_color = _track_color
	draw_style_box(_cap_stylebox, Rect2(left_cap_pos.x - cap_radius, left_cap_pos.y - cap_radius, cap_radius * 2, cap_radius * 2))
	draw_style_box(_cap_stylebox, Rect2(right_cap_pos.x - cap_radius, right_cap_pos.y - cap_radius, cap_radius * 2, cap_radius * 2))
	
	# Endpoint indicator (right side only, 4dp dot)
	var endpoint_radius = M3Units.dp(2)
	_endpoint_stylebox.bg_color = _endpoint_color
	draw_style_box(_endpoint_stylebox, Rect2(right_cap_pos.x - endpoint_radius, right_cap_pos.y - endpoint_radius, endpoint_radius * 2, endpoint_radius * 2))
	
	# Draw fill on top of track
	if fill_width > 0:
		var fill_rect_width = fill_width - radius
		if fill_rect_width > 0:
			draw_rect(Rect2(Vector2(start_x + radius, track_y), Vector2(fill_rect_width, track_height)), _indicator_color, true)
		# Fill left cap
		_cap_stylebox.bg_color = _indicator_color
		draw_style_box(_cap_stylebox, Rect2(start_x + radius - cap_radius, track_center_y - cap_radius, cap_radius * 2, cap_radius * 2))
		# Fill right cap (before gap) — always draw, just like track caps
		draw_style_box(_cap_stylebox, Rect2(end_x - cap_radius, track_center_y - cap_radius, cap_radius * 2, cap_radius * 2))

func _draw_circular():
	var diameter: float
	var stroke: float
	match progress_size:
		Size.LARGE:
			diameter = M3Units.dp(44)
			stroke = M3Units.dp(8)
		_:
			diameter = M3Units.dp(40)
			stroke = M3Units.dp(4)
	
	var radius = diameter / 2.0
	var center = Vector2(size.x / 2.0, size.y / 2.0)
	
	# Track (full ring)
	_draw_thick_arc(center, radius, 0.0, TAU, _track_color, stroke)
	
	var start_fraction: float
	var end_fraction: float
	
	if indeterminate:
		start_fraction = _indet_start
		end_fraction = _indet_end
	else:
		start_fraction = 0.0
		end_fraction = value / max_value
	
	var fraction = end_fraction - start_fraction
	
	# Indicator with 4dp gap at start
	if fraction > 0:
		var gap_distance = M3Units.dp(4)
		var gap_angle = gap_distance / radius
		var progress_angle = TAU * fraction
		var start_angle = gap_angle + (TAU * start_fraction)
		var end_angle = start_angle + progress_angle
		
		if end_angle > start_angle:
			_draw_thick_arc(center, radius, start_angle, end_angle, _indicator_color, stroke)
			
			# Rounded caps at indicator endpoints
			var start_point = center + Vector2(cos(start_angle - PI / 2.0), sin(start_angle - PI / 2.0)) * radius
			var end_point = center + Vector2(cos(end_angle - PI / 2.0), sin(end_angle - PI / 2.0)) * radius
			
			var cap_radius = stroke * 0.5
			_cap_stylebox.bg_color = _indicator_color
			draw_style_box(_cap_stylebox, Rect2(start_point.x - cap_radius, start_point.y - cap_radius, cap_radius * 2, cap_radius * 2))
			draw_style_box(_cap_stylebox, Rect2(end_point.x - cap_radius, end_point.y - cap_radius, cap_radius * 2, cap_radius * 2))

func _draw_thick_arc(center: Vector2, radius: float, start_angle: float, end_angle: float, color: Color, width: float):
	# Godot angles: 0 = right, positive = counter-clockwise
	# We want 0 = top (12 o'clock), clockwise direction
	var offset = -PI / 2.0
	var actual_start = start_angle + offset
	var actual_end = end_angle + offset
	
	# Draw thick arc using Godot's draw_arc with width
	draw_arc(center, radius, actual_start, actual_end, 64, color, width, true)

# ============================================
# THEME
# ============================================

func refresh_theme():
	_track_color = M3Theme.get_elevation_surface(5)
	_indicator_color = M3Theme.get_primary()
	_endpoint_color = M3Theme.get_on_surface()
	queue_redraw()

# ============================================
# API
# ============================================

func set_fraction(fraction: float) -> void:
	value = clampf(fraction, 0.0, 1.0) * max_value

func get_fraction() -> float:
	return value / max_value if max_value > 0 else 0.0

# ============================================
# SIZE
# ============================================

func _invalidate_min_size():
	_cached_min_size_dirty = true
	update_minimum_size()

func _get_minimum_size() -> Vector2:
	if not _cached_min_size_dirty:
		return _cached_min_size
	
	if mode == Mode.LINEAR:
		var h: float
		match progress_size:
			Size.LARGE:
				h = M3Units.dp(8)
			_:
				h = M3Units.dp(4)
		_cached_min_size = Vector2(M3Units.dp(100), h)
	else:
		var d: float
		match progress_size:
			Size.LARGE:
				d = M3Units.dp(44)
			_:
				d = M3Units.dp(40)
		_cached_min_size = Vector2(d, d)
	
	_cached_min_size_dirty = false
	return _cached_min_size
