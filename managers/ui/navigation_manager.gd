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

# ==================== UNIFIED DIRECTIONAL INPUT / AUTO-REPEAT ====================

const INITIAL_DELAY: float = 0.4
const REPEAT_DELAY: float = 0.12
const KEYBOARD_DEBOUNCE_MS: int = 80
const ANALOG_DEADZONE: float = 0.25

enum InputSource { NONE, DISCRETE, ANALOG }

var _held_dir: String = ""
var _held_source: int = InputSource.NONE
var _delay_timer: Timer = null
var _repeat_timer: Timer = null
var _last_press: int = 0

func _ready():
	ui_manager = get_parent()
	_setup_timers()

func _setup_timers() -> void:
	_delay_timer = Timer.new()
	_delay_timer.wait_time = INITIAL_DELAY
	_delay_timer.one_shot = true
	_delay_timer.timeout.connect(_on_delay_timeout)
	add_child(_delay_timer)

	_repeat_timer = Timer.new()
	_repeat_timer.wait_time = REPEAT_DELAY
	_repeat_timer.one_shot = false
	_repeat_timer.timeout.connect(_on_repeat)
	add_child(_repeat_timer)

func _process(delta: float) -> void:
	# Analog thumbstick is polled every frame and treated as a discrete held
	# direction. It uses the same delay/repeat timer as keyboard/D-pad so all
	# directional inputs feel identical.
	if not UIManager or not controller_has_priority():
		return

	var raw_strength := _get_analog_strength()
	if raw_strength < ANALOG_DEADZONE:
		if _held_source == InputSource.ANALOG:
			_held_dir = ""
			_held_source = InputSource.NONE
			_delay_timer.stop()
			_repeat_timer.stop()
		return

	var dir := _get_dominant_analog_direction()
	if dir == "":
		return

	if _held_source == InputSource.DISCRETE:
		return

	if _held_dir == dir and _held_source == InputSource.ANALOG:
		return

	_held_dir = dir
	_held_source = InputSource.ANALOG
	print("[NavAnalog] new analog direction: ", dir, " strength=", raw_strength)
	_delay_timer.start()
	_dispatch_direction(dir)

func _get_analog_strength() -> float:
	return maxf(
		Input.get_action_raw_strength("ui_up"),
		maxf(
			Input.get_action_raw_strength("ui_down"),
			maxf(
				Input.get_action_raw_strength("ui_left"),
				Input.get_action_raw_strength("ui_right")
			)
		)
	)

func _get_dominant_analog_direction() -> String:
	var up := Input.get_action_raw_strength("ui_up")
	var down := Input.get_action_raw_strength("ui_down")
	var left := Input.get_action_raw_strength("ui_left")
	var right := Input.get_action_raw_strength("ui_right")
	var max_val := maxf(up, maxf(down, maxf(left, right)))
	if max_val <= 0.0:
		return ""
	if is_equal_approx(max_val, up):
		return "ui_up"
	if is_equal_approx(max_val, down):
		return "ui_down"
	if is_equal_approx(max_val, left):
		return "ui_left"
	return "ui_right"

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

	# Reparenting ContentWrapper changes the grid's available size without a
	# viewport resize, so DisplayManager won't fire its resize signal. Refresh
	# the current view's grid once the new layout has settled.
	call_deferred("_refresh_current_view_grid")
	# Layout rebuild may create/reparent focusable controls; re-apply focus lock.
	ui_manager.call_deferred("refresh_focus_lock_state")

func _refresh_current_view_grid() -> void:
	"""Refresh the current view's grid after a nav layout change.

	Reparenting ContentWrapper changes the grid's available size without a
	viewport resize, so the grid's DisplayManager-driven recalc won't fire.
	The hidden Home/Library view is marked for rebuild so it also recalculates
	when next shown."""
	if not ui_manager or not ui_manager.view:
		return

	var current_view = ui_manager.view.get_current_view()
	if not current_view or not current_view.games_grid:
		return

	var grid = current_view.games_grid
	if grid.size.x <= 0 or grid.size.y <= 0:
		# Layout hasn't settled yet; retry a few times.
		if not has_meta("_nav_rebuild_retry_count"):
			set_meta("_nav_rebuild_retry_count", 0)
		var retry_count = get_meta("_nav_rebuild_retry_count")
		if retry_count < 5:
			set_meta("_nav_rebuild_retry_count", retry_count + 1)
			call_deferred("_refresh_current_view_grid")
		else:
			set_meta("_nav_rebuild_retry_count", 0)
		return

	set_meta("_nav_rebuild_retry_count", 0)
	grid.refresh_dimensions()

	# Mark the other grid-bearing view for rebuild so it recalculates when shown.
	for view_name in ["Home", "Library"]:
		if view_name == current_view.view_name:
			continue
		ui_manager.view.mark_view_for_rebuild(view_name, "Navigation layout changed")

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
		ui_manager.show_shuffler_dialog()
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

# ==================== UNIFIED DIRECTIONAL INPUT / AUTO-REPEAT ====================

func handle_directional_input(event: InputEvent) -> bool:
	"""Handle directional input events. Returns true if the event was consumed."""
	# Directional input counts as controller input, so keep mouse-hover suppression alive.
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_last_controller_input_time = Time.get_ticks_msec()

	# Analog stick motion is handled in _process() so stick and D-pad share the same
	# delay/repeat timer. Consume mapped directional JoypadMotion events so they don't
	# leak to other UI controls and cause double movement.
	if event is InputEventJoypadMotion:
		if event.is_action("ui_left") or event.is_action("ui_right") or event.is_action("ui_up") or event.is_action("ui_down"):
			return true
		return false

	var dirs := ["ui_left", "ui_right", "ui_up", "ui_down"]
	for dir in dirs:
		if event.is_action_pressed(dir):
			# Synthetic events are generated by our own timer/dispatch. They must be
			# allowed to propagate to Godot's built-in navigation, but they must never
			# re-enter our state machine (e.g., switching ANALOG -> DISCRETE or
			# restarting the delay timer). Otherwise an analog flick can get stuck in
			# DISCRETE mode and repeat forever.
			if event.has_meta("kyodai_synthetic"):
				print("[NavInput] synthetic press state-guarded, allowed for ", dir)
				return false

			if event is InputEventKey:
				var now := Time.get_ticks_msec()
				if now - _last_press < KEYBOARD_DEBOUNCE_MS:
					return true
				_last_press = now

			if _held_dir == dir and _held_source == InputSource.DISCRETE:
				print("[NavInput] engine echo swallowed for ", dir)
				return true

			if _held_source == InputSource.ANALOG:
				print("[NavInput] switching from analog to discrete ", dir)
				_held_source = InputSource.DISCRETE

			_held_dir = dir
			_held_source = InputSource.DISCRETE
			print("[NavInput] first press ", dir)
			_delay_timer.start()
			return _dispatch_direction(dir)

		if event.is_action_released(dir) and _held_dir == dir and _held_source == InputSource.DISCRETE:
			if event.has_meta("kyodai_synthetic"):
				print("[NavInput] synthetic release allowed for ", dir)
				return false
			print("[NavInput] discrete release for ", dir)
			_held_dir = ""
			_held_source = InputSource.NONE
			_delay_timer.stop()
			_repeat_timer.stop()
			return false

	return false

func _dispatch_direction(dir: String) -> bool:
	"""Dispatch a single directional movement. Returns true if the event was consumed."""
	# Any dispatched movement counts as active controller use, so keep controller priority
	# alive for the full duration of a held input. Without this, the 2-second controller
	# priority window can expire between timer repeats and stop grid navigation.
	_last_controller_input_time = Time.get_ticks_msec()
	print("[NavDispatch] dispatching ", dir)

	if _try_nav_to_grid(dir):
		print("[NavDispatch] nav-to-grid consumed ", dir)
		return true

	var grid := _get_current_grid()
	if grid and grid.is_focus_locked_and_active():
		var result := grid.navigate_direction(dir)
		print("[NavDispatch] grid.navigate_direction(", dir, ") = ", result)
		return result

	_send_synthetic(dir)
	print("[NavDispatch] synthetic event sent for ", dir)
	return true

func _send_synthetic(dir: String) -> void:
	"""Send a tagged synthetic press/release pair for Godot's built-in navigation."""
	var press := InputEventAction.new()
	press.action = dir
	press.pressed = true
	press.set_meta("kyodai_synthetic", true)
	Input.parse_input_event(press)

	var release := InputEventAction.new()
	release.action = dir
	release.pressed = false
	release.set_meta("kyodai_synthetic", true)
	Input.parse_input_event(release)

func _on_delay_timeout() -> void:
	print("[NavTimer] delay timeout fired, held_dir=", _held_dir, ", source=", _held_source)
	if _held_dir != "":
		_repeat_timer.start()
		_dispatch_direction(_held_dir)

func _on_repeat() -> void:
	print("[NavTimer] repeat timeout fired, held_dir=", _held_dir, ", source=", _held_source)
	if _held_dir != "":
		_dispatch_direction(_held_dir)

func _get_current_grid() -> VirtualScrollGridContainer:
	var current_view = UIManager.get_current_view()
	if not current_view:
		return null
	var grid = current_view.get("games_grid")
	if grid is VirtualScrollGridContainer:
		return grid
	return null

func _try_nav_to_grid(dir: String) -> bool:
	"""Handle manual focus navigation between nav, settings, and grid.
	Avoids NodePaths which break when nodes are reparented (dual screen mode)."""
	var focused := get_viewport().gui_get_focus_owner()
	if not focused:
		return false

	var nav_type := get_nav_type()
	var settings_btn := find_nav_settings_button()
	var last_dest := get_last_nav_destination()

	# From nav destination -> Grid (UP for bar, RIGHT for rail)
	if focused is M3NavigationDestination:
		if nav_type == 0:  # Bar
			if dir == "ui_up":
				return _enter_grid()
			if dir == "ui_right" and focused == last_dest:
				if settings_btn and settings_btn.focus_mode != Control.FOCUS_NONE:
					settings_btn.grab_focus()
					return true
		else:  # Rail
			if dir == "ui_right":
				return _enter_grid()
			if dir == "ui_down" and focused == last_dest:
				if settings_btn and settings_btn.focus_mode != Control.FOCUS_NONE:
					settings_btn.grab_focus()
					return true
		return false

	# From Settings -> Last nav destination (LEFT for bar, UP for rail)
	if focused == settings_btn:
		if nav_type == 0:  # Bar
			if dir == "ui_left":
				if last_dest and last_dest.focus_mode != Control.FOCUS_NONE:
					last_dest.grab_focus()
					return true
		else:  # Rail
			if dir == "ui_up":
				if last_dest and last_dest.focus_mode != Control.FOCUS_NONE:
					last_dest.grab_focus()
					return true
		return false

	return false

func _enter_grid() -> bool:
	var current_view = UIManager.get_current_view()
	if not current_view:
		return false
	var grid = current_view.get("games_grid")
	if not grid or not grid is VirtualScrollGridContainer:
		return false
	grid.focus_last_or_first_card()
	return true
