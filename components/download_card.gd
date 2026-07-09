class_name DownloadCard
extends PanelContainer

@onready var title_label: M3Label = $MarginContainer/VBoxContainer/HBoxContainer/TitleLabel
@onready var platform_label: M3Label = $MarginContainer/VBoxContainer/HBoxContainer/PlatformLabel
@onready var progress_bar: M3Progress = $MarginContainer/VBoxContainer/ProgressBar
@onready var status_label: M3Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var cancel_button: M3Button = $MarginContainer/VBoxContainer/HBoxContainer/CancelButton

var download_item = null  # Will be set to SystemManager.download.QueueItem

func _ready():
	cancel_button.pressed.connect(_on_cancel_pressed)
	_update_display()
	
	# Connect to download manager signals
	SystemManager.download.download_progress.connect(_on_download_progress)
	SystemManager.download.download_completed.connect(_on_download_completed)
	SystemManager.download.extraction_progress.connect(_on_extraction_progress)
	SystemManager.download.extraction_completed.connect(_on_extraction_completed)

func set_download_item(item):
	download_item = item
	_update_display()

func _update_display():
	if not download_item or not is_node_ready():
		return
	
	# Use game resource for display info if available
	if download_item.game_resource:
		title_label.text = download_item.game_resource.get_display_name()
		platform_label.text = download_item.game_resource.platform if download_item.game_resource.platform else "Unknown"
	else:
		title_label.text = download_item.name
		platform_label.text = download_item.type.capitalize()
	
	match download_item.status:
		"queued":
			status_label.text = "Queued"
			status_label.modulate = Color.GRAY
			progress_bar.value = 0
			cancel_button.text = "Cancel"
		"downloading":
			status_label.text = "Downloading..."
			status_label.modulate = Color.YELLOW
			progress_bar.value = download_item.progress * 100
			cancel_button.text = "Cancel"
		"extract_pending", "extracting":
			if download_item.total_count > 0:
				status_label.text = "Extracting... (" + str(download_item.extracted_count) + "/" + str(download_item.total_count) + " files)"
			elif download_item.extracted_count > 0:
				status_label.text = "Extracting... (" + str(download_item.extracted_count) + " files)"
			else:
				status_label.text = "Extracting..."
			status_label.modulate = Color.ORANGE
			progress_bar.value = download_item.progress * 100
			cancel_button.text = "Cancel"
		"completed":
			status_label.text = "Completed"
			status_label.modulate = Color.GREEN
			progress_bar.value = 100
			cancel_button.text = "Remove"
		"failed":
			status_label.text = "Failed: " + download_item.error_message
			status_label.modulate = Color.RED
			progress_bar.value = 0
			cancel_button.text = "Remove"

func _on_download_progress(item_id: String, progress: float):
	if download_item and download_item.id == item_id:
		progress_bar.value = progress * 100
		_update_display()

func _on_download_completed(_item_id: String, _success: bool, _message: String):
	if download_item and download_item.id == _item_id:
		_update_display()

func _on_extraction_progress(item_id: String, progress: float):
	if download_item and download_item.id == item_id:
		progress_bar.value = progress * 100
		_update_display()

func _on_extraction_completed(_item_id: String, _success: bool, _message: String):
	if download_item and download_item.id == _item_id:
		_update_display()

func _on_cancel_pressed():
	if not download_item:
		return
	
	if download_item.status == "completed" or download_item.status == "failed":
		# Just remove from UI
		queue_free()
	else:
		# Cancel download
		SystemManager.download.cancel(download_item.id)
		queue_free()
