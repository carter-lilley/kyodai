extends Manager

# UIManager - Facade for UI orchestration.
# Child managers own views, navigation, hero/background, overlays, theme, and dual-screen logic.

@onready var view = $ViewSubManager
@onready var navigation = $NavigationSubManager
@onready var overlay = $OverlaySubManager
@onready var theme = $ThemeSubManager
@onready var dual_screen = $DualScreenSubManager

func _ready() -> void:
	PlatformCardPool.process(0.0)

func _process(delta: float) -> void:
	PlatformCardPool.process(delta)

# Cached references passed during initialization
var _library_background: LibraryBackground = null

# Centralized card/grid settings state. Owned by UIManager; consumers read this
# instead of querying DataManager directly for card/grid settings.
var card_settings_state: CardSettingsState = null

# Layout management - NEW ARCHITECTURE
var _root_control: Control = null  # Plain control, never replaced
var _inner_layout: BoxContainer = null  # VBox or HBox, replaced only on orientation change
var _main_content_vbox: VBoxContainer = null  # Never replaced, never cleared
var _content_wrapper: Control = null

# Cached on-screen keyboard reference (survives reparenting in dual-screen mode)
var _onscreen_keyboard: PanelContainer = null

# Focus lock state: when a locked grid owns focus, all other focusable controls
# in the scene are temporarily set to FOCUS_NONE so directional input cannot leak.
var _focus_lock_active: bool = false
var _focus_locked_grid: VirtualScrollGridContainer = null
var _saved_focus_modes: Dictionary[NodePath, int] = {}

# Proxy for legacy external access to dual-screen keyboard state.
var _keyboard_is_in_second_viewport: bool:
	get:
		if dual_screen:
			return dual_screen._keyboard_is_in_second_viewport
		return false

# Signals
signal modal_shown(modal_id: String)
signal modal_dismissed(modal_id: String)
signal modal_item_selected(item_id: String, context: Dictionary)
@warning_ignore("unused_signal")
signal tab_changed(view_name: String)
signal layout_changed(position: String)
signal settings_dialog_dismissed()

func initialize(
	tab_container: TabContainer,
	library_background: LibraryBackground,
	content_wrapper: Control,
	main_content_vbox: VBoxContainer,
	root_layout: Control
) -> void:
	"""Initialize UIManager with all the pre-built nodes from main.tscn."""

	var init_start_us := Time.get_ticks_usec()
	_root_control = root_layout
	_content_wrapper = content_wrapper
	_main_content_vbox = main_content_vbox
	_library_background = library_background

	# Get navigation type setting
	var nav_type: int = 0
	if DataManager:
		var type_setting = DataManager.get_setting("library_navigation_type")
		if type_setting:
			nav_type = type_setting.value

	# Create InnerLayout and add it to the root control
	var phase_start_us := Time.get_ticks_usec()
	_inner_layout = _create_inner_layout(nav_type == 0)
	_root_control.add_child(_inner_layout)
	print("[UIManager] inner layout create elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Wrap MainContentVBox in a MarginContainer to keep content away from screen edges
	phase_start_us = Time.get_ticks_usec()
	var content_margin = MarginContainer.new()
	content_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var margin = int(M3Units.dp(16))
	content_margin.add_theme_constant_override("margin_left", margin)
	content_margin.add_theme_constant_override("margin_right", margin)
	content_margin.add_theme_constant_override("margin_top", margin)
	content_margin.add_theme_constant_override("margin_bottom", margin)

	var mcv_index = _main_content_vbox.get_index()
	_content_wrapper.remove_child(_main_content_vbox)
	content_margin.add_child(_main_content_vbox)
	_content_wrapper.add_child(content_margin)
	_content_wrapper.move_child(content_margin, mcv_index)
	print("[UIManager] content margin reparent elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Ensure MainContentVBox fills the MarginContainer
	_main_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_content_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create and sync the centralized card/grid settings state BEFORE views are
	# instantiated so that HomeView/LibraryView and their grids can read the
	# saved layout/orientation during _ready()/_enter_tree().
	phase_start_us = Time.get_ticks_usec()
	card_settings_state = CardSettingsState.new()
	card_settings_state.sync_from_settings_manager()
	card_settings_state.changed.connect(_on_card_settings_state_changed)
	print("[UIManager] card settings state sync elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Configure child managers
	phase_start_us = Time.get_ticks_usec()
	navigation.setup(_root_control, _content_wrapper, _inner_layout, nav_type)
	print("[UIManager] navigation.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	view.setup(tab_container)
	print("[UIManager] view.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	overlay.setup(_root_control)
	print("[UIManager] overlay.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	theme.setup(tab_container)
	print("[UIManager] theme.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	dual_screen.setup(_root_control)
	print("[UIManager] dual_screen.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Reconnect dual-screen detection signal and re-evaluate current state.
	if SystemManager.display:
		SystemManager.display.dual_screen_mode_changed.connect(dual_screen._on_dual_screen_mode_changed)
		if SystemManager.display.is_dual_screen_enabled():
			dual_screen._on_dual_screen_mode_changed(true, SystemManager.display.get_second_screen_index())
	print("[UIManager] initialize total elapsed_us=", Time.get_ticks_usec() - init_start_us)

	# Apply library background configuration now and when settings change
	if _library_background and DataManager:
		var bg_setting = DataManager.get_setting("library_background_config")
		if bg_setting and bg_setting.value is Dictionary:
			_library_background.set_background_config(bg_setting.value)

	# Connect settings signals
	DataManager.setting_changed.connect(_on_setting_changed)
	DataManager.settings_saved.connect(_on_settings_saved)
	DataManager.apply_preset_begin.connect(_on_apply_preset_begin)
	DataManager.apply_preset_end.connect(_on_apply_preset_end)

	# Apply dark mode setting on startup
	var dark_mode_setting = DataManager.get_setting("dark_mode")
	if dark_mode_setting:
		theme._apply_dark_mode(dark_mode_setting.value)

	# Apply primary color setting on startup
	var primary_color_setting = DataManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		M3Theme.set_primary_seed(primary_color_setting.value)

	theme._request_theme_refresh()

# ============================================================================
# Layout helpers
# ============================================================================

func _create_inner_layout(is_horizontal: bool) -> BoxContainer:
	var layout: BoxContainer
	if is_horizontal:
		layout = VBoxContainer.new()
	else:
		layout = HBoxContainer.new()

	layout.name = "InnerLayout"
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)

	return layout

# ============================================================================
# Public shell API (thin wrappers around child managers)
# ============================================================================

func switch_to_tab(tab_name: String):
	view.switch_to_tab(tab_name)

func get_current_view() -> View:
	return view.get_current_view()

func is_current_view(view_name: String) -> bool:
	return view.is_current_view(view_name)

func get_view(view_name: String) -> View:
	return view.get_view(view_name)

func rebuild_game_grid() -> void:
	view.rebuild_game_grid()

func show_settings_dialog() -> void:
	overlay.show_settings_dialog()

func get_onscreen_keyboard() -> PanelContainer:
	if _onscreen_keyboard and is_instance_valid(_onscreen_keyboard):
		return _onscreen_keyboard
	_onscreen_keyboard = get_tree().root.find_child("OnscreenKeyboard", true, false)
	return _onscreen_keyboard

func is_onscreen_keyboard_visible() -> bool:
	var kb = get_onscreen_keyboard()
	return kb != null and kb.visible

func is_focus_in_onscreen_keyboard(control: Control) -> bool:
	var kb = get_onscreen_keyboard()
	return kb != null and kb.is_focus_within_keyboard(control)

func pre_create_settings_dialog(force: bool = false) -> void:
	overlay.pre_create_settings_dialog(force)

func is_settings_dialog_open() -> bool:
	return overlay.is_settings_dialog_open()

func show_settings_dialog_with_category(category_id: String) -> void:
	overlay.show_settings_dialog_with_category(category_id)

func reopen_settings_dialog() -> void:
	overlay.reopen_settings_dialog()

func show_shuffler_dialog() -> void:
	overlay.show_shuffler_dialog()

func set_card_designer_preview_game(romm_id: int) -> void:
	overlay.set_card_designer_preview_game(romm_id)

func get_settings_dialog_platforms_view() -> PlatformsSettingsView:
	return overlay.get_settings_dialog_platforms_view()

func show_game_context_menu(romm_id: int, anchor: Control, show_delete: bool = true) -> String:
	return overlay.show_game_context_menu(romm_id, anchor, show_delete)

func show_context_menu(items: Array[Dictionary], anchor: Control, context: Dictionary = {}) -> String:
	return overlay.show_context_menu(items, anchor, context)

func show_game_details(romm_id: int) -> void:
	overlay.show_game_details(romm_id)

func dismiss_modal() -> void:
	overlay.dismiss_modal()

func is_modal_open() -> bool:
	return overlay.is_modal_open()

func show_folder_dialog(title: String, initial_dir: String, on_dir_selected: Callable, use_native: bool = true) -> FileDialog:
	return overlay.show_folder_dialog(title, initial_dir, on_dir_selected, use_native)

func show_file_dialog(title: String, filters: PackedStringArray, initial_dir: String, on_file_selected: Callable, use_native: bool = true) -> FileDialog:
	return overlay.show_file_dialog(title, filters, initial_dir, on_file_selected, use_native)

func show_confirm(title: String, body: String, on_accept: Callable = Callable(), on_cancel: Callable = Callable(), on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	return overlay.show_confirm(title, body, on_accept, on_cancel, on_dismissed, options)

func show_alert(title: String, body: String, on_ok: Callable = Callable(), on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	return overlay.show_alert(title, body, on_ok, on_dismissed, options)

func show_custom_dialog(build_fn: Callable, on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	return overlay.show_custom_dialog(build_fn, on_dismissed, options)

func find_home_button() -> Control:
	return navigation.find_home_button()

func find_nav_settings_button() -> Control:
	return navigation.find_nav_settings_button()

func get_last_nav_destination() -> Control:
	return navigation.get_last_nav_destination()

func get_active_nav_destination() -> Control:
	return navigation.get_active_nav_destination()

func get_nav_type() -> int:
	return navigation.get_nav_type()

func is_focus_lock_active() -> bool:
	return _focus_lock_active

func should_card_grab_focus_on_hover() -> bool:
	return navigation.should_card_grab_focus_on_hover()

func suppress_next_focus_sound() -> void:
	navigation.suppress_next_focus_sound()

func controller_has_priority() -> bool:
	return navigation.controller_has_priority()

func handle_directional_input(event: InputEvent) -> bool:
	return navigation.handle_directional_input(event)

# ============================================================================
# Focus lock: disable focus on all non-grid controls while a locked grid owns focus
# ============================================================================

func enter_focus_lock(grid: VirtualScrollGridContainer) -> void:
	"""Activate scene-wide focus lock around the given grid."""
	if _focus_lock_active and _focus_locked_grid == grid:
		return
	# If we were already locked to a different grid, restore first.
	if _focus_lock_active:
		_exit_focus_lock()
	_focus_locked_grid = grid
	_focus_lock_active = true
	_apply_focus_lock()

func exit_focus_lock(grid: VirtualScrollGridContainer) -> void:
	"""Exit focus lock if it is currently held by the given grid."""
	if not _focus_lock_active:
		return
	if _focus_locked_grid != grid:
		return
	_exit_focus_lock()

func _exit_focus_lock() -> void:
	if not _focus_lock_active:
		return
	_focus_lock_active = false
	_focus_locked_grid = null
	_restore_focus_modes()

func refresh_focus_lock_state() -> void:
	"""Re-apply the current focus lock after layout/theme changes."""
	if not _focus_lock_active or not _focus_locked_grid:
		return
	if not is_instance_valid(_focus_locked_grid) or not _focus_locked_grid.is_inside_tree():
		_exit_focus_lock()
		return
	# Only remain locked if the grid still has focus.
	var viewport := get_viewport()
	if not is_instance_valid(viewport):
		_exit_focus_lock()
		return
	var focused := viewport.gui_get_focus_owner()
	if not focused or not _focus_locked_grid.is_ancestor_of(focused):
		_exit_focus_lock()
		return
	# Re-apply in case new focusable controls were created.
	_apply_focus_lock()

func _apply_focus_lock() -> void:
	"""Save and disable focus modes for all controls outside the locked grid."""
	if not _focus_locked_grid or not _root_control:
		return
	_saved_focus_modes.clear()
	var focusables := _gather_focusable_controls(_root_control)
	for ctrl in focusables:
		if not is_instance_valid(ctrl):
			continue
		var path := ctrl.get_path()
		_saved_focus_modes[path] = ctrl.focus_mode
		ctrl.focus_mode = Control.FOCUS_NONE

func _restore_focus_modes() -> void:
	"""Restore original focus modes saved by _apply_focus_lock."""
	for path in _saved_focus_modes.keys():
		var node := get_node_or_null(path)
		if node is Control and is_instance_valid(node):
			node.focus_mode = _saved_focus_modes[path]
	_saved_focus_modes.clear()

func _gather_focusable_controls(node: Node) -> Array[Control]:
	"""Recursively collect Controls with non-NONE focus modes."""
	var result: Array[Control] = []
	if node is Control and node.focus_mode != Control.FOCUS_NONE:
		result.append(node)
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		# Don't descend into the locked grid or its children.
		if _focus_locked_grid and (_focus_locked_grid == child or _focus_locked_grid.is_ancestor_of(child)):
			continue
		# Don't descend into overlays/dialogs (CanvasLayer children).
		if child is CanvasLayer:
			continue
		result.append_array(_gather_focusable_controls(child))
	return result

# ============================================================================
# High-level setting-change dispatcher
# ============================================================================

func _on_settings_saved() -> void:
	"""Re-sync CardSettingsState after a save in case anything bypassed set_setting."""
	if card_settings_state:
		card_settings_state.sync_from_settings_manager()

func apply_settings_now() -> void:
	"""Public hook for settings dialog dismissal; ensures CardSettingsState re-syncs."""
	_on_settings_saved()

func _on_apply_preset_begin() -> void:
	"""Batch card settings updates during preset application."""
	if card_settings_state:
		card_settings_state.begin_batch()
	theme._on_apply_preset_begin()

func _on_apply_preset_end() -> void:
	"""Flush batched card settings, then let ThemeManager drive the rebuild."""
	if card_settings_state:
		card_settings_state.end_batch()
	theme._on_apply_preset_end()
	# Theme/layout may have created new focusable controls; re-apply lock if needed.
	call_deferred("refresh_focus_lock_state")

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	"""Handle settings changes.

	Always update the centralized CardSettingsState. During a preset the actual
	view rebuild is deferred to ThemeManager._on_apply_preset_end(); outside of
	presets we still drive navigation/background/hero changes here.
	"""
	if card_settings_state:
		card_settings_state.apply_setting(setting.property_name, _value)

	if theme._preset_in_progress:
		# During preset application ThemeManager handles the final rebuild.
		return

	print("[UIManager] _on_setting_changed: %s" % setting.property_name)
	match setting.property_name:
		"library_background_config":
			if _library_background and _value is Dictionary:
				_library_background.set_background_config(_value)
		"library_navigation_type":
			navigation.set_nav_type(setting.value)
			navigation._rebuild_nav_and_layout()
			# Nav rebuild may add/reparent focusable controls; re-apply lock.
			call_deferred("refresh_focus_lock_state")
		"hero_effect_config":
			var hero_image = get_hero_image()
			if hero_image and hero_image.has_method("refresh_from_settings"):
				hero_image.refresh_from_settings()
			view.mark_view_for_rebuild("Home", "Hero effect config changed")
			view.mark_view_for_rebuild("Library", "Hero effect config changed")
		"dark_mode":
			theme._apply_dark_mode(_value)
		"library_primary_color":
			M3Theme.set_primary_seed(_value)
			theme._request_theme_refresh()
		# Card/grid specific settings (layout_mode, grid_vertical, card_zoom,
		# grid_padding, focus_scale, display_mode, content_alignment, media_ratio,
		# show_title_mode, card_effect_config, focus_lock) are owned by
		# CardSettingsState. VirtualScrollGridContainer and GameCard react to its
		# typed change events directly.
		_:
			pass

func _on_card_settings_state_changed(_mask: int) -> void:
	"""React to batched card/grid settings changes.

	Currently this is a hook for future centralized handling. Grid and card
	consumers connect to CardSettingsState.changed directly.
	"""
	pass

# ============================================================================
# Hero / library background helpers (moved from removed HeroBackgroundManager)
# ============================================================================

func get_hero_image() -> HeroImage:
	if dual_screen:
		return dual_screen.get_hero_image()
	return null

func _apply_library_background_config() -> void:
	"""Apply the current library background configuration from settings."""
	if not _library_background or not DataManager:
		return
	var config_setting = DataManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_background.set_background_config(config_setting.value)

func _on_hero_game_changed(game: GameResource) -> void:
	"""Handle hero game change from views. Updates both the main hero and the
	second-screen copy when dual screen is active."""
	var hero_image = get_hero_image()
	if not hero_image:
		return

	var current_view = view.get_current_view()
	if not current_view or not current_view.supports_hero:
		return

	# Check if hero height is set to 0% (hidden)
	var hero_config_setting = DataManager.get_setting("hero_effect_config") if DataManager else null
	var hero_config = hero_config_setting.value if hero_config_setting and hero_config_setting.value is Dictionary else {}
	var height_index = hero_config.get("hero_height", 0)
	var height_ratio = 0.0
	if height_index is int or height_index is float:
		var idx = int(height_index)
		var ratios = [1.0, 0.66, 0.5, 0.33, 0.0]
		if idx >= 0 and idx < ratios.size():
			height_ratio = ratios[idx]
	if height_ratio == 0.0:
		return

	if game:
		hero_image.set_game(game)
		if dual_screen and dual_screen._dual_screen_active:
			dual_screen.set_hero_game(game)
	else:
		hero_image.clear()

# ============================================================================
# Cleanup
# ============================================================================

func pre_shutdown_cleanup() -> void:
	"""Release static UI caches before the tree is freed.

	Can be called safely while the UI tree is still alive.
	"""
	SystemManager.memory.clear_texture_cache()
	M3Theme.clear_theme_cache()
	EffectStack.clear_script_cache()
	GameCard.clear_platform_icon_cache()
	LaunchTransitionOverlay._clear_source_override()
	M3NavigationDestination.clear_shared_stylebox()
	M3MenuRenderer.clear_shared_stylebox()
	LibraryFilterSheet.cleanup_instance()
	PlatformCardPool.clear()

func _exit_tree() -> void:
	"""Release the UIManager's cached references so the engine can free the UI tree.
	Nodes still in the tree are left for the tree to free; orphaned overlays are
	freed immediately because queue_free() may not flush during process exit."""

	_exit_focus_lock()

	# Drop all cached node references so the tree can free them.
	_root_control = null
	_inner_layout = null
	_main_content_vbox = null
	_content_wrapper = null

	# Release static caches that hold resources.
	pre_shutdown_cleanup()
