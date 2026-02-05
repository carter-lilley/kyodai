class_name DownloadItemUI
extends PanelContainer

@onready var title_label: Label = $MarginContainer/VBoxContainer/HBoxContainer/TitleLabel
@onready var platform_label: Label = $MarginContainer/VBoxContainer/HBoxContainer/PlatformLabel
@onready var progress_bar: ProgressBar = $MarginContainer/VBoxContainer/ProgressBar
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var cancel_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/CancelButton

var download_item: DownloadManager.DownloadItem

func _ready():
	cancel_button.pressed.connect(_on_cancel_pressed)
	_update_display()
	
	# Connect to download manager signals
	DownloadManager.download_progress.connect(_on_download_progress)
	DownloadManager.download_completed.connect(_on_download_completed)

func set_download_item(item: DownloadManager.DownloadItem):
	download_item = item
	_update_display()

func _update_display():
	if not download_item or not is_node_ready():
		return
	
	title_label.text = download_item.game.get_display_name()
	platform_label.text = download_item.game.platform if download_item.game.platform else "Unknown"
	
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

func _on_download_progress(game_id: int, bytes_received: int, total_bytes: int):
	if download_item and download_item.game.romm_id == game_id:
		if total_bytes > 0:
			progress_bar.value = (float(bytes_received) / float(total_bytes)) * 100
		_update_display()

func _on_download_completed(game_id: int, success: bool, message: String):
	if download_item and download_item.game.romm_id == game_id:
		_update_display()

func _on_cancel_pressed():
	if not download_item:
		return
	
	if download_item.status == "completed" or download_item.status == "failed":
		# Just remove from UI
		queue_free()
	else:
		# Cancel download
		DownloadManager.cancel_download(download_item.game.romm_id)
		queue_free()
