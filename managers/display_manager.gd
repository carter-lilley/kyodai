@icon("res://Icons/ArrayMesh.svg")
#display_manager.gd
extends Manager

signal viewport_size_changed(new_size: Vector2)
signal dual_screen_detected(second_screen_index: int)
signal dual_screen_lost()
signal dual_screen_mode_changed(enabled: bool, second_screen_index: int)
signal dual_screen_availability_changed(available: bool)

@onready var settings_man = $"../SettingsManager"

var _viewport_size: Vector2 = Vector2.ZERO

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
	
	# Connect to viewport size changes
	var viewport = get_viewport()
	if viewport:
		viewport.size_changed.connect(_on_viewport_size_changed)
		_viewport_size = viewport.size
	
	# Initialize display detection
	_initialize_display_detection()
	
	# UI scale setting disabled — now using DP-based scaling via M3Units
	#_apply_ui_scale()
	
	# Try to connect to AynThor screen swap signal (may not exist yet)
	call_deferred("_connect_ayn_thor_signals")

func _connect_ayn_thor_signals() -> void:
	_ayn_thor_manager = get_node_or_null("/root/Main/AynThorManager")
	if _ayn_thor_manager and _ayn_thor_manager.has_signal("screens_swapped"):
		_ayn_thor_manager.screens_swapped.connect(_on_screens_swapped)

func _process(_delta: float) -> void:
	if _subviewport_dual_screen_active:
		_check_subviewport_size_changes()

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
	var viewport = get_viewport()
	if viewport:
		_viewport_size = viewport.size
		viewport_size_changed.emit(_viewport_size)

func get_viewport_size() -> Vector2:
	if _viewport_size == Vector2.ZERO:
		var viewport = get_viewport()
		if viewport:
			_viewport_size = viewport.size
	return _viewport_size

func _on_setting_changed(value: Variant, setting: SettingsVar):
	match setting.property_name:
		"windowed":
			windowed_toggle(value)
		"resolution":
			set_resolution(value)
		"dual_screen_mode":
			# Trigger a display check when dual screen setting changes
			_check_for_dual_screen()

func _check_subviewport_size_changes() -> void:
	var ds = get_node_or_null("/root/Main/DualScreenSetup")
	var main_viewport = ds.get_node_or_null("MainViewportContainer/MainViewport") if ds else null
	var second_viewport = ds.get_node_or_null("SecondViewportContainer/SecondViewport") if ds else null
	
	var main_changed = false
	var second_changed = false
	
	if main_viewport and main_viewport.size != _last_main_viewport_size:
		_last_main_viewport_size = main_viewport.size
		main_changed = true
	
	if second_viewport and second_viewport.size != _last_second_viewport_size:
		_last_second_viewport_size = second_viewport.size
		second_changed = true
	
	if main_changed or second_changed:
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

func enter_subviewport_dual_screen_mode() -> void:
	if _subviewport_dual_screen_active:
		return
	_subviewport_dual_screen_active = true
	#_apply_ui_scale()

func exit_subviewport_dual_screen_mode() -> void:
	if not _subviewport_dual_screen_active:
		return
	_subviewport_dual_screen_active = false
	_clear_subviewport_scale()
	#_apply_ui_scale()

func set_resolution(choice : Vector2i):
	#var chosen_res : Vector2i = settings_man.settings.resolutions[choice]
	DisplayServer.window_set_size(choice)
	DisplayServer.window_set_position(Vector2i(Vector2(DisplayServer.screen_get_position()) + Vector2(DisplayServer.screen_get_size()) / 2.0 - Vector2(choice) / 2.0))

func windowed_toggle(value : bool):
	if value:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		set_resolution(settings_man.get_setting("resolution").value)
		settings_man.enable_setting("resolution")
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		settings_man.disable_setting("resolution")

# ============================================================================
# Dual Screen Detection and Management
# ============================================================================

func _check_for_dual_screen() -> void:
	"""Check if a second display is available. Works on both desktop and Android."""
	
	var detected_second_screen: int = -1
	
	# Try Android plugin first if available
	if _android_plugin != null:
		detected_second_screen = _get_second_screen_android()
	
	# Fall back to Godot DisplayServer if no Android plugin or plugin returned -1
	if detected_second_screen == -1:
		detected_second_screen = _get_second_screen_desktop()
	
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
	"""Get second screen index using Android plugin."""
	if _android_plugin == null:
		return -1
	
	# Just call the method directly - has_method() doesn't work reliably with Android plugins
	# even when the methods exist in the compiled code
	var display_count = _android_plugin.getDisplayCount()
	
	if display_count >= 2:
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
