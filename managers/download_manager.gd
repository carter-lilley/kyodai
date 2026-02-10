extends Manager

signal download_started(game_id: int)
signal download_progress(game_id: int, bytes_received: int, total_bytes: int)
signal download_completed(game_id: int, success: bool, message: String)
signal download_queue_changed()

# Emulator download signals
signal emulator_download_started(emulator_id: String)
signal emulator_download_progress(emulator_id: String, progress: float)
signal emulator_download_completed(emulator_id: String, success: bool, message: String)

class DownloadItem:
	var game: GameResource
	var status: String = "queued"  # queued, downloading, completed, failed
	var progress: float = 0.0
	var error_message: String = ""
	var http_request: HTTPRequest = null

class EmulatorDownloadItem:
	var emulator_id: String
	var emulator_name: String
	var download_url: String
	var destination_path: String
	var status: String = "queued"  # queued, downloading, completed, failed
	var progress: float = 0.0
	var error_message: String = ""
	var http_request: HTTPRequest = null
	var notification_id: int = -1

var _download_queue: Array[DownloadItem] = []
var _active_downloads: Dictionary = {}
var _max_concurrent: int = 3

# Emulator downloads
var _emulator_download_queue: Array[EmulatorDownloadItem] = []
var _active_emulator_downloads: Dictionary = {}  # emulator_id -> EmulatorDownloadItem
var _completed_emulator_downloads: Array[String] = []  # Track downloaded emulators

func queue_download(game: GameResource) -> bool:
	if game.file_name == "":
		download_completed.emit(game.romm_id, false, "Game has no file")
		return false
	
	# Check if already in queue or downloading
	for item in _download_queue:
		if item.game.romm_id == game.romm_id:
			return false
	
	if _active_downloads.has(game.romm_id):
		return false
	
	var item = DownloadItem.new()
	item.game = game
	_download_queue.append(item)
	download_queue_changed.emit()
	
	_process_queue()
	return true

func cancel_download(game_id: int) -> bool:
	# Cancel if in queue
	for i in range(_download_queue.size()):
		if _download_queue[i].game.romm_id == game_id:
			_download_queue.remove_at(i)
			download_queue_changed.emit()
			return true
	
	# Cancel if active
	if _active_downloads.has(game_id):
		var item = _active_downloads[game_id]
		if item.http_request:
			item.http_request.cancel_request()
			item.http_request.queue_free()
		_active_downloads.erase(game_id)
		download_completed.emit(game_id, false, "Download cancelled")
		_process_queue()
		return true
	
	return false

func _process_queue():
	while _active_downloads.size() < _max_concurrent and _download_queue.size() > 0:
		var item = _download_queue.pop_front()
		_start_download(item)
		download_queue_changed.emit()

func _start_download(item: DownloadItem):
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		item.status = "failed"
		item.error_message = "Games folder not set"
		download_completed.emit(item.game.romm_id, false, item.error_message)
		_process_queue()
		return
	
	# Build destination path
	var platform_folder = item.game.platform_slug
	var destination_folder = root_folder.value + "/" + platform_folder
	var destination_path = destination_folder + "/" + item.game.file_name
	
	# Ensure folder exists
	var dir = DirAccess.open(root_folder.value)
	if dir and not dir.dir_exists(platform_folder):
		dir.make_dir(platform_folder)
	
	item.status = "downloading"
	item.game.file_path = destination_path
	_active_downloads[item.game.romm_id] = item
	
	download_started.emit(item.game.romm_id)
	
	# Start download via NetworkManager
	item.http_request = NetworkManager.download_rom(
		item.game.romm_id,
		item.game.file_name,
		destination_path,
		func(bytes_received, total_bytes):
			if total_bytes > 0:
				item.progress = float(bytes_received) / float(total_bytes)
				download_progress.emit(item.game.romm_id, bytes_received, total_bytes),
		func(success, message):
			_active_downloads.erase(item.game.romm_id)
			
			if success:
				item.status = "completed"
				item.game.has_local_copy = true
				item.game.file_path = destination_path
				DataManager.update_game(item.game)
			else:
				item.status = "failed"
				item.error_message = message
			
			download_completed.emit(item.game.romm_id, success, message)
			_process_queue()
	)

func get_queued_downloads() -> Array[DownloadItem]:
	var result: Array[DownloadItem] = []
	result.append_array(_download_queue)
	return result

func get_active_downloads() -> Array[DownloadItem]:
	var result: Array[DownloadItem] = []
	result.append_array(_active_downloads.values())
	return result

func is_downloading(game_id: int) -> bool:
	return _active_downloads.has(game_id)

func is_queued(game_id: int) -> bool:
	for item in _download_queue:
		if item.game.romm_id == game_id:
			return true
	return false

# ==================== EMULATOR DOWNLOADS ====================

func queue_emulator_download(emulator_id: String, emulator_name: String, download_url: String, destination_path: String) -> bool:
	# Check if already downloaded
	if emulator_id in _completed_emulator_downloads:
		print("[DownloadManager] Emulator already downloaded: " + emulator_id)
		return false
	
	# Check if already in queue or downloading
	for item in _emulator_download_queue:
		if item.emulator_id == emulator_id:
			return false
	
	if _active_emulator_downloads.has(emulator_id):
		return false
	
	var item = EmulatorDownloadItem.new()
	item.emulator_id = emulator_id
	item.emulator_name = emulator_name
	item.download_url = download_url
	item.destination_path = destination_path
	
	_emulator_download_queue.append(item)
	
	# Show notification with progress
	item.notification_id = NotificationManager.show_notification(
		"Downloading " + emulator_name + "...",
		Notification.Type.INFO,
		null,
		0.0,  # No timeout
		func() -> float:
			return item.progress,
		func(progress: float) -> String:
			return "Downloading " + emulator_name + ": %d%%" % int(progress * 100)
	)
	
	_process_emulator_queue()
	return true

func _process_emulator_queue():
	while _active_emulator_downloads.size() < 1 and _emulator_download_queue.size() > 0:  # Only 1 concurrent emulator download
		var item = _emulator_download_queue.pop_front()
		_start_emulator_download(item)

func _start_emulator_download(item: EmulatorDownloadItem):
	# Ensure destination folder exists
	var dir_path = item.destination_path.get_base_dir()
	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists(dir_path.trim_prefix("user://")):
		var make_dir_result = dir.make_dir_recursive(dir_path.trim_prefix("user://"))
		if make_dir_result != OK:
			item.status = "failed"
			item.error_message = "Failed to create directory"
			_emulator_download_completed(item, false, "Failed to create directory")
			return
	
	item.status = "downloading"
	_active_emulator_downloads[item.emulator_id] = item
	
	emulator_download_started.emit(item.emulator_id)
	
	# Start download via NetworkManager
	item.http_request = NetworkManager.download_file(
		item.download_url,
		item.destination_path,
		func(bytes_received: int, total_bytes: int):
			if total_bytes > 0:
				item.progress = float(bytes_received) / float(total_bytes)
				emulator_download_progress.emit(item.emulator_id, item.progress),
		func(success: bool, message: String):
			_emulator_download_completed(item, success, message)
	)

func _emulator_download_completed(item: EmulatorDownloadItem, success: bool, message: String):
	_active_emulator_downloads.erase(item.emulator_id)
	
	if success:
		item.status = "completed"
		item.progress = 1.0  # Set to 100% so notification auto-dismisses
		_completed_emulator_downloads.append(item.emulator_id)
		print("[DownloadManager] Emulator download completed: " + item.emulator_id)
		
		# Start extraction automatically
		print("[DownloadManager] Starting extraction for: " + item.emulator_id)
		LaunchManager.extract_emulator(item.emulator_id)
	else:
		item.status = "failed"
		item.error_message = message
		print("[DownloadManager] Emulator download failed: " + item.emulator_id + " - " + message)
	
	emulator_download_completed.emit(item.emulator_id, success, message)
	_process_emulator_queue()

func is_emulator_downloading(emulator_id: String) -> bool:
	return _active_emulator_downloads.has(emulator_id)

func is_emulator_queued(emulator_id: String) -> bool:
	for item in _emulator_download_queue:
		if item.emulator_id == emulator_id:
			return true
	return false

func has_emulator_been_downloaded(emulator_id: String) -> bool:
	return emulator_id in _completed_emulator_downloads
