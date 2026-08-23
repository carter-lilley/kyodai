class_name FocusSubManager
extends Manager

## Owns the single global focus ring drawn above all UI.
##
## Pure RenderingServer (canvas + one canvas item): no nodes are added to the
## tree and nothing polls per frame. The manager listens to
## Viewport.gui_focus_changed, then tracks the focused control through signals
## only (item_rect_changed / visibility_changed / tree_exiting).
##
## Controls decide their own ring geometry by implementing:
##   func m3_get_focus_geometry() -> Dictionary
##       "rect":   Rect2  (canvas/global coords)
##       "radius": float  (px, uniform)           [default: default_radius_dp]
##       "shape":  int    (Shape)                 [default: ring_shape]
##       "color":  Color  (MIRROR color source)   [default: theme primary]
## The ring is opt-in: controls without the method keep their existing focus
## visuals and get no global ring (incremental migration).
##
## Controls that move without a local rect change (e.g. RenderingServer-stamped
## grid slots) push updates via FocusSubManager.notify_geometry_changed(self).
## Controls should also forward NOTIFICATION_TRANSFORM_CHANGED the same way —
## the manager enables transform notifications on whatever it tracks, so
## ancestor motion (sheet slides, dialog scale-ins) reaches the ring.

const DEBUG_LOG: bool = false

## CanvasLayer-equivalent stacking layer for the ring canvas (max is 128).
const CANVAS_LAYER: int = 128

## Draw index used when the ring is parented into a grid's visual layer.
## Cards max out at virtual_index*10 + 1_000_000 (focus boost) + 3, so this
## parks the ring above every card and effect but still below chrome (the
## visual layer lives in the TabContainer subtree; navbar/mask draw later).
const GRID_DRAW_INDEX: int = 2_000_000

enum Shape { BOX, PILL, CIRCLE, CORNERS }
enum ColorMode { PRIMARY, MIRROR, CUSTOM }
enum MovementAnim { NONE, POP, FOLLOW }
enum IdleAnim { NONE, BREATHE, CHASE }

signal config_changed

static var _instance: FocusSubManager = null

var ui_manager: Node = null

# ============================================================================
# Configuration — every setter repaints the live ring immediately
# ============================================================================

var enabled: bool = true:
	set(value):
		enabled = value
		if not is_inside_tree():
			return
		if not enabled:
			_hide_ring()
		else:
			var vp := get_viewport()
			if vp:
				_on_gui_focus_changed(vp.gui_get_focus_owner())

var ring_shape: Shape = Shape.BOX:
	set(value):
		ring_shape = value
		_on_config_changed()

var stroke_width_dp: float = 3.0:
	set(value):
		stroke_width_dp = maxf(0.0, value)
		_on_config_changed()

## Outset between the control's reported rect and the ring.
var offset_dp: float = 2.0:
	set(value):
		offset_dp = value
		_on_config_changed()

var default_radius_dp: float = 12.0:
	set(value):
		default_radius_dp = maxf(0.0, value)
		_on_config_changed()

var color_mode: ColorMode = ColorMode.PRIMARY:
	set(value):
		color_mode = value
		_on_config_changed()

var custom_color: Color = Color.WHITE:
	set(value):
		custom_color = value
		_on_config_changed()

var glow_size_dp: float = 0.0:
	set(value):
		glow_size_dp = maxf(0.0, value)
		_on_config_changed()

var glow_color: Color = Color(0.0, 0.0, 0.0, 0.35):
	set(value):
		glow_color = value
		_on_config_changed()

## NONE snaps the ring to each newly focused control, POP snaps and settles
## with a quick scale-down, FOLLOW tweens between controls.
## Indices mirror the library_focus_movement_anim setting options.
var movement_anim: MovementAnim = MovementAnim.FOLLOW
var idle_anim: IdleAnim = IdleAnim.NONE:
	set(value):
		idle_anim = value
		_on_config_changed()

## Chase tween duration (seconds).
var chase_duration: float = M3Motion.STATE

## Tick length for Shape.CORNERS.
var corner_tick_dp: float = 10.0:
	set(value):
		corner_tick_dp = maxf(1.0, value)
		_on_config_changed()

const BREATHE_PERIOD: float = 1.6
const BREATHE_MIN_ALPHA: float = 0.3
const ORBIT_PERIOD: float = 2.0
## Fraction of the perimeter covered by the CHASE comet (head + fading tail).
const ORBIT_WINDOW: float = 0.15
const ORBIT_POINTS: int = 16
## Base ring alpha multiplier while the CHASE comet orbits over it.
const ORBIT_BASE_ALPHA: float = 0.35

## POP movement: the ring snaps to the new target slightly enlarged, then
## eases back down to its exact pose.
const POP_START_SCALE: float = 1.12
const POP_DURATION: float = 0.15

# ============================================================================
# RenderingServer state
# ============================================================================

var _canvas: RID
var _ring_item: RID
var _ring_style: StyleBoxFlat = null
var _attached_viewport: Viewport = null
## Grid visual layer RID when the focused control is inside a grid; invalid
## RID means the ring is on the always-on-top viewport canvas.
var _ring_parent_grid: RID

# ============================================================================
# Target state. _dest_* is the resolved destination pose; _ring_* is the
# currently drawn pose (equal unless a chase tween is running).
# ============================================================================

var _target_ref: WeakRef = null
var _ring_rect := Rect2()
var _ring_radius: float = 0.0
var _ring_shape: int = Shape.BOX
var _ring_color: Color = Color.WHITE
var _ring_visible: bool = false
var _dest_rect := Rect2()
var _dest_radius: float = 0.0
var _dest_shape: int = Shape.BOX

var _chase_tween: Tween = null
var _idle_tween: Tween = null
var _orbit_t: float = 0.0
var _pop_tween: Tween = null
var _pop_scale: float = 1.0
var _target_prev_notify: bool = false

# ============================================================================
# Lifecycle
# ============================================================================

func _ready() -> void:
	ui_manager = get_parent()
	_instance = self

	_ring_style = StyleBoxFlat.new()
	_ring_style.bg_color = Color.TRANSPARENT
	_ring_style.anti_aliasing = true
	_ring_style.anti_aliasing_size = 1.0
	_ring_style.shadow_offset = Vector2.ZERO
	_apply_style()

	_canvas = RenderingServer.canvas_create()
	_ring_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_ring_item, _canvas)
	RenderingServer.canvas_item_set_visible(_ring_item, false)

	var vp := get_viewport()
	if vp:
		vp.gui_focus_changed.connect(_on_gui_focus_changed)
		_attach_to_viewport(vp)
		call_deferred("_initial_sync")

func _initial_sync() -> void:
	var vp := get_viewport()
	if vp:
		_on_gui_focus_changed(vp.gui_get_focus_owner())

func _exit_tree() -> void:
	if _instance == self:
		_instance = null
	_kill_chase_tween()
	_kill_pop_tween()
	_stop_idle()
	_ring_parent_grid = RID()
	if _attached_viewport and is_instance_valid(_attached_viewport):
		RenderingServer.viewport_remove_canvas(_attached_viewport.get_viewport_rid(), _canvas)
		_attached_viewport = null
	if _ring_item.is_valid():
		RenderingServer.free_rid(_ring_item)
		_ring_item = RID()
	if _canvas.is_valid():
		RenderingServer.free_rid(_canvas)
		_canvas = RID()

## Push API for controls/containers that move a focused control without
## changing its local rect (virtual grids stamping RS transforms, etc.).
static func notify_geometry_changed(control: Control) -> void:
	if _instance == null:
		return
	if _instance._get_target() == control:
		_instance._on_target_moved()

## Re-resolve style and geometry for the current target (theme/color changes).
func refresh() -> void:
	if _ring_style == null:
		return
	_apply_style()
	var t := _get_target()
	if t and _ring_visible:
		_show_target(false)

# ============================================================================
# Focus tracking (signal driven)
# ============================================================================

func _on_gui_focus_changed(control: Control) -> void:
	_untrack_target()
	if not enabled or control == null or not is_instance_valid(control) \
			or not control.is_visible_in_tree() or not control.has_method("m3_get_focus_geometry"):
		_hide_ring()
		return
	var vp := control.get_viewport()
	if vp and vp != _attached_viewport:
		_attach_to_viewport(vp)
	_track_target(control)
	_update_ring_parent(control)
	_show_target(true)

func _get_target() -> Control:
	if _target_ref == null:
		return null
	var t: Control = _target_ref.get_ref()
	if t == null or not is_instance_valid(t):
		return null
	return t

func _track_target(control: Control) -> void:
	_target_ref = weakref(control)
	# Enable global-transform notifications while tracked so ancestor motion
	# (sheet slides, dialog scale-ins, overlay moves) reaches the control and
	# is forwarded to us via the protocol. Restored on untrack.
	_target_prev_notify = control.is_transform_notification_enabled()
	control.set_notify_transform(true)
	control.item_rect_changed.connect(_on_target_moved)
	control.resized.connect(_on_target_moved)
	control.visibility_changed.connect(_on_target_visibility_changed)
	control.tree_exiting.connect(_on_target_tree_exiting)

func _untrack_target() -> void:
	var t := _get_target()
	if t:
		t.set_notify_transform(_target_prev_notify)
		if t.item_rect_changed.is_connected(_on_target_moved):
			t.item_rect_changed.disconnect(_on_target_moved)
		if t.resized.is_connected(_on_target_moved):
			t.resized.disconnect(_on_target_moved)
		if t.visibility_changed.is_connected(_on_target_visibility_changed):
			t.visibility_changed.disconnect(_on_target_visibility_changed)
		if t.tree_exiting.is_connected(_on_target_tree_exiting):
			t.tree_exiting.disconnect(_on_target_tree_exiting)
	_target_ref = null

func _on_target_moved() -> void:
	var t := _get_target()
	if t == null or not _ring_visible:
		return
	# Grid visual layers can be recreated on view rebuilds; re-resolve if the
	# one we're parented to was freed.
	if _ring_parent_grid != RID() and not _ring_parent_grid.is_valid():
		_ring_parent_grid = RID()
		_update_ring_parent(t)
	var geo := _resolve_geometry(t)
	# Dedupe: pre-draw stampers push every frame; only react to real change.
	if geo.rect.is_equal_approx(_dest_rect) and is_equal_approx(geo.radius, _dest_radius) and geo.shape == _dest_shape:
		return
	_dest_rect = geo.rect
	_dest_radius = geo.radius
	_dest_shape = geo.shape
	_ring_shape = geo.shape
	_apply_color(geo)
	# A running chase reads _dest_* live; restarting it every push (grid
	# stamps, focus-pop scale) would freeze it at frame one.
	if _chase_tween and _chase_tween.is_valid():
		return
	_ring_rect = _dest_rect
	_ring_radius = _dest_radius
	_redraw_ring()

func _on_target_visibility_changed() -> void:
	var t := _get_target()
	if t == null:
		return
	if t.is_visible_in_tree() and t.has_focus():
		_show_target(false)
	else:
		_hide_ring()

func _on_target_tree_exiting() -> void:
	# Targets can leave the tree without being freed (grid cards recycled into
	# the pool via remove_child). Disconnect through the guarded teardown so a
	# reused card doesn't accumulate duplicate connections on re-track.
	_untrack_target()
	_hide_ring()

# ============================================================================
# Geometry
# ============================================================================

func _resolve_geometry(control: Control) -> Dictionary:
	var geo: Dictionary = control.m3_get_focus_geometry()
	var rect: Rect2 = geo.get("rect", control.get_global_rect())
	var radius: float = geo.get("radius", -1.0)
	var shape: int = geo.get("shape", ring_shape)
	var color: Color = geo.get("color", Color(0.0, 0.0, 0.0, 0.0))
	if radius < 0.0:
		radius = M3Units.dp(default_radius_dp)
	radius = minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	return {"rect": rect, "radius": radius, "shape": shape, "color": color}

# ============================================================================
# Ring presentation
# ============================================================================

func _show_target(animate: bool) -> void:
	var t := _get_target()
	if t == null:
		_hide_ring()
		return
	var geo := _resolve_geometry(t)
	_dest_rect = geo.rect
	_dest_radius = geo.radius
	_dest_shape = geo.shape
	_ring_shape = geo.shape
	_apply_color(geo)
	if animate and _ring_visible and movement_anim == MovementAnim.FOLLOW:
		_start_chase()
	else:
		_kill_chase_tween()
		_ring_rect = _dest_rect
		_ring_radius = _dest_radius
		_set_ring_visible(true)
		_redraw_ring()
		if animate and movement_anim == MovementAnim.POP:
			_start_pop()
	_restart_idle()

func _hide_ring() -> void:
	_kill_chase_tween()
	_kill_pop_tween()
	_pop_scale = 1.0
	_stop_idle()
	_set_ring_visible(false)

func _set_ring_visible(value: bool) -> void:
	if _ring_visible == value:
		return
	_ring_visible = value
	if _ring_item.is_valid():
		RenderingServer.canvas_item_set_visible(_ring_item, value)

func _attach_to_viewport(vp: Viewport) -> void:
	if _attached_viewport == vp:
		return
	if _attached_viewport and is_instance_valid(_attached_viewport):
		RenderingServer.viewport_remove_canvas(_attached_viewport.get_viewport_rid(), _canvas)
	_attached_viewport = vp
	RenderingServer.viewport_attach_canvas(vp.get_viewport_rid(), _canvas)
	RenderingServer.viewport_set_canvas_stacking(vp.get_viewport_rid(), _canvas, CANVAS_LAYER, 0)

## Inside a grid the ring re-parents into the grid's visual layer (above all
## cards/effects via GRID_DRAW_INDEX, below chrome via tree order). Outside a
## grid it lives on the always-on-top viewport canvas.
func _update_ring_parent(control: Control) -> void:
	var grid_rid := _find_grid_ring_parent(control)
	if grid_rid == _ring_parent_grid:
		return
	_ring_parent_grid = grid_rid
	if not _ring_item.is_valid():
		return
	if _ring_parent_grid.is_valid():
		RenderingServer.canvas_item_set_parent(_ring_item, _ring_parent_grid)
		RenderingServer.canvas_item_set_draw_index(_ring_item, GRID_DRAW_INDEX)
	else:
		RenderingServer.canvas_item_set_parent(_ring_item, _canvas)
		RenderingServer.canvas_item_set_draw_index(_ring_item, 0)

## Walks ancestors for a VirtualScrollGridContainer (duck-typed via its public
## visual layer accessor). Returns an invalid RID when not inside a grid.
func _find_grid_ring_parent(control: Control) -> RID:
	var node := control.get_parent()
	while node:
		if node.has_method("get_visual_layer_rid"):
			var rid: RID = node.get_visual_layer_rid()
			if rid.is_valid():
				return rid
		node = node.get_parent()
	return RID()

func _apply_style() -> void:
	_ring_style.set_border_width_all(M3Units.dpi(stroke_width_dp))
	if glow_size_dp > 0.0:
		_ring_style.shadow_size = M3Units.dpi(glow_size_dp)
		_ring_style.shadow_color = glow_color
	else:
		_ring_style.shadow_size = 0
		_ring_style.shadow_color = Color.TRANSPARENT

func _apply_color(geo: Dictionary) -> void:
	match color_mode:
		ColorMode.CUSTOM:
			_ring_color = custom_color
		ColorMode.MIRROR:
			var c: Color = geo.color
			_ring_color = c if c.a > 0.0 else M3Theme.get_primary()
		_:
			_ring_color = M3Theme.get_primary()
	_ring_style.border_color = _ring_color

func _redraw_ring() -> void:
	if not _ring_item.is_valid():
		return
	RenderingServer.canvas_item_clear(_ring_item)
	if not _ring_visible:
		return
	var orbiting := idle_anim == IdleAnim.CHASE
	var base_color := _ring_color
	if orbiting:
		base_color.a *= ORBIT_BASE_ALPHA
	_ring_style.border_color = base_color
	var offset := M3Units.dp(offset_dp)
	var rect := _ring_rect.grow(offset)
	var radius := minf(_ring_radius + offset, minf(rect.size.x, rect.size.y) * 0.5)
	if _pop_scale != 1.0:
		var center := rect.get_center()
		rect = Rect2(center - rect.size * _pop_scale * 0.5, rect.size * _pop_scale)
		radius *= _pop_scale
	match _ring_shape:
		Shape.PILL:
			_ring_style.set_corner_radius_all(int(minf(rect.size.x, rect.size.y) * 0.5))
			_ring_style.draw(_ring_item, rect)
		Shape.CIRCLE:
			var side := minf(rect.size.x, rect.size.y)
			var square := Rect2(rect.get_center() - Vector2(side, side) * 0.5, Vector2(side, side))
			_ring_style.set_corner_radius_all(int(side * 0.5))
			_ring_style.draw(_ring_item, square)
		Shape.CORNERS:
			_draw_corners(rect, radius)
		_:
			_ring_style.set_corner_radius_all(int(radius))
			_ring_style.draw(_ring_item, rect)
	if orbiting:
		_draw_orbit_comet(rect, radius)

## Walk the rounded-rect perimeter; t in [0,1) wraps. Starts at the top edge
## (after the top-left arc) and proceeds clockwise.
func _perimeter_point(rect: Rect2, radius: float, t: float) -> Vector2:
	var r := clampf(radius, 0.001, minf(rect.size.x, rect.size.y) * 0.5)
	var straight_w := rect.size.x - 2.0 * r
	var straight_h := rect.size.y - 2.0 * r
	var arc := r * PI * 0.5
	var total := 2.0 * (straight_w + straight_h) + 4.0 * arc
	if total <= 0.0:
		return rect.position
	var d := fposmod(t, 1.0) * total
	var segs := [straight_w, arc, straight_h, arc, straight_w, arc, straight_h, arc]
	var idx := 0
	while idx < 8 and d > segs[idx]:
		d -= segs[idx]
		idx += 1
	var tl := rect.position
	var tr := Vector2(rect.end.x, rect.position.y)
	var br := rect.end
	var bl := Vector2(rect.position.x, rect.end.y)
	match idx:
		0:
			return Vector2(tl.x + r + d, tl.y)
		1:
			var c := tr + Vector2(-r, r)
			var a := -PI * 0.5 + d / r
			return c + Vector2(cos(a), sin(a)) * r
		2:
			return Vector2(tr.x, tr.y + r + d)
		3:
			var c := br + Vector2(-r, -r)
			var a := d / r
			return c + Vector2(cos(a), sin(a)) * r
		4:
			return Vector2(br.x - r - d, br.y)
		5:
			var c := bl + Vector2(r, -r)
			var a := PI * 0.5 + d / r
			return c + Vector2(cos(a), sin(a)) * r
		6:
			return Vector2(bl.x, bl.y - r - d)
		7:
			var c := tl + Vector2(r, r)
			var a := PI + d / r
			return c + Vector2(cos(a), sin(a)) * r
	return tl

func _draw_orbit_comet(rect: Rect2, radius: float) -> void:
	var width := M3Units.dp(stroke_width_dp)
	if width <= 0.0:
		return
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	points.resize(ORBIT_POINTS)
	colors.resize(ORBIT_POINTS)
	for i in range(ORBIT_POINTS):
		var f := float(i) / float(ORBIT_POINTS - 1)  # 0 = tail, 1 = head
		points[i] = _perimeter_point(rect, radius, _orbit_t - ORBIT_WINDOW * (1.0 - f))
		var c := _ring_color
		c.a *= f * f
		colors[i] = c
	RenderingServer.canvas_item_add_polyline(_ring_item, points, colors, width, true)
	# Round nose on the comet head (polylines end in butt caps).
	RenderingServer.canvas_item_add_circle(_ring_item, points[ORBIT_POINTS - 1], width * 0.5, _ring_color)

func _draw_corners(rect: Rect2, radius: float) -> void:
	var width := M3Units.dp(stroke_width_dp)
	if width <= 0.0:
		return
	# Inset by half the stroke so ticks stay inside the grown rect.
	var r := Rect2(rect.position + Vector2.ONE * width * 0.5, rect.size - Vector2.ONE * width)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	radius = minf(radius, minf(r.size.x, r.size.y) * 0.5)
	# Each straight edge is shared by the ticks of two corners; budget half to
	# each so neighboring corners can never overlap on small/circular controls.
	var straight_w := maxf(0.0, r.size.x - 2.0 * radius)
	var straight_h := maxf(0.0, r.size.y - 2.0 * radius)
	var tick := minf(M3Units.dp(corner_tick_dp), minf(straight_w, straight_h) * 0.5)
	# Near-circular controls have no straight edge for ticks; shrink the arc
	# sweep instead so the four corners stay visually separated.
	var sweep := PI * 0.5
	if tick < 1.0:
		sweep *= 0.7
	# Border color was already set by _redraw_ring (dimmed during CHASE idle).
	var colors := PackedColorArray([_ring_style.border_color])
	# Per corner: arc center, start angle, tick direction at start, tick dir at end.
	var corners := [
		[r.position + Vector2(radius, radius), PI, Vector2(0, 1), Vector2(1, 0)],
		[Vector2(r.end.x, r.position.y) + Vector2(-radius, radius), PI * 1.5, Vector2(-1, 0), Vector2(0, 1)],
		[r.end - Vector2(radius, radius), 0.0, Vector2(0, -1), Vector2(-1, 0)],
		[Vector2(r.position.x, r.end.y) + Vector2(radius, -radius), PI * 0.5, Vector2(1, 0), Vector2(0, -1)],
	]
	# Tessellate arcs by arc length (physical px) so large corners stay smooth
	# while small ones stay cheap.
	const SEGMENT_TARGET_PX := 4.0
	const SEGMENTS_MIN := 4
	const SEGMENTS_MAX := 48
	var segments := clampi(int(ceil(radius * sweep / SEGMENT_TARGET_PX)), SEGMENTS_MIN, SEGMENTS_MAX)
	var cap_color: Color = colors[0]
	for c in corners:
		var center: Vector2 = c[0]
		# Center the (possibly shrunk) sweep on the corner bisector.
		var a0: float = c[1] + (PI * 0.5 - sweep) * 0.5
		var a1: float = a0 + sweep
		var p0 := center + Vector2(cos(a0), sin(a0)) * radius
		var p1 := center + Vector2(cos(a1), sin(a1)) * radius
		var points := PackedVector2Array()
		points.append(p0 + c[2] * tick)
		for i in range(segments + 1):
			var a := lerpf(a0, a1, float(i) / float(segments))
			points.append(center + Vector2(cos(a), sin(a)) * radius)
		points.append(p1 + c[3] * tick)
		RenderingServer.canvas_item_add_polyline(_ring_item, points, colors, width, true)
		# Polylines have butt caps; stamp circles on the tips for pill ends.
		RenderingServer.canvas_item_add_circle(_ring_item, points[0], width * 0.5, cap_color)
		RenderingServer.canvas_item_add_circle(_ring_item, points[points.size() - 1], width * 0.5, cap_color)

# ============================================================================
# Animation
# ============================================================================

func _start_chase() -> void:
	_kill_chase_tween()
	var from_rect := _ring_rect
	var from_radius := _ring_radius
	_chase_tween = create_tween()
	_chase_tween.set_trans(M3Motion.EASE_ENTER_TRANS)
	_chase_tween.set_ease(M3Motion.EASE_ENTER)
	_chase_tween.tween_method(_apply_chase_pose.bind(from_rect, from_radius), 0.0, 1.0, chase_duration)
	_chase_tween.finished.connect(_on_chase_finished)

func _apply_chase_pose(t: float, from_rect: Rect2, from_radius: float) -> void:
	# Destination is read live: cards re-stamp their target pose mid-flight
	# (focus-pop scale, grid scroll) and the chase must track, not restart.
	_ring_rect = Rect2(from_rect.position.lerp(_dest_rect.position, t), from_rect.size.lerp(_dest_rect.size, t))
	_ring_radius = lerpf(from_radius, _dest_radius, t)
	_redraw_ring()

func _on_chase_finished() -> void:
	_ring_rect = _dest_rect
	_ring_radius = _dest_radius
	_redraw_ring()

func _kill_chase_tween() -> void:
	if _chase_tween and _chase_tween.is_valid():
		_chase_tween.kill()
	_chase_tween = null

func _start_pop() -> void:
	_kill_pop_tween()
	_pop_scale = POP_START_SCALE
	_pop_tween = create_tween()
	_pop_tween.set_trans(M3Motion.EASE_ENTER_TRANS)
	_pop_tween.set_ease(M3Motion.EASE_ENTER)
	_pop_tween.tween_method(_apply_pop_scale, POP_START_SCALE, 1.0, POP_DURATION)

func _apply_pop_scale(scale_factor: float) -> void:
	_pop_scale = scale_factor
	_redraw_ring()

func _kill_pop_tween() -> void:
	if _pop_tween and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = null

func _restart_idle() -> void:
	_stop_idle()
	if not _ring_visible:
		return
	match idle_anim:
		IdleAnim.BREATHE:
			_idle_tween = create_tween().set_loops()
			_idle_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_idle_tween.tween_method(_set_ring_alpha, 1.0, BREATHE_MIN_ALPHA, BREATHE_PERIOD * 0.5)
			_idle_tween.tween_method(_set_ring_alpha, BREATHE_MIN_ALPHA, 1.0, BREATHE_PERIOD * 0.5)
		IdleAnim.CHASE:
			_idle_tween = create_tween().set_loops()
			_idle_tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
			_idle_tween.tween_method(_set_orbit_t, 0.0, 1.0, ORBIT_PERIOD)

func _stop_idle() -> void:
	if _idle_tween and _idle_tween.is_valid():
		_idle_tween.kill()
	_idle_tween = null
	if _ring_item.is_valid():
		RenderingServer.canvas_item_set_modulate(_ring_item, Color.WHITE)
	if _ring_style:
		_apply_style()

func _set_ring_alpha(alpha: float) -> void:
	if _ring_item.is_valid():
		RenderingServer.canvas_item_set_modulate(_ring_item, Color(1.0, 1.0, 1.0, alpha))

func _set_orbit_t(t: float) -> void:
	_orbit_t = t
	_redraw_ring()

# ============================================================================
# Config
# ============================================================================

func _on_config_changed() -> void:
	config_changed.emit()
	if _ring_style == null:
		return
	_apply_style()
	var t := _get_target()
	if t and _ring_visible:
		var geo := _resolve_geometry(t)
		_dest_rect = geo.rect
		_dest_radius = geo.radius
		_dest_shape = geo.shape
		_ring_rect = _dest_rect
		_ring_radius = _dest_radius
		_ring_shape = _dest_shape
		_apply_color(geo)
		_redraw_ring()
		_restart_idle()
