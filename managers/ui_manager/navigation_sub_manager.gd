class_name NavigationSubManager
extends Manager

const DEBUG_LOG: bool = false

var ui_manager: Node

var _nav_node: M3Navigation = null
var _nav_type: int = 0  # 0 = Bar, 1 = Rail

const NAV_DESTINATIONS = [
	{"id": "home",      "label": "Home",      "icon": "home",     "view": "Home"},
	{"id": "library",   "label": "Library",   "icon": "shopping", "view": "Library"},
	{"id": "shuffle",   "label": "Shuffle",   "icon": "dice-6",   "view": ""},
]

const ADD_DESTINATION = {"id": "add", "label": "", "icon": "plus", "view": ""}

var _last_nav_index: int = 0

var _root_control: Control = null
var _content_wrapper: Control = null
var _inner_layout: BoxContainer = null

var _add_menu: M3Menu = null

# Feedback tracking for navigation sounds
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

func _process(_delta: float) -> void:
	# Block all navigation during background state (emulator running)
	if LaunchManager and LaunchManager.is_in_background_state():
		return

	# Let the on-screen keyboard handle its own controller navigation.
	if UIManager and UIManager.is_onscreen_keyboard_visible():
		# Safety trap: a held analog direction from before the keyboard opened may
		# still have an active repeat timer. Clear it so focus doesn't drift.
		if _held_dir != "":
			_held_dir = ""
			_held_source = InputSource.NONE
			_delay_timer.stop()
			_repeat_timer.stop()
		return
	
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
	if DEBUG_LOG: print("[NavAnalog] new analog direction: ", dir, " strength=", raw_strength)
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
	_setup_feedback_handlers()

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
		if nav_dests[i].get("view", "") == view_name:
			_set_nav_selected_index_no_signal(i)
			break

func _set_nav_selected_index_no_signal(index: int) -> void:
	"""Set the nav selected index without re-firing destination_selected."""
	if not _nav_node:
		return
	if _nav_node.destination_selected.is_connected(_on_nav_destination_selected):
		_nav_node.destination_selected.disconnect(_on_nav_destination_selected)
		_nav_node.selected_index = index
		_nav_node.destination_selected.connect(_on_nav_destination_selected)
	else:
		_nav_node.selected_index = index

func _rebuild_nav_and_layout() -> void:
	"""Rebuild nav node and layout when type changes or pins mutate."""

	var is_bar = _nav_type == 0
	var is_horizontal = is_bar

	print("[NavigationManager] rebuilding nav layout: type=%s" % ["bar" if is_bar else "rail"])

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

	# The InnerLayout was just rebuilt (and possibly replaced); re-assert the
	# window-chrome top offset so the nav never slides under the title bar.
	_apply_chrome_offset()

	# Emit signal
	ui_manager.layout_changed.emit("bar" if is_bar else "rail")

	# Reparenting ContentWrapper changes the grid's available size without a
	# viewport resize, so SystemManager.display won't fire its resize signal.
	# The actual grid refresh is deferred to _refresh_nav_layout() so it runs
	# after the nav node has finalized its dimensions and compact level.
	# Layout rebuild may create/reparent focusable controls; re-apply focus lock.
	ui_manager.queue_refresh_focus_lock_state()
	# The nav node may have been sized before its parent assigned a real width;
	# force a deferred sizing pass once the layout has settled.
	call_deferred("_refresh_nav_layout")

func _refresh_current_view_grid() -> void:
	"""Refresh the current view's grid after a nav layout change.

	Reparenting ContentWrapper changes the grid's available size without a
	viewport resize, so the grid's SystemManager.display-driven recalc won't fire.
	We compute the expected available size deterministically and recalc once.
	The hidden Home/Library view is marked for rebuild so it also recalculates
	when next shown."""
	if not ui_manager or not ui_manager.view:
		return

	var current_view = ui_manager.view.get_current_view()
	if not current_view or not current_view.games_grid:
		return

	var grid = current_view.games_grid
	var available_size = ui_manager.compute_grid_available_size(grid, current_view)
	grid.recalculate_layout_with_size(available_size)

	# Mark the other grid-bearing views for rebuild so they recalculate when shown.
	for view_name in ["Home", "Library"]:
		if view_name == current_view.view_name:
			continue
		ui_manager.view.mark_view_for_rebuild(view_name, "Navigation layout changed")

func _refresh_nav_layout() -> void:
	"""Recompute nav sizing once the parent layout has assigned a real size."""
	if not _nav_node or not is_instance_valid(_nav_node):
		return

	print("[NavigationManager] _refresh_nav_layout type=%s node_size=%s viewport=%s" % [
		"bar" if _nav_type == 0 else "rail",
		_nav_node.size,
		_nav_node.get_viewport_rect().size if _nav_node.is_inside_tree() else Vector2.ZERO
	])

	if _nav_node is M3NavigationBar:
		_nav_node._update_item_sizes()
	elif _nav_node is M3NavigationRail:
		_nav_node._apply_compact_level()

	if _inner_layout and is_instance_valid(_inner_layout) and _inner_layout is Container:
		_inner_layout.queue_sort()

	# Refresh the current grid now that the nav node has finalized its size and
	# the layout has been queued to sort. This ensures the grid computes its
	# available size from the final nav dimensions rather than a transient value.
	_refresh_current_view_grid()

func refresh_for_screen_swap() -> void:
	"""Public entry point called from main.gd after a dual-screen swap.

	Recomputes the nav layout and forces the current grid to refresh so the UI
	matches the new SubViewport size after the swap has settled. The grid refresh
	is handled inside _refresh_nav_layout()."""
	print("[NavigationManager] refresh_for_screen_swap")
	_refresh_nav_layout()
	if _inner_layout and is_instance_valid(_inner_layout) and _inner_layout is Container:
		_inner_layout.queue_sort()
	# Reparenting into/out of the dual-screen SubViewport changes absolute node
	# paths, so the stored focus_neighbor NodePaths go stale. Re-wire them once
	# the tree has settled.
	call_deferred("_setup_nav_focus_neighbors")

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

## Push the whole inner layout (nav rail/bar AND content wrapper) below the
## window-chrome strip. The custom title bar floats full-width on the
## ChromeLayer above everything, so without this the rail's top destinations
## slide under it. The InnerLayout node is REPLACED on every nav rebuild
## (type switch, pin changes), so this is re-applied at the end of each
## rebuild; UIManager re-applies it on chrome visibility and scale changes.
func _apply_chrome_offset() -> void:
	if not _inner_layout or not is_instance_valid(_inner_layout):
		return
	_inner_layout.offset_top = M3Overlay.get_chrome_top_inset()

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
		if dest.has("icon_data") and not dest.icon_data.is_empty():
			var bytes = Marshalls.base64_to_raw(dest.icon_data)
			if bytes.size() > 0:
				var img = Image.new()
				if img.load_png_from_buffer(bytes) == OK:
					d.icon_texture = ImageTexture.create_from_image(img)
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
	settings_btn.focus_mode = Control.FOCUS_ALL
	settings_btn.pressed.connect(ui_manager.overlay.show_settings_dialog)

	_nav_node.set_meta("_deferred_show_menu_button", false)
	_nav_node.set_meta("_deferred_footer_content", settings_btn)
	if not _nav_node.ready.is_connected(_on_nav_node_ready):
		_nav_node.ready.connect(_on_nav_node_ready)

func _get_static_destinations() -> Array[Dictionary]:
	"""Return the static nav destinations for this platform."""
	var result: Array[Dictionary] = []
	for dest in NAV_DESTINATIONS:
		if dest.id == "shuffle" and SystemManager.platform.is_android():
			continue
		result.append(dest)
	return result

func _get_pinned_shortcuts() -> Array[Dictionary]:
	"""Return the pinned shortcuts that should be visible on this platform.

	Includes platform-specific app/program pins and cross-platform collection pins."""
	if not DataManager:
		return []
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting or not (setting.value is Array):
		return []
	var result: Array[Dictionary] = []
	var current_type := "app" if SystemManager.platform.is_android() else "program"
	for item in setting.value:
		if item is Dictionary:
			var type = item.get("type", "")
			if type == current_type or type == "collection" or type == "favorites" or type == "platform":
				result.append(item)
	return result

func _get_nav_destinations() -> Array[Dictionary]:
	"""Return the nav destinations that should be visible on this platform."""
	var result: Array[Dictionary] = []
	result.append_array(_get_static_destinations())
	result.append_array(_get_pinned_shortcuts())
	result.append(ADD_DESTINATION.duplicate())
	return result

func _is_pinned_destination(dest: Dictionary) -> bool:
	return dest.get("type") in ["app", "program", "collection", "favorites", "platform"]

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

	# Restore the active static selection so the nav highlights the current tab.
	_set_nav_selected_index_no_signal(clampi(_last_nav_index, 0, maxi(_get_static_destinations().size() - 1, 0)))

	# Connect context menus for pinned shortcuts (right-click / long-press)
	var nav_dests = _get_nav_destinations()
	for i in range(min(_nav_node._destination_items.size(), nav_dests.size())):
		var item = _nav_node._destination_items[i]
		var dest = nav_dests[i]
		if _is_pinned_destination(dest):
			item.context_menu_enabled = true
			if not item.context_menu_requested.is_connected(_on_pinned_context_menu_requested):
				item.context_menu_requested.connect(_on_pinned_context_menu_requested.bind(item, dest))

	_setup_nav_focus_neighbors()

func get_transition_icon_for_view(view_name: String) -> String:
	"""Icon to show in the fullscreen view transition, or "" if the view
	should switch instantly without a transition."""
	for dest in NAV_DESTINATIONS:
		if dest.get("view", "") == view_name:
			return dest.get("icon", "")
	if view_name.begins_with("Collection_"):
		return "star"
	if view_name == "Favorites":
		return "heart"
	if view_name.begins_with("Platform_"):
		return "gamepad-variant"
	return ""

func _on_nav_destination_selected(index: int, _reselected: bool) -> void:
	"""Handle M3 nav destination selection."""
	var nav_dests = _get_nav_destinations()
	if index < 0 or index >= nav_dests.size():
		return

	var static_count := _get_static_destinations().size()
	var pin_count := _get_pinned_shortcuts().size()
	var dest = nav_dests[index]
	if dest.id == "shuffle":
		# Restore previous nav selection so shuffle doesn't stay highlighted
		_set_nav_selected_index_no_signal(_last_nav_index)
		ui_manager.show_shuffler_dialog()
		return

	if dest.id == "add":
		var add_control := get_active_nav_destination()
		_set_nav_selected_index_no_signal(_last_nav_index)
		_show_add_menu(add_control)
		return

	if index >= static_count and index < static_count + pin_count:
		# Pinned shortcut selected; keep static selection highlighted.
		_set_nav_selected_index_no_signal(_last_nav_index)
		if dest.get("type") == "collection" or dest.get("type") == "favorites" or dest.get("type") == "platform":
			_focus_tapped_destination(index)
			ui_manager.switch_to_tab(dest.view)
		else:
			_launch_pinned_shortcut(dest)
		return

	if index < static_count:
		# Only remember selection for the static tabs (not shuffle/add/pins).
		_last_nav_index = index
	_focus_tapped_destination(index)
	ui_manager.switch_to_tab(dest.view)

func _focus_tapped_destination(index: int) -> void:
	"""Focus the tapped destination after a pointer-initiated selection.

	While grid-locked, nav destinations are FOCUS_NONE (UIManager focus lock),
	so a tap never grabs focus and the ensuing view switch orphans the old
	focus owner, leaving controller navigation dead. Release the lock (which
	restores focus modes) and focus the tapped destination. Must run BEFORE
	switch_to_tab, which synchronously hides the old grid and exits the lock.
	No-op when the lock isn't active — unlocked taps grab click focus natively."""
	if not ui_manager.is_focus_lock_active():
		return
	ui_manager.release_focus_lock()
	if not _nav_node or index < 0 or index >= _nav_node._destination_items.size():
		return
	var item: Control = _nav_node._destination_items[index]
	if item.focus_mode != Control.FOCUS_NONE:
		ui_manager.grab_focus_silent(item)

func _show_add_menu(anchor: Control) -> void:
	"""Open the add-shortcut context menu anchored to the plus destination."""
	if not anchor:
		return
	if _add_menu and is_instance_valid(_add_menu):
		_add_menu.queue_free()
	_add_menu = M3Menu.new()
	_add_menu.add_item("Shortcut", _on_add_menu_item_selected, "expand-all")
	_add_menu.add_item("Collection", _on_add_collection_selected, "star")
	if not _has_favorites_pin():
		_add_menu.add_item("Favorites", _on_add_favorites_selected, "heart")
	_add_menu.add_item("Platform", _on_add_platform_selected, "gamepad-variant")
	_add_menu.popup(anchor)

func _on_add_menu_item_selected() -> void:
	"""Open the platform-appropriate shortcut picker."""
	if SystemManager.platform.is_android():
		_show_android_app_picker()
	else:
		_show_desktop_file_picker()

func _on_add_collection_selected() -> void:
	"""Open the collection picker to pin a RomM collection."""
	var picker := CollectionPicker.new()
	picker.set_pinned_ids(_get_pinned_collection_ids())
	picker.collection_selected.connect(_on_collection_pin_selected)
	picker.show_overlay()

func _has_favorites_pin() -> bool:
	if not DataManager:
		return false
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting or not (setting.value is Array):
		return false
	for item in setting.value:
		if item is Dictionary and item.get("type", "") == "favorites":
			return true
	return false

func _on_add_favorites_selected() -> void:
	"""Pin the RomM favorites collection to the navigation bar."""
	if _has_favorites_pin():
		return

	if ui_manager and ui_manager.view:
		ui_manager.view._add_favorites_tab()

	var pin := {
		"id": "favorites",
		"type": "favorites",
		"label": "Favorites",
		"icon": "heart",
		"view": "Favorites",
		"data": {}
	}
	_add_pinned_shortcut(pin)
	ui_manager.switch_to_tab(pin.view)

func _get_pinned_collection_ids() -> Array[int]:
	var ids: Array[int] = []
	if not DataManager:
		return ids
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting or not (setting.value is Array):
		return ids
	for item in setting.value:
		if item is Dictionary and item.get("type", "") == "collection":
			var id = item.get("data", {}).get("collection_id", 0)
			if id is int and id > 0 and not ids.has(id):
				ids.append(id)
	return ids

func _on_collection_pin_selected(collection_id: int, collection_name: String) -> void:
	"""Persist a new collection pin and rebuild the navigation."""
	if collection_id == 0:
		return
	if _get_pinned_collection_ids().has(collection_id):
		return
	
	if ui_manager and ui_manager.view:
		ui_manager.view._add_collection_tab(collection_id, collection_name)
	
	var pin := {
		"id": "collection_%d" % collection_id,
		"type": "collection",
		"label": collection_name,
		"icon": "star",
		"view": "Collection_%d" % collection_id,
		"data": {"collection_id": collection_id, "collection_name": collection_name}
	}
	_add_pinned_shortcut(pin)
	ui_manager.switch_to_tab(pin.view)

func _on_add_platform_selected() -> void:
	"""Open the platform picker to pin a synced platform."""
	var picker := PlatformPicker.new()
	picker.set_disabled_slugs(_get_pinned_platform_slugs())
	picker.platform_selected.connect(_on_platform_pin_selected)
	picker.show_overlay()

func _get_pinned_platform_slugs() -> Array[String]:
	var slugs: Array[String] = []
	if not DataManager:
		return slugs
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting or not (setting.value is Array):
		return slugs
	for item in setting.value:
		if item is Dictionary and item.get("type", "") == "platform":
			var slug = item.get("data", {}).get("platform_slug", "")
			if slug is String and not slug.is_empty() and not slugs.has(slug):
				slugs.append(slug)
	return slugs

func _on_platform_pin_selected(platform_slug: String, platform_name: String) -> void:
	"""Persist a new platform pin and rebuild the navigation."""
	if platform_slug.is_empty():
		return
	if _get_pinned_platform_slugs().has(platform_slug):
		return

	if ui_manager and ui_manager.view:
		ui_manager.view._add_platform_tab(platform_slug)

	var pin := {
		"id": "platform_%s" % platform_slug,
		"type": "platform",
		"label": platform_name,
		"icon": "gamepad-variant",
		"view": "Platform_%s" % platform_slug,
		"data": {"platform_slug": platform_slug, "platform_name": platform_name}
	}
	_add_pinned_shortcut(pin)
	ui_manager.switch_to_tab(pin.view)

func _show_desktop_file_picker() -> void:
	var filters := PackedStringArray(["*"])
	match OS.get_name():
		"Windows":
			filters = PackedStringArray(["*.exe", "*.bat", "*.cmd"])
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			filters = PackedStringArray(["*.desktop", "*.sh", "*.AppImage", "*"])
	UIManager.show_file_dialog(
		"Select Shortcut",
		filters,
		"",
		_on_shortcut_file_selected
	)

func _on_shortcut_file_selected(path: String) -> void:
	if path.is_empty():
		return
	var label := path.get_file().get_basename()
	if path.to_lower().ends_with(".desktop"):
		var desktop_name := _read_desktop_entry(path, "Name")
		if not desktop_name.is_empty():
			label = desktop_name
	var pin := {
		"id": _generate_shortcut_id(),
		"type": "program",
		"label": label,
		"icon": "application",
		"data": {"path": path}
	}
	_add_pinned_shortcut(pin)

func _show_android_app_picker() -> void:
	var picker := AndroidAppPicker.new()
	picker.app_selected.connect(_on_android_app_selected)
	picker.show_overlay()

func _on_android_app_selected(package_name: String, app_name: String, icon_base64: String) -> void:
	var pin := {
		"id": package_name,
		"type": "app",
		"label": app_name,
		"icon": "application",
		"icon_data": icon_base64,
		"data": {"package": package_name}
	}
	_add_pinned_shortcut(pin)

func _add_pinned_shortcut(pin: Dictionary) -> void:
	"""Persist a new pinned shortcut and rebuild the navigation."""
	if not DataManager:
		return
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting:
		return
	var current: Array = setting.value.duplicate() if setting.value is Array else []
	current.append(pin)
	DataManager.set_setting(current, setting)
	DataManager.save_settings()
	print("[NavigationManager] added pin id=%s type=%s total_pins=%d" % [pin.get("id", ""), pin.get("type", ""), current.size()])
	_rebuild_nav_and_layout()

func _generate_shortcut_id() -> String:
	return "pin_%d_%d" % [Time.get_ticks_msec(), randi() % 100000]

func _on_pinned_context_menu_requested(item: Control, dest: Dictionary) -> void:
	_show_pin_context_menu(dest, item)

func _show_pin_context_menu(dest: Dictionary, anchor: Control) -> void:
	if _add_menu and is_instance_valid(_add_menu):
		_add_menu.queue_free()
	_add_menu = M3Menu.new()
	_add_menu.add_item("Remove shortcut", _on_remove_pin_selected.bind(dest), "delete")
	_add_menu.popup(anchor)

func _on_remove_pin_selected(dest: Dictionary) -> void:
	if not DataManager:
		return
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting:
		return
	var current: Array = setting.value.duplicate() if setting.value is Array else []
	var filtered: Array = []
	var target_id = dest.get("id", "")
	for pin in current:
		if pin is Dictionary and pin.get("id", "") != target_id:
			filtered.append(pin)
	DataManager.set_setting(filtered, setting)
	DataManager.save_settings()
	print("[NavigationManager] removed pin id=%s remaining_pins=%d" % [target_id, filtered.size()])
	
	if dest.get("type") == "collection":
		var collection_id = dest.get("data", {}).get("collection_id", 0)
		if collection_id != 0 and ui_manager and ui_manager.view:
			ui_manager.view._remove_collection_tab(collection_id)
	elif dest.get("type") == "favorites":
		if ui_manager and ui_manager.view:
			ui_manager.view._remove_favorites_tab()
	elif dest.get("type") == "platform":
		var platform_slug: String = dest.get("data", {}).get("platform_slug", "")
		if not platform_slug.is_empty() and ui_manager and ui_manager.view:
			ui_manager.view._remove_platform_tab(platform_slug)
	
	_rebuild_nav_and_layout()

func _launch_pinned_shortcut(dest: Dictionary) -> void:
	if not dest.has("type") or not dest.has("data"):
		return
	
	var type: String = dest.type
	var data: Dictionary = dest.data
	
	if type == "program":
		var path: String = data.get("path", "")
		if path.is_empty():
			return
		var resolved := FileSystemSubManager.resolve_native_path(path)
		match OS.get_name():
			"Windows":
				if resolved.to_lower().ends_with(".exe") or resolved.to_lower().ends_with(".bat") or resolved.to_lower().ends_with(".cmd"):
					OS.create_process(resolved, [])
				else:
					OS.shell_open(resolved)
			"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
				_launch_linux_program(resolved)
			_:
				OS.shell_open(resolved)
		return
	
	if type == "app":
		var package_name: String = data.get("package", "")
		if package_name.is_empty():
			return
		if not Engine.has_singleton("PackageChecker"):
			push_error("[NavigationManager] PackageChecker plugin not available")
			return
		var plugin = Engine.get_singleton("PackageChecker")
		var success: bool = plugin.call("launchAppByPackageName", package_name)
		if success and LaunchManager and LaunchManager.process:
			LaunchManager.process.enter_background_state_android(null)
		return

func _launch_linux_program(path: String) -> void:
	if path.to_lower().ends_with(".desktop"):
		var exec_parts := _parse_desktop_exec(path)
		if not exec_parts.is_empty():
			var command := exec_parts[0]
			var args := PackedStringArray()
			for i in range(1, exec_parts.size()):
				args.append(exec_parts[i])
			OS.create_process(command, args)
			return
		push_warning("[NavigationManager] Could not parse Exec= from .desktop file: %s" % path)
		OS.shell_open(path)
		return

	if path.to_lower().ends_with(".sh") or _has_shebang(path):
		if _is_executable(path):
			OS.create_process(path, [])
		else:
			OS.create_process("/bin/sh", [path])
		return

	if _is_executable(path):
		OS.create_process(path, [])
		return

	OS.shell_open(path)


func _is_executable(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var perms: int = FileAccess.get_unix_permissions(path)
	# Any execute bit set (owner=64, group=8, other=1).
	return (perms & 73) != 0


func _has_shebang(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	return file.get_line().strip_edges().begins_with("#!")


func _parse_desktop_exec(desktop_path: String) -> PackedStringArray:
	var file := FileAccess.open(desktop_path, FileAccess.READ)
	if not file:
		return PackedStringArray()
	while file.get_position() < file.get_length():
		var line := file.get_line().strip_edges()
		if line.begins_with("Exec="):
			var exec_line := line.substr(5)
			# Replace escaped percent, then remove field codes (%f, %u, etc.).
			exec_line = exec_line.replace("%%", "__PERCENT__")
			var raw_tokens := exec_line.split(" ", false)
			var tokens := PackedStringArray()
			for token in raw_tokens:
				if token.begins_with("%"):
					continue
				tokens.append(token.strip_edges().replace("__PERCENT__", "%"))
			if tokens.is_empty():
				return PackedStringArray()
			# Strip surrounding quotes from the command.
			var command := tokens[0].trim_prefix("\"").trim_suffix("\"")
			if command.is_empty():
				return PackedStringArray()
			tokens[0] = command
			return tokens
	return PackedStringArray()


func _read_desktop_entry(desktop_path: String, key: String) -> String:
	var file := FileAccess.open(desktop_path, FileAccess.READ)
	if not file:
		return ""
	while file.get_position() < file.get_length():
		var line := file.get_line().strip_edges()
		if line.begins_with(key + "="):
			return line.substr(key.length() + 1).strip_edges()
	return ""


func _get_all_nav_destinations() -> Array[M3NavigationDestination]:
	"""Return all destination items from the current nav node."""
	if not _nav_node:
		return []
	return _nav_node._destination_items

func _get_focused_destination_index(focused: Control) -> int:
	"""Index into the nav destinations of the focused destination, or -1.
	Uses an ancestor walk so focus held by a destination's child still counts."""
	if not focused:
		return -1
	var destinations := _get_all_nav_destinations()
	for i in range(destinations.size()):
		var dest := destinations[i]
		if dest == focused or dest.is_ancestor_of(focused):
			return i
	return -1

func _setup_nav_focus_neighbors() -> void:
	"""Block the one direction that leaks from nav into the game grid and
	wire the last destination directly to the settings button so controller
	navigation always ends at settings rather than escaping to the grid."""
	if not _nav_node:
		return

	var destinations := _get_all_nav_destinations()
	var settings_btn := find_nav_settings_button()

	# Block the grid-leak direction for every destination (including pins and add button).
	for dest in destinations:
		if _nav_type == 0:  # Bar — grid is above
			dest.focus_neighbor_top = NodePath("")
		else:  # Rail — grid is to the right
			dest.focus_neighbor_right = NodePath("")

	# Wire the last destination to the settings button and back.
	if destinations.size() > 0 and settings_btn:
		var last_dest = destinations[destinations.size() - 1]
		if last_dest.is_inside_tree() and settings_btn.is_inside_tree():
			if _nav_type == 0:  # Bar — settings is to the right of the last destination
				last_dest.focus_neighbor_right = settings_btn.get_path()
				settings_btn.focus_neighbor_left = last_dest.get_path()
			else:  # Rail — settings is below the last destination
				last_dest.focus_neighbor_bottom = settings_btn.get_path()
				settings_btn.focus_neighbor_top = last_dest.get_path()
		else:
			# Internal UI may not be fully in the tree yet; retry after a frame.
			call_deferred("_setup_nav_focus_neighbors")

	# Block settings button from leaking to the grid.
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

	var destinations := _get_all_nav_destinations()
	if destinations.size() > 0:
		return destinations[0]
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
	"""Find the last nav destination (e.g. Library or the plus button)."""
	if not _nav_node:
		return null

	var destinations := _get_all_nav_destinations()
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

	var destinations := _get_all_nav_destinations()
	if selected_idx < destinations.size():
		return destinations[selected_idx]
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
	"""Ensure the feedback handler is connected. Focus events arrive via the
	FocusSubManager hub, which tracks the UI viewport across dual-screen
	reparents itself, so this is an idempotent ensure-connect."""
	var hub := FocusSubManager.get_instance()
	if hub and not hub.ui_focus_changed.is_connected(_on_feedback_focus_changed):
		hub.ui_focus_changed.connect(_on_feedback_focus_changed)

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
	if SystemManager.audio:
		SystemManager.audio.play_sfx("click_00")

func _control_is_game_card(control: Control) -> bool:
	"""Traverse up the tree to check if control is inside a GameCard."""
	var ancestor = control
	while ancestor:
		if ancestor is GameCard:
			return true
		ancestor = ancestor.get_parent()
	return false

func _get_active_viewport() -> Viewport:
	"""Resolve the viewport that actually owns GUI focus for the nav UI.
	Delegates to UIManager's unified resolver (dual-screen SubViewport aware)."""
	return ui_manager.get_active_viewport()

func _unhandled_input(event: InputEvent) -> void:
	"""Play activation sound on ui_accept for non-game card elements."""
	if event.is_action_pressed("ui_accept"):
		var focused = _get_active_viewport().gui_get_focus_owner()
		if focused and is_instance_valid(focused) and not _control_is_game_card(focused):
			if SystemManager.audio:
				SystemManager.audio.play_sfx("click_03")

# ==================== UNIFIED DIRECTIONAL INPUT / AUTO-REPEAT ====================

func handle_directional_input(event: InputEvent) -> bool:
	"""Handle directional input events. Returns true if the event was consumed."""
	# Let the on-screen keyboard handle its own controller navigation.
	if UIManager and UIManager.is_onscreen_keyboard_visible():
		return false
	
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
				if DEBUG_LOG: print("[NavInput] synthetic press state-guarded, allowed for ", dir)
				return false

			if event is InputEventKey:
				var now := Time.get_ticks_msec()
				if now - _last_press < KEYBOARD_DEBOUNCE_MS:
					return true
				_last_press = now

			if _held_dir == dir and _held_source == InputSource.DISCRETE:
				if DEBUG_LOG: print("[NavInput] engine echo swallowed for ", dir)
				return true

			if _held_source == InputSource.ANALOG:
				if DEBUG_LOG: print("[NavInput] switching from analog to discrete ", dir)
				_held_source = InputSource.DISCRETE

			_held_dir = dir
			_held_source = InputSource.DISCRETE
			if DEBUG_LOG: print("[NavInput] first press ", dir)
			_delay_timer.start()
			return _dispatch_direction(dir)

		if event.is_action_released(dir) and _held_dir == dir and _held_source == InputSource.DISCRETE:
			if event.has_meta("kyodai_synthetic"):
				if DEBUG_LOG: print("[NavInput] synthetic release allowed for ", dir)
				return false
			if DEBUG_LOG: print("[NavInput] discrete release for ", dir)
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
	if DEBUG_LOG: print("[NavDispatch] dispatching ", dir)

	if _try_nav_to_grid(dir):
		if DEBUG_LOG: print("[NavDispatch] nav-to-grid consumed ", dir)
		return true

	var grid := _get_current_grid()
	if grid:
		var focused := _get_active_viewport().gui_get_focus_owner()
		var focus_in_grid := focused != null and grid.is_ancestor_of(focused)
		if grid.is_focus_locked_and_active() or focus_in_grid:
			# The lock can be dropped while focus is still inside the grid (e.g. a
			# deferred refresh ran during a programmatic focus handoff). Re-establish
			# it so the first directional press navigates instead of no-oping.
			if focus_in_grid and not grid.is_focus_locked_and_active():
				UIManager.enter_focus_lock(grid)
			var result := grid.navigate_direction(dir)
			if DEBUG_LOG: print("[NavDispatch] grid.navigate_direction(", dir, ") = ", result)
			return result

	_send_synthetic(dir)
	if DEBUG_LOG: print("[NavDispatch] synthetic event sent for ", dir)
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
	if DEBUG_LOG: print("[NavTimer] delay timeout fired, held_dir=", _held_dir, ", source=", _held_source)
	# Safety trap: stop dispatching if the keyboard became visible since the timer started.
	if UIManager and UIManager.is_onscreen_keyboard_visible():
		_held_dir = ""
		_held_source = InputSource.NONE
		_delay_timer.stop()
		_repeat_timer.stop()
		return
	if _held_dir != "":
		_repeat_timer.start()
		_dispatch_direction(_held_dir)

func _on_repeat() -> void:
	if DEBUG_LOG: print("[NavTimer] repeat timeout fired, held_dir=", _held_dir, ", source=", _held_source)
	# Safety trap: stop dispatching if the keyboard became visible since the timer started.
	if UIManager and UIManager.is_onscreen_keyboard_visible():
		_held_dir = ""
		_held_source = InputSource.NONE
		_repeat_timer.stop()
		return
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
	var focused := _get_active_viewport().gui_get_focus_owner()
	if not focused:
		return false

	var nav_type := get_nav_type()
	var settings_btn := find_nav_settings_button()
	var destinations := _get_all_nav_destinations()
	var dest_idx := _get_focused_destination_index(focused)

	# From nav destination -> siblings / Grid / Settings.
	# Sibling movement is walked manually through the destination list: Godot's
	# spatial search can pick a grid card instead (seen most in pagination
	# views where card rects rebuild constantly), leaking focus into the grid.
	if dest_idx >= 0:
		if nav_type == 0:  # Bar
			if dir == "ui_up":
				return _enter_grid()
			if dir == "ui_right":
				if dest_idx < destinations.size() - 1:
					destinations[dest_idx + 1].grab_focus()
					return true
				if settings_btn and settings_btn.focus_mode != Control.FOCUS_NONE:
					settings_btn.grab_focus()
				return true  # Clamp at the last destination
			if dir == "ui_left":
				if dest_idx > 0:
					destinations[dest_idx - 1].grab_focus()
				return true  # Clamp at the first destination
			return false
		else:  # Rail
			if dir == "ui_right":
				return _enter_grid()
			if dir == "ui_down":
				if dest_idx < destinations.size() - 1:
					destinations[dest_idx + 1].grab_focus()
					return true
				if settings_btn and settings_btn.focus_mode != Control.FOCUS_NONE:
					settings_btn.grab_focus()
				elif settings_btn:
					# Fallback: force focus onto settings if neighbor wiring is missing.
					settings_btn.focus_mode = Control.FOCUS_ALL
					settings_btn.grab_focus()
				return true  # Clamp at the last destination
			if dir == "ui_up":
				if dest_idx > 0:
					destinations[dest_idx - 1].grab_focus()
				return true  # Clamp at the first destination
			return false

	# From Settings -> Last nav destination (LEFT for bar, UP for rail)
	if focused == settings_btn and destinations.size() > 0:
		var last_dest := destinations[destinations.size() - 1]
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
