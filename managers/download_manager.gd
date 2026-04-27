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
	var delete_after_extract: bool = false  # Whether to delete archive after extraction
	var suppress_notification: bool = false  # If true, don't show per-item notifications

# Unified queue
var _queue: Array[QueueItem] = []
var _active_items: Dictionary = {}  # id -> QueueItem
var _max_concurrent: int = 5  # Concurrent downloads for better throughput on mobile

# Progress timer for downloads
var _progress_timers: Dictionary = {}  # item_id -> Timer

# Timeout tracking
var _download_start_times: Dictionary = {}  # item_id -> start_time_msec
var _last_progress_times: Dictionary = {}  # item_id -> last_progress_time_msec
var _last_downloaded_bytes: Dictionary = {}  # item_id -> bytes at last check
const DOWNLOAD_TIMEOUT_MS: int = 30 * 60 * 1000  # 30 minutes max
const STALL_TIMEOUT_MS: int = 120 * 1000  # 120 seconds with no progress = stall
const INITIAL_GRACE_PERIOD_MS: int = 30 * 1000  # 30 second grace period at start

# Chunked download constants
const CHUNKED_DOWNLOAD_THRESHOLD: int = 20 * 1024 * 1024  # 20MB minimum for chunking
const MIN_CHUNK_SIZE: int = 10 * 1024 * 1024  # 10MB minimum chunk size
const OVER_SUBSCRIPTION_MULTIPLIER_SMALL: float = 1.0  # 1x for files < 100MB
const OVER_SUBSCRIPTION_MULTIPLIER_MEDIUM: float = 2.0  # 2x for files 100MB-1GB
const OVER_SUBSCRIPTION_MULTIPLIER_LARGE: float = 3.0  # 3x for files 1GB-5GB
const OVER_SUBSCRIPTION_MULTIPLIER_XL: float = 4.0  # 4x for files > 5GB

var max_concurrent_chunks: int = MemoryManager.get_download_thread_count()  # Always match thread count

# Chunk retry settings
const MAX_CHUNK_RETRIES: int = 3
const CHUNK_RETRY_DELAY_SEC: float = 1.5  # 1.5 seconds between retries

# Polling interval for HTTPClient (2 seconds between polls when no data)
const POLLING_INTERVAL_MS: int = 100
const POLLING_INTERVAL_US: int = 2000000

## Calculates optimal chunk size and count using over-subscription strategy
## Files < 100MB: 1x over-subscription (just fill threads)
## Files 100MB-1GB: 2x over-subscription (twice as many chunks as threads)
## Files 1GB-5GB: 3x over-subscription
## Files > 5GB: 4x over-subscription (capped)
## Minimum chunk size: 10MB to avoid overhead
func _calculate_chunk_strategy(file_size: int) -> Dictionary:
	var thread_count = MemoryManager.get_download_thread_count()
	
	# Determine over-subscription multiplier based on file size
	var multiplier: float
	if file_size < 100 * 1024 * 1024:  # < 100MB
		multiplier = OVER_SUBSCRIPTION_MULTIPLIER_SMALL
	elif file_size < 1024 * 1024 * 1024:  # < 1GB
		multiplier = OVER_SUBSCRIPTION_MULTIPLIER_MEDIUM
	elif file_size < 5 * 1024 * 1024 * 1024:  # < 5GB
		multiplier = OVER_SUBSCRIPTION_MULTIPLIER_LARGE
	else:  # >= 5GB
		multiplier = OVER_SUBSCRIPTION_MULTIPLIER_XL
	
	# Calculate target number of chunks with over-subscription
	var target_chunks = max(thread_count, int(multiplier * thread_count))
	
	# Calculate chunk size, ensuring minimum chunk size
	var chunk_size = max(MIN_CHUNK_SIZE, file_size / target_chunks)
	
	# Recalculate actual number of chunks based on chunk size
	var num_chunks = ceili(float(file_size) / float(chunk_size))
	
	print("[DownloadManager] Chunk strategy for %d bytes: %d chunks x %d bytes (multiplier=%.1f, threads=%d)" % [
		file_size, num_chunks, chunk_size, multiplier, thread_count
	])
	
	return {
		"chunk_size": chunk_size,
		"num_chunks": num_chunks,
		"thread_count": thread_count
	}

# Chunked download tracking
var _chunked_downloads: Dictionary = {}  # item_id -> ChunkedDownloadInfo
class ChunkedDownloadInfo:
	var item: QueueItem
	var chunks: Array[ChunkInfo] = []
	var chunks_completed: int = 0
	var total_chunks: int = 0
	var temp_dir: String = ""
	var final_path: String = ""
	var use_chunking: bool = false
	var active_downloads: int = 0
	var download_callback: Callable
	var progress_timer: Timer = null  # Timer for polling chunk progress
	var last_progress_update: float = 0.0  # Last progress value to reduce emissions
	
class ChunkInfo:
	var index: int
	var start_byte: int
	var end_byte: int
	var temp_path: String
	var completed: bool = false
	var failed: bool = false
	var in_progress: bool = false
	var retry_count: int = 0  # Track retry attempts
	var temp_bytes_downloaded: int = 0  # Track bytes during download for real-time progress

# Foreground service tracking for Android
var _foreground_service_active: bool = false
var _active_download_count: int = 0

# Connection pool for chunked downloads - per-thread persistent connections
# Reduces TLS handshakes by reusing connections across chunks
var _download_connection_pools: Dictionary = {}  # item_id -> Array[HTTPClient] (one per thread)
var _connection_pool_mutex: Mutex = Mutex.new()

# Track per-thread chunk completion times for debugging connection reuse
var _thread_chunk_finish_times: Dictionary = {}  # "item_id_thread_index" -> finish_time_msec

## Starts the Android foreground service to prevent app kill during downloads
func _start_foreground_service(game_name: String = "Game"):
	if not PlatformManager.is_android():
		return
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_warning("[DownloadManager] PackageChecker plugin not available for foreground service")
		return
	
	# Note: has_method() is unreliable with Android plugins, just call directly
	if _active_download_count == 0:
		print("[DownloadManager] Starting foreground service for download: " + game_name)
		plugin.startDownloadForegroundService(game_name)
		_foreground_service_active = true
	
	_active_download_count += 1
	print("[DownloadManager] Active downloads: " + str(_active_download_count))

## Updates the foreground service notification with progress
func _update_foreground_service(game_name: String, progress: int):
	if not PlatformManager.is_android() or not _foreground_service_active:
		return
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		return
	
	# Note: has_method() is unreliable with Android plugins, just call directly
	plugin.updateDownloadForegroundService(game_name, progress)

## Stops the Android foreground service when downloads complete
func _stop_foreground_service():
	if not PlatformManager.is_android():
		return
	
	_active_download_count = max(0, _active_download_count - 1)
	
	if _active_download_count == 0 and _foreground_service_active:
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin != null:
			# Note: has_method() is unreliable with Android plugins, just call directly
			print("[DownloadManager] Stopping foreground service")
			plugin.stopDownloadForegroundService()
			_foreground_service_active = false
		
		# Restore normal CPU mode on Android
		if PlatformManager.is_android():
			OS.set_low_processor_usage_mode(false)
			print("[DownloadManager] Disabled low processor mode")

## Queues a download with optional auto-extraction
## delete_after_extract: If true, deletes the archive after successful extraction (default: true for emulator_core type)
## Returns the item ID or empty string if failed
func queue_download(url: String, destination: String, type: String = "file", name: String = "", auto_extract: bool = false, extract_dir: String = "", game: GameResource = null, callbacks: Dictionary = {}, romm_id: int = 0, delete_after_extract: bool = true, suppress_notification: bool = false) -> String:
	# Generate unique ID
	var item_id = type + "_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000)
	
	# Check if already downloading this URL (in queue OR active)
	for item in _queue:
		if item.url == url:
			return ""
	
	for active_id in _active_items:
		if _active_items[active_id].url == url:
			return ""
	
	if _active_items.has(item_id):
		return ""
	
	# Create item
	var item = QueueItem.new()
	item.id = item_id
	item.url = url
	item.destination_path = destination
	item.type = type
	item.name = name if name != "" else item_id
	item.auto_extract = auto_extract
	item.game_resource = game
	item.callbacks = callbacks
	item.romm_id = romm_id if romm_id != 0 else (game.romm_id if game else 0)
	item.delete_after_extract = delete_after_extract
	item.suppress_notification = suppress_notification
	
	# Store expected file size for progress tracking
	if game:
		item.expected_file_size = game.get_active_file_size()
	
	# Set extract_dir and ensure destination directory exists
	item.extract_dir = extract_dir if extract_dir != "" else destination.get_base_dir()
	var dest_dir = destination.get_base_dir()
	
	if not FileSystemManager.make_dir_recursive(dest_dir):
		push_error("[DownloadManager] Failed to create directory: " + dest_dir)
		return ""
	
	_queue.append(item)
	
	queue_changed.emit()
	_process_queue()
	
	return item_id

## Queues an extraction task (for already-downloaded archives)
## delete_after_extract: If true, deletes the archive after successful extraction (default: true)
## suppress_notification: If true, skips showing extraction notifications (for batch operations)
func queue_extraction(archive_path: String, extract_dir: String, type: String = "archive", name: String = "", delete_after_extract: bool = true, suppress_notification: bool = false) -> String:
	var item_id = "extract_" + str(Time.get_ticks_msec()) + "_" + str(randi() % 1000)
	
	# Check if already extracting this archive
	for item in _queue:
		if item.destination_path == archive_path and item.status == "extract_pending":
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
	item.delete_after_extract = delete_after_extract
	item.suppress_notification = suppress_notification
	
	_queue.append(item)
	
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
	
	# Start foreground service on Android to prevent app kill during large downloads
	_start_foreground_service(item.name)
	
	# Reduce CPU usage on Android to prevent overheating during downloads
	if PlatformManager.is_android():
		OS.set_low_processor_usage_mode(true)
		print("[DownloadManager] Enabled low processor mode for download")
	
	# Track start time for timeout detection
	_download_start_times[item.id] = Time.get_ticks_msec()
	_last_progress_times[item.id] = Time.get_ticks_msec()
	_last_downloaded_bytes[item.id] = 0
	
	# Show notification with progress (unless suppressed for batch downloads)
	if not item.suppress_notification:
		item.notification_id = NotificationManager.show_notification(
			item.name + "...",
			Notification.Type.INFO,
			null,
			0.0,
			func() -> float:
				return item.progress,
			func(progress: float) -> String:
				if item.expected_file_size > 0:
					var mb_downloaded = int(item.expected_file_size * progress / (1024 * 1024))
					var mb_total = int(item.expected_file_size / (1024 * 1024))
					return "%s: %d/%d MB (%d%%)" % [item.name, mb_downloaded, mb_total, int(progress * 100)]
				return item.name + ": %d%%" % int(progress * 100)
		)
	
	download_started.emit(item.id)
	
	# Start looping sound while downloading
	if AudioManager:
		AudioManager.play_loop_while("loading_2", func(): 
			var still_active = item.status == "downloading"
			return still_active
		)
	
	# Make HTTP request through NetworkManager
	# Always include User-Agent to prevent blocking (archive.org requires this)
	var headers = ["User-Agent: Kyodai-Launcher/1.0"]
	if item.type == "game":
		headers.append("Authorization: " + NetworkManager.get_auth_header())
	
	# Check if this is a large file that should use chunked downloading
	var is_large_file = item.type == "game" or item.type == "emulator" or item.type == "emulator_core"
	var should_use_chunking = is_large_file and item.expected_file_size > CHUNKED_DOWNLOAD_THRESHOLD
	
	if should_use_chunking:
		print("[DownloadManager] Checking Range support for chunked download: " + item.name + " (size=" + str(item.expected_file_size) + ")")
		_check_range_and_start_chunked(item, headers)
		return
	
	# All downloads now stream directly to disk via HTTPRequest.download_file
	# This avoids memory issues with large files (games, emulators, cores)
	print("[DownloadManager] Using file-based download for: " + item.name + " (type=" + item.type + ")")
	item.download_info = NetworkManager.http_download_file(
		item.url,
		item.destination_path,
		headers,
		func(success: bool, status_code: int, error_msg: String):
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
	
	if item.http_request == null:
		item.status = "failed"
		item.error_message = "Failed to start download"
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	# Setup progress timer - use longer intervals to reduce CPU/disk overhead
	# Desktop: 3s (reduced from 1s to save CPU), Android: 8s (for heat management)
	var poll_interval = 8.0 if PlatformManager.is_android() else 3.0
	_progress_timers[item.id] = Timer.new()
	_progress_timers[item.id].wait_time = poll_interval
	_progress_timers[item.id].autostart = true
	add_child(_progress_timers[item.id])
	
	_progress_timers[item.id].timeout.connect(func():
		_update_download_progress(item)
		_check_download_timeout(item.id)
	)

# ==================== CONNECTION POOL HELPERS ====================
## Creates a new HTTPClient connection for the given URL components
func _create_connection(url_parts: Dictionary) -> HTTPClient:
	var http = HTTPClient.new()
	
	var err: int
	if url_parts.protocol == "https":
		var tls_options = TLSOptions.client()
		err = http.connect_to_host(url_parts.host, url_parts.port, tls_options)
	else:
		err = http.connect_to_host(url_parts.host, url_parts.port)
	
	if err != OK:
		push_error("[DownloadManager] Failed to connect to host: " + url_parts.host + " error: " + str(err))
		return null
	
	# Wait for connection to establish
	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		OS.delay_usec(100)
	
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		push_error("[DownloadManager] Failed to connect, status: " + str(http.get_status()))
		return null
	
	return http

## Checks if an HTTPClient connection is still valid and connected
func _is_connection_valid(http: HTTPClient) -> bool:
	if http == null:
		return false
	return http.get_status() == HTTPClient.STATUS_CONNECTED

## Checks if a platform needs TitleID extraction for save sync
func _needs_title_id(game: GameResource) -> bool:
	match game.platform_slug:
		"3ds", "wiiu", "ngc", "wii", "ps2", "psp", "ps3", "ps4", "switch", "vita", "xbox360":
			return true
		_:
			return false

# ==================== CHUNKED DOWNLOAD METHODS ====================

func _check_range_and_start_chunked(item: QueueItem, headers: Array):
	"""Check if server supports Range requests, then start chunked or regular download"""
	NetworkManager.check_range_support(item.url, headers, func(supports_range: bool, error_msg: String, content_length: int = 0):
		if supports_range:
			print("[DownloadManager] Server supports Range, starting chunked download for: " + item.name)
			
			# Validate and update expected file size from server's Content-Length
			if content_length > 0:
				if item.expected_file_size != content_length:
					print("[DownloadManager] File size mismatch for " + item.name + ": expected " + str(item.expected_file_size) + " bytes, server reports " + str(content_length) + " bytes")
					print("[DownloadManager] Using server-reported size: " + str(content_length) + " bytes")
					item.expected_file_size = content_length
					# Also update the game resource if available
					if item.game_resource:
						item.game_resource.file_size = content_length
				else:
					print("[DownloadManager] Warning: Server did not provide Content-Length for " + item.name + ", using expected size: " + str(item.expected_file_size))
			
			_start_chunked_download(item, headers)
		else:
			print("[DownloadManager] Server doesn't support Range, falling back to regular download for: " + item.name)
			# Fall back to regular file-based download
			item.download_info = NetworkManager.http_download_file(
				item.url,
				item.destination_path,
				headers,
				func(success: bool, status_code: int, err: String):
					_on_file_download_complete(item, success, err),
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
			
			# Setup progress timer for fallback download
			_progress_timers[item.id] = Timer.new()
			_progress_timers[item.id].wait_time = 1.0
			_progress_timers[item.id].autostart = true
			add_child(_progress_timers[item.id])
			
			_progress_timers[item.id].timeout.connect(func():
				_update_download_progress(item)
				_check_download_timeout(item.id)
			)
	)

func _start_chunked_download(item: QueueItem, headers: Array):
	"""Start a chunked download using parallel threads"""
	var file_size = item.expected_file_size
	
	# Use dynamic chunk strategy based on file size and thread count
	var strategy = _calculate_chunk_strategy(file_size)
	var chunk_size = strategy.chunk_size
	var num_chunks = strategy.num_chunks
	var thread_count = strategy.thread_count
	
	# Create temp directory for chunks
	var temp_dir = "user://downloads/chunks/" + item.id
	if not FileSystemManager.make_dir_recursive(temp_dir):
		push_error("[DownloadManager] Failed to create chunk temp directory: " + temp_dir)
		item.status = "failed"
		item.error_message = "Failed to create temp directory"
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	# Create chunked download info
	var chunked_info = ChunkedDownloadInfo.new()
	chunked_info.item = item
	chunked_info.temp_dir = temp_dir
	chunked_info.final_path = item.destination_path
	chunked_info.total_chunks = num_chunks
	chunked_info.use_chunking = true
	
	# Create chunk infos
	for i in range(num_chunks):
		var chunk = ChunkInfo.new()
		chunk.index = i
		chunk.start_byte = i * chunk_size
		chunk.end_byte = mini((i + 1) * chunk_size - 1, file_size - 1)
		chunk.temp_path = temp_dir + "/chunk_" + str(i) + ".tmp"
		chunked_info.chunks.append(chunk)
	
	_chunked_downloads[item.id] = chunked_info
	
	# Initialize connection pool for persistent TLS connections
	# Use thread_count from strategy (already calculated)
	var connection_pool: Array[HTTPClient] = []
	connection_pool.resize(thread_count)
	_connection_pool_mutex.lock()
	_download_connection_pools[item.id] = connection_pool
	_connection_pool_mutex.unlock()
	
	print("[DownloadManager] Starting chunked download with " + str(num_chunks) + " chunks for: " + item.name)
	print("[DownloadManager] Using " + str(thread_count) + " threads with connection pool")
	
	# Queue all chunks to the download thread pool
	# This distributes chunks across threads for controlled parallelism
	var chunk_items = []
	for i in range(num_chunks):
		var thread_index = i % thread_count
		chunk_items.append({
			"item_id": item.id,
			"chunk_index": i,
			"url": item.url,
			"temp_path": chunked_info.chunks[i].temp_path,
			"start_byte": chunked_info.chunks[i].start_byte,
			"end_byte": chunked_info.chunks[i].end_byte,
			"headers": headers,
			"thread_index": thread_index
		})
	
	print("[DownloadManager] Queuing " + str(chunk_items.size()) + " chunks to thread pool for: " + item.name)
	
	# Use MemoryManager's download thread pool
	await MemoryManager.queue_parallel_downloads(
		chunk_items,
		func(chunk_data, index):
			var success = _download_chunk_on_thread(chunk_data)
			return {
				"success": success,
				"chunk_index": chunk_data.chunk_index
			},
		func(completed, total, batch_index, result):
			var success = result.get("success", false) if result is Dictionary else result
			var chunk_index = result.get("chunk_index", batch_index) if result is Dictionary else batch_index
			_update_chunk_download_progress(item.id, chunk_index, success),
		func(results):
			_on_all_chunks_complete(item.id, headers, results)
	)
	
	# Progress updates now come from worker threads only (no polling timer to avoid race conditions)

func _start_chunked_progress_timer(item_id: String):
	"""Start a timer to poll chunk file sizes for smooth progress updates"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	# Create timer to poll progress - more frequent for smoother UI updates
	# Desktop: 0.5s (faster for real-time feel), Android: 2s (for battery/heat)
	chunked_info.progress_timer = Timer.new()
	chunked_info.progress_timer.wait_time = 2.0 if PlatformManager.is_android() else 0.5
	chunked_info.progress_timer.autostart = true
	add_child(chunked_info.progress_timer)
	
	chunked_info.progress_timer.timeout.connect(func():
		_update_chunked_progress(item_id)
	)

## Downloads a single chunk on a worker thread using HTTPClient
## Called by the thread pool - runs on a background thread
## Uses connection pooling to reuse TLS connections across chunks
func _download_chunk_on_thread(chunk_data: Dictionary) -> bool:
	var url = chunk_data.url
	var temp_path = chunk_data.temp_path
	var start_byte = chunk_data.start_byte
	var end_byte = chunk_data.end_byte
	var headers = chunk_data.headers
	var chunk_index = chunk_data.chunk_index
	var item_id = chunk_data.item_id
	var thread_index = chunk_data.thread_index
	
	var chunk_start_time = Time.get_ticks_msec()
	print("[DownloadManager] [DEBUG] Starting chunk " + str(chunk_index) + " on thread " + str(thread_index) + " at time=" + str(chunk_start_time))
	
	# Parse URL to get components
	var url_parts = _parse_url(url)
	
	# Get or create connection from pool (thread-safe access)
	var http: HTTPClient
	var connection_created = false
	var was_reused = false
	
	_connection_pool_mutex.lock()
	if _download_connection_pools.has(item_id):
		var connection_pool = _download_connection_pools[item_id]
		if thread_index < connection_pool.size():
			http = connection_pool[thread_index]
			var status_before = http.get_status() if http != null else -1
			print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " connection status before check: " + str(status_before) + " (CONNECTED=" + str(HTTPClient.STATUS_CONNECTED) + ")")
			
			# Check for previous chunk finish time to calculate idle time
			var thread_key = item_id + "_" + str(thread_index)
			var prev_finish_time = _thread_chunk_finish_times.get(thread_key, 0)
			if prev_finish_time > 0:
				var idle_time = chunk_start_time - prev_finish_time
				print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " idle time between chunks: " + str(idle_time) + "ms")
			
			# Check if connection is still valid
			if not _is_connection_valid(http):
				print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " connection invalid, creating new for chunk " + str(chunk_index))
				http = _create_connection(url_parts)
				if http != null:
					connection_pool[thread_index] = http
					connection_created = true
					print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " created new connection (status=" + str(http.get_status()) + ")")
			else:
				was_reused = true
				print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " reusing connection (status=" + str(http.get_status()) + ") for chunk " + str(chunk_index))
		else:
			push_error("[DownloadManager] Thread index out of bounds: " + str(thread_index))
			_connection_pool_mutex.unlock()
			return false
	else:
		push_error("[DownloadManager] No connection pool found for item: " + item_id)
		_connection_pool_mutex.unlock()
		return false
	_connection_pool_mutex.unlock()
	
	if http == null:
		push_error("[DownloadManager] Failed to get/create connection for chunk " + str(chunk_index))
		return false
	
	# Prepare headers
	var request_headers = headers.duplicate()
	
	# Add required Host header for HTTP/1.1
	var has_host = false
	for header in request_headers:
		if header.to_lower().begins_with("host:"):
			has_host = true
			break
	if not has_host:
		request_headers.append("Host: " + url_parts.host)
	
	# Add Range header
	request_headers.append("Range: bytes=%d-%d" % [start_byte, end_byte])
	
	# Add User-Agent if not present
	var has_user_agent = false
	for header in request_headers:
		if header.begins_with("User-Agent:"):
			has_user_agent = true
			break
	if not has_user_agent:
		request_headers.append("User-Agent: Kyodai-Launcher/1.0")
	
	# Add Connection header for keep-alive
	var has_connection = false
	for header in request_headers:
		if header.to_lower().begins_with("connection:"):
			has_connection = true
			break
	if not has_connection:
		request_headers.append("Connection: keep-alive")
	
	# Add Accept header
	var has_accept = false
	for header in request_headers:
		if header.to_lower().begins_with("accept:"):
			has_accept = true
			break
	if not has_accept:
		request_headers.append("Accept: */*")
	
	# Make the request
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " making request, connection status: " + str(http.get_status()))
	
	var err = http.request(HTTPClient.METHOD_GET, url_parts.path + url_parts.query, request_headers)
	if err != OK:
		push_error("[DownloadManager] Failed to make request: " + str(err))
		return false
	
	# Wait for response headers
	var poll_count = 0
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		poll_count += 1
		if poll_count % 100 == 0:
			print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " still requesting... (poll " + str(poll_count) + ")")
		OS.delay_msec(10)
	
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " finished requesting after " + str(poll_count) + " polls, status: " + str(http.get_status()))
	
	# Get and log response headers
	var response_headers = http.get_response_headers()
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " response headers: " + str(response_headers))
	
	# Check for Connection header in response
	var connection_header = ""
	for header in response_headers:
		if header.to_lower().begins_with("connection:"):
			connection_header = header.split(":", false, 1)[1].strip_edges().to_lower()
			break
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " server Connection header: '" + connection_header + "' (was_reused=" + str(was_reused) + ")")
	
	# Check response code
	var response_code = http.get_response_code()
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " response code: " + str(response_code))
	
	if response_code != 200 and response_code != 206:
		# Read error response body
		var error_body = ""
		while http.get_status() == HTTPClient.STATUS_BODY:
			http.poll()
			var chunk_data_err = http.read_response_body_chunk()
			if chunk_data_err.size() > 0:
				error_body += chunk_data_err.get_string_from_utf8()
			else:
				break
		push_error("[DownloadManager] Chunk " + str(chunk_index) + " HTTP error " + str(response_code) + ": " + error_body)
		return false
	
	# Validate Content-Range header for 206 responses
	if response_code == 206:
		var content_range_valid = false
		var content_range_header = ""
		for header in response_headers:
			if header.to_lower().begins_with("content-range:"):
				content_range_header = header.split(":", false, 1)[1].strip_edges()
				break
		
		if content_range_header != "":
			# Parse "bytes start-end/total" format using RegEx
			var regex = RegEx.new()
			var regex_compile = regex.compile("bytes (\\d+)-(\\d+)/(\\d+)")
			if regex_compile == OK:
				var range_match = regex.search(content_range_header)
				if range_match:
					var range_start = int(range_match.get_string(1))
					var range_end = int(range_match.get_string(2))
					var range_total = int(range_match.get_string(3))
					
					if range_start == start_byte and range_end == end_byte:
						content_range_valid = true
						print("[DownloadManager] Chunk " + str(chunk_index) + " Content-Range validated: " + content_range_header)
					else:
						push_error("[DownloadManager] Chunk " + str(chunk_index) + " Content-Range mismatch. Expected: bytes=" + str(start_byte) + "-" + str(end_byte) + ", Got: " + content_range_header)
				else:
					push_error("[DownloadManager] Chunk " + str(chunk_index) + " Invalid Content-Range format: " + content_range_header)
			else:
				push_error("[DownloadManager] Chunk " + str(chunk_index) + " Failed to compile Content-Range regex")
		else:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " Missing Content-Range header for 206 response")
		
		if not content_range_valid:
			return false
	
	# Open file for writing
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if not file:
		push_error("[DownloadManager] Failed to create chunk file: " + temp_path)
		return false
	
	# Download the chunk with improved polling
	var bytes_downloaded = 0
	var last_progress_emit = 0
	var body_poll_count = 0
	var last_poll_time = Time.get_ticks_msec()
	var last_data_received_time = last_poll_time
	
	while http.get_status() == HTTPClient.STATUS_BODY:
		var current_time = Time.get_ticks_msec()
		
		# Poll every POLLING_INTERVAL_MS to balance responsiveness with CPU usage
		if current_time - last_poll_time >= POLLING_INTERVAL_MS:
			http.poll()
			body_poll_count += 1
			last_poll_time = current_time
		
		var chunk = http.read_response_body_chunk()
		if chunk.size() > 0:
			file.store_buffer(chunk)
			bytes_downloaded += chunk.size()
			last_data_received_time = current_time
			
			# Emit progress every 10MB
			if bytes_downloaded - last_progress_emit >= 10 * 1024 * 1024:
				call_deferred("_update_chunk_progress", chunk_data.item_id, chunk_index, bytes_downloaded)
				last_progress_emit = bytes_downloaded
				print("[DownloadManager] Chunk " + str(chunk_index) + " progress: " + str(bytes_downloaded / 1024 / 1024) + "MB")
		else:
			# No data available, wait a bit before checking again
			OS.delay_usec(1000)  # 1ms micro-sleep to prevent busy-waiting
	
	file.close()
	
	# Verify chunk file exists and has correct size
	if not FileAccess.file_exists(temp_path):
		push_error("[DownloadManager] Chunk file not found after download: " + temp_path)
		return false
	
	var verify_file = FileAccess.open(temp_path, FileAccess.READ)
	if not verify_file:
		push_error("[DownloadManager] Failed to open chunk file for verification: " + temp_path)
		return false
	
	var actual_size = verify_file.get_length()
	verify_file.close()
	
	if actual_size != bytes_downloaded:
		push_error("[DownloadManager] Chunk " + str(chunk_index) + " size mismatch: expected " + str(bytes_downloaded) + " bytes, got " + str(actual_size) + " bytes")
		return false
	
	var chunk_end_time = Time.get_ticks_msec()
	var download_duration = chunk_end_time - chunk_start_time
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " finished body after " + str(body_poll_count) + " polls, status: " + str(http.get_status()))
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " download duration: " + str(download_duration) + "ms")
	
	# Track finish time for this thread for debugging connection reuse
	var thread_key = item_id + "_" + str(thread_index)
	_thread_chunk_finish_times[thread_key] = chunk_end_time
	
	# DO NOT close the connection - leave it open for reuse by other chunks
	
	if bytes_downloaded == 0:
		push_error("[DownloadManager] Downloaded 0 bytes for chunk " + str(chunk_index))
		return false
	
	print("[DownloadManager] Chunk " + str(chunk_index) + " completed successfully with " + str(bytes_downloaded) + " bytes (connection left open, status=" + str(http.get_status()) + ")")
	return true

## Parses URL into components
func _parse_url(url: String) -> Dictionary:
	var result = {"protocol": "http", "host": "", "port": 80, "path": "/", "query": ""}
	
	# Extract protocol
	var protocol_end = url.find("://")
	if protocol_end != -1:
		result.protocol = url.substr(0, protocol_end)
		url = url.substr(protocol_end + 3)
	
	# Set default port based on protocol
	if result.protocol == "https":
		result.port = 443
	
	# Extract host and path
	var path_start = url.find("/")
	if path_start == -1:
		result.host = url
	else:
		result.host = url.substr(0, path_start)
		var remainder = url.substr(path_start)
		var query_start = remainder.find("?")
		if query_start == -1:
			result.path = remainder
		else:
			result.path = remainder.substr(0, query_start)
			result.query = remainder.substr(query_start)
	
	# Check for explicit port in host
	var port_start = result.host.find(":")
	if port_start != -1:
		result.port = result.host.substr(port_start + 1).to_int()
		result.host = result.host.substr(0, port_start)
	
	return result

## Updates progress when a chunk completes via thread pool
func _update_chunk_download_progress(item_id: String, chunk_index: int, success: bool):
	if not _chunked_downloads.has(item_id):
		return
	
	if chunk_index < 0 or chunk_index >= _chunked_downloads[item_id].chunks.size():
		push_error("[DownloadManager] Invalid chunk index in progress update: " + str(chunk_index))
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	var chunk = chunked_info.chunks[chunk_index]
	
	if success:
		if not chunk.completed:
			chunk.completed = true
			chunk.in_progress = false
			chunked_info.chunks_completed += 1
			print("[DownloadManager] Chunk " + str(chunk_index) + " completed successfully (total: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")
	else:
		chunk.in_progress = false
		chunk.failed = true
		print("[DownloadManager] Chunk " + str(chunk_index) + " failed (total completed: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")
	
	# Update overall progress based on actual bytes
	var total_downloaded_bytes = 0
	for c in chunked_info.chunks:
		if c.completed:
			total_downloaded_bytes += (c.end_byte - c.start_byte + 1)
		else:
			total_downloaded_bytes += c.temp_bytes_downloaded
	
	var total_size = float(item.expected_file_size)
	if total_size > 0:
		var progress = float(total_downloaded_bytes) / total_size
		progress = min(progress, 0.99)
		if abs(progress - chunked_info.last_progress_update) >= 0.001:
			chunked_info.last_progress_update = progress
			item.progress = progress
			download_progress.emit(item_id, progress)

## Called when all chunks have been processed by the thread pool
func _on_all_chunks_complete(item_id: String, headers: Array, results: Dictionary = {}):
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	print("[DownloadManager] Thread pool callback: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + " chunks done")
	
	# Check if all chunks completed successfully
	if chunked_info.chunks_completed >= chunked_info.total_chunks:
		print("[DownloadManager] All chunks marked complete for: " + item.name + ", verifying files before reassembly...")
		
		# Verify chunk files actually exist on disk (protects against race conditions / external deletion)
		var missing_or_bad_chunks = []
		for chunk in chunked_info.chunks:
			if not FileAccess.file_exists(chunk.temp_path):
				push_error("[DownloadManager] Chunk file missing despite being marked complete: " + chunk.temp_path)
				missing_or_bad_chunks.append(chunk)
			else:
				var verify_file = FileAccess.open(chunk.temp_path, FileAccess.READ)
				if verify_file:
					var actual_size = verify_file.get_length()
					verify_file.close()
					var expected_size = chunk.end_byte - chunk.start_byte + 1
					if actual_size != expected_size:
						push_error("[DownloadManager] Chunk " + str(chunk.index) + " size mismatch despite being marked complete: expected " + str(expected_size) + ", got " + str(actual_size))
						missing_or_bad_chunks.append(chunk)
				else:
					push_error("[DownloadManager] Cannot open chunk file despite being marked complete: " + chunk.temp_path)
					missing_or_bad_chunks.append(chunk)
		
		if missing_or_bad_chunks.size() > 0:
			print("[DownloadManager] Found " + str(missing_or_bad_chunks.size()) + " chunks marked complete but files missing/bad. Resetting for retry...")
			for chunk in missing_or_bad_chunks:
				chunk.completed = false
				chunked_info.chunks_completed -= 1
			_handle_failed_chunks_thread_pool(item_id, headers)
			return
		
		_stop_chunked_progress_timer(item_id)
		_cleanup_download_tracking(item_id)
		_reassemble_chunks(item_id)
	else:
		# Some chunks failed - check if we should retry
		print("[DownloadManager] Not all chunks completed, checking for retries...")
		_handle_failed_chunks_thread_pool(item_id, headers)

## Handles failed chunks with retry logic for thread pool
func _handle_failed_chunks_thread_pool(item_id: String, headers: Array):
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	# Find failed chunks that can be retried
	var failed_chunks = []
	for chunk in chunked_info.chunks:
		if not chunk.completed and chunk.retry_count < MAX_CHUNK_RETRIES:
			failed_chunks.append(chunk)
	
	if failed_chunks.size() > 0:
		print("[DownloadManager] Retrying " + str(failed_chunks.size()) + " failed chunks for: " + item.name)
		
		# Prepare retry items
		var retry_items = []
		for chunk in failed_chunks:
			chunk.retry_count += 1
			chunk.failed = false
			chunk.in_progress = false
			chunk.temp_bytes_downloaded = 0  # Reset progress tracking
			
			# Delete partial file
			if FileSystemManager.file_exists(chunk.temp_path):
				FileSystemManager.delete_file(chunk.temp_path)
			
			retry_items.append({
				"item_id": item_id,
				"chunk_index": chunk.index,
				"url": item.url,
				"temp_path": chunk.temp_path,
				"start_byte": chunk.start_byte,
				"end_byte": chunk.end_byte,
				"headers": headers,
				"thread_index": chunk.index % MemoryManager.get_download_thread_count()
			})
		
		# Wait before retry using non-blocking timer
		await get_tree().create_timer(CHUNK_RETRY_DELAY_SEC).timeout
		
		# Queue retry via thread pool
		await MemoryManager.queue_parallel_downloads(
			retry_items,
			func(chunk_data, index):
				var success = _download_chunk_on_thread(chunk_data)
				return {
					"success": success,
					"chunk_index": chunk_data.chunk_index
				},
			func(completed, total, batch_index, result):
				var success = result.get("success", false) if result is Dictionary else result
				var chunk_index = result.get("chunk_index", batch_index) if result is Dictionary else batch_index
				_update_chunk_download_progress(item_id, chunk_index, success),
			func(results):
				_on_all_chunks_complete(item_id, headers, results)
		)
	else:
		# No more retries available
		push_error("[DownloadManager] Chunks failed with no retries remaining for: " + item.name)
		item.status = "failed"
		item.error_message = "Chunk download failed after " + str(MAX_CHUNK_RETRIES) + " retries"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		_active_items.erase(item_id)
		download_completed.emit(item_id, false, item.error_message)
		queue_changed.emit()
		_process_queue()

func _update_chunked_progress(item_id: String):
	"""Update progress by summing bytes from all chunks"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	# Calculate total bytes downloaded across all chunks
	var total_downloaded_bytes = 0
	
	for chunk in chunked_info.chunks:
		if chunk.completed:
			# Full chunk size
			total_downloaded_bytes += (chunk.end_byte - chunk.start_byte + 1)
		elif chunk.in_progress:
			# Use temp_bytes_downloaded for real-time progress during download
			total_downloaded_bytes += chunk.temp_bytes_downloaded
	
	# Calculate progress
	var total_size = float(item.expected_file_size)
	if total_size > 0:
		var progress = float(total_downloaded_bytes) / total_size
		# Cap at 0.99 until fully complete
		progress = min(progress, 0.99)
		
		# Only emit if progress changed significantly (0.1% or more)
		if abs(progress - chunked_info.last_progress_update) >= 0.001:
			chunked_info.last_progress_update = progress
			item.progress = progress
			download_progress.emit(item_id, progress)

## Called from worker thread to update chunk progress in real-time
func _update_chunk_progress(item_id: String, chunk_index: int, bytes_downloaded: int):
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	if chunk_index < chunked_info.chunks.size():
		chunked_info.chunks[chunk_index].temp_bytes_downloaded = bytes_downloaded
		
		# Calculate and emit progress immediately for responsive UI
		var item = chunked_info.item
		var total_downloaded_bytes = 0
		
		for chunk in chunked_info.chunks:
			if chunk.completed:
				total_downloaded_bytes += (chunk.end_byte - chunk.start_byte + 1)
			else:
				total_downloaded_bytes += chunk.temp_bytes_downloaded
		
		var total_size = float(item.expected_file_size)
		if total_size > 0:
			var progress = float(total_downloaded_bytes) / total_size
			progress = min(progress, 0.99)
			
			# Emit if progress changed significantly
			if abs(progress - chunked_info.last_progress_update) >= 0.005:  # 0.5% threshold
				chunked_info.last_progress_update = progress
				item.progress = progress
				download_progress.emit(item_id, progress)

func _stop_chunked_progress_timer(item_id: String):
	"""Stop and clean up the progress timer"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	if chunked_info.progress_timer and is_instance_valid(chunked_info.progress_timer):
		chunked_info.progress_timer.stop()
		chunked_info.progress_timer.queue_free()
		chunked_info.progress_timer = null

func _start_next_chunk_downloads(item_id: String, headers: Array):
	"""Start downloading the next batch of chunks up to max_concurrent_chunks"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	# Count how many chunks are currently downloading
	var active_count = 0
	for chunk in chunked_info.chunks:
		if chunk.in_progress and not chunk.completed and not chunk.failed:
			active_count += 1
	
	# Start more downloads until we hit max_concurrent_chunks
	for chunk in chunked_info.chunks:
		if active_count >= max_concurrent_chunks:
			break
		
		if not chunk.in_progress and not chunk.completed and not chunk.failed:
			chunk.in_progress = true
			active_count += 1
			
			# Start this chunk download
			_start_single_chunk_download(item_id, chunk, headers)

func _start_single_chunk_download(item_id: String, chunk: ChunkInfo, headers: Array):
	"""Start downloading a single chunk"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	# Add User-Agent if not present
	var request_headers = headers.duplicate()
	var has_user_agent = false
	for header in request_headers:
		if header.begins_with("User-Agent:"):
			has_user_agent = true
			break
	if not has_user_agent:
		request_headers.append("User-Agent: Kyodai-Launcher/1.0")
	
	# Start the download
	print("[DownloadManager] Starting chunk " + str(chunk.index) + " for: " + item.name)
	NetworkManager.http_download_chunk(
		item.url,
		chunk.temp_path,
		chunk.start_byte,
		chunk.end_byte,
		request_headers,
		func(success: bool, status_code: int, error_msg: String):
			_on_chunk_download_complete(item_id, chunk.index, success, error_msg, headers)
	)

func _on_chunk_download_complete(item_id: String, chunk_index: int, success: bool, error_msg: String, headers: Array):
	"""Called when a chunk download completes"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	var chunk = chunked_info.chunks[chunk_index]
	
	chunk.in_progress = false
	
	if success:
		chunk.completed = true
		chunked_info.chunks_completed += 1
		print("[DownloadManager] Chunk " + str(chunk_index) + " completed for: " + item.name + " (" + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")
		
		# Note: Progress is now handled by _update_chunked_progress timer which tracks actual bytes
		# This prevents progress jumps and provides smooth 0-100% updates
		
		# Check if all chunks are complete
		if chunked_info.chunks_completed >= chunked_info.total_chunks:
			print("[DownloadManager] All chunks complete for: " + item.name)
			_stop_chunked_progress_timer(item_id)
			_cleanup_download_tracking(item_id)
			_reassemble_chunks(item_id)
		else:
			# Start the next chunk
			_start_next_chunk_downloads(item_id, headers)
	else:
		chunk.retry_count += 1
		chunk.in_progress = false
		
		# Reset progress tracking for retry
		chunk.temp_bytes_downloaded = 0
		
		if chunk.retry_count <= MAX_CHUNK_RETRIES:
			# Delete partial/failed chunk file
			if FileSystemManager.file_exists(chunk.temp_path):
				FileSystemManager.delete_file(chunk.temp_path)
				print("[DownloadManager] Deleted failed chunk file: " + chunk.temp_path)
			
			# Update progress to show retry status
			_update_chunked_progress(item_id)
			
			NotificationManager.update_notification_text(
				item.notification_id,
				"Retrying chunk " + str(chunk_index) + " (" + str(chunk.retry_count) + "/" + str(MAX_CHUNK_RETRIES) + "): " + item.name
			)
			
			print("[DownloadManager] Chunk " + str(chunk_index) + " failed, retrying in " + str(CHUNK_RETRY_DELAY_SEC) + "s (" + str(chunk.retry_count) + "/" + str(MAX_CHUNK_RETRIES) + ")")
			
			# Wait before retry
			await get_tree().create_timer(CHUNK_RETRY_DELAY_SEC).timeout
			
			# Retry the chunk
			chunk.failed = false
			_start_next_chunk_downloads(item_id, headers)
		else:
			# Max retries exceeded - fail the download
			chunk.failed = true
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " failed after " + str(MAX_CHUNK_RETRIES) + " retries: " + error_msg)
			_stop_chunked_progress_timer(item_id)
			item.status = "failed"
			item.error_message = "Chunk download failed after " + str(MAX_CHUNK_RETRIES) + " retries: " + error_msg
			_cleanup_chunked_download(item_id)
			_cleanup_item(item)
			_active_items.erase(item_id)
			download_completed.emit(item_id, false, item.error_message)
			queue_changed.emit()
			_process_queue()

func _reassemble_chunks(item_id: String):
	"""Reassemble all chunks into the final file - platform-specific implementation"""
	if not _chunked_downloads.has(item_id):
		push_error("[DownloadManager] No chunked download found for item: " + item_id)
		return
	
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	
	print("[DownloadManager] Starting chunk reassembly for: " + item.name)
	
	# Dismiss the download progress notification and show a pulsing reassembly notification
	if item.notification_id != -1:
		NotificationManager.dismiss_notification(item.notification_id)
	
	if not item.suppress_notification:
		item.notification_id = NotificationManager.show_notification(
			"Assembling " + item.name + "...",
			Notification.Type.INFO,
			null,
			0.0,
			Callable(),  # No progress callable - using pulsing
			Callable(),  # No text formatter
			true  # pulsing = true
		)
	
	# Reassemble chunks to the final destination path
	var reassembly_temp_path = chunked_info.final_path
	
	# Pre-reassembly verification: ensure all chunk files exist and have correct sizes
	var missing_chunks = []
	for chunk in chunked_info.chunks:
		if not FileAccess.file_exists(chunk.temp_path):
			push_error("[DownloadManager] [Reassembly] Pre-check: chunk file missing: " + chunk.temp_path)
			missing_chunks.append(chunk)
		else:
			var verify_file = FileAccess.open(chunk.temp_path, FileAccess.READ)
			if verify_file:
				var actual_size = verify_file.get_length()
				verify_file.close()
				var expected_size = chunk.end_byte - chunk.start_byte + 1
				if actual_size != expected_size:
					push_error("[DownloadManager] [Reassembly] Pre-check: chunk " + str(chunk.index) + " size mismatch: expected " + str(expected_size) + ", got " + str(actual_size))
					missing_chunks.append(chunk)
			else:
				push_error("[DownloadManager] [Reassembly] Pre-check: cannot open chunk file: " + chunk.temp_path)
				missing_chunks.append(chunk)
	
	if missing_chunks.size() > 0:
		print("[DownloadManager] [Reassembly] Found " + str(missing_chunks.size()) + " missing/bad chunks before reassembly. This should have been caught earlier - failing download.")
		item.status = "failed"
		item.error_message = "Chunk files missing or corrupted before reassembly"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		_active_items.erase(item_id)
		download_completed.emit(item_id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	# Platform-specific reassembly
	if PlatformManager.is_android():
		_reassemble_chunks_android(item_id, chunked_info, item, reassembly_temp_path)
	else:
		_reassemble_chunks_desktop(item_id, chunked_info, item, reassembly_temp_path)

func _reassemble_chunks_android(item_id: String, chunked_info: ChunkedDownloadInfo, item: QueueItem, reassembly_temp_path: String):
	"""Reassemble chunks using native Java on Android (low memory footprint)"""
	# Build JSON array of chunk paths
	var chunk_paths = []
	for chunk in chunked_info.chunks:
		var absolute_path = ProjectSettings.globalize_path(chunk.temp_path)
		chunk_paths.append(absolute_path)
	
	var chunk_paths_json = JSON.stringify(chunk_paths)
	var output_absolute_path = ProjectSettings.globalize_path(reassembly_temp_path)
	
	print("[DownloadManager] [Reassembly] Calling native reassembly for: " + item.name + " (" + str(chunk_paths.size()) + " chunks) -> " + output_absolute_path)
	
	# Call native Java reassembly
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_error("[DownloadManager] PackageChecker plugin not available for reassembly")
		_stop_chunked_progress_timer(item_id)
		item.status = "failed"
		item.error_message = "Plugin not available for reassembly"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		_active_items.erase(item_id)
		download_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	# Perform reassembly in native code (runs in foreground service process)
	var success = plugin.reassembleChunks(chunk_paths_json, output_absolute_path)
	
	print("[DownloadManager] [Reassembly] Native reassembly returned: " + str(success) + " for: " + item.name)
	
	if not success:
		push_error("[DownloadManager] Native reassembly failed for: " + item.name)
		# Clean up failed final file
		if FileSystemManager.file_exists(reassembly_temp_path):
			FileSystemManager.delete_file(reassembly_temp_path)
		
		_stop_chunked_progress_timer(item_id)
		item.status = "failed"
		item.error_message = "Failed to reassemble chunks"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		_active_items.erase(item_id)
		download_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	# Success! Clean up chunk temp files and continue
	_finish_reassembly_success(item_id, item, reassembly_temp_path)

func _reassemble_chunks_desktop(item_id: String, chunked_info: ChunkedDownloadInfo, item: QueueItem, reassembly_temp_path: String):
	"""Reassemble chunks using Godot threading on Desktop"""
	# Store values needed for thread operation
	var final_path = reassembly_temp_path
	var chunks_data = []
	for chunk in chunked_info.chunks:
		chunks_data.append({
			"temp_path": chunk.temp_path,
			"index": chunk.index
		})
	
	# Create the reassembly callable for the extraction thread
	var reassembly_callable = func() -> bool:
		print("[DownloadManager] [Reassembly] Starting desktop reassembly for: " + item.name + " -> " + final_path)
		
		# Open final file for writing
		var final_file = FileAccess.open(final_path, FileAccess.WRITE)
		if not final_file:
			push_error("[DownloadManager] [Reassembly] Failed to create final file: " + final_path)
			return false
		
		# Append each chunk to final file with buffered I/O to avoid memory spikes
		const BUFFER_SIZE = 8 * 1024 * 1024  # 8MB buffer for streaming
		
		for chunk_data in chunks_data:
			var chunk_path = chunk_data.temp_path
			
			print("[DownloadManager] [Reassembly] Appending chunk " + str(chunk_data.index + 1) + "/" + str(chunks_data.size()) + ": " + chunk_path)
			
			if not FileAccess.file_exists(chunk_path):
				push_error("[DownloadManager] [Reassembly] Chunk file missing: " + chunk_path)
				final_file.close()
				return false
			
			var chunk_file = FileAccess.open(chunk_path, FileAccess.READ)
			if not chunk_file:
				push_error("[DownloadManager] [Reassembly] Failed to open chunk file: " + chunk_path)
				final_file.close()
				return false
			
			# Stream the chunk file in 8MB buffers instead of loading all at once
			var chunk_size = chunk_file.get_length()
			var bytes_remaining = chunk_size
			
			while bytes_remaining > 0:
				var read_size = mini(BUFFER_SIZE, bytes_remaining)
				var buffer = chunk_file.get_buffer(read_size)
				final_file.store_buffer(buffer)
				bytes_remaining -= buffer.size()
			
			chunk_file.close()
			print("[DownloadManager] [Reassembly] Finished chunk " + str(chunk_data.index + 1) + " (" + str(chunk_size) + " bytes)")
		
		final_file.close()
		
		var final_size = 0
		if FileAccess.file_exists(final_path):
			var size_file = FileAccess.open(final_path, FileAccess.READ)
			if size_file:
				final_size = size_file.get_length()
				size_file.close()
		
		print("[DownloadManager] [Reassembly] Desktop reassembly complete for: " + item.name + ". Final size: " + str(final_size) + " bytes")
		return true
	
	print("[DownloadManager] [Reassembly] Queueing desktop reassembly to extraction thread for: " + item.name)
	
	# Queue to extraction thread - callback runs on main thread
	MemoryManager.queue_extraction_task(reassembly_callable, func(success: bool):
		if not _chunked_downloads.has(item_id):
			print("[DownloadManager] [Reassembly] Reassembly callback ignored: download was cancelled or cleaned up for: " + item.name)
			return
		
		if not success:
			push_error("[DownloadManager] [Reassembly] Desktop reassembly failed for: " + item.name)
			
			# Clean up failed final file
			if FileSystemManager.file_exists(final_path):
				FileSystemManager.delete_file(final_path)
			
			item.status = "failed"
			item.error_message = "Failed to reassemble chunks"
			_cleanup_chunked_download(item_id)
			_cleanup_item(item)
			_active_items.erase(item_id)
			download_completed.emit(item.id, false, item.error_message)
			queue_changed.emit()
			_process_queue()
			return
		
		print("[DownloadManager] [Reassembly] Desktop reassembly callback success for: " + item.name)
		# Success - clean up and finish
		_finish_reassembly_success(item_id, item, reassembly_temp_path)
	)

func _finish_reassembly_success(item_id: String, item: QueueItem, reassembly_temp_path: String):
	"""Handle successful reassembly completion (shared between Android and Desktop)"""
	if not _chunked_downloads.has(item_id):
		return
	
	var final_size = 0
	if FileAccess.file_exists(reassembly_temp_path):
		var size_file = FileAccess.open(reassembly_temp_path, FileAccess.READ)
		if size_file:
			final_size = size_file.get_length()
			size_file.close()
	
	print("[DownloadManager] [Reassembly] Finishing reassembly success for: " + item.name + " path=" + reassembly_temp_path + " size=" + str(final_size) + " bytes")
	
	# Validate final size against expected size
	if item.expected_file_size > 0 and final_size != item.expected_file_size:
		push_error("[DownloadManager] [Reassembly] Final size mismatch for: " + item.name + ". Expected: " + str(item.expected_file_size) + " bytes, Got: " + str(final_size) + " bytes")
		item.status = "failed"
		item.error_message = "Download corrupted: size mismatch (expected " + str(item.expected_file_size) + ", got " + str(final_size) + ")"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		_active_items.erase(item_id)
		
		# Clean up the corrupted file
		if FileSystemManager.file_exists(reassembly_temp_path):
			FileSystemManager.delete_file(reassembly_temp_path)
		
		if item.notification_id != -1:
			NotificationManager.dismiss_notification(item.notification_id)
			item.notification_id = -1
		
		download_completed.emit(item_id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return
	
	_cleanup_chunked_download(item_id)
	
	# Continue with normal completion flow
	_on_file_download_complete(item, true, "")

func _cleanup_chunked_download(item_id: String):
	"""Clean up temp files for chunked download"""
	if not _chunked_downloads.has(item_id):
		return
	
	var chunked_info = _chunked_downloads[item_id]
	
	# Stop progress timer
	if chunked_info.progress_timer and is_instance_valid(chunked_info.progress_timer):
		chunked_info.progress_timer.stop()
		chunked_info.progress_timer.queue_free()
		chunked_info.progress_timer = null
	
	# Clean up temp chunk files
	for chunk in chunked_info.chunks:
		if FileSystemManager.file_exists(chunk.temp_path):
			FileSystemManager.delete_file(chunk.temp_path)
	
	# Clean up temp directory
	if FileSystemManager.dir_exists(chunked_info.temp_dir):
		_cleanup_temp_dir(chunked_info.temp_dir)
	
	# Close and clean up connection pool
	_connection_pool_mutex.lock()
	if _download_connection_pools.has(item_id):
		var connection_pool = _download_connection_pools[item_id]
		for http in connection_pool:
			if http != null and http.get_status() == HTTPClient.STATUS_CONNECTED:
				http.close()
		_download_connection_pools.erase(item_id)
	_connection_pool_mutex.unlock()
	
	# Remove from tracking
	_chunked_downloads.erase(item_id)

func _update_download_progress(item: QueueItem):
	if item.http_request == null and item.download_info.is_empty():
		return
	
	# All downloads are now file-based; check actual file on disk to avoid 32-bit overflow
	if not item.download_info.is_empty():
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
				
				# Track progress periodically (every 50MB change)
				var last_bytes = _last_downloaded_bytes.get(item.id, 0)
				if abs(current_size - last_bytes) > 50 * 1024 * 1024:
					_last_downloaded_bytes[item.id] = current_size
				
				# Update stall time if making progress
				if current_size > 0 and current_size != last_bytes:
					_last_progress_times[item.id] = Time.get_ticks_msec()
		
		# Check if download completed via request_completed callback
		if item.download_info.get("completed", false):
			_on_file_download_complete(item, true, "")
			return
		
		# Check if download had an error
		if item.download_info.has("error"):
			var error_msg = item.download_info.get("error", "Unknown error")
			_on_file_download_complete(item, false, error_msg)
			return
		
		download_progress.emit(item.id, item.progress)
		
		# Update foreground service notification on Android
		_update_foreground_service(item.name, int(item.progress * 100))

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
		_stop_foreground_service()  # Stop foreground service on failure
		download_completed.emit(item.id, false, error_msg)
		queue_changed.emit()
		_process_queue()
		return
	
	# Verify file exists and has content
	if not FileAccess.file_exists(item.destination_path):
		item.status = "failed"
		item.error_message = "Download file not found"
		NotificationManager.update_notification_text(item.notification_id, "Download failed: " + item.name)
		_cleanup_item(item)
		_active_items.erase(item.id)
		_stop_foreground_service()  # Stop foreground service on failure
		download_completed.emit(item.id, false, "Download file not found")
		queue_changed.emit()
		_process_queue()
		return
	
	# Finish download completion
	_finish_download_completion(item)

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
		_fail_download(item_id, "Download timed out")
		return
	
	# Don't check for stall during initial grace period
	if elapsed_since_start < INITIAL_GRACE_PERIOD_MS:
		return
	
	# Check for stall (no progress for too long after grace period)
	if current_time - last_progress > STALL_TIMEOUT_MS:
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
	_stop_foreground_service()  # Stop foreground service on failure
	
	NotificationManager.update_notification_text(item.notification_id, "Download failed: " + item.name)
	download_completed.emit(item_id, false, error_msg)
	queue_changed.emit()
	_process_queue()

func _start_extraction(item: QueueItem):
	item.status = "extracting"
	if not _active_items.has(item.id):
		_active_items[item.id] = item
	
	# Show extraction notification with pulsing progress (indeterminate)
	# Dismiss old notification first, then create new one (unless suppressed for batch)
	if not item.suppress_notification:
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
	
	# Determine format and extract
	var archive_path = item.destination_path
	var extract_dir = item.extract_dir
	
	print("[DownloadManager] _start_extraction: archive_path=" + archive_path + ", extract_dir=" + extract_dir)
	
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

func _finish_download_completion(item: QueueItem):
	"""Complete the download after file operations are done"""
	# Update game resource if applicable
	if item.game_resource:
		var downloaded_id = item.romm_id if item.romm_id != 0 else item.game_resource.romm_id
		item.game_resource.mark_sibling_downloaded(downloaded_id)
		item.game_resource.file_path = item.destination_path
		DataManager.update_game(item.game_resource)
		
		# Extract TitleID in background if needed
		if item.game_resource.get_active_title_id() == "" and _needs_title_id(item.game_resource):
			var game = item.game_resource
			var notify_id = NotificationManager.show_notification("Extracting TitleID for " + game.title + "...", Notification.Type.INFO, null, 3.0, Callable(), Callable(), true)
			MemoryManager.queue_extraction_task(func():
				var title_id = TitleIDParser.extract_for_game(game)
				return title_id
			, func(title_id: String):
				NotificationManager.dismiss_notification(notify_id)
				if title_id != "":
					DataManager.update_game_title_id(game.romm_id, title_id)
					NotificationManager.show_notification("TitleID " + title_id + " found for " + game.title + "!", Notification.Type.SUCCESS, null, 3.0)
					print("[DownloadManager] TitleID extracted post-download: " + title_id + " for " + game.title)
				else:
					print("[DownloadManager] TitleID extraction failed for " + game.title)
			)
	
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
		if item.notification_id != -1:
			NotificationManager.dismiss_notification(item.notification_id)
			item.notification_id = -1
		_active_items.erase(item.id)
		_stop_foreground_service()  # Stop foreground service on completion (no extraction)
		download_completed.emit(item.id, true, item.destination_path)
		queue_changed.emit()
		_process_queue()

func _extract_zip(item: QueueItem, archive_path: String, extract_dir: String):
	# Show extraction notification immediately
	NotificationManager.update_notification_text(item.notification_id, item.name + "...")
	
	# Create extraction callable for MemoryManager
	var extraction_callable = func() -> bool:
		print("[DownloadManager] Extraction worker started: " + archive_path + " -> " + extract_dir)
		
		# Delegate to FileSystemManager for all ZIP extraction
		var success = FileSystemManager.extract_zip(archive_path, extract_dir)
		
		if not success:
			push_error("[DownloadManager] Extraction failed for: " + archive_path)
			return false
		
		# Clean up archive only if delete_after_extract is true
		if item.delete_after_extract:
			FileSystemManager.delete_file(archive_path)
		
		return true
	
	# Queue extraction to MemoryManager
	MemoryManager.queue_extraction_task(extraction_callable, func(success: bool):
		if success:
			item.status = "completed"
			item.progress = 1.0
			NotificationManager.dismiss_notification(item.notification_id)
			_cleanup_item(item)
			_active_items.erase(item.id)
			
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
			push_error("[DownloadManager] 7z extraction failed with exit code: " + str(exit_code))
			return false
		
		# Clean up archive only if delete_after_extract is true
		if item.delete_after_extract:
			FileSystemManager.delete_file(archive_path)
		
		return true
	
	# Queue extraction to MemoryManager
	MemoryManager.queue_extraction_task(extraction_callable, func(success: bool):
		if success:
			item.status = "completed"
			item.progress = 1.0
			NotificationManager.dismiss_notification(item.notification_id)
			_cleanup_item(item)
			_active_items.erase(item.id)
			
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
	return true

## Helper function to recursively clean up a temp directory
func _cleanup_temp_dir(dir_path: String) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = dir_path + "/" + file_name
			if dir.current_is_dir():
				_cleanup_temp_dir(full_path)
			else:
				FileSystemManager.delete_file(full_path)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	FileSystemManager.delete_dir_recursive(dir_path)
