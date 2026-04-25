class_name FocusIndicator
extends ColorRect

@export var border_color: Color = Color(0.0, 0.757, 0.757, 0.8)
@export var border_width: float = 6.0
@export var padding: float = 0.0

@export var chase_speed: float = 0.375
@export var gap_size: float = 0.03
@export var fade_length: float = 0.65

@export var tween_duration: float = 0.15
@export var tween_trans: Tween.TransitionType = Tween.TRANS_QUART
@export var tween_ease: Tween.EaseType = Tween.EASE_OUT

var _target_control: Control
var _shader_material: ShaderMaterial
var _current_tween: Tween

# Cached shape params from the focused control
var _custom_shape_size: Vector2 = Vector2.ZERO
var _custom_corner_radius_ratio: float = 0.0
var _custom_corner_radius_pixels: float = 0.0
var _use_custom_shape: bool = false
var _was_using_custom_shape: bool = false

# Track if this is the first focus change (to skip sound on app start)
var _is_first_focus: bool = true

# Target position and size for tweening
var _target_position: Vector2 = Vector2.ZERO
var _target_size: Vector2 = Vector2.ZERO

# Keyboard override - when virtual keyboard is open, lock indicator on the LineEdit
var _keyboard_override: bool = false
var _keyboard_target: Control = null
var _keyboard_node: Node = null

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
	
	# Find and connect to the on-screen keyboard for override behavior
	_connect_to_keyboard()

func _connect_to_keyboard() -> void:
	"""Find the OnscreenKeyboard node and connect to its signals."""
	# Try to find the keyboard in the scene tree
	var keyboard = get_tree().root.find_child("OnscreenKeyboard", true, false)
	if keyboard == null:
		# Try alternative names/paths
		keyboard = get_node_or_null("/root/Main/UILayer/OnscreenKeyboard")
	
	if keyboard != null and keyboard.has_signal("keyboard_opened") and keyboard.has_signal("keyboard_closed"):
		_keyboard_node = keyboard
		if not keyboard.keyboard_opened.is_connected(_on_keyboard_opened):
			keyboard.keyboard_opened.connect(_on_keyboard_opened)
		if not keyboard.keyboard_closed.is_connected(_on_keyboard_closed):
			keyboard.keyboard_closed.connect(_on_keyboard_closed)
		
		# If keyboard is already open, apply override immediately
		if keyboard.visible and keyboard.has_method("is_keyboard_focus_object"):
			var active_edit = keyboard.get("_active_line_edit")
			if active_edit != null:
				_on_keyboard_opened(active_edit)

func _on_keyboard_opened(active_line_edit: LineEdit) -> void:
	"""Lock the focus indicator on the active LineEdit while keyboard is open."""
	_keyboard_override = true
	_keyboard_target = active_line_edit
	_target_control = active_line_edit
	
	# Show indicator on the LineEdit (normally it hides for LineEdit)
	_update_shader_params()
	visible = true
	_snap_to_target()

func _on_keyboard_closed() -> void:
	"""Release keyboard override and return to normal focus behavior."""
	_keyboard_override = false
	_keyboard_target = null
	visible = false
	
	# Let the next focus change restore normal behavior
	var focused = get_viewport().gui_get_focus_owner()
	if focused:
		_on_focus_changed(focused)

func _exit_tree() -> void:
	if is_instance_valid(get_viewport()):
		if get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
			get_viewport().gui_focus_changed.disconnect(_on_focus_changed)

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting to ensure focus events are received."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	# Try to disconnect from any viewport (might fail if not connected, that's ok)
	# We need to try the old viewport first, but we don't have a reference to it
	# So we'll just try to disconnect from current viewport in case we're reconnecting multiple times
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	# Connect to new viewport
	viewport.gui_focus_changed.connect(_on_focus_changed)
	
	# Check if there's already a focused control
	var focused = viewport.gui_get_focus_owner()
	if focused:
		_on_focus_changed(focused)

func _on_focus_changed(control: Control) -> void:
	# If keyboard override is active, ignore all focus changes and stay on the LineEdit
	if _keyboard_override and _keyboard_target != null and is_instance_valid(_keyboard_target):
		return
	
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
		_custom_corner_radius_pixels = params.get("corner_radius_pixels", 0.0)
		_use_custom_shape = _custom_shape_size != Vector2.ZERO
	else:
		# Traverse up the tree to find a node with get_focus_shape_params
		# This handles nested structures like CardInput -> VisualContainer -> GameCard
		var found_shape = false
		var ancestor = control.get_parent()
		while ancestor:
			if ancestor.has_method("get_focus_shape_params"):
				var params = ancestor.get_focus_shape_params()
				_custom_shape_size = params.get("shape_size", Vector2.ZERO)
				_custom_corner_radius_ratio = params.get("corner_radius_ratio", 0.0)
				_custom_corner_radius_pixels = params.get("corner_radius_pixels", 0.0)
				_use_custom_shape = _custom_shape_size != Vector2.ZERO
				found_shape = true
				break
			ancestor = ancestor.get_parent()
		
		# Use control's size with default corner radius if no shape found
		if not found_shape:
			_custom_shape_size = control.size
			_custom_corner_radius_ratio = 0.0
			_custom_corner_radius_pixels = 0.0
			_use_custom_shape = false
	
	_update_shader_params()
	visible = true
	
	# Check if we're transitioning between card and non-card
	var transitioning_to_card = _use_custom_shape and not _was_using_custom_shape
	_was_using_custom_shape = _use_custom_shape
	
	# Play appropriate sound for focus change (skip on initial app start)
	if not _use_custom_shape and not _is_first_focus:
		# Non-game card focus - play generic click sound
		if AudioManager:
			AudioManager.play_sfx("click_00")
	# Note: Game cards (_use_custom_shape) handle their own sound in game_card.gd
	
	# Mark that we've had our first focus
	_is_first_focus = false
	
	if transitioning_to_card:
		# Skip tween - snap immediately to correct position/size
		_snap_to_target()
	else:
		# Normal tween for card→card or non-card→non-card
		_tween_to_target()

func _get_target_global_rect(control: Control) -> Rect2:
	var global_pos = control.global_position
	var ctrl_size = control.size
	
	# If using custom shape, traverse up to find the node with get_focus_shape_params
	# This handles nested structures like CardInput -> VisualContainer -> GameCard
	if _use_custom_shape:
		var ancestor = control.get_parent()
		while ancestor:
			if ancestor.has_method("get_focus_shape_params"):
				# For GameCards, check if there's a VisualContainer child that handles scaling
				var visual_container = ancestor.get_node_or_null("VisualContainer")
				if visual_container:
					# Use VisualContainer's position and scaled size
					global_pos = visual_container.global_position
					ctrl_size = visual_container.size * visual_container.scale
				else:
					global_pos = ancestor.global_position
					ctrl_size = ancestor.size * ancestor.scale
				break
			ancestor = ancestor.get_parent()
	
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

func _snap_to_target() -> void:
	if not _target_control or not is_instance_valid(_target_control):
		return
	
	var target_rect = _get_target_global_rect(_target_control)
	
	# Kill any existing tween
	if _current_tween:
		_current_tween.kill()
		_current_tween = null
	
	# Snap immediately to target position and size
	global_position = target_rect.position
	size = target_rect.size
	
	# Update target values so _process doesn't re-tween
	_target_position = target_rect.position
	_target_size = target_rect.size
	
	# Update shader params
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
		# Use ratio for consistent roundness - shader will calculate appropriate pixel radius
		# based on the focus indicator's actual size
		_shader_material.set_shader_parameter("corner_radius_ratio", _custom_corner_radius_ratio)
		# Don't pass pixels - let shader calculate from ratio to match proportions
		_shader_material.set_shader_parameter("corner_radius_pixels", 0.0)
	else:
		_shader_material.set_shader_parameter("shape_size", size)
		_shader_material.set_shader_parameter("corner_radius_ratio", 0.0)
		_shader_material.set_shader_parameter("corner_radius_pixels", 0.0)

func _process(_delta: float) -> void:
	# Check if target has moved and update tween target
	if _target_control and is_instance_valid(_target_control):
		var target_rect = _get_target_global_rect(_target_control)
		
		# If target moved significantly, update the tween
		if target_rect.position.distance_to(_target_position) > 1.0 or target_rect.size.distance_to(_target_size) > 1.0:
			_tween_to_target()

func _unhandled_input(event: InputEvent) -> void:
	# Play click_03 when ui_accept is pressed on non-game card elements
	if event.is_action_pressed("ui_accept"):
		if _target_control and is_instance_valid(_target_control) and not _use_custom_shape:
			# Non-game card element activated - play activation sound
			if AudioManager:
				AudioManager.play_sfx("click_03")

func set_border_color(color: Color) -> void:
	border_color = color
	_update_shader_params()

func hide_indicator() -> void:
	visible = false
	_target_control = null
	_use_custom_shape = false
	_was_using_custom_shape = false
	if _current_tween:
		_current_tween.kill()
		_current_tween = null
