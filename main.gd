extends Control

const DEBUG_LOG: bool = false
const ShaderPrewarmer := preload("res://utils/shader_prewarmer.gd")
const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

# UI Nodes - initialized in _ready()
var tab_container: TabContainer
var library_background: LibraryBackground
var content_wrapper: Control
var main_content_vbox: VBoxContainer
var root_layout: Control
var view_mode_group: M3ButtonGroup
var toolbar: PanelContainer = null

# Cached reference to the on-screen keyboard (survives reparenting in dual-screen mode)
var _keyboard: PanelContainer = null

# Cached reference to UILayer (survives reparenting in dual-screen mode)
var _ui_layer: CanvasLayer = null


# Zoom state tracking for analog triggers
var _zoom_in_pressed: bool = false
var _zoom_out_pressed: bool = false
var _startup_zoom_sync_active: bool = true

# Current grid snap ratios ( populated when in GRID mode, empty for LIST/CAROUSEL )
var _current_snap_ratios: Array[float] = []

# Focus restoration on app resume (Android)
var _last_focused_index: int = -1

# Debounced zoom save to avoid LIST/CAROUSEL flash during interaction
var _zoom_save_timer: Timer = null
const ZOOM_SAVE_DELAY_MS: int = 1500

# True while hibernated for a game launch (memory trim already applied)
var _trimmed_for_launch: bool = false

# Rendering suspend while the desktop window is unfocused
var _rendering_suspended: bool = false
var _prev_viewport_update_mode: int = -1

# M3 Theme resource (applied to root for fallback native control styling)
var _m3_theme: Theme = null


func _enter_tree():
	# Set the global startup suppression flag as early as possible so that every
	# VirtualScrollGridContainer (including HomeView created during scene load)
	# defers its expensive pool creation and layout until Main settles it once.
	VirtualScrollGridContainer.startup_layout_suppressed = true

func _ready():
	var main_ready_start_us := Time.get_ticks_usec()
	# Disable automatic quit so we can free the scene tree before the rendering
	# server shuts down. Without this, get_tree().quit() exits without destroying
	# nodes, which causes CanvasItem/Texture RID leaks.
	get_tree().auto_accept_quit = false

	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")

	# Preload the Home view scene on a worker thread while the window settles
	ResourceLoader.load_threaded_request("res://view/home_view.tscn")

	if SystemManager.display:
		await SystemManager.display.initial_window_size_settled

	print("[Main] initial_window_size_settled elapsed_us=", Time.get_ticks_usec() - main_ready_start_us)

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
	var phase_start_us := Time.get_ticks_usec()
	UIManager.initialize(
		tab_container,
		library_background,
		content_wrapper,
		main_content_vbox,
		root_layout
	)
	print("[Main] UIManager.initialize elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Create debounced zoom save timer (replaces _process polling)
	_zoom_save_timer = Timer.new()
	_zoom_save_timer.one_shot = true
	_zoom_save_timer.wait_time = ZOOM_SAVE_DELAY_MS / 1000.0
	_zoom_save_timer.timeout.connect(_on_zoom_save_timer_timeout)
	add_child(_zoom_save_timer)

	# Raise toolbar above the card grid (grid has z_index=-1 to let card focus
	# overflow render behind sibling UI; toolbar must sit above that).
	toolbar = main_content_vbox.get_node_or_null("controlbar_background")
	if toolbar:
		toolbar.z_index = OverlayLayers.TOOLBAR_Z

	# Get UI references early so we can connect signals and block the slider during startup settle.
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	view_mode_group = main_content_vbox.get_node("controlbar_background/controlbar_hbox/M3ButtonGroup")

	# Connect zoom slider signals. value_changed is deferred until after startup
	# so the slider cannot override the saved zoom during initial layout.
	if zoom_slider:
		zoom_slider.drag_ended.connect(_on_zoom_changed_finished)

	# Connect view mode buttons
	# Note: UIManager.initialize() reparents ContentWrapper, so we must use the
	# cached main_content_vbox reference instead of a root-relative path.
	view_mode_group.selection_changed.connect(_on_view_mode_changed)

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
		# Hibernate (release reclaimable memory) before the process/intent starts
		LaunchManager.pre_launch_hook = _pre_launch_trim
		LaunchManager.launch_failed_hook = _restore_after_launch

	# Set initial view controls
	phase_start_us = Time.get_ticks_usec()
	_sync_view_mode_button_to_setting()
	_update_ui_for_view("Home")
	print("[Main] view mode setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Apply M3 theme to root for fallback native control styling before grid is shown.
	phase_start_us = Time.get_ticks_usec()
	_apply_m3_theme()
	print("[Main] _apply_m3_theme elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Connect to screen swap signal for dual screen handling
	phase_start_us = Time.get_ticks_usec()
	var ayn_thor_manager = get_node_or_null("AynThorManager")
	if ayn_thor_manager:
		ayn_thor_manager.screens_swapped.connect(_on_screens_swapped)
		# Restore saved screen swap state while layout is still suppressed so the
		# viewport resize does not re-snap the grid away from the saved zoom.
		var swap_setting = DataManager.get_setting("dual_screen_swapped")
		print("[Main] Startup dual_screen_swapped setting: ", swap_setting.value if swap_setting else "NULL")
		# Only restore the swap when dual-screen mode is actually enabled —
		# otherwise the main viewport would be drawn to a released screen.
		var ds_enabled = SystemManager.display.is_dual_screen_enabled() if SystemManager and SystemManager.display else false
		if ds_enabled and swap_setting and swap_setting.value and not ayn_thor_manager.is_swapped:
			print("[Main] Restoring saved screen swap state")
			ayn_thor_manager.swap_screens()
		else:
			print("[Main] Not restoring screen swap (setting=", swap_setting.value if swap_setting else "NULL", ", is_swapped=", ayn_thor_manager.is_swapped, ", ds_enabled=", ds_enabled, ")")
	print("[Main] screen swap setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Single final layout: settle the visible grid(s) now that the window size and
	# screen swap state are final. This is the one layout pass that should happen
	# during startup; any resize events triggered before this point are suppressed.
	# Grids in hidden tabs have no valid size yet and will settle naturally when shown.
	var settle_start_us := Time.get_ticks_usec()
	print("[Main] Unsuppressing grid layout and settling once...")
	VirtualScrollGridContainer.startup_layout_suppressed = false
	var current_view = UIManager.get_current_view()
	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			# Use a deterministic computed size rather than relying on grid.size, which
			# may not have caught up to the post-swap viewport yet. Keep it set so
			# later layout passes keep using the expected viewport rect.
			var grid_settle_start_us := Time.get_ticks_usec()
			var available_size := UIManager.compute_grid_available_size(grid, current_view)
			grid.set_deterministic_available_size(available_size)
			print("[Main] settle: set_deterministic_available_size elapsed_us=", Time.get_ticks_usec() - grid_settle_start_us)
			# The total count arrives asynchronously when the DB cache is cold.
			# Settling with 0 items sizes the card pool to 0 and forces a full
			# post-settle relayout when data lands (collapsed layout + a burst of
			# synchronous card instantiations). Wait for the count first.
			_settle_grid_when_data_ready(grid, current_view, available_size, grid_settle_start_us)
	else:
		print("[Main] No current view to settle")

	# Sync zoom slider to the final grid ratio without reapplying zoom to the grids.
	# Keep the deterministic startup size active so get_snap_ratios() works even
	# though Godot hasn't propagated grid.size yet.
	phase_start_us = Time.get_ticks_usec()
	_sync_zoom_slider_to_current_view()
	print("[Main] _sync_zoom_slider_to_current_view elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	# Save the current level and snapped ratio so the settings stay in sync with
	# the slider and don't hold stale values from a previous viewport size.
	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			if UIManager and UIManager.card_settings_state:
				var level = UIManager.card_settings_state.card_zoom_level
				if level < 0 and _current_snap_ratios.size() > 0:
					level = _find_nearest_snap_index(grid.target_card_width_ratio)
					UIManager.card_settings_state.card_zoom_level = level
				if level >= 0 and DataManager:
					var level_setting = DataManager.get_setting("library_card_zoom_level")
					if level_setting:
						DataManager.set_setting(level, level_setting)
						if _zoom_save_timer:
							_zoom_save_timer.start()
					var ratio_setting = DataManager.get_setting("library_card_zoom")
					if ratio_setting:
						DataManager.set_setting(grid.target_card_width_ratio, ratio_setting)
						if _zoom_save_timer:
							_zoom_save_timer.start()
					if UIManager and UIManager.card_settings_state:
						UIManager.card_settings_state.card_zoom_ratio = grid.target_card_width_ratio
				else:
					_save_zoom_ratio(grid.target_card_width_ratio)
	print("[Main] Settle block total elapsed_us=", Time.get_ticks_usec() - settle_start_us)

	# Compile all shader pipelines in the background so the first scroll/focus
	# doesn't pay lazy-compile hitches. Deferred + internally delayed so first
	# paint and grid settle win the main thread.
	call_deferred("_prewarm_shader_pipelines")

	# Sync the top background mask height to match the control bar.
	# The mask covers the area behind the toolbar so cards scrolling up
	# don't peek through. It sits between the grid (z=-1) and toolbar (z=10).
	# Note: UIManager wraps MainContentVBox in a MarginContainer (dp(16) margins),
	# so the toolbar is offset from ContentWrapper's top-left. We must compute the
	# toolbar's bottom edge in ContentWrapper coordinates, not just use size.y.
	phase_start_us = Time.get_ticks_usec()
	var mask = content_wrapper.get_node_or_null("controlbar_mask")
	if mask and toolbar:
		var _update_mask_height := func():
			var toolbar_bottom: float = toolbar.global_position.y - content_wrapper.global_position.y + toolbar.size.y
			mask.custom_minimum_size.y = toolbar_bottom
			mask.offset_top = 0
			mask.offset_bottom = toolbar_bottom
		toolbar.resized.connect(_update_mask_height)
		# Defer a single update so the toolbar has a chance to size itself; this
		# avoids blocking _ready() while waiting for process frames.
		_update_mask_height.call_deferred()
		_update_controlbar_mask_color()
	print("[Main] mask setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Extract bundled tools on packaged builds (binaries inside the PCK cannot be executed)
	if SystemManager.platform.is_packaged():
		AndroidBinaryExtractor.extract_all_binaries()

	# Check if first-run wizard needs to be shown
	phase_start_us = Time.get_ticks_usec()
	_show_oobe_wizard_if_needed()
	print("[Main] _show_oobe_wizard_if_needed elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Focus the first Home card on startup once data is loaded, and pre-create the
	# settings dialog in the background so opening it later (especially the RomM
	# platform cards screen) is instant.
	var first_run_setting = DataManager.get_setting("first_run_completed")
	if first_run_setting and first_run_setting.value:
		call_deferred("_focus_first_home_card_on_startup")
		call_deferred("_pre_create_settings_dialog")

	# Connect the slider's value_changed now that startup sync is complete; this
	# prevents any slider-initiated zoom change from overriding the saved zoom.
	if zoom_slider and not zoom_slider.value_changed.is_connected(_on_zoom_changed):
		zoom_slider.value_changed.connect(_on_zoom_changed)

	# Startup zoom sync is complete; clear the guard after the current frame so
	# any deferred slider emissions that fire during this frame are ignored.
	call_deferred("_set_startup_zoom_sync_active", false)
	print("[Main] _ready() completed, elapsed_us=", Time.get_ticks_usec() - main_ready_start_us)

	var args := OS.get_cmdline_args()
	var startup_benchmark := args.has("--benchmark-startup")
	var shutdown_benchmark := args.has("--benchmark-shutdown")

	# If the startup benchmark flag is set, log startup and exit through the close
	# handler so we get a clean shutdown and no leaked background threads.
	if startup_benchmark:
		var delay_sec := 0.0
		for arg in args:
			if arg.begins_with("--benchmark-startup-delay="):
				delay_sec = arg.split("=")[1].to_float()
		print("[Main] --benchmark-startup: startup complete, shutdown in ", delay_sec, "s")
		if delay_sec > 0.0:
			# --benchmark-staggered-at=<sec>: enable staggered AFTER startup has
			# settled (mirrors a live menu toggle); bare --benchmark-staggered
			# enables immediately. Same for --benchmark-paginated(-at).
			var staggered_at := -1.0
			var paginated_at := -1.0
			for arg in args:
				if arg.begins_with("--benchmark-staggered-at="):
					staggered_at = arg.split("=")[1].to_float()
				if arg.begins_with("--benchmark-paginated-at="):
					paginated_at = arg.split("=")[1].to_float()
			if args.has("--benchmark-staggered"):
				staggered_at = 0.0
			if args.has("--benchmark-paginated"):
				paginated_at = 0.0
			if staggered_at >= 0.0:
				_benchmark_set_state_delayed(staggered_at, "staggered")
			if paginated_at >= 0.0:
				_benchmark_set_state_delayed(paginated_at, "paginated")
			# --benchmark-scroll-to=<idx>[,back]: force a recycle burst by
			# jumping to an index mid-run ("back" returns to 0 before the dump).
			var scroll_to := -1
			var scroll_back := false
			for arg in args:
				if arg.begins_with("--benchmark-scroll-to="):
					var spec = arg.split("=")[1]
					scroll_to = spec.split(",")[0].to_int()
					scroll_back = spec.contains("back")
			if scroll_to >= 0:
				_benchmark_scroll_sequence(minf(delay_sec - 1.5, 2.5), scroll_to, scroll_back)
			await get_tree().create_timer(delay_sec).timeout
			_dump_grid_debug_state()
		call_deferred("_benchmark_shutdown")
		return

	# If the shutdown benchmark flag is set, trigger the close notification after
	# startup so we can measure shutdown time in an automated way.
	if shutdown_benchmark:
		call_deferred("_benchmark_shutdown")

func _benchmark_set_state_delayed(at_sec: float, what: String) -> void:
	"""Benchmark helper: flip a layout flag via the shared runtime state after a
	delay (no persistence), mirroring a post-settle menu toggle."""
	await get_tree().create_timer(at_sec).timeout
	if not UIManager or not UIManager.card_settings_state:
		return
	if what == "staggered":
		UIManager.card_settings_state.set_grid_staggered(true)
	else:
		UIManager.card_settings_state.set_pagination_enabled(true)
	print("[Main] benchmark: enabled ", what, " at ", at_sec, "s")

func _benchmark_scroll_sequence(at_sec: float, idx: int, and_back: bool) -> void:
	"""Benchmark helper: raw scroll to force card recycling, optionally back.
	idx is interpreted as a pixel-ish target via index->slot scroll math."""
	await get_tree().create_timer(maxf(at_sec, 0.1)).timeout
	var home_view = UIManager.get_view("Home") if UIManager else null
	if not home_view or not home_view.games_grid:
		return
	var grid = home_view.games_grid
	var target = grid.get_centered_scroll_for_index(idx)
	print("[Main] benchmark: raw scroll to ", target, " (idx ", idx, ")")
	grid._scroll_container.scroll_vertical = int(target)
	grid._on_scroll_value_changed(target, true, true)
	if and_back:
		await get_tree().create_timer(0.75).timeout
		if not is_instance_valid(grid):
			return
		print("[Main] benchmark: scroll back to 0")
		grid._scroll_container.scroll_vertical = 0
		grid._on_scroll_value_changed(0.0, true, true)

func _dump_grid_debug_state() -> void:
	"""Benchmark diagnostic: dump the Home grid's layout state after startup."""
	var home_view = UIManager.get_view("Home") if UIManager else null
	if not home_view or not home_view.games_grid:
		print("[GridDump] no home grid")
		return
	var grid = home_view.games_grid
	var info = grid.get_visible_range()
	print("[GridDump] ipl=", grid._get_items_per_line(), " card_size=", grid.card_size, " source_total=", info.get("source_total", -1), " total=", info.get("total", -1), " staggered=", grid.staggered, " last_staggered=", grid._last_layout_staggered, " paginated=", grid.pagination_enabled)
	var flow = grid._flow_container
	print("[GridDump] flow min_size=", flow.custom_minimum_size, " size=", flow.size, " children=", flow.get_child_count(), " active=", grid._active_cards.size())
	var xs: Array = []
	for i in range(mini(14, flow.get_child_count())):
		var c = flow.get_child(i)
		var tag := "SP" if (c.has_meta("page_spacer") or c.has_meta("stagger_spacer")) else str(c.get_meta("virtual_index", -1))
		xs.append("%s@(%d,%d)" % [tag, int(c.position.x), int(c.position.y)])
	print("[GridDump] first children=", xs)

func _benchmark_shutdown() -> void:
	"""Trigger the close notification so we can measure shutdown time automatically."""
	print("[Main] --benchmark-shutdown: triggering close notification")
	get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)

func _set_startup_zoom_sync_active(value: bool) -> void:
	_startup_zoom_sync_active = value

func _update_controlbar_mask_color() -> void:
	var mask = content_wrapper.get_node_or_null("controlbar_mask")
	if mask and mask.material:
		var surface := M3Theme.get_surface()
		var accent := M3Theme.get_primary()
		# Use accent hue, but keep the surface's value and only borrow a small
		# amount of accent saturation so the fade stays subtle in light modes.
		var h := accent.h
		var s: float = lerp(surface.s, accent.s, 0.08)
		var v := surface.v * 0.85
		var fade_color := Color.from_hsv(h, s, v)
		mask.material.set_shader_parameter("fade_color", fade_color)

func _apply_m3_theme() -> void:
	_m3_theme = M3Theme.generate_theme()
	self.theme = _m3_theme

func refresh_theme() -> void:
	# Called by UIManager when theme colors change (dark mode, primary color, etc.)
	_apply_m3_theme()
	_update_controlbar_mask_color()

func refresh_scale() -> void:
	# main.gd bakes no dp-derived sizes itself (the dp(16) margins around
	# MainContentVBox are owned by UIManager); children re-bake their own.
	refresh_theme()

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

func _pre_create_settings_dialog() -> void:
	"""Build the settings dialog eagerly while the home screen is visible so the
	platform cards screen can appear instantly when opened. Waits for a gap in
	user input (5s cap) so the build can't land mid-interaction; the category
	builds themselves spread over frames inside the dialog."""
	for i in range(3):
		await get_tree().process_frame
	var waited_ms := Time.get_ticks_msec()
	while WarmupBudget.input_idle_ms() < 500 and Time.get_ticks_msec() - waited_ms < 5000:
		await get_tree().process_frame
	if UIManager:
		var start_us := Time.get_ticks_usec()
		UIManager.pre_create_settings_dialog()
		print("[Main] pre_create_settings_dialog (initial burst) elapsed_us=", Time.get_ticks_usec() - start_us)

func _on_settings_button_pressed() -> void:
	UIManager.show_settings_dialog()

func _on_more_button_pressed() -> void:
	var menu = M3Menu.new()
	var current_view = UIManager.get_current_view()
	var is_grid = false
	var is_horizontal = false
	var pagination_enabled = false
	var staggered_enabled = false

	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			is_grid = grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID
			is_horizontal = not grid.grid_vertical

	# Read the check state from the persisted setting (the shared source of
	# truth across all views), not from a single grid's applied state.
	if DataManager:
		var pagination_setting = DataManager.get_setting("library_pagination_view")
		if pagination_setting and pagination_setting.value is bool:
			pagination_enabled = pagination_setting.value
		var staggered_setting = DataManager.get_setting("library_grid_staggered")
		if staggered_setting and staggered_setting.value is bool:
			staggered_enabled = staggered_setting.value

	# Grid Settings submenu (independent toggles — no radio group)
	var grid_settings = M3Menu.new()
	grid_settings.auto_free = false
	grid_settings.add_check_item("Horizontal Grid", is_horizontal, _toggle_horizontal_grid)
	if not is_grid:
		grid_settings.get_item(grid_settings.get_item_count() - 1).disabled = true
	grid_settings.add_check_item("Pagination View", pagination_enabled, _toggle_pagination_view)
	if not is_grid:
		grid_settings.get_item(grid_settings.get_item_count() - 1).disabled = true
	grid_settings.add_check_item("Staggered Grid", staggered_enabled, _toggle_staggered_grid)
	if not is_grid or is_horizontal:
		# Staggered applies to the vertical grid only.
		grid_settings.get_item(grid_settings.get_item_count() - 1).disabled = true
	menu.add_submenu_item("Grid Settings", grid_settings, "view-grid")

	# Focus Centering submenu
	var focus_centering = 0
	if DataManager:
		var centering_setting = DataManager.get_setting("library_focus_centering")
		if centering_setting and centering_setting.value is int:
			focus_centering = centering_setting.value

	var centering_submenu = M3Menu.new()
	centering_submenu.auto_free = false
	centering_submenu.radio_group = true
	centering_submenu.add_check_item("Margin", focus_centering == 0, func(): _set_focus_centering(0))
	centering_submenu.add_check_item("Center", focus_centering == 1, func(): _set_focus_centering(1))
	menu.add_submenu_item("Focus Centering", centering_submenu, "crosshairs")

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

func _set_focus_centering(mode: int) -> void:
	if DataManager:
		var setting = DataManager.get_setting("library_focus_centering")
		if setting:
			DataManager.set_setting(mode, setting)
			DataManager.save_settings()

func _toggle_pagination_view() -> void:
	var target_enabled = true
	if DataManager:
		var setting = DataManager.get_setting("library_pagination_view")
		if setting and setting.value is bool:
			target_enabled = not setting.value

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = _get_focused_card_index()

	# Persist; CardSettingsState propagates the change to all grid views.
	if DataManager:
		var setting = DataManager.get_setting("library_pagination_view")
		if setting:
			DataManager.set_setting(target_enabled, setting)
			DataManager.save_settings()

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

func _toggle_staggered_grid() -> void:
	var target_enabled = true
	if DataManager:
		var setting = DataManager.get_setting("library_grid_staggered")
		if setting and setting.value is bool:
			target_enabled = not setting.value

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = _get_focused_card_index()

	# Persist; CardSettingsState propagates the change to all grid views.
	if DataManager:
		var setting = DataManager.get_setting("library_grid_staggered")
		if setting:
			DataManager.set_setting(target_enabled, setting)
			DataManager.save_settings()

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

func _toggle_horizontal_grid() -> void:
	var target_vertical = true
	var current_view = UIManager.get_current_view()
	if current_view:
		var grid = _get_view_grid(current_view)
		if grid:
			target_vertical = not grid.grid_vertical

	# Remember which card had focus so we can restore it after re-layout
	var focused_index = _get_focused_card_index()

	# Apply to all grid views
	if UIManager:
		for view_name in UIManager.view._views.keys():
			if not _is_grid_view(view_name):
				continue
			var view = UIManager.get_view(view_name)
			if view:
				var grid = _get_view_grid(view)
				if grid:
					grid.grid_vertical = target_vertical

	# Persist. The zoom level index is orientation-relative (columns vs rows),
	# so sync it to the post-flip layout BEFORE the LAYOUT change propagates —
	# otherwise the batch would re-apply the stale index against the new
	# orientation's stop list and clobber the size-preserving derivation above.
	var new_level := -1
	if current_view:
		var current_grid = _get_view_grid(current_view)
		if current_grid:
			new_level = current_grid.get_zoom_level()
	if new_level >= 0 and UIManager and UIManager.card_settings_state:
		UIManager.card_settings_state.card_zoom_level = new_level
	if DataManager:
		var setting = DataManager.get_setting("library_grid_vertical")
		if setting:
			DataManager.set_setting(target_vertical, setting)
		if new_level >= 0:
			var level_setting = DataManager.get_setting("library_card_zoom_level")
			if level_setting:
				DataManager.set_setting(new_level, level_setting)
		DataManager.save_settings()

	# Refresh zoom slider so it uses snap ratios for the new orientation
	if current_view:
		_update_ui_for_view(current_view.view_name)

	# Restore focus after the grid has re-laid out
	if focused_index >= 0:
		call_deferred("_restore_focus_to_card", focused_index, true)

func _is_grid_view(view_name: String) -> bool:
	return view_name == "Home" or view_name == "Library" or view_name == "Favorites" or view_name.begins_with("Collection_")

func _on_tab_changed(view_name: String):
	# Sync slider to the current view's grid; do not re-apply saved zoom here,
	# because that overrides the live zoom whenever tabs are switched (e.g. when
	# adding/removing a collection pin).
	_update_ui_for_view(view_name)

func _on_viewport_resized(_new_size: Vector2) -> void:
	"""Re-sync zoom slider after viewport resize. The grid re-snaps its zoom
	in _on_resize_debounced(), but the slider stops and position are owned
	by main.gd and must be updated to match."""
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	var current_view = UIManager.get_current_view()
	if not current_view:
		return
	var view_name = current_view.view_name
	if not _is_grid_view(view_name):
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
		var level = UIManager.card_settings_state.card_zoom_level if UIManager and UIManager.card_settings_state else -1
		if level < 0:
			level = _find_nearest_snap_index(games_grid.target_card_width_ratio)
		level = clampi(level, 0, _current_snap_ratios.size() - 1)
		zoom_slider.set_value_no_signal(level)
	else:
		zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
	zoom_slider.set_block_signals(false)

func _update_ui_for_view(view_name: String):
	var is_grid = _is_grid_view(view_name)
	# Show/hide view mode buttons only on grid views
	if view_mode_group:
		view_mode_group.visible = is_grid

	# Show/hide zoom slider only on grid views
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if zoom_slider:
		zoom_slider.visible = is_grid

	# Skip zoom slider value/stops sync during startup; final slider sync is handled
	# explicitly after the grid has settled so the stops are based on the real window size.
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return

	# Update zoom slider to match current view's grid
	if zoom_slider and is_grid:
		var view = UIManager.get_view(view_name)
		if view:
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
					var level = UIManager.card_settings_state.card_zoom_level if UIManager and UIManager.card_settings_state else -1
					if level < 0:
						level = _find_nearest_snap_index(games_grid.target_card_width_ratio)
					level = clampi(level, 0, _current_snap_ratios.size() - 1)
					zoom_slider.set_value_no_signal(level)
				else:
					zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)
				zoom_slider.set_block_signals(false)

func _update_zoom_slider_stops(zoom_slider: M3Slider, games_grid: VirtualScrollGridContainer) -> void:
	"""Update slider stops to match the grid's calculated snap levels."""
	var snap_ratios = games_grid.get_snap_ratios_ascending()
	# Index 0 = smallest ratio (zoomed out, most items per line)
	# and max index = largest ratio (zoomed in, fewest items per line)

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

	# Snapshot the grid zoom level before leaving GRID so returning restores it
	# exactly, even if the user never dragged the zoom slider while in grid mode
	# (in which case no level was ever persisted).
	if new_mode != VirtualScrollGridContainer.ViewMode.GRID and UIManager and UIManager.card_settings_state:
		if UIManager.card_settings_state.card_zoom_level < 0:
			var current_view = UIManager.get_current_view()
			var current_grid = _get_view_grid(current_view) if current_view else null
			if current_grid:
				var snapshot: int = current_grid.get_zoom_level()
				if snapshot >= 0:
					UIManager.card_settings_state.card_zoom_level = snapshot

	# Apply to all grid views
	if UIManager:
		for view_name in UIManager.view._views.keys():
			if not _is_grid_view(view_name):
				continue
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
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	if _startup_zoom_sync_active:
		print("[Main] _on_zoom_changed ignored during startup sync: value=", value)
		return
	print("[Main] _on_zoom_changed: value=", value, " snap_ratios=", _current_snap_ratios)

	if _current_snap_ratios.size() > 0:
		# Grid mode: value is an integer level. Keep CardSettingsState in sync
		# so lazily created views inherit the current level.
		var level := clampi(int(round(value)), 0, _current_snap_ratios.size() - 1)
		if UIManager and UIManager.card_settings_state:
			UIManager.card_settings_state.card_zoom_level = level
			UIManager.card_settings_state.card_zoom_ratio = _current_snap_ratios[level]

		# Apply the same level to ALL grid views. Each grid resolves the level
		# to its own items-per-line stop so the zoom level stays consistent.
		# Hidden views only get the level stamped; running their full layout
		# (card adds, effect rebuilds, data requests) while invisible multiplies
		# the zoom cost by every instantiated view. They settle on next show
		# via View.on_view_show -> recalculate_layout_with_size.
		if UIManager:
			for view_name in UIManager.view._views.keys():
				if not _is_grid_view(view_name):
					continue
				var view = UIManager.get_view(view_name)
				if view:
					var games_grid = _get_view_grid(view)
					if games_grid:
						if view.is_visible_in_tree():
							games_grid.set_zoom_level(level)
						else:
							games_grid.stamp_zoom_level(level)
		else:
			return
		return

	# List/Carousel mode: value is the actual ratio (stored separately from the
	# grid zoom so the modes never pollute each other's memory).
	var actual_zoom = clampf(value, 0.05, 0.5)
	if UIManager and UIManager.card_settings_state:
		UIManager.card_settings_state.card_zoom_list_ratio = actual_zoom

	if UIManager:
		for view_name in UIManager.view._views.keys():
			if not _is_grid_view(view_name):
				continue
			var view = UIManager.get_view(view_name)
			if view:
				var games_grid = _get_view_grid(view)
				if games_grid:
					if view.is_visible_in_tree():
						if not is_equal_approx(actual_zoom, games_grid.target_card_width_ratio):
							games_grid.target_card_width_ratio = actual_zoom
					else:
						games_grid.stamp_zoom_ratio(actual_zoom)

func _on_zoom_changed_finished(value_changed: bool):
	"""Called when drag ends - saves the current slider value to settings."""
	if not value_changed or VirtualScrollGridContainer.startup_layout_suppressed:
		return
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if not zoom_slider:
		return

	if _current_snap_ratios.size() > 0:
		# Grid mode: save the integer level.
		var level = clampi(int(round(zoom_slider.value)), 0, _current_snap_ratios.size() - 1)
		if DataManager:
			var zoom_level_setting = DataManager.get_setting("library_card_zoom_level")
			if zoom_level_setting:
				DataManager.set_setting(level, zoom_level_setting)
				if _zoom_save_timer:
					_zoom_save_timer.start()
			var zoom_setting = DataManager.get_setting("library_card_zoom")
			if zoom_setting:
				DataManager.set_setting(_current_snap_ratios[level], zoom_setting)
				if _zoom_save_timer:
					_zoom_save_timer.start()
	else:
		# List/Carousel mode: save the per-mode ratio.
		var saved_value = zoom_slider.value
		if DataManager:
			var zoom_setting = DataManager.get_setting("library_card_zoom_list")
			if zoom_setting:
				DataManager.set_setting(saved_value, zoom_setting)
				if _zoom_save_timer:
					_zoom_save_timer.start()

func _on_zoom_save_timer_timeout() -> void:
	if DataManager:
		DataManager.save_settings()

func _save_zoom_ratio(ratio: float) -> void:
	"""Persist the given zoom ratio to the library_card_zoom setting."""
	if not DataManager:
		return
	# Don't save a zoom derived from a headless / zero-size window; it would
	# clamp to the maximum and corrupt the user's saved zoom.
	var win_size = DisplayServer.window_get_size()
	if win_size == Vector2i.ZERO or OS.get_cmdline_args().has("--benchmark-startup"):
		return
	var zoom_setting = DataManager.get_setting("library_card_zoom")
	if not zoom_setting:
		return
	var clamped_ratio = clampf(ratio, 0.05, 0.5)
	if is_equal_approx(zoom_setting.value, clamped_ratio):
		return
	DataManager.set_setting(clamped_ratio, zoom_setting)
	if _zoom_save_timer:
		_zoom_save_timer.start()

func _get_view_grid(view: View) -> VirtualScrollGridContainer:
	# Standard structure: MarginContainer/VBoxContainer/VirtualScrollGridContainer
	if view.has_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer"):
		return view.get_node("MarginContainer/VBoxContainer/VirtualScrollGridContainer") as VirtualScrollGridContainer
	return null

# Grid available-size computation now lives in UIManager so it can be reused at
# startup, on tab changes, after nav rebuilds, after sync, and after screen swaps.

func _load_and_apply_saved_zoom() -> void:
	"""Apply the saved zoom level/ratio to all grids and sync the slider.

	Used at runtime (e.g. after a preset is applied) when the grid may already
	be visible with a different zoom. Startup layout now applies the saved zoom
	via CardSettingsState before the grid is laid out.
	"""
	if VirtualScrollGridContainer.startup_layout_suppressed:
		return
	if not DataManager:
		return

	var zoom_level_setting = DataManager.get_setting("library_card_zoom_level")
	var zoom_setting = DataManager.get_setting("library_card_zoom")
	var layout_mode_setting = DataManager.get_setting("library_layout_mode")
	var is_grid: bool = layout_mode_setting.value == 0 if layout_mode_setting else true

	if is_grid and zoom_level_setting and zoom_level_setting.value is int and zoom_level_setting.value >= 0:
		var level: int = zoom_level_setting.value
		if UIManager and UIManager.card_settings_state:
			UIManager.card_settings_state.card_zoom_level = level

		# Apply the same level to all grid views.
		if UIManager:
			for view_name in UIManager.view._views.keys():
				if not _is_grid_view(view_name):
					continue
				var view = UIManager.get_view(view_name)
				if view:
					var games_grid = _get_view_grid(view)
					if games_grid:
						games_grid.set_zoom_level(level)

	elif not is_grid:
		# List/Carousel: apply the per-mode ratio.
		var list_setting = DataManager.get_setting("library_card_zoom_list")
		if list_setting:
			var saved_zoom = list_setting.value
			if UIManager and UIManager.card_settings_state:
				UIManager.card_settings_state.card_zoom_list_ratio = saved_zoom

			# Apply saved list/carousel zoom to all grid views
			if UIManager:
				for view_name in UIManager.view._views.keys():
					if not _is_grid_view(view_name):
						continue
					var view = UIManager.get_view(view_name)
					if view:
						var games_grid = _get_view_grid(view)
						if games_grid:
							games_grid.target_card_width_ratio = saved_zoom

	elif zoom_setting:
		# GRID without a saved level: legacy ratio fallback (grid derives N).
		var saved_zoom = zoom_setting.value

		# Apply saved zoom to all grid views
		if UIManager:
			for view_name in UIManager.view._views.keys():
				if not _is_grid_view(view_name):
					continue
				var view = UIManager.get_view(view_name)
				if view:
					var games_grid = _get_view_grid(view)
					if games_grid:
						games_grid.target_card_width_ratio = saved_zoom

	# Set zoom slider to the current level (grid) or actual grid ratio (list/carousel)
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if zoom_slider:
		var current_view = UIManager.get_current_view()
		var games_grid = _get_view_grid(current_view) if current_view else null
		if games_grid:
			_update_zoom_slider_stops(zoom_slider, games_grid)
		# Use the current level in grid mode so the slider reflects the saved level.
		var actual_zoom: float
		if games_grid:
			actual_zoom = games_grid.target_card_width_ratio
		elif is_grid:
			actual_zoom = zoom_setting.value if zoom_setting else 0.25
		else:
			var list_zoom_setting = DataManager.get_setting("library_card_zoom_list")
			actual_zoom = list_zoom_setting.value if list_zoom_setting else 0.25
		zoom_slider.set_block_signals(true)
		if _current_snap_ratios.size() > 0:
			var level = UIManager.card_settings_state.card_zoom_level if UIManager and UIManager.card_settings_state else -1
			if level < 0:
				level = _find_nearest_snap_index(actual_zoom)
			level = clampi(level, 0, _current_snap_ratios.size() - 1)
			zoom_slider.set_value_no_signal(level)
		else:
			zoom_slider.set_value_no_signal(actual_zoom)
		zoom_slider.set_block_signals(false)

func _sync_zoom_slider_to_current_view() -> void:
	"""Sync the zoom slider to the current grid's zoom level.

	Does not modify the grid's target_card_width_ratio; use this at startup
	after the grid has settled. The caller is responsible for blocking the
	slider's value_changed signal around this call.
	"""
	var zoom_slider = main_content_vbox.get_node_or_null("controlbar_background/controlbar_hbox/M3Slider_Zoom")
	if not zoom_slider:
		return

	var current_view = UIManager.get_current_view()
	var games_grid = _get_view_grid(current_view) if current_view else null
	if not games_grid:
		return

	print("[Main] _sync_zoom_slider_to_current_view: view=", current_view.view_name if current_view else "null", " grid_ratio=", games_grid.target_card_width_ratio)
	_update_zoom_slider_stops(zoom_slider, games_grid)
	if _current_snap_ratios.size() > 0:
		var level = UIManager.card_settings_state.card_zoom_level if UIManager and UIManager.card_settings_state else -1
		if level < 0:
			level = _find_nearest_snap_index(games_grid.target_card_width_ratio)
		level = clampi(level, 0, _current_snap_ratios.size() - 1)
		print("[Main] syncing slider to level=", level, " ratio=", _current_snap_ratios[level])
		zoom_slider.set_value_no_signal(level)
	else:
		zoom_slider.set_value_no_signal(games_grid.target_card_width_ratio)

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

func _prewarm_shader_pipelines() -> void:
	# Wait out the startup critical path (first paint, grid settle, focus
	# restore) before spending frames on pipeline compilation.
	await get_tree().create_timer(1.0).timeout
	if not is_inside_tree():
		return
	ShaderPrewarmer.prewarm(get_tree())

func _settle_grid_when_data_ready(grid: VirtualScrollGridContainer, view: View, available_size: Vector2, settle_start_us: int, attempts: int = 0) -> void:
	"""Defer the pool build + startup settle until the grid's total count is
	known (it arrives asynchronously when the DB cache is cold at startup)."""
	if not is_instance_valid(grid):
		return
	var source_total: int = grid.get_visible_range().get("source_total", 0)
	# Empty-library case: the view's count load has resolved with 0 items —
	# settle empty rather than polling forever.
	var count_resolved_empty := false
	if source_total <= 0:
		var pending = view.get("_total_count_load_pending")
		var loading = view.get("_is_loading")
		if pending is bool and not pending and loading is bool and not loading:
			count_resolved_empty = true
	if source_total <= 0 and not count_resolved_empty and attempts < 120:
		await get_tree().process_frame
		_settle_grid_when_data_ready(grid, view, available_size, settle_start_us, attempts + 1)
		return
	if attempts > 0:
		print("[Main] settle waited ", attempts, " frames for grid data (source_total=", source_total, ", count_resolved_empty=", count_resolved_empty, ")")
	var sub_start_us := Time.get_ticks_usec()
	grid._instantiate_card_pool()
	print("[Main] settle: _instantiate_card_pool elapsed_us=", Time.get_ticks_usec() - sub_start_us)
	sub_start_us = Time.get_ticks_usec()
	grid.settle_startup_with_buffer(0)
	print("[Main] settle: settle_startup_with_buffer elapsed_us=", Time.get_ticks_usec() - sub_start_us)
	print("[Main] Settled grid for ", view.view_name, " target_ratio=", grid.target_card_width_ratio, " available=", available_size, " elapsed_us=", Time.get_ticks_usec() - settle_start_us)
	# Open the warmup gates (platform card pool waits on this) and start the
	# countdown out of startup budgeting back to steady-state.
	WarmupBudget.notify_home_grid_settled()
	await get_tree().create_timer(2.0).timeout
	WarmupBudget.set_startup_mode(false)

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home destination in the M3 nav."""
	var home_button = UIManager.find_home_button()
	if DEBUG_LOG: print("[Main] find_home_button returned: ", home_button)
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		if DEBUG_LOG: print("[Main] Grabbing focus on: ", home_button.name)
		home_button.grab_focus()
	else:
		if DEBUG_LOG: print("[Main] Could not grab focus — home_button invalid or focus disabled")

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
	if DEBUG_LOG: print("[Main] _handle_ui_cancel: _keyboard=", _keyboard, " visible=", str(_keyboard.visible) if _keyboard else "N/A", " in_second_viewport=", str(UIManager._keyboard_is_in_second_viewport) if UIManager else "N/A")
	if _keyboard and _keyboard.visible:
		# If keyboard is in SecondViewport, it won't receive ui_cancel (controller input goes to MainViewport)
		# So we need to manually dismiss it here
		if UIManager and UIManager._keyboard_is_in_second_viewport:
			if DEBUG_LOG: print("[Main] Manually dismissing keyboard in SecondViewport")
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

	# If a side sheet (library filters, etc.) is open, let it dismiss itself
	if M3Overlay.is_showing("side_sheet"):
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
				if DEBUG_LOG: print("[Main] _handle_ui_cancel: escaped locked grid to nav destination: ", nav_dest.name)
			else:
				var home_button = UIManager.find_home_button()
				if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
					if SystemManager.audio:
						SystemManager.audio.play_sfx("return")
					home_button.grab_focus()
					if DEBUG_LOG: print("[Main] _handle_ui_cancel: escaped locked grid to home button")
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
	if event is InputEventKey or event is InputEventJoypadButton \
			or event is InputEventMouseButton or event is InputEventMouseMotion \
			or event is InputEventScreenTouch or event is InputEventScreenDrag:
		WarmupBudget.note_input()
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
	if _startup_zoom_sync_active:
		return
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
			# Save the integer level for grid mode.
			if DataManager:
				var zoom_level_setting = DataManager.get_setting("library_card_zoom_level")
				if zoom_level_setting:
					DataManager.set_setting(new_index, zoom_level_setting)
					if _zoom_save_timer:
						_zoom_save_timer.start()
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

	# Grab focus on the card directly (M3Card-based GameCard has no CardInput sub-node).
	# Suppress the container's follow-focus smooth scroll: the grid already ran
	# scroll_to_index_and_focus for this zoom tick, and an unsuppressed provider
	# scroll here overrides in-flight wheel scrolling and spams value_changed.
	if card is Control and card.focus_mode != Control.FOCUS_NONE:
		card.set_meta("_suppress_smooth_scroll", true)
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

	# The navigation bar sizes its items from the parent width, which can be
	# stale after a screen swap. Force a deferred nav/grid refresh once the new
	# SubViewport size has propagated.
	if UIManager and UIManager.navigation:
		UIManager.navigation.call_deferred("refresh_for_screen_swap")

func _suspend_rendering_if_hidden() -> void:
	"""Only suspend when the window is actually minimized/hidden — plain
	alt-tab keeps rendering so the app stays live when visible again."""
	var window := get_window()
	if window and (window.mode == Window.MODE_MINIMIZED or not window.visible):
		_suspend_rendering()

func _suspend_rendering() -> void:
	"""Stop issuing frames while the desktop window is minimized/hidden. The
	SceneTree keeps processing (downloads, poll timers, sync all keep running);
	only the renderer and the perpetual focus-ring idle animation are halted."""
	if _rendering_suspended:
		return
	if SystemManager and SystemManager.platform and SystemManager.platform.is_android():
		return
	_rendering_suspended = true
	_prev_viewport_update_mode = RenderingServer.viewport_get_update_mode(get_tree().root.get_viewport_rid())
	RenderingServer.viewport_set_update_mode(get_tree().root.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_DISABLED)
	if UIManager and UIManager.focus:
		UIManager.focus.suspend_idle_animation()
	print("[Main] Rendering suspended (window unfocused)")

func _resume_rendering() -> void:
	if not _rendering_suspended:
		return
	_rendering_suspended = false
	if _prev_viewport_update_mode >= 0:
		RenderingServer.viewport_set_update_mode(get_tree().root.get_viewport_rid(), _prev_viewport_update_mode)
		_prev_viewport_update_mode = -1
	if UIManager and UIManager.focus:
		UIManager.focus.resume_idle_animation()
	print("[Main] Rendering resumed (window focused)")

func _notification(what: int) -> void:
	"""Handle application lifecycle notifications."""
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		# Defer one frame so the window manager state (minimize/hide) has settled
		call_deferred("_suspend_rendering_if_hidden")
		return

	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_resume_rendering()
		return

	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		var close_start_us := Time.get_ticks_usec()
		print("[Main] NOTIFICATION_WM_CLOSE_REQUEST: shutdown started")

		# Hide/minimize the window immediately on desktop so the app feels closed,
		# even if cleanup continues for a few more frames. Skip on Android because mobile
		# has no minimize-to-taskbar concept, and skip in headless mode.
		if not OS.has_feature("headless") and SystemManager.platform and not SystemManager.platform.is_android():
			get_window().mode = Window.MODE_MINIMIZED
		print("[Main] Window hidden/minimized, running cleanup...")

		# Remember the current windowed size before shutdown.
		var window_save_start_us := Time.get_ticks_usec()
		if SystemManager.display:
			SystemManager.display.save_last_window_size()
		print("[Main] save_last_window_size elapsed_us=", Time.get_ticks_usec() - window_save_start_us)

		# Flush any pending settings changes before shutdown
		var settings_save_start_us := Time.get_ticks_usec()
		if DataManager:
			DataManager.save_settings()
		print("[Main] save_settings elapsed_us=", Time.get_ticks_usec() - settings_save_start_us)

		# Pre-clean heavy resources and background work before freeing the tree.
		# This reduces the number of synchronous RenderingServer.free_rid() calls
		# and thread-join waits during root teardown.
		_pre_shutdown_cleanup()

		# The OS asked us to close. Free the entire scene tree now so all node
		# RIDs are released before the rendering server finalizes, then quit.
		# auto_accept_quit is disabled in _ready(), so the default quit() is
		# suppressed and we take over the shutdown sequence.
		var tree = get_tree()
		if tree:
			tree.root.queue_free()
			call_deferred("_deferred_quit")

		print("[Main] NOTIFICATION_WM_CLOSE_REQUEST total elapsed_us=", Time.get_ticks_usec() - close_start_us)
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

func _pre_shutdown_cleanup() -> void:
	"""Release heavy resources and stop background work before the tree is freed.

	Doing this before tree.root.queue_free() reduces the synchronous work done
	during node teardown, which is the main source of slow app shutdown.
	"""
	var cleanup_start_us := Time.get_ticks_usec()
	print("[Main] Pre-shutdown cleanup starting")

	# Stop any pending debounced settings save.
	if _zoom_save_timer:
		_zoom_save_timer.stop()

	# Cancel active downloads and clear the download queue.
	# This stops HTTPRequest nodes and chunked-download timers.
	var download_start_us := Time.get_ticks_usec()
	if SystemManager and SystemManager.download:
		SystemManager.download.shutdown()
	print("[Main] download shutdown elapsed_us=", Time.get_ticks_usec() - download_start_us)

	# Cancel active HTTP requests and free the request pool.
	var network_start_us := Time.get_ticks_usec()
	if SystemManager and SystemManager.network:
		SystemManager.network.shutdown()
	print("[Main] network shutdown elapsed_us=", Time.get_ticks_usec() - network_start_us)

	# Release card pools, overlays, pending image work, and static caches.
	# Shared with the launch-hibernation trim so pooled cards (and their
	# RenderingServer items) are freed before the root is queue_freed.
	_release_heavy_resources("shutdown")

	# Stop all background worker threads (DB, image, download, extraction, OS execute).
	# After this point SystemManager.memory static methods will safely no-op.
	var memory_start_us := Time.get_ticks_usec()
	if SystemManager and SystemManager.memory:
		MemorySubManager.shutdown()
	print("[Main] memory shutdown elapsed_us=", Time.get_ticks_usec() - memory_start_us)

	print("[Main] Pre-shutdown cleanup elapsed_us=", Time.get_ticks_usec() - cleanup_start_us)

func _deferred_quit() -> void:
	var tree = get_tree()
	if tree:
		tree.quit()

# ==================== LAUNCH HIBERNATION ====================

func _pre_launch_trim(_game: GameResource) -> void:
	"""Release reclaimable memory before the game process starts (and before
	Android suspends us), then yield frames so deferred frees fully complete."""
	_log_rss("pre-launch trim start")
	_trim_memory("launch")
	# queue_free()'d nodes and RenderingServer RIDs release on frame boundaries;
	# yield so the trim is fully materialized before the process/intent starts.
	await get_tree().process_frame
	await get_tree().process_frame
	_log_rss("pre-launch trim done")

func _trim_memory(reason: String) -> void:
	"""Idempotent entry point for launch hibernation."""
	if _trimmed_for_launch:
		return
	_trimmed_for_launch = true
	_release_heavy_resources(reason)

func _release_heavy_resources(reason: String) -> void:
	"""Free every reclaimable memory hold that existing lazy paths can rebuild.
	Downloads, worker threads, and in-flight network requests are untouched."""
	var trim_start_us := Time.get_ticks_usec()
	print("[Main] Memory trim (", reason, ") starting")

	# Stop periodic work that wakes the main thread while backgrounded.
	if UIManager:
		UIManager.set_status_bar_polling(false)
	if SystemManager and SystemManager.notifications:
		SystemManager.notifications.dismiss_all_notifications()

	# Pools release their texture refs before the cache wipe below.
	var pool_start_us := Time.get_ticks_usec()
	if UIManager and UIManager.view:
		for grid in UIManager.view.get_all_grids():
			grid.clear_pool()
	PlatformCardPool.clear()
	print("[Main] trim grid pools elapsed_us=", Time.get_ticks_usec() - pool_start_us)

	# Overlays rebuild lazily through their existing show paths.
	if UIManager and UIManager.overlay:
		UIManager.overlay.release_settings_dialog()
		UIManager.overlay.clear_game_details_sheet_content()
	LibraryFilterSheet.cleanup_instance()

	# Drop queued cover/prefetch work; in-flight tasks and downloads continue.
	# At shutdown the tree is dying, so drained waiters must not be called back.
	MemorySubManager.clear_pending_image_tasks(reason != "shutdown")

	# Static caches; covers re-decode from the disk cache on demand.
	var cache_start_us := Time.get_ticks_usec()
	MemorySubManager.clear_texture_cache()
	GameCard.clear_platform_icon_cache()
	EffectBase.clear_shared_caches()
	EffectStack.clear_script_cache()
	M3Theme.clear_theme_cache()
	LaunchTransitionOverlay._clear_source_override()
	M3NavigationDestination.clear_shared_stylebox()
	M3MenuRenderer.clear_shared_stylebox()
	print("[Main] trim static caches elapsed_us=", Time.get_ticks_usec() - cache_start_us)

	if SystemManager and SystemManager.network:
		SystemManager.network.clear_response_cache()

	print("[Main] Memory trim (", reason, ") total elapsed_us=", Time.get_ticks_usec() - trim_start_us)

func _restore_after_launch() -> void:
	"""Undo launch hibernation. Pools, covers, and the settings dialog all
	rebuild through existing lazy paths; only polling needs an explicit nudge."""
	if not _trimmed_for_launch:
		return
	_trimmed_for_launch = false
	if UIManager:
		UIManager.set_status_bar_polling(true)
	_log_rss("post-resume")

func _log_rss(label: String) -> void:
	var rss_kb := _get_process_rss_kb()
	if rss_kb >= 0:
		print("[Main] VmRSS (", label, "): ", snappedf(rss_kb / 1024.0, 0.1), " MB")
	else:
		print("[Main] Resource count (", label, "): ", Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))

func _get_process_rss_kb() -> int:
	"""VmRSS from /proc/self/status (Linux/Android); -1 where unavailable.
	procfs entries fail stat-style existence checks, so open directly."""
	var f := FSM.open_file_read("/proc/self/status")
	if not f:
		return -1
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			var parts := line.split(" ", false)
			f.close()
			if parts.size() >= 2:
				return parts[1].to_int()
			return -1
	f.close()
	return -1

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
	# Fallback trim for launch paths that bypass pre_launch_hook (e.g. standalone
	# emulator launches); no-op if the pre-launch trim already ran.
	_trim_memory("background")
	# Optional: Show overlay or dim the UI
	# UIManager.set_dimmed(true)

func _restore_platform_focus() -> void:
	var platforms_view = UIManager.get_settings_dialog_platforms_view()
	if platforms_view and platforms_view.has_method("restore_focus_to_last_active"):
		platforms_view.restore_focus_to_last_active()

func _on_background_state_exited(_game: GameResource, _exit_code: int) -> void:
	"""Handle exiting background state - restore focus."""
	print("[Main] Background state exited - restoring focus")
	_restore_after_launch()
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
