class_name SmoothScrollContainer
extends ScrollContainer

signal scroll_value_changed(value: float)
signal scroll_completed()

@export var smooth_scrolling: bool = true
## Duration (seconds) of a scroll covering `smooth_scroll_reference_distance` pixels.
## Actual duration scales proportionally with distance, clamped to [min, max].
## Used for focus/programmatic scrolls; wheel scrolling uses wheel_scroll_duration.
@export var smooth_scroll_duration: float = 0.5
@export var smooth_scroll_reference_distance: float = 1000.0
@export var smooth_scroll_min_duration: float = 0.15
@export var smooth_scroll_max_duration: float = 2.5
## Duration multiplier for follow-focus scrolls only (ui/kb focus tracking).
## > 1 stretches the distance-scaled duration so focus hops glide instead of snap.
@export var focus_scroll_duration_multiplier: float = 1.6
## Fixed tween duration for mouse-wheel scrolling. Wheel ticks accumulate into
## the target and restart the tween, so a longer fixed duration keeps repeated
## ticks chasing the target smoothly instead of stuttering.
@export var wheel_scroll_duration: float = 1.0
## Time constant (seconds) for the wheel chase: the scroll position glides
## toward the accumulated target exponentially (velocity proportional to the
## remaining distance), so any tick cadence stays smooth — no tween restarts.
@export var wheel_chase_tau: float = 0.2
var _wheel_chase_active: bool = false
var _chase_pos: float = 0.0
var _last_wheel_tick_msec: int = -10000
@export var vertical: bool = true:
	set(value):
		if vertical != value:
			vertical = value
			_target_scroll = 0.0
			if is_inside_tree():
				_reconnect_scrollbars()

var _target_scroll: float = 0.0
var _scroll_tween: Tween
var _is_smooth_scrolling: bool = false
var _is_dragging_scrollbar: bool = false
var _scrollbar_drag_start_mouse_pos: float = 0.0
var _scrollbar_drag_start_value: float = 0.0
var _focus_timer: Timer = null

## Optional delegate for follow-focus scroll targets. Signature: (Control) -> float.
## When set, the provider decides where to scroll when a control inside this
## container gains focus (returning the current scroll value means "no scroll").
## This lets the owning grid use layout math instead of measuring global rects.
var scroll_target_provider: Callable = Callable()

## When true, follow-focus scrolling is ignored (used while the owning grid
## runs a programmatic scroll-and-focus sequence).
var follow_focus_suppressed: bool = false

## True while a wheel-initiated page turn is animating. Suppresses follow-focus
## for the duration so auto-reassigned focus (e.g. after the focused card is
## recycled mid-turn) cannot retarget the tween to a different page.
var _page_scroll_in_flight: bool = false

## When > 0, scrolling snaps to positions k * page_snap_period + page_snap_offset.
## Wheel ticks jump one whole page; drag/touch free-scrolls then snaps on release.
var page_snap_period: float = 0.0
var page_snap_offset: float = 0.0
## When >= 0, page snap/wheel targets never exceed this value (the last page's
## target), even if the scrollbar range extends slightly past it.
var page_snap_max_target: float = -1.0

## Optional delegate for paged wheel scrolling. Signature: (direction: int) -> float.
## Returns the absolute scroll target for one page forward (+1) or back (-1),
## letting the owning grid define page targets with the same math used for
## keyboard/controller navigation (single source of truth).
var page_step_provider: Callable = Callable()

## When true, all scroll input (wheel, scrollbar drag, focus-driven) is blocked.
var scroll_paused: bool = false:
	set(value):
		scroll_paused = value
		if scroll_paused:
			_wheel_chase_active = false
			if _scroll_tween and _scroll_tween.is_valid():
				_scroll_tween.kill()
			_is_smooth_scrolling = false
			_page_scroll_in_flight = false

func _process(delta: float) -> void:
	if not _wheel_chase_active:
		return
	# _chase_pos carries the sub-pixel position the int scrollbar can't hold, so
	# the exponential tail glides to rest instead of stalling in 1px steps.
	var diff := _target_scroll - _chase_pos
	if absf(diff) < 0.05:
		_set_current_scroll(_target_scroll)
		_wheel_chase_active = false
		_is_smooth_scrolling = false
		_page_scroll_in_flight = false
		scroll_completed.emit()
		return
	_chase_pos += diff * (1.0 - exp(-delta / wheel_chase_tau))
	_set_current_scroll(_chase_pos)

func _ready():
	# Disable built-in follow_focus - we'll handle it manually via gui_focus_changed
	follow_focus = false
	await get_tree().process_frame

	_connect_scrollbar()

	if smooth_scrolling:
		gui_input.connect(_on_gui_input)
		_connect_scrollbar_input()

	# Snap to a page target after native touch-drag scrolling settles.
	if not scroll_ended.is_connected(_on_native_scroll_ended):
		scroll_ended.connect(_on_native_scroll_ended)

	# Connect to viewport's focus changed signal
	_connect_focus_signal()

func _exit_tree():
	# Disconnect from viewport to prevent dangling signal connections
	var viewport = get_viewport()
	if is_instance_valid(viewport) and viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)

func _connect_focus_signal() -> void:
	"""Connect to the current viewport's gui_focus_changed signal."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	# Try to disconnect first (in case already connected)
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	# Connect to handle focus changes for smooth scrolling
	viewport.gui_focus_changed.connect(_on_focus_changed)

func _on_focus_changed(control: Control) -> void:
	"""Handle focus changes to smoothly scroll focused items into view."""
	if scroll_paused:
		return
	if not control:
		return

	# Only scroll if the focused control is inside this container
	if not is_ancestor_of(control):
		return

	# Consume one-shot metas even while suppressed so a stale meta can't leak
	# into a later, legitimate focus change.
	if control.has_meta("mouse_hover_focus"):
		control.remove_meta("mouse_hover_focus")
		return
	if control.has_meta("_suppress_smooth_scroll"):
		control.remove_meta("_suppress_smooth_scroll")
		return

	if follow_focus_suppressed or _page_scroll_in_flight:
		return

	# When a target provider is set, the owning grid decides the scroll target
	# from its layout math (including deadzone / centering policy). Returning
	# the current scroll means no scroll is needed.
	if scroll_target_provider.is_valid():
		var provided_target: float = scroll_target_provider.call(control)
		if is_equal_approx(provided_target, _get_current_scroll()):
			return
		_target_scroll = provided_target
		_start_smooth_scroll(focus_scroll_duration_multiplier, -1.0, Callable(), Tween.TRANS_CUBIC, Tween.EASE_OUT)
		return

	# If the control is already fully visible, don't re-center it. This prevents
	# subtle vertical/horizontal drift when moving across a row/column that is
	# already inside the viewport.
	if _is_control_fully_visible(control):
		return

	# Calculate and smoothly scroll to centered position
	_target_scroll = _get_centered_scroll_for_control(control)
	_start_smooth_scroll(focus_scroll_duration_multiplier, -1.0, Callable(), Tween.TRANS_CUBIC, Tween.EASE_OUT)

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	# Disconnect from old viewport first
	var old_viewport = get_viewport()
	if is_instance_valid(old_viewport) and old_viewport.gui_focus_changed.is_connected(_on_focus_changed):
		old_viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	# Connect to new viewport (may be same, but ensures we're connected to current)
	_connect_focus_signal()

func _connect_scrollbar():
	if vertical:
		var v_scrollbar = get_v_scroll_bar()
		if v_scrollbar and not v_scrollbar.value_changed.is_connected(_on_internal_scroll_changed):
			v_scrollbar.value_changed.connect(_on_internal_scroll_changed)
	else:
		var h_scrollbar = get_h_scroll_bar()
		if h_scrollbar and not h_scrollbar.value_changed.is_connected(_on_internal_scroll_changed):
			h_scrollbar.value_changed.connect(_on_internal_scroll_changed)

func _connect_scrollbar_input():
	if vertical:
		var v_scrollbar = get_v_scroll_bar()
		if v_scrollbar and not v_scrollbar.gui_input.is_connected(_on_scrollbar_input):
			v_scrollbar.gui_input.connect(_on_scrollbar_input)
	else:
		var h_scrollbar = get_h_scroll_bar()
		if h_scrollbar and not h_scrollbar.gui_input.is_connected(_on_scrollbar_input):
			h_scrollbar.gui_input.connect(_on_scrollbar_input)

func _disconnect_scrollbar_signals(scrollbar: ScrollBar):
	if scrollbar and scrollbar.value_changed.is_connected(_on_internal_scroll_changed):
		scrollbar.value_changed.disconnect(_on_internal_scroll_changed)
	if scrollbar and scrollbar.gui_input.is_connected(_on_scrollbar_input):
		scrollbar.gui_input.disconnect(_on_scrollbar_input)

func _reconnect_scrollbars():
	var v_scrollbar = get_v_scroll_bar()
	var h_scrollbar = get_h_scroll_bar()
	
	_disconnect_scrollbar_signals(v_scrollbar)
	_disconnect_scrollbar_signals(h_scrollbar)
	
	_connect_scrollbar()
	_connect_scrollbar_input()

func _get_current_scroll() -> float:
	return scroll_vertical if vertical else scroll_horizontal

func _set_current_scroll(value: float):
	if vertical:
		scroll_vertical = int(value)
	else:
		scroll_horizontal = int(value)

func _get_scrollbar():
	if vertical:
		return get_v_scroll_bar()
	return get_h_scroll_bar()

func _on_internal_scroll_changed(value: float):
	# Re-sync the wheel/tween target when the scroll position changes with no
	# tween in flight (engine end-of-frame clamps, guarded writes during layout
	# recalcs). Without this the next wheel tick accumulates from a stale
	# target and jumps to a far position.
	if not _is_smooth_scrolling:
		_target_scroll = value
	scroll_value_changed.emit(value)

func _get_centered_scroll_for_control(p_control: Control) -> float:
	var control_rect = p_control.get_global_rect()
	var scroll_rect = get_global_rect()
	
	if vertical:
		var control_center = control_rect.position.y + control_rect.size.y / 2.0
		var viewport_center = scroll_rect.position.y + scroll_rect.size.y / 2.0
		var diff = control_center - viewport_center
		var target = _get_current_scroll() + diff
		
		var scrollbar = _get_scrollbar()
		if scrollbar:
			target = clampf(target, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
		
		return target
	else:
		var control_center = control_rect.position.x + control_rect.size.x / 2.0
		var viewport_center = scroll_rect.position.x + scroll_rect.size.x / 2.0
		var diff = control_center - viewport_center
		var target = _get_current_scroll() + diff
		
		var scrollbar = _get_scrollbar()
		if scrollbar:
			target = clampf(target, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
		
		return target

func _is_control_fully_visible(p_control: Control) -> bool:
	"""Returns true if the control is completely within the viewport bounds."""
	var control_rect = p_control.get_global_rect()
	var scroll_rect = get_global_rect()

	if vertical:
		return control_rect.position.y >= scroll_rect.position.y \
			and control_rect.end.y <= scroll_rect.end.y
	else:
		return control_rect.position.x >= scroll_rect.position.x \
			and control_rect.end.x <= scroll_rect.end.x

func _on_gui_input(event: InputEvent):
	if not smooth_scrolling or scroll_paused:
		return
	
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var scrollbar = _get_scrollbar()
			if not scrollbar:
				return

			if page_snap_period > 0.0 and page_step_provider.is_valid():
				# Paged mode via provider: the owning grid resolves the target
				# with the same math as keyboard/controller navigation.
				var max_target = scrollbar.max_value - scrollbar.page
				if page_snap_max_target >= 0.0:
					max_target = minf(max_target, page_snap_max_target)
				var target: float = page_step_provider.call(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
				_target_scroll = clampf(target, scrollbar.min_value, max_target)
				_page_scroll_in_flight = true
				_start_smooth_scroll(1.0, wheel_scroll_duration)
				accept_event()
				return

			if page_snap_period > 0.0:
				# Paged mode: one tick = one page. Derive the current page with
				# round() (nearest) rather than floor/ceil on the float ratio —
				# at exact page targets the ratio lands a hair above or below k,
				# which made ticks stick in place or skip a page depending on
				# float rounding.
				var max_target = scrollbar.max_value - scrollbar.page
				if page_snap_max_target >= 0.0:
					max_target = minf(max_target, page_snap_max_target)
				var page := int(round((_target_scroll - page_snap_offset) / page_snap_period))
				page += -1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1
				_target_scroll = clampf(page * page_snap_period + page_snap_offset, scrollbar.min_value, max_target)
				_page_scroll_in_flight = true
				_start_smooth_scroll(1.0, wheel_scroll_duration)
				accept_event()
				return

			var step = scrollbar.custom_step
			if step <= 0:
				step = scrollbar.page / 10.0
			if event.factor > 1.0:
				step *= event.factor

			if not _wheel_chase_active:
				_chase_pos = _get_current_scroll()
			var current := _chase_pos
			var dir := -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			# Reversing direction discards any accumulated backlog so the view
			# responds immediately instead of unwinding the old target first.
			if signf(_target_scroll - current) == -dir:
				_target_scroll = current
			_target_scroll += dir * step
			_target_scroll = clampf(_target_scroll, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			# Chase the target with exponential smoothing in _process() instead of
			# restarting a tween per tick: velocity stays proportional to the
			# remaining distance, so bursts track the wheel without jitter and
			# isolated ticks keep the same glide shape.
			if _scroll_tween and _scroll_tween.is_valid():
				_scroll_tween.kill()
			_wheel_chase_active = true
			_is_smooth_scrolling = true
			accept_event()

func _on_scrollbar_input(event: InputEvent):
	if not smooth_scrolling or scroll_paused:
		return
	
	var scrollbar = _get_scrollbar()
	if not scrollbar:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_is_dragging_scrollbar = true
				_scrollbar_drag_start_mouse_pos = event.global_position.y if vertical else event.global_position.x
				_wheel_chase_active = false
				if _scroll_tween and _scroll_tween.is_valid():
					_scroll_tween.kill()
				_is_smooth_scrolling = false
				_page_scroll_in_flight = false

				_target_scroll = _get_current_scroll()
				_scrollbar_drag_start_value = _target_scroll
			else:
				_is_dragging_scrollbar = false
				snap_to_page()
	
	elif event is InputEventMouseMotion and _is_dragging_scrollbar:
		var mouse_delta = (event.global_position.y if vertical else event.global_position.x) - _scrollbar_drag_start_mouse_pos
		
		var scrollable_range = scrollbar.max_value - scrollbar.min_value - scrollbar.page
		var scrollbar_track_size = scrollbar.size.y if vertical else scrollbar.size.x
		var scrollbar_min_size = scrollbar.get_combined_minimum_size().y if vertical else scrollbar.get_combined_minimum_size().x
		var scrollbar_track_length = scrollbar_track_size - scrollbar_min_size
		
		if scrollbar_track_length > 0 and scrollable_range > 0:
			var scroll_delta = (mouse_delta / scrollbar_track_length) * scrollable_range
			_target_scroll = _scrollbar_drag_start_value + scroll_delta
			
			_target_scroll = clampf(_target_scroll, scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			_start_smooth_scroll()
			scrollbar.accept_event()

func _start_smooth_scroll(duration_multiplier: float = 1.0, fixed_duration: float = -1.0, _focus_callback: Callable = Callable(), trans_type: Tween.TransitionType = Tween.TRANS_EXPO, ease_type: Tween.EaseType = Tween.EASE_OUT):
	var scrollbar = _get_scrollbar()
	if not scrollbar:
		return

	# Cancel any pending focus timer from previous scroll
	if _focus_timer:
		_focus_timer.stop()
		_focus_timer.queue_free()
		_focus_timer = null

	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_wheel_chase_active = false

	var start_value = _get_current_scroll()
	var target_value = _target_scroll

	var duration: float
	if fixed_duration >= 0.0:
		# Caller-requested fixed duration (e.g. mouse-wheel chasing).
		duration = fixed_duration
	else:
		# Duration scales with distance so short hops feel snappy and long jumps
		# don't teleport, with hard bounds on both ends.
		var distance = abs(target_value - start_value)
		duration = smooth_scroll_min_duration
		if distance > 0.0 and smooth_scroll_reference_distance > 0.0:
			duration = clampf(
				smooth_scroll_duration * (distance / smooth_scroll_reference_distance),
				smooth_scroll_min_duration,
				smooth_scroll_max_duration)

	# Apply duration multiplier for faster/slower animations
	duration = clampf(duration * duration_multiplier, 0.0, smooth_scroll_max_duration)
	
	_is_smooth_scrolling = true

	# DISABLED: Focus callback logic causing HSL flicker during scroll
	# This was added for the "random game" feature but causes focus conflicts
	# during smooth scrolling, making HSL effects flicker.
	# TODO: Find alternative approach for focusing after scroll completes
	# Set up focus callback to fire at 60% completion
	#if focus_callback.is_valid():
	#   _focus_timer = Timer.new()
	#   _focus_timer.wait_time = duration * 0.6
	#   _focus_timer.one_shot = true
	#   _focus_timer.timeout.connect(focus_callback)
	#   add_child(_focus_timer)
	#   _focus_timer.start()
	
	_scroll_tween = create_tween()
	_scroll_tween.set_trans(trans_type)
	_scroll_tween.set_ease(ease_type)
	
	_scroll_tween.tween_method(
		func(val: float): 
			_set_current_scroll(val),
		start_value,
		target_value,
		duration
	)
	
	_scroll_tween.finished.connect(func():
		_is_smooth_scrolling = false
		_page_scroll_in_flight = false
		scroll_completed.emit()
	)

func get_target_scroll() -> float:
	if smooth_scrolling:
		return _target_scroll
	return _get_current_scroll()

func is_scrolling() -> bool:
	return _is_smooth_scrolling

## Snaps the current scroll position to the nearest page target (no-op when
## page snapping is disabled or already aligned). Called on drag/touch release.
func snap_to_page() -> void:
	if page_snap_period <= 0.0 or scroll_paused:
		return
	var scrollbar = _get_scrollbar()
	if not scrollbar:
		return
	var current = _get_current_scroll()
	var snapped = round((current - page_snap_offset) / page_snap_period) * page_snap_period + page_snap_offset
	var max_target = maxf(scrollbar.min_value, scrollbar.max_value - scrollbar.page)
	if page_snap_max_target >= 0.0:
		max_target = minf(max_target, page_snap_max_target)
	snapped = clampf(snapped, scrollbar.min_value, max_target)
	if is_equal_approx(snapped, current):
		return
	_target_scroll = snapped
	_start_smooth_scroll()

func _on_native_scroll_ended() -> void:
	if _is_dragging_scrollbar or _is_smooth_scrolling:
		return
	snap_to_page()

func scroll_to(target: float, animate: bool = true, duration_multiplier: float = 1.0, _focus_callback: Callable = Callable()):
	# Kill any running tween first to prevent conflicts
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_wheel_chase_active = false
	_is_smooth_scrolling = false
	_page_scroll_in_flight = false
	
	if animate and smooth_scrolling:
		_target_scroll = target
		# Focus callback disabled - see _start_smooth_scroll() for details
		_start_smooth_scroll(duration_multiplier)
	else:
		_target_scroll = target
		var sb: ScrollBar = _get_scrollbar()
		if sb and target > sb.max_value - sb.page:
			sb.max_value = target + sb.page
		_set_current_scroll(target)

func stop_smooth_scroll() -> void:
	"""Stop any active smooth-scroll tween without changing the target."""
	_wheel_chase_active = false
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_is_smooth_scrolling = false
