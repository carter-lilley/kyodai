class_name AngleDial
extends Control

signal angle_changed(angle: float)

var angle: float = 180.0
var default_angle: float = 180.0
var dragging: bool = false
var editable: bool = true:
	set(value):
		editable = value
		queue_redraw()

const SNAP_STEP: float = 15.0

func _ready():
	set_focus_mode(FOCUS_ALL)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func _gui_input(event: InputEvent):
	if not editable:
		return

	if event is InputEventMouseButton:
		var mb = event

		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if mb.double_click:
				_set_angle(default_angle)
				angle_changed.emit(angle)
			else:
				dragging = true
				_set_angle_from_pos(mb.position, mb.ctrl_pressed)
			accept_event()

		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			if dragging:
				dragging = false
				angle_changed.emit(angle)
			accept_event()

		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_nudge(1.0 if mb.ctrl_pressed else SNAP_STEP)
			accept_event()

		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_nudge(-(1.0 if mb.ctrl_pressed else SNAP_STEP))
			accept_event()

	if event is InputEventMouseMotion and dragging:
		_set_angle_from_pos(event.position, event.ctrl_pressed)
		accept_event()

func _nudge(delta: float):
	_set_angle(fposmod(angle + delta, 360.0))
	angle_changed.emit(angle)

func _set_angle_from_pos(pos: Vector2, free_snap: bool):
	var center = size / 2.0
	var rad = atan2(pos.x - center.x, -(pos.y - center.y))
	_set_angle(fposmod(rad_to_deg(rad), 360.0), free_snap)

func _set_angle(new_angle: float, free_snap: bool = false):
	if not free_snap:
		new_angle = snapped(new_angle, SNAP_STEP)
	angle = fposmod(new_angle, 360.0)
	queue_redraw()
	if dragging:
		angle_changed.emit(angle)

func _draw():
	var w = size.x
	var h = size.y
	if w == 0 or h == 0:
		return

	var center = Vector2(w, h) / 2.0
	var radius = min(w, h) / 2.0 - 2.0

	var ring_color = Color(1, 1, 1, 0.4) if editable else Color(1, 1, 1, 0.15)
	var tick_color = Color(1, 1, 1, 0.6) if editable else Color(1, 1, 1, 0.2)
	var needle_color = Color(1, 1, 1, 0.95) if editable else Color(1, 1, 1, 0.3)

	draw_arc(center, radius, 0.0, TAU, 48, ring_color, 1.5, true)

	for i in range(8):
		var tick_rad = deg_to_rad(i * 45.0)
		var dir = Vector2(sin(tick_rad), -cos(tick_rad))
		var tick_len = 4.0 if i % 2 == 0 else 2.5
		draw_line(center + dir * (radius - tick_len), center + dir * radius, tick_color, 1.0, true)

	var rad = deg_to_rad(angle)
	var needle_dir = Vector2(sin(rad), -cos(rad))
	draw_line(center, center + needle_dir * (radius - 2.0), needle_color, 2.0, true)
	draw_circle(center + needle_dir * (radius - 2.0), 3.0, needle_color)
	draw_circle(center, 2.0, ring_color)

	if has_focus():
		draw_arc(center, radius + 1.5, 0.0, TAU, 48, Color(1, 1, 1, 0.6), 1.0, true)

func _notification(what: int):
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not is_visible():
			dragging = false

func _get_minimum_size() -> Vector2:
	return Vector2(48, 48)

func set_angle(new_angle: float):
	angle = fposmod(new_angle, 360.0)
	queue_redraw()

func get_angle() -> float:
	return angle
