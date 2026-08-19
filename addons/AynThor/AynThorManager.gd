extends Node

@export_group("Screens")
@export var main_screen: Screen
@export var second_screen: Screen

@export var target_fps: int = 0:
	set(value):
		target_fps = value
		if renderer:
			renderer.set_target_fps(value)

@export var rotation_degrees: ScreenRotation = ScreenRotation.DEG_180:
	set(value):
		rotation_degrees = value
		if renderer:
			renderer.set_rotation_degrees(value)
			
var _main_viewport: SubViewport
var _second_viewport: SubViewport
var _main_container: SubViewportContainer
var _second_container: SubViewportContainer

var ayn_thor_plugin = null
var renderer = null

## True while the Android Presentation is shown on the second display.
var _screen_active: bool = false

## Shows the Android Presentation on the second display (no-op if already up).
func acquire_second_screen() -> void:
	if not ayn_thor_plugin:
		return
	if _screen_active:
		return
	if ayn_thor_plugin.has_method("isScreenActive") and ayn_thor_plugin.isScreenActive():
		_screen_active = true
		return
	ayn_thor_plugin.init_screen()
	_screen_active = true

## Dismisses the Android Presentation so the second display is released
## instead of sitting on a blank viewport when dual-screen mode is off.
func release_second_screen() -> void:
	if not ayn_thor_plugin:
		return
	_screen_active = false
	ayn_thor_plugin.destroy_screen()

var is_swapped: bool = false
var original_main_size: Vector2i
var original_second_size: Vector2i
var is_android: bool = false
var second_size_confirmed: bool = false
var last_touch_positions: Dictionary = {}
var touch_down_positions: Dictionary = {}

# Finger jitter on the touchscreen produces tiny MOVE events between down/up;
# forwarded as mouse drags they turn taps into ScrollContainer scrolls and
# break clicks. Don't forward motion until it leaves this deadzone (physical px).
const TOUCH_MOVE_DEADZONE_PX: float = 12.0

signal screens_swapped(swapped: bool)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("swap_screens"):
		swap_screens()
		
func set_screen_resources(main: Screen, second: Screen) -> void:
	main_screen = main
	second_screen = second
	refresh_screens()

func refresh_screens() -> void:
	if main_screen:
		main_screen.setup(self)
		if main_screen.viewport: _main_viewport = main_screen.viewport
		if main_screen.container: _main_container = main_screen.container

	if second_screen:
		second_screen.setup(self)
		if second_screen.container: _second_container = second_screen.container
		if second_screen.viewport: _second_viewport = second_screen.viewport

	if _main_viewport:
		_main_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _second_viewport:
		_second_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	_apply_screen_geometry()

func _apply_screen_geometry() -> void:
	"""Apply container/viewport sizes and positions for the current swap state.
	Must stay swap-aware: refresh_screens() runs on every DualScreenSetup
	rebuild and previously reset geometry to the unswapped layout even while
	is_swapped was true, desyncing rendering from touch coordinate mapping."""
	if original_main_size.x <= 0 or original_second_size.x <= 0:
		return
	if is_swapped:
		if _main_container:
			_main_container.position = Vector2(-10000, 0)
			_main_container.size = original_second_size
		if _second_container:
			_second_container.position = Vector2.ZERO
			_second_container.size = original_main_size
		if _second_viewport:
			_second_viewport.size = original_main_size
		if _main_viewport:
			_main_viewport.size = original_second_size
	else:
		if _main_container:
			_main_container.position = Vector2.ZERO
			_main_container.size = original_main_size
		if _second_container:
			_second_container.position = Vector2(-10000, 0)
			_second_container.size = original_second_size
		if _main_viewport:
			_main_viewport.size = original_main_size
		if _second_viewport:
			_second_viewport.size = original_second_size

func _ready():
	is_android = OS.get_name() == "Android"
	
	if Engine.has_singleton("AynThor"):
		refresh_screens()
		
		ayn_thor_plugin = Engine.get_singleton("AynThor")
		ayn_thor_plugin.connect("second_screen_connected", _on_screen_connected)
		ayn_thor_plugin.connect("second_screen_input", _on_second_screen_input)
		# Only show the second-screen presentation at boot when dual-screen mode
		# is enabled; otherwise it sits on the second display as a blank viewport.
		var ds_enabled := false
		if DataManager and DataManager.is_settings_loaded():
			var ds_setting = DataManager.get_setting("dual_screen_mode")
			if ds_setting and ds_setting.value is bool:
				ds_enabled = ds_setting.value
		if ds_enabled:
			acquire_second_screen()
	
	if ClassDB.class_exists("AynThorRenderer"):
		renderer = get_node_or_null("AynThorRenderer")
		if not renderer:
			renderer = ClassDB.instantiate("AynThorRenderer")
			add_child(renderer)
			renderer.name = "AynThorRenderer"
		renderer.set_target_fps(target_fps)
		renderer.set_rotation_degrees(rotation_degrees)
	
	original_main_size = get_viewport().size
	if original_main_size.x == 0:
		original_main_size = Vector2i(1920, 1080)
	
	original_second_size = Vector2i(1080, 1240)
	refresh_screens()


var skip_frames: int = 0

func _process(_delta):
	if skip_frames > 0:
		skip_frames -= 1
		return

	# Don't blit while the presentation is released (dual-screen mode off).
	if not _screen_active:
		return

	if not renderer or not renderer.is_window_available():
		return
	
	if not second_size_confirmed:
		_try_update_second_screen_size()

	var texture_to_draw = _main_viewport if is_swapped else _second_viewport
	if texture_to_draw:
		renderer.draw_viewport_texture(texture_to_draw.get_texture().get_rid())

func _try_update_second_screen_size():
	if renderer and renderer.is_window_available():
		var size = renderer.get_second_screen_size()
		if size != Vector2i.ZERO:
			original_second_size = size
			second_size_confirmed = true
			if not is_swapped and _second_viewport:
				_second_viewport.size = original_second_size

func swap_screens():
	is_swapped = !is_swapped

	if renderer and renderer.is_window_available():
		var s = renderer.get_second_screen_size()
		if s != Vector2i.ZERO:
			original_second_size = s

	_apply_screen_geometry()

	screens_swapped.emit(is_swapped)
	skip_frames = 2
	
	# Force hero viewport update after swap since UPDATE_ONCE may have stale texture
	force_hero_viewport_update()

func force_hero_viewport_update():
	"""Force the hero viewport (SecondViewport) to update.
	Since we use UPDATE_ALWAYS, this just ensures rendering is active."""
	# With UPDATE_ALWAYS mode, the viewport updates every frame automatically
	# This function is kept for API compatibility but doesn't need to do anything
	pass

func _on_second_screen_input(action: int, x: float, y: float, pid: int):
	var current_pos = Vector2(x, y)
	var target_vp = _main_viewport if is_swapped else _second_viewport
	
	if not target_vp:
		print("[AynThor] No target viewport!")
		return
	
	# Get the actual screen size from renderer (physical second screen resolution)
	var screen_size = original_second_size
	if renderer and renderer.is_window_available():
		var s = renderer.get_second_screen_size()
		if s != Vector2i.ZERO:
			screen_size = s
	
	# Scale coordinates from screen space to viewport space
	# This ensures touches map correctly regardless of which viewport is being displayed
	var viewport_size = target_vp.size
	var scale_x = float(viewport_size.x) / float(screen_size.x)
	var scale_y = float(viewport_size.y) / float(screen_size.y)
	var scaled_pos = Vector2(current_pos.x * scale_x, current_pos.y * scale_y)
	
	# Ensure local input handling is enabled (may get reset by engine under certain conditions)
	if not target_vp.handle_input_locally:
		target_vp.handle_input_locally = true
	
	if action == 0 or action == 5:
		last_touch_positions[pid] = current_pos
		touch_down_positions[pid] = current_pos
		var mouse_event = InputEventMouseButton.new()
		mouse_event.button_index = MOUSE_BUTTON_LEFT
		mouse_event.pressed = true
		mouse_event.position = scaled_pos
		mouse_event.global_position = scaled_pos
		mouse_event.device = InputEvent.DEVICE_ID_EMULATION
		target_vp.push_input(mouse_event)

	elif action == 1 or action == 6:
		last_touch_positions.erase(pid)
		touch_down_positions.erase(pid)
		var mouse_event = InputEventMouseButton.new()
		mouse_event.pressed = false
		mouse_event.button_index = MOUSE_BUTTON_LEFT
		mouse_event.position = scaled_pos
		mouse_event.global_position = scaled_pos
		mouse_event.device = InputEvent.DEVICE_ID_EMULATION
		target_vp.push_input(mouse_event)

	elif action == 2:
		# Suppress sub-deadzone jitter so taps aren't reinterpreted as drags.
		var down_pos = touch_down_positions.get(pid, current_pos)
		if current_pos.distance_to(down_pos) < TOUCH_MOVE_DEADZONE_PX:
			return
		var prev_pos = last_touch_positions.get(pid, current_pos)
		var scaled_prev = Vector2(prev_pos.x * scale_x, prev_pos.y * scale_y)
		var mouse_event = InputEventMouseMotion.new()
		mouse_event.position = scaled_pos
		mouse_event.global_position = scaled_pos
		mouse_event.relative = scaled_pos - scaled_prev
		mouse_event.button_mask = MOUSE_BUTTON_MASK_LEFT
		mouse_event.device = InputEvent.DEVICE_ID_EMULATION
		target_vp.push_input(mouse_event)
		last_touch_positions[pid] = current_pos

func _on_screen_connected():
	_try_update_second_screen_size()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		release_second_screen()

enum ScreenRotation {
	DEG_0 = 0,
	DEG_90 = 90,
	DEG_180 = 180,
	DEG_270 = 270
}
