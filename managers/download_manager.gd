extends Manager

# DownloadManager - Unified download and extraction queue
# Handles all file downloads: games, emulators, cores, images, etc.
# Also handles archive extraction with progress notifications

signal download_started(item_id: String)
signal download_progress(item_id: String, progress: float)
signal download_completed(item_id: String, success: bool, message: String)
signal extraction_started(item_id: String)
signal extraction_progress(item_id: String, progress: float)
signal extraction_completed(item_id: String, success: bool, message: String)
signal queue_changed()

class QueueItem:
	var id: String
	var url: String
	var destination_path: String
	var type: String  # "game", "emulator", "cores", "image", etc.
	var name: String  # Display name for notifications
	var status: String = "queued"  # queued, downloading, extract_pending, extracting, completed, failed
	var progress: float = 0.0  # 0.0 - 1.0
	var auto_extract: bool = false
	var extract_dir: String = ""
	var http_request: HTTPRequest = null
	var notification_id: int = -1
	var error_message: String = ""
	var game_resource: GameResource = null  # Optional: for game downloads
	var callbacks: Dictionary = {}  # Optional custom callbacks
	var romm_id: int = 0  # The actual RomM ID being downloaded (could be a sibling)

# Unified queue
var _queue: Array[QueueItem] = []
var _active_items: Dictionary = {}  # id -> QueueItem
var _max_concurrent: int = 2

# Progress timer for downloads
var _progress_timers: Dictionary = {}  # item_id -> Timer

## Queues a download with optional auto-extraction
## Returns the item ID or empty string if failed
func queue_download(url: String, destination: String, type: String = "file", name: String = "", auto_extract: bool = false, extract_dir: String = "", game: GameResource = null, callbacks: Dictionary = {}, romm_id: int = 0) -> String:
	# Generate unique ID
	var item_id = type + "_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000)
	
	# Check if already downloading this URL
	for item in _queue:
		if item.url == url:
			print("[DownloadManager] Already queued: " + url)
			return ""
	
	if _active_items.has(item_id):
		print("[DownloadManager] Already active: " + item_id)
		return ""
	
	# Create item
	var item = QueueItem.new()
	item.id = item_id
	item.url = url
	item.destination_path = destination
	item.type = type
	item.name = name if name != "" else item_id
	item.auto_extract = auto_extract
	item.extract_dir = extract_dir if extract_dir != "" else destination.get_base_dir()
	item.game_resource = game
	item.callbacks = callbacks
	item.romm_id = romm_id if romm_id != 0 else (game.romm_id if game else 0)
	
	# Ensure destination directory exists
	var dir = DirAccess.open("user://")
	var dest_dir = destination.get_base_dir().trim_prefix("user://")
	if dir and not dir.dir_exists(dest_dir):
		var result = dir.make_dir_recursive(dest_dir)
		if result != OK:
			print("[DownloadManager] Failed to create directory: " + dest_dir)
			return ""
	
	_queue.append(item)
	print("[DownloadManager] Queued download: " + item_id + " (" + type + ") - " + url)
	
	queue_changed.emit()
	_process_queue()
	
	return item_id

## Queues an extraction task (for already-downloaded archives)
func queue_extraction(archive_path: String, extract_dir: String, type: String = "archive", name: String = "") -> String:
	var item_id = "extract_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000)
	
	# Check if already extracting this archive
	for item in _queue:
		if item.destination_path == archive_path and item.status == "extract_pending":
			print("[DownloadManager] Already queued for extraction: " + archive_path)
			return ""
	
	var item = QueueItem.new()
	item.id = item_id
	item.url = ""  # No URL, already have file
	item.destination_path = archive_path
	item.type = type
	item.name = name if name != "" else "Archive"
	item.status = "extract_pending"
	item.auto_extract = false  # Already an extraction task
	item.extract_dir = extract_dir
	
	_queue.append(item)
	print("[DownloadManager] Queued extraction: " + item_id + " - " + archive_path)
	
	queue_changed.emit()
	_process_queue()
	
	return item_id

## Cancels a queued or active download
func cancel(item_id: String) -> bool:
	# Cancel if in queue
	for i in range(_queue.size()):
		if _queue[i].id == item_id:
			var item = _queue[i]
			_cleanup_item(item)
			_queue.remove_at(i)
			queue_changed.emit()
			print("[DownloadManager] Cancelled queued: " + item_id)
			return true
	
	# Cancel if active
	if _active_items.has(item_id):
		var item = _active_items[item_id]
		if item.http_request:
			item.http_request.cancel_request()
		item.http_request = null
		_cleanup_item(item)
		_active_items.erase(item_id)
		queue_changed.emit()
		download_completed.emit(item_id, false, "Cancelled")
		print("[DownloadManager] Cancelled active: " + item_id)
		_process_queue()
		return true
	
	return false

## Gets the current progress of an item
func get_progress(item_id: String) -> float:
	if _active_items.has(item_id):
		return _active_items[item_id].progress
	for item in _queue:
		if item.id == item_id:
			return item.progress
	return 0.0

## Gets the status of an item
func get_status(item_id: String) -> String:
	if _active_items.has(item_id):
		return _active_items[item_id].status
	for item in _queue:
		if item.id == item_id:
			return item.status
	return "unknown"

## Checks if an item is currently downloading
func is_downloading(item_id: String) -> bool:
	if _active_items.has(item_id):
		return _active_items[item_id].status == "downloading"
	return false

## Checks if an item is in the queue
func is_queued(item_id: String) -> bool:
	for item in _queue:
		if item.id == item_id:
			return true
	return false

## Gets all queued items
func get_queued() -> Array[QueueItem]:
	var result: Array[QueueItem] = []
	result.append_array(_queue)
	return result

## Gets all active items
func get_active() -> Array[QueueItem]:
	var result: Array[QueueItem] = []
	result.append_array(_active_items.values())
	return result

## Checks if any item in the queue matches a predicate
func has_item(predicate: Callable) -> bool:
	for item in _queue:
		if predicate.call(item):
			return true
	for item in _active_items.values():
		if predicate.call(item):
			return true
	return false

## Gets an item by ID
func get_item(item_id: String) -> QueueItem:
	if _active_items.has(item_id):
		return _active_items[item_id]
	for item in _queue:
		if item.id == item_id:
			return item
	return null

# ==================== INTERNAL METHODS ====================

func _process_queue():
	while _active_items.size() < _max_concurrent and _queue.size() > 0:
		var item = _queue.pop_front()
		
		if item.status == "extract_pending":
			# This is an extraction-only task
			_start_extraction(item)
		else:
			# This is a download task
			_start_download(item)
		
		queue_changed.emit()

func _start_download(item: QueueItem):
	item.status = "downloading"
	item.progress = 0.0
	_active_items[item.id] = item
	
	# Show notification with progress
	item.notification_id = NotificationManager.show_notification(
		"Downloading " + item.name + "...",
		Notification.Type.INFO,
		null,
		0.0,
		func() -> float:
			return item.progress,
		func(progress: float) -> String:
			return "Downloading " + item.name + ": %d%%" % int(progress * 100)
	)
	
	download_started.emit(item.id)
	print("[DownloadManager] Starting download: " + item.id + " - " + item.url)
	
	# Make HTTP request through NetworkManager
	var headers = []
	if item.type == "game":
		headers = ["Authorization: " + NetworkManager.get_auth_header()]
	
	item.http_request = NetworkManager.http_get(
		item.url,
		headers,
		func(success: bool, body: PackedByteArray, status_code: int, error_msg: String):
			_on_download_complete(item, success, body, error_msg)
	)
	
	if item.http_request == null:
		# Failed to start
		item.status = "failed"
		item.error_message = "Failed to start download"
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	# Setup progress timer
	_progress_timers[item.id] = Timer.new()
	_progress_timers[item.id].wait_time = 0.5
	_progress_timers[item.id].autostart = true
	add_child(_progress_timers[item.id])
	
	_progress_timers[item.id].timeout.connect(func():
		if item.http_request and is_instance_valid(item.http_request):
			var body_size = item.http_request.get_body_size()
			var downloaded = item.http_request.get_downloaded_bytes()
			if body_size > 0:
				item.progress = float(downloaded) / float(body_size)
				download_progress.emit(item.id, item.progress)
	)

func _on_download_complete(item: QueueItem, success: bool, body: PackedByteArray, error_msg: String):
	# Stop progress timer
	if _progress_timers.has(item.id):
		_progress_timers[item.id].stop()
		_progress_timers[item.id].queue_free()
		_progress_timers.erase(item.id)
	
	item.http_request = null
	
	if not success:
		item.status = "failed"
		item.error_message = error_msg
		NotificationManager.update_notification_text(item.notification_id, "Download failed: " + item.name)
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, error_msg)
		queue_changed.emit()
		_process_queue()
		return
	
	# Write file
	var file = FileAccess.open(item.destination_path, FileAccess.WRITE)
	if not file:
		item.status = "failed"
		item.error_message = "Failed to write file"
		NotificationManager.update_notification_text(item.notification_id, "Failed to save: " + item.name)
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, "Failed to write file")
		queue_changed.emit()
		_process_queue()
		return
	
	file.store_buffer(body)
	file.close()
	
	print("[DownloadManager] Download complete: " + item.id + " -> " + item.destination_path)
	
	# Update game resource if applicable
	if item.game_resource:
		var downloaded_id = item.romm_id if item.romm_id != 0 else item.game_resource.romm_id
		item.game_resource.mark_sibling_downloaded(downloaded_id)
		item.game_resource.file_path = item.destination_path
		DataManager.update_game(item.game_resource)
	
	# Call custom callback if provided
	if item.callbacks.has("on_complete"):
		item.callbacks.on_complete.call(true, item.destination_path)
	
	# Auto-extract if requested
	if item.auto_extract:
		item.status = "extract_pending"
		item.progress = 0.0
		_start_extraction(item)
	else:
		item.status = "completed"
		item.progress = 1.0
		_active_items.erase(item.id)
		download_completed.emit(item.id, true, item.destination_path)
		queue_changed.emit()
		_process_queue()

func _start_extraction(item: QueueItem):
	item.status = "extracting"
	if not _active_items.has(item.id):
		_active_items[item.id] = item
	
	# Show extraction notification with pulsing progress (indeterminate)
	# Dismiss old notification first, then create new one
	if item.notification_id != -1:
		NotificationManager.dismiss_notification(item.notification_id)
	
	item.notification_id = NotificationManager.show_notification(
		"Extracting " + item.name + "...",
		Notification.Type.INFO,
		null,
		0.0,
		Callable(),  # No progress callable - using pulsing
		Callable(),  # No text formatter
		true  # pulsing = true
	)
	
	extraction_started.emit(item.id)
	print("[DownloadManager] Starting extraction: " + item.id + " - " + item.destination_path)
	
	# Determine format and extract
	var archive_path = item.destination_path
	var extract_dir = item.extract_dir
	
	if archive_path.ends_with(".zip"):
		_extract_zip(item, archive_path, extract_dir)
	elif archive_path.ends_with(".7z"):
		_extract_7z(item, archive_path, extract_dir)
	else:
		item.status = "failed"
		item.error_message = "Unknown archive format"
		NotificationManager.update_notification_text(item.notification_id, "Unknown format: " + item.name)
		_cleanup_item(item)
		_active_items.erase(item.id)
		extraction_completed.emit(item.id, false, "Unknown archive format")
		queue_changed.emit()
		_process_queue()

func _extract_zip(item: QueueItem, archive_path: String, extract_dir: String):
	# Show extraction notification immediately
	NotificationManager.update_notification_text(item.notification_id, "Extracting " + item.name + "...")
	
	# Create extraction callable for ThreadManager
	var extraction_callable = func() -> bool:
		var reader = ZIPReader.new()
		var err = reader.open(archive_path)
		
		if err != OK:
			print("[DownloadManager] Failed to open ZIP: " + str(err))
			return false
		
		var files = reader.get_files()
		
		for file in files:
			var dest_path = extract_dir + "/" + file
			
			# Create directory if needed
			if file.ends_with("/"):
				var dir = DirAccess.open("user://")
				if dir:
					dir.make_dir_recursive(dest_path.trim_prefix("user://"))
				continue
			
			# Extract file
			var buffer = reader.read_file(file)
			if buffer.size() > 0:
				var file_dir = dest_path.get_base_dir()
				var dir = DirAccess.open("user://")
				if dir:
					dir.make_dir_recursive(file_dir.trim_prefix("user://"))
				
				var f = FileAccess.open(dest_path, FileAccess.WRITE)
				if f:
					f.store_buffer(buffer)
					f.close()
		
		reader.close()
		
		# Clean up archive
		var dir = DirAccess.open("user://")
		if dir:
			dir.remove(archive_path.trim_prefix("user://"))
		
		return true
	
	# Queue extraction to ThreadManager
	ThreadManager.queue_extraction_task(extraction_callable, func(success: bool):
		if success:
			item.status = "completed"
			item.progress = 1.0
			NotificationManager.dismiss_notification(item.notification_id)
			_cleanup_item(item)
			_active_items.erase(item.id)
			
			print("[DownloadManager] Extraction complete: " + item.id)
			extraction_completed.emit(item.id, true, extract_dir)
			queue_changed.emit()
			_process_queue()
		else:
			item.status = "failed"
			item.error_message = "Extraction failed"
			NotificationManager.dismiss_notification(item.notification_id)
			_cleanup_item(item)
			_active_items.erase(item.id)
			extraction_completed.emit(item.id, false, item.error_message)
			queue_changed.emit()
			_process_queue()
	)

func _extract_7z(item: QueueItem, archive_path: String, extract_dir: String):
	var binary_path = _get_7z_binary_path()
	
	if not FileAccess.file_exists(binary_path):
		item.status = "failed"
		item.error_message = "7z binary not found"
		NotificationManager.dismiss_notification(item.notification_id)
		_cleanup_item(item)
		_active_items.erase(item.id)
		extraction_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	var abs_archive_path = ProjectSettings.globalize_path(archive_path)
	var abs_extract_dir = ProjectSettings.globalize_path(extract_dir)
	
	# Create extraction callable for ThreadManager
	var extraction_callable = func() -> bool:
		# Start extraction process (blocking in thread)
		var args = ["x", abs_archive_path, "-o" + abs_extract_dir, "-y"]
		var output = []
		var exit_code = OS.execute(binary_path, args, output, true)
		
		if exit_code != 0:
			print("[DownloadManager] 7z extraction failed with exit code: " + str(exit_code))
			return false
		
		# Clean up archive
		var dir = DirAccess.open("user://")
		if dir:
			dir.remove(archive_path.trim_prefix("user://"))
		
		return true
	
	# Queue extraction to ThreadManager
	ThreadManager.queue_extraction_task(extraction_callable, func(success: bool):
		if success:
			item.status = "completed"
			item.progress = 1.0
			NotificationManager.dismiss_notification(item.notification_id)
			_cleanup_item(item)
			_active_items.erase(item.id)
			
			print("[DownloadManager] 7z extraction complete: " + item.id)
			extraction_completed.emit(item.id, true, extract_dir)
			queue_changed.emit()
			_process_queue()
		else:
			item.status = "failed"
			item.error_message = "Extraction failed"
			NotificationManager.dismiss_notification(item.notification_id)
			_cleanup_item(item)
			_active_items.erase(item.id)
			extraction_completed.emit(item.id, false, item.error_message)
			queue_changed.emit()
			_process_queue()
	)

func _get_7z_binary_path() -> String:
	var platform_name = ""
	match PlatformManager.current_platform:
		PlatformManager.Platform.WINDOWS:
			platform_name = "windows"
		PlatformManager.Platform.LINUX:
			platform_name = "linux"
		_:
			return ""
	
	var binary_name = "7za.exe" if PlatformManager.is_windows() else "7z"
	return ProjectSettings.globalize_path("res://bin/7z/" + platform_name + "/" + binary_name)

func _cleanup_item(item: QueueItem):
	if item.notification_id != -1:
		# Let notification auto-dismiss on completion/failure
		pass

# ==================== IMAGE DOWNLOADS (NO QUEUE) ====================

# Track active image downloads for deduplication
var _active_image_downloads: Dictionary = {}  # url -> {callbacks: [], completed: bool, success: bool}

## Downloads an image immediately (no queue) with caching and deduplication
## callback(success: bool)
func download_image(url: String, cache_path: String, callback: Callable) -> bool:
	# Check if already cached
	if FileAccess.file_exists(cache_path):
		callback.call(true)
		return true
	
	# Check if already downloading (deduplication)
	if _active_image_downloads.has(url):
		var state = _active_image_downloads[url]
		if state.completed:
			callback.call(state.success)
		else:
			state.callbacks.append(callback)
		return true
	
	# Start new download
	_active_image_downloads[url] = {
		"callbacks": [callback],
		"completed": false,
		"success": false
	}
	
	# Make HTTP request
	NetworkManager.http_get(url, [], func(success: bool, body: PackedByteArray, status_code: int, error_msg: String):
		if not success or body.is_empty():
			# Download failed
			var state = _active_image_downloads[url]
			state.completed = true
			state.success = false
			for cb in state.callbacks:
				cb.call(false)
			# Clean up after delay
			await get_tree().create_timer(5.0).timeout
			_active_image_downloads.erase(url)
			return
		
		# Save to cache
		var file = FileAccess.open(cache_path, FileAccess.WRITE)
		if file:
			file.store_buffer(body)
			file.close()
		
		# Notify callbacks
		var state = _active_image_downloads[url]
		state.completed = true
		state.success = true
		for cb in state.callbacks:
			cb.call(true)
		
		# Clean up after delay
		await get_tree().create_timer(5.0).timeout
		_active_image_downloads.erase(url)
	)
	
	return true
