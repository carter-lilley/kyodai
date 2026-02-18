class_name FocusIndicator
extends Control

@export var border_color: Color = Color(1, 1, 1, 0.8)
@export var border_width: float = 3.0
@export var corner_radius: float = 6.0
@export var padding: float = 2.0

var _style_box: StyleBoxFlat
var _target_control: Control

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true
	z_index = 50
	
	_style_box = StyleBoxFlat.new()
	_style_box.bg_color = Color(0, 0, 0, 0)
	_style_box.border_color = border_color
	_style_box.set_border_width_all(int(border_width))
	_style_box.set_corner_radius_all(int(corner_radius))
	_style_box.set_content_margin_all(padding)
	
	visible = false
	
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	await get_tree().process_frame
	var focused = get_viewport().gui_get_focus_owner()
	if focused:
		_on_focus_changed(focused)

func _exit_tree() -> void:
	if is_instance_valid(get_viewport()):
		if get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
			get_viewport().gui_focus_changed.disconnect(_on_focus_changed)

func _on_focus_changed(control: Control) -> void:
	if not is_instance_valid(control):
		visible = false
		_target_control = null
		return
	
	if control is LineEdit or control is TextEdit:
		visible = false
		_target_control = null
		return
	
	_target_control = control
	visible = true

func _get_target_global_rect(control: Control) -> Rect2:
	var global_pos = control.global_position
	var ctrl_size = control.size
	
	return Rect2(
		global_pos.x - border_width - padding,
		global_pos.y - border_width - padding,
		ctrl_size.x + (border_width + padding) * 2,
		ctrl_size.y + (border_width + padding) * 2
	)

func _draw() -> void:
	draw_style_box(_style_box, Rect2(Vector2.ZERO, size))

func _process(_delta: float) -> void:
	if _target_control and is_instance_valid(_target_control):
		var target_rect = _get_target_global_rect(_target_control)
		global_position = target_rect.position
		size = target_rect.size

func set_border_color(color: Color) -> void:
	border_color = color
	if _style_box:
		_style_box.border_color = color

func hide_indicator() -> void:
	visible = false
	_target_control = null
