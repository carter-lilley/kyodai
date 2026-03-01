extends Manager

# UIManager - Manages tab-based view navigation and modal overlays
# Coordinates between the main TabContainer, view instances, and modals

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

# Layout management
var _root_control: Control = null
var _layout_container: BoxContainer = null
var _bottom_bar: BottomBar = null
var _current_bar_position: String = "bottom"

# Position index mapping
const BAR_POSITIONS = ["bottom", "top", "left", "right"]

# Bar sizing constant (7.5% of viewport dimension)
const BAR_SIZE_RATIO = 0.075

# Hero image sizing constant (33% of viewport height)
const HERO_SIZE_RATIO = 0.33

# Hero image management
var _hero_image: HeroImage = null

# Library background management
var _library_background: LibraryBackground = null
var _content_wrapper: Control = null

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

func initialize(tab_container: TabContainer, layout_container: BoxContainer, bottom_bar: BottomBar = null):
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	
	_layout_container = layout_container
	_root_control = layout_container.get_parent()
	_bottom_bar = bottom_bar
	
	# Create LibraryBackground first (before layout setup)
	_setup_library_background()
	
	# Setup layout based on current setting (this creates MainVBox)
	_setup_layout()
	
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
		print("[UIManager DEBUG] Initial view set to: ", current_tab_title, " calling _update_hero_visibility")
		# Apply hero image visibility based on saved setting
		_update_hero_visibility(current_tab_title)
	else:
		print("[UIManager DEBUG] No view found for tab: ", current_tab_title)
	
	# Setup modal input handling
	_setup_modal_input_handling()
	
	# Setup focus indicator
	_setup_focus_indicator()
	
	# Setup library appearance (background color)
	_setup_library_appearance()
	SettingsManager.setting_changed.connect(_on_setting_changed)
	
	# Set initial focus
	_set_initial_focus()

func _get_bar_position_string(index: int) -> String:
	"""Convert position index to string."""
	if index >= 0 and index < BAR_POSITIONS.size():
		return BAR_POSITIONS[index]
	return "bottom"

func _get_bar_position_index(position: String) -> int:
	"""Convert position string to index."""
	return BAR_POSITIONS.find(position)

func _connect_viewport_resize() -> void:
	"""Connect to viewport resize signal to update bar size."""
	if is_inside_tree():
		var viewport = get_viewport()
		if viewport:
			if viewport.size_changed.is_connected(_on_viewport_resized):
				viewport.size_changed.disconnect(_on_viewport_resized)
			viewport.size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	"""Handle viewport resize to update bar and hero dimensions."""
	_update_bar_size()
	_update_hero_size()

func _update_bar_size() -> void:
	"""Update the bottom bar size based on viewport and orientation."""
	if not _bottom_bar or not is_inside_tree():
		return
	
	var viewport_size = get_viewport().size
	var is_horizontal = _current_bar_position in ["top", "bottom"]
	
	if is_horizontal:
		# Horizontal bar: fixed height, full width
		var target_height = viewport_size.y * BAR_SIZE_RATIO
		_bottom_bar.custom_minimum_size = Vector2(0, target_height)
		_bottom_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_bottom_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	else:
		# Vertical bar: fixed width, full height
		var target_width = viewport_size.x * BAR_SIZE_RATIO
		_bottom_bar.custom_minimum_size = Vector2(target_width, 0)
		_bottom_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_bottom_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _update_hero_size() -> void:
	"""Update the hero image size based on viewport."""
	if not _hero_image or not is_inside_tree():
		return
	
	var viewport_size = get_viewport().size
	var target_height = viewport_size.y * HERO_SIZE_RATIO
	_hero_image.custom_minimum_size = Vector2(0, target_height)
	_hero_image.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero_image.size_flags_vertical = Control.SIZE_SHRINK_CENTER

func _setup_hero_image(main_content_vbox: VBoxContainer = null) -> void:
	"""Create and setup the shared HeroImage instance."""
	if _hero_image:
		return
	
	var hero_scene = preload("res://components/hero_image.tscn")
	_hero_image = hero_scene.instantiate()
	_hero_image.name = "HeroImage"
	
	# Add to main_content_vbox if provided
	if main_content_vbox:
		main_content_vbox.add_child(_hero_image)
		main_content_vbox.move_child(_hero_image, 0)
		print("[UIManager] HeroImage added to MainContentVBox at index 0")
	else:
		# Temporarily add to root control until layout is set up
		_root_control.add_child(_hero_image)
		_root_control.move_child(_hero_image, 0)
		print("[UIManager] HeroImage added to root control temporarily")
	
	_update_hero_size()
	
	# Check if hero should be hidden by default
	var hide_hero_setting = SettingsManager.get_setting("library_hide_hero_image")
	print("[UIManager DEBUG] _setup_hero_image - hide_hero_setting: ", hide_hero_setting, " value: ", hide_hero_setting.value if hide_hero_setting else "null")
	if hide_hero_setting and hide_hero_setting.value:
		_hero_image.visible = false
		print("[UIManager DEBUG] HeroImage set to hidden in _setup_hero_image")
	else:
		print("[UIManager DEBUG] HeroImage left visible (setting: ", hide_hero_setting.value if hide_hero_setting else "no setting", ")")
	
	print("[UIManager] HeroImage setup complete")

func _setup_library_background() -> void:
	"""Create and setup the shared LibraryBackground instance."""
	if _library_background:
		return
	
	var background_scene = preload("res://components/library_background.tscn")
	_library_background = background_scene.instantiate()
	_library_background.name = "LibraryBackground"
	
	# Don't add to any parent yet - _setup_layout() will add it to ContentWrapper
	print("[UIManager] LibraryBackground created (will be added to ContentWrapper in _setup_layout)")
	
	# Set initial background color from settings
	_update_library_background_color()
	
	print("[UIManager] LibraryBackground setup complete")

func _update_library_background_color() -> void:
	"""Update the library background color from settings."""
	if not _library_background:
		return
	
	var bg_color = Color(0.1, 0.1, 0.1, 1.0)  # Default dark gray
	if SettingsManager:
		var color_setting = SettingsManager.get_setting("library_background_color")
		if color_setting:
			bg_color = color_setting.value
	
	_library_background.set_background_color(bg_color)

func _setup_layout() -> void:
	"""Setup the layout container based on the bottom bar position setting."""
	# Get current position setting (stored as index)
	var position_setting = SettingsManager.get_setting("library_bottom_bar_position")
	if position_setting:
		_current_bar_position = _get_bar_position_string(position_setting.value)
	
	# Determine if we need horizontal or vertical layout
	var is_horizontal = _current_bar_position in ["top", "bottom"]
	
	# Store references to children before reorganizing
	var tab_container_ref = _tab_container
	var bottom_bar_ref = _bottom_bar
	
	# Remove BottomBar from wherever it currently is
	if bottom_bar_ref and is_instance_valid(bottom_bar_ref) and bottom_bar_ref.get_parent():
		print("[UIManager] Removing BottomBar from parent: ", bottom_bar_ref.get_parent().name)
		bottom_bar_ref.get_parent().remove_child(bottom_bar_ref)
	
	# Remove children from current layout container so they can be reparented
	for child in _layout_container.get_children():
		_layout_container.remove_child(child)
	
	# Create or get the RootLayout container (HBox or VBox based on bar position)
	var need_hbox = not is_horizontal
	var root_layout: BoxContainer
	
	# Check if we need to create a new root layout or reuse existing
	var existing_root = _root_control.get_node_or_null("RootLayout")
	if existing_root and ((need_hbox and existing_root is HBoxContainer) or (not need_hbox and existing_root is VBoxContainer)):
		# Reuse existing container of correct type
		root_layout = existing_root
		# Ensure it's properly attached and sized
		if root_layout.get_parent() != _root_control:
			if root_layout.get_parent():
				root_layout.get_parent().remove_child(root_layout)
			_root_control.add_child(root_layout)
		root_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
		# Clear all children from root_layout to prepare for rebuild
		for child in root_layout.get_children():
			root_layout.remove_child(child)
	else:
		# Create new root layout container
		if existing_root:
			# Make sure existing_root has no children before freeing
			for child in existing_root.get_children():
				existing_root.remove_child(child)
			existing_root.queue_free()
		
		if need_hbox:
			root_layout = HBoxContainer.new()
		else:
			root_layout = VBoxContainer.new()
		
		root_layout.name = "RootLayout"
		root_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
		_root_control.add_child(root_layout)
		
		# Move layout container from old parent to root control temporarily
		if _layout_container and _layout_container.get_parent():
			_layout_container.get_parent().remove_child(_layout_container)
	
	# Create MainContentVBox to hold HeroImage + TabContainer
	var main_content_vbox = _root_control.get_node_or_null("MainContentVBox")
	if not main_content_vbox:
		main_content_vbox = VBoxContainer.new()
		main_content_vbox.name = "MainContentVBox"
		main_content_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		# Note: Will be added to root_layout later
	elif main_content_vbox.get_parent():
		# Remove from old parent before re-adding
		main_content_vbox.get_parent().remove_child(main_content_vbox)
	
	# Clear MainContentVBox children to rebuild
	for child in main_content_vbox.get_children():
		main_content_vbox.remove_child(child)
	
	# Setup hero image in MainContentVBox
	if not _hero_image:
		_setup_hero_image(main_content_vbox)
	else:
		if _hero_image.get_parent():
			_hero_image.get_parent().remove_child(_hero_image)
		main_content_vbox.add_child(_hero_image)
	
	# Add TabContainer to MainContentVBox
	main_content_vbox.add_child(tab_container_ref)
	
	# Configure MainContentVBox sizing
	main_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_content_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Remove separation between HeroImage and TabContainer
	main_content_vbox.add_theme_constant_override("separation", 0)
	
	# Update _layout_container reference to MainContentVBox
	_layout_container = main_content_vbox
	
	# Configure bottom bar orientation
	if _bottom_bar:
		if is_horizontal:
			_bottom_bar.set_orientation(BottomBar.BarOrientation.HORIZONTAL)
		else:
			_bottom_bar.set_orientation(BottomBar.BarOrientation.VERTICAL)
	
	# Create ContentWrapper to hold both LibraryBackground and MainContentVBox
	# This allows them to overlap (LibraryBackground behind, MainContentVBox on top)
	if not _content_wrapper:
		_content_wrapper = Control.new()
		_content_wrapper.name = "ContentWrapper"
	elif _content_wrapper.get_parent():
		_content_wrapper.get_parent().remove_child(_content_wrapper)
	
	# Clear ContentWrapper children except LibraryBackground (which stays permanently)
	for child in _content_wrapper.get_children():
		if child != _library_background:
			_content_wrapper.remove_child(child)
	
	# Add LibraryBackground to ContentWrapper if not already there
	if _library_background.get_parent() == null:
		_library_background.set_anchors_preset(Control.PRESET_FULL_RECT)
		_content_wrapper.add_child(_library_background)
		print("[UIManager] LibraryBackground added to ContentWrapper")
	
	# Configure MainContentVBox to fill the content wrapper (on top of LibraryBackground)
	main_content_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content_wrapper.add_child(main_content_vbox)
	
	# ContentWrapper fills the available space in RootLayout
	_content_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Add BottomBar and ContentWrapper to RootLayout in correct order
	match _current_bar_position:
		"top", "left":
			if bottom_bar_ref:
				root_layout.add_child(bottom_bar_ref)
			root_layout.add_child(_content_wrapper)
		"bottom", "right", _:
			root_layout.add_child(_content_wrapper)
			if bottom_bar_ref:
				root_layout.add_child(bottom_bar_ref)
	
	# TabContainer fills the MainContentVBox (below HeroImage)
	tab_container_ref.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_container_ref.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Update bar size and connect resize handler
	_update_bar_size()
	_connect_viewport_resize()
	
	print("[UIManager] Layout setup complete with bar position: ", _current_bar_position)

func _rebuild_layout() -> void:
	"""Rebuild the layout when bar position setting changes."""
	# Store current tab
	var current_tab = _tab_container.current_tab
	
	# Rebuild layout
	_setup_layout()
	
	# Restore tab
	_tab_container.current_tab = current_tab
	
	# Emit signal
	layout_changed.emit(_current_bar_position)

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
	"""Set initial focus to the Home button in the bottom bar."""
	# Wait a frame for the UI to be fully ready
	await get_tree().process_frame
	
	# Try to find the home button in the bottom bar (search recursively since buttons are in dynamic containers)
	var home_button = _find_home_button()
	if home_button and home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
		home_button.grab_focus()
		print("[UIManager] Set initial focus to Home button in bottom bar")
		return
	
	# Fallback: try to focus the first focusable element in the root control
	if _root_control:
		var first_focusable = _find_first_focusable(_root_control)
		if first_focusable:
			first_focusable.grab_focus()
			print("[UIManager] Set initial focus to: " + first_focusable.name)

func _find_home_button() -> Control:
	"""Find the Home button in the bottom bar."""
	if not _bottom_bar:
		return null
	
	# Search recursively for a button named HomeButton
	return _find_node_by_name(_bottom_bar, "HomeButton")

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

func _setup_library_appearance() -> void:
	"""Apply library background color to the LibraryBackground shader."""
	# Update the library background color from settings
	_update_library_background_color()
	
	# Make TabContainer background transparent so we can see the LibraryBackground behind it
	var transparent_style = StyleBoxFlat.new()
	transparent_style.bg_color = Color(0, 0, 0, 0)  # Transparent
	_tab_container.add_theme_stylebox_override("panel", transparent_style)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	print("[UIManager] _on_setting_changed called for: %s with value: %s" % [setting.property_name, str(_value)])
	if setting.property_name == "library_background_color":
		_update_library_background_color()
	elif setting.property_name == "library_bottom_bar_position":
		_current_bar_position = _get_bar_position_string(setting.value)
		# Store currently focused control before rebuild
		var focused_control = get_viewport().gui_get_focus_owner()
		_rebuild_layout()
		# Restore focus after rebuild if control still exists
		if focused_control and is_instance_valid(focused_control):
			focused_control.grab_focus()
	elif setting.property_name == "library_hide_hero_image":
		# Update hero image visibility when setting changes
		var current_view_name = _current_view.view_name if _current_view else ""
		_update_hero_visibility(current_view_name)
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
				home_view.rebuild_grid()
			else:
				home_view.mark_for_rebuild("Card effects changed")
		if _views.has("Library"):
			var library_view = _views["Library"]
			if is_current_view("Library"):
				library_view.rebuild_grid()
			else:
				library_view.mark_for_rebuild("Card effects changed")
	elif setting.property_name == "library_grid_padding":
		print("[UIManager] Grid padding changed to: %d" % setting.value)
		print("[UIManager] Current view: %s" % (_current_view.view_name if _current_view else "none"))
		# Rebuild visible views immediately, mark hidden views for rebuild
		if _views.has("Home"):
			var home_view = _views["Home"]
			print("[UIManager] Home view needs_rebuild before: %s" % str(home_view.needs_rebuild))
			if is_current_view("Home"):
				print("[UIManager] Rebuilding Home view immediately")
				home_view.rebuild_grid()
			else:
				print("[UIManager] Marking Home view for rebuild")
				home_view.mark_for_rebuild("Grid padding changed")
			print("[UIManager] Home view needs_rebuild after: %s" % str(home_view.needs_rebuild))
		if _views.has("Library"):
			var library_view = _views["Library"]
			print("[UIManager] Library view needs_rebuild before: %s" % str(library_view.needs_rebuild))
			if is_current_view("Library"):
				print("[UIManager] Rebuilding Library view immediately")
				library_view.rebuild_grid()
			else:
				print("[UIManager] Marking Library view for rebuild")
				library_view.mark_for_rebuild("Grid padding changed")
			print("[UIManager] Library view needs_rebuild after: %s" % str(library_view.needs_rebuild))

func _on_tab_changed(tab_idx: int):
	var tab_title = _tab_container.get_tab_title(tab_idx)
	print("[UIManager] _on_tab_changed called for tab: %s (index: %d)" % [tab_title, tab_idx])
	
	# Hide current view
	if _current_view:
		print("[UIManager] Hiding current view: %s" % _current_view.view_name)
		_current_view.on_view_hide()
	
	# Show new view
	if _views.has(tab_title):
		print("[UIManager] Showing new view: %s" % tab_title)
		_current_view = _views[tab_title]
		print("[UIManager] Calling on_view_show() for: %s" % _current_view.view_name)
		_current_view.on_view_show()
		
		# Update hero image visibility based on view
		_update_hero_visibility(tab_title)
		
		# Emit tab changed signal for global UI updates
		tab_changed.emit(tab_title)

func _update_hero_visibility(view_name: String) -> void:
	"""Show/hide hero image and library background based on current view and settings."""
	# Update hero image visibility
	if not _hero_image:
		print("[UIManager DEBUG] _update_hero_visibility - no _hero_image!")
	else:
		# Check if hero image is disabled in settings
		var hide_hero_setting = SettingsManager.get_setting("library_hide_hero_image")
		var hide_hero = hide_hero_setting and hide_hero_setting.value
		
		print("[UIManager DEBUG] _update_hero_visibility - view_name: ", view_name, " hide_hero_setting: ", hide_hero_setting, " hide_hero: ", hide_hero)
		
		# Show hero for Home and Library views (unless disabled), hide for Downloads and Settings
		var show_hero = (view_name in ["Home", "Library"]) and not hide_hero
		print("[UIManager DEBUG] _update_hero_visibility - setting hero visible to: ", show_hero, " (was: ", _hero_image.visible, ")")
		_hero_image.visible = show_hero
		
		if show_hero:
			# Clear hero when switching to a view that shows it
			_hero_image.clear()
		
		print("[UIManager] HeroImage visibility set to: ", show_hero, " for view: ", view_name, " (hide_hero: ", hide_hero, ")")
	
	# Update library background visibility
	if not _library_background:
		print("[UIManager DEBUG] _update_hero_visibility - no _library_background!")
	else:
		# Show library background for Home and Library views, hide for Downloads and Settings
		var show_background = view_name in ["Home", "Library"]
		print("[UIManager DEBUG] _update_hero_visibility - setting library background visible to: ", show_background, " (was: ", _library_background.visible, ")")
		_library_background.visible = show_background
		print("[UIManager] LibraryBackground visibility set to: ", show_background, " for view: ", view_name)

func _on_hero_game_changed(game: GameResource) -> void:
	"""Handle hero game change from views."""
	if not _hero_image:
		return
	
	# Only update hero image if we're in Home or Library view
	var current_view_name = _current_view.view_name if _current_view else ""
	print("[UIManager DEBUG] _on_hero_game_changed - game: ", game.get_display_name() if game else "null", " current_view: ", current_view_name)
	
	if current_view_name not in ["Home", "Library"]:
		return
	
	# Check if hero image is disabled in settings
	var hide_hero_setting = SettingsManager.get_setting("library_hide_hero_image")
	if hide_hero_setting and hide_hero_setting.value:
		return
	
	if game:
		_hero_image.set_game(game)
	else:
		_hero_image.clear()

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
	"""Get the current bottom bar position."""
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
