class_name SmoothScrollContainer
extends ScrollContainer

signal scroll_value_changed(value: float)

@export var smooth_scrolling: bool = true
@export var smooth_scroll_duration: float = 2.0
@export var smooth_scroll_big_jump_threshold: float = 3500.0
@export var smooth_scroll_big_jump_multiplier: float = 3.0

var _target_scroll_y: float = 0.0
var _scroll_tween: Tween
var _is_smooth_scrolling: bool = false
var _is_dragging_scrollbar: bool = false
var _scrollbar_drag_start_mouse_y: float = 0.0
var _scrollbar_drag_start_value: float = 0.0

var _pre_focus_scroll: float = -1.0
var _focus_key_pressed: bool = false

func _ready():
	follow_focus = true
	
	await get_tree().process_frame
	
	var v_scrollbar = get_v_scroll_bar()
	if v_scrollbar:
		v_scrollbar.value_changed.connect(_on_internal_scroll_changed)
	
	if smooth_scrolling:
		gui_input.connect(_on_gui_input)
		if v_scrollbar:
			v_scrollbar.gui_input.connect(_on_scrollbar_input)

func _input(event: InputEvent):
	if not smooth_scrolling:
		return
	
	if not event.is_pressed():
		return
	
	if event.is_action("ui_up") or event.is_action("ui_down") or \
	   event.is_action("ui_left") or event.is_action("ui_right") or \
	   event.is_action("ui_focus_next") or event.is_action("ui_focus_prev"):
		var focused = get_viewport().gui_get_focus_owner()
		if focused and is_ancestor_of(focused):
			_pre_focus_scroll = scroll_vertical
			_focus_key_pressed = true

func _on_internal_scroll_changed(value: float):
	if _focus_key_pressed and _pre_focus_scroll >= 0:
		var pre_scroll = _pre_focus_scroll
		_focus_key_pressed = false
		_pre_focus_scroll = -1.0
		
		if abs(value - pre_scroll) > 10.0:
			if _scroll_tween and _scroll_tween.is_valid():
				_scroll_tween.kill()
			_is_smooth_scrolling = false
			
			scroll_vertical = int(pre_scroll)
			
			var focused = get_viewport().gui_get_focus_owner()
			if focused and is_ancestor_of(focused):
				_target_scroll_y = _get_centered_scroll_for_control(focused)
			else:
				_target_scroll_y = value
			
			call_deferred("_start_smooth_scroll")
			return
	
	scroll_value_changed.emit(value)

func _get_centered_scroll_for_control(p_control: Control) -> float:
	var control_rect = p_control.get_global_rect()
	var scroll_rect = get_global_rect()
	
	var control_center_y = control_rect.position.y + control_rect.size.y / 2.0
	var viewport_center_y = scroll_rect.position.y + scroll_rect.size.y / 2.0
	
	var diff = control_center_y - viewport_center_y
	var target_scroll = scroll_vertical + diff
	
	var scrollbar = get_v_scroll_bar()
	if scrollbar:
		target_scroll = clampf(target_scroll, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
	
	return target_scroll

func _on_gui_input(event: InputEvent):
	if not smooth_scrolling:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var scrollbar = get_v_scroll_bar()
			if not scrollbar:
				return
			
			var step = scrollbar.custom_step
			if step <= 0:
				step = scrollbar.page / 10.0
			
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_target_scroll_y -= step
			else:
				_target_scroll_y += step
			
			_target_scroll_y = clampf(_target_scroll_y, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			_start_smooth_scroll()
			accept_event()

func _on_scrollbar_input(event: InputEvent):
	if not smooth_scrolling:
		return
	
	var scrollbar = get_v_scroll_bar()
	if not scrollbar:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_is_dragging_scrollbar = true
				_scrollbar_drag_start_mouse_y = event.global_position.y
				_scrollbar_drag_start_value = _target_scroll_y
				
				if _scroll_tween and _scroll_tween.is_valid():
					_scroll_tween.kill()
				_is_smooth_scrolling = false
			else:
				_is_dragging_scrollbar = false
	
	elif event is InputEventMouseMotion and _is_dragging_scrollbar:
		var mouse_delta = event.global_position.y - _scrollbar_drag_start_mouse_y
		
		var scrollable_range = scrollbar.max_value - scrollbar.min_value - scrollbar.page
		var scrollbar_track_height = scrollbar.size.y - scrollbar.get_combined_minimum_size().y
		
		if scrollbar_track_height > 0 and scrollable_range > 0:
			var scroll_delta = (mouse_delta / scrollbar_track_height) * scrollable_range
			_target_scroll_y = _scrollbar_drag_start_value + scroll_delta
			
			_target_scroll_y = clampf(_target_scroll_y, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			_start_smooth_scroll()
			scrollbar.accept_event()

func _start_smooth_scroll():
	var scrollbar = get_v_scroll_bar()
	if not scrollbar:
		return
	
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	
	var start_value = float(scroll_vertical)
	var target_value = _target_scroll_y
	
	var distance = abs(target_value - start_value)
	var duration = smooth_scroll_duration
	
	if distance > smooth_scroll_big_jump_threshold:
		var extra_distance = distance - smooth_scroll_big_jump_threshold
		var extra_duration = (extra_distance / smooth_scroll_big_jump_threshold) * (smooth_scroll_duration * (smooth_scroll_big_jump_multiplier - 1.0))
		duration = smooth_scroll_duration + extra_duration
	
	_is_smooth_scrolling = true
	
	_scroll_tween = create_tween()
	_scroll_tween.set_trans(Tween.TRANS_EXPO)
	_scroll_tween.set_ease(Tween.EASE_OUT)
	
	_scroll_tween.tween_method(
		func(val: float): 
			scroll_vertical = int(val),
		start_value,
		target_value,
		duration
	)
	
	_scroll_tween.finished.connect(func(): 
		_is_smooth_scrolling = false
	)

func get_target_scroll() -> float:
	if smooth_scrolling:
		return _target_scroll_y
	return float(scroll_vertical)

func scroll_to(target_y: float, animate: bool = true):
	if animate and smooth_scrolling:
		_target_scroll_y = target_y
		_start_smooth_scroll()
	else:
		scroll_vertical = target_y
