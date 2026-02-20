extends Manager

# UIManager - Manages tab-based view navigation and modal overlays
# Coordinates between the main TabContainer, view instances, and modals

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

# Modal management
var _active_modal: Modal = null
var _modal_context: Dictionary = {}
var _root_control: Control = null
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

func initialize(tab_container: TabContainer, root_control: Control = null):
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	
	if root_control:
		_root_control = root_control
	else:
		_root_control = tab_container.get_parent_control()
	
	# Setup existing tabs
	_setup_library_tab()
	_setup_downloads_tab()
	_setup_settings_tab()
	
	# Setup modal input handling
	_setup_modal_input_handling()
	
	# Setup focus indicator
	_setup_focus_indicator()

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

func _on_tab_changed(tab_idx: int):
	var tab_title = _tab_container.get_tab_title(tab_idx)
	
	# Hide current view
	if _current_view:
		_current_view.on_view_hide()
	
	# Show new view
	if _views.has(tab_title):
		_current_view = _views[tab_title]
		_current_view.on_view_show()

func get_current_view() -> View:
	return _current_view

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

func show_game_context_menu(romm_id: int, position: Vector2) -> String:
	"""Show the standard game context menu."""
	var items: Array[Dictionary] = [
		{"id": "launch", "text": "Launch"},
		{"id": "details", "text": "Details"},
		{"id": "hide", "text": "Hide"}
	]
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
