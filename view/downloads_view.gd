class_name DownloadsView
extends View

@onready var scroll_container: ScrollContainer = $VBoxContainer/ScrollContainer
@onready var downloads_list: VBoxContainer = $VBoxContainer/ScrollContainer/DownloadsList
@onready var clear_completed_button: Button = $VBoxContainer/Toolbar/ClearCompletedButton
@onready var status_label: Label = $VBoxContainer/StatusLabel

var _download_items: Dictionary = {}  # item_id -> DownloadCard

func _ready():
	clear_completed_button.pressed.connect(_on_clear_completed)
	
	# Connect to new DownloadManager signals
	DownloadManager.queue_changed.connect(_refresh_list)
	DownloadManager.download_started.connect(_on_download_started)
	DownloadManager.download_progress.connect(_on_download_progress)
	DownloadManager.download_completed.connect(_on_download_completed)
	DownloadManager.extraction_started.connect(_on_extraction_started)
	DownloadManager.extraction_progress.connect(_on_extraction_progress)
	DownloadManager.extraction_completed.connect(_on_extraction_completed)
	
	_refresh_list()

func _refresh_list():
	# Clear existing
	for item in _download_items.values():
		if is_instance_valid(item):
			item.queue_free()
	_download_items.clear()
	
	# Get all queued and active items from DownloadManager
	for item in DownloadManager.get_queued():
		if item.game_resource != null:  # Only show game downloads in this view
			_add_download_item(item)
	
	for item in DownloadManager.get_active():
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

func _on_download_started(item_id: String):
	_refresh_list()

func _on_download_progress(item_id: String, progress: float):
	if _download_items.has(item_id):
		var item = _download_items[item_id]
		if is_instance_valid(item):
			item._update_display()

func _on_download_completed(item_id: String, success: bool, message: String):
	if _download_items.has(item_id):
		var item = _download_items[item_id]
		if is_instance_valid(item):
			item._update_display()
	_update_status()

func _on_extraction_started(item_id: String):
	if _download_items.has(item_id):
		var item = _download_items[item_id]
		if is_instance_valid(item):
			item._update_display()

func _on_extraction_progress(item_id: String, progress: float):
	if _download_items.has(item_id):
		var item = _download_items[item_id]
		if is_instance_valid(item):
			item._update_display()

func _on_extraction_completed(item_id: String, success: bool, message: String):
	if _download_items.has(item_id):
		var item = _download_items[item_id]
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

func _update_status():
	var queued = DownloadManager.get_queued().size()
	var active = DownloadManager.get_active().size()
	
	if active > 0:
		status_label.text = "Downloading: %d active, %d queued" % [active, queued]
	elif queued > 0:
		status_label.text = "Queued: %d downloads" % queued
	else:
		status_label.text = "No active downloads"
