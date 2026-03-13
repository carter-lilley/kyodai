extends Manager

# UIManager - Manages tab-based view navigation and modal overlays
# Uses "always present" architecture with targeted container replacement

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

# Layout management - NEW ARCHITECTURE
var _root_control: Control = null  # Plain control, never replaced
var _inner_layout: BoxContainer = null  # VBox or HBox, replaced only on orientation change
var _navigation_bar: NavigationBar = null
var _current_bar_position: String = "bottom"

# Position index mapping
const BAR_POSITIONS = ["bottom", "top", "left", "right"]

# Bar sizing constants
const BAR_SIZE_RATIO_HORIZONTAL = 0.075  # 7.5% of viewport height for top/bottom
const BAR_SIZE_RATIO_VERTICAL = 0.05     # 5% of viewport width for left/right

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

# Modal management
var _active_modal: Modal = null
var _modal_context: Dictionary = {}
var _modal_backdrop: ColorRect = null
var _is_dismissing: bool = false
var _focus_indicator: FocusIndicator = null

# Game details tab
var _details_tab_idx: int = -1
var _game_details_view: View = null

# Signals
signal modal_shown(modal_id: String)
signal modal_dismissed(modal_id: String)
signal modal_item_selected(item_id: String, context: Dictionary)
signal tab_changed(view_name: String)
signal layout_changed(position: String)

func initialize(
	tab_container: TabContainer,
	navigation_bar: NavigationBar,
	hero_image: HeroImage,
	hero_spacer: Control,
	library_background: LibraryBackground,
	content_wrapper: Control,
	main_content_vbox: VBoxContainer,
	root_layout: Control
) -> void:
	"""Initialize UIManager with all pre-built nodes from main.tscn."""
	
	# Debug: Log received nodes
	# Store references to all pre-built nodes
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	
	_navigation_bar = navigation_bar
	_hero_image = hero_image
	_hero_spacer = hero_spacer
	_library_background = library_background
	_content_wrapper = content_wrapper
	_main_content_vbox = main_content_vbox
	_root_control = root_layout
	
	# Get current position setting
	var position_setting = SettingsManager.get_setting("library_navigation_bar_position")
	if position_setting:
		_current_bar_position = _get_bar_position_string(position_setting.value)
	
	var is_horizontal = _current_bar_position in ["top", "bottom"]
	
	# Create InnerLayout (VBox or HBox based on orientation)
	_inner_layout = _create_inner_layout(is_horizontal)
	_root_control.add_child(_inner_layout)
	
	# Remove NavigationBar from Main and ContentWrapper from RootLayout (they're direct children now)
	# We'll reparent them into InnerLayout
	if _navigation_bar.get_parent():
		_navigation_bar.get_parent().remove_child(_navigation_bar)
	if _content_wrapper.get_parent():
		_content_wrapper.get_parent().remove_child(_content_wrapper)
	
	# Add NavigationBar and ContentWrapper to InnerLayout in correct order
	_update_inner_layout_children()
	
	# Ensure MainContentVBox fills ContentWrapper
	_main_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_content_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Connect viewport resize first
	_connect_viewport_resize()
	
	# Update sizes immediately - nodes should be ready now
	_update_bar_size()
	_update_hero_size()
	
	# Apply colors
	_apply_navigation_bar_colors()
	
	# Setup existing tabs
	_setup_home_tab()
	_setup_library_tab()
	_setup_downloads_tab()
	_setup_settings_tab()
	
	# Set initial current view based on current tab
	var current_tab_idx = _tab_container.current_tab
	var current_tab_title = _tab_container.get_tab_title(current_tab_idx)
	if _views.has(current_tab_title):
		_current_view = _views[current_tab_title]
		_current_view.on_view_show()
		_update_hero_visibility(current_tab_title)
	
	# Setup modal input handling
	_setup_modal_input_handling()
	
	# Setup focus indicator
	_setup_focus_indicator()
	
	# Setup library appearance
	_setup_library_appearance()
	SettingsManager.setting_changed.connect(_on_setting_changed)
	
	# Connect to dual screen mode changes
	if DisplayManager:
		DisplayManager.dual_screen_mode_changed.connect(_on_dual_screen_mode_changed)
		
		# Debug: Check plugin availability
		print("[UIManager] Checking dual screen plugins...")
		print("[UIManager] Platform: ", OS.get_name())
		print("[UIManager] AynThor singleton available: ", Engine.has_singleton("AynThor"))
		
		# Check initial dual screen state (delay to allow plugins to initialize)
		if DisplayManager.is_dual_screen_enabled():
			print("[UIManager] Dual screen enabled, will initialize shortly...")
			print("[UIManager] About to call _initialize_dual_screen.call_deferred()")
			# Try calling directly first to see if deferred is the issue
			_initialize_dual_screen()
			print("[UIManager] _initialize_dual_screen() returned (direct call)")
	
	# Set initial focus
	_set_initial_focus()
	
	print("[UIManager] Initialized with pre-built nodes, position: ", _current_bar_position)

func _initialize_dual_screen() -> void:
	print("[UIManager] >>> _initialize_dual_screen() ENTERED <<<")
	"""Initialize dual screen mode (called deferred to allow plugin initialization)."""
	print("[UIManager] Initializing dual screen mode (deferred)...")
	print("[UIManager] AynThor singleton check: ", Engine.has_singleton("AynThor"))
	print("[UIManager] DisplayManager second screen index: ", DisplayManager.get_second_screen_index())
	_on_dual_screen_mode_changed(true, DisplayManager.get_second_screen_index())
	print("[UIManager] _initialize_dual_screen() COMPLETED")

func _get_bar_position_string(index: int) -> String:
	"""Convert position index to string."""
	if index >= 0 and index < BAR_POSITIONS.size():
		return BAR_POSITIONS[index]
	return "bottom"

func _connect_viewport_resize() -> void:
	"""Connect to viewport resize signal to update bar size."""
	if get_viewport():
		get_viewport().size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	"""Handle viewport resize - update bar and hero sizes."""
	_update_bar_size()
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
	"""Update the order of children in InnerLayout based on bar position."""
	
	# Remove existing children
	for child in _inner_layout.get_children():
		_inner_layout.remove_child(child)
	
	var is_horizontal = _current_bar_position in ["top", "bottom"]
	
	# Configure size flags for NavigationBar (fixed size based on bar ratio)
	if is_horizontal:
		_navigation_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_navigation_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	else:
		_navigation_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_navigation_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Configure size flags for ContentWrapper (expand to fill remaining space)
	_content_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Add in correct order
	match _current_bar_position:
		"top", "left":
			_inner_layout.add_child(_navigation_bar)
			_inner_layout.add_child(_content_wrapper)
		"bottom", "right", _:
			_inner_layout.add_child(_content_wrapper)
			_inner_layout.add_child(_navigation_bar)
	
	# Configure navigation bar orientation
	if is_horizontal:
		_navigation_bar.set_orientation(NavigationBar.BarOrientation.HORIZONTAL)
	else:
		_navigation_bar.set_orientation(NavigationBar.BarOrientation.VERTICAL)

# ============================================================================
# Layout Updates (No rebuilding, just property changes)
# ============================================================================

func _update_layout_orientation() -> void:
	"""Update layout when orientation changes. Only replaces InnerLayout if needed."""
	
	var position_setting = SettingsManager.get_setting("library_navigation_bar_position")
	if position_setting:
		_current_bar_position = _get_bar_position_string(position_setting.value)
	
	var is_horizontal = _current_bar_position in ["top", "bottom"]
	var current_is_horizontal = _inner_layout is VBoxContainer
	
	# Only replace InnerLayout if orientation type changed
	if is_horizontal != current_is_horizontal:
		print("[UIManager] Orientation changed, replacing InnerLayout...")
		
		# IMPORTANT: Remove children from old layout BEFORE freeing it
		# Otherwise queue_free() will destroy NavigationBar and ContentWrapper too!
		if _navigation_bar.get_parent() == _inner_layout:
			_inner_layout.remove_child(_navigation_bar)
		if _content_wrapper.get_parent() == _inner_layout:
			_inner_layout.remove_child(_content_wrapper)
		
		# Create new InnerLayout
		var new_layout = _create_inner_layout(is_horizontal)
		
		# Replace old layout
		_root_control.remove_child(_inner_layout)
		_inner_layout.queue_free()
		_inner_layout = new_layout
		_root_control.add_child(_inner_layout)
		
		# Re-add children in correct order (they're now orphaned but still valid)
		_update_inner_layout_children()
	else:
		# Just update child order
		_update_inner_layout_children()
	
	# Update sizes
	_update_bar_size()
	_update_hero_size()
	
	# Emit signal
	layout_changed.emit(_current_bar_position)

# ============================================================================
# Existing methods (preserved functionality)
# ============================================================================

func _update_hero_size() -> void:
	"""Update hero image size and spacer. Only property changes, no tree manipulation."""
	
	# Safety checks - fail fast so we can see the actual issue
	if _hero_image == null:
		push_error("[UIManager] CRITICAL: _hero_image is null! This should have been set in initialize()")
		return
	if _hero_spacer == null:
		push_error("[UIManager] CRITICAL: _hero_spacer is null! This should have been set in initialize()")
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
	var raw_setting_value = null
	
	if SettingsManager:
		var height_setting = SettingsManager.get_setting("library_hero_layout_height")
		if height_setting:
			raw_setting_value = height_setting.value
			print("[UIManager] Raw height setting value: ", raw_setting_value, " (type: ", typeof(raw_setting_value), ")")
			# Better type checking that handles float/int conversion
			if height_setting.value is int or height_setting.value is float:
				var index = int(height_setting.value)
				if index >= 0 and index < HERO_HEIGHT_RATIOS.size():
					height_ratio = HERO_HEIGHT_RATIOS[index]
					print("[UIManager] Mapped setting index ", index, " to ratio ", height_ratio)
				else:
					print("[UIManager] WARNING: Setting index ", index, " out of range, using default ", HERO_SIZE_RATIO_DEFAULT)
			else:
				print("[UIManager] WARNING: Setting value is not int/float, using default ", HERO_SIZE_RATIO_DEFAULT)
		else:
			print("[UIManager] WARNING: No height setting found, using default ", HERO_SIZE_RATIO_DEFAULT)
	else:
		print("[UIManager] WARNING: SettingsManager not available, using default ", HERO_SIZE_RATIO_DEFAULT)
	
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
	
	print("[UIManager] Hero height set: ratio=", height_ratio, " target_height=", target_height)
	print("[UIManager] HeroImage offset_bottom: ", _hero_image.offset_bottom)
	print("[UIManager] HeroSpacer min_size: ", _hero_spacer.custom_minimum_size, " visible: ", _hero_spacer.visible)
	
	# Force redraw to apply changes
	_hero_image.queue_redraw()

func _verify_hero_size() -> void:
	"""Debug function to verify hero size after layout update."""
	if _hero_image:
		print("[UIManager] VERIFICATION - HeroImage actual size: ", _hero_image.size)
		print("[UIManager] VERIFICATION - HeroImage offset_bottom: ", _hero_image.offset_bottom)

func _update_bar_size() -> void:
	"""Update navigation bar size based on viewport and orientation."""
	if not _navigation_bar or not is_inside_tree():
		return
	
	var viewport_size = get_viewport().size
	var is_horizontal = _current_bar_position in ["top", "bottom"]
	
	if is_horizontal:
		var target_height = viewport_size.y * BAR_SIZE_RATIO_HORIZONTAL
		_navigation_bar.custom_minimum_size = Vector2(0, target_height)
		_navigation_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_navigation_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	else:
		var target_width = viewport_size.x * BAR_SIZE_RATIO_VERTICAL
		_navigation_bar.custom_minimum_size = Vector2(target_width, 0)
		_navigation_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_navigation_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL

# Keep other existing methods...
func _apply_navigation_bar_colors() -> void:
	"""Apply bar background and icon colors from settings."""
	if not _navigation_bar:
		return
	
	var bar_color_setting = SettingsManager.get_setting("library_bar_color")
	if bar_color_setting:
		_navigation_bar.set_bar_background_color(bar_color_setting.value)
	
	var icon_color_setting = SettingsManager.get_setting("library_icon_color")
	if icon_color_setting:
		_navigation_bar.set_icon_color(icon_color_setting.value)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	"""Handle settings changes."""
	if setting.property_name == "library_background_config":
		# Update the library background with new effect configuration
		if _library_background and _value is Dictionary:
			_library_background.set_background_config(_value.duplicate())
	elif setting.property_name == "library_navigation_bar_position":
		_current_bar_position = _get_bar_position_string(setting.value)
		# Update layout orientation (only replaces InnerLayout if needed)
		_update_layout_orientation()
	elif setting.property_name == "library_hero_layout_height":
		# Update hero image size when height setting changes
		print("[UIManager] Hero layout height changed to index: ", setting.value)
		_update_hero_size()
		# Mark views for rebuild so they reflect the new hero size
		if _views.has("Home"):
			_views["Home"].mark_for_rebuild("Hero height changed")
		if _views.has("Library"):
			_views["Library"].mark_for_rebuild("Hero height changed")
	elif setting.property_name == "library_vertical_layout":
		# Rebuild visible views immediately, mark hidden views for rebuild
		if _views.has("Home"):
			var home_view = _views["Home"]
			if is_current_view("Home"):
				home_view.rebuild_grid()
			else:
				home_view.mark_for_rebuild("Vertical layout changed")
		if _views.has("Library"):
			var library_view = _views["Library"]
			if is_current_view("Library"):
				library_view.rebuild_grid()
			else:
				library_view.mark_for_rebuild("Vertical layout changed")
	elif setting.property_name == "card_effect_config":
		# Rebuild visible views immediately, mark hidden views for rebuild
		if _views.has("Home"):
			var home_view = _views["Home"]
			if is_current_view("Home"):
				home_view.rebuild_grid(true)
			else:
				home_view.mark_for_rebuild("Card effects changed")
		if _views.has("Library"):
			var library_view = _views["Library"]
			if is_current_view("Library"):
				library_view.rebuild_grid(true)
			else:
				library_view.mark_for_rebuild("Card effects changed")
	elif setting.property_name == "hero_effect_config":
		# Refresh hero image when hero effects change
		if _hero_image and _hero_image.has_method("refresh_from_settings"):
			_hero_image.refresh_from_settings()
	elif setting.property_name == "library_grid_padding":
		# Rebuild visible views immediately, mark hidden views for rebuild
		if _views.has("Home"):
			var home_view = _views["Home"]
			if is_current_view("Home"):
				home_view.rebuild_grid()
			else:
				home_view.mark_for_rebuild("Grid padding changed")
		if _views.has("Library"):
			var library_view = _views["Library"]
			if is_current_view("Library"):
				library_view.rebuild_grid()
			else:
				library_view.mark_for_rebuild("Grid padding changed")
	elif setting.property_name == "library_bar_color":
		if _navigation_bar:
			_navigation_bar.set_bar_background_color(setting.value)
	elif setting.property_name == "library_icon_color":
		if _navigation_bar:
			_navigation_bar.set_icon_color(setting.value)

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

func _setup_settings_tab():
	var settings_idx = _get_tab_index("Settings")
	if settings_idx == -1:
		push_warning("[UIManager]: Settings tab not found")
		return
	
	var settings_tab = _tab_container.get_tab_control(settings_idx)
	
	# Clear existing content
	for child in settings_tab.get_children():
		child.queue_free()
	
	# Add SettingsView (auto-generated from SettingsVar)
	var settings_view = SettingsView.new()
	settings_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_view.view_name = "Settings"
	settings_tab.add_child(settings_view)
	_views["Settings"] = settings_view

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
	var home_button = _find_home_button()
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		home_button.grab_focus()
		print("[UIManager] Set initial focus to Home button in navigation bar")
		return
	
	# Fallback: try to focus the first focusable element in the root control
	if _root_control:
		var first_focusable = _find_first_focusable(_root_control)
		if first_focusable:
			first_focusable.grab_focus()
			print("[UIManager] Set initial focus to: " + first_focusable.name)

func _find_home_button() -> Control:
	"""Find the Home button in the navigation bar."""
	if not _navigation_bar:
		return null
	
	# Search recursively for a button named HomeButton
	return _find_node_by_name(_navigation_bar, "HomeButton")

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
			"effect_id": "xmb",
			"background_gradient": default_gradient,
			"gradient_direction": 0,
			"settings": {
				"time_scale": 1.0,
				"show_dust": true,
				"wave_intensity": 1.0,
				"star_threshold": 0.99,
				"color_top_left": Color(0.7, 0.2, 0.2, 1.0),
				"color_top_right": Color(0.4, 0.1, 0.1, 1.0),
				"color_bottom_left": Color(0.45, 0.1, 0.1, 1.0),
				"color_bottom_right": Color(0.8, 0.3, 0.5, 1.0),
				"wave_blend_color": Color.WHITE
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
		
		# Emit tab changed signal for global UI updates
		tab_changed.emit(tab_title)

func _update_hero_visibility(view_name: String) -> void:
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
		var height_setting = SettingsManager.get_setting("library_hero_layout_height")
		# Better type checking that handles float/int conversion (same as _update_hero_size)
		if height_setting and (height_setting.value is int or height_setting.value is float):
			var index = int(height_setting.value)
			if index >= 0 and index < HERO_HEIGHT_RATIOS.size():
				height_ratio = HERO_HEIGHT_RATIOS[index]
	var hero_enabled = height_ratio > 0.0
	
	# Show background for Home/Library/Downloads, hide for Settings
	var show_background = view_name != "Settings"
	
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
		var height_setting = SettingsManager.get_setting("library_hero_layout_height")
		if height_setting and height_setting.value is int and height_setting.value >= 0 and height_setting.value < HERO_HEIGHT_RATIOS.size():
			height_ratio = HERO_HEIGHT_RATIOS[height_setting.value]
	if height_ratio == 0.0:
		return
	
	if game:
		_hero_image.set_game(game)
		# Also set game on second screen hero if dual screen is active
		if _dual_screen_active and _hero_copy_in_second_viewport and _hero_copy_in_second_viewport.has_method("set_game"):
			_hero_copy_in_second_viewport.set_game(game)
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

func switch_to_tab(tab_name: String):
	var idx = _get_tab_index(tab_name)
	if idx != -1:
		_tab_container.current_tab = idx

func get_bar_position() -> String:
	"""Get the current navigation bar position."""
	return _current_bar_position

# ==================== MODAL MANAGEMENT ====================

func _setup_focus_indicator() -> void:
	"""Create and add the global focus indicator."""
	_focus_indicator = FocusIndicator.new()
	_focus_indicator.name = "FocusIndicator"
	_root_control.add_child(_focus_indicator)

func show_context_menu(items: Array[Dictionary], position: Vector2, context: Dictionary = {}) -> String:
	"""Show a context menu modal at the specified position. Returns modal ID."""
	# Dismiss any existing modal first
	dismiss_modal()
	
	# Create backdrop
	_create_backdrop()
	
	# Create and configure modal
	_active_modal = Modal.new(items)
	
	# Store context
	_modal_context = context.duplicate()
	var modal_id = str(Time.get_unix_time_from_system())
	_modal_context["modal_id"] = modal_id
	
	# Connect signals
	_active_modal.item_selected.connect(_on_modal_item_selected)
	_active_modal.dismissed.connect(_on_modal_dismissed)
	
	# Add to scene and show
	_root_control.add_child(_active_modal)
	_active_modal.popup_at_position(position)
	
	modal_shown.emit(modal_id)
	return modal_id

func show_game_context_menu(romm_id: int, position: Vector2, show_delete: bool = true) -> String:
	"""Show the standard game context menu."""
	var items: Array[Dictionary] = [
		{"id": "launch", "text": "Launch"},
		{"id": "details", "text": "Details"}
	]
	
	# Add delete option only if game is downloaded and show_delete is true
	var game = DataManager.get_game_by_id(romm_id)
	if show_delete and game and game.is_active_variant_downloaded():
		items.append({"id": "delete", "text": "Delete"})
		
		# Add "Add to Steam" option if game is downloaded and Steam folder is configured
		var steam_folder = SettingsManager.get_setting("steam_folder")
		if steam_folder and not steam_folder.value.is_empty() and SteamVDFWriter.is_valid_steam_path(steam_folder.value):
			items.append({"id": "add_to_steam", "text": "Add to Steam"})
	
	items.append({"id": "hide", "text": "Hide"})
	return show_context_menu(items, position, {"romm_id": romm_id})

func dismiss_modal() -> void:
	"""Dismiss the active modal if one exists."""
	if _is_dismissing or not _active_modal:
		return
	
	_is_dismissing = true
	var modal_id = _modal_context.get("modal_id", "")
	
	_active_modal.hide()
	_active_modal.queue_free()
	_active_modal = null
	_modal_context.clear()
	
	if _modal_backdrop:
		_modal_backdrop.queue_free()
		_modal_backdrop = null
	
	_is_dismissing = false
	modal_dismissed.emit(modal_id)

func is_modal_open() -> bool:
	"""Returns whether a modal is currently displayed."""
	return _active_modal != null and is_instance_valid(_active_modal)

func _create_backdrop() -> void:
	"""Create a semi-transparent backdrop behind the modal."""
	_modal_backdrop = ColorRect.new()
	_modal_backdrop.color = Color(0, 0, 0, 0.5)
	_modal_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_backdrop.z_index = 90
	_modal_backdrop.top_level = true
	_modal_backdrop.gui_input.connect(_on_backdrop_input)
	_root_control.add_child(_modal_backdrop)

func _on_backdrop_input(event: InputEvent) -> void:
	"""Handle input on backdrop - clicking dismisses modal."""
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		dismiss_modal()

func _on_modal_item_selected(item_id: String) -> void:
	"""Handle item selection from modal."""
	modal_item_selected.emit(item_id, _modal_context.duplicate())
	dismiss_modal()

func _on_modal_dismissed() -> void:
	"""Handle modal dismissal."""
	# This is called when modal closes itself
	if _active_modal:
		dismiss_modal()

func _setup_modal_input_handling() -> void:
	"""Setup global input handling for modal dismiss."""
	# Modal input handling is managed through _unhandled_input
	pass

func _unhandled_input(event: InputEvent) -> void:
	"""Handle global input - Escape dismisses modal."""
	if is_modal_open() and event.is_action_pressed("ui_cancel"):
		dismiss_modal()
		get_viewport().set_input_as_handled()

# ==================== DUAL SCREEN MODE ====================

var _dual_screen_active: bool = false
var _dual_screen_viewport_mode: bool = false
var _hero_copy_in_second_viewport: Node = null

# Node reparenting state for Android dual screen
var _main_ui_original_parent: Node = null
var _navigation_bar_original_parent: Node = null
var _is_nodes_reparented: bool = false
var _viewport_layout: Node = null

func _on_dual_screen_mode_changed(enabled: bool, second_screen_index: int) -> void:
	"""Handle dual screen mode changes from DisplayManager."""
	print("[UIManager] Dual screen mode changed - enabled: ", enabled, ", screen: ", second_screen_index)
	
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
	
	print("[UIManager] Enabling dual screen mode on screen ", second_screen_index)
	
	# Check if AynThor plugin is available (Android dual screen)
	var has_aynthor = Engine.has_singleton("AynThor")
	print("[UIManager] AynThor plugin available: ", has_aynthor)
	
	if has_aynthor and PlatformManager.is_android():
		# Use dual screen viewport plugin (works on any dual screen Android device)
		_enable_dual_screen_viewport_mode()
	else:
		# Desktop: use Godot Window approach
		_enable_dual_screen_mode_desktop.call_deferred(second_screen_index)

func _enable_dual_screen_viewport_mode() -> void:
	"""Enable dual screen using viewport plugin (generic dual screen support)."""
	print("[UIManager] Using dual screen viewport mode")
	
	# Get the dual screen setup nodes
	var dual_screen_setup = get_node("/root/Main/DualScreenSetup")
	var second_viewport = get_node("/root/Main/DualScreenSetup/SecondViewportContainer/SecondViewport")
	_hero_copy_in_second_viewport = get_node_or_null("/root/Main/DualScreenSetup/SecondViewportContainer/SecondViewport/HeroImageSecondScreen")
	
	if not dual_screen_setup or not second_viewport or not _hero_copy_in_second_viewport:
		push_warning("[UIManager] Dual screen setup nodes not found")
		return
	
	print("[UIManager] Found second screen hero: ", _hero_copy_in_second_viewport.name)
	
	# REPARENTING: Move main UI nodes into MainViewport
	var main_viewport = get_node("/root/Main/DualScreenSetup/MainViewportContainer/MainViewport")
	if main_viewport:
		_reparent_ui_to_main_viewport(main_viewport)
	
	# Hide hero in main UI since it will be on second screen
	if _hero_spacer:
		_hero_spacer.visible = false
		_hero_spacer.custom_minimum_size = Vector2.ZERO
	if _hero_image:
		_hero_image.set_dual_screen_mode(true)
	
	# Sync current game to second screen hero
	var current_game = null
	print("[UIManager] DEBUG: _hero_image = ", _hero_image)
	if _hero_image:
		print("[UIManager] DEBUG: _hero_image has get_current_game = ", _hero_image.has_method("get_current_game"))
		if _hero_image.has_method("get_current_game"):
			current_game = _hero_image.get_current_game()
			print("[UIManager] DEBUG: current_game = ", current_game)
			if current_game:
				print("[UIManager] DEBUG: _hero_copy_in_second_viewport has set_game = ", _hero_copy_in_second_viewport.has_method("set_game"))
				if _hero_copy_in_second_viewport.has_method("set_game"):
					print("[UIManager] Setting game on second screen hero: ", current_game.get_display_name() if current_game.has_method("get_display_name") else "unknown")
					_hero_copy_in_second_viewport.set_game(current_game)
	
	# Position and make dual screen setup visible
	# MainViewportContainer will be at (0,0) relative to this, so position at (0,0)
	dual_screen_setup.position = Vector2.ZERO
	dual_screen_setup.visible = true
	
	_dual_screen_active = true
	_dual_screen_viewport_mode = true
	print("[UIManager] Dual screen viewport mode enabled")

func _disable_dual_screen_mode() -> void:
	"""Disable dual screen mode - restore HeroImage to main layout."""
	if not _dual_screen_active:
		return
	
	print("[UIManager] Disabling dual screen mode")
	
	# Restore UI nodes to original parents first
	_restore_ui_to_original_parents()
	
	if _dual_screen_viewport_mode:
		# Hide dual screen setup and move it back off-screen
		var dual_screen_setup = get_node_or_null("/root/Main/DualScreenSetup")
		if dual_screen_setup:
			dual_screen_setup.visible = false
			dual_screen_setup.position = Vector2(-10000, -10000)
		
		_dual_screen_viewport_mode = false
	else:
		# Desktop: close secondary window
		_disable_dual_screen_mode_desktop()
	
	# Show hero in main UI again
	if _hero_image:
		_hero_image.set_dual_screen_mode(false)
	
	# Show hero spacer again
	if _hero_spacer:
		_hero_spacer.visible = true
		_update_hero_size()  # This will set the correct spacer size
	
	_dual_screen_active = false
	print("[UIManager] Dual screen mode disabled")

func _reparent_ui_to_main_viewport(main_viewport: SubViewport) -> void:
	"""Reparent NavigationBar and RootLayout into MainViewport for dual screen."""
	if _is_nodes_reparented:
		return
	
	print("[UIManager] Reparenting UI nodes to MainViewport")
	
	# Store original parents
	if _root_control:
		_main_ui_original_parent = _root_control.get_parent()
	if _navigation_bar:
		_navigation_bar_original_parent = _navigation_bar.get_parent()
	
	# Remove from current parents
	if _root_control and _root_control.get_parent():
		_root_control.get_parent().remove_child(_root_control)
	if _navigation_bar and _navigation_bar.get_parent():
		_navigation_bar.get_parent().remove_child(_navigation_bar)
	
	# Create layout container within the viewport
	_viewport_layout = VBoxContainer.new()
	_viewport_layout.name = "ViewportLayout"
	_viewport_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_viewport.add_child(_viewport_layout)
	
	# Add RootLayout (fills most space)
	_root_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_layout.add_child(_root_control)
	
	# Add NavigationBar (fixed size at bottom)
	_navigation_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_viewport_layout.add_child(_navigation_bar)
	
	_is_nodes_reparented = true
	
	# Reconnect FocusIndicator to new viewport after reparenting
	if _focus_indicator and is_instance_valid(_focus_indicator):
		_focus_indicator.reconnect_viewport()
	
	# Reconnect HomeView and LibraryView to new viewport after reparenting
	var home_view = get_view("Home")
	if home_view and home_view.has_method("reconnect_viewport"):
		home_view.reconnect_viewport()
	
	var library_view = get_view("Library")
	if library_view and library_view.has_method("reconnect_viewport"):
		library_view.reconnect_viewport()
	
	print("[UIManager] UI nodes reparented successfully")

func _restore_ui_to_original_parents() -> void:
	"""Restore NavigationBar and RootLayout to their original parents."""
	if not _is_nodes_reparented:
		return
	
	print("[UIManager] Restoring UI nodes to original parents")
	
	# Remove viewport layout from MainViewport
	if _viewport_layout:
		# Remove children first
		for child in _viewport_layout.get_children():
			_viewport_layout.remove_child(child)
		_viewport_layout.queue_free()
		_viewport_layout = null
	
	# Restore RootLayout
	if _root_control and _main_ui_original_parent:
		if _root_control.get_parent():
			_root_control.get_parent().remove_child(_root_control)
		_main_ui_original_parent.add_child(_root_control)
	
	# Restore NavigationBar
	if _navigation_bar and _navigation_bar_original_parent:
		if _navigation_bar.get_parent():
			_navigation_bar.get_parent().remove_child(_navigation_bar)
		_navigation_bar_original_parent.add_child(_navigation_bar)
	
	_is_nodes_reparented = false
	_main_ui_original_parent = null
	_navigation_bar_original_parent = null
	
	# Reconnect FocusIndicator to original viewport after restoring
	if _focus_indicator and is_instance_valid(_focus_indicator):
		_focus_indicator.reconnect_viewport()
	
	# Reconnect HomeView and LibraryView to original viewport after restoring
	var home_view = get_view("Home")
	if home_view and home_view.has_method("reconnect_viewport"):
		home_view.reconnect_viewport()
	
	var library_view = get_view("Library")
	if library_view and library_view.has_method("reconnect_viewport"):
		library_view.reconnect_viewport()
	
	print("[UIManager] UI nodes restored successfully")

# ==================== DUAL SCREEN DESKTOP FALLBACK ====================

var _hero_secondary_window: Window = null
var _hero_original_parent: Node = null

func _enable_dual_screen_mode_desktop(second_screen_index: int) -> void:
	"""Desktop fallback: Use Godot Window for dual screen."""
	print("[UIManager] Enabling dual screen mode (desktop) on screen ", second_screen_index)
	
	# Use call_deferred to avoid race conditions during _ready()
	_setup_desktop_dual_screen.call_deferred(second_screen_index)

func _setup_desktop_dual_screen(second_screen_index: int) -> void:
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
	_hero_image.size = Vector2(screen_rect.size)
	
	# Add window to scene tree
	get_tree().root.add_child(_hero_secondary_window)
	
	# Hide hero spacer since hero is now in separate window
	if _hero_spacer:
		_hero_spacer.visible = false
		_hero_spacer.custom_minimum_size = Vector2.ZERO
	
	_dual_screen_active = true
	print("[UIManager] Desktop dual screen mode enabled")

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
	print("[UIManager] Desktop dual screen mode disabled")

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
