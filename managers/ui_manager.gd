extends Manager

# UIManager - Manages tab-based view navigation and modal overlays
# Uses "always present" architecture with targeted container replacement

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

# Layout management - NEW ARCHITECTURE
var _root_control: Control = null  # Plain control, never replaced
var _inner_layout: BoxContainer = null  # VBox or HBox, replaced only on orientation change
var _nav_node: M3Navigation = null
var _nav_type: int = 0  # 0 = Bar, 1 = Rail

const NAV_DESTINATIONS = [
	{"id": "home",      "label": "Home",      "icon": "home",     "view": "Home"},
	{"id": "library",   "label": "Library",   "icon": "library",  "view": "Library"},
	{"id": "downloads", "label": "Downloads", "icon": "download", "view": "Downloads"},
]

# Settings dialog
var _settings_dialog = null

# Default hero height ratio (will be overridden by settings)
const HERO_SIZE_RATIO_DEFAULT = 0.33
const HERO_HEIGHT_RATIOS = [1.0, 0.66, 0.5, 0.33, 0.0]

# Hero image management - ALWAYS PRESENT
var _hero_image: HeroImage = null
var _hero_spacer: Control = null  # ALWAYS present, size controls layout

# Library background management - ALWAYS PRESENT
var _library_background: LibraryBackground = null
var _content_wrapper: Control = null  # Layers background + content

# Main content area - ALWAYS PRESENT
var _main_content_vbox: VBoxContainer = null  # Never replaced, never cleared

# Modal management (now uses M3Menu)
var _active_menu: M3Menu = null
var _modal_context: Dictionary = {}
var _focus_indicator: FocusIndicator = null

# Feedback tracking for navigation sounds
var _feedback_connected_viewport: Viewport = null
var _is_first_focus: bool = true

# Game details tab
var _details_tab_idx: int = -1
var _game_details_view: View = null

# Input tracking for mouse hover focus
const MOUSE_IDLE_THRESHOLD_MS: int = 1000  # Mouse must have moved within last 1 second
const CONTROLLER_PRIORITY_MS: int = 2000   # Controller has priority for 2 seconds after use
var _last_mouse_move_time: int = 0
var _last_controller_input_time: int = 0
var _last_mouse_position: Vector2 = Vector2.ZERO

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
	
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	
	_hero_image = hero_image
	_hero_spacer = hero_spacer
	_library_background = library_background
	_content_wrapper = content_wrapper
	_main_content_vbox = main_content_vbox
	_root_control = root_layout
	
	# Get navigation type setting
	if SettingsManager:
		var type_setting = SettingsManager.get_setting("library_navigation_type")
		if type_setting:
			_nav_type = type_setting.value
	
	# Create InnerLayout and nav node
	_rebuild_nav_and_layout()
	
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
	
	# Connect viewport resize
	_connect_viewport_resize()
	
	# Update hero size
	_update_hero_size()
	
	# Setup existing tabs
	_setup_home_tab()
	_setup_library_tab()
	_setup_downloads_tab()
	
	# Set initial current view based on current tab
	var current_tab_idx = _tab_container.current_tab
	var current_tab_title = _tab_container.get_tab_title(current_tab_idx)
	if _views.has(current_tab_title):
		_current_view = _views[current_tab_title]
		_current_view.on_view_show()
		_update_hero_visibility(current_tab_title)
		# Update nav selection
		for i in range(NAV_DESTINATIONS.size()):
			if NAV_DESTINATIONS[i].view == current_tab_title:
				if _nav_node:
					_nav_node.selected_index = i
				break
	
	# Focus indicator disabled — M3 components provide their own focus visuals
	# _setup_focus_indicator()
	
	# Setup library appearance
	_setup_library_appearance()
	SettingsManager.setting_changed.connect(_on_setting_changed)
	SettingsManager.apply_preset_begin.connect(_on_apply_preset_begin)
	SettingsManager.apply_preset_end.connect(_on_apply_preset_end)
	
	# Apply dark mode setting on startup
	var dark_mode_setting = SettingsManager.get_setting("dark_mode")
	if dark_mode_setting:
		_apply_dark_mode(dark_mode_setting.value)
	
	# Apply primary color setting on startup
	var primary_color_setting = SettingsManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		M3Theme.set_primary_seed(primary_color_setting.value)
	
	# Pre-create settings dialog so first open is instant.
	# On first launch we skip this; it will be created after OOBE completes.
	var first_run_setting = SettingsManager.get_setting("first_run_completed")
	if first_run_setting and first_run_setting.value:
		pre_create_settings_dialog()
	
	# Connect to dual screen mode changes
	if DisplayManager:
		DisplayManager.dual_screen_mode_changed.connect(_on_dual_screen_mode_changed)
		if DisplayManager.is_dual_screen_enabled():
			_initialize_dual_screen()
	
	# Set initial focus
	_set_initial_focus()
	
	# Setup focus feedback handlers (navigation sounds)
	_setup_feedback_handlers()

## Input tracking for mouse hover focus
func _input(event: InputEvent) -> void:
	# Track mouse movement
	if event is InputEventMouseMotion:
		var current_pos = event.position
		# Only update if mouse actually moved (not just received same position)
		if current_pos != _last_mouse_position:
			_last_mouse_move_time = Time.get_ticks_msec()
			_last_mouse_position = current_pos
	
	# Track controller input (gamepad/joystick)
	elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_last_controller_input_time = Time.get_ticks_msec()
	
	# Track keyboard navigation (arrow keys, tab, etc. - not typing)
	elif event is InputEventKey:
		if event.is_action("ui_left") or event.is_action("ui_right") or \
		   event.is_action("ui_up") or event.is_action("ui_down") or \
		   event.is_action("ui_accept") or event.is_action("ui_cancel"):
			_last_controller_input_time = Time.get_ticks_msec()

## Check if mouse has moved recently (within threshold)
func is_mouse_recently_active() -> bool:
	var now = Time.get_ticks_msec()
	var time_since_move = now - _last_mouse_move_time
	return time_since_move < MOUSE_IDLE_THRESHOLD_MS

## Check if controller has priority over mouse (used recently)
func controller_has_priority() -> bool:
	var now = Time.get_ticks_msec()
	var time_since_controller = now - _last_controller_input_time
	return time_since_controller < CONTROLLER_PRIORITY_MS

## Check if card should grab focus on mouse hover
func should_card_grab_focus_on_hover() -> bool:
	# Don't grab if mouse is idle
	if not is_mouse_recently_active():
		return false
	# Don't grab if controller was used recently (controller has priority)
	if controller_has_priority():
		return false
	return true

func _initialize_dual_screen() -> void:
	"""Initialize dual screen mode (called deferred to allow plugin initialization)."""
	_on_dual_screen_mode_changed(true, DisplayManager.get_second_screen_index())

func _connect_viewport_resize() -> void:
	"""Connect to viewport resize signal to update hero size."""
	if get_viewport():
		get_viewport().size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	"""Handle viewport resize - update hero size."""
	_update_hero_size()

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

func _update_inner_layout_children() -> void:
	"""Update the order of children in InnerLayout based on nav type."""
	
	# Remove existing children
	for child in _inner_layout.get_children():
		_inner_layout.remove_child(child)
	
	var is_bar = _nav_type == 0
	
	# Configure size flags for nav node
	if _nav_node:
		if is_bar:
			_nav_node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_nav_node.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		else:
			_nav_node.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_nav_node.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Configure size flags for ContentWrapper (expand to fill remaining space)
	_content_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Remove from current parents before reparenting (fixes Android dual-screen mode issue)
	if _nav_node and _nav_node.get_parent():
		_nav_node.get_parent().remove_child(_nav_node)
	if _content_wrapper.get_parent():
		_content_wrapper.get_parent().remove_child(_content_wrapper)
	
	# Add in correct order
	if is_bar:
		# Bar at bottom: ContentWrapper first, then nav
		_inner_layout.add_child(_content_wrapper)
		if _nav_node:
			_inner_layout.add_child(_nav_node)
	else:
		# Rail at left: nav first, then ContentWrapper
		if _nav_node:
			_inner_layout.add_child(_nav_node)
		_inner_layout.add_child(_content_wrapper)

# ============================================================================
# Layout Updates
# ============================================================================

func _rebuild_nav_and_layout() -> void:
	"""Rebuild nav node and layout when type changes."""
	
	var is_bar = _nav_type == 0
	var is_horizontal = is_bar
	
	# Remove existing nav and content from current layout
	if _inner_layout:
		if _nav_node and _nav_node.get_parent() == _inner_layout:
			_inner_layout.remove_child(_nav_node)
		if _content_wrapper.get_parent() == _inner_layout:
			_inner_layout.remove_child(_content_wrapper)
	
	# Free old nav node
	if _nav_node:
		_nav_node.queue_free()
		_nav_node = null
	
	# Check if we need to replace InnerLayout (VBox ↔ HBox)
	var current_is_horizontal = _inner_layout is VBoxContainer
	if is_horizontal != current_is_horizontal:
		if _inner_layout and _inner_layout.get_parent() == _root_control:
			_root_control.remove_child(_inner_layout)
			_inner_layout.queue_free()
		_inner_layout = _create_inner_layout(is_horizontal)
		_root_control.add_child(_inner_layout)
	elif not _inner_layout:
		# First-time initialization
		_inner_layout = _create_inner_layout(is_horizontal)
		_root_control.add_child(_inner_layout)
	
	# Create new nav node
	_create_nav_node()
	
	# Re-add children in correct order
	_update_inner_layout_children()
	
	# Update hero size
	_update_hero_size()
	
	# Emit signal
	layout_changed.emit("bar" if is_bar else "rail")

func _create_nav_node() -> void:
	"""Create the M3 navigation node (Bar or Rail) with destinations."""
	if _nav_type == 0:
		_nav_node = M3NavigationBar.new()
	else:
		_nav_node = M3NavigationRail.new()
	
	_nav_node.name = "M3Nav"
	_nav_node.placement_mode = M3Navigation.PlacementMode.OVERLAY
	_nav_node.label_visibility = M3Navigation.LabelVisibility.AUTO
	
	# Build destinations
	var dest_data: Array[M3NavigationDestinationData] = []
	for dest in NAV_DESTINATIONS:
		var d = M3NavigationDestinationData.new()
		d.id = dest.id
		d.label = dest.label
		d.icon_name = dest.icon
		dest_data.append(d)
	_nav_node.destinations = dest_data
	
	# Connect selection signal
	_nav_node.destination_selected.connect(_on_nav_destination_selected)
	
	# Deferred config: the M3 nav node creates its internal UI in _ready(),
	# which only fires after it enters the tree. Setting show_menu_button and
	# footer_content before that point silently fails because the wrappers
	# don't exist yet. We stash the values and apply them on ready.
	var settings_btn = M3IconButton.new()
	settings_btn.name = "SettingsButton"
	settings_btn.icon_name = "cog"
	settings_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
	settings_btn.icon_button_size = M3IconButton.IconSize.MEDIUM
	settings_btn.pressed.connect(show_settings_dialog)
	
	_nav_node.set_meta("_deferred_show_menu_button", false)
	_nav_node.set_meta("_deferred_footer_content", settings_btn)
	if not _nav_node.ready.is_connected(_on_nav_node_ready):
		_nav_node.ready.connect(_on_nav_node_ready)

func _on_nav_node_ready() -> void:
	"""Apply deferred nav node config now that _ready() has created internal UI."""
	if not _nav_node:
		return
	if _nav_node.has_meta("_deferred_show_menu_button"):
		_nav_node.show_menu_button = _nav_node.get_meta("_deferred_show_menu_button")
		_nav_node.remove_meta("_deferred_show_menu_button")
	if _nav_node.has_meta("_deferred_footer_content"):
		_nav_node.footer_content = _nav_node.get_meta("_deferred_footer_content")
		_nav_node.remove_meta("_deferred_footer_content")

func _on_nav_destination_selected(index: int, _reselected: bool) -> void:
	"""Handle M3 nav destination selection."""
	if index >= 0 and index < NAV_DESTINATIONS.size():
		switch_to_tab(NAV_DESTINATIONS[index].view)

# ============================================================================
# Existing methods (preserved functionality)
# ============================================================================

func _update_hero_size() -> void:
	"""Update hero image size based on settings."""
	if not _hero_image:
		return
	
	if not is_instance_valid(_hero_image):
		push_error("[UIManager] CRITICAL: _hero_image is not valid!")
		return
	if not is_instance_valid(_hero_spacer):
		push_error("[UIManager] CRITICAL: _hero_spacer is not valid!")
		return
	
	if not _hero_image.is_inside_tree():
		push_error("[UIManager] CRITICAL: _hero_image is not in the tree!")
		return
	
	var viewport_size = get_viewport().size
	var height_ratio = HERO_SIZE_RATIO_DEFAULT
	var _raw_setting_value = null
	
	if SettingsManager:
		var hero_config_setting = SettingsManager.get_setting("hero_effect_config")
		if hero_config_setting and hero_config_setting.value is Dictionary:
			var hero_config = hero_config_setting.value
			var height_index = hero_config.get("hero_height", 0)
			# Better type checking that handles float/int conversion
			if height_index is int or height_index is float:
				var index = int(height_index)
				if index >= 0 and index < HERO_HEIGHT_RATIOS.size():
					height_ratio = HERO_HEIGHT_RATIOS[index]
					_raw_setting_value = index
	
	var target_height = viewport_size.y * height_ratio
	if target_height < 1.0:
		target_height = 1.0
	
	# Use preset-based layout - NO manual positioning!
	# Let Godot's layout system handle positioning based on anchors
	if height_ratio >= 1.0:
		# Full height - fills entire ContentWrapper (like LibraryBackground)
		_hero_image.set_anchors_preset(Control.PRESET_FULL_RECT)
		_hero_image.offset_bottom = 0
	else:
		# Partial height - anchored to top with fixed height via offset_bottom
		# PRESET_TOP_WIDE sets anchor_top=0, anchor_bottom=0, so height = offset_bottom
		_hero_image.set_anchors_preset(Control.PRESET_TOP_WIDE)
		_hero_image.offset_bottom = target_height
	
	# Update spacer to push grid down when hero is <100%
	var spacer_height = 0.0 if height_ratio >= 1.0 else target_height
	_hero_spacer.custom_minimum_size = Vector2(0, spacer_height)
	# Note: Don't set visibility here - _update_hero_visibility() controls that based on view
	
	# Force redraw to apply changes
	_hero_image.queue_redraw()

func _verify_hero_size() -> void:
	"""Debug function to verify hero size after layout update."""
	if _hero_image:
		pass

func _update_zoom_range_for_current_view() -> void:
	var current_view_name = _current_view.view_name if _current_view else ""
	if not current_view_name in ["Home", "Library"]:
		return
	if not _views.has(current_view_name):
		return
	var view = _views[current_view_name]
	var grid = view.games_grid if "games_grid" in view else null
	if grid:
		var _max_zoom = 1.0 if grid.view_mode != VirtualScrollGridContainer.ViewMode.GRID else 0.5
		# Zoom overlay is managed by main.gd; UIManager just knows the range
		pass

func _rebuild_views(reason: String, use_true: bool = false) -> void:
	"""Rebuild visible views immediately, mark hidden views for rebuild.
	Defer ALL rebuilds while the SettingsDialog is open to avoid stutter."""
	var settings_open = _settings_dialog and is_instance_valid(_settings_dialog) and _settings_dialog.visible
	
	if _views.has("Home"):
		var home_view = _views["Home"]
		if is_current_view("Home") and not settings_open:
			home_view.rebuild_grid(use_true)
		else:
			home_view.mark_for_rebuild(reason)
	if _views.has("Library"):
		var library_view = _views["Library"]
		if is_current_view("Library") and not settings_open:
			library_view.rebuild_grid(use_true)
		else:
			library_view.mark_for_rebuild(reason)

var _preset_in_progress: bool = false

func _on_apply_preset_begin() -> void:
	_preset_in_progress = true

func _on_apply_preset_end() -> void:
	_preset_in_progress = false
	# Update nav type from settings before rebuilding
	var old_nav_type = _nav_type
	var type_setting = SettingsManager.get_setting("library_navigation_type")
	if type_setting:
		_nav_type = type_setting.value
	# One rebuild after preset is fully applied
	# use_true=true to ensure card effects are fully refreshed
	_rebuild_views("Preset applied", true)
	# Apply background config in case it changed
	_apply_library_background_config()
	# Rebuild navigation only if navigation type actually changed
	if _nav_type != old_nav_type:
		_rebuild_nav_and_layout()
	# Apply dark mode in case it changed during preset
	var dark_mode_setting = SettingsManager.get_setting("dark_mode")
	if dark_mode_setting:
		_apply_dark_mode(dark_mode_setting.value)
	# Apply primary color in case it changed during preset
	var primary_color_setting = SettingsManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		M3Theme.set_primary_seed(primary_color_setting.value)
	# Ensure theme is refreshed in case accent color or dark mode changed
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		call_deferred("_do_refresh_theme")

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	"""Handle settings changes."""
	if _preset_in_progress:
		# Skip individual rebuilds during preset application; one rebuild at the end
		return
	match setting.property_name:
		"library_background_config":
			if _library_background and _value is Dictionary:
				_library_background.set_background_config(_value.duplicate())
		"library_navigation_type":
			_nav_type = setting.value
			_rebuild_nav_and_layout()
		"library_layout_mode":
			_rebuild_views("Layout mode changed")
			_update_zoom_range_for_current_view()
		"library_grid_vertical":
			_rebuild_views("Grid orientation changed")
		"library_focus_scale":
			_rebuild_views("Focus scale changed")
		"card_media_aspect_ratio":
			_rebuild_views("Card media ratio changed")
		"library_card_display_mode":
			_rebuild_views("Card display mode changed")
		"library_card_content_alignment":
			_rebuild_views("Card content alignment changed")
		"card_effect_config":
			_rebuild_views("Card effects changed", true)
		"hero_effect_config":
			if _hero_image and _hero_image.has_method("refresh_from_settings"):
				_hero_image.refresh_from_settings()
			_update_hero_size()
			if _views.has("Home"):
				_views["Home"].mark_for_rebuild("Hero height changed")
			if _views.has("Library"):
				_views["Library"].mark_for_rebuild("Hero height changed")
		"library_grid_padding":
			_rebuild_views("Grid padding changed")
		"dark_mode":
			_apply_dark_mode(_value)
		"library_primary_color":
			M3Theme.set_primary_seed(_value)
			if not _theme_refresh_pending:
				_theme_refresh_pending = true
				call_deferred("_do_refresh_theme")

var _theme_refresh_pending: bool = false

func _apply_dark_mode(enabled: bool) -> void:
	M3Theme.is_dark_mode = enabled
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		call_deferred("_do_refresh_theme")

func _do_refresh_theme() -> void:
	_theme_refresh_pending = false
	_refresh_theme_on_all_nodes(get_tree().root)

func _refresh_theme_on_all_nodes(node: Node) -> void:
	if node.has_method("refresh_theme"):
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_on_all_nodes(child)

func _setup_home_tab():
	var home_idx = _get_tab_index("Home")
	if home_idx == -1:
		push_warning("[UIManager]: Home tab not found")
		return
	
	var home_tab = _tab_container.get_tab_control(home_idx)
	
	# Clear existing content
	for child in home_tab.get_children():
		child.queue_free()
	
	# Add HomeView (load scene to get UI nodes)
	var home_scene = preload("res://view/home_view.tscn")
	var home_view = home_scene.instantiate()
	home_view.view_name = "Home"
	home_tab.add_child(home_view)
	_views["Home"] = home_view
	
	# Connect hero image signal
	if home_view.has_signal("hero_game_changed"):
		home_view.hero_game_changed.connect(_on_hero_game_changed)

func _setup_library_tab():
	var library_idx = _get_tab_index("Library")
	if library_idx == -1:
		push_warning("[UIManager]: Library tab not found")
		return
	
	var library_tab = _tab_container.get_tab_control(library_idx)
	
	# Clear existing content
	for child in library_tab.get_children():
		child.queue_free()
	
	# Add LibraryView (load scene to get UI nodes)
	var library_scene = preload("res://view/library_view.tscn")
	var library_view = library_scene.instantiate()
	library_view.view_name = "Library"
	library_tab.add_child(library_view)
	_views["Library"] = library_view
	
	# Connect hero image signal
	if library_view.has_signal("hero_game_changed"):
		library_view.hero_game_changed.connect(_on_hero_game_changed)

func _setup_downloads_tab():
	var downloads_idx = _get_tab_index("Downloads")
	if downloads_idx == -1:
		push_warning("[UIManager]: Downloads tab not found")
		return
	
	var downloads_tab = _tab_container.get_tab_control(downloads_idx)
	
	# Clear existing content
	for child in downloads_tab.get_children():
		child.queue_free()
	
	# Add DownloadsView (load scene to get UI nodes)
	var downloads_scene = preload("res://view/downloads_view.tscn")
	var downloads_view = downloads_scene.instantiate()
	downloads_view.view_name = "Downloads"
	downloads_tab.add_child(downloads_view)
	_views["Downloads"] = downloads_view

func pre_create_settings_dialog() -> void:
	"""Eagerly build the settings dialog in the background."""
	if _settings_dialog and is_instance_valid(_settings_dialog):
		_settings_dialog.queue_free()
		_settings_dialog = null
	
	# Use script .new() instead of scene instantiation to avoid CanvasLayer script attachment issues in SubViewports
	var settings_script = load("res://view/settings_dialog.gd")
	if not settings_script:
		push_error("[UIManager] Failed to load SettingsDialog script")
		return
	_settings_dialog = settings_script.new()
	if not _settings_dialog or not is_instance_valid(_settings_dialog):
		push_error("[UIManager] Failed to instantiate SettingsDialog")
		return
	if not _settings_dialog.has_signal("dismissed"):
		push_error("[UIManager] SettingsDialog instance missing 'dismissed' signal — script failed to attach. Class: " + _settings_dialog.get_class())
		return
	_settings_dialog.dismissed.connect(_on_settings_dialog_dismissed)
	
	if not _settings_dialog.is_inside_tree():
		_add_settings_dialog_to_correct_parent()

func show_settings_dialog() -> void:
	"""Show the fullscreen settings dialog."""
	if not _settings_dialog or not is_instance_valid(_settings_dialog):
		pre_create_settings_dialog()
	
	if not _settings_dialog.is_inside_tree():
		_add_settings_dialog_to_correct_parent()
	
	_settings_dialog.show_overlay()

func _add_settings_dialog_to_correct_parent() -> void:
	"""Add SettingsDialog to a parent where its CanvasLayer script will attach correctly.
	SubViewports break CanvasLayer script attachment; keep it in the root viewport."""
	if _settings_dialog.is_inside_tree():
		return
	var tree = Engine.get_main_loop()
	if tree and tree.root:
		# Deferred to avoid "busy parent" during _ready, but check again at execution
		# time in case show_overlay() auto-added it to a SubViewport in the meantime.
		var add_fn = func():
			if is_instance_valid(_settings_dialog) and not _settings_dialog.is_inside_tree():
				tree.root.add_child(_settings_dialog)
		add_fn.call_deferred()
	else:
		var add_fn = func():
			if is_instance_valid(_settings_dialog) and not _settings_dialog.is_inside_tree():
				_root_control.add_child(_settings_dialog)
		add_fn.call_deferred()

func show_settings_dialog_with_category(category_id: String) -> void:
	"""Open the settings dialog and jump to a specific category."""
	show_settings_dialog()
	if _settings_dialog and is_instance_valid(_settings_dialog):
		_settings_dialog.select_category(category_id)

func is_settings_dialog_open() -> bool:
	return _settings_dialog and is_instance_valid(_settings_dialog) and _settings_dialog.visible

func _on_settings_dialog_dismissed() -> void:
	"""Handle settings dialog dismissal."""
	settings_dialog_dismissed.emit()
	
	# Trigger any deferred rebuilds on the currently visible view now that
	# the dialog is closed. Hidden views will rebuild when they become visible.
	if _current_view and _current_view.needs_rebuild:
		_current_view.check_and_rebuild_if_needed()

func _get_tab_index(tab_title: String) -> int:
	for i in range(_tab_container.get_tab_count()):
		if _tab_container.get_tab_title(i) == tab_title:
			return i
	return -1

func _set_initial_focus() -> void:
	"""Set initial focus to the Home button in the navigation bar."""
	# Wait a frame for the UI to be fully ready
	await get_tree().process_frame
	
	# Try to find the home button in the navigation bar (search recursively since buttons are in dynamic containers)
	var home_button = find_home_button()
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		home_button.grab_focus()
		return
	
	# Fallback: try to focus the first focusable element in the root control
	if _root_control:
		var first_focusable = _find_first_focusable(_root_control)
		if first_focusable:
			first_focusable.grab_focus()

func find_home_button() -> Control:
	"""Find the Home destination in the M3 nav."""
	if not _nav_node:
		print("[UIManager] find_home_button: _nav_node is null")
		return null
	
	# M3NavigationDestination items are children of the nav's content container
	# Search recursively for the first destination node (index 0 = Home)
	for child in _nav_node.get_children():
		if child is M3NavigationDestination:
			# The first M3NavigationDestination is Home
			return child
		# Also search deeper in case they're inside containers
		for sub in child.get_children():
			if sub is M3NavigationDestination:
				return sub
			for subsub in sub.get_children():
				if subsub is M3NavigationDestination:
					return subsub
	return null

func find_nav_settings_button() -> Control:
	"""Find the settings button in the nav's footer slot."""
	if not _nav_node:
		return null
	
	# footer_content is set directly on the nav node
	if _nav_node.footer_content and is_instance_valid(_nav_node.footer_content):
		return _nav_node.footer_content
	return null

func _find_node_by_name(node: Node, target_name: String) -> Node:
	"""Recursively find a node by name."""
	if node.name == target_name:
		return node
	
	for child in node.get_children():
		var result = _find_node_by_name(child, target_name)
		if result:
			return result
	
	return null

func _find_first_focusable(node: Node) -> Control:
	"""Find the first focusable Control in the node tree."""
	if node is Control and node.focus_mode != Control.FOCUS_NONE:
		return node
	
	for child in node.get_children():
		var result = _find_first_focusable(child)
		if result:
			return result
	
	return null

func _apply_library_background_config() -> void:
	"""Apply the library background configuration from settings."""
	if not _library_background:
		return
	
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_background.set_background_config(config_setting.value.duplicate())
	else:
		# Apply default config
		var default_gradient = Gradient.new()
		default_gradient.offsets = [0.0, 1.0]
		default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
		
		_library_background.set_background_config({
			"effect_id": "gradient",
			"settings": {
				"background_gradient": default_gradient,
				"gradient_direction": 0
			}
		})

func _setup_library_appearance() -> void:
	"""Apply library background configuration to the LibraryBackground."""
	# Update the library background configuration from settings
	_apply_library_background_config()
	
	# Make TabContainer background transparent so we can see the LibraryBackground behind it
	var transparent_style = StyleBoxFlat.new()
	transparent_style.bg_color = Color(0, 0, 0, 0)  # Transparent
	_tab_container.add_theme_stylebox_override("panel", transparent_style)

func _on_tab_changed(tab_idx: int):
	var tab_title = _tab_container.get_tab_title(tab_idx)
	
	# Hide current view
	if _current_view:
		_current_view.on_view_hide()
	
	# Show new view
	if _views.has(tab_title):
		_current_view = _views[tab_title]
		_current_view.on_view_show()
		
		# Update hero image visibility based on view
		_update_hero_visibility(tab_title)
		

func _update_hero_visibility(_view_name: String) -> void:
	"""Show/hide hero image, spacer, and library background based on current view and settings."""
	# In dual screen mode, main hero should always be hidden (shown on second screen instead)
	if _dual_screen_active:
		if _hero_image:
			_hero_image.visible = false
		if _hero_spacer:
			_hero_spacer.visible = false
		return
	
	# Check if hero height is set to 0% (hidden)
	var height_ratio = HERO_SIZE_RATIO_DEFAULT
	if SettingsManager:
		var hero_config_setting = SettingsManager.get_setting("hero_effect_config")
		if hero_config_setting and hero_config_setting.value is Dictionary:
			var hero_config = hero_config_setting.value
			var height_index = hero_config.get("hero_height", 0)
			# Better type checking that handles float/int conversion (same as _update_hero_size)
			if height_index is int or height_index is float:
				var index = int(height_index)
				if index >= 0 and index < HERO_HEIGHT_RATIOS.size():
					height_ratio = HERO_HEIGHT_RATIOS[index]
	var hero_enabled = height_ratio > 0.0
	
	# Show background for all main views (Settings is now a dialog overlay)
	var show_background = true
	
	# Update hero image visibility (only visible when enabled AND showing background)
	if _hero_image:
		_hero_image.visible = show_background and hero_enabled
		
		if show_background and hero_enabled:
			# Clear hero when switching to a view that shows it
			_hero_image.clear()
	
	# Update spacer visibility (only when hero is enabled)
	if _hero_spacer:
		_hero_spacer.visible = show_background and hero_enabled
	
	# Update library background visibility (always show)
	if _library_background:
		_library_background.visible = true

func _on_hero_game_changed(game: GameResource) -> void:
	"""Handle hero game change from views."""
	if not _hero_image:
		return
	
	# Only update hero image if we're in Home or Library view
	var current_view_name = _current_view.view_name if _current_view else ""
	
	if current_view_name not in ["Home", "Library"]:
		return
	
	# Check if hero height is set to 0% (hidden)
	var height_ratio = HERO_SIZE_RATIO_DEFAULT
	if SettingsManager:
		var hero_config_setting = SettingsManager.get_setting("hero_effect_config")
		if hero_config_setting and hero_config_setting.value is Dictionary:
			var hero_config = hero_config_setting.value
			var height_index = hero_config.get("hero_height", 0)
			if height_index is int and height_index >= 0 and height_index < HERO_HEIGHT_RATIOS.size():
				height_ratio = HERO_HEIGHT_RATIOS[height_index]
	if height_ratio == 0.0:
		return
	
	if game:
		_hero_image.set_game(game)
		# Also set game on second screen hero if dual screen is active
		if _dual_screen_active and _hero_copy_in_second_viewport and _hero_copy_in_second_viewport.has_method("set_game"):
			_hero_copy_in_second_viewport.set_game(game)
		# Force viewport update for UPDATE_ONCE mode
		if _dual_screen_active:
			var ayn_thor_manager = get_node_or_null("/root/Main/AynThorManager")
			if ayn_thor_manager and ayn_thor_manager.has_method("force_hero_viewport_update"):
				ayn_thor_manager.force_hero_viewport_update()
	else:
		_hero_image.clear()
		if _dual_screen_active and _hero_copy_in_second_viewport and _hero_copy_in_second_viewport.has_method("clear"):
			_hero_copy_in_second_viewport.clear()

func get_current_view() -> View:
	return _current_view

func is_current_view(view_name: String) -> bool:
	"""Check if a view by name is the currently active view."""
	if _current_view == null:
		return false
	return _current_view.view_name == view_name

func is_node_in_current_view(node: Node) -> bool:
	"""Check if a node belongs to the currently active view."""
	if _current_view == null or node == null:
		return false
	
	# Traverse up the tree to find if this node is a child of the current view
	var current = node
	while current != null:
		if current == _current_view:
			return true
		current = current.get_parent()
	
	return false

func rebuild_game_grid() -> void:
	"""Rebuild the library view to reflect card size changes."""
	if _views.has("Library"):
		var library_view = _views["Library"]
		if library_view.has_method("rebuild_grid"):
			library_view.rebuild_grid()

func get_view(view_name: String) -> View:
	if _views.has(view_name):
		return _views[view_name]
	return null

func get_settings_dialog_platforms_view() -> PlatformsSettingsView:
	if _settings_dialog and is_instance_valid(_settings_dialog):
		return _settings_dialog.get_platforms_settings_view()
	return null

func switch_to_tab(tab_name: String):
	var idx = _get_tab_index(tab_name)
	if idx != -1:
		_tab_container.current_tab = idx

func get_nav_type() -> int:
	"""Get the current navigation type (0 = Bar, 1 = Rail)."""
	return _nav_type

# ==================== FOCUS FEEDBACK (Navigation Sounds) ====================

func _setup_feedback_handlers() -> void:
	"""Connect to viewport focus changes for navigation sounds."""
	_reconnect_feedback_viewport()

func _reconnect_feedback_viewport() -> void:
	"""Reconnect feedback handlers to the current viewport."""
	if _feedback_connected_viewport and is_instance_valid(_feedback_connected_viewport):
		if _feedback_connected_viewport.gui_focus_changed.is_connected(_on_feedback_focus_changed):
			_feedback_connected_viewport.gui_focus_changed.disconnect(_on_feedback_focus_changed)
	
	var viewport = get_viewport()
	if is_instance_valid(viewport):
		if viewport.gui_focus_changed.is_connected(_on_feedback_focus_changed):
			viewport.gui_focus_changed.disconnect(_on_feedback_focus_changed)
		viewport.gui_focus_changed.connect(_on_feedback_focus_changed)
		_feedback_connected_viewport = viewport

func _on_feedback_focus_changed(control: Control) -> void:
	"""Play navigation sounds on focus changes."""
	if not is_instance_valid(control):
		return
	
	# Skip text edits
	if control is LineEdit or control is TextEdit:
		return
	
	# Skip game cards (they handle their own focus sound)
	if _control_is_game_card(control):
		return
	
	# Skip first focus (app startup)
	if _is_first_focus:
		_is_first_focus = false
		return
	
	# Non-game card focus - play generic click sound
	if AudioManager:
		AudioManager.play_sfx("click_00")

func _control_is_game_card(control: Control) -> bool:
	"""Traverse up the tree to check if control is inside a GameCard."""
	var ancestor = control
	while ancestor:
		if ancestor is GameCard:
			return true
		ancestor = ancestor.get_parent()
	return false

func _unhandled_input(event: InputEvent) -> void:
	"""Play activation sound on ui_accept for non-game card elements."""
	if event.is_action_pressed("ui_accept"):
		var focused = get_viewport().gui_get_focus_owner()
		if focused and is_instance_valid(focused) and not _control_is_game_card(focused):
			if AudioManager:
				AudioManager.play_sfx("click_03")

# ==================== MODAL MANAGEMENT ====================

func _setup_focus_indicator() -> void:
	"""Create and add the global focus indicator.
	Disabled for now — M3 components provide their own focus visuals."""
	pass
	# _focus_indicator = FocusIndicator.new()
	# _focus_indicator.name = "FocusIndicator"
	# _root_control.add_child(_focus_indicator)

func show_context_menu(items: Array[Dictionary], anchor: Control, context: Dictionary = {}) -> String:
	"""Show a context menu modal anchored to the given control. Returns modal ID."""
	dismiss_modal()
	
	var menu = M3Menu.new()
	
	# Store context
	_modal_context = context.duplicate()
	var modal_id = str(Time.get_unix_time_from_system())
	_modal_context["modal_id"] = modal_id
	
	# Build menu items with callbacks
	for item in items:
		var item_id = item.get("id", "")
		var item_text = item.get("text", "")
		var item_icon = item.get("icon", "")
		var item_disabled = item.get("disabled", false)
		
		var callback = func():
			modal_item_selected.emit(item_id, _modal_context.duplicate())
			dismiss_modal()
		
		menu.add_item(item_text, callback, item_icon)
		if item_disabled:
			menu.get_item(menu.get_item_count() - 1).disabled = true
	
	# Add scrim backdrop to block interaction with content below
	var scrim = ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.5)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	menu.add_child(scrim)
	
	# Find and pause the scroll container so the anchor doesn't move
	var scroll_container = anchor
	while scroll_container:
		if scroll_container is SmoothScrollContainer:
			scroll_container.scroll_paused = true
			break
		scroll_container = scroll_container.get_parent()
	
	# Connect dismissed signal — cleanup happens here so dismiss_modal() doesn't double-fire
	menu.dismissed.connect(func():
		if scroll_container and is_instance_valid(scroll_container):
			scroll_container.scroll_paused = false
		_active_menu = null
		_modal_context.clear()
		modal_dismissed.emit(modal_id)
	, CONNECT_ONE_SHOT)
	
	_active_menu = menu
	menu.popup(anchor)
	
	modal_shown.emit(modal_id)
	return modal_id

func show_game_context_menu(romm_id: int, anchor: Control, show_delete: bool = true) -> String:
	"""Show the standard game context menu."""
	var items: Array[Dictionary] = [
		{"id": "launch", "text": "Launch", "icon": "play"},
		{"id": "details", "text": "Details", "icon": "information"}
	]
	
	# Add delete option only if game is downloaded and show_delete is true
	var game = DataManager.get_game_by_id(romm_id)
	if show_delete and game and game.is_active_variant_downloaded():
		items.append({"id": "delete", "text": "Delete", "icon": "trash-can"})
		
		# Add "Add to Steam" option if game is downloaded and Steam folder is configured
		var steam_folder = SettingsManager.get_setting("steam_folder")
		if steam_folder and not steam_folder.value.is_empty() and SteamVDFWriter.is_valid_steam_path(steam_folder.value):
			items.append({"id": "add_to_steam", "text": "Add to Steam"})
	
	items.append({"id": "card_designer", "text": "Card Designer", "icon": "cards-outline"})
	items.append({"id": "hide", "text": "Hide", "icon": "eye-off"})
	return show_context_menu(items, anchor, {"romm_id": romm_id})

func dismiss_modal() -> void:
	"""Dismiss the active menu if one exists.
	Cleanup and modal_dismissed emission are handled by the menu's dismissed signal."""
	if _active_menu != null and is_instance_valid(_active_menu) and _active_menu.is_open():
		_active_menu.dismiss()
	# If menu is already closed, the dismissed callback already cleaned up.

func is_modal_open() -> bool:
	"""Returns whether a modal is currently displayed."""
	return _active_menu != null and is_instance_valid(_active_menu) and _active_menu.is_open()

# ==================== DUAL SCREEN MODE ====================

var _dual_screen_active: bool = false
var _dual_screen_viewport_mode: bool = false
var _hero_copy_in_second_viewport: Node = null

# Node reparenting state for Android dual screen
var _main_ui_original_parent: Node = null
var _ui_layer_original_parent: Node = null
var _settings_dialog_original_parent: Node = null
var _is_nodes_reparented: bool = false
var _viewport_layout: Node = null

func _on_dual_screen_mode_changed(enabled: bool, second_screen_index: int) -> void:
	"""Handle dual screen mode changes from DisplayManager."""
	if enabled:
		_enable_dual_screen_mode(second_screen_index)
	else:
		_disable_dual_screen_mode()

func _enable_dual_screen_mode(second_screen_index: int) -> void:
	"""Enable dual screen mode - show HeroImage on second display."""
	if _dual_screen_active:
		return
	
	if not _hero_image:
		push_error("[UIManager] Cannot enable dual screen - hero image not available")
		return
	
	# Check if AynThor plugin is available (Android dual screen)
	var has_aynthor = Engine.has_singleton("AynThor")
	
	if has_aynthor and PlatformManager.is_android():
		# Use dual screen viewport plugin (works on any dual screen Android device)
		_enable_dual_screen_viewport_mode()
	else:
		# Desktop: use Godot Window approach
		_enable_dual_screen_mode_desktop.call_deferred(second_screen_index)

func _enable_dual_screen_viewport_mode() -> void:
	"""Enable dual screen using viewport plugin (generic dual screen support)."""
	
	# Ensure DualScreenSetup is in the tree (it may have been removed on desktop)
	var main_node = get_node_or_null("/root/Main")
	var dual_screen_setup = null
	var second_viewport = null
	_hero_copy_in_second_viewport = null
	
	if main_node and main_node.has_method("ensure_dual_screen_setup"):
		dual_screen_setup = main_node.ensure_dual_screen_setup()
	else:
		dual_screen_setup = get_node_or_null("/root/Main/DualScreenSetup")
	
	if dual_screen_setup:
		second_viewport = dual_screen_setup.get_node_or_null("SecondViewportContainer/SecondViewport")
		_hero_copy_in_second_viewport = dual_screen_setup.get_node_or_null("SecondViewportContainer/SecondViewport/HeroImageSecondScreen")
	
	if not dual_screen_setup or not second_viewport or not _hero_copy_in_second_viewport:
		push_warning("[UIManager] Dual screen setup nodes not found")
		return
	
	# Dismiss any active M3 overlays before reparenting so they don't get stranded
	M3Overlay.dismiss_type("menu")
	M3Overlay.dismiss_type("snackbar")
	M3Overlay.dismiss_type("dialog")
	M3Overlay.dismiss_type("tooltip")
	M3Overlay.dismiss_type("sheet")

	# REPARENTING: Move main UI nodes into MainViewport
	var main_viewport = dual_screen_setup.get_node_or_null("MainViewportContainer/MainViewport")
	if main_viewport:
		# Mark viewport as overlay parent so M3 components render inside it
		main_viewport.add_to_group("m3_overlay_parent")
		# Enable local input handling so touch/mouse events are processed inside the viewport
		main_viewport.handle_input_locally = true
		_reparent_ui_to_main_viewport(main_viewport)
	
	# Enable local input handling on second viewport as well
	if second_viewport:
		second_viewport.handle_input_locally = true
	
	# Hide hero in main UI since it will be on second screen
	if _hero_spacer:
		_hero_spacer.visible = false
		_hero_spacer.custom_minimum_size = Vector2.ZERO
	if _hero_image:
		_hero_image.set_dual_screen_mode(true)
	
	# Sync current game to second screen hero
	var current_game = null
	if _hero_image:
		if _hero_image.has_method("get_current_game"):
			current_game = _hero_image.get_current_game()
			if current_game and _hero_copy_in_second_viewport.has_method("set_game"):
				_hero_copy_in_second_viewport.set_game(current_game)
	
	# Position and make dual screen setup visible
	# MainViewportContainer will be at (0,0) relative to this, so position at (0,0)
	dual_screen_setup.position = Vector2.ZERO
	dual_screen_setup.visible = true
	
	_dual_screen_active = true
	_dual_screen_viewport_mode = true
	
	# Apply SubViewport-based UI scaling (disables Window scaling, scales inside SubViewports)
	DisplayManager.enter_subviewport_dual_screen_mode()

func _disable_dual_screen_mode() -> void:
	"""Disable dual screen mode - restore HeroImage to main layout."""
	if not _dual_screen_active:
		return
	
	# Remove main viewport from overlay parent group so M3 components attach to root viewport
	var dual_screen_setup = null
	var main_node = get_node_or_null("/root/Main")
	if main_node and main_node.has_method("ensure_dual_screen_setup"):
		dual_screen_setup = main_node.ensure_dual_screen_setup()
	else:
		dual_screen_setup = get_node_or_null("/root/Main/DualScreenSetup")
	
	if dual_screen_setup:
		var main_viewport = dual_screen_setup.get_node_or_null("MainViewportContainer/MainViewport")
		if main_viewport:
			main_viewport.remove_from_group("m3_overlay_parent")
	
	# Restore UI nodes to original parents first
	_restore_ui_to_original_parents()
	
	if _dual_screen_viewport_mode:
		# Restore input handling to default (forward to parent viewport)
		var main_vp = null
		var second_vp = null
		if dual_screen_setup:
			main_vp = dual_screen_setup.get_node_or_null("MainViewportContainer/MainViewport")
			second_vp = dual_screen_setup.get_node_or_null("SecondViewportContainer/SecondViewport")
		if main_vp:
			main_vp.handle_input_locally = false
		if second_vp:
			second_vp.handle_input_locally = false
		
		# Remove dual screen setup from tree (prevents input interference on desktop)
		main_node = get_node_or_null("/root/Main")
		if main_node and main_node.has_method("remove_dual_screen_setup"):
			main_node.remove_dual_screen_setup()
		else:
			dual_screen_setup = get_node_or_null("/root/Main/DualScreenSetup")
			if dual_screen_setup:
				dual_screen_setup.visible = false
				dual_screen_setup.position = Vector2(-10000, -10000)
		
		_dual_screen_viewport_mode = false
	else:
		# Desktop: close secondary window
		_disable_dual_screen_mode_desktop()
	
	# Clear SubViewport-based UI scaling and restore Window scaling
	DisplayManager.exit_subviewport_dual_screen_mode()
	
	# Show hero in main UI again
	if _hero_image:
		_hero_image.set_dual_screen_mode(false)
	
	# Show hero spacer again
	if _hero_spacer:
		_hero_spacer.visible = true
		_update_hero_size()  # This will set the correct spacer size
	
	_dual_screen_active = false

func _reparent_ui_to_main_viewport(main_viewport: SubViewport) -> void:
	"""Reparent RootLayout into MainViewport for dual screen.
	
	The RootLayout contains the full UI hierarchy including InnerLayout (which holds
	M3 nav and ContentWrapper), so we only need to reparent RootLayout.
	"""
	if _is_nodes_reparented:
		return
	
	# Store original parent
	if _root_control:
		_main_ui_original_parent = _root_control.get_parent()
	
	# Find and store UILayer original parent
	var ui_layer = get_node_or_null("/root/Main/UILayer")
	if ui_layer:
		_ui_layer_original_parent = ui_layer.get_parent()
	
	# Store SettingsDialog original parent and remove it from _root_control
	# CanvasLayers must not be nested inside VBoxContainer inside SubViewport
	if _settings_dialog and _settings_dialog.get_parent():
		_settings_dialog_original_parent = _settings_dialog.get_parent()
		_settings_dialog.get_parent().remove_child(_settings_dialog)
	
	# Remove RootLayout from current parent (this includes M3 nav via InnerLayout)
	if _root_control and _root_control.get_parent():
		_root_control.get_parent().remove_child(_root_control)
	
	# Remove UILayer from its current parent
	if ui_layer and ui_layer.get_parent():
		ui_layer.get_parent().remove_child(ui_layer)
	
	# Create layout container within the viewport
	_viewport_layout = VBoxContainer.new()
	_viewport_layout.name = "ViewportLayout"
	_viewport_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_viewport.add_child(_viewport_layout)
	
	# Add RootLayout (fills viewport, includes InnerLayout with Navbar + ContentWrapper)
	_root_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_layout.add_child(_root_control)
	
	# Add UILayer directly to MainViewport (CanvasLayer can't go in VBoxContainer)
	if ui_layer:
		main_viewport.add_child(ui_layer)
	
	# Add SettingsDialog directly to MainViewport (same reason as UILayer)
	if _settings_dialog:
		main_viewport.add_child(_settings_dialog)
	
	_is_nodes_reparented = true
	
	# Reconnect FocusIndicator to new viewport after reparenting
	if _focus_indicator and is_instance_valid(_focus_indicator):
		_focus_indicator.reconnect_viewport()
	
	# Reconnect OnscreenKeyboard to new viewport after reparenting
	var keyboard = get_node_or_null("/root/Main/UILayer/OnscreenKeyboard")
	if keyboard and keyboard.has_method("reconnect_viewport"):
		keyboard.reconnect_viewport()
	
	# Reconnect HomeView and LibraryView to new viewport after reparenting
	var home_view = get_view("Home")
	if home_view and home_view.has_method("reconnect_viewport"):
		home_view.reconnect_viewport()
	
	var library_view = get_view("Library")
	if library_view and library_view.has_method("reconnect_viewport"):
		library_view.reconnect_viewport()
	
	# Reconnect all other views that support viewport reconnection
	for view_name in ["Downloads", "Platforms"]:
		var view = get_view(view_name)
		if view and view.has_method("reconnect_viewport"):
			view.reconnect_viewport()
	
	# Reconnect feedback handlers to new viewport
	_reconnect_feedback_viewport()

func _restore_ui_to_original_parents() -> void:
	"""Restore RootLayout to its original parent.
	
	RootLayout contains the full UI hierarchy including InnerLayout (which holds
	M3 nav and ContentWrapper), so restoring RootLayout restores everything.
	"""
	if not _is_nodes_reparented:
		return
	
	# Remove viewport layout from MainViewport
	if _viewport_layout:
		# Remove children first
		for child in _viewport_layout.get_children():
			_viewport_layout.remove_child(child)
		_viewport_layout.queue_free()
		_viewport_layout = null
	
	# Restore RootLayout (this restores the full hierarchy including InnerLayout with Navbar)
	if _root_control and _main_ui_original_parent:
		if _root_control.get_parent():
			_root_control.get_parent().remove_child(_root_control)
		_main_ui_original_parent.add_child(_root_control)
	
	# Restore UILayer
	var ui_layer = get_node_or_null("/root/Main/UILayer")
	if ui_layer and _ui_layer_original_parent:
		if ui_layer.get_parent():
			ui_layer.get_parent().remove_child(ui_layer)
		_ui_layer_original_parent.add_child(ui_layer)
	
	# Restore SettingsDialog to its original parent (or _root_control as fallback)
	if _settings_dialog:
		if _settings_dialog.get_parent():
			_settings_dialog.get_parent().remove_child(_settings_dialog)
		if _settings_dialog_original_parent:
			_settings_dialog_original_parent.add_child(_settings_dialog)
		else:
			# Created after reparenting — move back to _root_control
			_root_control.add_child(_settings_dialog)
	
	_is_nodes_reparented = false
	_main_ui_original_parent = null
	_ui_layer_original_parent = null
	_settings_dialog_original_parent = null
	
	# Reconnect FocusIndicator to original viewport after restoring
	if _focus_indicator and is_instance_valid(_focus_indicator):
		_focus_indicator.reconnect_viewport()
	
	# Reconnect OnscreenKeyboard to original viewport after restoring
	var keyboard = get_node_or_null("/root/Main/UILayer/OnscreenKeyboard")
	if keyboard and keyboard.has_method("reconnect_viewport"):
		keyboard.reconnect_viewport()
	
	# Reconnect HomeView and LibraryView to original viewport after restoring
	var home_view = get_view("Home")
	if home_view and home_view.has_method("reconnect_viewport"):
		home_view.reconnect_viewport()
	
	var library_view = get_view("Library")
	if library_view and library_view.has_method("reconnect_viewport"):
		library_view.reconnect_viewport()
	
	# Reconnect feedback handlers to original viewport
	_reconnect_feedback_viewport()

# ==================== DUAL SCREEN DESKTOP FALLBACK ====================

var _hero_secondary_window: Window = null
var _hero_original_parent: Node = null

func _enable_dual_screen_mode_desktop(second_screen_index: int) -> void:
	"""Desktop fallback: Use Godot Window for dual screen."""
	# Use call_deferred to avoid race conditions during _ready()
	_setup_desktop_dual_screen.call_deferred(second_screen_index)

func _setup_desktop_dual_screen(_second_screen_index: int) -> void:
	"""Setup desktop dual screen (called deferred to avoid race conditions)."""
	# Store reference to original parent
	_hero_original_parent = _hero_image.get_parent()
	
	# Get second screen bounds
	var screen_rect = DisplayManager.get_second_screen_rect()
	if screen_rect.size == Vector2i.ZERO:
		push_warning("[UIManager] Second screen has zero size, aborting dual screen mode")
		return
	
	# Create a secondary window for the hero image
	_hero_secondary_window = Window.new()
	_hero_secondary_window.title = "Kyodai - Hero"
	_hero_secondary_window.size = screen_rect.size
	_hero_secondary_window.position = screen_rect.position
	_hero_secondary_window.exclusive = false
	_hero_secondary_window.always_on_top = false
	_hero_secondary_window.borderless = true
	_hero_secondary_window.unresizable = true
	
	# Reparent hero image to secondary window
	if _hero_image.get_parent():
		_hero_image.get_parent().remove_child(_hero_image)
	
	_hero_secondary_window.add_child(_hero_image)
	
	# Make hero image fill the window
	_hero_image.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hero_image.offset_bottom = 0
	_hero_image.position = Vector2.ZERO
	# DISABLED: Setting size on FULL_RECT controls fights Godot's layout system
	# and causes wrong sizes when the parent resizes between deferral and execution.
	# Anchors handle sizing automatically.
	# _hero_image.set_deferred("size", Vector2(screen_rect.size))
	
	# Add window to scene tree
	get_tree().root.add_child(_hero_secondary_window)
	
	# Hide hero spacer since hero is now in separate window
	if _hero_spacer:
		_hero_spacer.visible = false
		_hero_spacer.custom_minimum_size = Vector2.ZERO
	
	_dual_screen_active = true

func _disable_dual_screen_mode_desktop() -> void:
	"""Desktop fallback: Close secondary window and restore hero."""
	# Remove hero from secondary window
	if _hero_image and _hero_image.get_parent() == _hero_secondary_window:
		_hero_secondary_window.remove_child(_hero_image)
	
	# Restore hero to original parent
	if _hero_original_parent and _hero_image:
		_hero_original_parent.add_child(_hero_image)
		_update_hero_size()
	
	# Close secondary window
	if _hero_secondary_window:
		_hero_secondary_window.queue_free()
		_hero_secondary_window = null
	
	_hero_original_parent = null

# ==================== GAME DETAILS VIEW ====================

func show_game_details(romm_id: int) -> void:
	"""Show the game details view for a specific game."""
	var game = DataManager.get_game_by_id(romm_id)
	if not game:
		push_warning("[UIManager] Cannot show details - game not found: ", romm_id)
		return
	
	# Create details tab if it doesn't exist
	if _details_tab_idx == -1:
		var details_scene = preload("res://view/game_details_view.tscn")
		_game_details_view = details_scene.instantiate()
		_game_details_view.view_name = "Details"
		
		_tab_container.add_child(_game_details_view)
		_details_tab_idx = _tab_container.get_tab_count() - 1
		_tab_container.set_tab_title(_details_tab_idx, "Details")
		_views["Details"] = _game_details_view
	
	# Set the game data
	_game_details_view.set_game(game)
	
	# Switch to the details tab
	_tab_container.current_tab = _details_tab_idx
