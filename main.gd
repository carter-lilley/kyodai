extends Control

@onready var layout_container: BoxContainer = $VBoxContainer
@onready var tab_container: TabContainer = $VBoxContainer/TabContainer
@onready var bottom_bar: BottomBar = $VBoxContainer/BottomBar

# Auto-repeat navigation
var _held_dir: String = ""
var _delay_timer: Timer
var _repeat_timer: Timer
const INITIAL_DELAY: float = 0.5
const REPEAT_DELAY: float = 0.1
var _last_press: int = 0

# Zoom state tracking for analog triggers
var _zoom_in_pressed: bool = false
var _zoom_out_pressed: bool = false

func _ready():
	_setup_repeat()
	
	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")
	
	# Initialize UIManager with the tab container, layout container, and bottom bar
	UIManager.initialize(tab_container, layout_container, bottom_bar)
	
	# Connect bottom bar signals
	if bottom_bar:
		print("[Main] BottomBar found, connecting signals")
		bottom_bar.nav_button_pressed.connect(_on_nav_button_pressed)
		bottom_bar.zoom_changed.connect(_on_zoom_changed)
		bottom_bar.zoom_changed_finished.connect(_on_zoom_changed_finished)
		print("[Main] Zoom signal connected: ", bottom_bar.zoom_changed.is_connected(_on_zoom_changed))
	else:
		push_error("[Main] BottomBar not found!")
	
	# Connect to UIManager for tab changes
	UIManager.tab_changed.connect(_on_tab_changed)
	
	# Set initial view
	_update_bottom_bar_for_view("Home")
	
	# Load and apply saved zoom setting (wait for views to be ready)
	await get_tree().process_frame
	_load_and_apply_saved_zoom()

func _on_nav_button_pressed(view_name: String):
	UIManager.switch_to_tab(view_name)

func _on_tab_changed(view_name: String):
	_update_bottom_bar_for_view(view_name)
	
	# Apply saved zoom to newly visible view (deferred to allow layout)
	if view_name in ["Home", "Library"]:
		_apply_zoom_to_view_deferred(view_name)

func _apply_zoom_to_view_deferred(view_name: String) -> void:
	"""Apply saved zoom to the specified view when it becomes visible."""
	var view = UIManager.get_view(view_name)
	if not view:
		return
	
	var grid = _get_view_grid(view)
	if not grid or not SettingsManager:
		return
	
	var zoom_setting = SettingsManager.get_setting("library_card_zoom")
	if not zoom_setting:
		return
	
	# Keep checking until grid has valid dimensions
	if grid.size.x <= 0 or grid.size.y <= 0:
		print("[Main] Grid for %s not ready yet (size: %s), deferring..." % [view_name, str(grid.size)])
		await get_tree().process_frame
		_apply_zoom_to_view_deferred(view_name)
		return
	
	print("[Main] Applying saved zoom to %s: %s (grid size: %s)" % [view_name, zoom_setting.value, str(grid.size)])
	grid.target_card_width_ratio = zoom_setting.value

func _update_bottom_bar_for_view(view_name: String):
	bottom_bar.set_current_view(view_name)
	
	# Update zoom slider to match current view's grid
	var view = UIManager.get_view(view_name)
	if view and view_name in ["Home", "Library"]:
		var games_grid = _get_view_grid(view)
		if games_grid:
			bottom_bar.set_zoom_value(games_grid.target_card_width_ratio)

func _on_zoom_changed(value: float):
	"""Called continuously while dragging - updates both views for parity."""
	print("[Main] Zoom changed to: ", value)
	# Apply zoom to BOTH Home and Library grids for consistent zoom across views
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var games_grid = _get_view_grid(view)
			if games_grid:
				print("[Main] Setting target_card_width_ratio to: ", value, " for view: ", view_name)
				games_grid.target_card_width_ratio = value

func _on_zoom_changed_finished(value: float):
	"""Called when drag ends - saves the setting."""
	print("[Main] Zoom drag finished at: ", value)
	# Save zoom to settings (only when drag ends)
	if SettingsManager:
		var zoom_setting = SettingsManager.get_setting("library_card_zoom")
		if zoom_setting:
			SettingsManager.set_setting(value, zoom_setting)
			SettingsManager.save_settings()
			print("[Main] Saved zoom setting: ", value)

func _get_view_grid(view: View) -> VirtualScrollGridContainer:
	# Safely get the games grid from a view
	# After adding MarginContainer wrapper, grid is at MarginContainer/VirtualScrollGridContainer
	if view.has_node("MarginContainer/VirtualScrollGridContainer"):
		return view.get_node("MarginContainer/VirtualScrollGridContainer")
	# Fallback to old path for backward compatibility
	elif view.has_node("VirtualScrollGridContainer"):
		return view.get_node("VirtualScrollGridContainer")
	return null

func _load_and_apply_saved_zoom() -> void:
	"""Load saved zoom from settings and apply to both grids for parity."""
	print("[Main] _load_and_apply_saved_zoom() called")
	
	if not SettingsManager:
		print("[Main] ERROR: SettingsManager is null!")
		return
	
	var zoom_setting = SettingsManager.get_setting("library_card_zoom")
	if not zoom_setting:
		print("[Main] No saved zoom setting found, using default")
		return
	
	var saved_zoom = zoom_setting.value
	print("[Main] Loading saved zoom: ", saved_zoom)
	
	# Apply to BOTH Home and Library views for consistent zoom across views
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var grid = _get_view_grid(view)
			if grid:
				print("[Main] Applying zoom to %s grid: %s" % [view_name, saved_zoom])
				grid.target_card_width_ratio = saved_zoom
	
	# Set bottom bar slider to saved value
	if bottom_bar:
		print("[Main] Setting bottom bar zoom slider to: ", saved_zoom)
		bottom_bar.set_zoom_value(saved_zoom)

func set_status_text(text: String):
	if is_instance_valid(bottom_bar):
		bottom_bar.set_status_text(text)

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home button in the bottom bar."""
	if not is_instance_valid(bottom_bar):
		return
	
	# Search recursively for HomeButton since it's in dynamic containers
	var home_button = _find_node_by_name(bottom_bar, "HomeButton")
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		home_button.grab_focus()

func _find_node_by_name(node: Node, target_name: String) -> Node:
	"""Recursively find a node by name."""
	if node.name == target_name:
		return node
	
	for child in node.get_children():
		var result = _find_node_by_name(child, target_name)
		if result:
			return result
	
	return null

func _setup_repeat():
	_delay_timer = Timer.new()
	_delay_timer.wait_time = INITIAL_DELAY
	_delay_timer.one_shot = true
	_delay_timer.timeout.connect(_on_delay_timeout)
	add_child(_delay_timer)
	
	_repeat_timer = Timer.new()
	_repeat_timer.wait_time = REPEAT_DELAY
	_repeat_timer.timeout.connect(_on_repeat)
	add_child(_repeat_timer)

func _input(event: InputEvent):
	var dirs = ["ui_left", "ui_right", "ui_up", "ui_down"]
	
	for dir in dirs:
		if event.is_action_pressed(dir):
			if event is InputEventKey:
				var now = Time.get_ticks_msec()
				if now - _last_press < 80:
					return
				_last_press = now
			
			_held_dir = dir
			_delay_timer.start()
			return
		
		if event.is_action_released(dir) and _held_dir == dir:
			# Ignore synthetic release events from our repeat system
			if event is InputEventAction:
				return
			_held_dir = ""
			_delay_timer.stop()
			_repeat_timer.stop()
			return
	
	# Handle zoom in/out with triggers - only on press, not hold
	if event.is_action_pressed("zoom_in") and not _zoom_in_pressed:
		_zoom_in_pressed = true
		_adjust_zoom(0.02)
		return
	elif event.is_action_released("zoom_in"):
		_zoom_in_pressed = false
		return
	
	if event.is_action_pressed("zoom_out") and not _zoom_out_pressed:
		_zoom_out_pressed = true
		_adjust_zoom(-0.02)
		return
	elif event.is_action_released("zoom_out"):
		_zoom_out_pressed = false
		return
	
	# Handle ui_cancel to go back to Home
	if event.is_action_pressed("ui_cancel"):
		# Play return sound
		if AudioManager:
			AudioManager.play_sfx("return")
		# Switch to Home view
		UIManager.switch_to_tab("Home")
		# Set focus to Home button (use UIManager's helper to find it)
		await get_tree().process_frame
		reset_focus_to_home_button()
		return

func _adjust_zoom(delta: float) -> void:
	"""Adjust zoom level by delta and save to settings."""
	if not bottom_bar:
		return
	
	var current_zoom = bottom_bar.get_zoom_value()
	var new_zoom = clampf(current_zoom + delta, 0.05, 0.5)
	
	# Only update if value actually changed
	if not is_equal_approx(current_zoom, new_zoom):
		# Update bottom bar slider (uses set_value_no_signal, so we need to manually trigger updates)
		bottom_bar.set_zoom_value(new_zoom)
		
		# Manually trigger zoom update for grids (since set_zoom_value doesn't emit signals)
		_on_zoom_changed(new_zoom)
		
		# Save to settings immediately
		if SettingsManager:
			var zoom_setting = SettingsManager.get_setting("library_card_zoom")
			if zoom_setting:
				SettingsManager.set_setting(new_zoom, zoom_setting)
				SettingsManager.save_settings()
				print("[Main] Zoom adjusted to %.2f and saved" % new_zoom)

func _on_delay_timeout():
	if _held_dir != "":
		_repeat_timer.start()
		_resend()

func _on_repeat():
	if _held_dir != "":
		_resend()

func _resend():
	if _held_dir != "":
		# Send press event
		var press = InputEventAction.new()
		press.action = _held_dir
		press.pressed = true
		Input.parse_input_event(press)
		
		# Send release event to reset action state (allows analog sticks to work)
		var release = InputEventAction.new()
		release.action = _held_dir
		release.pressed = false
		Input.parse_input_event(release)
