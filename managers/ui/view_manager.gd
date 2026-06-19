class_name ViewManager
extends Manager

var ui_manager: Node

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

func _ready():
	ui_manager = get_parent()

enum RefreshType { STRUCTURE = 1, EFFECTS = 2 }

var _pending_refresh_mask: int = 0
var _pending_effects_full_rebuild: bool = false
var _skip_next_dialog_dismiss_flush: bool = false

func setup(tab_container: TabContainer) -> void:
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	ui_manager.settings_dialog_dismissed.connect(_on_settings_dialog_dismissed)

	_setup_home_tab()
	_setup_library_tab()
	_setup_downloads_tab()
	_sync_current_view_from_tab()

func _setup_home_tab():
	var home_idx = _get_tab_index("Home")
	if home_idx == -1:
		push_warning("[ViewManager]: Home tab not found")
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
		home_view.hero_game_changed.connect(ui_manager._on_hero_game_changed)

func _setup_library_tab():
	var library_idx = _get_tab_index("Library")
	if library_idx == -1:
		push_warning("[ViewManager]: Library tab not found")
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
		library_view.hero_game_changed.connect(ui_manager._on_hero_game_changed)

func _setup_downloads_tab():
	var downloads_idx = _get_tab_index("Downloads")
	if downloads_idx == -1:
		push_warning("[ViewManager]: Downloads tab not found")
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

func _sync_current_view_from_tab() -> void:
	var current_tab_idx = _tab_container.current_tab
	var current_tab_title = _tab_container.get_tab_title(current_tab_idx)
	if _views.has(current_tab_title):
		_current_view = _views[current_tab_title]
		_current_view.on_view_show()
		ui_manager.navigation._sync_nav_selection(current_tab_title)

func _on_tab_changed(tab_idx: int):
	var tab_title = _tab_container.get_tab_title(tab_idx)

	# Sync nav selection to the new tab
	ui_manager.navigation._sync_nav_selection(tab_title)

	# Hide current view
	if _current_view:
		_current_view.on_view_hide()

	# Show new view
	if _views.has(tab_title):
		_current_view = _views[tab_title]
		_current_view.on_view_show()

	ui_manager.tab_changed.emit(tab_title)

func _get_tab_index(tab_title: String) -> int:
	for i in range(_tab_container.get_tab_count()):
		if _tab_container.get_tab_title(i) == tab_title:
			return i
	return -1

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
		# Zoom overlay is managed by main.gd; ViewManager just knows the range
		pass

func update_structure() -> void:
	"""Apply orientation/mode changes to both views without full rebuilds.
	Deferred while the settings dialog is open."""
	if ui_manager.overlay.is_settings_dialog_open():
		_pending_refresh_mask |= RefreshType.STRUCTURE
		return
	_apply_structure_refresh()

func refresh_effects(force_full_rebuild: bool = false) -> void:
	"""Refresh card effects on both views. If only parameters changed, pass false
	to avoid rebuilding the effect node tree. Deferred while settings dialog is open."""
	if ui_manager.overlay.is_settings_dialog_open():
		_pending_refresh_mask |= RefreshType.EFFECTS
		if force_full_rebuild:
			_pending_effects_full_rebuild = true
		return
	_apply_effects_refresh(force_full_rebuild)

func _apply_structure_refresh() -> void:
	for view_name in ["Home", "Library"]:
		if _views.has(view_name):
			_views[view_name]._update_grid_orientation()

func _apply_effects_refresh(force_full_rebuild: bool = false) -> void:
	for view_name in ["Home", "Library"]:
		if not _views.has(view_name):
			continue
		var view = _views[view_name]
		if view.games_grid:
			view.games_grid.refresh_all_card_effects(force_full_rebuild)

func _on_settings_dialog_dismissed() -> void:
	if _skip_next_dialog_dismiss_flush:
		_skip_next_dialog_dismiss_flush = false
		return
	_apply_pending_refresh()

func skip_next_dialog_dismiss_flush() -> void:
	"""Signal that the next settings-dialog dismissal should not flush
	pending rebuilds. Used when opening a confirmation popup that replaces
	the settings dialog; the rebuild is deferred until the popup closes."""
	_skip_next_dialog_dismiss_flush = true

func flush_pending_rebuilds_if_no_dialog() -> void:
	"""Flush pending structure/effects rebuilds only if no dialog is open.
	This lets confirmation popups replace the settings dialog without
	triggering an immediate rebuild; the rebuild is deferred until the
	confirmation dialog itself closes."""
	if M3Overlay.is_showing("dialog"):
		return
	_apply_pending_refresh()
	var current_view = get_current_view()
	if current_view and current_view.needs_rebuild:
		current_view.check_and_rebuild_if_needed()

func _apply_pending_refresh() -> void:
	if _pending_refresh_mask & RefreshType.STRUCTURE:
		_apply_structure_refresh()
	if _pending_refresh_mask & RefreshType.EFFECTS:
		_apply_effects_refresh(_pending_effects_full_rebuild)
	_pending_refresh_mask = 0
	_pending_effects_full_rebuild = false

func _rebuild_views(reason: String, use_true: bool = false) -> void:
	"""Rebuild visible views immediately, mark hidden views for rebuild.
	Defer ALL rebuilds while any dialog overlay is open to avoid stutter
	and to prevent confirmation popups from triggering premature rebuilds."""
	var any_dialog_open = M3Overlay.is_showing("dialog")

	if _views.has("Home"):
		var home_view = _views["Home"]
		if is_current_view("Home") and not any_dialog_open:
			home_view.rebuild_grid(use_true)
		else:
			home_view.mark_for_rebuild(reason, use_true)
	if _views.has("Library"):
		var library_view = _views["Library"]
		if is_current_view("Library") and not any_dialog_open:
			library_view.rebuild_grid(use_true)
		else:
			library_view.mark_for_rebuild(reason, use_true)

func mark_view_for_rebuild(view_name: String, reason: String) -> void:
	if _views.has(view_name):
		_views[view_name].mark_for_rebuild(reason)

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
