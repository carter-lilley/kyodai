extends Control

# UI Nodes - initialized in _ready()
var tab_container: TabContainer
var hero_image: HeroImage
var hero_spacer: Control
var library_background: LibraryBackground
var content_wrapper: Control
var main_content_vbox: VBoxContainer
var root_layout: Control
var view_mode_group: M3ButtonGroup

# Cached reference to the on-screen keyboard (survives reparenting in dual-screen mode)
var _keyboard: PanelContainer = null

# Cached reference to UILayer (survives reparenting in dual-screen mode)
var _ui_layer: CanvasLayer = null

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

# Current grid snap ratios ( populated when in GRID mode, empty for LIST/CAROUSEL )
var _current_snap_ratios: Array[float] = []

# Focus restoration on app resume (Android)
var _last_focused_index: int = -1

func _ready():
	_setup_repeat()
	
	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")
	
	# Get all nodes using get_node to ensure they're ready
	tab_container = get_node("RootLayout/ContentWrapper/MainContentVBox/TabContainer")
	hero_image = get_node("RootLayout/ContentWrapper/HeroImage")
	hero_spacer = get_node("RootLayout/ContentWrapper/MainContentVBox/HeroSpacer")
	library_background = get_node("RootLayout/ContentWrapper/LibraryBackground")
	content_wrapper = get_node("RootLayout/ContentWrapper")
	main_content_vbox = get_node("RootLayout/ContentWrapper/MainContentVBox")
	root_layout = get_node("RootLayout")
	
	# Cache the on-screen keyboard and UILayer references (survive reparenting in dual-screen mode)
	_ui_layer = get_node_or_null("UILayer")
	_keyboard = get_node_or_null("UILayer/OnscreenKeyboard")
	
	# Initialize UIManager with all the pre-built nodes
	UIManager.initialize(
		tab_container,
		hero_image,
		hero_spacer,
		library_background,
		content_wrapper,
		main_content_vbox,
		root_layout
	)
	
	# Connect zoom slider signals
	var zoom_slider = main_content_vbox.get_node_or_null("HBoxContainer/M3Slider_Zoom")
	if zoom_slider:
		zoom_slider.value_changed.connect(_on_zoom_changed)
		zoom_slider.drag_ended.connect(_on_zoom_changed_finished)
	
	# Connect view mode buttons
	# Note: UIManager.initialize() reparents ContentWrapper, so we must use the
	# cached main_content_vbox reference instead of a root-relative path.
	view_mode_group = main_content_vbox.get_node("HBoxContainer/M3ButtonGroup")
	view_mode_group.selection_changed.connect(_on_view_mode_changed)
	_sync_view_mode_button_to_setting()
	
	# Connect settings gear button
	var settings_button = main_content_vbox.get_node("HBoxContainer/SettingsButton")
	if settings_button:
		settings_button.pressed.connect(_on_settings_button_pressed)
	
	# Connect more-options button
	var more_button = main_content_vbox.get_node_or_null("HBoxContainer/M3IconButton_More")
	if more_button:
		more_button.pressed.connect(_on_more_button_pressed)
	
	# Connect to UIManager for tab changes and settings dialog
	UIManager.tab_changed.connect(_on_tab_changed)
	UIManager.settings_dialog_dismissed.connect(_on_settings_dialog_dismissed)
	
	# Connect to LaunchManager to save focus before game launch
	if LaunchManager:
		LaunchManager.game_launch_initiated.connect(_on_game_launch_initiated)
		# Connect to background state signals for desktop
		LaunchManager.background_state_entered.connect(_on_background_state_entered)
		LaunchManager.background_state_exited.connect(_on_background_state_exited)
	
	# Set initial view
	_update_ui_for_view("Home")
	
	# Load and apply saved zoom setting (wait for views to be ready)
	await get_tree().process_frame
	_load_and_apply_saved_zoom()
	
	# Connect to screen swap signal for dual screen handling
	var ayn_thor_manager = get_node_or_null("AynThorManager")
	if ayn_thor_manager:
		ayn_thor_manager.screens_swapped.connect(_on_screens_swapped)
	
	# DEBUG: Connect to global focus changed to see what's grabbing focus
	get_viewport().gui_focus_changed.connect(_on_global_focus_changed)
	
	# Fix: Prevent SubViewportContainers from grabbing focus on touch
	var main_viewport_container = get_node_or_null("DualScreenSetup/MainViewportContainer")
	if main_viewport_container:
		main_viewport_container.focus_mode = Control.FOCUS_NONE
		print("[Main] Set MainViewportContainer focus_mode to FOCUS_NONE")
	
	var second_viewport_container = get_node_or_null("DualScreenSetup/SecondViewportContainer")
	if second_viewport_container:
		second_viewport_container.focus_mode = Control.FOCUS_NONE
		print("[Main] Set SecondViewportContainer focus_mode to FOCUS_NONE")
	
	# Extract native binaries on Android (non-blocking, happens in background)
	if PlatformManager.is_android():
		AndroidBinaryExtractor.extract_all_binaries()
	
	# Check if first-run wizard needs to be shown
	_show_oobe_wizard_if_needed()

func _show_oobe_wizard_if_needed():
	var first_run_setting = SettingsManager.get_setting("first_run_completed")
	var is_first_run = true
	if first_run_setting:
		is_first_run = not first_run_setting.value
	
	if is_first_run:
		print("[Main] First run detected, showing OOBE wizard")
		var wizard_scene = preload("res://components/oobe_wizard.tscn")
		var wizard = wizard_scene.instantiate()
		
		if _ui_layer:
			_ui_layer.add_child(wizard)
			wizard.start_wizard()
			wizard.wizard_completed.connect(_on_oobe_wizard_completed)
		else:
			push_error("[Main] UILayer not found, cannot show OOBE wizard")

func _on_oobe_wizard_completed():
	print("[Main] OOBE wizard completed")
	# Rebuild settings dialog with updated path/RomM values so it's fresh
	UIManager.pre_create_settings_dialog()
	# Refresh any views that might need updated settings
	UIManager.rebuild_game_grid()
	# Restore focus to the home button
	call_deferred("reset_focus_to_home_button")

func _on_settings_button_pressed() -> void:
	UIManager.show_settings_dialog()

func _on_settings_dialog_dismissed() -> void:
	# Restore focus to the settings gear button
	var settings_button = main_content_vbox.get_node_or_null("HBoxContainer/SettingsButton")
	if settings_button and settings_button.focus_mode != Control.FOCUS_NONE:
		settings_button.grab_focus()

func _on_more_button_pressed() -> void:
	var menu = M3Menu.new()
	var current_view = UIManager.get_current_view()
	var is_grid = false
	var is_horizontal = false
	
	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			is_grid = grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID
			is_horizontal = not grid.grid_vertical
	
	menu.add_check_item("Horizontal Grid", is_horizontal, _toggle_horizontal_grid)
	if not is_grid:
		menu.get_item(menu.get_item_count() - 1).disabled = true
	
	var more_button = main_content_vbox.get_node_or_null("HBoxContainer/M3IconButton_More")
	if more_button:
		menu.popup(more_button)

func _toggle_horizontal_grid() -> void:
	var target_vertical = true
	var current_view = UIManager.get_current_view()
	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			target_vertical = not grid.grid_vertical
	
	# Apply to both Home and Library grids
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var grid = _get_view_grid(view)
			if grid:
				grid.grid_vertical = target_vertical
	
	# Persist
	if SettingsManager:
		var setting = SettingsManager.get_setting("library_grid_vertical")
		if setting:
			SettingsManager.set_setting(target_vertical, setting)
			SettingsManager.save_settings()
	
	# Refresh zoom slider so it uses snap ratios for the new orientation
	if current_view:
		_update_ui_for_view(current_view.view_name)

func _on_tab_changed(view_name: String):
	# Apply saved zoom first, then sync slider so UI reflects the applied value
	if view_name in ["Home", "Library"]:
		await _apply_zoom_to_view_deferred(view_name)
	_update_ui_for_view(view_name)

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
		await get_tree().process_frame
		_apply_zoom_to_view_deferred(view_name)
		return
	
	grid.target_card_width_ratio = zoom_setting.value

func _update_ui_for_view(view_name: String):
	# Show/hide view mode buttons only on Home and Library
	if view_mode_group:
		view_mode_group.visible = view_name in ["Home", "Library"]
	
	# Update zoom slider to match current view's grid
	var zoom_slider = main_content_vbox.get_node_or_null("HBoxContainer/M3Slider_Zoom")
	if zoom_slider:
		zoom_slider.visible = view_name in ["Home", "Library"]
		var view = UIManager.get_view(view_name)
		if view and view_name in ["Home", "Library"]:
			var games_grid = _get_view_grid(view)
			if games_grid:
				# Defer if grid hasn't been laid out yet — get_snap_ratios() needs valid size
				# Guard with retry counter to prevent infinite recursion
				if games_grid.size.x <= 0 or games_grid.size.y <= 0:
					if not games_grid.has_meta("_ui_view_retry_count"):
						games_grid.set_meta("_ui_view_retry_count", 0)
					var retry_count = games_grid.get_meta("_ui_view_retry_count")
					if retry_count < 5:
						games_grid.set_meta("_ui_view_retry_count", retry_count + 1)
						await get_tree().process_frame
						_update_ui_for_view(view_name)
					else:
						games_grid.set_meta("_ui_view_retry_count", 0)
					return
				games_grid.set_meta("_ui_view_retry_count", 0)
				_update_zoom_slider_stops(zoom_slider, games_grid)
				if _current_snap_ratios.size() > 0:
					zoom_slider.set_value_no_signal(_find_nearest_snap_index(games_grid.target_card_width_ratio))
				else:
					zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)

func _update_zoom_slider_stops(zoom_slider: M3Slider, games_grid: VirtualScrollGridContainer) -> void:
	"""Update slider stops to match the grid's calculated snap levels."""
	var snap_ratios = games_grid.get_snap_ratios()
	# Reverse so index 0 = smallest ratio (zoomed out, most items per line)
	# and max index = largest ratio (zoomed in, fewest items per line)
	snap_ratios.reverse()
	_current_snap_ratios = snap_ratios
	if snap_ratios.size() > 0:
		# Grid mode: use integer indices so stops are evenly spaced visually.
		# The actual snap ratios are looked up by index when applying zoom.
		zoom_slider.step = 1.0
		zoom_slider.custom_stop_values = []
		zoom_slider.min_value = 0
		zoom_slider.max_value = snap_ratios.size() - 1
		zoom_slider.label_behavior = M3Slider.LabelBehavior.NEVER
	else:
		# List/Carousel mode: fall back to uniform float steps
		zoom_slider.custom_stop_values = []
		var max_zoom: float
		match games_grid.view_mode:
			VirtualScrollGridContainer.ViewMode.GRID:
				max_zoom = 0.5
			VirtualScrollGridContainer.ViewMode.CAROUSEL:
				max_zoom = 0.5
			VirtualScrollGridContainer.ViewMode.LIST:
				max_zoom = 0.5
		zoom_slider.min_value = 0.15
		zoom_slider.max_value = max_zoom
		zoom_slider.step = 0.05
		zoom_slider.label_behavior = M3Slider.LabelBehavior.WHILE_DRAGGING

func _find_nearest_snap_index(ratio: float) -> int:
	"""Find the index of the snap ratio closest to the given ratio."""
	if _current_snap_ratios.is_empty():
		return 0
	var nearest_idx = 0
	var nearest_dist = abs(ratio - _current_snap_ratios[0])
	for i in range(_current_snap_ratios.size()):
		var dist = abs(ratio - _current_snap_ratios[i])
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_idx = i
	return nearest_idx

func _on_view_mode_changed(selected_indices: Array[int]) -> void:
	if selected_indices.is_empty():
		return
	
	var new_mode: VirtualScrollGridContainer.ViewMode
	var setting_value: int
	
	match selected_indices[0]:
		0:  # Grid
			new_mode = VirtualScrollGridContainer.ViewMode.GRID
			setting_value = 0
		1:  # List
			new_mode = VirtualScrollGridContainer.ViewMode.LIST
			setting_value = 3
		2:  # Carousel
			new_mode = VirtualScrollGridContainer.ViewMode.CAROUSEL
			setting_value = 2
		_:
			return
	
	# Apply to both Home and Library grids
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var grid = _get_view_grid(view)
			if grid:
				grid.view_mode = new_mode
			else:
				push_error("[Main] No grid found for view: " + view_name)
		else:
			push_error("[Main] View not found: " + view_name)
	
	# Save to settings
	if SettingsManager:
		var mode_setting = SettingsManager.get_setting("library_layout_mode")
		if mode_setting:
			SettingsManager.set_setting(setting_value, mode_setting)
			SettingsManager.save_settings()
	
	# Update zoom slider stops/range since max zoom and snap levels differ per mode
	var current_view = UIManager.get_current_view()
	if current_view:
		var games_grid = _get_view_grid(current_view)
		if games_grid:
			var zoom_slider = main_content_vbox.get_node_or_null("HBoxContainer/M3Slider_Zoom")
			if zoom_slider:
				_update_zoom_slider_stops(zoom_slider, games_grid)
				# Sync slider value to the grid's actual current ratio
				if _current_snap_ratios.size() > 0:
					zoom_slider.set_value_no_signal(_find_nearest_snap_index(games_grid.target_card_width_ratio))
				else:
					zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)

func _sync_view_mode_button_to_setting() -> void:
	if not view_mode_group or not SettingsManager:
		return
	
	var mode_setting = SettingsManager.get_setting("library_layout_mode")
	var layout_mode = mode_setting.value if mode_setting else 0
	
	var button_index: int
	match layout_mode:
		0, 1: button_index = 0  # Grid
		2:    button_index = 2  # Carousel
		3:    button_index = 1  # List
		_:    button_index = 0
	
	view_mode_group.select_button(button_index)

func _on_zoom_changed(value: float):
	"""Called continuously while dragging - updates both views for parity."""
	var actual_zoom = value
	if _current_snap_ratios.size() > 0:
		# Grid mode: value is an integer index — map to actual ratio
		var index = clampi(int(round(value)), 0, _current_snap_ratios.size() - 1)
		actual_zoom = _current_snap_ratios[index]
	
	# Apply zoom to BOTH Home and Library grids for consistent zoom across views
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var games_grid = _get_view_grid(view)
			if games_grid:
				# Only update if the zoom actually changed
				if not is_equal_approx(actual_zoom, games_grid.target_card_width_ratio):
					games_grid.target_card_width_ratio = actual_zoom

func _on_zoom_changed_finished(value_changed: bool):
	"""Called when drag ends - saves the current slider value to settings."""
	if not value_changed:
		return
	var zoom_slider = main_content_vbox.get_node_or_null("HBoxContainer/M3Slider_Zoom")
	var saved_value = 0.15
	if zoom_slider:
		if _current_snap_ratios.size() > 0:
			# Grid mode: map integer index back to actual ratio
			var index = clampi(int(round(zoom_slider.value)), 0, _current_snap_ratios.size() - 1)
			saved_value = _current_snap_ratios[index]
		else:
			saved_value = zoom_slider.value
	
	# Save zoom to settings
	if SettingsManager:
		var zoom_setting = SettingsManager.get_setting("library_card_zoom")
		if zoom_setting:
			SettingsManager.set_setting(saved_value, zoom_setting)
			SettingsManager.save_settings()

func _get_view_grid(view: View) -> VirtualScrollGridContainer:
	# Safely get the games grid from a view
	# New structure: MarginContainer/VBoxContainer/VirtualScrollGridContainer (for platform indicator)
	if view.has_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer"):
		return view.get_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer")
	# Old structure: MarginContainer/VirtualScrollGridContainer
	elif view.has_node("MarginContainer/VirtualScrollGridContainer"):
		return view.get_node("MarginContainer/VirtualScrollGridContainer")
	# Very old structure: VirtualScrollGridContainer
	elif view.has_node("VirtualScrollGridContainer"):
		return view.get_node("VirtualScrollGridContainer")
	return null

func _load_and_apply_saved_zoom() -> void:
	"""Load saved zoom from settings and apply to both grids for parity."""
	if not SettingsManager:
		return
	
	var zoom_setting = SettingsManager.get_setting("library_card_zoom")
	if not zoom_setting:
		return
	
	var saved_zoom = zoom_setting.value
	
	# Apply to BOTH Home and Library views for consistent zoom across views
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var grid = _get_view_grid(view)
			if grid:
				grid.target_card_width_ratio = saved_zoom
	
	# Set zoom slider to saved value and refresh stops
	var zoom_slider = main_content_vbox.get_node_or_null("HBoxContainer/M3Slider_Zoom")
	if zoom_slider:
		var current_view = UIManager.get_current_view()
		var games_grid = _get_view_grid(current_view) if current_view else null
		if games_grid:
			_update_zoom_slider_stops(zoom_slider, games_grid)
		# Use the grid's actual snapped ratio (not the raw saved value) so slider matches reality
		var actual_zoom = games_grid.target_card_width_ratio if games_grid else saved_zoom
		if _current_snap_ratios.size() > 0:
			zoom_slider.set_value_no_signal(_find_nearest_snap_index(actual_zoom))
		else:
			zoom_slider.set_value_no_signal(actual_zoom)

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home destination in the M3 nav."""
	var home_button = UIManager.find_home_button()
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		home_button.grab_focus()

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
	# Block all input during background state (emulator running)
	if LaunchManager and LaunchManager.is_in_background_state():
		get_viewport().set_input_as_handled()
		return
	
	# Block input if OOBE wizard is visible
	if _ui_layer:
		for child in _ui_layer.get_children():
			if child.has_method("start_wizard") and child.visible:
				return
	
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
	# Play sound effect when zooming (R2/L2)
		if AudioManager:
			AudioManager.play_sfx("click_04")
		_zoom_in_pressed = true
		_adjust_zoom(0.02)
		return
	elif event.is_action_released("zoom_in"):
		_zoom_in_pressed = false
		return
	
	if event.is_action_pressed("zoom_out") and not _zoom_out_pressed:
	# Play sound effect when zooming (R2/L2)
		if AudioManager:
			AudioManager.play_sfx("click_04")
		_zoom_out_pressed = true
		_adjust_zoom(-0.02)
		return
	elif event.is_action_released("zoom_out"):
		_zoom_out_pressed = false
		return
	
	# Handle ui_cancel to go back to Home (unless keyboard is open)
	if event.is_action_pressed("ui_cancel"):
		# Check if keyboard is visible - if so, let keyboard handle it
		if _keyboard and _keyboard.visible:
			# Keyboard will handle ui_cancel to close itself
			return
		
		# If in Library view with an active search, clear the search first
		var current_view = UIManager.get_current_view()
		if current_view and current_view.view_name == "Library" and current_view.has_method("try_clear_search"):
			if current_view.try_clear_search():
				get_viewport().set_input_as_handled()
				return
		
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
	var zoom_slider = main_content_vbox.get_node_or_null("HBoxContainer/M3Slider_Zoom")
	if not zoom_slider:
		return
	
	var current_view = UIManager.get_current_view()
	var is_grid = false
	if current_view:
		var games_grid = _get_view_grid(current_view)
		if games_grid:
			is_grid = games_grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID
	
	if _current_snap_ratios.size() > 0 and is_grid:
		# Grid mode: move by whole stop indices
		var current_index = int(round(zoom_slider.value))
		var new_index = clampi(current_index + sign(delta), 0, _current_snap_ratios.size() - 1)
		if new_index != current_index:
			var focused_index = _get_focused_card_index()
			zoom_slider.set_value_no_signal(new_index)
			_on_zoom_changed(new_index)
			if focused_index >= 0:
				call_deferred("_restore_focus_to_card", focused_index)
			if SettingsManager:
				var zoom_setting = SettingsManager.get_setting("library_card_zoom")
				if zoom_setting:
					SettingsManager.set_setting(_current_snap_ratios[new_index], zoom_setting)
					SettingsManager.save_settings()
		return
	
	# List/Carousel mode: existing float logic
	var current_zoom = zoom_slider.value
	var max_zoom = 0.5
	var new_zoom = clampf(current_zoom + delta, 0.05, max_zoom)
	
	if not is_equal_approx(current_zoom, new_zoom):
		var focused_index = _get_focused_card_index()
		zoom_slider.set_value_no_signal(new_zoom)
		var actual_zoom = zoom_slider.value
		_on_zoom_changed(actual_zoom)
		if focused_index >= 0:
			call_deferred("_restore_focus_to_card", focused_index)
		if SettingsManager:
			var zoom_setting = SettingsManager.get_setting("library_card_zoom")
			if zoom_setting:
				SettingsManager.set_setting(actual_zoom, zoom_setting)
				SettingsManager.save_settings()

func _get_focused_card_index() -> int:
	"""Get the virtual index of the currently focused card, or -1 if none."""
	var viewport = get_viewport()
	print("[Main] _get_focused_card_index: viewport = ", viewport)
	if not viewport:
		print("[Main] _get_focused_card_index: no viewport")
		return -1
	
	var focused = viewport.gui_get_focus_owner()
	print("[Main] _get_focused_card_index: gui_get_focus_owner() = ", focused)
	if not focused:
		print("[Main] _get_focused_card_index: no focused control")
		return -1
	
	print("[Main] _get_focused_card_index: focused control = ", focused.name, " (", focused.get_class(), ")")
	print("[Main] _get_focused_card_index: focused path = ", focused.get_path())
	
	# Find the GameCard that contains the focused control
	var parent = focused
	var depth = 0
	while parent:
		print("[Main] _get_focused_card_index: checking parent at depth ", depth, ": ", parent.name, " has_meta virtual_index = ", parent.has_meta("virtual_index"))
		if parent.has_meta("virtual_index"):
			var idx = parent.get_meta("virtual_index", -1)
			print("[Main] _get_focused_card_index: found virtual_index ", idx, " at depth ", depth, " (", parent.name, ")")
			return idx
		parent = parent.get_parent()
		depth += 1
	
	print("[Main] _get_focused_card_index: no virtual_index found in parent chain")
	return -1

func _restore_focus_to_card(index: int) -> void:
	"""Restore focus to the card at the given virtual index."""
	#print("[Main] _restore_focus_to_card() called for index: ", index)
	
	# Get the current view
	var current_view = UIManager.get_current_view()
	if not current_view:
		print("[Main] _restore_focus_to_card: no current view")
		return
	print("[Main] _restore_focus_to_card: current view = ", current_view.name)
	
	# For HomeView, always restore to index 0 since it reorders by last played
	# For LibraryView, restore to the saved index
	var target_index = index
	if current_view is HomeView:
		target_index = 0
		print("[Main] _restore_focus_to_card: HomeView detected, forcing index to 0")
	
	var games_grid = _get_view_grid(current_view)
	if not games_grid:
		print("[Main] _restore_focus_to_card: no games_grid")
		return
	print("[Main] _restore_focus_to_card: found games_grid")
	
	# Get the card at the target index
	var card = games_grid.get_card_at_index(target_index)
	if not card:
		print("[Main] _restore_focus_to_card: no card at index ", target_index)
		return
	print("[Main] _restore_focus_to_card: found card ", card.name, " at index ", target_index)
	
	# Grab focus on the card directly (M3Card-based GameCard has no CardInput sub-node)
	if card is Control and card.focus_mode != Control.FOCUS_NONE:
		print("[Main] _restore_focus_to_card: calling grab_focus() on card")
		card.grab_focus()
		print("[Main] _restore_focus_to_card: grab_focus() completed")
	else:
		print("[Main] _restore_focus_to_card: card invalid or not focusable")

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

func _on_screens_swapped(is_swapped: bool) -> void:
	"""Handle screen swap from AynThorManager."""
	# Update any UI state that depends on which screen is primary
	# Note: No reparenting needed - AynThorManager handles rendering swap

func _on_global_focus_changed(control: Control) -> void:
	pass

func _notification(what: int) -> void:
	"""Handle application lifecycle notifications."""
	if what == NOTIFICATION_APPLICATION_RESUMED:
		print("[Main] NOTIFICATION_APPLICATION_RESUMED received, _last_focused_index = ", _last_focused_index)
		
		# On Android, exiting background state when we resume triggers save upload
		if LaunchManager and LaunchManager.is_in_background_state():
			print("[Main] In background state on resume, exiting to trigger save upload")
			LaunchManager.force_exit_background_state()
		
		# Restore focus when app returns to foreground (Android)
		if _last_focused_index >= 0:
			print("[Main] Calling _restore_focus_to_card deferred")
			call_deferred("_restore_focus_to_card", _last_focused_index)
		else:
			print("[Main] No saved focus index, skipping restoration")
		
		# Clear emulator validation cache and refresh platform cards
		# This handles APK installs that completed while the app was in the background
		if LaunchManager:
			LaunchManager.clear_validation_cache()
		var platforms_view = UIManager.get_settings_dialog_platforms_view()
		if platforms_view and platforms_view.has_method("refresh_cards"):
			platforms_view.refresh_cards()
			print("[Main] Refreshed platform cards after resume")
		
		# Dismiss any stale notifications (e.g., extraction notifications that completed while backgrounded)
		if NotificationManager:
			NotificationManager.dismiss_all_notifications()
			print("[Main] Dismissed all notifications after resume")

func _on_game_launch_initiated(_game: GameResource, focus_index: int) -> void:
	"""Save the focused card index when a game launch is initiated."""
	print("[Main] _on_game_launch_initiated() called with focus_index: ", focus_index)
	
	# Store the focused card index (passed from card before focus is lost)
	_last_focused_index = focus_index
	print("[Main] Saved _last_focused_index: ", _last_focused_index)
	
	# Note: Pre-launch save sync is now handled inside LaunchManager.launch_game()

func _on_background_state_entered(_pid: int, _game: GameResource) -> void:
	"""Handle entering background state - input is now blocked in _input."""
	print("[Main] Background state entered - input blocked")
	# Optional: Show overlay or dim the UI
	# UIManager.set_dimmed(true)

func _on_background_state_exited(_game: GameResource, _exit_code: int) -> void:
	"""Handle exiting background state - restore focus."""
	print("[Main] Background state exited - restoring focus")
	# Optional: Remove overlay
	# UIManager.set_dimmed(false)
	
	# Auto-upload saves after playing
	if _game:
		var emulator_id = LaunchManager.resolve_emulator_for_game(_game)
		print("[Main] Auto-upload check - emulator_id: " + emulator_id)
		if emulator_id != "":
			SaveManager.auto_upload_saves_for_game(_game, emulator_id)
		else:
			print("[Main] Auto-upload skipped: no emulator resolved")
	else:
		print("[Main] Auto-upload skipped: _game is null")
	
	# Restore focus to the last known position
	if _last_focused_index >= 0:
		call_deferred("_restore_focus_to_card", _last_focused_index)
	else:
		# Fallback to home button
		call_deferred("reset_focus_to_home_button")
