@icon("res://Icons/ArrayMesh.svg")
#display_sub_manager.gd
extends Manager
class_name DisplaySubManager

## Single source of truth for viewport size and UI scale.
## Emits debounced viewport_size_changed signals so consumers don't redo layout
## math on every pixel of a window resize.

signal viewport_size_changed(new_size: Vector2)
signal ui_scale_changed(new_scale: float)
signal dual_screen_detected(second_screen_index: int)
signal dual_screen_lost()
signal dual_screen_mode_changed(enabled: bool, second_screen_index: int)
signal dual_screen_availability_changed(available: bool)
signal initial_window_size_settled()

const RESIZE_DEBOUNCE_SECONDS := 0.25
const SCALE_DEBOUNCE_SECONDS := 0.2
const BASE_HEIGHT := 1080.0
const BASE_DPI := 160.0
const DEFAULT_DPI := 96.0
const MIN_UI_SCALE := 1.0
const MAX_UI_SCALE := 4.0

@onready var settings_man = $"/root/DataManager"

var _viewport_size: Vector2 = Vector2.ZERO
var _ui_scale: float = -1.0
var _user_scale_factor: float = 1.0
var _current_screen: int = -1
var _resize_debounce_timer: Timer = null
var _scale_debounce_timer: Timer = null

# Dual screen detection state
var _dual_screen_enabled: bool = false
var _dual_screen_available: bool = false
var _second_screen_index: int = -1
var _android_plugin = null

# UI scale state for SubViewport dual screen mode
var _subviewport_dual_screen_active: bool = false
var _saved_ui_scale: float = 1.0
var _last_main_viewport_size: Vector2i = Vector2i.ZERO
var _last_second_viewport_size: Vector2i = Vector2i.ZERO
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
	ui_scale_changed.emit(_ui_scale)

	# Initialize display detection
	_initialize_display_detection()

	# Apply the saved windowed size once the OS window is ready.
	call_deferred("_apply_initial_window_size")

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
	"""Raw resize event: restart the debounce timer."""
	if _resize_debounce_timer:
		_resize_debounce_timer.stop()
		_resize_debounce_timer.start()

func _on_resize_debounced() -> void:
	"""Stable resize event: update cached viewport size and notify consumers."""
	var viewport = get_viewport()
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
			ui_scale_changed.emit(_ui_scale)

	viewport_size_changed.emit(_viewport_size)

	# Continuously save the windowed size so we don't rely solely on close-time
	# reads, which can return stale/zero values during shutdown.
	save_last_window_size()

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

func get_screen_size() -> Vector2i:
	var screen := DisplayServer.window_get_current_screen()
	return DisplayServer.screen_get_size(screen)

func is_narrow_viewport(breakpoint_dp := 850.0) -> bool:
	return get_viewport_size().x < M3Units.dp(breakpoint_dp)

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
	var resolution_scale := pow(screen_size.y / BASE_HEIGHT, 0.85)

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
	if windowed_setting and not windowed_setting.value:
		# Fullscreen (windowed = false): restore exclusive fullscreen.
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		print("[SystemManager.display] Restored fullscreen mode")
	elif windowed_setting and windowed_setting.value:
		# Windowed: restore last size if available; otherwise let the existing
		# signal/resize path handle it.
		var last_size := restore_last_window_size()
		if last_size == Vector2i.ZERO:
			print("[SystemManager.display] No saved window size, using resolution preset")
		else:
			print("[SystemManager.display] Restored saved window size: ", last_size)
	else:
		# Setting missing; leave default window mode alone.
		pass

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
		ui_scale_changed.emit(_ui_scale)

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
		ui_scale_changed.emit(_ui_scale)

func _connect_subviewport_signals() -> void:
	var ds = get_node_or_null("/root/Main/DualScreenSetup")
	var main_viewport = ds.get_node_or_null("MainViewportContainer/MainViewport") if ds else null
	var second_viewport = ds.get_node_or_null("SecondViewportContainer/SecondViewport") if ds else null

	if main_viewport and not main_viewport.size_changed.is_connected(_on_subviewport_size_changed):
		main_viewport.size_changed.connect(_on_subviewport_size_changed)
	if second_viewport and not second_viewport.size_changed.is_connected(_on_subviewport_size_changed):
		second_viewport.size_changed.connect(_on_subviewport_size_changed)

func _disconnect_subviewport_signals() -> void:
	var ds = get_node_or_null("/root/Main/DualScreenSetup")
	var main_viewport = ds.get_node_or_null("MainViewportContainer/MainViewport") if ds else null
	var second_viewport = ds.get_node_or_null("SecondViewportContainer/SecondViewport") if ds else null

	if main_viewport and main_viewport.size_changed.is_connected(_on_subviewport_size_changed):
		main_viewport.size_changed.disconnect(_on_subviewport_size_changed)
	if second_viewport and second_viewport.size_changed.is_connected(_on_subviewport_size_changed):
		second_viewport.size_changed.disconnect(_on_subviewport_size_changed)

func _on_subviewport_size_changed() -> void:
	_apply_subviewport_scale(_saved_ui_scale)

func _apply_subviewport_scale(scale: float) -> void:
	if scale <= 0:
		scale = 1.0

	var ds = get_node_or_null("/root/Main/DualScreenSetup")
	var main_viewport = ds.get_node_or_null("MainViewportContainer/MainViewport") if ds else null
	var second_viewport = ds.get_node_or_null("SecondViewportContainer/SecondViewport") if ds else null

	if main_viewport:
		var original_size = main_viewport.size
		main_viewport.size_2d_override = Vector2i(int(original_size.x / scale), int(original_size.y / scale))
		main_viewport.size_2d_override_stretch = true
		_last_main_viewport_size = original_size

	if second_viewport:
		var original_size = second_viewport.size
		second_viewport.size_2d_override = Vector2i(int(original_size.x / scale), int(original_size.y / scale))
		second_viewport.size_2d_override_stretch = true
		_last_second_viewport_size = original_size

func _clear_subviewport_scale() -> void:
	var ds = get_node_or_null("/root/Main/DualScreenSetup")
	var main_viewport = ds.get_node_or_null("MainViewportContainer/MainViewport") if ds else null
	var second_viewport = ds.get_node_or_null("SecondViewportContainer/SecondViewport") if ds else null

	if main_viewport:
		main_viewport.size_2d_override = Vector2i.ZERO
		main_viewport.size_2d_override_stretch = false

	if second_viewport:
		second_viewport.size_2d_override = Vector2i.ZERO
		second_viewport.size_2d_override_stretch = false

	_last_main_viewport_size = Vector2i.ZERO
	_last_second_viewport_size = Vector2i.ZERO

func _on_screens_swapped(_swapped: bool) -> void:
	if _subviewport_dual_screen_active:
		# Re-apply scale after screen swap since viewport sizes change
		_apply_subviewport_scale(_saved_ui_scale)
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

func enter_subviewport_dual_screen_mode() -> void:
	if _subviewport_dual_screen_active:
		return
	_subviewport_dual_screen_active = true
	_connect_subviewport_signals()
	_apply_subviewport_scale(_saved_ui_scale)

func exit_subviewport_dual_screen_mode() -> void:
	if not _subviewport_dual_screen_active:
		return
	_subviewport_dual_screen_active = false
	_disconnect_subviewport_signals()
	_clear_subviewport_scale()

func set_resolution(choice : Vector2i):
	#var chosen_res : Vector2i = settings_man.settings.resolutions[choice]
	DisplayServer.window_set_size(choice)
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
			DisplayServer.window_set_size(last_size)
			print("[SystemManager.display] Restored last window size: ", last_size)
			return last_size
	return Vector2i.ZERO

func save_last_window_size() -> void:
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
