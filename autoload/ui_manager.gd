extends Manager

# UIManager - Manages tab-based view navigation
# Coordinates between the main TabContainer and view instances

var _tab_container: TabContainer
var _views: Dictionary[String, View] = {}
var _current_view: View

func initialize(tab_container: TabContainer):
	_tab_container = tab_container
	_tab_container.tab_changed.connect(_on_tab_changed)
	
	# Setup existing tabs
	_setup_library_tab()
	_setup_downloads_tab()
	_setup_settings_tab()

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
	var library_scene = preload("res://ui/library_view.tscn")
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
	var downloads_scene = preload("res://ui/downloads_view.tscn")
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

func get_view(view_name: String) -> View:
	if _views.has(view_name):
		return _views[view_name]
	return null

func switch_to_tab(tab_name: String):
	var idx = _get_tab_index(tab_name)
	if idx != -1:
		_tab_container.current_tab = idx
