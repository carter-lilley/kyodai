extends Manager

# UIManager - Facade for UI orchestration.
# Child managers own views, navigation, hero/background, overlays, theme, and dual-screen logic.

@onready var view = $ViewManager
@onready var navigation = $NavigationManager
@onready var overlay = $OverlayManager
@onready var theme = $ThemeManager
@onready var dual_screen = $DualScreenManager

# Cached references passed during initialization
var _library_background: LibraryBackground = null
var _hero_image: HeroImage = null

# Centralized card/grid settings state. Owned by UIManager; consumers read this
# instead of querying SettingsManager directly for card/grid settings.
var card_settings_state: CardSettingsState = null

# Layout management - NEW ARCHITECTURE
var _root_control: Control = null  # Plain control, never replaced
var _inner_layout: BoxContainer = null  # VBox or HBox, replaced only on orientation change
var _main_content_vbox: VBoxContainer = null  # Never replaced, never cleared
var _content_wrapper: Control = null

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
	hero_image: HeroImage,
	hero_spacer: Control,
	library_background: LibraryBackground,
	content_wrapper: Control,
	main_content_vbox: VBoxContainer,
	root_layout: Control
) -> void:
	"""Initialize UIManager with all pre-built nodes from main.tscn."""

	_root_control = root_layout
	_content_wrapper = content_wrapper
	_main_content_vbox = main_content_vbox
	_library_background = library_background
	_hero_image = hero_image

	# Get navigation type setting
	var nav_type: int = 0
	if SettingsManager:
		var type_setting = SettingsManager.get_setting("library_navigation_type")
		if type_setting:
			nav_type = type_setting.value

	# Create InnerLayout and add it to the root control
	_inner_layout = _create_inner_layout(nav_type == 0)
	_root_control.add_child(_inner_layout)

	# Wrap MainContentVBox in a MarginContainer to keep content away from screen edges
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

	# Ensure MainContentVBox fills the MarginContainer
	_main_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_content_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Configure child managers
	navigation.setup(_root_control, _content_wrapper, _inner_layout, nav_type)
	view.setup(tab_container)
	overlay.setup(_root_control)
	theme.setup(tab_container)
	dual_screen.setup(_root_control, hero_image, hero_spacer)

	# Apply library background configuration now and when settings change
	if _library_background and SettingsManager:
		var bg_setting = SettingsManager.get_setting("library_background_config")
		if bg_setting and bg_setting.value is Dictionary:
			_library_background.set_background_config(bg_setting.value)

	# Create and sync the centralized card/grid settings state.
	card_settings_state = CardSettingsState.new()
	card_settings_state.sync_from_settings_manager()
	card_settings_state.changed.connect(_on_card_settings_state_changed)

	# Connect settings signals
	SettingsManager.setting_changed.connect(_on_setting_changed)
	SettingsManager.settings_saved.connect(_on_settings_saved)
	SettingsManager.apply_preset_begin.connect(_on_apply_preset_begin)
	SettingsManager.apply_preset_end.connect(_on_apply_preset_end)

	# Apply dark mode setting on startup
	var dark_mode_setting = SettingsManager.get_setting("dark_mode")
	if dark_mode_setting:
		theme._apply_dark_mode(dark_mode_setting.value)

	# Apply primary color setting on startup
	var primary_color_setting = SettingsManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		M3Theme.set_primary_seed(primary_color_setting.value)

	# Eagerly create the settings dialog so the first open is stutter-free.
	overlay.pre_create_settings_dialog()

	# Connect to dual screen mode changes
	if DisplayManager:
		DisplayManager.dual_screen_mode_changed.connect(dual_screen._on_dual_screen_mode_changed)
		if DisplayManager.is_dual_screen_enabled():
			dual_screen._initialize_dual_screen()

	# Set initial focus
	navigation._set_initial_focus()

	# Setup focus feedback handlers (navigation sounds)
	navigation._setup_feedback_handlers()

func _create_inner_layout(is_horizontal: bool) -> BoxContainer:
	"""Create the inner layout container (VBox or HBox)."""
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

func show_settings_dialog_with_category(category_id: String) -> void:
	overlay.show_settings_dialog_with_category(category_id)

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

func get_settings_dialog_platforms_view() -> PlatformsSettingsView:
	return overlay.get_settings_dialog_platforms_view()

func set_card_designer_preview_game(romm_id: int) -> void:
	overlay.set_card_designer_preview_game(romm_id)

func is_mouse_recently_active() -> bool:
	return navigation.is_mouse_recently_active()

func controller_has_priority() -> bool:
	return navigation.controller_has_priority()

func should_card_grab_focus_on_hover() -> bool:
	return navigation.should_card_grab_focus_on_hover()

func pre_create_settings_dialog() -> void:
	overlay.pre_create_settings_dialog()

func is_settings_dialog_open() -> bool:
	return overlay.is_settings_dialog_open()

func apply_settings_now() -> void:
	"""Flush settings changes to the live UI immediately.

	Called when the Settings dialog is dismissed with OK or outside-click.
	Syncs CardSettingsState, rebuilds views, and refreshes theme/background.
	"""
	print("[UIManager] apply_settings_now")

	# Sync centralized card/grid state with current SettingsManager values.
	if card_settings_state:
		card_settings_state.sync_from_settings_manager()

	# Rebuild navigation layout if the navigation type changed.
	var type_setting = SettingsManager.get_setting("library_navigation_type")
	if type_setting:
		var new_nav_type = type_setting.value
		if new_nav_type != navigation.get_nav_type():
			navigation.set_nav_type(new_nav_type)
			navigation._rebuild_nav_and_layout()

	# Rebuild all views so card size / layout changes are visible immediately.
	view._rebuild_views("Settings applied", true)

	# Apply library background and theme colors.
	_apply_library_background_config()

	var dark_mode_setting = SettingsManager.get_setting("dark_mode")
	if dark_mode_setting:
		theme._apply_dark_mode(dark_mode_setting.value)

	var primary_color_setting = SettingsManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		M3Theme.set_primary_seed(primary_color_setting.value)

	theme._request_theme_refresh()

# ============================================================================
# High-level setting-change dispatcher
# ============================================================================

func _on_settings_saved() -> void:
	"""Re-sync CardSettingsState after a save in case anything bypassed set_setting."""
	if card_settings_state:
		card_settings_state.sync_from_settings_manager()

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
		"hero_effect_config":
			if _hero_image and _hero_image.has_method("refresh_from_settings"):
				_hero_image.refresh_from_settings()
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

func _apply_library_background_config() -> void:
	"""Apply the current library background configuration from settings."""
	if not _library_background or not SettingsManager:
		return
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_background.set_background_config(config_setting.value)

func _on_hero_game_changed(game: GameResource) -> void:
	"""Handle hero game change from views. Updates both the main hero and the
	second-screen copy when dual screen is active."""
	if not _hero_image:
		return

	var current_view = view.get_current_view()
	var current_view_name = current_view.view_name if current_view else ""
	if current_view_name not in ["Home", "Library"]:
		return

	# Check if hero height is set to 0% (hidden)
	var hero_config_setting = SettingsManager.get_setting("hero_effect_config") if SettingsManager else null
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
		_hero_image.set_game(game)
		if dual_screen and dual_screen._dual_screen_active and dual_screen._hero_copy_in_second_viewport and dual_screen._hero_copy_in_second_viewport.has_method("set_game"):
			dual_screen._hero_copy_in_second_viewport.set_game(game)
		if dual_screen and dual_screen._dual_screen_active:
			var ayn_thor_manager = get_node_or_null("/root/Main/AynThorManager")
			if ayn_thor_manager and ayn_thor_manager.has_method("force_hero_viewport_update"):
				ayn_thor_manager.force_hero_viewport_update()
	else:
		_hero_image.clear()
		if dual_screen and dual_screen._dual_screen_active and dual_screen._hero_copy_in_second_viewport and dual_screen._hero_copy_in_second_viewport.has_method("clear"):
			dual_screen._hero_copy_in_second_viewport.clear()

# ============================================================================
# Cleanup
# ============================================================================

func _exit_tree() -> void:
	"""Release the UIManager's cached references so the engine can free the UI tree.
	Nodes still in the tree are left for the tree to free; orphaned overlays are
	freed immediately because queue_free() may not flush during process exit."""

	# Drop all cached node references so the tree can free them.
	_root_control = null
	_inner_layout = null
	_main_content_vbox = null
	_content_wrapper = null

	# Release static caches that hold resources.
	MemoryManager.clear_texture_cache()
	M3Theme.clear_theme_cache()
	EffectStack.clear_script_cache()
	GameCard.clear_platform_icon_cache()
	LaunchTransitionOverlay._clear_source_override()
	M3NavigationDestination.clear_shared_stylebox()
	M3MenuRenderer.clear_shared_stylebox()
	LibraryFilterSheet.cleanup_instance()
