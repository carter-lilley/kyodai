extends Manager

signal download_started(game_id: int)
signal download_progress(game_id: int, bytes_received: int, total_bytes: int)
signal download_completed(game_id: int, success: bool, message: String)
signal download_queue_changed()

class DownloadItem:
	var game: GameResource
	var status: String = "queued"  # queued, downloading, completed, failed
	var progress: float = 0.0
	var error_message: String = ""
	var http_request: HTTPRequest = null

var _download_queue: Array[DownloadItem] = []
var _active_downloads: Dictionary = {}
var _max_concurrent: int = 3

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
