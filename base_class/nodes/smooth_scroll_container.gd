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
## Fixed tween duration for paged mouse-wheel scrolling. Free wheel ticks use
## the velocity-based chase below.
@export var wheel_scroll_duration: float = 1.0
## Time constant (seconds) for the free wheel chase: wheel input sets an
## isolated target/velocity that glides to rest without interfering with tweens
## or programmatic scrolls.
@export var wheel_chase_tau: float = 0.2
## Far-jump policy (borrowed from Argosy/Playnite): when an animated scroll's
## distance exceeds this many viewport pages, the container first SNAPS to
## within `far_jump_page_count` pages of the target and only tweens the short
## remainder. Long letter-carousel / random-game jumps therefore never tween
## across the whole library (the tween-vs-input fight), while short hops and
## wheel scrolling stay fully animated.
@export var far_jump_page_count: float = 2.0
var _wheel_chase_active: bool = false
## Wheel input uses its own target/velocity so it can never fight a tween or
## programmatic scroll. Tween/programmatic paths reset this state.
var _wheel_target: float = 0.0
var _wheel_velocity: float = 0.0

## px/s velocity of the float motion model (EMA over frame deltas), exposed
## for consumers like the grid's cover-suppression and buffer-load debounce.
## SSC owns the float model, so it owns its derivative too. Discontinuous
## writes (write_immediate*) reset the baseline so teleports don't read as
## motion; decays to exactly 0 at rest.
var _scroll_velocity_ema: float = 0.0
var _velocity_last_scroll: float = -1.0

## Single-writer scroll ownership. Every scroll operation (wheel tick burst,
## tween, instant set, scrollbar drag) bumps this monotonic id and captures it;
## stale per-frame callbacks (killed tweens, lagging chases) compare against it
## and no-op. There is exactly one live writer of the scrollbar at any moment.
var _owner_id: int = 0
## Precise (non-int-truncated) scroll position. The ScrollBar stores ints, which
## quantize smooth motion into 1px steps; the grid and visual layer read this
## float instead so tween/chase motion stays sub-pixel smooth.
var _scroll_float: float = 0.0
## Set after a programmatic scroll so snap_to_page/native-scroll-end handlers
## do not yank the freshly landed position to a page boundary.
var _suppress_next_snap: bool = false

## Diagnostic scroll trace, enabled with KYODAI_SCROLL_TRACE=1 in the
## environment. Logs every scroll-state transition with timestamps so a
## jump-then-wheel repro shows exactly who moves the scroll and when.
## Off by default; a single bool check when off.
static var trace_enabled: bool = OS.get_environment("KYODAI_SCROLL_TRACE") == "1"

static func _strace(msg: String) -> void:
	if trace_enabled:
		print("[ScrollTrace] t=", Time.get_ticks_msec(), " ", msg)

static func _strace_caller() -> String:
	var stack := get_stack()
	if stack.size() > 1:
		return str(stack[1].get("function", "?"))
	return "?"
@export var vertical: bool = true:
	set(value):
		if vertical != value:
			vertical = value
			_target_scroll = 0.0
			_wheel_target = 0.0
			_wheel_velocity = 0.0
			_wheel_chase_active = false
			if is_inside_tree():
				_reconnect_scrollbars()

var _target_scroll: float = 0.0
var _scroll_tween: Tween
var _is_smooth_scrolling: bool = false
var _is_dragging_scrollbar: bool = false
var _scrollbar_drag_start_mouse_pos: float = 0.0
var _scrollbar_drag_start_value: float = 0.0

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
			_wheel_velocity = 0.0
			if _scroll_tween and _scroll_tween.is_valid():
				_scroll_tween.kill()
			_is_smooth_scrolling = false
			_page_scroll_in_flight = false

func _process(delta: float) -> void:
	# Velocity EMA over the float model — runs even when idle so the reading
	# decays to exactly 0 at rest (consumers poll it every frame).
	if delta > 0.0:
		var inst := 0.0
		if _velocity_last_scroll >= 0.0:
			inst = (_scroll_float - _velocity_last_scroll) / delta
		_velocity_last_scroll = _scroll_float
		_scroll_velocity_ema = lerpf(_scroll_velocity_ema, inst, 0.3)
		if absf(inst) < 0.5 and not _wheel_chase_active and not _is_smooth_scrolling:
			_scroll_velocity_ema = 0.0
	if not _wheel_chase_active:
		return
	# Wheel chase: exponential glide toward the isolated wheel target, on the
	# FLOAT motion model — the fractional remainder keeps flowing through the
	# tail so the glide settles instead of stalling in 1px steps. Tweens and
	# programmatic scrolls own the scrollbar separately; the value_changed echo
	# handler ignores echoes while a smooth operation is in flight.
	# Re-clamp the target to the LIVE range every frame: a library shrink
	# (platform switch, filter) can strand a chase beyond the new content end.
	# Without this the writes clamp to max, diff never reaches the done
	# threshold, and the chase — plus is_scrolling() — runs forever.
	var sb_reclamp = _get_scrollbar()
	if sb_reclamp:
		_wheel_target = clampf(_wheel_target, sb_reclamp.min_value, maxf(sb_reclamp.min_value, sb_reclamp.max_value - sb_reclamp.page))
	var current := _scroll_float
	var diff := _wheel_target - current
	if absf(diff) < 0.05:
		# Terminal write lands on the exact quantized target so rest state is
		# pixel-identical to content (echoes of our own writes are ignored, so
		# the write itself must carry the exact value).
		_set_current_scroll_terminal(_wheel_target)
		_wheel_chase_active = false
		_wheel_velocity = 0.0
		_is_smooth_scrolling = false
		_page_scroll_in_flight = false
		_strace("wheel-chase-done target=" + str(_wheel_target))
		scroll_completed.emit()
		return
	var step := diff * (1.0 - exp(-delta / wheel_chase_tau))
	_wheel_velocity = step / delta
	_set_current_scroll(current + step)

## The float MOTION MODEL position. During tweens/wheel chase this carries the
## sub-pixel remainder so the visual layer glides; the scrollbar/content holds
## the rounded int. At rest both are pixel-identical (terminal writes land
## exactly). Prefer over scroll_vertical/horizontal for visual math.
func get_scroll_float() -> float:
	return _scroll_float

## px/s velocity of the float motion model (EMA over frame deltas; exactly 0
## at rest). The grid consumes this for cover-download suppression and the
## buffer-load debounce.
func get_scroll_velocity() -> float:
	return _scroll_velocity_ema

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
	# Disconnect from the focus hub to prevent dangling signal connections.
	var hub := FocusSubManager.get_instance()
	if hub and hub.ui_focus_changed.is_connected(_on_focus_changed):
		hub.ui_focus_changed.disconnect(_on_focus_changed)

func _connect_focus_signal() -> void:
	"""Connect to UI-viewport focus changes via the FocusSubManager hub, which
	survives dual-screen reparents without any reconnect bookkeeping."""
	var hub := FocusSubManager.get_instance()
	if not hub:
		return
	if not hub.ui_focus_changed.is_connected(_on_focus_changed):
		hub.ui_focus_changed.connect(_on_focus_changed)

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
		# 1px deadzone: the scrollbar truncates to int, so an untruncated float
		# target would otherwise re-trigger a sub-pixel tween on every focus hop.
		if absf(provided_target - _get_current_scroll()) < 1.0:
			return
		_target_scroll = provided_target
		_start_smooth_scroll(focus_scroll_duration_multiplier, -1.0, Tween.TRANS_CUBIC, Tween.EASE_OUT)
		return

	# If the control is already fully visible, don't re-center it. This prevents
	# subtle vertical/horizontal drift when moving across a row/column that is
	# already inside the viewport.
	if _is_control_fully_visible(control):
		return

	# Calculate and smoothly scroll to centered position
	_target_scroll = _get_centered_scroll_for_control(control)
	_start_smooth_scroll(focus_scroll_duration_multiplier, -1.0, Tween.TRANS_CUBIC, Tween.EASE_OUT)

func reconnect_viewport() -> void:
	"""Ensure the hub focus connection after reparenting into a SubViewport.
	The hub follows the UI viewport itself, so this is an idempotent ensure."""
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

## Diagnostic for the single scroll-writer contract: counts scroll writes
## observed on the scrollbar that did NOT pass through this class's write
## paths (_set_current_scroll). External writers (the grid poking
## scroll_vertical directly, engine clamps engaging because the extent was
## not pre-raised) show up here. Read/reset from tests; should stay 0.
var external_write_count := 0
var _write_depth := 0

func _set_current_scroll(value: float):
	# Motion model vs layout truth: the ScrollBar stores ints (content moves in
	# 1px steps), but the tracked float keeps the raw fractional position so
	# the visual layer — stamped from get_scroll_float() — glides through the
	# tail instead of stalling in quantized steps. round() (not int()) keeps
	# the quantization symmetric, and every terminal write lands on the target
	# exactly, so at rest float and content are pixel-identical.
	_scroll_float = value
	_write_depth += 1
	if vertical:
		scroll_vertical = roundi(value)
	else:
		scroll_horizontal = roundi(value)
	_write_depth -= 1

## Terminal variant: after the write, reconcile the float model with the
## POST-CLAMP scrollbar truth. The Range can clamp to a fractional
## max − page just below the quantized value, leaving the model 1px off the
## int content otherwise. Use for rest-state writes only — mid-motion writes
## must keep the fractional glide.
func _set_current_scroll_terminal(value: float) -> void:
	_set_current_scroll(value)
	_scroll_float = float(scroll_vertical if vertical else scroll_horizontal)

func _get_scrollbar():
	if vertical:
		return get_v_scroll_bar()
	return get_h_scroll_bar()

func _on_internal_scroll_changed(value: float):
	# Echoes of our OWN writes (Range emits synchronously from
	# _set_current_scroll) carry no information — the float motion model is
	# already authoritative — so they are ignored entirely. Only writes that
	# did not pass through this class land below: engine end-of-frame clamps,
	# native touch-scroll pans, and contract violations. An external write
	# always WINS over in-flight motion (it is either the user or the engine
	# asserting layout truth), so motion stands down and the model adopts it.
	if _write_depth == 0:
		external_write_count += 1
		if _is_smooth_scrolling or _wheel_chase_active:
			_strace("external write during motion: standing down (value=" + str(value) + ")")
			_owner_id += 1
			if _scroll_tween and _scroll_tween.is_valid():
				_scroll_tween.kill()
			_wheel_chase_active = false
			_wheel_velocity = 0.0
			_is_smooth_scrolling = false
			_page_scroll_in_flight = false
		_strace("resync target " + str(_target_scroll) + " -> " + str(value))
		# Adopt the engine/user truth from the POST-CLAMP int content position
		# (the Range can clamp to a fractional max − page just below the
		# rounded value), so the float model matches the content at rest.
		var adopted := float(scroll_vertical if vertical else scroll_horizontal)
		_target_scroll = adopted
		_wheel_target = adopted
		_scroll_float = adopted
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
				_owner_id += 1
				_target_scroll = clampf(target, scrollbar.min_value, max_target)
				_page_scroll_in_flight = true
				_start_smooth_scroll(1.0, wheel_scroll_duration)
				accept_event()
				return

			if page_snap_period > 0.0:
				# Paged mode: one tick = one page. Derive the current page from the
				# actual scrollbar value, not the accumulated wheel target, so page
				# snaps never jump from a stale target.
				var max_target = scrollbar.max_value - scrollbar.page
				if page_snap_max_target >= 0.0:
					max_target = minf(max_target, page_snap_max_target)
				var page := int(round((_get_current_scroll() - page_snap_offset) / page_snap_period))
				page += -1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1
				_owner_id += 1
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

			var current := _scroll_float
			var dir := -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			# Wheel input writes to a dedicated target/velocity state so it can
			# never carry stale backlog into a tween or programmatic scroll.
			# Reversing direction cancels the in-flight wheel target.
			if signf(_wheel_target - current) == -dir:
				_wheel_target = current
				_wheel_velocity = 0.0
			# Wheel destinations are free-scroll targets with no alignment
			# constraints: quantize to whole pixels so the glide lands exactly
			# and rest state is pixel-perfect (fractional targets would leave a
			# sub-pixel float/content gap at rest).
			_wheel_target = clampf(float(roundi(_wheel_target + dir * step)), scrollbar.min_value, scrollbar.max_value - scrollbar.page)
			# Wheel takes ownership: kill any tween so the two never write to the
			# scrollbar at the same time.
			_owner_id += 1
			if _scroll_tween and _scroll_tween.is_valid():
				_scroll_tween.kill()
				_is_smooth_scrolling = false
				_page_scroll_in_flight = false
			_wheel_chase_active = true
			_is_smooth_scrolling = true
			_strace("wheel dir=" + str(dir) + " wheel_target=" + str(_wheel_target) + " current=" + str(current))
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
				_owner_id += 1
				_wheel_chase_active = false
				_wheel_velocity = 0.0
				if _scroll_tween and _scroll_tween.is_valid():
					_scroll_tween.kill()
				_is_smooth_scrolling = false
				_page_scroll_in_flight = false
				_suppress_next_snap = false

				_target_scroll = _get_current_scroll()
				_wheel_target = _target_scroll
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

func _start_smooth_scroll(duration_multiplier: float = 1.0, fixed_duration: float = -1.0, trans_type: Tween.TransitionType = Tween.TRANS_CUBIC, ease_type: Tween.EaseType = Tween.EASE_OUT):
	var scrollbar = _get_scrollbar()
	if not scrollbar:
		return

	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()

	# Single-writer invariant: the tween owns the scroll position from here,
	# so stand down the wheel chase. Otherwise both write every frame and a
	# stale chase glides back toward its old target when the tween finishes.
	_wheel_chase_active = false
	_wheel_velocity = 0.0
	_wheel_target = _target_scroll

	# Capture the ownership token: if another scroll operation takes over
	# mid-tween, this tween's per-frame callback goes stale and stops writing.
	var my_owner_id := _owner_id
	var start_value = _scroll_float
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

	_strace("tween-start target=" + str(target_value) + " start=" + str(start_value) + " dur=" + str(duration) + " caller=" + _strace_caller() + " chase_was=" + str(_wheel_chase_active))
	_is_smooth_scrolling = true

	_scroll_tween = create_tween()
	_scroll_tween.set_trans(trans_type)
	_scroll_tween.set_ease(ease_type)
	
	_scroll_tween.tween_method(
		func(val: float):
			if my_owner_id != _owner_id:
				# A newer scroll operation owns the scrollbar; stop writing.
				return
			_set_current_scroll(val),
		start_value,
		target_value,
		duration
	)

	_scroll_tween.finished.connect(func():
		if my_owner_id != _owner_id:
			return
		# Land exactly on the target, quantized: echoes of our own writes are
		# ignored, so this write itself must leave float == int content.
		# Clamp to the live range first: the library may have shrunk mid-tween,
		# and an unclamped landing would park the float model beyond the
		# content end.
		_is_smooth_scrolling = false
		_page_scroll_in_flight = false
		var sb_land = _get_scrollbar()
		if sb_land:
			target_value = clampf(target_value, sb_land.min_value, maxf(sb_land.min_value, sb_land.max_value - sb_land.page))
		_set_current_scroll_terminal(target_value)
		SmoothScrollContainer._strace("tween-done target=" + str(target_value) + " actual=" + str(_get_current_scroll()))
		scroll_completed.emit()
	)

func get_target_scroll() -> float:
	if _wheel_chase_active:
		return _wheel_target
	if smooth_scrolling:
		return _target_scroll
	return _get_current_scroll()

func is_scrolling() -> bool:
	return _is_smooth_scrolling or _wheel_chase_active

## Snaps the current scroll position to the nearest page target (no-op when
## page snapping is disabled or already aligned). Called on drag/touch release.
func snap_to_page() -> void:
	if page_snap_period <= 0.0 or scroll_paused:
		return
	if _suppress_next_snap:
		# A programmatic jump just landed on a deliberate (non-page) position;
		# snapping now would yank it to a boundary and fight the user.
		_suppress_next_snap = false
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
	_wheel_target = snapped
	_start_smooth_scroll()

func _on_native_scroll_ended() -> void:
	if _is_dragging_scrollbar or _is_smooth_scrolling:
		return
	snap_to_page()

func scroll_to(target: float, animate: bool = true, duration_multiplier: float = 1.0):
	_strace("scroll_to target=" + str(target) + " animate=" + str(animate) + " caller=" + _strace_caller())
	# Take ownership: any previous writer (tween, chase) goes stale right now.
	_owner_id += 1
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_wheel_chase_active = false
	_wheel_velocity = 0.0
	_is_smooth_scrolling = false
	_page_scroll_in_flight = false

	_target_scroll = target
	_wheel_target = target
	if animate and smooth_scrolling:
		var scrollbar = _get_scrollbar()
		var current: float = _scroll_float
		var distance: float = absf(target - current)
		var page_size: float = scrollbar.page if scrollbar else 0.0
		var snap_distance: float = far_jump_page_count * page_size
		if snap_distance > 0.0 and distance > snap_distance:
			# Far jump (Argosy/Playnite policy): snap to within `snap_distance`
			# of the target instantly so the window rebuilds at the destination,
			# then tween only the short remainder. No more multi-second tween
			# fighting user input across the whole library.
			var intermediate: float = target - signf(target - current) * snap_distance
			if page_snap_period > 0.0:
				# Paginated: a raw geometric intermediate lands in the inter-page
				# gap (a broken empty frame). Snap it to the nearest page target
				# on the path instead, so the rebuild lands on a real page.
				var travel := signf(target - current)
				intermediate = round((intermediate - page_snap_offset) / page_snap_period) * page_snap_period + page_snap_offset
				if page_snap_max_target >= 0.0:
					intermediate = minf(intermediate, page_snap_max_target)
				intermediate = clampf(intermediate, minf(current, target), maxf(current, target))
				if signf(target - intermediate) != travel and intermediate != target:
					# Rounding sent it behind the start; fall back to one period out.
					intermediate = target - travel * page_snap_period
					if page_snap_max_target >= 0.0:
						intermediate = minf(intermediate, page_snap_max_target)
			_set_current_scroll(intermediate)
			_suppress_next_snap = true
		_start_smooth_scroll(duration_multiplier)
		_suppress_next_snap = true
	else:
		# Clamp to the valid range instead of extending max_value: the old
		# extension corrupted the scrollbar range when a stale/deep target
		# landed here after a library shrink, and every later window/margin
		# computation ran against a garbage range.
		var sb: ScrollBar = _get_scrollbar()
		if sb:
			target = clampf(target, sb.min_value, maxf(sb.min_value, sb.max_value - sb.page))
		# Instant jump: no glide follows, so land the float model on the exact
		# quantized position — rest state must be pixel-identical to content.
		_set_current_scroll_terminal(target)
		_suppress_next_snap = true

## Instant write — the ONLY way external owners (the grid) may move the
## scroll position. Takes ownership (stale tween/chase callbacks go inert),
## lands the float model and the scrollbar on the exact quantized value, and
## clamps to the live range. Use scroll_to() for anything animated.
func write_immediate(value: float) -> void:
	_strace("write_immediate value=" + str(value) + " caller=" + _strace_caller())
	_owner_id += 1
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_wheel_chase_active = false
	_wheel_velocity = 0.0
	_is_smooth_scrolling = false
	_page_scroll_in_flight = false
	# Discontinuous write: reset the velocity baseline so the jump doesn't
	# read as motion (the EMA measures continuous movement only).
	_scroll_velocity_ema = 0.0
	_velocity_last_scroll = -1.0
	var sb: ScrollBar = _get_scrollbar()
	if sb:
		value = clampf(value, sb.min_value, maxf(sb.min_value, sb.max_value - sb.page))
	_target_scroll = value
	_wheel_target = value
	_set_current_scroll_terminal(value)
	_suppress_next_snap = true

## Instant write that first pre-raises the scrollbar extent so the value is
## not clamped by a stale range. Use for layout-recalc restores: mid-frame
## the scrollbar max_value still reflects the OLD content size, and a clamped
## write would rebuild the grid's window at the wrong offset. The extent
## argument must be what the end-of-frame sort will compute anyway
## (grid-computed truth), so the clamp never actually engages afterwards.
func write_immediate_with_extent(value: float, required_max_value: float) -> void:
	var sb: ScrollBar = _get_scrollbar()
	if sb and required_max_value > sb.max_value:
		sb.max_value = required_max_value
	write_immediate(value)

func stop_smooth_scroll() -> void:
	"""Stop any active smooth-scroll tween without changing the target."""
	_strace("stop chase_was=" + str(_wheel_chase_active) + " tween_valid=" + str(_scroll_tween != null and _scroll_tween.is_valid()))
	_wheel_chase_active = false
	_wheel_velocity = 0.0
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_is_smooth_scrolling = false
