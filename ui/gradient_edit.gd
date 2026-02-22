class_name GradientEdit
extends Control

signal gradient_changed(gradient: Gradient)

var popup: PopupPanel
var picker: ColorPicker
var checker: ImageTexture

var grabbing: bool = false
var grabbed: int = -1
var points: Array = []

const SPACING: int = 3
const POINT_WIDTH: int = 8

func _ready():
	set_focus_mode(FOCUS_ALL)
	
	popup = PopupPanel.new()
	picker = ColorPicker.new()
	popup.add_child(picker)
	add_child(popup)
	
	picker.color_changed.connect(_on_color_changed)
	
	_generate_checker_texture()
	
	if points.is_empty():
		var gradient = Gradient.new()
		gradient.add_point(0.0, Color.WHITE)
		gradient.add_point(1.0, Color.BLACK)
		set_gradient(gradient)

func _generate_checker_texture():
	var size = 8
	var image = Image.create(size * 2, size * 2, false, Image.FORMAT_RGBA8)
	
	for y in range(size * 2):
		for x in range(size * 2):
			var is_light = ((x / size) + (y / size)) % 2 == 0
			var color = Color(0.5, 0.5, 0.5, 1.0) if is_light else Color(0.35, 0.35, 0.35, 1.0)
			image.set_pixel(x, y, color)
	
	checker = ImageTexture.create_from_image(image)

func _gui_input(event: InputEvent):
	if event is InputEventKey and event.pressed and event.keycode == KEY_DELETE and grabbed != -1:
		if points.size() > 1:
			points.remove_at(grabbed)
			grabbed = -1
			grabbing = false
			queue_redraw()
			_emit_gradient_changed()
		accept_event()
	
	if event is InputEventMouseButton:
		var mb = event
		
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click and mb.pressed:
			grabbed = _get_point_from_pos(mb.position.x)
			if grabbed != -1:
				_show_color_picker()
			accept_event()
		
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var clicked_point = _get_point_from_pos(mb.position.x)
			if clicked_point != -1 and points.size() > 1:
				points.remove_at(clicked_point)
				grabbed = -1
				grabbing = false
				queue_redraw()
				_emit_gradient_changed()
			accept_event()
		
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.alt_pressed:
			var x = mb.position.x
			grabbed = _get_point_from_pos(x)
			
			if grabbed != -1:
				var total_w = size.x - size.y - SPACING
				var new_offset = clamp(x / float(total_w), 0.0, 1.0)
				var new_point = {
					"offset": new_offset,
					"color": points[grabbed].color
				}
				points.append(new_point)
				_sort_points()
				for i in range(points.size()):
					if abs(points[i].offset - new_offset) < 0.0001:
						grabbed = i
						break
				_emit_gradient_changed()
				queue_redraw()
			accept_event()
		
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			queue_redraw()
			var x = mb.position.x
			var total_w = size.x - size.y - SPACING
			
			if x > total_w + SPACING:
				_show_color_picker()
				accept_event()
				return
			
			grabbing = true
			grabbed = _get_point_from_pos(x)
			
			if grabbed != -1:
				accept_event()
				return
			
			var new_offset = clamp(x / float(total_w), 0.0, 1.0)
			var new_color = _interpolate_color_at_offset(new_offset)
			
			var new_point = {
				"offset": new_offset,
				"color": new_color
			}
			points.append(new_point)
			_sort_points()
			for i in range(points.size()):
				if abs(points[i].offset - new_offset) < 0.0001:
					grabbed = i
					break
			
			_emit_gradient_changed()
			accept_event()
		
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			if grabbing:
				grabbing = false
				_emit_gradient_changed()
			queue_redraw()
	
	if event is InputEventMouseMotion and grabbing:
		var mm = event
		var total_w = size.x - size.y - SPACING
		var x = mm.position.x
		
		var new_offset = clamp(x / float(total_w), 0.0, 1.0)
		
		if mm.ctrl_pressed:
			new_offset = snapped(new_offset, 0.025 if mm.shift_pressed else 0.1)
		elif mm.shift_pressed:
			var snap_threshold = 0.03
			for i in range(points.size()):
				if i != grabbed:
					var temp_offset = abs(points[i].offset - new_offset)
					if temp_offset < snap_threshold:
						new_offset = points[i].offset + (0.00001 if points[i].offset < new_offset else -0.00001)
						new_offset = clamp(new_offset, 0.0, 1.0)
						break
		
		var valid = true
		for i in range(points.size()):
			if abs(points[i].offset - new_offset) < 0.0001 and i != grabbed:
				valid = false
				break
		
		if valid and grabbed != -1:
			points[grabbed].offset = new_offset
			_sort_points()
			for i in range(points.size()):
				if abs(points[i].offset - new_offset) < 0.0001:
					grabbed = i
					break
			_emit_gradient_changed()
			queue_redraw()

func _get_point_from_pos(x: int) -> int:
	var result = -1
	var total_w = size.x - size.y - SPACING
	var min_distance = 1e20
	
	for i in range(points.size()):
		var distance = abs(x - points[i].offset * total_w)
		var threshold = POINT_WIDTH / 2.0 * 1.7
		if distance <= threshold and distance < min_distance:
			result = i
			min_distance = distance
	
	return result

func _interpolate_color_at_offset(offset: float) -> Color:
	if points.is_empty():
		return Color.WHITE
	if points.size() == 1:
		return points[0].color
	
	_sort_points()
	
	if offset <= points[0].offset:
		return points[0].color
	if offset >= points[points.size() - 1].offset:
		return points[points.size() - 1].color
	
	for i in range(points.size() - 1):
		if offset >= points[i].offset and offset <= points[i + 1].offset:
			var t = (offset - points[i].offset) / (points[i + 1].offset - points[i].offset)
			return points[i].color.lerp(points[i + 1].color, t)
	
	return Color.WHITE

func _sort_points():
	points.sort_custom(func(a, b): return a.offset < b.offset)

func _show_color_picker():
	if grabbed == -1:
		return
	picker.color = points[grabbed].color
	var minsize = popup.get_contents_minimum_size()
	var show_above = false
	if global_position.y + size.y + minsize.y > get_viewport_rect().size.y:
		show_above = true
	if show_above:
		popup.position = global_position - Vector2(0, minsize.y)
	else:
		popup.position = global_position + Vector2(0, size.y)
	popup.popup()

func _on_color_changed(color: Color):
	if grabbed == -1:
		return
	points[grabbed].color = color
	queue_redraw()
	_emit_gradient_changed()

func _draw():
	var w = size.x
	var h = size.y
	
	if w == 0 or h == 0:
		return
	
	var total_w = size.x - size.y - SPACING
	
	_draw_checker(0, 0, total_w, h)
	
	if points.is_empty():
		draw_rect(Rect2(0, 0, total_w, h), Color.BLACK)
	else:
		_sort_points()
		var prev = {"offset": 0.0, "color": points[0].color if points.size() > 0 else Color.BLACK}
		
		for i in range(-1, points.size()):
			var next
			if i + 1 >= points.size():
				next = {"offset": 1.0, "color": points[points.size() - 1].color if points.size() > 0 else Color.BLACK}
			else:
				next = points[i + 1]
			
			if abs(prev.offset - next.offset) < 0.0001:
				prev = next
				continue
			
			var polygon_points = PackedVector2Array([
				Vector2(prev.offset * total_w, h),
				Vector2(prev.offset * total_w, 0),
				Vector2(next.offset * total_w, 0),
				Vector2(next.offset * total_w, h)
			])
			var colors = PackedColorArray([
				prev.color,
				prev.color,
				next.color,
				next.color
			])
			draw_polygon(polygon_points, colors)
			prev = next
	
	for i in range(points.size()):
		var col = points[i].color.lerp(points[i].color.inverted(), 0.5)
		col.a = 0.9
		
		draw_line(Vector2(points[i].offset * total_w, 0), Vector2(points[i].offset * total_w, h / 2.0), col)
		var rect = Rect2(points[i].offset * total_w - POINT_WIDTH / 2.0, h / 2.0, POINT_WIDTH, h / 2.0)
		draw_rect(rect, points[i].color, true)
		draw_rect(rect, col, false)
		
		if grabbed == i:
			rect = rect.grow(-1)
			if has_focus():
				draw_rect(rect, Color(1, 0, 0, 0.9), false)
			else:
				draw_rect(rect, Color(0.6, 0, 0, 0.9), false)
			rect = rect.grow(-1)
			draw_rect(rect, col, false)
	
	_draw_checker(total_w + SPACING, 0, h, h)
	if grabbed != -1:
		draw_rect(Rect2(total_w + SPACING, 0, h, h), points[grabbed].color)
	else:
		draw_rect(Rect2(total_w + SPACING, 0, h, h), Color(0.5, 0.5, 0.5, 1.0))
		draw_line(Vector2(total_w + SPACING, 0), Vector2(total_w + SPACING + h, h), Color(1, 1, 1, 0.6))
		draw_line(Vector2(total_w + SPACING, h), Vector2(total_w + SPACING + h, 0), Color(1, 1, 1, 0.6))
	
	if has_focus():
		draw_rect(Rect2(-1, -1, total_w + 2, h + 2), Color(1, 1, 1, 0.6), false)

func _draw_checker(x: int, y: int, w: int, h: int):
	if not checker:
		return
	
	var polygon_points = PackedVector2Array([
		Vector2(x, y),
		Vector2(x, y + h),
		Vector2(x + w, y + h),
		Vector2(x + w, y)
	])
	var colors = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	var uv_points = PackedVector2Array([
		Vector2(0, 0),
		Vector2(0, h / 4.0),
		Vector2(w / 4.0, h / 4.0),
		Vector2(w / 4.0, 0)
	])
	draw_polygon(polygon_points, colors, uv_points, checker)

func _notification(what: int):
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not is_visible():
			grabbing = false

func _get_minimum_size() -> Vector2:
	return Vector2(0, 16)

func set_gradient(gradient: Gradient):
	points.clear()
	for i in range(gradient.get_point_count()):
		points.append({
			"offset": gradient.get_offset(i),
			"color": gradient.get_color(i)
		})
	queue_redraw()

func get_gradient() -> Gradient:
	var gradient = Gradient.new()
	_sort_points()
	for i in range(points.size()):
		gradient.add_point(points[i].offset, points[i].color)
	return gradient

func _emit_gradient_changed():
	gradient_changed.emit(get_gradient())
