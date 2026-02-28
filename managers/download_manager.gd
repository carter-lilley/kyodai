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
	var download_info: Dictionary = {}  # For file-based downloads: {http, callback, path, completed}
	var expected_file_size: int = 0  # Fallback if get_body_size() returns -1

# Unified queue
var _queue: Array[QueueItem] = []
var _active_items: Dictionary = {}  # id -> QueueItem
var _max_concurrent: int = 3  # Increased from 2 for better throughput

# Progress timer for downloads
var _progress_timers: Dictionary = {}  # item_id -> Timer

# Timeout tracking
var _download_start_times: Dictionary = {}  # item_id -> start_time_msec
var _last_progress_times: Dictionary = {}  # item_id -> last_progress_time_msec
var _last_downloaded_bytes: Dictionary = {}  # item_id -> bytes at last check
const DOWNLOAD_TIMEOUT_MS: int = 30 * 60 * 1000  # 30 minutes max
const STALL_TIMEOUT_MS: int = 120 * 1000  # 120 seconds with no progress = stall
const INITIAL_GRACE_PERIOD_MS: int = 30 * 1000  # 30 second grace period at start

## Queues a download with optional auto-extraction
## Returns the item ID or empty string if failed
func queue_download(url: String, destination: String, type: String = "file", name: String = "", auto_extract: bool = false, extract_dir: String = "", game: GameResource = null, callbacks: Dictionary = {}, romm_id: int = 0) -> String:
	# Generate unique ID
	var item_id = type + "_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000)
	
	# Check if already downloading this URL (in queue OR active)
	for item in _queue:
		if item.url == url:
			print("[DownloadManager] Already queued: " + url)
			return ""
	
	for active_id in _active_items:
		if _active_items[active_id].url == url:
			print("[DownloadManager] Already downloading: " + url)
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
	
	# Store expected file size for progress tracking
	if game:
		item.expected_file_size = game.get_active_file_size()
	
	# Ensure destination directory exists
	var dest_dir = destination.get_base_dir()
	var dir: DirAccess
	
	# Handle absolute vs relative paths
	if dest_dir.begins_with("user://") or dest_dir.begins_with("res://"):
		dir = DirAccess.open(dest_dir.get_base_dir())
		if dir and not dir.dir_exists(dest_dir.get_file()):
			var result = dir.make_dir_recursive(dest_dir.get_file())
			if result != OK:
				print("[DownloadManager] Failed to create directory: " + dest_dir)
				return ""
	else:
		# Absolute path (e.g., D:/Emulation/roms/switch)
		dir = DirAccess.open(dest_dir)
		if dir == null:
			# Directory doesn't exist, try to create it using OS
			var global_path = ProjectSettings.globalize_path(dest_dir) if dest_dir.begins_with("res://") else dest_dir
			var result = DirAccess.make_dir_recursive_absolute(global_path)
			if result != OK:
				print("[DownloadManager] Failed to create directory: " + global_path + " (error: " + str(result) + ")")
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
	
	# Track start time for timeout detection
	_download_start_times[item.id] = Time.get_ticks_msec()
	_last_progress_times[item.id] = Time.get_ticks_msec()
	_last_downloaded_bytes[item.id] = 0
	
	# Show notification with progress
	item.notification_id = NotificationManager.show_notification(
		"Downloading " + item.name + "...",
		Notification.Type.INFO,
		null,
		0.0,
		func() -> float:
			return item.progress,
		func(progress: float) -> String:
			if item.expected_file_size > 0:
				var mb_downloaded = int(item.expected_file_size * progress / (1024 * 1024))
				var mb_total = int(item.expected_file_size / (1024 * 1024))
				return "Downloading %s: %d/%d MB (%d%%)" % [item.name, mb_downloaded, mb_total, int(progress * 100)]
			return "Downloading " + item.name + ": %d%%" % int(progress * 100)
	)
	
	download_started.emit(item.id)
	print("[DownloadManager] Starting download: " + item.id + " - " + item.url)
	
	# Start looping sound while downloading
	if AudioManager:
		print("[DownloadManager] Starting audio loop for item: " + item.id + " with status: " + item.status)
		var audio_started = AudioManager.play_loop_while("loading_2", func(): 
			var still_active = item.status == "downloading"
			return still_active
		)
		print("[DownloadManager] Audio loop started: " + str(audio_started))
	else:
		print("[DownloadManager] AudioManager not available!")
	
	# Make HTTP request through NetworkManager
	# Always include User-Agent to prevent blocking (archive.org requires this)
	var headers = ["User-Agent: Kyodai-Launcher/1.0"]
	if item.type == "game":
		headers.append("Authorization: " + NetworkManager.get_auth_header())
	
	# Use file-based download for large files (games)
	# Note: HTTPRequest.download_file streams directly to disk
	if item.type == "game":
		print("[DownloadManager] Using file-based download for: " + item.name)
		print("[DownloadManager] Expected file size: " + str(item.expected_file_size) + " bytes (" + str(item.expected_file_size / (1024*1024)) + " MB)")
		item.download_info = NetworkManager.http_download_file(
			item.url,
			item.destination_path,
			headers,
			func(success: bool, status_code: int, error_msg: String):
				print("[DownloadManager] Callback fired for %s - success: %s, code: %d, error: %s" % [item.name, str(success), status_code, error_msg])
				_on_file_download_complete(item, success, error_msg),
			item.expected_file_size
		)
		
		if item.download_info.is_empty():
			item.status = "failed"
			item.error_message = "Failed to start download"
			_cleanup_item(item)
			_active_items.erase(item.id)
			download_completed.emit(item.id, false, item.error_message)
			queue_changed.emit()
			_process_queue()
			return
		
		item.http_request = item.download_info.get("http", null)
	else:
		item.http_request = NetworkManager.http_get(
			item.url,
			headers,
			func(success: bool, body: PackedByteArray, status_code: int, error_msg: String):
				_on_download_complete(item, success, body, error_msg)
		)
	
	if item.http_request == null:
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
	_progress_timers[item.id].wait_time = 1.0  # Check every second
	_progress_timers[item.id].autostart = true
	add_child(_progress_timers[item.id])
	
	_progress_timers[item.id].timeout.connect(func():
		_update_download_progress(item)
		_check_download_timeout(item.id)
	)

func _update_download_progress(item: QueueItem):
	if item.http_request == null and item.download_info.is_empty():
		return
	
	# For file-based downloads, check actual file on disk to avoid 32-bit overflow
	if item.type == "game" and not item.download_info.is_empty():
		var file_path = item.download_info.get("path", item.destination_path)
		
		# Check file size on disk (64-bit, no overflow)
		if FileAccess.file_exists(file_path):
			var file = FileAccess.open(file_path, FileAccess.READ)
			if file:
				var current_size = file.get_length()
				file.close()
				
				# Use expected_file_size from game data for accurate progress
				if item.expected_file_size > 0:
					item.progress = float(current_size) / float(item.expected_file_size)
					if item.progress > 0.99:
						item.progress = 0.99
				else:
					# No expected size, cap at 99%
					item.progress = 0.5  # Unknown progress
				
				# Log progress periodically (every 50MB change)
				var last_bytes = _last_downloaded_bytes.get(item.id, 0)
				if abs(current_size - last_bytes) > 50 * 1024 * 1024:
					var mb_downloaded = current_size / (1024 * 1024)
					if item.expected_file_size > 0:
						var mb_total = item.expected_file_size / (1024 * 1024)
						print("[DownloadManager] %s: %d/%d MB (%.1f%%)" % [item.name, mb_downloaded, mb_total, item.progress * 100])
					else:
						print("[DownloadManager] %s: %d MB downloaded" % [item.name, mb_downloaded])
					_last_downloaded_bytes[item.id] = current_size
				
				# Update stall time if making progress
				if current_size > 0 and current_size != last_bytes:
					_last_progress_times[item.id] = Time.get_ticks_msec()
		
		# Check if download completed via request_completed callback
		if item.download_info.get("completed", false):
			print("[DownloadManager] Download request completed for: " + item.name)
			_on_file_download_complete(item, true, "")
			return
		
		# Check if download had an error
		if item.download_info.has("error"):
			var error_msg = item.download_info.get("error", "Unknown error")
			print("[DownloadManager] Download failed for %s: %s" % [item.name, error_msg])
			_on_file_download_complete(item, false, error_msg)
			return
		
		download_progress.emit(item.id, item.progress)
	else:
		# For non-game downloads, use HTTPRequest progress
		if item.http_request and is_instance_valid(item.http_request):
			var body_size = item.http_request.get_body_size()
			var downloaded = item.http_request.get_downloaded_bytes()
			
			if body_size > 0:
				item.progress = float(downloaded) / float(body_size)
				download_progress.emit(item.id, item.progress)
			
			# Update stall time if making progress
			var last_bytes = _last_downloaded_bytes.get(item.id, -1)
			if downloaded > 0 and downloaded != last_bytes:
				_last_progress_times[item.id] = Time.get_ticks_msec()
				_last_downloaded_bytes[item.id] = downloaded

func _on_download_complete(item: QueueItem, success: bool, body: PackedByteArray, error_msg: String):
	# Stop progress timer and cleanup timeout tracking
	_cleanup_download_tracking(item.id)
	
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

func _on_file_download_complete(item: QueueItem, success: bool, error_msg: String):
	# Guard against double-calls
	if item.status != "downloading":
		return
	
	# Stop progress timer and cleanup timeout tracking
	_cleanup_download_tracking(item.id)
	
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
	
	print("[DownloadManager] File download complete: " + item.id + " -> " + item.destination_path)
	
	# Verify file exists and has content
	if not FileAccess.file_exists(item.destination_path):
		item.status = "failed"
		item.error_message = "Download file not found"
		NotificationManager.update_notification_text(item.notification_id, "Download failed: " + item.name)
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, "Download file not found")
		queue_changed.emit()
		_process_queue()
		return
	
	# Get final file size for logging
	var file = FileAccess.open(item.destination_path, FileAccess.READ)
	if file:
		var final_size = file.get_length()
		file.close()
		print("[DownloadManager] Final file size: " + str(final_size) + " bytes (" + str(final_size / (1024*1024)) + " MB)")
	
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

func _cleanup_download_tracking(item_id: String):
	# Stop progress timer
	if _progress_timers.has(item_id):
		_progress_timers[item_id].stop()
		_progress_timers[item_id].queue_free()
		_progress_timers.erase(item_id)
	
	# Clean up timeout tracking
	_download_start_times.erase(item_id)
	_last_progress_times.erase(item_id)
	_last_downloaded_bytes.erase(item_id)

func _check_download_timeout(item_id: String):
	if not _active_items.has(item_id):
		return
	
	var current_time = Time.get_ticks_msec()
	var start_time = _download_start_times.get(item_id, current_time)
	var last_progress = _last_progress_times.get(item_id, current_time)
	
	var item = _active_items[item_id]
	var elapsed_since_start = current_time - start_time
	
	# Check for overall timeout
	if elapsed_since_start > DOWNLOAD_TIMEOUT_MS:
		print("[DownloadManager] Download timed out (max duration): " + item_id)
		_fail_download(item_id, "Download timed out")
		return
	
	# Don't check for stall during initial grace period
	if elapsed_since_start < INITIAL_GRACE_PERIOD_MS:
		return
	
	# Check for stall (no progress for too long after grace period)
	if current_time - last_progress > STALL_TIMEOUT_MS:
		print("[DownloadManager] Download stalled (no progress for %d sec): " % [(current_time - last_progress) / 1000] + item_id)
		_fail_download(item_id, "Download stalled - no progress")
		return

func _fail_download(item_id: String, error_msg: String):
	if not _active_items.has(item_id):
		return
	
	var item = _active_items[item_id]
	
	# Cancel the HTTP request
	if item.http_request and is_instance_valid(item.http_request):
		item.http_request.cancel_request()
	
	item.http_request = null
	item.status = "failed"
	item.error_message = error_msg
	
	_cleanup_download_tracking(item_id)
	_cleanup_item(item)
	_active_items.erase(item_id)
	
	NotificationManager.update_notification_text(item.notification_id, "Download failed: " + item.name)
	download_completed.emit(item_id, false, error_msg)
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
	
	# Create extraction callable for MemoryManager
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
	
	# Queue extraction to MemoryManager
	MemoryManager.queue_extraction_task(extraction_callable, func(success: bool):
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
	
	# Create extraction callable for MemoryManager
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
	
	# Queue extraction to MemoryManager
	MemoryManager.queue_extraction_task(extraction_callable, func(success: bool):
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
