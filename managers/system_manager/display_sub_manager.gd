@icon("res://Icons/ArrayMesh.svg")
#display_sub_manager.gd
extends Manager
class_name DisplaySubManager

## Single source of truth for viewport size and UI scale.
## Emits debounced viewport_size_changed signals so consumers don't redo layout
## math on every pixel of a window resize.
##
## Resize-path model: all window-size-driven *layout* logic (grid, breakpoints,
## tiers, compact re-eval, overlay broadcast) consumes viewport_size_changed —
## this manager's single gated pipeline. Raw window/control resize listeners
## elsewhere are deliberately reserved for (a) chrome/geometry bookkeeping that
## must stay prompt and cheap (title bar, grips, maximize-state guard) and
## (b) local rect maintenance where a control's rect tracks local state — not
## for layout math. Don't fork a new window-resize path.

signal viewport_size_changed(new_size: Vector2)
signal ui_scale_changed(new_scale: float)
signal dual_screen_detected(second_screen_index: int)
signal dual_screen_lost()
signal dual_screen_mode_changed(enabled: bool, second_screen_index: int)
signal dual_screen_availability_changed(available: bool)
signal initial_window_size_settled()
## Emitted whenever the custom title bar chrome (borderless windowed frame)
## becomes active or inactive. TitleBar/WindowResizeGrips show/hide on it.
signal window_chrome_changed(active: bool)

# Debounce for non-gesture resizes (fullscreen toggle, maximize/restore,
# WM-driven, programmatic): one stable update instead of one per pixel.
# Grip drags are gated separately: _resize_gesture_active suppresses the
# cascade for the whole OS resize loop, and end_resize_gesture() flushes it
# the moment the button releases — the grid never re-snaps mid-drag.
const RESIZE_DEBOUNCE_SECONDS := 0.15
const SCALE_DEBOUNCE_SECONDS := 0.2
const BASE_HEIGHT := 1080.0
const BASE_DPI := 160.0
const DEFAULT_DPI := 96.0
const MIN_UI_SCALE := 1.0
const MAX_UI_SCALE := 5.0

## Smallest windowed size while the native frame is stripped (the OS can no
## longer enforce a minimum via the frame). Matches _clamp_window_size.
const MIN_WINDOW_SIZE := Vector2i(400, 300)

## Shared layout tier breakpoints (viewport width in dp). Compact tightens
## margins; small additionally collapses secondary content (covers, setting
## descriptions, related rows). M3Dialog's 600dp small-screen rule matches
## SMALL_VIEWPORT_DP.
const COMPACT_VIEWPORT_DP := 700.0
const SMALL_VIEWPORT_DP := 600.0

## CanvasLayer.layer for the black resize-freeze overlay: above every app
## overlay (LAUNCH_CRITICAL = 1101), so nothing peeks through mid-drag.
const RESIZE_FREEZE_LAYER := 1200

@onready var settings_man = $"/root/DataManager"

var _viewport_size: Vector2 = Vector2.ZERO
var _ui_scale: float = -1.0

# Set when ui_scale_changed fires with no listeners connected (startup race:
# _load_user_scale_factor can run before UIManager.initialize connects).
# UIManager consumes this after connecting and reconciles early-built nodes.
var _scale_refresh_pending: bool = false
var _user_scale_factor: float = 1.0
var _current_screen: int = -1
var _resize_debounce_timer: Timer = null
var _scale_debounce_timer: Timer = null

# OS resize gesture gating (see RESIZE_DEBOUNCE_SECONDS): while a
# WindowResizeGrips drag runs, the debounced cascade is held back.
# _resize_pending marks that raw size changes arrived since the last emitted
# cascade, so a gesture that never resized (grip click, no drag) flushes nothing.
var _resize_gesture_active: bool = false
var _resize_pending: bool = false

# Black freeze overlay shown for the whole OS resize gesture: the window keeps
# resizing while the app re-lays-out underneath, and that mid-drag churn is
# distracting — render solid black instead, then reveal the flushed layout the
# moment the gesture ends. Nodes are created lazily and reused across gestures.
var _freeze_layer: CanvasLayer = null
var _freeze_rect: ColorRect = null
# Window size at gesture press, to tell a real drag (window.size changed) from
# a bare grip click — the viewport is frozen mid-gesture, so _resize_pending
# can't make that distinction while the content-scale freeze is in effect.
var _gesture_start_window_size: Vector2i = Vector2i.ZERO

# Dual screen detection state
var _dual_screen_enabled: bool = false
var _dual_screen_available: bool = false
var _second_screen_index: int = -1
var _android_plugin = null

# Custom title bar chrome state (borderless frame in windowed mode, desktop).
# _pre_maximize_rect: windowed rect captured before maximize, used to restore.
# _manual_maximized: true when we sized the window to the work area ourselves
# because the native borderless maximize overlapped the taskbar; mode stays
# WINDOWED in that state, so remember it explicitly (also gates saving the
# window size so the maximized rect never gets persisted as the windowed size).
var _pre_maximize_rect: Rect2i = Rect2i()
var _manual_maximized: bool = false
var _manual_max_rect: Rect2i = Rect2i()
var _max_verify_token: int = 0

# Dual-screen SubViewports are always 1:1 (no size_2d_override): dp scaling is
# applied inside them via M3Units (see _calculate_ui_scale). Never reintroduce
# viewport-level scaling here without disabling M3Units first, or every element
# would be scaled twice. Both Thor screens are ~same density (369dpi top,
# ~350dpi bottom), so per-viewport density correction is unneeded.
var _ayn_thor_manager: Node = null

func _ready() -> void:
	settings_man.connect("setting_changed", _on_setting_changed)

	# Debounce raw viewport resize events into a single stable update.
	_resize_debounce_timer = Timer.new()
	_resize_debounce_timer.one_shot = true
	_resize_debounce_timer.wait_time = RESIZE_DEBOUNCE_SECONDS
	_resize_debounce_timer.timeout.connect(_on_resize_debounced)
	add_child(_resize_debounce_timer)

	# Debounce rapid ui_scale slider changes into a single scale recompute.
	_scale_debounce_timer = Timer.new()
	_scale_debounce_timer.one_shot = true
	_scale_debounce_timer.wait_time = SCALE_DEBOUNCE_SECONDS
	_scale_debounce_timer.timeout.connect(_on_scale_debounced)
	add_child(_scale_debounce_timer)

	# Load the persisted user scale multiplier once DataManager has loaded
	# settings (SystemManager autoloads before DataManager, so defer).
	call_deferred("_load_user_scale_factor")

	# Connect to viewport size changes
	var viewport = get_viewport()
	if viewport:
		viewport.size_changed.connect(_on_viewport_size_changed)
		_viewport_size = viewport.size

	# Calculate initial UI scale and emit it so consumers can initialize.
	_calculate_ui_scale()
	_emit_ui_scale_changed()

	# Diagnostic metrics for density/scaling issues (grep logcat for [Metrics]).
	call_deferred("dump_display_metrics", "startup")

	# Initialize display detection
	_initialize_display_detection()

	# Apply the saved windowed size once the OS window is ready.
	call_deferred("_apply_initial_window_size")

	# Watch window geometry so a manual work-area maximize can't go stale when
	# something else resizes/moves the window (WM tiling, fullscreen, etc.).
	var root_window := get_window()
	if root_window:
		root_window.size_changed.connect(_on_window_geometry_changed)

	# Try to connect to AynThor screen swap signal (may not exist yet)
	call_deferred("_connect_ayn_thor_signals")

func _connect_ayn_thor_signals() -> void:
	_ayn_thor_manager = get_node_or_null("/root/Main/AynThorManager")
	if _ayn_thor_manager and _ayn_thor_manager.has_signal("screens_swapped"):
		_ayn_thor_manager.screens_swapped.connect(_on_screens_swapped)

func _initialize_display_detection() -> void:
	"""Initialize dual screen detection based on platform."""
	# Check if we're on Android and get plugin reference
	if OS.get_name() == "Android":
		_initialize_android_plugin()

	# Check for dual screen once at launch
	# Users need to restart the app if they connect a display while it's running
	_check_for_dual_screen()

func _initialize_android_plugin() -> void:
	"""Initialize Android plugin for display detection."""
	if Engine.has_singleton("PackageChecker"):
		_android_plugin = Engine.get_singleton("PackageChecker")

func _on_viewport_size_changed() -> void:
	"""Raw window resize event: restart the debounce timer.

	Despite the name this is the Window's size_changed — it still fires per
	OS configure while the content-scale freeze pins the logical viewport,
	which is exactly what we want: it keeps _resize_pending tracking the drag
	without touching layout (nothing downstream runs until the cascade)."""
	_resize_pending = true
	if _resize_debounce_timer:
		_resize_debounce_timer.stop()
		_resize_debounce_timer.start()

func _on_resize_debounced() -> void:
	"""Stable resize event: update cached viewport size and notify consumers."""
	if _resize_gesture_active:
		# Grip drag in progress: hold the cascade (pending stays set) until
		# end_resize_gesture() flushes it with the final size.
		return
	# In dual-screen SubViewport mode the app lives in MainViewport, not the
	# root window; cache the active SubViewport size so breakpoint consumers
	# track the rectangle the UI actually occupies (mirrors
	# _emit_swap_resize_notification). Root resizes must not clobber it.
	var viewport = get_viewport()
	if UIManager and UIManager.dual_screen:
		# Group membership is the authoritative marker that the app UI has
		# been reparented into MainViewport (Android viewport mode); on the
		# desktop fallback the app stays in the root window.
		var sub = UIManager.dual_screen.get_main_viewport()
		if sub and sub.is_in_group("m3_overlay_parent"):
			viewport = sub
	if viewport:
		_viewport_size = viewport.size
	else:
		_viewport_size = Vector2.ZERO

	# Detect monitor changes (e.g. dragging window to a different screen).
	var screen := DisplayServer.window_get_current_screen()
	if screen != _current_screen:
		_current_screen = screen
		var old_scale := _ui_scale
		_calculate_ui_scale()
		if not is_equal_approx(_ui_scale, old_scale):
			M3Units.invalidate_cache()
			_emit_ui_scale_changed()

	viewport_size_changed.emit(_viewport_size)

	# Continuously save the windowed size so we don't rely solely on close-time
	# reads, which can return stale/zero values during shutdown.
	save_last_window_size()
	_resize_pending = false

func begin_resize_gesture() -> void:
	"""WindowResizeGrips: grip pressed, OS resize loop starting.

	Two things happen here so the drag is instant and quiet:
	1. Content-scale freeze: pin the logical viewport at its current size
	   (CONTENT_SCALE_MODE_CANVAS_ITEMS + content_scale_size) so the OS window
	   can resize freely underneath while the app receives ZERO size events —
	   no layout, no NOTIFICATION_RESIZED, no listeners, cheap repeat-frames.
	2. Blackout overlay: shown immediately at press so the very first drag
	   frame is already solid black.
	3. Render cut: hide RootLayout so the frozen UI behind the blackout is
	   never drawn — during the drag the app renders a single black rect, so
	   the compositor gets each new-size buffer as fast as the platform
	   allows. Release detection runs in _input, which hidden nodes still
	   receive."""
	if _resize_gesture_active:
		return
	_resize_gesture_active = true
	var window := get_window()
	var vp := get_viewport()
	if window and vp:
		_gesture_start_window_size = window.size
		window.content_scale_size = vp.size
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	_show_resize_freeze()
	if UIManager:
		UIManager.set_main_ui_visible(false)

func is_resize_gesture_active() -> bool:
	return _resize_gesture_active

func end_resize_gesture() -> void:
	"""WindowResizeGrips: first input event proving the resize button released.
	Unfreeze the viewport (it snaps to the real window size), rebuild once it
	has settled, then reveal. A bare grip click just drops the freeze."""
	if not _resize_gesture_active:
		return
	_resize_gesture_active = false
	var window := get_window()
	if window and window.content_scale_mode != Window.CONTENT_SCALE_MODE_DISABLED:
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	# Show the main UI now: the blackout still covers it until the drag path
	# flushes (or the click path drops it this same frame).
	if UIManager:
		UIManager.set_main_ui_visible(true)
	# Real drag = the OS window moved/resized, or the fallback path fired
	# (viewport events got through because the freeze wasn't in effect).
	var drag_resized := _resize_pending \
		or (window != null and window.size != _gesture_start_window_size)
	if drag_resized:
		if _resize_debounce_timer:
			_resize_debounce_timer.stop()
		call_deferred("_finish_resize_gesture")
	else:
		if _freeze_rect:
			_freeze_rect.visible = false
		_resize_pending = false

func _finish_resize_gesture() -> void:
	# The unfreeze resizes the logical viewport to the real window size; wait
	# until it (and any size_changed it queued) has settled so the cascade
	# reads the final size, then flush and reveal — all before the next draw.
	var window := get_window()
	for i in 3:
		if window == null or get_viewport() == null:
			break
		# .size may come through as Vector2i (Window); compare as Vector2.
		if Vector2(get_viewport().size) == Vector2(window.size):
			break
		await get_tree().process_frame
	_on_resize_debounced()
	if _freeze_rect:
		_freeze_rect.visible = false

func _show_resize_freeze() -> void:
	if _freeze_rect:
		_freeze_rect.visible = true
		return
	_freeze_layer = CanvasLayer.new()
	_freeze_layer.layer = RESIZE_FREEZE_LAYER
	_freeze_rect = ColorRect.new()
	_freeze_rect.color = Color.BLACK
	# Input must keep flowing to the grips (_input) so release detection works.
	_freeze_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Explicit anchors AND offsets: set_anchors_preset(PRESET_FULL_RECT) on a
	# fresh 0x0 node preserves the degenerate rect instead of snapping to the
	# parent (same gotcha documented in WindowResizeGrips._ready).
	_freeze_rect.anchor_left = 0.0
	_freeze_rect.anchor_top = 0.0
	_freeze_rect.anchor_right = 1.0
	_freeze_rect.anchor_bottom = 1.0
	_freeze_rect.offset_left = 0.0
	_freeze_rect.offset_top = 0.0
	_freeze_rect.offset_right = 0.0
	_freeze_rect.offset_bottom = 0.0
	_freeze_layer.add_child(_freeze_rect)
	add_child(_freeze_layer)

func get_viewport_size() -> Vector2:
	if _viewport_size == Vector2.ZERO:
		var viewport = get_viewport()
		if viewport:
			_viewport_size = viewport.size
	return _viewport_size

func get_ui_scale() -> float:
	if _ui_scale < 0:
		_calculate_ui_scale()
	return _ui_scale

func _emit_ui_scale_changed() -> void:
	"""Notify listeners, or flag the change when nobody is connected yet."""
	if ui_scale_changed.get_connections().is_empty():
		_scale_refresh_pending = true
	else:
		ui_scale_changed.emit(_ui_scale)

func consume_pending_scale_refresh() -> bool:
	"""UIManager calls this after connecting ui_scale_changed. Returns true (once)
	when a scale change went out before any listener existed, so the caller can
	reconcile nodes built with the stale scale."""
	var was_pending := _scale_refresh_pending
	_scale_refresh_pending = false
	return was_pending


## Diagnostic dump of everything that feeds DP scaling and DS sizing.
## Gated on the internal debug_geometry_logging setting (M3Debug.geom), except
## the startup call, which always logs once since it's the most useful block.
func dump_display_metrics(tag: String) -> void:
	var screen := DisplayServer.window_get_current_screen()
	M3Debug.geom("display", "---- %s ----" % tag)
	M3Debug.geom("display", "os=%s screen_count=%d window_screen=%d window_size=%s window_mode=%d" % [
		OS.get_name(), DisplayServer.get_screen_count(), screen,
		DisplayServer.window_get_size(), DisplayServer.window_get_mode()])
	for i in range(DisplayServer.get_screen_count()):
		M3Debug.geom("display", "screen[%d]: size=%s dpi=%d scale=%.2f position=%s" % [
			i, DisplayServer.screen_get_size(i), DisplayServer.screen_get_dpi(i),
			DisplayServer.screen_get_scale(i), DisplayServer.screen_get_position(i)])
	var os_scale := DisplayServer.screen_get_scale(screen)
	var screen_size := DisplayServer.screen_get_size(screen)
	var resolution_scale := pow(screen_size.y / BASE_HEIGHT, 0.85)
	var dpi := DisplayServer.screen_get_dpi()
	M3Debug.geom("display", "scale inputs: os_scale=%.2f resolution_scale=%.3f (screen_y=%d) dpi=%d dpi_scale=%.3f user_factor=%.2f -> ui_scale=%.3f m3units=%.3f" % [
		os_scale, resolution_scale, screen_size.y, dpi, dpi / BASE_DPI if dpi > 0 else -1.0,
		_user_scale_factor, _ui_scale, M3Units.get_scale()])
	M3Debug.geom("display", "viewport_size=%s ds_enabled=%s" % [_viewport_size, _dual_screen_enabled])
	if _dual_screen_enabled:
		var ds = get_node_or_null("/root/Main/DualScreenSetup")
		var main_viewport = ds.get_node_or_null("MainViewportContainer/MainViewport") if ds else null
		var second_viewport = ds.get_node_or_null("SecondViewportContainer/SecondViewport") if ds else null
		if main_viewport:
			M3Debug.geom("display", "main_viewport: size=%s override=%s stretch=%s" % [
				main_viewport.size, main_viewport.size_2d_override, main_viewport.size_2d_override_stretch])
		if second_viewport:
			M3Debug.geom("display", "second_viewport: size=%s override=%s stretch=%s" % [
				second_viewport.size, second_viewport.size_2d_override, second_viewport.size_2d_override_stretch])

func get_screen_size() -> Vector2i:
	var screen := DisplayServer.window_get_current_screen()
	return DisplayServer.screen_get_size(screen)

func is_narrow_viewport(breakpoint_dp := 850.0) -> bool:
	return get_viewport_size().x < M3Units.dp(breakpoint_dp)

## Compact tier: tighten margins/spacing.
func is_compact_viewport() -> bool:
	return is_narrow_viewport(COMPACT_VIEWPORT_DP)

## Small tier: additionally collapse secondary content (covers, descriptions).
func is_small_viewport() -> bool:
	return is_narrow_viewport(SMALL_VIEWPORT_DP)

func _calculate_ui_scale() -> float:
	"""Compute the DP scale from the current monitor/OS settings.

	This intentionally uses the monitor's resolution and OS display scale, not
	the window viewport size, so resizing the window does not fluctuate the UI
	scale.
	"""
	_current_screen = DisplayServer.window_get_current_screen()
	var os_scale := DisplayServer.screen_get_scale(_current_screen)
	if os_scale <= 0:
		os_scale = 1.0

	var screen_size := DisplayServer.screen_get_size(_current_screen)
	var resolution_scale := pow(screen_size.y / BASE_HEIGHT, 1.0)

	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0:
		dpi = int(DEFAULT_DPI)
	var dpi_scale := dpi / BASE_DPI

	_ui_scale = clamp(max(os_scale, resolution_scale, dpi_scale) * _user_scale_factor, MIN_UI_SCALE, MAX_UI_SCALE)
	return _ui_scale

func _apply_initial_window_size() -> void:
	var window_before := DisplayServer.window_get_size()
	var viewport: Viewport = get_viewport()
	var viewport_before: Vector2i = viewport.size
	var viewport_size_before := get_viewport_size()
	var windowed_setting = settings_man.get_setting("windowed")
	# Apply the borderless chrome BEFORE the mode/size changes below: the saved
	# window size is a client-area size, so it must be restored against the
	# final frame style (custom title bar vs. native title bar).
	if windowed_setting and not windowed_setting.value:
		# Fullscreen (windowed = false): restore exclusive fullscreen. The
		# borderless flag is ignored for fullscreen windows, so leave it alone.
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		print("[SystemManager.display] Restored fullscreen mode")
	elif windowed_setting and windowed_setting.value:
		# Windowed: strip the native frame (custom title bar on desktop), then
		# restore last size if available; otherwise let the existing
		# signal/resize path handle it.
		apply_window_chrome(true)
		var last_size := restore_last_window_size()
		if last_size == Vector2i.ZERO:
			print("[SystemManager.display] No saved window size, using resolution preset")
		else:
			print("[SystemManager.display] Restored saved window size: ", last_size)
	else:
		# Setting missing; leave default window mode alone, but match the
		# chrome to the mode we actually ended up in.
		apply_window_chrome(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED)

	# Wait for the OS window size and viewport size to stabilize. The OS may need
	# a few frames to apply the new window size, and the Godot viewport can lag
	# behind. Instead of waiting for an arbitrary timeout, we wait until both
	# sizes have stopped changing for several consecutive frames. If the sizes
	# never changed (no resize needed), we exit after one stable frame.
	const STABLE_FRAMES_REQUIRED: int = 3
	const MAX_WAIT_FRAMES: int = 60
	var frame_wait := 0
	var stable_frames := 0
	var last_window_size: Vector2i = DisplayServer.window_get_size()
	var last_viewport_size: Vector2i = viewport.size

	await get_tree().process_frame
	while frame_wait < MAX_WAIT_FRAMES:
		await get_tree().process_frame
		frame_wait += 1

		var current_window_size: Vector2i = DisplayServer.window_get_size()
		var current_viewport_size: Vector2i = viewport.size

		if current_window_size == last_window_size and current_viewport_size == last_viewport_size:
			stable_frames += 1
			# No resize needed: exit as soon as we see the original size stable.
			# Resize needed: wait for several stable frames so the OS is done.
			if (current_window_size == window_before and current_viewport_size == viewport_before) or stable_frames >= STABLE_FRAMES_REQUIRED:
				break
		else:
			stable_frames = 0

		last_window_size = current_window_size
		last_viewport_size = current_viewport_size

	print("[SystemManager.display] _apply_initial_window_size: window before=", window_before, " after=", DisplayServer.window_get_size(), " viewport before=", viewport_size_before, " direct=", viewport_before, " after=", viewport.size, " frames=", frame_wait)
	initial_window_size_settled.emit()

func _on_setting_changed(value: Variant, setting: SettingsVar):
	match setting.property_name:
		"windowed":
			windowed_toggle(value)
		"resolution":
			# ARRAY type stores the selected index (int), but set_resolution expects Vector2i
			var resolved_value = value
			if value is int and setting.options.size() > value:
				resolved_value = setting.options[value]
			set_resolution(resolved_value)
		"dual_screen_mode":
			# Trigger a display check when dual screen setting changes
			_check_for_dual_screen()
		"ui_scale":
			# Debounce: the settings slider emits on every tick of a drag, so
			# coalesce into a single scale recompute + UI refresh.
			_user_scale_factor = float(value)
			if _scale_debounce_timer:
				_scale_debounce_timer.stop()
				_scale_debounce_timer.start()

func _on_scale_debounced() -> void:
	"""Stable ui_scale change: recompute, invalidate the M3Units cache, notify."""
	var old_scale := _ui_scale
	_calculate_ui_scale()
	if not is_equal_approx(_ui_scale, old_scale):
		M3Units.invalidate_cache()
		_emit_ui_scale_changed()

func _load_user_scale_factor() -> void:
	var ui_scale_setting = settings_man.get_setting("ui_scale")
	if ui_scale_setting and ui_scale_setting.value is float:
		_user_scale_factor = ui_scale_setting.value
	# If the factor changes the scale vs. the initial _ready calculation, the
	# M3Units cache may already hold the unscaled value — invalidate and notify
	# so the UI refreshes with the persisted factor applied.
	var old_scale := _ui_scale
	_calculate_ui_scale()
	if not is_equal_approx(_ui_scale, old_scale):
		M3Units.invalidate_cache()
		_emit_ui_scale_changed()
	M3Debug.geom("display", "user scale factor applied: factor=%.2f ui_scale=%.3f m3units=%.3f" % [
		_user_scale_factor, _ui_scale, M3Units.get_scale()])

func _on_screens_swapped(_swapped: bool) -> void:
	# Defer resize notification so SubViewport size changes propagate to
	# controls (e.g. VirtualScrollGridContainer) before they recalculate.
	call_deferred("_emit_swap_resize_notification")

func _emit_swap_resize_notification() -> void:
	# In dual-screen SubViewport mode, emit the active MainViewport size, not the
	# root viewport size, so consumers that read the signal parameter see the
	# rectangle the grid actually occupies.
	var viewport = get_viewport()
	if UIManager and UIManager.dual_screen:
		var sub = UIManager.dual_screen.get_main_viewport()
		if sub:
			viewport = sub
	if viewport:
		_viewport_size = viewport.size
		viewport_size_changed.emit(_viewport_size)

func set_resolution(choice : Vector2i):
	#var chosen_res : Vector2i = settings_man.settings.resolutions[choice]
	# Window API instead of DisplayServer.window_set_size — see
	# restore_last_window_size() (X11 viewport-not-updating bug #105597).
	get_window().size = choice
	DisplayServer.window_set_position(Vector2i(Vector2(DisplayServer.screen_get_position()) + Vector2(DisplayServer.screen_get_size()) / 2.0 - Vector2(choice) / 2.0))

func _clamp_window_size(size: Vector2i) -> Vector2i:
	var screen := DisplayServer.window_get_current_screen()
	var screen_size := DisplayServer.screen_get_size(screen)
	var min_size := Vector2i(400, 300)
	return Vector2i(
		clampi(size.x, min_size.x, screen_size.x),
		clampi(size.y, min_size.y, screen_size.y)
	)

func restore_last_window_size() -> Vector2i:
	var last_size_setting = settings_man.get_setting("last_window_size")
	if last_size_setting and last_size_setting.value is Vector2i:
		var last_size: Vector2i = last_size_setting.value
		if last_size.x > 0 and last_size.y > 0:
			last_size = _clamp_window_size(last_size)
			# Use the Window API, not DisplayServer.window_set_size: on X11 the
			# raw DisplayServer call resizes the OS window but never fires
			# rect_changed_callback, so the viewport/render stays at the old
			# size (black bars) until a manual window interaction snaps it
			# (godotengine/godot#105597; fixed upstream for 4.8). Window.size
			# triggers the update on all platforms.
			get_window().size = last_size
			print("[SystemManager.display] Restored last window size: ", last_size)
			return last_size
	return Vector2i.ZERO

func save_last_window_size() -> void:
	# A manual work-area maximize runs in WINDOWED mode with the maximized rect
	# applied; that rect must never be persisted as the windowed size.
	if _manual_maximized:
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	# Use the OS window size directly; fall back to the root viewport size if
	# DisplayServer returns a zero/invalid value during shutdown.
	var size := DisplayServer.window_get_size()
	if size.x <= 0 or size.y <= 0:
		var viewport = get_viewport()
		if viewport:
			size = Vector2i(viewport.size)
	if size.x <= 0 or size.y <= 0:
		return
	var last_size_setting = settings_man.get_setting("last_window_size")
	if last_size_setting:
		settings_man.set_setting(size, last_size_setting)
		print("[SystemManager.display] Saved last window size: ", size)

func windowed_toggle(value : bool):
	if value:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		apply_window_chrome(true)
		var last_size := restore_last_window_size()
		if last_size == Vector2i.ZERO:
			var resolution_setting = settings_man.get_setting("resolution")
			var resolution_value = resolution_setting.value
			# ARRAY type may store either the selected index (int) or the actual Vector2i
			if resolution_value is int and resolution_setting.options.size() > resolution_value:
				resolution_value = resolution_setting.options[resolution_value]
			set_resolution(resolution_value)
		settings_man.enable_setting("resolution")
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		apply_window_chrome(false)
		settings_man.disable_setting("resolution")
		# Force immediate cascade so consumers (zoom, popups, grid) get the
		# new fullscreen resolution without waiting for the OS signal + debounce.
		_on_resize_debounced()

# ============================================================================
# Dual Screen Detection and Management
# ============================================================================

func _check_for_dual_screen() -> void:
	"""Check if a second display is available. Works on both desktop and Android."""

	var detected_second_screen: int = -1
	var detection_method = "none"

	# Try Android plugin first if available
	if _android_plugin != null:
		detected_second_screen = _get_second_screen_android()
		detection_method = "android_plugin"
		print("[SystemManager.display] Android plugin detection (hasMultipleDisplays): screen=" + str(detected_second_screen))

	# Fall back to Godot DisplayServer only on desktop platforms
	# On Android, DisplayServer may count virtual displays (casting, debug overlays)
	# which incorrectly reports >= 2 screens on single-screen devices
	if detected_second_screen == -1 and OS.get_name() != "Android":
		detected_second_screen = _get_second_screen_desktop()
		detection_method = "desktop"
		print("[SystemManager.display] Desktop fallback detection: screen=" + str(detected_second_screen))

	print("[SystemManager.display] Dual screen check: method=" + detection_method + ", available=" + str(detected_second_screen >= 0))

	# Update availability state
	var now_available = detected_second_screen >= 0
	if now_available != _dual_screen_available:
		_dual_screen_available = now_available
		dual_screen_availability_changed.emit(_dual_screen_available)

	# Check if dual screen mode is enabled in settings
	var dual_screen_setting = settings_man.get_setting("dual_screen_mode")
	if dual_screen_setting and not dual_screen_setting.value:
		# Dual screen mode is disabled in settings
		if _dual_screen_enabled:
			# We were in dual screen mode, but setting was turned off
			_dual_screen_enabled = false
			dual_screen_lost.emit()
			dual_screen_mode_changed.emit(false, -1)
		return

	# Update state based on detection
	if detected_second_screen >= 0:
		if not _dual_screen_enabled:
			# Second screen newly detected
			_dual_screen_enabled = true
			_second_screen_index = detected_second_screen
			dual_screen_detected.emit(_second_screen_index)
			dual_screen_mode_changed.emit(true, _second_screen_index)
		elif _second_screen_index != detected_second_screen:
			# Second screen changed
			_second_screen_index = detected_second_screen
			dual_screen_mode_changed.emit(true, _second_screen_index)
	else:
		if _dual_screen_enabled:
			# Second screen lost
			_dual_screen_enabled = false
			dual_screen_lost.emit()
			dual_screen_mode_changed.emit(false, -1)

func _get_second_screen_desktop() -> int:
	"""Get second screen index using Godot DisplayServer (desktop platforms)."""
	var screen_count = DisplayServer.get_screen_count()

	if screen_count < 2:
		return -1

	# Get current window's screen
	var current_window_screen = DisplayServer.window_get_current_screen()

	# Find a different screen
	for i in range(screen_count):
		if i != current_window_screen:
			return i

	return -1

func _get_second_screen_android() -> int:
	"""Get second screen index using Android plugin.
	Uses hasMultipleDisplays() which filters out virtual displays (debug, casting, etc.)
	to avoid false positives on single-screen devices."""
	if _android_plugin == null:
		return -1

	# Get debug info first so we can see what's happening in Godot console
	var debug_info = _android_plugin.getDisplayDebugInfo()
	if debug_info.has("info"):
		print("[SystemManager.display] Android display debug:\n" + str(debug_info["info"]))

	# Use hasMultipleDisplays() instead of getDisplayCount() because
	# getDisplayCount() counts virtual displays (USB debug overlay, screen casting,
	# accessibility services) which incorrectly reports >= 2 on single-screen devices.
	# hasMultipleDisplays() filters by resolution, state, and name.
	var has_multiple = _android_plugin.hasMultipleDisplays()

	if has_multiple:
		# Return display index 1 (second display)
		# On Android, display 0 is usually internal, display 1 is external
		return 1

	return -1

func is_dual_screen_enabled() -> bool:
	"""Returns true if dual screen mode is active."""
	return _dual_screen_enabled

func is_dual_screen_available() -> bool:
	"""Returns true if a second display is available (hardware detected)."""
	return _dual_screen_available

func get_second_screen_index() -> int:
	"""Returns the index of the second screen, or -1 if not available."""
	return _second_screen_index

func get_second_screen_rect() -> Rect2i:
	"""Get the rectangle of the second screen in global coordinates."""
	if not _dual_screen_enabled or _second_screen_index < 0:
		return Rect2i()

	# On Android, use the plugin to get display info since DisplayServer doesn't see all displays
	if OS.get_name() == "Android" and _android_plugin != null:
		var display_info = _android_plugin.getSecondDisplayInfo()
		if display_info.size() > 0:
			var width = display_info.get("width", 1920)
			var height = display_info.get("height", 1080)
			return Rect2i(Vector2i(0, 0), Vector2i(width, height))

	# Fallback to DisplayServer for desktop
	var position = DisplayServer.screen_get_position(_second_screen_index)
	var size = DisplayServer.screen_get_size(_second_screen_index)

	return Rect2i(position, size)

func force_check_displays() -> void:
	"""Manually trigger a display check. Useful for testing."""
	_check_for_dual_screen()

func get_android_plugin():
	"""Returns the Android plugin instance for other managers to use."""
	return _android_plugin

# ============================================================================
# Window chrome (borderless frame + custom title bar)
# ============================================================================

func supports_window_chrome() -> bool:
	## Custom title bar only replaces the frame on the platforms we export to
	## (Windows + Linux). Android has no decorations; macOS is not planned.
	if SystemManager and SystemManager.platform:
		return SystemManager.platform.is_windows() or SystemManager.platform.is_linux()
	return false

func apply_window_chrome(windowed: bool) -> void:
	## Apply/notify the borderless chrome for the given window mode.
	## Only the windowed side touches the flag: borderless is ignored for
	## fullscreen windows anyway, and clearing it mid-fullscreen would churn
	## the frame style for no benefit (windowed_toggle re-applies on return).
	if not supports_window_chrome():
		return
	var window := get_window()
	if window == null:
		return
	if windowed:
		window.min_size = MIN_WINDOW_SIZE
		window.borderless = true
	var active := is_window_chrome_active()
	print("[SystemManager.display] window chrome: windowed=", windowed, " borderless=", window.borderless, " active=", active)
	window_chrome_changed.emit(active)

func is_window_chrome_active() -> bool:
	## True while the native frame is stripped and the custom title bar strip
	## should be visible (windowed or maximized; never fullscreen).
	if not supports_window_chrome():
		return false
	var mode := DisplayServer.window_get_mode()
	if mode != DisplayServer.WINDOW_MODE_WINDOWED and mode != DisplayServer.WINDOW_MODE_MAXIMIZED:
		return false
	var window := get_window()
	return window != null and window.borderless

func is_window_maximized() -> bool:
	if _manual_maximized:
		return true
	var window := get_window()
	return window != null and window.mode == Window.MODE_MAXIMIZED

func toggle_window_maximize() -> void:
	if is_window_maximized():
		restore_window_maximize()
	else:
		maximize_window()

func maximize_window() -> void:
	if not is_window_chrome_active():
		return
	var window := get_window()
	if window == null or is_window_maximized():
		return
	_pre_maximize_rect = Rect2i(window.position, window.size)
	window.mode = Window.MODE_MAXIMIZED
	# Borderless maximize is known to cover the taskbar on some platforms
	# (godotengine/godot#104663); verify against the work area and fall back
	# to sizing there manually if the WM got it wrong.
	_schedule_maximize_work_area_check()

func restore_window_maximize() -> void:
	var window := get_window()
	if window == null:
		return
	_max_verify_token += 1  # cancel a pending work-area verification
	if _manual_maximized:
		_manual_maximized = false
		if _pre_maximize_rect.size.x > 0 and _pre_maximize_rect.size.y > 0:
			# The window manager never saw this maximize; restore it ourselves.
			window.size = _pre_maximize_rect.size
			window.position = _pre_maximize_rect.position
	else:
		# Native maximize: the WM remembers and restores the pre-maximize rect.
		window.mode = Window.MODE_WINDOWED

func minimize_window() -> void:
	if not is_window_chrome_active():
		return
	var window := get_window()
	if window:
		window.mode = Window.MODE_MINIMIZED

func begin_title_drag() -> void:
	## Start an OS-level window move from the custom title bar. A manual
	## work-area maximize is restored first (the WM doesn't know that state,
	## so a native drag wouldn't shrink the window), keeping the grabbed point
	## of the title bar under the cursor across the restore.
	var window := get_window()
	if window == null:
		return
	if _manual_maximized:
		var mouse := Vector2(DisplayServer.mouse_get_position())
		var rel := mouse - Vector2(window.position)
		restore_window_maximize()
		var new_rel := Vector2(
			clampf(rel.x, 0.0, maxf(0.0, window.size.x - 1.0)),
			clampf(rel.y, 0.0, maxf(0.0, window.size.y - 1.0)))
		window.position = Vector2i(mouse - new_rel)
	window.start_drag()

func _schedule_maximize_work_area_check() -> void:
	_max_verify_token += 1
	_verify_maximize_work_area(_max_verify_token)

func _verify_maximize_work_area(token: int) -> void:
	# Give the window manager a couple of frames to settle the maximized rect.
	for i in 2:
		var tree := get_tree()
		if tree == null:
			return
		await tree.process_frame
	if token != _max_verify_token:
		return
	var window := get_window()
	if window == null or window.mode != Window.MODE_MAXIMIZED:
		return
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return
	# Borderless windows have no frame, so position/size is the outer rect.
	if usable.encloses(Rect2i(window.position, window.size)):
		return  # Fits the work area; the taskbar was respected.
	print("[SystemManager.display] maximized rect ", Rect2i(window.position, window.size),
		" exceeds work area ", usable, "; falling back to manual maximize")
	# Overlap: size to the work area manually. Mode must go back to WINDOWED
	# first, or the window manager keeps owning the rect.
	window.mode = Window.MODE_WINDOWED
	window.size = usable.size
	window.position = usable.position
	_manual_max_rect = Rect2i(window.position, window.size)
	_manual_maximized = true

func _on_window_geometry_changed() -> void:
	# External changes (WM tiling shortcuts, fullscreen, snapping) invalidate
	# the manual maximize state; otherwise we'd skip size persistence forever
	# and the title bar icon would be wrong.
	if not _manual_maximized:
		return
	var window := get_window()
	if window == null or window.mode != Window.MODE_WINDOWED:
		_manual_maximized = false
		return
	var rect := Rect2i(window.position, window.size)
	var expected := _manual_max_rect
	# Tolerate a pixel of WM adjustment; anything else is a real change.
	if absi(rect.position.x - expected.position.x) > 2 or absi(rect.position.y - expected.position.y) > 2 \
			or absi(rect.size.x - expected.size.x) > 2 or absi(rect.size.y - expected.size.y) > 2:
		_manual_maximized = false
