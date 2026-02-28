class_name FocusIndicator
extends ColorRect

@export var border_color: Color = Color(1, 1, 1, 0.8)
@export var border_width: float = 6.0
@export var padding: float = 2.0

@export var chase_speed: float = 0.65
@export var gap_size: float = 0.04
@export var fade_length: float = 0.35

@export var tween_duration: float = 0.12
@export var tween_trans: Tween.TransitionType = Tween.TRANS_QUINT
@export var tween_ease: Tween.EaseType = Tween.EASE_OUT

var _target_control: Control
var _shader_material: ShaderMaterial
var _current_tween: Tween

# Cached shape params from the focused control
var _custom_shape_size: Vector2 = Vector2.ZERO
var _custom_corner_radius_ratio: float = 0.0
var _use_custom_shape: bool = false

# Target position and size for tweening
var _target_position: Vector2 = Vector2.ZERO
var _target_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true
	z_index = 100
	
	# ColorRect needs a base color - white, shader will override it
	color = Color.WHITE
	
	# Set up the shader material
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = preload("res://shaders/focus_indicator.gdshader")
	material = _shader_material
	
	# Initialize shader parameters
	_update_shader_params()
	
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
		_use_custom_shape = false
		return
	
	if control is LineEdit or control is TextEdit:
		visible = false
		_target_control = null
		_use_custom_shape = false
		return
	
	_target_control = control
	
	# Get shape params from the focused control
	# Check if focused control itself has the method
	if control.has_method("get_focus_shape_params"):
		var params = control.get_focus_shape_params()
		_custom_shape_size = params.get("shape_size", Vector2.ZERO)
		_custom_corner_radius_ratio = params.get("corner_radius_ratio", 0.0)
		_use_custom_shape = _custom_shape_size != Vector2.ZERO
	# Check if parent has the method (e.g., Button inside GameCard)
	elif control.get_parent() and control.get_parent().has_method("get_focus_shape_params"):
		var parent = control.get_parent()
		var params = parent.get_focus_shape_params()
		_custom_shape_size = params.get("shape_size", Vector2.ZERO)
		_custom_corner_radius_ratio = params.get("corner_radius_ratio", 0.0)
		_use_custom_shape = _custom_shape_size != Vector2.ZERO
	else:
		# Use control's size with default corner radius
		_custom_shape_size = control.size
		_custom_corner_radius_ratio = 0.0
		_use_custom_shape = false
	
	_update_shader_params()
	visible = true
	
	# Start tweening to new target
	_tween_to_target()

func _get_target_global_rect(control: Control) -> Rect2:
	var global_pos = control.global_position
	var ctrl_size = control.size
	
	# If using custom shape from parent, use parent's position and size
	if _use_custom_shape and control.get_parent() and control.get_parent().has_method("get_focus_shape_params"):
		var parent = control.get_parent()
		global_pos = parent.global_position
		ctrl_size = parent.size
	
	return Rect2(
		global_pos.x - border_width - padding,
		global_pos.y - border_width - padding,
		ctrl_size.x + (border_width + padding) * 2,
		ctrl_size.y + (border_width + padding) * 2
	)

func _tween_to_target() -> void:
	if not _target_control or not is_instance_valid(_target_control):
		return
	
	var target_rect = _get_target_global_rect(_target_control)
	_target_position = target_rect.position
	_target_size = target_rect.size
	
	# Kill any existing tween
	if _current_tween:
		_current_tween.kill()
	
	# Create new tween for position and size
	_current_tween = create_tween()
	_current_tween.set_trans(tween_trans)
	_current_tween.set_ease(tween_ease)
	
	# Tween position
	_current_tween.parallel().tween_property(self, "global_position", _target_position, tween_duration)
	
	# Tween size and update shader params during the tween
	_current_tween.parallel().tween_property(self, "size", _target_size, tween_duration)
	
	# Update shader params on each step of the tween
	_current_tween.step_finished.connect(_on_tween_step)
	_current_tween.finished.connect(_on_tween_finished)

func _on_tween_step(_idx: int) -> void:
	_update_shader_params()

func _on_tween_finished() -> void:
	if _current_tween:
		_current_tween.step_finished.disconnect(_on_tween_step)
		_current_tween.finished.disconnect(_on_tween_finished)
		_current_tween = null

func _update_shader_params() -> void:
	if not _shader_material:
		return
	
	_shader_material.set_shader_parameter("border_color", border_color)
	_shader_material.set_shader_parameter("border_width", border_width)
	_shader_material.set_shader_parameter("padding", padding)
	_shader_material.set_shader_parameter("debug_mode", false)
	_shader_material.set_shader_parameter("chase_speed", chase_speed)
	_shader_material.set_shader_parameter("gap_size", gap_size)
	_shader_material.set_shader_parameter("fade_size", gap_size)
	_shader_material.set_shader_parameter("fade_length", fade_length)
	
	if _use_custom_shape:
		_shader_material.set_shader_parameter("shape_size", size)
		_shader_material.set_shader_parameter("corner_radius_ratio", _custom_corner_radius_ratio)
	else:
		_shader_material.set_shader_parameter("shape_size", size)
		_shader_material.set_shader_parameter("corner_radius_ratio", 0.0)

func _process(_delta: float) -> void:
	# Check if target has moved and update tween target
	if _target_control and is_instance_valid(_target_control):
		var target_rect = _get_target_global_rect(_target_control)
		
		# If target moved significantly, update the tween
		if target_rect.position.distance_to(_target_position) > 1.0 or target_rect.size.distance_to(_target_size) > 1.0:
			_tween_to_target()

func set_border_color(color: Color) -> void:
	border_color = color
	_update_shader_params()

func hide_indicator() -> void:
	visible = false
	_target_control = null
	_use_custom_shape = false
	if _current_tween:
		_current_tween.kill()
		_current_tween = null
