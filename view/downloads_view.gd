class_name DownloadsView
extends View

@onready var scroll_container: ScrollContainer = $VBoxContainer/ScrollContainer
@onready var downloads_list: VBoxContainer = $VBoxContainer/ScrollContainer/DownloadsList
@onready var clear_completed_button: M3Button = $VBoxContainer/Toolbar/ClearCompletedButton

var _download_items: Dictionary = {}  # item_id -> DownloadCard

func _ready():
	clear_completed_button.pressed.connect(_on_clear_completed)
	
	# Connect to new SystemManager.download signals
	SystemManager.download.queue_changed.connect(_refresh_list)
	SystemManager.download.download_started.connect(_on_download_started)
	SystemManager.download.download_progress.connect(_on_download_progress)
	SystemManager.download.download_completed.connect(_on_download_completed)
	SystemManager.download.extraction_started.connect(_on_extraction_started)
	SystemManager.download.extraction_progress.connect(_on_extraction_progress)
	SystemManager.download.extraction_completed.connect(_on_extraction_completed)
	
	_refresh_list()
	
	# Let the base View class own the focus signal connection.
	reconnect_viewport()

func _refresh_list():
	# Clear existing
	for item in _download_items.values():
		if is_instance_valid(item):
			item.queue_free()
	_download_items.clear()
	
	# Get all queued and active items from SystemManager.download
	for item in SystemManager.download.get_queued():
		if item.game_resource != null:  # Only show game downloads in this view
			_add_download_item(item)
	
	for item in SystemManager.download.get_active():
		if item.game_resource != null:  # Only show game downloads in this view
			_add_download_item(item)
	
	_update_status()

func _add_download_item(item):
	if _download_items.has(item.id):
		return
	
	var item_scene = preload("res://components/download_card.tscn")
	var ui_item = item_scene.instantiate()
	ui_item.set_download_item(item)
	downloads_list.add_child(ui_item)
	_download_items[item.id] = ui_item

func _on_download_started(_item_id: String):
	_refresh_list()

func _on_download_progress(_item_id: String, _progress: float):
	if _download_items.has(_item_id):
		var item = _download_items[_item_id]
		if is_instance_valid(item):
			item._update_display()

func _on_download_completed(_item_id: String, _success: bool, _message: String):
	if _download_items.has(_item_id):
		var item = _download_items[_item_id]
		if is_instance_valid(item):
			item._update_display()
	_update_status()

func _on_extraction_started(item_id: String):
	if _download_items.has(item_id):
		var item = _download_items[item_id]
		if is_instance_valid(item):
			item._update_display()

func _on_extraction_progress(_item_id: String, _progress: float):
	if _download_items.has(_item_id):
		var item = _download_items[_item_id]
		if is_instance_valid(item):
			item._update_display()

func _on_extraction_completed(_item_id: String, _success: bool, _message: String):
	if _download_items.has(_item_id):
		var item = _download_items[_item_id]
		if is_instance_valid(item):
			item._update_display()
	_update_status()

func _on_clear_completed():
	# Remove completed/failed items
	var to_remove = []
	for item_id in _download_items.keys():
		var item_ui = _download_items[item_id]
		if is_instance_valid(item_ui) and item_ui.download_item:
			var status = item_ui.download_item.status
			if status == "completed" or status == "failed":
				to_remove.append(item_id)
				item_ui.queue_free()
	
	for item_id in to_remove:
		_download_items.erase(item_id)
	
	_update_status()

func _update_status(_text: String = "") -> void:
	# Status bar removed - no-op
	pass
