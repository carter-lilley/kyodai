class_name DownloadsView
extends View

@onready var scroll_container: ScrollContainer = $VBoxContainer/ScrollContainer
@onready var downloads_list: VBoxContainer = $VBoxContainer/ScrollContainer/DownloadsList
@onready var clear_completed_button: Button = $VBoxContainer/Toolbar/ClearCompletedButton
@onready var status_label: Label = $VBoxContainer/StatusLabel

var _download_items: Dictionary = {}  # game_id -> DownloadItemUI

func _ready():
	clear_completed_button.pressed.connect(_on_clear_completed)
	
	# Connect to high-level network manager signals
	NetworkManager.download_progress_update.connect(_on_download_progress)
	NetworkManager.download_finished.connect(_on_download_completed)
	
	# Still need to connect to low-level queue changes for UI refresh
	DownloadManager.download_queue_changed.connect(_refresh_list)
	DownloadManager.download_started.connect(_on_download_started)
	
	_refresh_list()

func _refresh_list():
	# Clear existing
	for item in _download_items.values():
		if is_instance_valid(item):
			item.queue_free()
	_download_items.clear()
	
	# Use NetworkManager to get downloads
	for item in NetworkManager.get_queued_downloads():
		_add_download_item(item)
	
	for item in NetworkManager.get_active_downloads():
		_add_download_item(item)
	
	_update_status()

func _add_download_item(item: DownloadManager.DownloadItem):
	if _download_items.has(item.game.romm_id):
		return
	
	var item_scene = preload("res://components/download_item.tscn")
	var ui_item = item_scene.instantiate()
	ui_item.set_download_item(item)
	downloads_list.add_child(ui_item)
	_download_items[item.game.romm_id] = ui_item

func _on_download_started(game_id: int):
	_refresh_list()

func _on_download_progress(game_id: int, progress_percent: float):
	if _download_items.has(game_id):
		var item = _download_items[game_id]
		if is_instance_valid(item):
			item.download_item.progress = progress_percent / 100.0
			item._update_display()

func _on_download_completed(game_id: int, success: bool, file_path: String):
	if _download_items.has(game_id):
		var item = _download_items[game_id]
		if is_instance_valid(item):
			item.download_item.status = "completed" if success else "failed"
			item._update_display()
	_update_status()

func _on_clear_completed():
	# Remove completed/failed items
	var to_remove = []
	for game_id in _download_items.keys():
		var item_ui = _download_items[game_id]
		if is_instance_valid(item_ui) and item_ui.download_item:
			var status = item_ui.download_item.status
			if status == "completed" or status == "failed":
				to_remove.append(game_id)
				item_ui.queue_free()
	
	for game_id in to_remove:
		_download_items.erase(game_id)
	
	_update_status()

func _update_status():
	var queue_size = NetworkManager.get_download_queue_size()
	var active = NetworkManager.get_active_downloads().size()
	var queued = NetworkManager.get_queued_downloads().size()
	
	if active > 0:
		status_label.text = "Downloading: %d active, %d queued" % [active, queued]
	elif queued > 0:
		status_label.text = "Queued: %d downloads" % queued
	else:
		status_label.text = "No active downloads"
