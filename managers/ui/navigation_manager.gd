class_name NavigationManager
extends Manager

var ui_manager: Node

var _nav_node: M3Navigation = null
var _nav_type: int = 0  # 0 = Bar, 1 = Rail

const NAV_DESTINATIONS = [
	{"id": "home",      "label": "Home",      "icon": "home",     "view": "Home"},
	{"id": "library",   "label": "Library",   "icon": "library",  "view": "Library"},
	{"id": "downloads", "label": "Downloads", "icon": "download", "view": "Downloads"},
	{"id": "shuffle",   "label": "Shuffle",   "icon": "shuffle",  "view": ""},
]

var _last_nav_index: int = 0

var _root_control: Control = null
var _content_wrapper: Control = null
var _inner_layout: BoxContainer = null

# Feedback tracking for navigation sounds
var _feedback_connected_viewport: Viewport = null
var _is_first_focus: bool = true

# Input tracking for mouse hover focus
const MOUSE_IDLE_THRESHOLD_MS: int = 1000  # Mouse must have moved within last 1 second
const CONTROLLER_PRIORITY_MS: int = 2000   # Controller has priority for 2 seconds after use
var _last_mouse_move_time: int = 0
var _last_controller_input_time: int = 0
var _last_mouse_position: Vector2 = Vector2.ZERO

func _ready():
	ui_manager = get_parent()

func setup(root_control: Control, content_wrapper: Control, inner_layout: BoxContainer, nav_type: int) -> void:
	_root_control = root_control
	_content_wrapper = content_wrapper
	_inner_layout = inner_layout
	_nav_type = nav_type
	_rebuild_nav_and_layout()

func set_nav_type(value: int) -> void:
	_nav_type = value

func get_nav_type() -> int:
	"""Get the current navigation type (0 = Bar, 1 = Rail)."""
	return _nav_type

func _sync_nav_selection(view_name: String) -> void:
	if not _nav_node:
		return
	var nav_dests = _get_nav_destinations()
	for i in range(nav_dests.size()):
		if nav_dests[i].view == view_name:
			_nav_node.selected_index = i
			break

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

	# Emit signal
	ui_manager.layout_changed.emit("bar" if is_bar else "rail")

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
	for dest in _get_nav_destinations():
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
	settings_btn.pressed.connect(ui_manager.overlay.show_settings_dialog)

	_nav_node.set_meta("_deferred_show_menu_button", false)
	_nav_node.set_meta("_deferred_footer_content", settings_btn)
	if not _nav_node.ready.is_connected(_on_nav_node_ready):
		_nav_node.ready.connect(_on_nav_node_ready)

func _get_nav_destinations() -> Array[Dictionary]:
	"""Return the nav destinations that should be visible on this platform."""
	var result: Array[Dictionary] = []
	for dest in NAV_DESTINATIONS:
		if dest.id == "shuffle" and PlatformManager.is_android():
			continue
		result.append(dest)
	return result

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
	# If a theme refresh was queued while nav was rebuilding, apply it now
	ui_manager.theme._trigger_refresh_if_pending()
	_setup_nav_focus_neighbors()

func _on_nav_destination_selected(index: int, _reselected: bool) -> void:
	"""Handle M3 nav destination selection."""
	var nav_dests = _get_nav_destinations()
	if index < 0 or index >= nav_dests.size():
		return

	var dest = nav_dests[index]
	if dest.id == "shuffle":
		# Restore previous nav selection so shuffle doesn't stay highlighted
		if _nav_node:
			_nav_node.selected_index = _last_nav_index
		ui_manager.overlay._show_shuffler_dialog()
		return

	_last_nav_index = index
	ui_manager.switch_to_tab(dest.view)

func _setup_nav_focus_neighbors() -> void:
	"""Block the one direction that leaks from nav into the game grid.
	Nav-to-nav and nav-to-settings navigation is left to Godot's spatial
	search so we don't store stale NodePaths across nav rebuilds."""
	if not _nav_node:
		return

	# Find all M3NavigationDestination children
	var destinations: Array[M3NavigationDestination] = []
	for child in _nav_node.get_children():
		if child is M3NavigationDestination:
			destinations.append(child)
		else:
			for sub in child.get_children():
				if sub is M3NavigationDestination:
					destinations.append(sub)
				else:
					for subsub in sub.get_children():
						if subsub is M3NavigationDestination:
							destinations.append(subsub)

	# Only block the grid-leak direction. Don't wire nav-to-nav neighbors
	# because nodes get rebuilt (dual-screen, orientation changes) and
	# NodePaths become stale, causing "Neighbor focus node path is invalid".
	for dest in destinations:
		if _nav_type == 0:  # Bar — grid is above
			dest.focus_neighbor_top = NodePath("")
		else:  # Rail — grid is to the right
			dest.focus_neighbor_right = NodePath("")

	# Block settings button from leaking to the grid
	var settings_btn = find_nav_settings_button()
	if settings_btn:
		if _nav_type == 0:
			settings_btn.focus_neighbor_top = NodePath("")
		else:
			settings_btn.focus_neighbor_right = NodePath("")

func find_home_button() -> Control:
	"""Find the Home destination in the M3 nav."""
	if not _nav_node:
		print("[NavigationManager] find_home_button: _nav_node is null")
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

func get_last_nav_destination() -> Control:
	"""Find the last nav destination (e.g. Downloads)."""
	if not _nav_node:
		return null

	var destinations: Array[M3NavigationDestination] = []
	for child in _nav_node.get_children():
		if child is M3NavigationDestination:
			destinations.append(child)
		else:
			for sub in child.get_children():
				if sub is M3NavigationDestination:
					destinations.append(sub)
				else:
					for subsub in sub.get_children():
						if subsub is M3NavigationDestination:
							destinations.append(subsub)

	if destinations.size() > 0:
		return destinations[destinations.size() - 1]
	return null

func get_active_nav_destination() -> Control:
	"""Find the currently selected nav destination (active tab)."""
	if not _nav_node:
		return null

	var selected_idx = _nav_node.selected_index
	if selected_idx < 0:
		return null

	# Find all M3NavigationDestination children
	var destinations: Array[M3NavigationDestination] = []
	for child in _nav_node.get_children():
		if child is M3NavigationDestination:
			destinations.append(child)
		else:
			for sub in child.get_children():
				if sub is M3NavigationDestination:
					destinations.append(sub)
				else:
					for subsub in sub.get_children():
						if subsub is M3NavigationDestination:
							destinations.append(subsub)

	if selected_idx < destinations.size():
		return destinations[selected_idx]
	return null

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

func _find_first_focusable(node: Node) -> Control:
	"""Find the first focusable Control in the node tree."""
	if node is Control and node.focus_mode != Control.FOCUS_NONE:
		return node

	for child in node.get_children():
		var result = _find_first_focusable(child)
		if result:
			return result

	return null

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

# ==================== FOCUS FEEDBACK (Navigation Sounds) ====================

# Temporarily set to true around deliberate focus grabs (e.g. menu open/dismiss)
# to avoid playing the navigation click for the programmatic focus change.
var _suppress_next_focus_sound: bool = false

func suppress_next_focus_sound() -> void:
	_suppress_next_focus_sound = true

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

	# Suppress programmatic focus grabs (e.g. menu open/dismiss)
	if _suppress_next_focus_sound:
		_suppress_next_focus_sound = false
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
