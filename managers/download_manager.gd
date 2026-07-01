extends Manager

# DownloadManager - Unified download and extraction queue
# Handles all file downloads: games, emulators, cores, images, etc.
# Also handles archive extraction with progress notifications

const FSM = preload("res://managers/filesystem_manager.gd")

signal download_started(item_id: String)
signal download_progress(item_id: String, progress: float)
signal download_completed(item_id: String, success: bool, message: String)
signal extraction_started(item_id: String)
@warning_ignore("unused_signal")
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
	var update_game_resource: bool = true  # If false, skip DataManager.update_game() on completion
	var extracted_count: int = 0  # Files extracted so far
	var total_count: int = 0  # Total files in archive

# Unified queue
var _queue: Array[QueueItem] = []
var _active_items: Dictionary = {}  # id -> QueueItem

# Max concurrent downloads is now driven by the download_speed_profile setting.
var _max_concurrent: int = 5  # Default; updated in _ready and when settings change.

# Unified progress/timeout tracking struct
class DownloadProgress:
	var timer: Timer
	var start_time_ms: int
	var last_progress_time_ms: int
	var last_downloaded_bytes: int

var _download_progress: Dictionary = {}  # item_id -> DownloadProgress
const DOWNLOAD_TIMEOUT_MS: int = 30 * 60 * 1000  # 30 minutes max
const STALL_TIMEOUT_MS: int = 120 * 1000  # 120 seconds with no progress = stall
const INITIAL_GRACE_PERIOD_MS: int = 30 * 1000  # 30 second grace period at start

# Chunked download constants
const CHUNKED_DOWNLOAD_THRESHOLD: int = 20 * 1024 * 1024  # 20MB minimum for chunking

# Dynamic chunk sizing (copyparty-style): start at 1 MiB, grow by 512 KiB steps,
# targeting <=256 chunks. For very large files we allow up to 4096 chunks once
# the chunk size has reached 32 MiB. A platform cap keeps memory/temp overhead sane.
const DYNAMIC_CHUNK_MIN_SIZE: int = 1 * 1024 * 1024
const DYNAMIC_CHUNK_STEP: int = 512 * 1024
const DYNAMIC_CHUNK_TARGET_MAX: int = 256
const DYNAMIC_CHUNK_ABS_MAX: int = 4096
const DYNAMIC_CHUNK_LARGE_THRESHOLD: int = 32 * 1024 * 1024
const DYNAMIC_CHUNK_MAX_DESKTOP: int = 32 * 1024 * 1024
const DYNAMIC_CHUNK_MAX_ANDROID: int = 16 * 1024 * 1024

# Per-file chunk concurrency caps for each download speed profile.
# Index matches download_speed_profile value (Conservative=0, Balanced=1, Fast=2, Unrestricted=3).
const MAX_CONCURRENT_CHUNKS_PROFILES: Array[int] = [2, 4, 6, 10]
const MAX_CONCURRENT_CHUNKS_ANDROID_PROFILES: Array[int] = [1, 2, 3, 4]

# Overall concurrent downloads for each profile. Keep Android conservative.
const MAX_CONCURRENT_DOWNLOADS_PROFILES: Array[int] = [2, 4, 6, 8]
const MAX_CONCURRENT_DOWNLOADS_ANDROID_PROFILES: Array[int] = [1, 2, 3, 4]

# In-place assembly writes chunks directly into the final sparse file at the
# correct offset, eliminating the post-download reassembly pass.
# Disabled on Android because external storage often lacks sparse-file support.
const IN_PLACE_CHUNKED_DOWNLOADS: bool = true

# Chunk retry / timeout settings
const MAX_CHUNK_RETRIES: int = 5
const CHUNK_REQUEST_TIMEOUT_MS: int = 20 * 1000  # time to finish request headers
const CHUNK_STALL_TIMEOUT_MS: int = 15 * 1000   # no bytes received
const CHUNK_FALLBACK_TO_SINGLE_STREAM: bool = true
const CHUNK_MAX_TOTAL_TIME_MS: int = 10 * 60 * 1000  # Hard ceiling per chunk (10 min)
const CHUNK_WATCHDOG_INTERVAL_SEC: float = 10.0

# Polling interval for HTTPClient (2 seconds between polls when no data)
const POLLING_INTERVAL_MS: int = 100

# Per-download resume state file (sidecar next to destination)
const DOWNLOAD_STATE_VERSION: int = 1
const DOWNLOAD_STATE_SUFFIX: String = ".kyodai_download"
const DOWNLOAD_PARTIAL_SUFFIX: String = ".kyodai_partial"

## Calculates an adaptive chunk size similar to copyparty's up2k client.
## Starts at 1 MiB and grows by 512 KiB until the file fits in <=256 chunks.
## Once the chunk size reaches 32 MiB we allow up to 4096 chunks.
## A platform cap prevents excessive temp-file/memory overhead.
func _get_chunksize(file_size: int) -> int:
	if file_size <= 0:
		return DYNAMIC_CHUNK_MIN_SIZE

	var chunk_size = DYNAMIC_CHUNK_MIN_SIZE
	var step = DYNAMIC_CHUNK_STEP
	while true:
		for mul in [1, 2]:
			var nchunks = ceili(float(file_size) / float(chunk_size))
			if nchunks <= DYNAMIC_CHUNK_TARGET_MAX:
				return chunk_size
			if chunk_size >= DYNAMIC_CHUNK_LARGE_THRESHOLD and nchunks <= DYNAMIC_CHUNK_ABS_MAX:
				return chunk_size
			chunk_size += step
			step *= mul
			# Apply platform cap so we don't keep searching forever
			var cap = DYNAMIC_CHUNK_MAX_ANDROID if PlatformManager.is_android() else DYNAMIC_CHUNK_MAX_DESKTOP
			chunk_size = mini(chunk_size, cap)
			if chunk_size >= cap and nchunks <= DYNAMIC_CHUNK_ABS_MAX:
				return chunk_size
			if chunk_size >= cap:
				return cap

	# Unreachable, but keeps the static analyzer happy
	return DYNAMIC_CHUNK_MIN_SIZE

## Calculates chunk size and concurrency for a given file size.
func _calculate_chunk_strategy(file_size: int) -> Dictionary:
	var thread_count = MemoryManager.get_download_thread_count()
	var max_concurrent = _get_max_chunk_concurrency()
	var concurrency = mini(thread_count, max_concurrent)

	var chunk_size = _get_chunksize(file_size)
	var num_chunks = ceili(float(file_size) / float(chunk_size))

	print("[DownloadManager] Chunk strategy for %d bytes: %d chunks x %d bytes (concurrency=%d, threads=%d)" % [
		file_size, num_chunks, chunk_size, concurrency, thread_count
	])

	return {
		"chunk_size": chunk_size,
		"num_chunks": num_chunks,
		"concurrency": concurrency,
		"thread_count": thread_count
	}

# Chunked download tracking
var _chunked_downloads: Dictionary = {}  # item_id -> ChunkedDownloadInfo

# Final copy progress for temp-dir in-place assembly (Android)
var _final_copy_progress: Dictionary = {}  # item_id -> float

# Coalesce state-file writes: save at most once per interval and on important events.
var _state_file_dirty: Dictionary = {}  # item_id -> bool
var _state_file_last_save_ms: Dictionary = {}  # item_id -> int
const STATE_FILE_SAVE_INTERVAL_MS: int = 2500

class ChunkedDownloadInfo:
	var item: QueueItem
	var chunks: Array[ChunkInfo] = []
	var chunks_completed: int = 0
	var total_chunks: int = 0
	var concurrency: int = 0  # Active chunk concurrency for this download
	var temp_dir: String = ""
	var final_path: String = ""
	var partial_path: String = ""
	var use_chunking: bool = false
	var in_place_assembly: bool = false  # Write chunks directly to a sparse partial file
	var final_file_mutex: Mutex = null  # Serializes writes to the partial file (if shared handle)
	var active_downloads: int = 0
	var download_callback: Callable
	var progress_timer: Timer = null  # Timer for polling chunk progress
	var last_progress_update: float = 0.0  # Last progress value to reduce emissions
	var headers: Array = []
	var start_time_ms: int = 0
	var watchdog_timer: Timer = null
	var watchdog_last_total_bytes: int = 0
	var watchdog_last_progress_time_ms: int = 0

class ChunkInfo:
	var index: int
	var start_byte: int
	var end_byte: int
	var original_start_byte: int  # Unchanged start for resume on retry
	var temp_path: String
	var completed: bool = false
	var failed: bool = false
	var in_progress: bool = false
	var retry_count: int = 0  # Track retry attempts
	var temp_bytes_downloaded: int = 0  # Track bytes during download for real-time progress
	# Integrity / resume state (copyparty-style)
	var expected_hash: String = ""  # Expected SHA-256 of the chunk data
	var actual_hash: String = ""    # SHA-256 computed after the chunk is written
	var coolmul: float = 0.5        # Exponential backoff multiplier
	var cooldown_until_ms: int = 0  # Absolute time (ticks_msec) before retry

# ============================================================================
# DOWNLOAD STATE FILE (chunk bitmap for resume)
# ============================================================================

func _get_state_file_path(destination_path: String) -> String:
	return destination_path + DOWNLOAD_STATE_SUFFIX

func _get_partial_file_path(destination_path: String) -> String:
	return destination_path + DOWNLOAD_PARTIAL_SUFFIX

## Creates a sparse file of the given size on supported filesystems.
## Returns true if the file was created and sized successfully.
## On Windows this uses fsutil; on Linux/macOS it relies on seek+write holes.
func _create_sparse_file(path: String, size: int) -> bool:
	if size <= 0:
		return false

	# Ensure parent directory exists
	var parent_dir = path.get_base_dir()
	if not FSM.dir_exists(parent_dir):
		if not FSM.make_dir_recursive(parent_dir):
			push_error("[DownloadManager] Failed to create destination directory: " + parent_dir)
			return false

	# Create (or truncate) the destination file
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[DownloadManager] Failed to create destination file: " + path)
		return false
	file.close()

	if PlatformManager.is_windows():
		var native_path = FSM.resolve_native_path(path)
		var exit_code = OS.execute("fsutil", ["sparse", "setflag", native_path, "1"])
		if exit_code != 0:
			push_error("[DownloadManager] fsutil sparse setflag failed for: " + native_path)
			return false
		exit_code = OS.execute("fsutil", ["file", "seteof", native_path, str(size)])
		if exit_code != 0:
			push_error("[DownloadManager] fsutil file seteof failed for: " + native_path)
			return false
	else:
		# On Linux/macOS/Android, seeking past EOF and writing creates a sparse
		# hole on filesystems that support it (ext4, btrfs, apfs, etc.).
		file = FileAccess.open(path, FileAccess.WRITE_READ)
		if file == null:
			push_error("[DownloadManager] Failed to open destination file for sizing: " + path)
			return false
		file.seek(size - 1)
		file.store_8(0)
		file.close()

		# Probe whether the filesystem actually stored the file sparsely.
		# If it allocated the whole file (e.g. FAT32/exFAT), sparse assembly
		# would waste disk space, so fall back to sequential temp-file reassembly.
		var native_path = FSM.resolve_native_path(path)
		var stat_args = ["-c", "%b %B", native_path]
		if PlatformManager.is_macos():
			stat_args = ["-f", "%b %B", native_path]
		var output: Array = []
		var exit_code = OS.execute("stat", stat_args, output, true)
		if exit_code == 0 and output.size() > 0:
			var parts = output[0].strip_edges().split(" ")
			if parts.size() >= 2:
				var blocks = int(parts[0])
				var block_size = int(parts[1])
				var allocated = blocks * block_size
				# Sparse filesystems should allocate only a few blocks for the
				# one-byte probe. If the allocation is a large fraction of the
				# logical size, assume sparse files are not supported.
				# Use a floor of 64 KiB so that normal single-block allocation on
				# sparse filesystems does not trigger the fallback.
				var threshold = maxi(64 * 1024, size / 2)
				if block_size > 0 and allocated > threshold:
					push_error("[DownloadManager] Filesystem does not appear to support sparse files: " + path + " (allocated " + str(allocated) + " bytes for " + str(size) + " byte file)")
					FSM.delete_file(path)
					return false
		else:
			push_warning("[DownloadManager] Could not probe filesystem sparse support for: " + path)

	# Verify the file reached the expected logical size
	if not FSM.file_exists(path):
		return false
	var actual_size = FSM.get_file_size(path)
	if actual_size != size:
		push_error("[DownloadManager] Sparse file size mismatch: expected " + str(size) + ", got " + str(actual_size))
		return false

	return true

func _delete_download_state(destination_path: String) -> void:
	var state_path = _get_state_file_path(destination_path)
	if FSM.file_exists(state_path):
		if not FSM.delete_file(state_path):
			push_error("[DownloadManager] Failed to remove state file: " + state_path)

## Loads a previously saved chunk state file, if it is valid for this URL/size/strategy.
func _load_download_state(destination_path: String, url: String, file_size: int) -> Dictionary:
	var state_path = _get_state_file_path(destination_path)
	if not FSM.file_exists(state_path):
		return {}

	var text = FSM.read_file_bytes(state_path).get_string_from_utf8()
	if text.is_empty():
		push_error("[DownloadManager] Could not read state file: " + state_path)
		return {}

	var json = JSON.new()
	if json.parse(text) != OK:
		push_error("[DownloadManager] Corrupt state file, ignoring: " + state_path)
		return {}

	var data = json.data
	if not (data is Dictionary):
		return {}

	if int(data.get("version", 0)) != DOWNLOAD_STATE_VERSION:
		return {}
	if data.get("url", "") != url:
		return {}
	if int(data.get("file_size", 0)) != file_size:
		return {}

	var strategy = _calculate_chunk_strategy(file_size)
	if int(data.get("chunk_size", 0)) != strategy.chunk_size or int(data.get("num_chunks", 0)) != strategy.num_chunks:
		return {}

	return data

## Applies a loaded state dictionary to a freshly created ChunkedDownloadInfo.
func _apply_download_state(chunked_info: ChunkedDownloadInfo, state: Dictionary) -> void:
	if state.is_empty():
		return

	var chunks_data = state.get("chunks", [])
	if not (chunks_data is Array):
		return

	for chunk_state in chunks_data:
		if not (chunk_state is Dictionary):
			continue
		var idx = int(chunk_state.get("index", -1))
		if idx < 0 or idx >= chunked_info.chunks.size():
			continue

		var chunk = chunked_info.chunks[idx]
		chunk.expected_hash = chunk_state.get("expected_hash", "")
		chunk.actual_hash = chunk_state.get("actual_hash", "")
		chunk.retry_count = int(chunk_state.get("retry_count", 0))
		chunk.coolmul = float(chunk_state.get("coolmul", 0.5))
		chunk.cooldown_until_ms = int(chunk_state.get("cooldown_until_ms", 0))

		var status = chunk_state.get("status", "pending")
		if status == "complete":
			var expected_size = chunk.end_byte - chunk.start_byte + 1
			var verified = false

			if chunked_info.in_place_assembly:
				# For sparse in-place assembly, verify the chunk range in the partial file.
				if FileAccess.file_exists(chunked_info.partial_path):
					var partial_file = FileAccess.open(chunked_info.partial_path, FileAccess.READ)
					if partial_file != null:
						var partial_size = partial_file.get_length()
						if partial_size == chunked_info.item.expected_file_size:
							partial_file.seek(chunk.start_byte)
							var hasher = HashingContext.new()
							hasher.start(HashingContext.HASH_SHA256)
							var remaining = expected_size
							while remaining > 0:
								var read_size = mini(remaining, 1024 * 1024)
								var buf = partial_file.get_buffer(read_size)
								if buf.size() == 0:
									break
								hasher.update(buf)
								remaining -= buf.size()
							partial_file.close()

							if remaining <= 0:
								var disk_hash = hasher.finish().hex_encode()
								var expected = chunk.actual_hash if not chunk.actual_hash.is_empty() else chunk.expected_hash
								if expected.is_empty() or disk_hash == expected:
									verified = true
								else:
									print("[DownloadManager] Resume hash mismatch for chunk " + str(chunk.index) + ", will re-download")
						else:
							partial_file.close()
			else:
				# Trust the state only if the temp file is actually present and the right size.
				if FileAccess.file_exists(chunk.temp_path):
					var f = FileAccess.open(chunk.temp_path, FileAccess.READ)
					if f != null:
						var actual_size = f.get_length()
						f.close()
						if actual_size == expected_size:
							verified = true

			if verified:
				chunk.completed = true
				chunked_info.chunks_completed += 1

## Persists the current chunk bitmap so resume can continue after a crash/kill.
func _save_download_state(chunked_info: ChunkedDownloadInfo, force: bool = false) -> void:
	if chunked_info == null or chunked_info.item == null:
		return

	var item_id = chunked_info.item.id
	var now = Time.get_ticks_msec()
	var last_save = _state_file_last_save_ms.get(item_id, 0)

	if not force and (now - last_save) < STATE_FILE_SAVE_INTERVAL_MS:
		_state_file_dirty[item_id] = true
		return

	_state_file_dirty[item_id] = false
	_state_file_last_save_ms[item_id] = now

	var state_path = _get_state_file_path(chunked_info.final_path)
	var chunks_data: Array = []
	for chunk in chunked_info.chunks:
		var status = "pending"
		if chunk.completed:
			status = "complete"
		elif chunk.failed:
			status = "failed"
		elif chunk.in_progress:
			status = "downloading"
		chunks_data.append({
			"index": chunk.index,
			"start_byte": chunk.start_byte,
			"end_byte": chunk.end_byte,
			"status": status,
			"expected_hash": chunk.expected_hash,
			"actual_hash": chunk.actual_hash,
			"retry_count": chunk.retry_count,
			"coolmul": chunk.coolmul,
			"cooldown_until_ms": chunk.cooldown_until_ms
		})

	var data = {
		"version": DOWNLOAD_STATE_VERSION,
		"url": chunked_info.item.url,
		"destination_path": chunked_info.final_path,
		"file_size": chunked_info.item.expected_file_size,
		"chunk_size": chunked_info.chunks[0].end_byte - chunked_info.chunks[0].start_byte + 1 if not chunked_info.chunks.is_empty() else 0,
		"num_chunks": chunked_info.total_chunks,
		"chunks": chunks_data
	}

	if not FSM.write_file(state_path, JSON.stringify(data)):
		push_error("[DownloadManager] Failed to write state file: " + state_path)

## Flush any pending state-file write for the given item. Call before cleanup or
## any event where resume state must be persisted immediately.
func _flush_download_state(item_id: String) -> void:
	if _state_file_dirty.get(item_id, false):
		if _chunked_downloads.has(item_id):
			_save_download_state(_chunked_downloads[item_id], true)
		_state_file_dirty.erase(item_id)

# Foreground service tracking for Android
var _foreground_service_active: bool = false
var _active_download_count: int = 0

# Connection pool for chunked downloads - per-thread persistent connections
# Reduces TLS handshakes by reusing connections across chunks
var _download_connection_pools: Dictionary = {}  # item_id -> Array[HTTPClient] (one per active slot)
var _connection_pool_mutex: Mutex = Mutex.new()

# Concurrency limiter for chunked downloads (per download)
var _chunk_concurrency_semaphores: Dictionary = {}  # item_id -> Semaphore

# Track per-thread chunk completion times for debugging connection reuse
var _thread_chunk_finish_times: Dictionary = {}  # "item_id_thread_index" -> finish_time_msec

func _ready():
	_update_concurrency_from_settings()
	if SettingsManager:
		SettingsManager.setting_changed.connect(_on_setting_changed)

func _on_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "download_speed_profile":
		_update_concurrency_from_settings()

func _update_concurrency_from_settings() -> void:
	var profile_index := 1  # Default to Balanced
	if SettingsManager and SettingsManager.settings:
		var setting = SettingsManager.get_setting("download_speed_profile")
		if setting and setting.value is int:
			profile_index = clampi(setting.value, 0, 3)

	var is_android := PlatformManager.is_android()
	var chunk_caps: Array[int] = MAX_CONCURRENT_CHUNKS_ANDROID_PROFILES if is_android else MAX_CONCURRENT_CHUNKS_PROFILES
	var download_caps: Array[int] = MAX_CONCURRENT_DOWNLOADS_ANDROID_PROFILES if is_android else MAX_CONCURRENT_DOWNLOADS_PROFILES

	_max_concurrent = download_caps[profile_index]
	print("[DownloadManager] Speed profile '%s': max_concurrent=%d, max_chunk_concurrency=%d" % [
		_get_speed_profile_name(profile_index), _max_concurrent, chunk_caps[profile_index]
	])

func _get_speed_profile_name(profile_index: int) -> String:
	match profile_index:
		0: return "Conservative"
		1: return "Balanced"
		2: return "Fast"
		3: return "Unrestricted"
	return "Balanced"

func _get_max_chunk_concurrency() -> int:
	var profile_index := 1
	if SettingsManager and SettingsManager.settings:
		var setting = SettingsManager.get_setting("download_speed_profile")
		if setting and setting.value is int:
			profile_index = clampi(setting.value, 0, 3)
	var caps: Array[int] = MAX_CONCURRENT_CHUNKS_ANDROID_PROFILES if PlatformManager.is_android() else MAX_CONCURRENT_CHUNKS_PROFILES
	return caps[profile_index]

## Starts the Android foreground service to prevent app kill during downloads
func _start_foreground_service(game_name: String = "Game"):
	if _active_download_count == 0:
		print("[DownloadManager] Starting foreground service for download: " + game_name)
		if PlatformManager.start_download_foreground_service(game_name):
			_foreground_service_active = true

	_active_download_count += 1
	print("[DownloadManager] Active downloads: " + str(_active_download_count))

## Updates the foreground service notification with progress
func _update_foreground_service(game_name: String, progress: int):
	if _foreground_service_active:
		PlatformManager.update_download_foreground_service(game_name, progress)

## Stops the Android foreground service when downloads complete
func _stop_foreground_service():
	_active_download_count = max(0, _active_download_count - 1)

	if _active_download_count == 0 and _foreground_service_active:
		print("[DownloadManager] Stopping foreground service")
		if PlatformManager.stop_download_foreground_service():
			_foreground_service_active = false
		# Restore normal CPU mode on Android
		if PlatformManager.is_android():
			OS.set_low_processor_usage_mode(false)
			print("[DownloadManager] Disabled low processor mode")

## Queues a download with optional auto-extraction
## delete_after_extract: If true, deletes the archive after successful extraction (default: true for emulator_core type)
## Returns the item ID or empty string if failed
func queue_download(url: String, destination: String, type: String = "file", item_name: String = "", auto_extract: bool = false, extract_dir: String = "", game: GameResource = null, callbacks: Dictionary = {}, romm_id: int = 0, delete_after_extract: bool = true, suppress_notification: bool = false, expected_file_size: int = 0, update_game_resource: bool = true) -> String:
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
	item.name = item_name if item_name != "" else item_id
	item.auto_extract = auto_extract
	item.game_resource = game
	item.callbacks = callbacks
	item.romm_id = romm_id if romm_id != 0 else (game.romm_id if game else 0)
	item.delete_after_extract = delete_after_extract
	item.suppress_notification = suppress_notification
	item.update_game_resource = update_game_resource

	# Store expected file size for progress tracking
	item.expected_file_size = expected_file_size
	if game:
		item.expected_file_size = game.get_active_file_size()

	# Set extract_dir and ensure destination directory exists
	item.extract_dir = extract_dir if extract_dir != "" else destination.get_base_dir()
	var dest_dir = destination.get_base_dir()

	if not FSM.make_dir_recursive(dest_dir):
		push_error("[DownloadManager] Failed to create directory: " + dest_dir)
		return ""

	_queue.append(item)

	queue_changed.emit()
	_process_queue()

	return item_id

## Queues an extraction task (for already-downloaded archives)
## delete_after_extract: If true, deletes the archive after successful extraction (default: true)
## suppress_notification: If true, skips showing extraction notifications (for batch operations)
func queue_extraction(archive_path: String, extract_dir: String, type: String = "archive", item_name: String = "", delete_after_extract: bool = true, suppress_notification: bool = false) -> String:
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
	item.name = item_name if item_name != "" else "Archive"
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
		# Clean up chunked download resources if this was a chunked download
		_cleanup_chunked_download(item_id)
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

	# Initialize unified progress tracking
	var prog = DownloadProgress.new()
	prog.start_time_ms = Time.get_ticks_msec()
	prog.last_progress_time_ms = prog.start_time_ms
	prog.last_downloaded_bytes = 0
	_download_progress[item.id] = prog

	# Show notification with progress (unless suppressed for batch downloads)
	if not item.suppress_notification:
		if item.expected_file_size > 0:
			item.notification_id = NotificationManager.show_notification(
				item.name + "...",
				NotificationManager.Type.INFO,
				null,
				0.0,
				func() -> float:
					return item.progress,
				func(progress: float) -> String:
					var mb_downloaded = int(item.expected_file_size * progress / (1024.0 * 1024.0))
					var mb_total = int(item.expected_file_size / (1024.0 * 1024.0))
					return "%s: %d/%d MB (%d%%)" % [item.name, mb_downloaded, mb_total, int(progress * 100)]
			)
		else:
			# No expected file size - use pulsing notification
			item.notification_id = NotificationManager.show_notification(
				item.name + "...",
				NotificationManager.Type.INFO,
				null,
				0.0,
				Callable(),
				Callable(),
				true  # pulsing
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
	# NOTE: Emulator downloads excluded from chunking because GitHub redirects (302)
	# break the HTTPClient-based chunk downloader. http_download_file handles redirects.
	var is_large_file = item.type == "game" or item.type == "emulator_core"
	var should_use_chunking = is_large_file and item.expected_file_size > CHUNKED_DOWNLOAD_THRESHOLD

	if should_use_chunking:
		print("[DownloadManager] Checking Range support for chunked download: " + item.name + " (size=" + str(item.expected_file_size) + ")")
		_check_range_and_start_chunked(item, headers)
		return

	# All downloads now stream directly to disk via HTTPRequest.download_file
	# This avoids memory issues with large files (games, emulators, cores)
	print("[DownloadManager] Using file-based download for: " + item.name + " (type=" + item.type + ")")
	print("[DownloadManager] Destination path: " + item.destination_path)
	item.download_info = NetworkManager.http_download_file(
		item.url,
		item.destination_path,
		headers,
		func(success: bool, _status_code: int, error_msg: String):
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

	# Setup progress timer - poll frequently for smooth UI updates
	# 0.5s provides responsive progress without excessive CPU/disk overhead
	var poll_interval = 0.5
	var progress = _download_progress[item.id] as DownloadProgress
	progress.timer = Timer.new()
	progress.timer.wait_time = poll_interval
	progress.timer.autostart = true
	add_child(progress.timer)

	progress.timer.timeout.connect(func():
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

## Closes an HTTPClient and clears it from the connection pool so retries get a fresh connection
func _invalidate_pool_connection(http: HTTPClient, item_id: String, thread_index: int):
	if http != null:
		http.close()

	_connection_pool_mutex.lock()
	if _download_connection_pools.has(item_id):
		var pool = _download_connection_pools[item_id]
		if thread_index >= 0 and thread_index < pool.size():
			pool[thread_index] = null
	_connection_pool_mutex.unlock()

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
	NetworkManager.check_range_support(item.url, headers, func(supports_range: bool, _error_msg: String, content_length: int = 0):
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
			func(success: bool, _status_code: int, err: String):
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
			var progress2 = _download_progress.get(item.id) as DownloadProgress
			if progress2 == null:
				progress2 = DownloadProgress.new()
				progress2.start_time_ms = Time.get_ticks_msec()
				progress2.last_progress_time_ms = progress2.start_time_ms
				progress2.last_downloaded_bytes = 0
				_download_progress[item.id] = progress2
			progress2.timer = Timer.new()
			progress2.timer.wait_time = 1.0
			progress2.timer.autostart = true
			add_child(progress2.timer)

			progress2.timer.timeout.connect(func():
				_update_download_progress(item)
				_check_download_timeout(item.id)
			)
	)

func _get_chunk_temp_dir_name(destination_path: String) -> String:
	"""Returns a deterministic temp directory name based on the destination path.
	This lets resumed downloads find the same partial file across app restarts."""
	var safe = destination_path.replace("/", "_").replace("\\", "_").replace(":", "_")
	# Trim leading/trailing underscores for cleanliness
	while safe.begins_with("_"):
		safe = safe.substr(1)
	while safe.ends_with("_"):
		safe = safe.substr(0, safe.length() - 1)
	return safe

func _start_chunked_download(item: QueueItem, headers: Array):
	"""Start a chunked download using parallel threads"""
	var file_size = item.expected_file_size

	# Use dynamic chunk strategy based on file size and thread count
	var strategy = _calculate_chunk_strategy(file_size)
	var chunk_size = strategy.chunk_size
	var num_chunks = strategy.num_chunks
	var concurrency = strategy.concurrency
	var thread_count = strategy.thread_count

	# Create temp directory for chunks (deterministic so resume can find it)
	var temp_dir = "user://downloads/chunks/" + _get_chunk_temp_dir_name(item.destination_path)
	if not FSM.make_dir_recursive(temp_dir):
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
	chunked_info.concurrency = concurrency
	chunked_info.use_chunking = true

	# Decide whether to use in-place assembly.
	# Desktop: create a sparse partial next to the destination.
	# Android: always stream into a partial in the temp dir, then copy/move it
	# to the destination. This avoids the blocking native reassembly step.
	var in_place_assembly = false
	if IN_PLACE_CHUNKED_DOWNLOADS:
		if PlatformManager.is_android():
			chunked_info.partial_path = temp_dir + "/partial"
			in_place_assembly = true
			print("[DownloadManager] Using Android temp-dir in-place assembly for: " + item.name)
		else:
			chunked_info.partial_path = _get_partial_file_path(item.destination_path)
			var state_path = _get_state_file_path(item.destination_path)
			var has_state = FSM.file_exists(state_path)
			var has_partial = FSM.file_exists(chunked_info.partial_path)
			var partial_ok = false

			if not has_state or not has_partial:
				# No valid resume state; start fresh and remove stale artifacts
				if FSM.file_exists(chunked_info.partial_path):
					FSM.delete_file(chunked_info.partial_path)
				if FSM.file_exists(item.destination_path):
					FSM.delete_file(item.destination_path)
			elif has_partial:
				# Resume: keep an existing partial file only if it has the expected size.
				var partial_size = FSM.get_file_size(chunked_info.partial_path)
				if partial_size == file_size:
					partial_ok = true
				else:
					push_error("[DownloadManager] Existing partial file size mismatch (" + str(partial_size) + " vs " + str(file_size) + "); restarting sparse file")
					FSM.delete_file(chunked_info.partial_path)

			if partial_ok:
				in_place_assembly = true
				print("[DownloadManager] Resuming in-place sparse assembly for: " + item.name)
			elif _create_sparse_file(chunked_info.partial_path, file_size):
				in_place_assembly = true
				print("[DownloadManager] Using in-place sparse assembly for: " + item.name)
			else:
				print("[DownloadManager] In-place sparse assembly not available, using temp files for: " + item.name)
				if FSM.file_exists(chunked_info.partial_path):
					FSM.delete_file(chunked_info.partial_path)
	else:
		chunked_info.partial_path = _get_partial_file_path(item.destination_path)

	chunked_info.in_place_assembly = in_place_assembly
	if in_place_assembly:
		chunked_info.final_file_mutex = Mutex.new()

	# Create chunk infos
	for i in range(num_chunks):
		var chunk = ChunkInfo.new()
		chunk.index = i
		chunk.start_byte = i * chunk_size
		chunk.original_start_byte = chunk.start_byte
		chunk.end_byte = mini((i + 1) * chunk_size - 1, file_size - 1)
		chunk.temp_path = temp_dir + "/chunk_" + str(i) + ".tmp"
		chunked_info.chunks.append(chunk)

	_chunked_downloads[item.id] = chunked_info
	chunked_info.headers = headers
	chunked_info.start_time_ms = Time.get_ticks_msec()

	# Load any existing resume state and skip already-complete chunks
	var state = _load_download_state(item.destination_path, item.url, file_size)
	if not state.is_empty():
		print("[DownloadManager] Resuming download from state file for: " + item.name + " (" + str(state.get("chunks", []).size()) + " chunks recorded)")
	_apply_download_state(chunked_info, state)
	_save_download_state(chunked_info, true)

	# On Android, a fresh download should not inherit a stale temp partial.
	# (Resume state would have been applied above if it were valid.)
	if PlatformManager.is_android():
		if state.is_empty():
			if FSM.file_exists(chunked_info.partial_path):
				FSM.delete_file(chunked_info.partial_path)
			# Also remove any leftover legacy chunk temp files
			for chunk in chunked_info.chunks:
				if FSM.file_exists(chunk.temp_path):
					FSM.delete_file(chunk.temp_path)

		# Ensure the partial file exists so worker threads can open it READ_WRITE.
		# Only create it when missing; on resume the existing partial is preserved.
		if not FSM.file_exists(chunked_info.partial_path):
			var partial_create = FileAccess.open(chunked_info.partial_path, FileAccess.WRITE)
			if partial_create:
				partial_create.close()
			else:
				push_error("[DownloadManager] Failed to create Android partial file: " + chunked_info.partial_path)
				item.status = "failed"
				item.error_message = "Failed to create partial file"
				_cleanup_item(item)
				_active_items.erase(item.id)
				download_completed.emit(item.id, false, item.error_message)
				queue_changed.emit()
				_process_queue()
				return

	# Initialize per-download concurrency semaphore and connection pool
	var chunk_sem = Semaphore.new()
	for _i in range(concurrency):
		chunk_sem.post()
	_chunk_concurrency_semaphores[item.id] = chunk_sem

	var connection_pool: Array[HTTPClient] = []
	connection_pool.resize(concurrency)
	_connection_pool_mutex.lock()
	_download_connection_pools[item.id] = connection_pool
	_connection_pool_mutex.unlock()

	print("[DownloadManager] Starting chunked download with " + str(num_chunks) + " chunks for: " + item.name)
	print("[DownloadManager] Using concurrency=" + str(concurrency) + " (thread pool=" + str(thread_count) + ")")

	# If every chunk is already complete on disk, go straight to verification/reassembly
	if chunked_info.chunks_completed >= chunked_info.total_chunks:
		print("[DownloadManager] All chunks already present on disk for: " + item.name)
		_on_all_chunks_complete(item.id, headers, {})
		return

	# Queue only pending chunks to the download thread pool
	# The semaphore ensures at most `concurrency` chunks are active at once
	var chunk_items = []
	for i in range(num_chunks):
		if chunked_info.chunks[i].completed:
			continue
		var thread_index = i % concurrency
		chunk_items.append({
			"item_id": item.id,
			"chunk_index": i,
			"url": item.url,
			"temp_path": chunked_info.chunks[i].temp_path,
			"partial_path": chunked_info.partial_path,
			"write_offset": chunked_info.chunks[i].start_byte,
			"in_place": chunked_info.in_place_assembly,
			"final_file_mutex": chunked_info.final_file_mutex,
			"start_byte": chunked_info.chunks[i].start_byte,
			"end_byte": chunked_info.chunks[i].end_byte,
			"original_start_byte": chunked_info.chunks[i].original_start_byte,
			"expected_hash": chunked_info.chunks[i].expected_hash,
			"headers": headers,
			"thread_index": thread_index
		})

	print("[DownloadManager] Queuing " + str(chunk_items.size()) + " pending chunks to thread pool for: " + item.name)

	# Start a watchdog that detects stuck chunk workers and falls back to single-stream.
	_start_chunked_watchdog_timer(item.id, headers)

	# Use MemoryManager's download thread pool
	await MemoryManager.queue_parallel_downloads(
		chunk_items,
		func(chunk_data, _index):
			chunk_sem.wait()
			var result = _download_chunk_on_thread(chunk_data)
			chunk_sem.post()
			return result,
		func(_completed, _total, batch_index, result):
			var chunk_index = result.get("chunk_index", batch_index) if result is Dictionary else batch_index
			_update_chunk_download_progress(item.id, chunk_index, result),
		func(_results):
			_on_all_chunks_complete(item.id, headers, _results)
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
## Downloads a single chunk on a worker thread using HTTPClient.
## Returns a result dictionary with success, hashes, and retry hints.
## Called by the thread pool - runs on a background thread.
func _download_chunk_on_thread(chunk_data: Dictionary) -> Dictionary:
	var url = chunk_data.url
	var temp_path = chunk_data.temp_path
	var in_place = chunk_data.get("in_place", false)
	var partial_path = chunk_data.get("partial_path", "") as String
	var write_offset = chunk_data.get("write_offset", 0) as int
	var final_file_mutex = chunk_data.get("final_file_mutex", null)
	var start_byte = chunk_data.start_byte
	var end_byte = chunk_data.end_byte
	var original_start_byte = chunk_data.get("original_start_byte", start_byte) as int
	var expected_hash = chunk_data.get("expected_hash", "") as String
	var headers = chunk_data.headers
	var chunk_index = chunk_data.chunk_index
	var item_id = chunk_data.item_id
	var thread_index = chunk_data.thread_index

	var result = {
		"success": false,
		"chunk_index": chunk_index,
		"actual_hash": "",
		"expected_hash": expected_hash,
		"bytes_downloaded": 0,
		"should_delete_partial": false,
		"error": ""
	}

	var expected_chunk_size = end_byte - original_start_byte + 1
	var chunk_start_time = Time.get_ticks_msec()
	var chunk_deadline_ms = chunk_start_time + CHUNK_MAX_TOTAL_TIME_MS
	print("[DownloadManager] [DEBUG] Starting chunk " + str(chunk_index) + " on thread " + str(thread_index) + " at time=" + str(chunk_start_time))

	# Parse URL to get components
	var url_parts = NetworkManager.parse_url(url)

	# Get or create connection from pool (thread-safe access)
	var http: HTTPClient
	var was_reused = false

	_connection_pool_mutex.lock()
	if _download_connection_pools.has(item_id):
		var connection_pool = _download_connection_pools[item_id]
		if thread_index < connection_pool.size():
			http = connection_pool[thread_index]
			var status_before = http.get_status() if http != null else -1
			print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " connection status before check: " + str(status_before) + " (CONNECTED=" + str(HTTPClient.STATUS_CONNECTED) + ")")

			# Check for previous chunk finish time to calculate idle time
			var idle_thread_key = item_id + "_" + str(thread_index)
			var prev_finish_time = _thread_chunk_finish_times.get(idle_thread_key, 0)
			if prev_finish_time > 0:
				var idle_time = chunk_start_time - prev_finish_time
				print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " idle time between chunks: " + str(idle_time) + "ms")

			# Check if connection is still valid WITHOUT creating a new one under lock
			var needs_new_connection = not _is_connection_valid(http)
			if not needs_new_connection:
				was_reused = true
				print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " reusing connection (status=" + str(http.get_status()) + ") for chunk " + str(chunk_index))
			_connection_pool_mutex.unlock()

			# Create connection OUTSIDE the mutex to avoid blocking other threads during TCP/TLS handshake
			if needs_new_connection:
				print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " connection invalid, creating new for chunk " + str(chunk_index))
				http = _create_connection(url_parts)
				if http != null:
					_connection_pool_mutex.lock()
					connection_pool[thread_index] = http
					_connection_pool_mutex.unlock()
					print("[DownloadManager] [DEBUG] Thread " + str(thread_index) + " created new connection (status=" + str(http.get_status()) + ")")
		else:
			push_error("[DownloadManager] Thread index out of bounds: " + str(thread_index))
			_connection_pool_mutex.unlock()
			result.error = "Thread index out of bounds"
			return result
	else:
		push_error("[DownloadManager] No connection pool found for item: " + item_id)
		_connection_pool_mutex.unlock()
		result.error = "No connection pool"
		return result

	if http == null:
		push_error("[DownloadManager] Failed to get/create connection for chunk " + str(chunk_index))
		result.error = "Failed to get/create connection"
		return result

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

	# Set up SHA-256 hasher for this chunk
	var hasher = HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)

	# Partial chunk resume: if a partial file exists, hash existing bytes and resume from its end
	var bytes_downloaded = 0
	var resume_offset = 0
	var file: FileAccess = null

	# In-place assembly does not resume within a chunk; pending chunks are re-downloaded whole.
	if not in_place and FileAccess.file_exists(temp_path):
		var partial_file = FileAccess.open(temp_path, FileAccess.READ)
		if partial_file:
			var partial_size = partial_file.get_length()
			partial_file.close()
			if partial_size >= expected_chunk_size:
				# Already complete on disk; just verify/hash it and return
				var hash_file = FileAccess.open(temp_path, FileAccess.READ)
				if hash_file:
					var remaining = partial_size
					while remaining > 0:
						var buf = hash_file.get_buffer(mini(remaining, 1024 * 1024))
						hasher.update(buf)
						remaining -= buf.size()
					hash_file.close()
				var actual_hash = hasher.finish().hex_encode()
				result.actual_hash = actual_hash
				result.bytes_downloaded = partial_size

				if not expected_hash.is_empty() and actual_hash != expected_hash:
					# Existing file is corrupt; force a re-download
					result.success = false
					result.should_delete_partial = true
					result.error = "Hash mismatch on existing complete chunk"
					print("[DownloadManager] Chunk " + str(chunk_index) + " existing file hash mismatch, will re-download")
					return result

				result.success = true
				result.expected_hash = expected_hash if not expected_hash.is_empty() else actual_hash
				var thread_key = item_id + "_" + str(thread_index)
				_connection_pool_mutex.lock()
				_thread_chunk_finish_times[thread_key] = Time.get_ticks_msec()
				_connection_pool_mutex.unlock()
				print("[DownloadManager] Chunk " + str(chunk_index) + " already complete on disk, verified " + str(partial_size) + " bytes")
				return result
			elif partial_size > 0:
				resume_offset = partial_size
				start_byte = original_start_byte + resume_offset
				bytes_downloaded = partial_size
				# Hash existing bytes so the final hash covers the whole chunk
				var hash_file = FileAccess.open(temp_path, FileAccess.READ)
				if hash_file:
					var remaining = partial_size
					while remaining > 0:
						var buf = hash_file.get_buffer(mini(remaining, 1024 * 1024))
						hasher.update(buf)
						remaining -= buf.size()
					hash_file.close()
				print("[DownloadManager] Chunk " + str(chunk_index) + " resuming from byte " + str(start_byte) + " (already have " + str(partial_size) + " bytes)")

	# Add Range header (uses possibly resumed start_byte)
	request_headers.append("Range: bytes=%d-%d" % [start_byte, end_byte])

	# Open file for writing/appending
	if in_place:
		if final_file_mutex == null:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " in-place assembly requested without mutex")
			result.error = "In-place assembly missing mutex"
			return result

		final_file_mutex.lock()
		file = FileAccess.open(partial_path, FileAccess.READ_WRITE)
		if not file and not FileAccess.file_exists(partial_path):
			# Hardening: create the partial file first if it disappeared
			var partial_create = FileAccess.open(partial_path, FileAccess.WRITE)
			if partial_create:
				partial_create.close()
				file = FileAccess.open(partial_path, FileAccess.READ_WRITE)
		if file:
			file.seek(write_offset)
			final_file_mutex.unlock()
		else:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " failed to open partial file for in-place chunk write: " + partial_path)
			result.error = "Failed to open partial file"
			final_file_mutex.unlock()
			return result
	elif resume_offset > 0:
		file = FileAccess.open(temp_path, FileAccess.READ_WRITE)
		if file:
			file.seek_end(0)
	else:
		file = FileAccess.open(temp_path, FileAccess.WRITE)

	if not file:
		push_error("[DownloadManager] Failed to create chunk file: " + temp_path)
		result.error = "Failed to create chunk file"
		return result

	# Make the request
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " making request, connection status: " + str(http.get_status()))

	var err = http.request(HTTPClient.METHOD_GET, url_parts.path + url_parts.query, request_headers)
	if err != OK:
		push_error("[DownloadManager] Failed to make request: " + str(err))
		file.close()
		result.error = "Failed to make request: " + str(err)
		return result

	# Wait for response headers
	var poll_count = 0
	var request_start_time = Time.get_ticks_msec()
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		poll_count += 1
		if poll_count % 100 == 0:
			print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " still requesting... (poll " + str(poll_count) + ")")

		if Time.get_ticks_msec() - request_start_time > CHUNK_REQUEST_TIMEOUT_MS:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " request phase timed out after " + str(CHUNK_REQUEST_TIMEOUT_MS) + "ms")
			file.close()
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Request phase timed out"
			return result

		OS.delay_msec(10)

	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " finished requesting after " + str(poll_count) + " polls, status: " + str(http.get_status()))

	# Get and log response headers
	var response_headers = http.get_response_headers()
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " response headers: " + str(response_headers))

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
		file.close()
		_invalidate_pool_connection(http, item_id, thread_index)
		result.error = "HTTP error " + str(response_code)
		return result

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
					var _range_total = int(range_match.get_string(3))

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
			file.close()
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Invalid Content-Range header"
			result.should_delete_partial = true
			return result

	# Download the chunk with stall detection
	var last_progress_emit = bytes_downloaded
	var body_poll_count = 0
	var last_poll_time = Time.get_ticks_msec()
	var last_byte_time = Time.get_ticks_msec()

	while http.get_status() == HTTPClient.STATUS_BODY:
		var current_time = Time.get_ticks_msec()

		if current_time > chunk_deadline_ms:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " exceeded max total time of " + str(CHUNK_MAX_TOTAL_TIME_MS) + "ms")
			file.close()
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Exceeded max total time"
			return result

		if current_time - last_byte_time > CHUNK_STALL_TIMEOUT_MS:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " stalled: no data for " + str(CHUNK_STALL_TIMEOUT_MS) + "ms")
			file.close()
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Stalled: no data"
			return result

		# Poll every POLLING_INTERVAL_MS to balance responsiveness with CPU usage
		if current_time - last_poll_time >= POLLING_INTERVAL_MS:
			http.poll()
			body_poll_count += 1
			last_poll_time = current_time

		var chunk = http.read_response_body_chunk()
		if chunk.size() > 0:
			if in_place:
				final_file_mutex.lock()
				file.seek(write_offset + bytes_downloaded)
				file.store_buffer(chunk)
				final_file_mutex.unlock()
			else:
				file.store_buffer(chunk)
			hasher.update(chunk)
			bytes_downloaded += chunk.size()
			last_byte_time = current_time

			# Emit progress every 10MB
			if bytes_downloaded - last_progress_emit >= 10 * 1024 * 1024:
				call_deferred("_update_chunk_progress", chunk_data.item_id, chunk_index, bytes_downloaded)
				last_progress_emit = bytes_downloaded
				print("[DownloadManager] Chunk " + str(chunk_index) + " progress: " + str(bytes_downloaded / (1024.0 * 1024.0)) + "MB")
		else:
			# No data available, wait a bit before checking again
			OS.delay_usec(1000)  # 1ms micro-sleep to prevent busy-waiting

	file.close()

	# Verify downloaded size and (when possible) on-disk chunk
	if bytes_downloaded != expected_chunk_size:
		push_error("[DownloadManager] Chunk " + str(chunk_index) + " size mismatch: expected " + str(expected_chunk_size) + " bytes, got " + str(bytes_downloaded) + " bytes")
		_invalidate_pool_connection(http, item_id, thread_index)
		result.error = "Size mismatch"
		result.should_delete_partial = not in_place
		return result

	if not in_place:
		if not FileAccess.file_exists(temp_path):
			push_error("[DownloadManager] Chunk file not found after download: " + temp_path)
			result.error = "Chunk file not found after download"
			result.should_delete_partial = true
			return result

		var verify_file = FileAccess.open(temp_path, FileAccess.READ)
		if not verify_file:
			push_error("[DownloadManager] Failed to open chunk file for verification: " + temp_path)
			result.error = "Failed to open chunk file for verification"
			result.should_delete_partial = true
			return result

		var actual_size = verify_file.get_length()
		verify_file.close()

		if actual_size != expected_chunk_size:
			push_error("[DownloadManager] Chunk " + str(chunk_index) + " size mismatch: expected " + str(expected_chunk_size) + " bytes, got " + str(actual_size) + " bytes")
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Size mismatch"
			result.should_delete_partial = true
			return result

	var actual_hash = hasher.finish().hex_encode()
	if expected_hash.is_empty():
		expected_hash = actual_hash

	result.actual_hash = actual_hash
	result.expected_hash = expected_hash

	if actual_hash != expected_hash:
		push_error("[DownloadManager] Chunk " + str(chunk_index) + " hash mismatch: expected " + expected_hash + ", got " + actual_hash)
		_invalidate_pool_connection(http, item_id, thread_index)
		result.error = "Hash mismatch"
		result.should_delete_partial = true
		return result

	var chunk_end_time = Time.get_ticks_msec()
	var download_duration = chunk_end_time - chunk_start_time
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " finished body after " + str(body_poll_count) + " polls, status: " + str(http.get_status()))
	print("[DownloadManager] [DEBUG] Chunk " + str(chunk_index) + " download duration: " + str(download_duration) + "ms")

	# Track finish time for this thread for debugging connection reuse (mutex-protected)
	var thread_key = item_id + "_" + str(thread_index)
	_connection_pool_mutex.lock()
	_thread_chunk_finish_times[thread_key] = chunk_end_time
	_connection_pool_mutex.unlock()

	if bytes_downloaded == 0:
		push_error("[DownloadManager] Downloaded 0 bytes for chunk " + str(chunk_index))
		result.error = "Downloaded 0 bytes"
		result.should_delete_partial = true
		return result

	result.success = true
	result.bytes_downloaded = bytes_downloaded
	print("[DownloadManager] Chunk " + str(chunk_index) + " completed successfully with " + str(bytes_downloaded) + " bytes (hash=" + actual_hash + ")")
	return result

## Updates progress when a chunk completes via thread pool
func _update_chunk_download_progress(item_id: String, chunk_index: int, result: Variant):
	if not _chunked_downloads.has(item_id):
		return

	if chunk_index < 0 or chunk_index >= _chunked_downloads[item_id].chunks.size():
		push_error("[DownloadManager] Invalid chunk index in progress update: " + str(chunk_index))
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	var chunk = chunked_info.chunks[chunk_index]

	var success = false
	var actual_hash = ""
	var expected_hash = ""
	var should_delete_partial = false
	var bytes_downloaded = 0

	if result is Dictionary:
		success = result.get("success", false)
		actual_hash = result.get("actual_hash", "")
		expected_hash = result.get("expected_hash", "")
		should_delete_partial = result.get("should_delete_partial", false)
		bytes_downloaded = result.get("bytes_downloaded", 0)
	elif result is bool:
		success = result
	else:
		push_error("[DownloadManager] Unexpected chunk result type: " + str(typeof(result)))
		return

	chunk.in_progress = false

	if success:
		if not chunk.completed:
			chunk.completed = true
			chunk.failed = false
			chunk.actual_hash = actual_hash
			chunk.expected_hash = expected_hash
			chunked_info.chunks_completed += 1
			print("[DownloadManager] Chunk " + str(chunk_index) + " completed successfully (total: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")
	else:
		chunk.failed = true
		chunk.actual_hash = actual_hash
		chunk.expected_hash = expected_hash
		# Reset progress tracking for retry
		chunk.temp_bytes_downloaded = 0

		# Delete corrupt/mismatched partial files so the retry starts clean
		if should_delete_partial and FSM.file_exists(chunk.temp_path):
			FSM.delete_file(chunk.temp_path)
			print("[DownloadManager] Deleted partial chunk file after failure: " + chunk.temp_path)

		print("[DownloadManager] Chunk " + str(chunk_index) + " failed (total completed: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")

	# Persist the updated bitmap after every chunk status change, but coalesce
	# rapid writes to avoid disk I/O throttling fast downloads.
	_save_download_state(chunked_info)

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
		if abs(progress - chunked_info.last_progress_update) >= _get_progress_threshold():
			chunked_info.last_progress_update = progress
			item.progress = progress
			download_progress.emit(item_id, progress)

## Called when all chunks have been processed by the thread pool
func _on_all_chunks_complete(item_id: String, headers: Array, _results: Dictionary = {}):
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	print("[DownloadManager] Thread pool callback: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + " chunks done")

	# Check if all chunks completed successfully
	if chunked_info.chunks_completed >= chunked_info.total_chunks:
		print("[DownloadManager] All chunks marked complete for: " + item.name + ", verifying before finalising...")

		var missing_or_bad_chunks = []
		if chunked_info.in_place_assembly:
			# For sparse in-place assembly, verify the partial file size and per-chunk hashes.
			if not FileAccess.file_exists(chunked_info.partial_path):
				push_error("[DownloadManager] Sparse partial file missing: " + chunked_info.partial_path)
				missing_or_bad_chunks.append_array(chunked_info.chunks)
			else:
				var verify_file = FileAccess.open(chunked_info.partial_path, FileAccess.READ)
				if verify_file:
					var actual_size = verify_file.get_length()
					verify_file.close()
					if actual_size != item.expected_file_size:
						push_error("[DownloadManager] Sparse partial file size mismatch: expected " + str(item.expected_file_size) + ", got " + str(actual_size))
						missing_or_bad_chunks.append_array(chunked_info.chunks)
				else:
					push_error("[DownloadManager] Cannot open sparse partial file for verification: " + chunked_info.partial_path)
					missing_or_bad_chunks.append_array(chunked_info.chunks)

			if missing_or_bad_chunks.size() == 0:
				for chunk in chunked_info.chunks:
					if not chunk.expected_hash.is_empty() and not chunk.actual_hash.is_empty() and chunk.actual_hash != chunk.expected_hash:
						push_error("[DownloadManager] Chunk " + str(chunk.index) + " hash mismatch despite being marked complete: expected " + chunk.expected_hash + ", got " + chunk.actual_hash)
						missing_or_bad_chunks.append(chunk)
		else:
			# Verify chunk files actually exist on disk and pass integrity checks
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
						elif not chunk.expected_hash.is_empty() and not chunk.actual_hash.is_empty() and chunk.actual_hash != chunk.expected_hash:
							push_error("[DownloadManager] Chunk " + str(chunk.index) + " hash mismatch despite being marked complete: expected " + chunk.expected_hash + ", got " + chunk.actual_hash)
							missing_or_bad_chunks.append(chunk)
					else:
						push_error("[DownloadManager] Cannot open chunk file despite being marked complete: " + chunk.temp_path)
						missing_or_bad_chunks.append(chunk)

		if missing_or_bad_chunks.size() > 0:
			print("[DownloadManager] Found " + str(missing_or_bad_chunks.size()) + " chunks marked complete but files missing/bad. Resetting for retry...")
			for chunk in missing_or_bad_chunks:
				chunk.completed = false
				chunked_info.chunks_completed -= 1
			_save_download_state(chunked_info, true)
			_handle_failed_chunks_thread_pool(item_id, headers)
			return

		_stop_chunked_progress_timer(item_id)
		_stop_chunked_watchdog_timer(item_id)
		_cleanup_download_tracking(item_id)

		if chunked_info.in_place_assembly:
			# Sparse assembly is already complete; just rename to the real output path.
			_rename_final_file(item_id)
		else:
			_reassemble_chunks(item_id)
	else:
		# Some chunks failed - check if we should retry
		print("[DownloadManager] Not all chunks completed, checking for retries...")
		_handle_failed_chunks_thread_pool(item_id, headers)

## Exponential cooldown for chunk retries (copyparty-style chill).
## Doubles the multiplier up to a cap and adds jitter. Returns delay in seconds.
func _chill(chunk: ChunkInfo) -> float:
	if chunk.coolmul < 0.5:
		chunk.coolmul = 0.5
	chunk.coolmul = min(chunk.coolmul * 2.0, 32.0)
	var delay_sec = chunk.coolmul + randf() * 4.0 + 2.0
	chunk.cooldown_until_ms = Time.get_ticks_msec() + int(delay_sec * 1000.0)
	return delay_sec

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

		var concurrency = chunked_info.concurrency if chunked_info.concurrency > 0 else _get_max_chunk_concurrency()
		var chunk_sem = _chunk_concurrency_semaphores.get(item_id)

		# Apply exponential backoff to each failed chunk and compute the longest delay
		var max_delay = 0.0
		for chunk in failed_chunks:
			chunk.retry_count += 1
			chunk.failed = false
			chunk.in_progress = false
			chunk.temp_bytes_downloaded = 0
			var delay = _chill(chunk)
			if delay > max_delay:
				max_delay = delay

		_save_download_state(chunked_info, true)

		# Wait before retry using non-blocking timer
		await get_tree().create_timer(max_delay).timeout

		# Prepare retry items (include expected hash so corrupt partials are detected)
		var retry_items = []
		for chunk in failed_chunks:
			retry_items.append({
				"item_id": item_id,
				"chunk_index": chunk.index,
				"url": item.url,
				"temp_path": chunk.temp_path,
				"partial_path": chunked_info.partial_path,
				"write_offset": chunk.start_byte,
				"in_place": chunked_info.in_place_assembly,
				"final_file_mutex": chunked_info.final_file_mutex,
				"start_byte": chunk.start_byte,
				"end_byte": chunk.end_byte,
				"original_start_byte": chunk.original_start_byte,
				"expected_hash": chunk.expected_hash,
				"headers": headers,
				"thread_index": chunk.index % concurrency
			})

		# Queue retry via thread pool
		await MemoryManager.queue_parallel_downloads(
			retry_items,
			func(chunk_data, _index):
				if chunk_sem != null:
					chunk_sem.wait()
				var result = _download_chunk_on_thread(chunk_data)
				if chunk_sem != null:
					chunk_sem.post()
				return result,
			func(_completed, _total, batch_index, result):
				var chunk_index = result.get("chunk_index", batch_index) if result is Dictionary else batch_index
				_update_chunk_download_progress(item_id, chunk_index, result),
			func(results):
				_on_all_chunks_complete(item_id, headers, results)
		)
	else:
		# No more retries available
		if CHUNK_FALLBACK_TO_SINGLE_STREAM:
			print("[DownloadManager] Chunked download failed after retries; falling back to single-stream for: " + item.name)
			_start_single_stream_fallback(item_id, headers)
		else:
			push_error("[DownloadManager] Chunks failed with no retries remaining for: " + item.name)
			item.status = "failed"
			item.error_message = "Chunk download failed after " + str(MAX_CHUNK_RETRIES) + " retries"
			_cleanup_chunked_download(item_id)
			_cleanup_item(item)
			_active_items.erase(item_id)
			download_completed.emit(item_id, false, item.error_message)
			queue_changed.emit()
			_process_queue()

func _start_single_stream_fallback(item_id: String, headers: Array):
	"""Fall back to a single HTTPRequest download when chunked Range downloads fail."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	print("[DownloadManager] Starting single-stream fallback for: " + item.name)
	NotificationManager.update_notification_text(
		item.notification_id,
		"Server throttling detected; switching to single-stream download..."
	)

	_cleanup_chunked_download(item_id)
	_delete_download_state(item.destination_path)

	item.download_info = NetworkManager.http_download_file(
		item.url,
		item.destination_path,
		headers,
		func(success: bool, _status_code: int, error_msg: String):
			_on_file_download_complete(item, success, error_msg),
		item.expected_file_size
	)

	if item.download_info.is_empty():
		item.status = "failed"
		item.error_message = "Failed to start single-stream fallback"
		_cleanup_item(item)
		_active_items.erase(item.id)
		download_completed.emit(item.id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return

	item.http_request = item.download_info.get("http", null)

	# Setup progress timer for fallback download
	var progress2 = _download_progress.get(item.id) as DownloadProgress
	if progress2 == null:
		progress2 = DownloadProgress.new()
		progress2.start_time_ms = Time.get_ticks_msec()
		progress2.last_progress_time_ms = progress2.start_time_ms
		progress2.last_downloaded_bytes = 0
		_download_progress[item.id] = progress2
	if progress2.timer != null and is_instance_valid(progress2.timer):
		progress2.timer.stop()
		progress2.timer.queue_free()
	progress2.timer = Timer.new()
	progress2.timer.wait_time = 1.0
	progress2.timer.autostart = true
	add_child(progress2.timer)

	progress2.timer.timeout.connect(func():
		_update_download_progress(item)
		_check_download_timeout(item.id)
	)

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

		# Only emit if progress changed significantly
		if abs(progress - chunked_info.last_progress_update) >= _get_progress_threshold():
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
		var total_downloaded_bytes = 0

		for chunk in chunked_info.chunks:
			if chunk.completed:
				total_downloaded_bytes += (chunk.end_byte - chunk.start_byte + 1)
			else:
				total_downloaded_bytes += chunk.temp_bytes_downloaded

		var total_size = float(chunked_info.item.expected_file_size)
		if total_size > 0:
			var progress = float(total_downloaded_bytes) / total_size
			progress = min(progress, 0.99)

			# Emit if progress changed significantly
			if abs(progress - chunked_info.last_progress_update) >= _get_progress_threshold():
				chunked_info.last_progress_update = progress
				chunked_info.item.progress = progress
				download_progress.emit(item_id, progress)

func _get_progress_threshold() -> float:
	"""Return the minimum progress delta required before emitting a signal.

	Higher speed profiles emit less often to reduce main-thread callback
	pressure during fast downloads. UI updates are still smooth enough visually.
	"""
	if SettingsManager and SettingsManager.settings:
		var setting = SettingsManager.get_setting("download_speed_profile")
		if setting and setting.value is int:
			match clampi(setting.value, 0, 3):
				0: return 0.001
				1: return 0.005
				2: return 0.01
				3: return 0.02
	return 0.005

func _stop_chunked_progress_timer(item_id: String):
	"""Stop and clean up the progress timer"""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	if chunked_info.progress_timer and is_instance_valid(chunked_info.progress_timer):
		chunked_info.progress_timer.stop()
		chunked_info.progress_timer.queue_free()
		chunked_info.progress_timer = null

func _start_chunked_watchdog_timer(item_id: String, headers: Array):
	"""Start a watchdog timer that detects stuck chunk downloads and falls back."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	_stop_chunked_watchdog_timer(item_id)

	chunked_info.headers = headers
	chunked_info.watchdog_last_total_bytes = 0
	chunked_info.watchdog_last_progress_time_ms = Time.get_ticks_msec()

	var timer := Timer.new()
	timer.wait_time = CHUNK_WATCHDOG_INTERVAL_SEC
	timer.one_shot = false
	timer.timeout.connect(_on_chunked_watchdog.bind(item_id))
	add_child(timer)
	timer.start()
	chunked_info.watchdog_timer = timer

func _stop_chunked_watchdog_timer(item_id: String):
	"""Stop and clean up the chunk watchdog timer."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	if chunked_info.watchdog_timer and is_instance_valid(chunked_info.watchdog_timer):
		chunked_info.watchdog_timer.stop()
		chunked_info.watchdog_timer.queue_free()
		chunked_info.watchdog_timer = null

func _on_chunked_watchdog(item_id: String):
	if not _chunked_downloads.has(item_id):
		_stop_chunked_watchdog_timer(item_id)
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	var now := Time.get_ticks_msec()

	var total_bytes: int = 0
	var in_progress_count: int = 0
	var completed_count: int = chunked_info.chunks_completed
	for chunk in chunked_info.chunks:
		if chunk.completed:
			total_bytes += chunk.end_byte - chunk.start_byte + 1
		else:
			total_bytes += chunk.temp_bytes_downloaded
			if chunk.in_progress:
				in_progress_count += 1

	print("[DownloadManager] [Watchdog] item=%s chunks=%d/%d in_progress=%d total_bytes=%d" % [
		item.name, completed_count, chunked_info.total_chunks, in_progress_count, total_bytes])

	var stalled := false
	if total_bytes > chunked_info.watchdog_last_total_bytes:
		chunked_info.watchdog_last_total_bytes = total_bytes
		chunked_info.watchdog_last_progress_time_ms = now
	elif now - chunked_info.watchdog_last_progress_time_ms > CHUNK_STALL_TIMEOUT_MS * 2:
		push_error("[DownloadManager] [Watchdog] Chunked download stalled for: " + item.name + ". Falling back to single-stream.")
		stalled = true

	if not stalled:
		var elapsed: int = now - chunked_info.start_time_ms
		var max_total_time := maxi(30 * 60 * 1000, item.expected_file_size / 2048)
		if elapsed > max_total_time:
			push_error("[DownloadManager] [Watchdog] Chunked download exceeded max total time for: " + item.name + " (elapsed=" + str(elapsed) + "ms). Falling back to single-stream.")
			stalled = true

	if stalled:
		_stop_chunked_watchdog_timer(item_id)
		_start_single_stream_fallback(item_id, chunked_info.headers)

## Helper to show reassembly notification on main thread (called via call_deferred)
func _show_reassembly_notification(item_id: String, item_name: String) -> void:
	if not _chunked_downloads.has(item_id):
		return
	var item = _chunked_downloads[item_id].item
	item.notification_id = NotificationManager.show_notification(
		"Reassembling chunks, please wait...",
		NotificationManager.Type.INFO,
		null,
		0.0,
		Callable(),  # No progress callable - using pulsing
		Callable(),  # No text formatter
		true  # pulsing = true
	)

func _reassemble_chunks(item_id: String):
	"""Reassemble all chunks into the final file - platform-specific implementation"""
	if not _chunked_downloads.has(item_id):
		push_error("[DownloadManager] No chunked download found for item: " + item_id)
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	print("[DownloadManager] Starting chunk reassembly for: " + item.name)

	# Show reassembly notification immediately
	if not item.suppress_notification:
		if item.notification_id != -1:
			NotificationManager.dismiss_notification(item.notification_id)
		_show_reassembly_notification(item_id, item.name)
		# Wait a short moment for the UI to render the new notification
		# before starting the blocking reassembly work
		await get_tree().create_timer(0.1).timeout

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

	# Call native Java reassembly on the main thread.
	# NOTE: This blocks the UI for the duration of reassembly, but a clear
	# notification is shown beforehand so the user knows what is happening.
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

	var success = plugin.call("reassembleChunks", chunk_paths_json, output_absolute_path)

	print("[DownloadManager] [Reassembly] Native reassembly returned: " + str(success) + " for: " + item.name)

	if not success:
		push_error("[DownloadManager] Native reassembly failed for: " + item.name)
		# Clean up failed final file
		if FSM.file_exists(reassembly_temp_path):
			FSM.delete_file(reassembly_temp_path)

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
		if FSM.file_exists(final_path):
			final_size = FSM.get_file_size(final_path)

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
			if FSM.file_exists(final_path):
				FSM.delete_file(final_path)

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

func _rename_final_file(item_id: String):
	"""Finalize an in-place sparse download by renaming the partial file to the destination."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	var partial_path = chunked_info.partial_path
	var final_path = chunked_info.final_path

	print("[DownloadManager] [InPlace] Renaming sparse partial to final: " + partial_path + " -> " + final_path)

	if FSM.file_exists(final_path):
		FSM.delete_file(final_path)

	# Ensure destination directory exists before attempting rename
	var dest_dir = final_path.get_base_dir()
	if not dest_dir.is_empty() and not FSM.dir_exists(dest_dir):
		FSM.make_dir_recursive(dest_dir)

	if FSM.move(partial_path, final_path):
		# Fast path: rename succeeded (same filesystem)
		_delete_download_state(final_path)
		_cleanup_chunked_download(item_id)
		_on_file_download_complete(item, true, "")
		return

	# Rename failed (usually cross-filesystem). Capture the exact error for diagnostics.
	print("[DownloadManager] [InPlace] Move failed, falling back to copy: %s -> %s" % [partial_path, final_path])
	_copy_partial_to_final(item_id, partial_path, final_path)

func _copy_partial_to_final(item_id: String, partial_path: String, final_path: String):
	"""Copy the assembled partial file to the final destination off the main thread.
	Shows real progress in the GUI. Uses the plugin for restricted Android paths."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	# Switch the notification to a copy progress indicator
	if item.notification_id != -1:
		NotificationManager.dismiss_notification(item.notification_id)

	item.notification_id = NotificationManager.show_notification(
		"Copying " + item.name + "...",
		NotificationManager.Type.INFO,
		null,
		0.0,
		func() -> float:
			return _final_copy_progress.get(item_id, 0.0),
		func(progress: float) -> String:
			var mb_copied = int(item.expected_file_size * progress / (1024.0 * 1024.0))
			var mb_total = int(item.expected_file_size / (1024.0 * 1024.0))
			return "Copying %s: %d/%d MB (%d%%)" % [item.name, mb_copied, mb_total, int(progress * 100)]
	)

	_final_copy_progress[item_id] = 0.0

	# For restricted Android paths, use the plugin's async copy.
	var use_plugin_copy = false
	if PlatformManager.is_android():
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin != null:
			use_plugin_copy = plugin.call("requiresDocumentsContract", final_path)

	if use_plugin_copy:
		_plugin_copy_partial_to_final(item_id, partial_path, final_path)
	else:
		_godot_copy_partial_to_final(item_id, partial_path, final_path)

func _plugin_copy_partial_to_final(item_id: String, partial_path: String, final_path: String):
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_error("[DownloadManager] PackageChecker plugin not available for copy")
		_final_copy_progress.erase(item_id)
		item.status = "failed"
		item.error_message = "Plugin not available for copy"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		_active_items.erase(item_id)
		download_completed.emit(item_id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return

	# Connect plugin signals for this copy operation
	var copy_token = item.id

	var on_progress = func(copy_id: String, bytes_copied: int, total_bytes: int):
		if copy_id != copy_token:
			return
		if total_bytes > 0:
			_final_copy_progress[item_id] = clamp(float(bytes_copied) / float(total_bytes), 0.0, 1.0)

	var on_complete = func(copy_id: String, success: bool, _dest_path: String, error: String):
		if copy_id != copy_token:
			return
		plugin.disconnect("copy_progress", on_progress)

		if item.notification_id != -1:
			NotificationManager.dismiss_notification(item.notification_id)
			item.notification_id = -1
		_final_copy_progress.erase(item_id)

		if not success:
			push_error("[DownloadManager] [InPlace] Plugin copy failed: " + error)
			item.status = "failed"
			item.error_message = "Failed to copy download to destination"
			_cleanup_chunked_download(item_id)
			_cleanup_item(item)
			_active_items.erase(item_id)
			download_completed.emit(item_id, false, item.error_message)
			queue_changed.emit()
			_process_queue()
			return

		_delete_download_state(final_path)
		_cleanup_chunked_download(item_id)
		_on_file_download_complete(item, true, "")

	plugin.connect("copy_progress", on_progress)
	# CONNECT_ONE_SHOT so the engine disconnects this handler automatically,
	# avoiding the need for the lambda to reference itself.
	plugin.connect("copy_complete", on_complete, CONNECT_ONE_SHOT)

	var absolute_source = ProjectSettings.globalize_path(partial_path)
	plugin.call("copyFileAsync", absolute_source, final_path, copy_token)

func _godot_copy_partial_to_final(item_id: String, partial_path: String, final_path: String):
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	MemoryManager.queue_extraction_task(
		func() -> bool:
			return _copy_file_with_progress(partial_path, final_path, item_id),
		func(success: bool):
			if item.notification_id != -1:
				NotificationManager.dismiss_notification(item.notification_id)
				item.notification_id = -1
			_final_copy_progress.erase(item_id)

			if not success:
				push_error("[DownloadManager] [InPlace] Failed to copy partial to destination: " + partial_path + " -> " + final_path)
				item.status = "failed"
				item.error_message = "Failed to copy download to destination"
				_cleanup_chunked_download(item_id)
				_cleanup_item(item)
				_active_items.erase(item_id)
				download_completed.emit(item_id, false, item.error_message)
				queue_changed.emit()
				_process_queue()
				return

			_delete_download_state(final_path)
			_cleanup_chunked_download(item_id)
			_on_file_download_complete(item, true, "")
	)

func _copy_file_with_progress(source_path: String, dest_path: String, item_id: String) -> bool:
	"""Copy a file in chunks, posting progress updates to the main thread.
	Runs on a background thread."""
	var source = FileAccess.open(source_path, FileAccess.READ)
	if not source:
		push_error("[DownloadManager] Failed to open source file for copy: " + source_path)
		return false

	var dest = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest:
		push_error("[DownloadManager] Failed to open destination file for copy: " + dest_path)
		source.close()
		return false

	var total = source.get_length()
	if total <= 0:
		total = 1

	var copied: int = 0
	const BUFFER_SIZE: int = 8 * 1024 * 1024  # 8 MB
	var last_reported_progress: float = -1.0

	while not source.eof_reached():
		var buffer = source.get_buffer(BUFFER_SIZE)
		if buffer.size() == 0:
			break
		dest.store_buffer(buffer)
		copied += buffer.size()

		var progress = clamp(float(copied) / float(total), 0.0, 1.0)
		if progress - last_reported_progress >= 0.01:
			last_reported_progress = progress
			MemoryManager.queue_main_thread_callback(func():
				_final_copy_progress[item_id] = progress
			)

	source.close()
	dest.close()

	MemoryManager.queue_main_thread_callback(func():
		_final_copy_progress[item_id] = 1.0
	)

	return true

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
		if FSM.file_exists(reassembly_temp_path):
			FSM.delete_file(reassembly_temp_path)

		if item.notification_id != -1:
			NotificationManager.dismiss_notification(item.notification_id)
			item.notification_id = -1

		download_completed.emit(item_id, false, item.error_message)
		queue_changed.emit()
		_process_queue()
		return

	# Success: remove resume state file and clean up chunked state
	_delete_download_state(reassembly_temp_path)
	_cleanup_chunked_download(item_id)

	# Continue with normal completion flow
	_on_file_download_complete(item, true, "")

func _cleanup_chunked_download(item_id: String):
	"""Clean up temp files for chunked download"""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]

	# Stop progress timer and watchdog
	if chunked_info.progress_timer and is_instance_valid(chunked_info.progress_timer):
		chunked_info.progress_timer.stop()
		chunked_info.progress_timer.queue_free()
		chunked_info.progress_timer = null

	if chunked_info.watchdog_timer and is_instance_valid(chunked_info.watchdog_timer):
		chunked_info.watchdog_timer.stop()
		chunked_info.watchdog_timer.queue_free()
		chunked_info.watchdog_timer = null

	# Clean up temp chunk files
	for chunk in chunked_info.chunks:
		if FSM.file_exists(chunk.temp_path):
			FSM.delete_file(chunk.temp_path)

	# Clean up temp directory
	if FSM.dir_exists(chunked_info.temp_dir):
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

	# Remove concurrency semaphore
	_chunk_concurrency_semaphores.erase(item_id)

	# Remove state-file coalescing bookkeeping
	_state_file_dirty.erase(item_id)
	_state_file_last_save_ms.erase(item_id)

	# Remove from tracking
	_chunked_downloads.erase(item_id)

func _update_download_progress(item: QueueItem):
	if item.http_request == null and item.download_info.is_empty():
		return

	# All downloads are now file-based; check actual file on disk to avoid 32-bit overflow
	if not item.download_info.is_empty():
		var file_path = item.download_info.get("path", item.destination_path)

		# Check file size on disk (64-bit, no overflow)
		# Use FileSystemManager for Android external storage compatibility
		if FSM.file_exists(file_path):
			var current_size = FSM.get_file_size(file_path)

			# Use expected_file_size from game data for accurate progress
			if item.expected_file_size > 0:
				item.progress = float(current_size) / float(item.expected_file_size)
				if item.progress > 0.99:
					item.progress = 0.99
			else:
				# No expected size, use indeterminate progress
				item.progress = -1.0

			# Track progress periodically (every 50MB change)
			var prog = _download_progress.get(item.id) as DownloadProgress
			if prog != null:
				var last_bytes = prog.last_downloaded_bytes
				if abs(current_size - last_bytes) > 50 * 1024 * 1024:
					prog.last_downloaded_bytes = current_size

				# Update stall time if making progress
				if current_size > 0 and current_size != last_bytes:
					prog.last_progress_time_ms = Time.get_ticks_msec()

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
		print("[DownloadManager] Download failed for " + item.name + ": " + error_msg)
		NotificationManager.update_notification_text(item.notification_id, "Download failed: " + item.name)
		_cleanup_item(item)
		_active_items.erase(item.id)
		_stop_foreground_service()  # Stop foreground service on failure
		download_completed.emit(item.id, false, error_msg)
		queue_changed.emit()
		_process_queue()
		return

	# Verify file exists and has content
	# Use FileSystemManager (not FileAccess) for Android external storage compatibility
	if not FSM.file_exists(item.destination_path):
		item.status = "failed"
		item.error_message = "Download file not found"
		print("[DownloadManager] Download file not found after completion: " + item.destination_path)
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
	var prog = _download_progress.get(item_id) as DownloadProgress
	if prog != null:
		if prog.timer != null:
			prog.timer.stop()
			prog.timer.queue_free()
		_download_progress.erase(item_id)

func _check_download_timeout(item_id: String):
	if not _active_items.has(item_id):
		return

	var current_time = Time.get_ticks_msec()
	var prog = _download_progress.get(item_id) as DownloadProgress
	var start_time = current_time
	var last_progress = current_time
	if prog != null:
		start_time = prog.start_time_ms
		last_progress = prog.last_progress_time_ms

	var _item = _active_items[item_id]
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
	item.extracted_count = 0
	item.total_count = 0
	item.progress = 0.0
	if not _active_items.has(item.id):
		_active_items[item.id] = item

	# Start foreground service on Android to prevent app kill during extraction
	_start_foreground_service(item.name)

	extraction_started.emit(item.id)

	# Delegate all extraction to FileSystemManager (handles its own notification)
	var archive_path = item.destination_path
	var extract_dir = item.extract_dir

	print("[DownloadManager] _start_extraction: archive_path=" + archive_path + ", extract_dir=" + extract_dir)

	FSM.extract_archive_async(
		archive_path,
		extract_dir,
		item.name,
		item.delete_after_extract,
		func(extracted: int, total: int):
			item.extracted_count = extracted
			item.total_count = total
			if total > 0:
				item.progress = float(extracted) / float(total)
			extraction_progress.emit(item.id, item.progress)
			queue_changed.emit(),
		func(success: bool, error_msg: String):
			if success:
				item.status = "completed"
				item.progress = 1.0
				item.extracted_count = item.total_count
				_cleanup_item(item)
				_active_items.erase(item.id)
				_stop_foreground_service()

				extraction_completed.emit(item.id, true, extract_dir)
				queue_changed.emit()
				_process_queue()
			else:
				item.status = "failed"
				item.error_message = error_msg if error_msg != "" else "Extraction failed"
				_cleanup_item(item)
				_active_items.erase(item.id)
				_stop_foreground_service()
				extraction_completed.emit(item.id, false, item.error_message)
				queue_changed.emit()
				_process_queue()
	)

func _finish_download_completion(item: QueueItem):
	"""Complete the download after file operations are done"""
	# Update game resource if applicable
	if item.game_resource and item.update_game_resource:
		var downloaded_id = item.romm_id if item.romm_id != 0 else item.game_resource.romm_id
		item.game_resource.mark_sibling_downloaded(downloaded_id)
		item.game_resource.file_path = item.destination_path
		DataManager.update_game(item.game_resource)

		# Extract TitleID in background if needed
		if item.game_resource.get_active_title_id() == "" and _needs_title_id(item.game_resource):
			var game = item.game_resource
			var notify_id = NotificationManager.show_notification("Extracting TitleID for " + game.title + "...", NotificationManager.Type.INFO, null, 3.0, Callable(), Callable(), true)
			MemoryManager.queue_extraction_task(func():
				var title_id = TitleIDParser.extract_for_game(game)
				return title_id
			, func(title_id: String):
				NotificationManager.dismiss_notification(notify_id)
				if title_id != "":
					DataManager.update_game_title_id(game.romm_id, title_id)
					NotificationManager.show_notification("TitleID " + title_id + " found for " + game.title + "!", NotificationManager.Type.SUCCESS, null, 3.0)
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
	if FSM.file_exists(cache_path):
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
	NetworkManager.http_get(url, [], func(success: bool, body: PackedByteArray, _status_code: int, _error_msg: String):
		var state = _active_image_downloads[url]
		if not success or body.is_empty():
			# Download failed
			state.completed = true
			state.success = false
			for cb in state.callbacks:
				cb.call(false)
			# Clean up after delay (guard against node destruction during await)
			await get_tree().create_timer(5.0).timeout
			if is_instance_valid(self):
				_active_image_downloads.erase(url)
			return

		# Save to cache
		FSM.write_file_bytes(cache_path, body)

		# Notify callbacks
		state.completed = true
		state.success = true
		for cb in state.callbacks:
			cb.call(true)

		# Clean up after delay (guard against node destruction during await)
		await get_tree().create_timer(5.0).timeout
		if is_instance_valid(self):
			_active_image_downloads.erase(url)
	)

	return true

## Helper function to recursively clean up a temp directory
func _cleanup_temp_dir(dir_path: String) -> void:
	FSM.delete_dir_recursive(dir_path)
