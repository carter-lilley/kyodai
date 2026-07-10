extends Control

# UI Nodes - initialized in _ready()
var tab_container: TabContainer
var library_background: LibraryBackground
var content_wrapper: Control
var main_content_vbox: VBoxContainer
var root_layout: Control
var view_mode_group: M3ButtonGroup

# Cached reference to the on-screen keyboard (survives reparenting in dual-screen mode)
var _keyboard: PanelContainer = null

# Cached reference to UILayer (survives reparenting in dual-screen mode)
var _ui_layer: CanvasLayer = null


# Zoom state tracking for analog triggers
var _zoom_in_pressed: bool = false
var _zoom_out_pressed: bool = false

# Current grid snap ratios ( populated when in GRID mode, empty for LIST/CAROUSEL )
var _current_snap_ratios: Array[float] = []

# Focus restoration on app resume (Android)
var _last_focused_index: int = -1

# Debounced zoom save to avoid LIST/CAROUSEL flash during interaction
var _zoom_save_timer: Timer = null
const ZOOM_SAVE_DELAY_MS: int = 1500

# M3 Theme resource (applied to root for fallback native control styling)
var _m3_theme: Theme = null

func _ready():
	# Disable automatic quit so we can free the scene tree before the rendering
	# server shuts down. Without this, get_tree().quit() exits without destroying
	# nodes, which causes CanvasItem/Texture RID leaks.
	get_tree().auto_accept_quit = false

	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")

	# Get all nodes using get_node to ensure they're ready
	tab_container = get_node("RootLayout/ContentWrapper/MainContentVBox/TabContainer")
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
		library_background,
		content_wrapper,
		main_content_vbox,
		root_layout
	)

	# Create debounced zoom save timer (replaces _process polling)
	_zoom_save_timer = Timer.new()
	_zoom_save_timer.one_shot = true
	_zoom_save_timer.wait_time = ZOOM_SAVE_DELAY_MS / 1000.0
	_zoom_save_timer.timeout.connect(_on_zoom_save_timer_timeout)
	add_child(_zoom_save_timer)

	# Raise toolbar above the card grid (grid has z_index=-1 to let card focus
	# overflow render behind sibling UI; toolbar must sit above that).
	var toolbar = main_content_vbox.get_node_or_null("controlbar_background")
	if toolbar:
		toolbar.z_index = 10

	# Sync the top background mask height to match the control bar.
	# The mask covers the area behind the toolbar so cards scrolling up
	# don't peek through. It sits between the grid (z=-1) and toolbar (z=10).
	# Note: UIManager wraps MainContentVBox in a MarginContainer (dp(16) margins),
	# so the toolbar is offset from ContentWrapper's top-left. We must compute the
	# toolbar's bottom edge in ContentWrapper coordinates, not just use size.y.
	var mask = content_wrapper.get_node_or_null("controlbar_mask")
	if mask and toolbar:
		var _update_mask_height := func():
			var toolbar_bottom: float = toolbar.global_position.y - content_wrapper.global_position.y + toolbar.size.y
			mask.custom_minimum_size.y = toolbar_bottom
			mask.offset_top = 0
			mask.offset_bottom = toolbar_bottom
		toolbar.resized.connect(_update_mask_height)
		# Deferred sync: toolbar size may not be final on first signal.
		await get_tree().process_frame
		await get_tree().process_frame
		_update_mask_height.call()

	# Connect zoom slider signals
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if zoom_slider:
		zoom_slider.value_changed.connect(_on_zoom_changed)
		zoom_slider.drag_ended.connect(_on_zoom_changed_finished)

	# Connect view mode buttons
	# Note: UIManager.initialize() reparents ContentWrapper, so we must use the
	# cached main_content_vbox reference instead of a root-relative path.
	view_mode_group = main_content_vbox.get_node("controlbar_background/controlbar_hbox/M3ButtonGroup")
	view_mode_group.selection_changed.connect(_on_view_mode_changed)
	_sync_view_mode_button_to_setting()

	# Connect settings gear button (if present in scene; nav footer button is primary)
	var settings_button = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/SettingsButton")
	if settings_button:
		settings_button.pressed.connect(_on_settings_button_pressed)

	# Connect more-options button
	var more_button = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3IconButton_More")
	if more_button:
		more_button.pressed.connect(_on_more_button_pressed)

	# Connect to UIManager for tab changes and settings dialog
	UIManager.tab_changed.connect(_on_tab_changed)
	UIManager.settings_dialog_dismissed.connect(_on_settings_dialog_dismissed)

	# Re-sync zoom slider when viewport size changes (e.g. window resize).
	# The grid re-snaps its zoom in _on_resize_debounced(), but the slider
	# stops and position need to be updated from main.gd since it owns the UI.
	if SystemManager.display:
		SystemManager.display.viewport_size_changed.connect(_on_viewport_resized)

	# Connect to DataManager to sync UI when presets are applied
	if DataManager:
		DataManager.apply_preset_end.connect(_on_preset_applied)

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
		# Restore saved screen swap state
		var swap_setting = DataManager.get_setting("dual_screen_swapped")
		print("[Main] Startup dual_screen_swapped setting: ", swap_setting.value if swap_setting else "NULL")
		if swap_setting and swap_setting.value and not ayn_thor_manager.is_swapped:
			print("[Main] Restoring saved screen swap state")
			ayn_thor_manager.swap_screens()
		else:
			print("[Main] Not restoring screen swap (setting=", swap_setting.value if swap_setting else "NULL", ", is_swapped=", ayn_thor_manager.is_swapped, ")")

	# Extract native binaries on Android (non-blocking, happens in background)
	if SystemManager.platform.is_android():
		AndroidBinaryExtractor.extract_all_binaries()

	# Check if first-run wizard needs to be shown
	_show_oobe_wizard_if_needed()

	# Apply M3 theme to root for fallback native control styling (scrollbars, etc.)
	_apply_m3_theme()

	# Focus the first Home card on startup once data is loaded
	var first_run_setting = DataManager.get_setting("first_run_completed")
	if first_run_setting and first_run_setting.value:
		call_deferred("_focus_first_home_card_on_startup")

func _apply_m3_theme() -> void:
	_m3_theme = M3Theme.generate_theme()
	self.theme = _m3_theme

func refresh_theme() -> void:
	# Called by UIManager when theme colors change (dark mode, primary color, etc.)
	_apply_m3_theme()

func _show_oobe_wizard_if_needed():
	var first_run_setting = DataManager.get_setting("first_run_completed")
	var is_first_run = true
	if first_run_setting:
		is_first_run = not first_run_setting.value

	if is_first_run:
		print("[Main] First run detected, showing OOBE wizard")
		var wizard = OobeWizard.new()
		wizard.wizard_completed.connect(_on_oobe_wizard_completed)
		wizard.start_wizard()

func _on_oobe_wizard_completed():
	print("[Main] OOBE wizard completed")
	# Rebuild settings dialog with updated path/RomM values so it's fresh
	UIManager.pre_create_settings_dialog(true)
	# Refresh any views that might need updated settings
	UIManager.rebuild_game_grid()
	# Restore focus to the home button
	call_deferred("reset_focus_to_home_button")

func _on_settings_button_pressed() -> void:
	UIManager.show_settings_dialog()

func _on_settings_dialog_dismissed() -> void:
	# Restore focus to the Home button so controller users land in a known
	# location after closing settings with ui_cancel or the OK button.
	if UIManager:
		UIManager.suppress_next_focus_sound()
	call_deferred("reset_focus_to_home_button")

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

	menu.add_separator()

	# Card Display Mode submenu
	var display_mode = 0
	if DataManager:
		var display_setting = DataManager.get_setting("library_card_display_mode")
		if display_setting and display_setting.value is int:
			display_mode = display_setting.value

	var display_submenu = M3Menu.new()
	display_submenu.auto_free = false
	display_submenu.radio_group = true
	display_submenu.add_check_item("Standard", display_mode == 0, func(): _set_card_display_mode(0))
	display_submenu.add_check_item("Transparent", display_mode == 1, func(): _set_card_display_mode(1))
	display_submenu.add_check_item("Media Only", display_mode == 2, func(): _set_card_display_mode(2))
	menu.add_submenu_item("Card Display Mode", display_submenu, "cards-outline")

	# Card Media Ratio submenu
	var media_ratio = 0
	if DataManager:
		var ratio_setting = DataManager.get_setting("card_media_aspect_ratio")
		if ratio_setting and ratio_setting.value is int:
			media_ratio = ratio_setting.value

	var ratio_submenu = M3Menu.new()
	ratio_submenu.auto_free = false
	ratio_submenu.radio_group = true
	ratio_submenu.add_check_item("Fill", media_ratio == 0, func(): _set_card_media_ratio(0))
	ratio_submenu.add_check_item("2:3", media_ratio == 1, func(): _set_card_media_ratio(1))
	ratio_submenu.add_check_item("3:4", media_ratio == 2, func(): _set_card_media_ratio(2))
	ratio_submenu.add_check_item("1:1", media_ratio == 3, func(): _set_card_media_ratio(3))
	ratio_submenu.add_check_item("16:11", media_ratio == 4, func(): _set_card_media_ratio(4))
	menu.add_submenu_item("Card Media Ratio", ratio_submenu, "aspect-ratio")

	# Content Alignment submenu
	var content_alignment = 0
	if DataManager:
		var align_setting = DataManager.get_setting("library_card_content_alignment")
		if align_setting and align_setting.value is int:
			content_alignment = align_setting.value

	var align_submenu = M3Menu.new()
	align_submenu.auto_free = false
	align_submenu.radio_group = true
	align_submenu.add_check_item("Left / Top", content_alignment == 0, func(): _set_content_alignment(0))
	align_submenu.add_check_item("Center / Middle", content_alignment == 1, func(): _set_content_alignment(1))
	align_submenu.add_check_item("Right / Bottom", content_alignment == 2, func(): _set_content_alignment(2))
	menu.add_submenu_item("Content Alignment", align_submenu, "format-align-center")

	var more_button = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3IconButton_More")
	if more_button:
		menu.popup(more_button)

func _set_card_display_mode(mode: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_card_display_mode")
		if setting:
			DataManager.set_setting(mode, setting)
			DataManager.save_settings()

func _set_card_media_ratio(ratio: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("card_media_aspect_ratio")
		if setting:
			DataManager.set_setting(ratio, setting)
			DataManager.save_settings()

func _set_content_alignment(alignment: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_card_content_alignment")
		if setting:
			DataManager.set_setting(alignment, setting)
			DataManager.save_settings()

func _toggle_horizontal_grid() -> void:
	var target_vertical = true
	var current_view = UIManager.get_current_view()
	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			target_vertical = not grid.grid_vertical

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = _get_focused_card_index()

	# Apply to both Home and Library grids
	for view_name in ["Home", "Library"]:
		var view = UIManager.get_view(view_name)
		if view:
			var grid = _get_view_grid(view)
			if grid:
				grid.grid_vertical = target_vertical

	# Persist
	if DataManager:
		var setting = DataManager.get_setting("library_grid_vertical")
		if setting:
			DataManager.set_setting(target_vertical, setting)
			DataManager.save_settings()

	# Refresh zoom slider so it uses snap ratios for the new orientation
	if current_view:
		_update_ui_for_view(current_view.view_name)

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

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
	if not grid or not DataManager:
		return

	var zoom_setting = DataManager.get_setting("library_card_zoom")
	if not zoom_setting:
		return

	# Keep checking until grid has valid dimensions
	if grid.size.x <= 0 or grid.size.y <= 0:
		await get_tree().process_frame
		_apply_zoom_to_view_deferred(view_name)
		return

	grid.target_card_width_ratio = zoom_setting.value

func _on_viewport_resized(_new_size: Vector2) -> void:
	"""Re-sync zoom slider after viewport resize. The grid re-snaps its zoom
	in _on_resize_debounced(), but the slider stops and position are owned
	by main.gd and must be updated to match."""
	var current_view = UIManager.get_current_view()
	if not current_view:
		return
	var view_name = current_view.view_name
	if view_name not in ["Home", "Library"]:
		return

	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if not zoom_slider:
		return

	var games_grid = _get_view_grid(current_view)
	if not games_grid:
		return

	# Wait one frame for the grid to finish its resize recalculation
	await get_tree().process_frame

	_update_zoom_slider_stops(zoom_slider, games_grid)
	zoom_slider.set_block_signals(true)
	if _current_snap_ratios.size() > 0:
		zoom_slider.set_value_no_signal(_find_nearest_snap_index(games_grid.target_card_width_ratio))
	else:
		zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
	zoom_slider.set_block_signals(false)

func _update_ui_for_view(view_name: String):
	# Show/hide view mode buttons only on Home and Library
	if view_mode_group:
		view_mode_group.visible = view_name in ["Home", "Library"]

	# Update zoom slider to match current view's grid
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
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
				zoom_slider.set_block_signals(true)
				if _current_snap_ratios.size() > 0:
					zoom_slider.set_value_no_signal(_find_nearest_snap_index(games_grid.target_card_width_ratio))
				else:
					zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
				zoom_slider.set_block_signals(false)

func _update_zoom_slider_stops(zoom_slider: M3Slider, games_grid: VirtualScrollGridContainer) -> void:
	"""Update slider stops to match the grid's calculated snap levels."""
	var snap_ratios = games_grid.get_snap_ratios()
	# Reverse so index 0 = smallest ratio (zoomed out, most items per line)
	# and max index = largest ratio (zoomed in, fewest items per line)
	snap_ratios.reverse()

	# Guard: ensure at least 2 snap ratios to prevent division-by-zero in slider
	# and to provide meaningful zoom range. If only 1 ratio, add a second.
	if snap_ratios.size() == 1:
		# Add a smaller ratio (zoomed out more) — cap at minimum 0.05
		var second_ratio = maxf(0.05, snap_ratios[0] * 0.7)
		if not is_equal_approx(second_ratio, snap_ratios[0]):
			snap_ratios.insert(0, second_ratio)

	_current_snap_ratios = snap_ratios
	if snap_ratios.size() >= 2:
		# Grid mode: use integer indices so stops are evenly spaced visually.
		# The actual snap ratios are looked up by index when applying zoom.
		zoom_slider.step = 1.0
		# Populate custom stops so M3Slider draws tick marks at each snap level
		var stops: Array[float] = []
		for i in range(snap_ratios.size()):
			stops.append(float(i))
		zoom_slider.custom_stop_values = stops
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
	var nearest_dist = INF
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
			setting_value = 1
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
	if DataManager:
		var mode_setting = DataManager.get_setting("library_layout_mode")
		if mode_setting:
			DataManager.set_setting(setting_value, mode_setting)
			DataManager.save_settings()

	# Update zoom slider stops/range since max zoom and snap levels differ per mode
	var current_view = UIManager.get_current_view()
	if current_view:
		var games_grid = _get_view_grid(current_view)
		if games_grid:
			var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
			if zoom_slider:
				_update_zoom_slider_stops(zoom_slider, games_grid)
				# Sync slider value to the grid's actual current ratio
				zoom_slider.set_block_signals(true)
				if _current_snap_ratios.size() > 0:
					zoom_slider.set_value_no_signal(_find_nearest_snap_index(games_grid.target_card_width_ratio))
				else:
					zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
				zoom_slider.set_block_signals(false)


func _on_preset_applied() -> void:
	"""Sync UI controls after a theme preset is applied."""
	# Sync view mode buttons to match the newly loaded setting
	_sync_view_mode_button_to_setting()
	# Re-apply zoom to both views (deferred so grids have valid dimensions)
	call_deferred("_load_and_apply_saved_zoom")

func _sync_view_mode_button_to_setting() -> void:
	if not view_mode_group or not DataManager:
		return

	var mode_setting = DataManager.get_setting("library_layout_mode")
	var layout_mode_val = mode_setting.value if mode_setting else 0

	var button_index: int
	match layout_mode_val:
		0: button_index = 0  # Grid
		1: button_index = 1  # List
		2: button_index = 2  # Carousel
		_: button_index = 0

	# Block signals during programmatic sync so it isn't treated as a user change.
	view_mode_group.set_block_signals(true)
	view_mode_group.select_button(button_index)
	view_mode_group.set_block_signals(false)

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
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	var saved_value = 0.15
	if zoom_slider:
		if _current_snap_ratios.size() > 0:
			# Grid mode: map integer index back to actual ratio
			var index = clampi(int(round(zoom_slider.value)), 0, _current_snap_ratios.size() - 1)
			saved_value = _current_snap_ratios[index]
		else:
			saved_value = zoom_slider.value

	# Update in-memory setting and schedule a debounced save to avoid LIST/CAROUSEL flash
	if DataManager:
		var zoom_setting = DataManager.get_setting("library_card_zoom")
		if zoom_setting:
			DataManager.set_setting(saved_value, zoom_setting)
			if _zoom_save_timer:
				_zoom_save_timer.start()

func _on_zoom_save_timer_timeout() -> void:
	if DataManager:
		DataManager.save_settings()

func _get_view_grid(view: View) -> VirtualScrollGridContainer:
	# Standard structure: MarginContainer/VBoxContainer/VirtualScrollGridContainer
	if view.has_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer"):
		return view.get_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer") as VirtualScrollGridContainer
	return null

func _load_and_apply_saved_zoom() -> void:
	"""Apply the saved zoom setting to both grids and sync the slider.

	Explicitly applies the saved ratio here so startup is robust even when
	view _ready() ran before the grid had valid dimensions.
	"""
	if not DataManager:
		return

	var zoom_setting = DataManager.get_setting("library_card_zoom")
	if not zoom_setting:
		return

	var saved_zoom = zoom_setting.value

	# Apply saved zoom to both Home and Library grids
	if UIManager:
		for view_name in ["Home", "Library"]:
			var view = UIManager.get_view(view_name)
			if view:
				var games_grid = _get_view_grid(view)
				if games_grid:
					games_grid.target_card_width_ratio = saved_zoom

	# Set zoom slider to the actual grid ratio
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if zoom_slider:
		var current_view = UIManager.get_current_view()
		var games_grid = _get_view_grid(current_view) if current_view else null
		if games_grid:
			_update_zoom_slider_stops(zoom_slider, games_grid)
		# Use the grid's actual snapped ratio (not the raw saved value) so slider matches reality
		var actual_zoom = games_grid.target_card_width_ratio if games_grid else saved_zoom
		zoom_slider.set_block_signals(true)
		if _current_snap_ratios.size() > 0:
			zoom_slider.set_value_no_signal(_find_nearest_snap_index(actual_zoom))
		else:
			zoom_slider.set_value_no_signal(actual_zoom)
		zoom_slider.set_block_signals(false)

func _focus_first_home_card_on_startup(attempts: int = 0) -> void:
	"""Focus the first game card in the Home grid once it has data."""
	if attempts > 60:
		print("[Main] Startup focus: grid did not populate, falling back to Home button")
		reset_focus_to_home_button()
		return

	if not UIManager or not UIManager.is_current_view("Home"):
		print("[Main] Startup focus: Home is not current view, aborting")
		return

	var home_view = UIManager.get_view("Home") as HomeView
	if not home_view or not home_view.games_grid:
		print("[Main] Startup focus: Home grid not ready, retrying...")
		await get_tree().process_frame
		_focus_first_home_card_on_startup(attempts + 1)
		return

	var grid = home_view.games_grid
	var range_info = grid.get_visible_range()
	if range_info.total <= 0:
		print("[Main] Startup focus: waiting for Home grid data (total=", range_info.total, ")")
		await get_tree().process_frame
		_focus_first_home_card_on_startup(attempts + 1)
		return

	print("[Main] Startup focus: focusing first Home card")
	grid.scroll_to_index_and_focus(0, false)

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home destination in the M3 nav."""
	var home_button = UIManager.find_home_button()
	print("[Main] find_home_button returned: ", home_button)
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		print("[Main] Grabbing focus on: ", home_button.name)
		home_button.grab_focus()
	else:
		print("[Main] Could not grab focus — home_button invalid or focus disabled")

func _is_home_button_focused() -> bool:
	var home_button = UIManager.find_home_button()
	if not home_button or not home_button is Control:
		return false
	return home_button == _get_focus_owner()

## DualScreenSetup lifecycle management
## Keep DualScreenSetup in the tree so its SubViewports are freed with Main.
## When not in use, disable processing and hide it to avoid input interference.

func _handle_ui_cancel() -> void:
	"""Handle ui_cancel: return to Home unless blocked by overlay."""
	# Block during background state (emulator running)
	if LaunchManager and LaunchManager.is_in_background_state():
		return

	# Block if OOBE wizard is visible
	if _ui_layer:
		for child in _ui_layer.get_children():
			if child.has_method("start_wizard") and child.visible:
				return

	# Check if keyboard is visible - let keyboard handle it
	print("[Main] _handle_ui_cancel: _keyboard=", _keyboard, " visible=", _keyboard.visible if _keyboard else "N/A", " in_second_viewport=", UIManager._keyboard_is_in_second_viewport if UIManager else "N/A")
	if _keyboard and _keyboard.visible:
		# If keyboard is in SecondViewport, it won't receive ui_cancel (controller input goes to MainViewport)
		# So we need to manually dismiss it here
		if UIManager and UIManager._keyboard_is_in_second_viewport:
			print("[Main] Manually dismissing keyboard in SecondViewport")
			if _keyboard.has_method("_hide_keyboard"):
				_keyboard._hide_keyboard()
				# Return focus to the active LineEdit in MainViewport
				if _keyboard._active_line_edit != null:
					_keyboard._active_line_edit.grab_focus()
			get_viewport().set_input_as_handled()
			return
		else:
			return

	# Check if settings dialog is open - let it handle dismissal
	if UIManager and UIManager.is_settings_dialog_open():
		return

	# Second cancel while on Home tab and Home button is focused opens Settings.
	if UIManager and UIManager.is_current_view("Home") and _is_home_button_focused():
		UIManager.show_settings_dialog()
		get_viewport().set_input_as_handled()
		return

	# If a bottom sheet overlay is open, let M3Overlay handle dismissal
	if M3Overlay.is_showing("bottom_sheet"):
		return

	# If in Library view with an active search, clear the search first
	var current_view = UIManager.get_current_view()
	if current_view and current_view.view_name == "Library" and current_view.has_method("try_clear_search"):
		if current_view.try_clear_search():
			return

	# If focus is locked in a grid, escape to the nav bar instead of switching to Home
	if current_view and current_view.games_grid:
		var grid = current_view.games_grid
		if grid.is_focus_locked_and_active():
			# Release scene-wide focus lock before moving focus to the nav bar.
			if UIManager:
				UIManager.exit_focus_lock(grid)
			var nav_dest = UIManager.get_active_nav_destination()
			if nav_dest and nav_dest is Control and nav_dest.focus_mode != Control.FOCUS_NONE:
				if SystemManager.audio:
					SystemManager.audio.play_sfx("return")
				nav_dest.grab_focus()
				print("[Main] _handle_ui_cancel: escaped locked grid to nav destination: ", nav_dest.name)
			else:
				var home_button = UIManager.find_home_button()
				if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
					if SystemManager.audio:
						SystemManager.audio.play_sfx("return")
					home_button.grab_focus()
					print("[Main] _handle_ui_cancel: escaped locked grid to home button")
			return

	# Play return sound
	if SystemManager.audio:
		SystemManager.audio.play_sfx("return")
	# Switch to Home view
	push_warning("[Main] ui_cancel: switching to Home")
	UIManager.switch_to_tab("Home")
	# Set focus to Home button (deferred so tab layout settles)
	call_deferred("reset_focus_to_home_button")

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

	# If the on-screen keyboard is on the second (dual) screen, controller input
	# does not reach that viewport automatically. Forward relevant actions so
	# the keyboard can be navigated and dismissed.
	if _keyboard and _keyboard.visible and UIManager and UIManager._keyboard_is_in_second_viewport:
		if _forward_input_to_second_viewport(event):
			return

	# Delegate directional input to NavigationManager for unified delay/repeat handling.
	# Skip when the on-screen keyboard is visible so keyboard keys can be navigated.
	if not (_keyboard and _keyboard.visible):
		if UIManager and UIManager.handle_directional_input(event):
			get_viewport().set_input_as_handled()
			return

	# Handle zoom in/out with triggers - only on press, not hold
	if event.is_action_pressed("zoom_in"):
		if not _zoom_in_pressed:
			if SystemManager.audio:
				SystemManager.audio.play_sfx("click_04")
			_zoom_in_pressed = true
			_adjust_zoom(1.0)
		return
	elif event.is_action_released("zoom_in"):
		_zoom_in_pressed = false
		return

	if event.is_action_pressed("zoom_out"):
		if not _zoom_out_pressed:
			if SystemManager.audio:
				SystemManager.audio.play_sfx("click_04")
			_zoom_out_pressed = true
			_adjust_zoom(-1.0)
		return
	elif event.is_action_released("zoom_out"):
		_zoom_out_pressed = false
		return

	# Handle ui_cancel: return to Home unless blocked by overlay.
	if event.is_action_pressed("ui_cancel"):
		_handle_ui_cancel()

func _get_focus_owner() -> Control:
	"""Get the focused control, accounting for dual-screen SubViewport."""
	if root_layout and root_layout.is_inside_tree():
		return root_layout.get_viewport().gui_get_focus_owner()
	return get_viewport().gui_get_focus_owner()

func _forward_input_to_second_viewport(event: InputEvent) -> bool:
	"""Forward controller actions to the second viewport while the keyboard is displayed there."""
	if not UIManager or not UIManager.dual_screen:
		return false
	var second_vp = UIManager.dual_screen.get_second_viewport()
	if not second_vp:
		return false
	var actions := ["ui_left", "ui_right", "ui_up", "ui_down", "ui_accept", "ui_cancel", "ui_start"]
	for action in actions:
		if event.is_action_pressed(action):
			second_vp.push_input(event)
			get_viewport().set_input_as_handled()
			return true
	return false

func _adjust_zoom(delta: float) -> void:
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
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
			# Update in-memory setting and schedule a debounced save to avoid LIST/CAROUSEL flash
			if DataManager:
				var zoom_setting = DataManager.get_setting("library_card_zoom")
				if zoom_setting:
					DataManager.set_setting(_current_snap_ratios[new_index], zoom_setting)
					if _zoom_save_timer:
						_zoom_save_timer.start()
		return

	# List/Carousel mode: step by slider step to avoid snapping back
	var current_zoom = zoom_slider.value
	var max_zoom = 0.5
	var effective_delta = sign(delta) * zoom_slider.step
	var new_zoom = clampf(current_zoom + effective_delta, 0.05, max_zoom)

	if not is_equal_approx(current_zoom, new_zoom):
		var focused_index = _get_focused_card_index()
		zoom_slider.set_value_no_signal(new_zoom)
		var actual_zoom = zoom_slider.value
		_on_zoom_changed(actual_zoom)
		if focused_index >= 0:
			call_deferred("_restore_focus_to_card", focused_index)
		# Update in-memory setting and schedule a debounced save to avoid LIST/CAROUSEL flash
		if DataManager:
			var zoom_setting = DataManager.get_setting("library_card_zoom")
			if zoom_setting:
				DataManager.set_setting(actual_zoom, zoom_setting)
				if _zoom_save_timer:
					_zoom_save_timer.start()

func _get_focused_card_index() -> int:
	"""Get the virtual index of the currently focused card, or -1 if none."""
	var viewport = get_viewport()
	if not viewport:
		return -1

	var focused = viewport.gui_get_focus_owner()
	if not focused:
		return -1

	# Find the GameCard that contains the focused control
	var parent = focused
	while parent:
		if parent.has_meta("virtual_index"):
			return parent.get_meta("virtual_index", -1)
		parent = parent.get_parent()

	return -1

func _restore_focus_to_card(index: int, preserve_index: bool = false) -> void:
	"""Restore focus to the card at the given virtual index."""
	var current_view = UIManager.get_current_view()
	if not current_view:
		return

	# For HomeView, normally restore to index 0 since it reorders by last played.
	# When preserve_index is true (e.g. orientation toggle), keep the original index.
	var target_index = index
	if current_view is HomeView and not preserve_index:
		target_index = 0

	var games_grid = _get_view_grid(current_view)
	if not games_grid:
		return

	var card = games_grid.get_card_at_index(target_index)
	if not card:
		return

	# Grab focus on the card directly (M3Card-based GameCard has no CardInput sub-node)
	if card is Control and card.focus_mode != Control.FOCUS_NONE:
		card.grab_focus()

func _on_screens_swapped(_is_swapped: bool) -> void:
	"""Handle screen swap from AynThorManager."""
	print("[Main] _on_screens_swapped called with _is_swapped=", _is_swapped)
	# Persist the new swapped state so it survives restarts
	if DataManager:
		var swap_setting = DataManager.get_setting("dual_screen_swapped")
		print("[Main] _on_screens_swapped: swap_setting=", swap_setting.value if swap_setting else "NULL")
		if swap_setting:
			DataManager.set_setting(_is_swapped, swap_setting)
			print("[Main] _on_screens_swapped: set value to ", _is_swapped, ", calling save_settings()")
			DataManager.save_settings()
			print("[Main] _on_screens_swapped: save_settings() returned")
		else:
			push_warning("[Main] _on_screens_swapped: dual_screen_swapped setting not found!")

	# Rebuild the settings dialog if it is open so it sizes to the new
	# viewport and is reparented to the correct overlay parent.
	if UIManager and UIManager.is_settings_dialog_open():
		UIManager.reopen_settings_dialog()

func _notification(what: int) -> void:
	"""Handle application lifecycle notifications."""
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Remember the current windowed size before shutdown.
		if SystemManager.display:
			SystemManager.display.save_last_window_size()

		# Flush any pending settings changes before shutdown
		if DataManager:
			DataManager.save_settings()

		# The OS asked us to close. Free the entire scene tree now so all node
		# RIDs are released before the rendering server finalizes, then quit.
		# auto_accept_quit is disabled in _ready(), so the default quit() is
		# suppressed and we take over the shutdown sequence.
		var tree = get_tree()
		if tree:
			tree.root.queue_free()
			call_deferred("_deferred_quit")
		return

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

		# Clear emulator validation cache and stale pending launches
		# This handles APK installs that completed while the app was in the background
		if LaunchManager:
			LaunchManager.clear_validation_cache()
			LaunchManager.clear_stale_pending_launches()
		var platforms_view = UIManager.get_settings_dialog_platforms_view()
		if platforms_view and platforms_view.has_method("refresh_cards"):
			platforms_view.refresh_cards()
			print("[Main] Refreshed platform cards after resume")
			# Restore focus to the platform card the user was last interacting with
			if platforms_view.has_method("restore_focus_to_last_active"):
				call_deferred("_restore_platform_focus")

		# Dismiss any stale notifications (e.g., extraction notifications that completed while backgrounded)
		if SystemManager.notifications:
			SystemManager.notifications.dismiss_all_notifications()
			print("[Main] Dismissed all notifications after resume")

func _deferred_quit() -> void:
	var tree = get_tree()
	if tree:
		tree.quit()

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

func _restore_platform_focus() -> void:
	var platforms_view = UIManager.get_settings_dialog_platforms_view()
	if platforms_view and platforms_view.has_method("restore_focus_to_last_active"):
		platforms_view.restore_focus_to_last_active()

func _on_background_state_exited(_game: GameResource, _exit_code: int) -> void:
	"""Handle exiting background state - restore focus."""
	print("[Main] Background state exited - restoring focus")
	# Optional: Remove overlay
	# UIManager.set_dimmed(false)

	# Auto-upload saves after playing (skip during shuffler sessions)
	if LaunchManager.is_session_active():
		print("[Main] Auto-upload skipped: shuffler session active")
	elif _game:
		var emulator_id = LaunchManager.resolve_emulator_for_game(_game)
		print("[Main] Auto-upload check - emulator_id: " + emulator_id)
		if emulator_id != "":
			DataManager.auto_upload_saves_for_game(_game, emulator_id)
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

func _exit_tree() -> void:
	"""Release root-level references so the Main node can be fully freed."""
	# Stop timers so they don't hold references after tree teardown.
	if _zoom_save_timer:
		_zoom_save_timer.stop()

	# Drop cached node references; the actual nodes are freed with the tree.
	_keyboard = null
	_ui_layer = null
	_m3_theme = null

	# Disconnect signals we own.
	if UIManager.is_connected("tab_changed", _on_tab_changed):
		UIManager.tab_changed.disconnect(_on_tab_changed)
	if UIManager.is_connected("settings_dialog_dismissed", _on_settings_dialog_dismissed):
		UIManager.settings_dialog_dismissed.disconnect(_on_settings_dialog_dismissed)
	if DataManager and DataManager.is_connected("apply_preset_end", _on_preset_applied):
		DataManager.apply_preset_end.disconnect(_on_preset_applied)
	if LaunchManager:
		if LaunchManager.is_connected("game_launch_initiated", _on_game_launch_initiated):
			LaunchManager.game_launch_initiated.disconnect(_on_game_launch_initiated)
		if LaunchManager.is_connected("background_state_entered", _on_background_state_entered):
			LaunchManager.background_state_entered.disconnect(_on_background_state_entered)
		if LaunchManager.is_connected("background_state_exited", _on_background_state_exited):
			LaunchManager.background_state_exited.disconnect(_on_background_state_exited)
	var ayn_thor_manager = get_node_or_null("AynThorManager")
	if ayn_thor_manager and ayn_thor_manager.is_connected("screens_swapped", _on_screens_swapped):
		ayn_thor_manager.screens_swapped.disconnect(_on_screens_swapped)
