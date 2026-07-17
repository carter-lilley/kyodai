class_name ViewSubManager
extends Manager

var ui_manager: Node

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

var _library_tab: Control = null
var _library_scene_path: String = "res://view/library_view.tscn"

var _downloads_tab: Control = null
var _downloads_scene_path: String = "res://view/downloads_view.tscn"

var _collection_scene_path: String = "res://view/collection_view.tscn"
var _collection_tabs: Dictionary[int, Control] = {}

func _ready():
	ui_manager = get_parent()

enum RefreshType { STRUCTURE = 1, EFFECTS = 2 }

var _pending_refresh_mask: int = 0
var _pending_effects_full_rebuild: bool = false
var _skip_next_dialog_dismiss_flush: bool = false
var _effects_refresh_was_deferred: bool = false

func setup(tab_container: TabContainer) -> void:
	var setup_start_us := Time.get_ticks_usec()
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	ui_manager.settings_dialog_dismissed.connect(_on_settings_dialog_dismissed)

	var phase_start_us := Time.get_ticks_usec()
	_setup_home_tab()
	print("[ViewSubManager] _setup_home_tab elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	_setup_library_tab()
	print("[ViewSubManager] _setup_library_tab elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	_setup_downloads_tab()
	print("[ViewSubManager] _setup_downloads_tab elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	_setup_collection_tabs()
	print("[ViewSubManager] _setup_collection_tabs elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	_sync_current_view_from_tab()
	print("[ViewSubManager] setup total elapsed_us=", Time.get_ticks_usec() - setup_start_us)

func _setup_home_tab():
	var setup_start_us := Time.get_ticks_usec()

	var home_idx = _get_tab_index("Home")
	if home_idx == -1:
		push_warning("[ViewManager]: Home tab not found")
		return

	var home_tab = _tab_container.get_tab_control(home_idx)

	# Clear existing content
	for child in home_tab.get_children():
		child.queue_free()

	# Add HomeView (load scene to get UI nodes)
	var phase_start_us := Time.get_ticks_usec()
	var home_scene = load("res://view/home_view.tscn")
	var home_view = home_scene.instantiate()
	print("[ViewSubManager] Home scene load/instantiate elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	home_view.view_name = "Home"
	home_tab.add_child(home_view)
	print("[ViewSubManager] Home add_child/_ready elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	_views["Home"] = home_view

	# Connect hero image signal
	if home_view.has_signal("hero_game_changed"):
		home_view.hero_game_changed.connect(ui_manager._on_hero_game_changed)

	print("[ViewSubManager] _setup_home_tab total elapsed_us=", Time.get_ticks_usec() - setup_start_us)

func _setup_library_tab():
	var library_idx = _get_tab_index("Library")
	if library_idx == -1:
		push_warning("[ViewManager]: Library tab not found")
		return

	var library_tab = _tab_container.get_tab_control(library_idx)

	# Clear existing content
	for child in library_tab.get_children():
		child.queue_free()

	# Defer LibraryView instantiation until the user first selects the Library tab.
	# This avoids paying the setup/data cost on startup when Home is shown first.
	_library_tab = library_tab

func _ensure_library_setup() -> bool:
	if _views.has("Library"):
		return true
	if _library_tab == null:
		return false

	var library_scene = load(_library_scene_path)
	var library_view = library_scene.instantiate()
	library_view.view_name = "Library"
	_library_tab.add_child(library_view)
	_views["Library"] = library_view

	# Connect hero image signal
	if library_view.has_signal("hero_game_changed"):
		library_view.hero_game_changed.connect(ui_manager._on_hero_game_changed)

	return true

func _setup_downloads_tab():
	var setup_start_us := Time.get_ticks_usec()

	var downloads_idx = _get_tab_index("Downloads")
	if downloads_idx == -1:
		push_warning("[ViewManager]: Downloads tab not found")
		return

	var downloads_tab = _tab_container.get_tab_control(downloads_idx)

	# Clear existing content
	for child in downloads_tab.get_children():
		child.queue_free()

	# Defer DownloadsView instantiation until the user first selects the Downloads tab.
	# This avoids paying the scene-load cost on startup when Home is shown first.
	_downloads_tab = downloads_tab

	print("[ViewSubManager] _setup_downloads_tab total elapsed_us=", Time.get_ticks_usec() - setup_start_us)

func _ensure_downloads_setup() -> bool:
	if _views.has("Downloads"):
		return true
	if _downloads_tab == null:
		return false

	var phase_start_us := Time.get_ticks_usec()
	var downloads_scene = load(_downloads_scene_path)
	var downloads_view = downloads_scene.instantiate()
	print("[ViewSubManager] Downloads scene load/instantiate elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	downloads_view.view_name = "Downloads"
	_downloads_tab.add_child(downloads_view)
	print("[ViewSubManager] Downloads add_child/_ready elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	_views["Downloads"] = downloads_view

	return true

func _setup_collection_tabs() -> void:
	if not DataManager:
		return
	var setting = DataManager.get_setting("nav_pinned_shortcuts")
	if not setting or not (setting.value is Array):
		return
	
	for item in setting.value:
		if not (item is Dictionary):
			continue
		if item.get("type", "") != "collection":
			continue
		var collection_id = item.get("data", {}).get("collection_id", 0)
		if collection_id == 0:
			continue
		var collection_name = item.get("data", {}).get("collection_name", "")
		_add_collection_tab(collection_id, collection_name)

func _add_collection_tab(collection_id: int, collection_name: String = "") -> void:
	if collection_id == 0:
		return
	if _collection_tabs.has(collection_id):
		return
	
	var tab_title = _collection_tab_title(collection_id)
	var tab = Control.new()
	tab.name = tab_title
	tab.visible = false
	_tab_container.add_child(tab)
	_collection_tabs[collection_id] = tab

func _ensure_collection_setup(collection_id: int) -> bool:
	var tab_title = _collection_tab_title(collection_id)
	if _views.has(tab_title):
		return true
	if not _collection_tabs.has(collection_id):
		return false
	
	var tab = _collection_tabs[collection_id]
	var collection = DataManager.get_collection(collection_id)
	var collection_name = collection.get("name", "") if collection else ""
	
	var scene = load(_collection_scene_path)
	var collection_view = scene.instantiate()
	collection_view.collection_id = collection_id
	collection_view.collection_name = collection_name
	collection_view.view_name = tab_title
	tab.add_child(collection_view)
	_views[tab_title] = collection_view
	
	if collection_view.has_signal("hero_game_changed"):
		collection_view.hero_game_changed.connect(ui_manager._on_hero_game_changed)
	
	return true

func _remove_collection_tab(collection_id: int) -> void:
	var tab_title = _collection_tab_title(collection_id)
	
	if _current_view and _current_view.view_name == tab_title:
		switch_to_tab("Home")
	
	if _views.has(tab_title):
		var view = _views[tab_title]
		_views.erase(tab_title)
		if view and is_instance_valid(view):
			view.queue_free()
	
	if _collection_tabs.has(collection_id):
		var tab = _collection_tabs[collection_id]
		_collection_tabs.erase(collection_id)
		if tab and is_instance_valid(tab) and tab.get_parent() == _tab_container:
			_tab_container.remove_child(tab)
			tab.queue_free()

func _collection_tab_title(collection_id: int) -> String:
	return "Collection_%d" % collection_id

func _is_collection_tab_title(tab_title: String) -> bool:
	return tab_title.begins_with("Collection_")

func _get_collection_id_from_tab_title(tab_title: String) -> int:
	if not _is_collection_tab_title(tab_title):
		return 0
	var suffix = tab_title.substr("Collection_".length())
	return suffix.to_int()

func _sync_current_view_from_tab() -> void:
	var current_tab_idx = _tab_container.current_tab
	var current_tab_title = _tab_container.get_tab_title(current_tab_idx)
	if current_tab_title == "Library":
		_ensure_library_setup()
	if current_tab_title == "Downloads":
		_ensure_downloads_setup()
	if _is_collection_tab_title(current_tab_title):
		_ensure_collection_setup(_get_collection_id_from_tab_title(current_tab_title))
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

	# Show new view (create Library, Downloads, or collection tabs lazily on first visit)
	if tab_title == "Library":
		_ensure_library_setup()
	if tab_title == "Downloads":
		_ensure_downloads_setup()
	if _is_collection_tab_title(tab_title):
		_ensure_collection_setup(_get_collection_id_from_tab_title(tab_title))
	if _views.has(tab_title):
		_current_view = _views[tab_title]
		_current_view.on_view_show()

	ui_manager.tab_changed.emit(tab_title)
	# A new view may have a focused grid; refresh focus lock state next frame.
	ui_manager.call_deferred("refresh_focus_lock_state")

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
		_effects_refresh_was_deferred = true
		if force_full_rebuild:
			_pending_effects_full_rebuild = true
		return
	_apply_effects_refresh(force_full_rebuild)

func _apply_structure_refresh() -> void:
	for view_name in _views.keys():
		_views[view_name]._update_grid_orientation()

func _apply_effects_refresh(force_full_rebuild: bool = false) -> void:
	for view_name in _views.keys():
		var view = _views[view_name]
		if view.games_grid:
			view.games_grid.refresh_all_card_effects(force_full_rebuild)

func _on_settings_dialog_dismissed() -> void:
	if _skip_next_dialog_dismiss_flush:
		_skip_next_dialog_dismiss_flush = false
		return
	_apply_pending_refresh()
	_effects_refresh_was_deferred = false

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
	# Only force a full off-screen effect refresh if actual effect work was
	# deferred while the dialog was open. Otherwise opening/closing settings
	# with no changes rebuilds every card for no reason.
	if _effects_refresh_was_deferred and current_view and current_view.games_grid:
		current_view.games_grid.refresh_all_card_effects(true)
	_effects_refresh_was_deferred = false

func _apply_pending_refresh() -> void:
	if _pending_refresh_mask & RefreshType.STRUCTURE:
		_apply_structure_refresh()
	if _pending_refresh_mask & RefreshType.EFFECTS:
		_apply_effects_refresh(_pending_effects_full_rebuild)
	_pending_refresh_mask = 0
	_pending_effects_full_rebuild = false
	_effects_refresh_was_deferred = false

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
	# If Library has never been instantiated, it will be built fresh when first shown.

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
	"""Rebuild the library view to reflect card size changes (only if set up)."""
	if _views.has("Library"):
		var library_view = _views["Library"]
		if library_view.has_method("rebuild_grid"):
			library_view.rebuild_grid()

func get_view(view_name: String) -> View:
	if _views.has(view_name):
		return _views[view_name]
	return null

func get_all_views() -> Array[View]:
	return _views.values()

func switch_to_tab(tab_name: String):
	var idx = _get_tab_index(tab_name)
	if idx != -1:
		_tab_container.current_tab = idx
