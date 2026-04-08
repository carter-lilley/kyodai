extends Control

# UI Nodes - initialized in _ready()
var tab_container: TabContainer
var navigation_bar: NavigationBar
var controls_bar: ControlsBar
var hero_image: HeroImage
var hero_spacer: Control
var library_background: LibraryBackground
var content_wrapper: Control
var main_content_vbox: VBoxContainer
var root_layout: Control

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

# Focus restoration on app resume (Android)
var _last_focused_index: int = -1

func _ready():
	_setup_repeat()
	
	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")
	
	# Get all nodes using get_node to ensure they're ready
	tab_container = get_node("RootLayout/ContentWrapper/MainContentVBox/TabContainer")
	navigation_bar = get_node("NavigationBar")
	controls_bar = get_node("ControlsBar")
	hero_image = get_node("RootLayout/ContentWrapper/HeroImage")
	hero_spacer = get_node("RootLayout/ContentWrapper/MainContentVBox/HeroSpacer")
	library_background = get_node("RootLayout/ContentWrapper/LibraryBackground")
	content_wrapper = get_node("RootLayout/ContentWrapper")
	main_content_vbox = get_node("RootLayout/ContentWrapper/MainContentVBox")
	root_layout = get_node("RootLayout")
	

	
	# Initialize UIManager with all the pre-built nodes
	UIManager.initialize(
		tab_container,
		navigation_bar,
		hero_image,
		hero_spacer,
		library_background,
		content_wrapper,
		main_content_vbox,
		root_layout,
		controls_bar
	)
	
	# Connect navigation bar signals
	if navigation_bar:
		navigation_bar.nav_button_pressed.connect(_on_nav_button_pressed)
		navigation_bar.zoom_changed.connect(_on_zoom_changed)
		navigation_bar.zoom_changed_finished.connect(_on_zoom_changed_finished)
	else:
		push_error("[Main] NavigationBar not found!")
	
	# Connect to UIManager for tab changes
	UIManager.tab_changed.connect(_on_tab_changed)
	
	# Connect to LaunchManager to save focus before game launch
	if LaunchManager:
		LaunchManager.game_launch_initiated.connect(_on_game_launch_initiated)
	
	# Set initial view
	_update_navigation_bar_for_view("Home")
	
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

func _on_nav_button_pressed(view_name: String):
	UIManager.switch_to_tab(view_name)

func _on_tab_changed(view_name: String):
	_update_navigation_bar_for_view(view_name)
	
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
		await get_tree().process_frame
		_apply_zoom_to_view_deferred(view_name)
		return
	
	grid.target_card_width_ratio = zoom_setting.value

func _update_navigation_bar_for_view(view_name: String):
	navigation_bar.set_current_view(view_name)
	
	# Update zoom slider to match current view's grid
	var view = UIManager.get_view(view_name)
	if view and view_name in ["Home", "Library"]:
		var games_grid = _get_view_grid(view)
		if games_grid:
			navigation_bar.set_zoom_value(games_grid.target_card_width_ratio)

func _on_zoom_changed(value: float):
	"""Called continuously while dragging - updates both views for parity."""
	# Apply zoom to BOTH Home and Library grids for consistent zoom across views
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var games_grid = _get_view_grid(view)
			if games_grid:
				games_grid.target_card_width_ratio = value

func _on_zoom_changed_finished(_value: float):
	"""Called when drag ends - syncs slider to snapped value and saves setting."""
	# Get the snapped zoom value from the Library view grid
	var snapped_value = _value
	var library_view = UIManager.get_view("Library")
	if library_view:
		var games_grid = _get_view_grid(library_view)
		if games_grid:
			snapped_value = games_grid.target_card_width_ratio
	
	# Update slider to match snapped value
	navigation_bar.set_zoom_value(snapped_value)
	
	# Save snapped zoom to settings
	if SettingsManager:
		var zoom_setting = SettingsManager.get_setting("library_card_zoom")
		if zoom_setting:
			SettingsManager.set_setting(snapped_value, zoom_setting)
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
	
	# Set navigation bar slider to saved value
	if navigation_bar:
		navigation_bar.set_zoom_value(saved_zoom)

func set_status_text(text: String):
	if is_instance_valid(navigation_bar):
		navigation_bar.set_status_text(text)

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home button in the navigation bar."""
	if not is_instance_valid(navigation_bar):
		return
	
	# Search recursively for HomeButton since it's in dynamic containers
	var home_button = _find_node_by_name(navigation_bar, "HomeButton")
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
		var keyboard = $UILayer/OnscreenKeyboard
		if keyboard and keyboard.visible:
			# Keyboard will handle ui_cancel to close itself
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
	"""Adjust zoom level by delta and save to settings."""
	if not navigation_bar:
		return
	
	var current_zoom = navigation_bar.get_zoom_value()
	var new_zoom = clampf(current_zoom + delta, 0.05, 0.5)
	
	# Only update if value actually changed
	if not is_equal_approx(current_zoom, new_zoom):
		# Save the currently focused card's index before zooming
		var focused_index = _get_focused_card_index()
		
		# Update navigation bar slider (uses set_value_no_signal, so we need to manually trigger updates)
		navigation_bar.set_zoom_value(new_zoom)
		
		# Manually trigger zoom update for grids (since set_zoom_value doesn't emit signals)
		_on_zoom_changed(new_zoom)
		
		# Restore focus to the previously focused card after layout updates
		if focused_index >= 0:
			call_deferred("_restore_focus_to_card", focused_index)
		
		# Save to settings immediately
		if SettingsManager:
			var zoom_setting = SettingsManager.get_setting("library_card_zoom")
			if zoom_setting:
				SettingsManager.set_setting(new_zoom, zoom_setting)
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
	
	# Grab focus on the card's input element (inside VisualContainer)
	if card.has_node("VisualContainer/CardInput"):
		var card_input = card.get_node("VisualContainer/CardInput")
		if card_input and card_input is Control and card_input.focus_mode != Control.FOCUS_NONE:
			print("[Main] _restore_focus_to_card: calling grab_focus() on CardInput")
			card_input.grab_focus()
			print("[Main] _restore_focus_to_card: grab_focus() completed")
		else:
			print("[Main] _restore_focus_to_card: CardInput invalid or not focusable")
	else:
		print("[Main] _restore_focus_to_card: card has no VisualContainer/CardInput node")

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
		# Restore focus when app returns to foreground (Android)
		if _last_focused_index >= 0:
			print("[Main] Calling _restore_focus_to_card deferred")
			call_deferred("_restore_focus_to_card", _last_focused_index)
		else:
			print("[Main] No saved focus index, skipping restoration")

func _on_game_launch_initiated(_game: GameResource, focus_index: int) -> void:
	"""Save the focused card index when a game launch is initiated."""
	print("[Main] _on_game_launch_initiated() called with focus_index: ", focus_index)
	
	# Store the focused card index (passed from card before focus is lost)
	_last_focused_index = focus_index
	print("[Main] Saved _last_focused_index: ", _last_focused_index)
