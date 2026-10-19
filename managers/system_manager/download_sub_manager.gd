extends Manager
class_name DownloadSubManager

# SystemManager.download - Unified download and extraction queue
# Handles all file downloads: games, emulators, cores, images, etc.
# Also handles archive extraction with progress notifications

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

const DEBUG_LOG: bool = false

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
	var suppress_sound: bool = false  # If true, don't play the download loop SFX
	var update_game_resource: bool = true  # If false, skip DataManager.update_game() on completion
	var extracted_count: int = 0  # Files extracted so far
	var total_count: int = 0  # Total files in archive
	var group_id: String = ""  # Non-empty for multi-disc batch downloads: per-item notifications are folded into one group notification

# Unified queue
var _queue: Array[QueueItem] = []
var _active_items: Dictionary = {}  # id -> QueueItem

# Monotonic serial for queue item IDs. Batch installs queue dozens of items in
# the same millisecond, so ticks+randi alone collided regularly (~30% per
# 27-item batch), silently stranding one download's callback.
var _item_serial: int = 0

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

## Total plays of the download loop SFX before it cuts itself off.
const DOWNLOAD_LOOP_MAX_PLAYS: int = 4
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
# Android: slightly below desktop parity for battery/heat on handhelds.
const MAX_CONCURRENT_CHUNKS_PROFILES: Array[int] = [2, 4, 6, 10]
const MAX_CONCURRENT_CHUNKS_ANDROID_PROFILES: Array[int] = [2, 4, 6, 8]

# Overall concurrent downloads for each profile. Android stays one notch below desktop.
const MAX_CONCURRENT_DOWNLOADS_PROFILES: Array[int] = [2, 4, 6, 8]
const MAX_CONCURRENT_DOWNLOADS_ANDROID_PROFILES: Array[int] = [1, 2, 4, 6]

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
			var cap = DYNAMIC_CHUNK_MAX_ANDROID if SystemManager.platform.is_android() else DYNAMIC_CHUNK_MAX_DESKTOP
			chunk_size = mini(chunk_size, cap)
			if chunk_size >= cap and nchunks <= DYNAMIC_CHUNK_ABS_MAX:
				return chunk_size
			if chunk_size >= cap:
				return cap

	# Unreachable, but keeps the static analyzer happy
	return DYNAMIC_CHUNK_MIN_SIZE

## Calculates chunk size and concurrency for a given file size.
func _calculate_chunk_strategy(file_size: int) -> Dictionary:
	var thread_count = SystemManager.memory.get_download_thread_count()
	var max_concurrent = _get_max_chunk_concurrency()
	var concurrency = mini(thread_count, max_concurrent)

	var chunk_size = _get_chunksize(file_size)
	var num_chunks = ceili(float(file_size) / float(chunk_size))

	print("[SystemManager.download] Chunk strategy for %d bytes: %d chunks x %d bytes (concurrency=%d, threads=%d)" % [
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
	var progress_mutex: Mutex = Mutex.new()  # Guards temp_bytes_downloaded (written by worker threads)
	var active_downloads: int = 0
	var download_callback: Callable
	var progress_timer: Timer = null  # Timer for polling chunk progress
	var last_progress_update: float = 0.0  # Last progress value to reduce emissions
	var headers: Array = []
	var start_time_ms: int = 0
	var watchdog_timer: Timer = null
	var watchdog_last_total_bytes: int = 0
	var watchdog_last_progress_time_ms: int = 0
	var batch_id: int = -1  # DownloadBatch ID for cancelling queued chunk tasks
	# Flush mode (Android): each completed chunk temp file is written directly
	# into the destination at its byte offset by the native plugin, so no
	# end-of-download full-file copy is needed.
	var flush_mode: bool = false
	var flushes_pending: int = 0
	var flush_failed: bool = false
	var all_chunks_done: bool = false
	var flush_retry_counts: Dictionary = {}  # chunk_index -> int

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
	var flushed: bool = false       # Flush mode: chunk written into the destination

# ============================================================================
# DOWNLOAD STATE FILE (chunk bitmap for resume)
# ============================================================================

func _get_state_file_path(destination_path: String) -> String:
	return destination_path + DOWNLOAD_STATE_SUFFIX

func _get_partial_file_path(destination_path: String) -> String:
	return destination_path + DOWNLOAD_PARTIAL_SUFFIX

## Creates a sparse file of the given size on supported filesystems.
## Returns true if the file was created and sized successfully.
## On Windows this uses fsutil; on Linux/Android it relies on seek+write holes.
## NOTE: spawns fsutil/stat subprocesses — call via _create_sparse_file_async
## so they never run on the main thread.
var _fsutil_unavailable: bool = false

func _create_sparse_file_async(path: String, size: int) -> bool:
	var state := {"done": false, "ok": false}
	MemorySubManager.queue_extraction_task(
		func(): return _create_sparse_file(path, size),
		func(result):
			state["done"] = true
			state["ok"] = result == true
	)
	while not state["done"]:
		await get_tree().process_frame
	return state["ok"]

func _create_sparse_file(path: String, size: int) -> bool:
	if size <= 0:
		return false

	# Ensure parent directory exists
	var parent_dir = path.get_base_dir()
	if not FSM.dir_exists(parent_dir):
		if not FSM.make_dir_recursive(parent_dir):
			push_error("[SystemManager.download] Failed to create destination directory: " + parent_dir)
			return false

	# Create (or truncate) the destination file
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SystemManager.download] Failed to create destination file: " + path)
		return false
	file.close()

	if SystemManager.platform.is_windows() and not _fsutil_unavailable:
		var native_path = FSM.resolve_native_path(path)
		var exit_code = OS.execute("fsutil", ["sparse", "setflag", native_path, "1"])
		if exit_code == 0:
			exit_code = OS.execute("fsutil", ["file", "seteof", native_path, str(size)])
		if exit_code != 0:
			# fsutil requires elevation on many systems; remember the failure
			# for the session and fall back to seek+write sizing from now on.
			_fsutil_unavailable = true
			push_warning("[SystemManager.download] fsutil failed (exit=" + str(exit_code) + "), falling back to seek+write sizing: " + native_path)
			file = FileAccess.open(path, FileAccess.WRITE_READ)
			if file == null:
				push_error("[SystemManager.download] Failed to open destination file for sizing: " + path)
				return false
			file.seek(size - 1)
			file.store_8(0)
			file.close()
	else:
		# On Linux/Android, seeking past EOF and writing creates a sparse
		# hole on filesystems that support it (ext4, btrfs, etc.).
		file = FileAccess.open(path, FileAccess.WRITE_READ)
		if file == null:
			push_error("[SystemManager.download] Failed to open destination file for sizing: " + path)
			return false
		file.seek(size - 1)
		file.store_8(0)
		file.close()

		# Probe whether the filesystem actually stored the file sparsely.
		# If it allocated the whole file (e.g. FAT32/exFAT), sparse assembly
		# would waste disk space, so fall back to sequential temp-file reassembly.
		# Windows has no stat; the fsutil path above (or its seek+write
		# fallback) already decided the sizing strategy there.
		if not SystemManager.platform.is_windows():
			var native_path = FSM.resolve_native_path(path)
			var stat_args = ["-c", "%b %B", native_path]
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
					var threshold = maxi(64 * 1024, int(size / float(2)))
					if block_size > 0 and allocated > threshold:
						push_error("[SystemManager.download] Filesystem does not appear to support sparse files: " + path + " (allocated " + str(allocated) + " bytes for " + str(size) + " byte file)")
						FSM.delete_file(path)
						return false
			else:
				push_warning("[SystemManager.download] Could not probe filesystem sparse support for: " + path)

	# Verify the file reached the expected logical size
	if not FSM.file_exists(path):
		return false
	var actual_size = FSM.get_file_size(path)
	if actual_size != size:
		push_error("[SystemManager.download] Sparse file size mismatch: expected " + str(size) + ", got " + str(actual_size))
		return false

	return true

func _delete_download_state(destination_path: String) -> void:
	var state_path = _get_state_file_path(destination_path)
	if FSM.file_exists(state_path):
		if not FSM.delete_file(state_path):
			push_error("[SystemManager.download] Failed to remove state file: " + state_path)

## Loads a previously saved chunk state file, if it is valid for this URL/size/strategy.
func _load_download_state(destination_path: String, url: String, file_size: int) -> Dictionary:
	var state_path = _get_state_file_path(destination_path)
	if not FSM.file_exists(state_path):
		return {}

	var text = FSM.read_file_bytes(state_path).get_string_from_utf8()
	if text.is_empty():
		push_error("[SystemManager.download] Could not read state file: " + state_path)
		return {}

	var json = JSON.new()
	if json.parse(text) != OK:
		push_error("[SystemManager.download] Corrupt state file, ignoring: " + state_path)
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

	# Flush mode: chunks marked flushed live in the destination file. Fetch its
	# size once via the plugin (Godot can't stat SAF-restricted paths directly).
	# The file grows lazily as chunks flush, so flushed chunks are trusted only
	# when the file extends past their end byte.
	var flush_dest_size := -1
	if chunked_info.flush_mode:
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin != null:
			flush_dest_size = int(plugin.call("androidFileSize", chunked_info.final_path))
		if flush_dest_size < 0:
			if DEBUG_LOG: print("[SystemManager.download] Flush-mode resume: destination missing/unreadable, flushed chunks will be re-downloaded")

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
		chunk.flushed = chunk_state.get("flushed", false)

		var status = chunk_state.get("status", "pending")
		if status == "complete":
			var expected_size = chunk.end_byte - chunk.start_byte + 1
			var verified = false

			if chunked_info.flush_mode:
				if chunk.flushed:
					# Already written into the destination; trust it if the file
					# extends past this chunk's end byte.
					verified = chunk.end_byte < flush_dest_size
					if not verified:
						chunk.flushed = false
				else:
					# Completed but not yet flushed: re-flush if the temp file survived.
					if FileAccess.file_exists(chunk.temp_path):
						var f = FileAccess.open(chunk.temp_path, FileAccess.READ)
						if f != null:
							var actual_size = f.get_length()
							f.close()
							if actual_size == expected_size:
								verified = true
			elif chunked_info.in_place_assembly:
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
									if DEBUG_LOG: print("[SystemManager.download] Resume hash mismatch for chunk " + str(chunk.index) + ", will re-download")
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
			"cooldown_until_ms": chunk.cooldown_until_ms,
			"flushed": chunk.flushed
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
		push_error("[SystemManager.download] Failed to write state file: " + state_path)

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
	if DataManager:
		DataManager.setting_changed.connect(_on_setting_changed)
	download_completed.connect(_on_completion_watcher)
	download_completed.connect(_on_group_download_completed)
	Performance.add_custom_monitor("download/image_active", _get_image_active_count)
	Performance.add_custom_monitor("download/image_pending", _get_image_pending_count)

func _get_image_active_count() -> int:
	_pending_image_downloads_mutex.lock()
	var count = _active_image_download_count
	_pending_image_downloads_mutex.unlock()
	return count

func _get_image_pending_count() -> int:
	_pending_image_downloads_mutex.lock()
	var count = _pending_image_downloads.size()
	_pending_image_downloads_mutex.unlock()
	return count

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "download_speed_profile":
		_update_concurrency_from_settings()

func _update_concurrency_from_settings() -> void:
	var profile_index := 1  # Default to Balanced
	if DataManager.is_settings_loaded():
		var setting = DataManager.get_setting("download_speed_profile")
		if setting and setting.value is int:
			profile_index = clampi(setting.value, 0, 3)

	var is_android: bool = SystemManager.platform.is_android()
	var chunk_caps: Array[int] = MAX_CONCURRENT_CHUNKS_ANDROID_PROFILES if is_android else MAX_CONCURRENT_CHUNKS_PROFILES
	var download_caps: Array[int] = MAX_CONCURRENT_DOWNLOADS_ANDROID_PROFILES if is_android else MAX_CONCURRENT_DOWNLOADS_PROFILES

	_max_concurrent = download_caps[profile_index]
	print("[SystemManager.download] Speed profile '%s': max_concurrent=%d, max_chunk_concurrency=%d" % [
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
	if DataManager.is_settings_loaded():
		var setting = DataManager.get_setting("download_speed_profile")
		if setting and setting.value is int:
			profile_index = clampi(setting.value, 0, 3)
	var caps: Array[int] = MAX_CONCURRENT_CHUNKS_ANDROID_PROFILES if SystemManager.platform.is_android() else MAX_CONCURRENT_CHUNKS_PROFILES
	return caps[profile_index]

## Starts the Android foreground service to prevent app kill during downloads
func _start_foreground_service(game_name: String = "Game"):
	if _active_download_count == 0:
		print("[SystemManager.download] Starting foreground service for download: " + game_name)
		if SystemManager.platform.start_download_foreground_service(game_name):
			_foreground_service_active = true

	_active_download_count += 1
	print("[SystemManager.download] Active downloads: " + str(_active_download_count))

## Updates the foreground service notification with progress
func _update_foreground_service(game_name: String, progress: int):
	if _foreground_service_active:
		SystemManager.platform.update_download_foreground_service(game_name, progress)

## Stops the Android foreground service when downloads complete
func _stop_foreground_service():
	_active_download_count = max(0, _active_download_count - 1)

	if _active_download_count == 0 and _foreground_service_active:
		print("[SystemManager.download] Stopping foreground service")
		if SystemManager.platform.stop_download_foreground_service():
			_foreground_service_active = false
		# Restore normal CPU mode on Android
		if SystemManager.platform.is_android():
			OS.set_low_processor_usage_mode(false)
			print("[SystemManager.download] Disabled low processor mode")

## Queues a download with optional auto-extraction
## delete_after_extract: If true, deletes the archive after successful extraction (default: true for emulator_core type)
## Returns the item ID or empty string if failed
func queue_download(url: String, destination: String, type: String = "file", item_name: String = "", auto_extract: bool = false, extract_dir: String = "", game: GameResource = null, callbacks: Dictionary = {}, romm_id: int = 0, delete_after_extract: bool = true, suppress_notification: bool = false, expected_file_size: int = 0, update_game_resource: bool = true, suppress_sound: bool = false, group_id: String = "") -> String:
	# Generate unique ID
	_item_serial += 1
	var item_id = type + "_" + str(Time.get_ticks_msec()) + "_" + str(_item_serial)

	# Check if already downloading this URL (in queue OR active)
	for item in _queue:
		if item.url == url:
			push_warning("[SystemManager.download] queue_download rejected duplicate queued URL: " + url)
			_notify_duplicate_request(item_name, "queued", suppress_notification, suppress_sound)
			return ""

	for active_id in _active_items:
		if _active_items[active_id].url == url:
			push_warning("[SystemManager.download] queue_download rejected duplicate active URL: " + url)
			_notify_duplicate_request(item_name, "downloading", suppress_notification, suppress_sound)
			return ""

	if _active_items.has(item_id):
		push_warning("[SystemManager.download] queue_download rejected colliding item id: " + item_id)
		return ""

	# Defense in depth: never write to a destination containing traversal
	# segments, regardless of how the caller built it (KYD-01).
	if destination.replace("\\", "/").split("/").has(".."):
		push_error("[SystemManager.download] Refusing destination with '..' segment: " + destination)
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
	item.suppress_sound = suppress_sound
	item.update_game_resource = update_game_resource
	item.group_id = group_id

	# Store expected file size for progress tracking
	item.expected_file_size = expected_file_size
	if item.expected_file_size <= 0 and game:
		item.expected_file_size = game.get_active_file_size()

	# Pre-flight disk space check (10% margin) when the expected size is known
	if item.expected_file_size > 0:
		var required_bytes := int(item.expected_file_size * 1.1)
		var space_left := FSM.get_space_left(destination.get_base_dir())
		if space_left >= 0 and space_left < required_bytes:
			var needed_mb := int(required_bytes / (1024.0 * 1024.0))
			var free_mb := int(space_left / (1024.0 * 1024.0))
			push_error("[SystemManager.download] Insufficient disk space for " + item.name + ": need ~" + str(needed_mb) + " MB, have " + str(free_mb) + " MB")
			SystemManager.notifications.show_notification(
				"Not enough disk space for " + item.name + " (need ~" + str(needed_mb) + " MB, " + str(free_mb) + " MB free)",
				SystemManager.notifications.Type.ERROR,
				null,
				10.0
			)
			return ""

	# Set extract_dir and ensure destination directory exists
	item.extract_dir = extract_dir if extract_dir != "" else destination.get_base_dir()
	var dest_dir = destination.get_base_dir()

	if not FSM.make_dir_recursive(dest_dir):
		push_error("[SystemManager.download] Failed to create directory: " + dest_dir)
		return ""

	_queue.append(item)

	queue_changed.emit()
	_process_queue()

	# If the item didn't start (all concurrent slots busy), confirm to the user
	# that it was queued - otherwise the tap looks like it was ignored.
	if _queue.has(item):
		_notify_queued_behind_capacity(item)

	return item_id

## User-facing feedback for a download request that was rejected because the
## same URL is already queued or downloading. Silent for suppressed batch items.
func _notify_duplicate_request(item_name: String, state: String, suppress_notification: bool, suppress_sound: bool) -> void:
	if suppress_notification:
		return
	var display := item_name if item_name != "" else "This download"
	SystemManager.notifications.show_notification(
		display + " is already " + state,
		SystemManager.notifications.Type.WARNING
	)
	if not suppress_sound and SystemManager.audio:
		SystemManager.audio.play_sfx("error")

## User-facing feedback for an item that was accepted but has to wait for a
## free download slot. Silent for suppressed/grouped batch items.
func _notify_queued_behind_capacity(item: QueueItem) -> void:
	if item.suppress_notification or item.group_id != "":
		return
	SystemManager.notifications.show_notification(
		item.name + " queued - will download after current downloads finish",
		SystemManager.notifications.Type.WARNING
	)
	if not item.suppress_sound and SystemManager.audio:
		SystemManager.audio.play_sfx("error")

## Queues downloads for a game. Multi-disc games on m3u-capable platforms queue
## every missing disc so an m3u playlist can be generated once the set is
## complete; all other games queue only the active variant.
## on_all_complete(success) fires once every queued download has settled.
func queue_game_download(game: GameResource, on_all_complete: Callable = Callable()) -> void:
	var root_folder = DataManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		SystemManager.notifications.show_notification("Error: Games folder not set", SystemManager.notifications.Type.ERROR)
		if on_all_complete.is_valid():
			on_all_complete.call(false)
		return
	var platform_dir: String = root_folder.value + "/" + game.platform_slug
	if not FSM.is_path_contained(platform_dir, root_folder.value):
		push_error("[SystemManager.download] Platform slug escapes games folder, refusing download: '" + game.platform_slug + "'")
		SystemManager.notifications.show_notification("Error: unsafe platform folder name from server", SystemManager.notifications.Type.ERROR)
		if on_all_complete.is_valid():
			on_all_complete.call(false)
		return

	if M3USubManager.supports_m3u(game.platform_slug) and game.is_multi_disc():
		var missing: Array[Dictionary] = []
		for entry in game.get_disc_entries():
			if not entry["downloaded"]:
				missing.append(entry)
		if missing.is_empty():
			if on_all_complete.is_valid():
				on_all_complete.call(true)
			return
		# Multi-disc batches get one unified progress notification instead of
		# one snackbar per disc (see _create_download_group).
		var group_id := _create_download_group(game, missing, false)
		queue_disc_files(game, missing, platform_dir, true, false, Callable(), on_all_complete, false, group_id)
		return

	_queue_disc_entry(game, {
		"id": game.get_active_game_id(),
		"file_name": game.get_active_file_name(),
		"file_size": game.get_active_file_size(),
	}, platform_dir, true, false, func(success: bool):
		if on_all_complete.is_valid():
			on_all_complete.call(success)
	)

## Queues downloads for a set of disc entries (from GameResource.get_disc_entries)
## into dest_dir. on_entry_done(entry, success) fires per disc;
## on_all_done(success) fires once when every disc has settled.
func queue_disc_files(game: GameResource, entries: Array[Dictionary], dest_dir: String, update_game_resource: bool, suppress_notification: bool = false, on_entry_done: Callable = Callable(), on_all_done: Callable = Callable(), suppress_sound: bool = false, group_id: String = "") -> void:
	if entries.is_empty():
		if on_all_done.is_valid():
			on_all_done.call(true)
		return
	var state := {"pending": entries.size(), "failed": false}
	for entry in entries:
		var on_done := func(success: bool):
			state.pending -= 1
			if not success:
				state.failed = true
			if on_entry_done.is_valid():
				on_entry_done.call(entry, success)
			if state.pending <= 0 and on_all_done.is_valid():
				on_all_done.call(not state.failed)
		_queue_disc_entry(game, entry, dest_dir, update_game_resource, suppress_notification, on_done, suppress_sound, group_id)

func _queue_disc_entry(game: GameResource, entry: Dictionary, dest_dir: String, update_game_resource: bool, suppress_notification: bool, on_done: Callable = Callable(), suppress_sound: bool = false, group_id: String = "") -> void:
	var disc_id: int = entry["id"]
	var file_name: String = entry["file_name"]
	# Sibling file names from sync lack an extension (fs_name_no_ext) until full
	# details are fetched; resolve the real file name before queueing. The main
	# entry always carries its full fs_name from sync.
	var resolved: bool = disc_id == game.romm_id or entry.get("name_resolved", false) == true
	if not resolved:
		for sibling in game.siblings:
			if sibling.get("id", 0) == disc_id:
				resolved = sibling.get("name_resolved", false)
				break
	if file_name != "" and resolved:
		_do_queue_disc(game, disc_id, file_name, int(entry.get("file_size", 0)), dest_dir, update_game_resource, suppress_notification, on_done, suppress_sound, group_id)
		return
	SystemManager.network.fetch_game_details(disc_id, func(data: Dictionary, error: String):
		if error != "" or not data.has("fs_name"):
			SystemManager.notifications.show_notification("Failed to fetch disc info for " + game.get_display_name() + ": " + error, SystemManager.notifications.Type.ERROR)
			_settle_group_disc(group_id, disc_id, false, file_name)
			if on_done.is_valid():
				on_done.call(false)
			return
		var full_file_name := FSM.sanitize_server_filename(str(data.get("fs_name", "")))
		if full_file_name == "":
			push_error("[SystemManager.download] Rejected unsafe file name from server for disc " + str(disc_id) + ": '" + str(data.get("fs_name", "")) + "'")
			SystemManager.notifications.show_notification("Failed to download disc: unsafe file name from server", SystemManager.notifications.Type.ERROR)
			_settle_group_disc(group_id, disc_id, false, file_name)
			if on_done.is_valid():
				on_done.call(false)
			return
		var file_size := int(data.get("fs_size_bytes", 0))
		# Persist the resolved name/size so m3u resolution and future downloads use it
		for i in range(game.siblings.size()):
			if game.siblings[i].get("id", 0) == disc_id:
				game.siblings[i]["file_name"] = full_file_name
				game.siblings[i]["file_size"] = file_size
				game.siblings[i]["name_resolved"] = true
				DataManager.update_game_siblings(game.romm_id, game.siblings)
				break
		_do_queue_disc(game, disc_id, full_file_name, file_size, dest_dir, update_game_resource, suppress_notification, on_done, suppress_sound, group_id)
	)

func _do_queue_disc(game: GameResource, disc_id: int, file_name: String, file_size: int, dest_dir: String, update_game_resource: bool, suppress_notification: bool, on_done: Callable, suppress_sound: bool = false, group_id: String = "") -> void:
	var safe_file_name := FSM.sanitize_server_filename(file_name)
	if safe_file_name == "":
		push_error("[SystemManager.download] Rejected unsafe file name for disc " + str(disc_id) + ": '" + file_name + "'")
		SystemManager.notifications.show_notification("Failed to download " + game.get_display_name() + ": unsafe file name from server", SystemManager.notifications.Type.ERROR)
		_settle_group_disc(group_id, disc_id, false, file_name)
		if on_done.is_valid():
			on_done.call(false)
		return
	var download_url = SystemManager.network.get_romm_download_url(disc_id, safe_file_name)
	var destination_path = dest_dir + "/" + safe_file_name
	# Never blindly redownload: a complete archive already on disk only needs its
	# DB state restored. A leftover state file marks an incomplete download, in
	# which case fall through and let the chunked downloader resume it.
	if update_game_resource and FSM.file_exists(destination_path) and not FSM.file_exists(_get_state_file_path(destination_path)):
		var on_disk_size := FSM.get_file_size(destination_path)
		if file_size <= 0 or on_disk_size == file_size:
			if DEBUG_LOG: print("[SystemManager.download] File already on disk, marking downloaded instead of redownloading: " + destination_path)
			# Per-row truth: stamp the variant's own row + rebuild group cache.
			DataManager.record_variant_download(game, disc_id, destination_path)
			if not suppress_notification and group_id == "":
				SystemManager.notifications.show_notification(game.get_display_name() + " is already downloaded", SystemManager.notifications.Type.INFO)
			# No QueueItem exists on this path, but listeners (HomeView) still need
			# to refresh; synthesized IDs are ignored by item-based consumers.
			download_completed.emit("ondisk_" + str(disc_id) + "_" + str(Time.get_ticks_msec()), true, destination_path)
			_settle_group_disc(group_id, disc_id, true)
			on_done.call(true)
			return
	var item_id = queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, disc_id, true, suppress_notification, file_size, update_game_resource, suppress_sound, group_id)
	if item_id == "":
		# queue_download rejects duplicates with "" - if this disc is already
		# queued/downloading (e.g. user re-launched mid-batch), attach to the
		# in-flight item instead of reporting a bogus failure.
		var existing_id := _find_item_id_by_url(download_url)
		if existing_id != "":
			if DEBUG_LOG: print("[SystemManager.download] Disc already in flight, attaching watcher: " + file_name)
			_register_group_item(group_id, existing_id, disc_id, file_size)
			if on_done.is_valid():
				if not _completion_watchers.has(existing_id):
					_completion_watchers[existing_id] = []
				_completion_watchers[existing_id].append(on_done)
			return
		if not suppress_notification:
			SystemManager.notifications.show_notification("Failed to queue download: " + file_name, SystemManager.notifications.Type.ERROR)
		_settle_group_disc(group_id, disc_id, false, file_name)
		if on_done.is_valid():
			on_done.call(false)
		return
	_register_group_item(group_id, item_id, disc_id, file_size)
	if on_done.is_valid():
		if not _completion_watchers.has(item_id):
			_completion_watchers[item_id] = []
		_completion_watchers[item_id].append(on_done)

# Item completion watchers for batched disc downloads (queue_disc_files). The
# download_completed signal fires after game-resource updates and the m3u hook
# on success, and on every failure path, so watchers always settle.
var _completion_watchers: Dictionary = {}  # item_id -> Array[Callable]

# Multi-disc download groups: one pinned notification aggregates progress for
# every disc of a single game instead of one snackbar per disc.
# group_id -> {
#   label: String, total: int, settled: int, failed: Array[String],
#   sizes: Dictionary (disc_id -> expected bytes),
#   done: Dictionary (disc_id -> true),
#   item_map: Dictionary (item_id -> disc_id),
#   notification_id: int,
# }
var _groups: Dictionary = {}

func _on_completion_watcher(item_id: String, success: bool, _message: String) -> void:
	if not _completion_watchers.has(item_id):
		return
	var watchers: Array = _completion_watchers[item_id]
	_completion_watchers.erase(item_id)
	for watcher in watchers:
		if watcher.is_valid():
			watcher.call(success)

# ==================== MULTI-DISC DOWNLOAD GROUPS ====================

## Creates a download group for a multi-disc batch: one pinned notification
## aggregates progress for every disc instead of one snackbar per disc.
## Returns "" when the batch doesn't warrant grouping (single disc).
func _create_download_group(game: GameResource, entries: Array[Dictionary], suppress_notification: bool) -> String:
	if suppress_notification or entries.size() < 2:
		return ""
	var group_id := "discs_" + str(game.romm_id)
	# Fold into an still-open group for the same game rather than stacking a
	# second notification (e.g. re-queue while the first batch is in flight).
	var group: Dictionary = _groups.get(group_id, {
		"label": game.get_display_name(),
		"total": 0,
		"failed": [],
		"sizes": {},        # disc_id -> expected bytes
		"settled_ids": {},  # disc_id -> true
		"item_map": {},     # item_id -> disc_id
		"notification_id": -1,
	})
	for entry in entries:
		var disc_id: int = entry["id"]
		if group.sizes.has(disc_id):
			continue
		group.sizes[disc_id] = int(entry.get("file_size", 0))
		group.total += 1
	_groups[group_id] = group
	return group_id

## Links a queued download item to a group disc and shows the group
## notification on first use.
func _register_group_item(group_id: String, item_id: String, disc_id: int, expected_size: int) -> void:
	if group_id == "" or not _groups.has(group_id):
		return
	var group: Dictionary = _groups[group_id]
	group.item_map[item_id] = disc_id
	if expected_size > 0:
		group.sizes[disc_id] = expected_size
	elif not group.sizes.has(disc_id):
		group.sizes[disc_id] = 0
	_ensure_group_notification(group_id)

## Marks a group disc as terminally settled (success or failure). When every
## disc has settled, dismisses the group notification and shows one summary.
func _settle_group_disc(group_id: String, disc_id: int, success: bool, disc_label: String = "") -> void:
	if group_id == "" or not _groups.has(group_id):
		return
	var group: Dictionary = _groups[group_id]
	if group.settled_ids.has(disc_id):
		return
	group.settled_ids[disc_id] = true
	if not success:
		group.failed.append(disc_label if disc_label != "" else "Disc " + str(disc_id))
	if group.settled_ids.size() >= group.total:
		_finish_download_group(group_id)

func _on_group_download_completed(item_id: String, success: bool, _message: String) -> void:
	for group_id in _groups:
		var group: Dictionary = _groups[group_id]
		if group.item_map.has(item_id):
			var disc_id: int = group.item_map[item_id]
			var label := ""
			# Item is still live when download_completed fires (emit happens
			# before _active_items.erase), so grab its file name for errors.
			var item := get_item(item_id)
			if item:
				label = item.destination_path.get_file()
			_settle_group_disc(group_id, disc_id, success, label)
			return

func _ensure_group_notification(group_id: String) -> void:
	var group: Dictionary = _groups.get(group_id, {})
	if group.is_empty() or group.notification_id != -1:
		return
	group.notification_id = SystemManager.notifications.show_notification(
		group.label + "...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		func() -> float:
			return _group_progress(group_id),
		func(progress_frac: float) -> String:
			return _group_progress_text(group_id, progress_frac),
		false,  # pulsing
		true  # pinned
	)

## Returns [done_bytes, total_bytes] across every disc in the group. Settled
## discs count in full; in-flight discs contribute progress x expected size.
func _group_bytes(group_id: String) -> Array:
	var group: Dictionary = _groups.get(group_id, {})
	var total_bytes: int = 0
	var done_bytes: int = 0
	for disc_id in group.get("sizes", {}):
		var size: int = group.sizes[disc_id]
		total_bytes += size
		if group.settled_ids.has(disc_id):
			done_bytes += size
		else:
			var item := _find_group_item(group_id, disc_id)
			if item:
				done_bytes += int(item.progress * size)
	return [done_bytes, total_bytes]

func _group_progress(group_id: String) -> float:
	var group: Dictionary = _groups.get(group_id, {})
	if group.is_empty():
		return 1.0
	var bytes: Array = _group_bytes(group_id)
	if bytes[1] > 0:
		return clampf(float(bytes[0]) / float(bytes[1]), 0.0, 1.0)
	# Sizes unknown: fall back to disc fraction
	return float(group.settled_ids.size()) / max(1, group.total)

func _group_progress_text(group_id: String, progress_frac: float) -> String:
	var group: Dictionary = _groups.get(group_id, {})
	if group.is_empty():
		return ""
	var text := "%s: %d/%d discs" % [group.label, group.settled_ids.size(), group.total]
	var bytes: Array = _group_bytes(group_id)
	if bytes[1] > 0:
		text += " - %.1f/%.1f GB (%d%%)" % [bytes[0] / 1e9, bytes[1] / 1e9, int(progress_frac * 100)]
	else:
		text += " (%d%%)" % int(progress_frac * 100)
	if not group.failed.is_empty():
		text += " - %d failed" % group.failed.size()
	return text

func _finish_download_group(group_id: String) -> void:
	var group: Dictionary = _groups.get(group_id, {})
	if group.is_empty():
		return
	_groups.erase(group_id)
	if group.notification_id != -1:
		SystemManager.notifications.dismiss_notification(group.notification_id)
	if group.failed.is_empty():
		SystemManager.notifications.show_notification(
			"All %d discs downloaded for %s" % [group.total, group.label],
			SystemManager.notifications.Type.SUCCESS,
			null,
			5.0
		)
	else:
		SystemManager.notifications.show_notification(
			"%s: failed to download %s" % [group.label, ", ".join(group.failed)],
			SystemManager.notifications.Type.ERROR,
			null,
			10.0
		)

## Finds the queued/active download item for a group disc
func _find_group_item(group_id: String, disc_id: int) -> QueueItem:
	for item in _queue:
		if item.group_id == group_id and item.romm_id == disc_id:
			return item
	for active_id in _active_items:
		var item: QueueItem = _active_items[active_id]
		if item.group_id == group_id and item.romm_id == disc_id:
			return item
	return null

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
			# Dismiss the progress notification: cancel bypasses the completion
			# path, and the snackbar's progress callable would freeze below 1.0
			# so its auto-dismiss never fires.
			if item.notification_id != -1:
				SystemManager.notifications.dismiss_notification(item.notification_id)
				item.notification_id = -1
			_cleanup_item(item)
			_queue.remove_at(i)
			queue_changed.emit()
			# Settle completion watchers / download groups: without this a
			# cancelled batched disc would leave on_all_done (and the unified
			# group notification) pending forever.
			download_completed.emit(item_id, false, "Cancelled")
			return true

	# Cancel if active
	if _active_items.has(item_id):
		var item = _active_items[item_id]
		if item.http_request:
			item.http_request.cancel_request()
		item.http_request = null
		if item.notification_id != -1:
			SystemManager.notifications.dismiss_notification(item.notification_id)
			item.notification_id = -1
		# Clean up chunked download resources if this was a chunked download
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		queue_changed.emit()
		download_completed.emit(item_id, false, "Cancelled")
		_active_items.erase(item_id)
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

## Finds the ID of a queued or active item by URL ("" if none). queue_download
## rejects duplicate URLs with "", so callers can use this to attach to the
## in-flight item instead of treating the rejection as a failure.
func _find_item_id_by_url(url: String) -> String:
	for item in _queue:
		if item.url == url:
			return item.id
	for active_id in _active_items:
		if _active_items[active_id].url == url:
			return active_id
	return ""

## Returns true if any download belonging to this game (main rom or any disc
## sibling) is currently queued or in flight.
func is_game_download_in_progress(game: GameResource) -> bool:
	if not game:
		return false
	var ids := {game.romm_id: true}
	for entry in game.get_disc_entries():
		ids[entry["id"]] = true
	return has_item(func(item: QueueItem) -> bool:
		return item.type == "game" and (item.game_resource == game or ids.has(item.romm_id))
	)

## Aggregate progress for a game's in-flight downloads, for user-facing
## messaging: {active, discs_total, discs_done, progress (0.0-1.0)}.
func get_game_download_summary(game: GameResource) -> Dictionary:
	var summary := {"active": false, "discs_total": 0, "discs_done": 0, "progress": 0.0}
	if not game:
		return summary
	var group_id := "discs_" + str(game.romm_id)
	if _groups.has(group_id):
		var group: Dictionary = _groups[group_id]
		summary.active = true
		summary.discs_total = group.total
		summary.discs_done = group.settled_ids.size()
		summary.progress = _group_progress(group_id)
		return summary
	# No group: aggregate any loose game items for this game
	var ids := {game.romm_id: true}
	for entry in game.get_disc_entries():
		ids[entry["id"]] = true
	var total := 0
	var frac_sum := 0.0
	for item in get_queued() + get_active():
		if item.type == "game" and (item.game_resource == game or ids.has(item.romm_id)):
			total += 1
			frac_sum += item.progress
	if total > 0:
		summary.active = true
		summary.discs_total = total
		summary.progress = frac_sum / total
	return summary

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
	if SystemManager.platform.is_android():
		OS.set_low_processor_usage_mode(true)
		print("[SystemManager.download] Enabled low processor mode for download")

	# Initialize unified progress tracking
	var prog = DownloadProgress.new()
	prog.start_time_ms = Time.get_ticks_msec()
	prog.last_progress_time_ms = prog.start_time_ms
	prog.last_downloaded_bytes = 0
	_download_progress[item.id] = prog

	# Show notification with progress (unless suppressed for batch downloads).
	# Grouped (multi-disc) items fold into a single shared group notification.
	if not item.suppress_notification and item.group_id == "":
		if item.expected_file_size > 0:
			item.notification_id = SystemManager.notifications.show_notification(
				item.name + "...",
				SystemManager.notifications.Type.INFO,
				null,
				0.0,
				func() -> float:
					return item.progress,
				func(progress_frac: float) -> String:
					var mb_downloaded = int(item.expected_file_size * progress_frac / (1024.0 * 1024.0))
					var mb_total = int(item.expected_file_size / (1024.0 * 1024.0))
					return "%s: %d/%d MB (%d%%)" % [item.name, mb_downloaded, mb_total, int(progress_frac * 100)],
				false,  # pulsing
				true  # pinned
			)
		else:
			# No expected file size - use pulsing notification
			item.notification_id = SystemManager.notifications.show_notification(
				item.name + "...",
				SystemManager.notifications.Type.INFO,
				null,
				0.0,
				Callable(),
				Callable(),
				true,  # pulsing
				true  # pinned
			)

	download_started.emit(item.id)

	# Start looping sound while downloading (capped so long downloads don't
	# loop the SFX forever; it still stops early when the download finishes)
	if SystemManager.audio and not item.suppress_sound:
		SystemManager.audio.play_loop_while("loading_2", func():
			var still_active = item.status == "downloading"
			return still_active
		, 0.0, DOWNLOAD_LOOP_MAX_PLAYS)

	# Make HTTP request through SystemManager.network
	# Always include User-Agent to prevent blocking (archive.org requires this)
	# Credentials attach ONLY when the URL is exactly the configured RomM
	# origin - never leak auth to redirects or off-host URLs (KYD-10).
	var headers = ["User-Agent: Kyodai-Launcher/1.0"]
	headers.append_array(SystemManager.network.get_auth_headers_for_url(item.url))

	# Check if this is a large file that should use chunked downloading
	# NOTE: Emulator downloads excluded from chunking because GitHub redirects (302)
	# break the HTTPClient-based chunk downloader. http_download_file handles redirects.
	var is_large_file = item.type == "game" or item.type == "emulator_core"
	var should_use_chunking = is_large_file and item.expected_file_size > CHUNKED_DOWNLOAD_THRESHOLD

	if should_use_chunking:
		if DEBUG_LOG: print("[SystemManager.download] Checking Range support for chunked download: " + item.name + " (size=" + str(item.expected_file_size) + ")")
		_check_range_and_start_chunked(item, headers)
		return

	# All downloads now stream directly to disk via HTTPRequest.download_file
	# This avoids memory issues with large files (games, emulators, cores)
	print("[SystemManager.download] Using file-based download for: " + item.name + " (type=" + item.type + ")")
	if DEBUG_LOG: print("[SystemManager.download] Destination path: " + item.destination_path)
	item.download_info = SystemManager.network.http_download_file(
		item.url,
		item.destination_path,
		headers,
		func(success: bool, status_code: int, error_msg: String):
			_on_file_download_complete(item, success, error_msg, status_code),
		item.expected_file_size
	)

	if item.download_info.is_empty():
		item.status = "failed"
		item.error_message = "Failed to start download"
		_cleanup_item(item)
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item.id)
		queue_changed.emit()
		_process_queue()
		return

	item.http_request = item.download_info.get("http", null)

	if item.http_request == null:
		item.status = "failed"
		item.error_message = "Failed to start download"
		_cleanup_item(item)
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item.id)
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
		push_error("[SystemManager.download] Failed to connect to host: " + url_parts.host + " error: " + str(err))
		return null

	# Wait for connection to establish
	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		OS.delay_usec(100)

	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		push_error("[SystemManager.download] Failed to connect, status: " + str(http.get_status()))
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
		"3ds", "wiiu", "ngc", "wii", "ps2", "psp", "ps3", "ps4", "switch", "vita", "xbox360", "psx":
			return true
		_:
			return false

# ==================== CHUNKED DOWNLOAD METHODS ====================

func _check_range_and_start_chunked(item: QueueItem, headers: Array):
	"""Check if server supports Range requests, then start chunked or regular download"""
	SystemManager.network.check_range_support(item.url, headers, func(supports_range: bool, _error_msg: String, content_length: int = 0):
		if supports_range:
			print("[SystemManager.download] Server supports Range, starting chunked download for: " + item.name)

			# Validate and update expected file size from server's Content-Length
			if content_length > 0:
				if item.expected_file_size != content_length:
					if DEBUG_LOG: print("[SystemManager.download] File size mismatch for " + item.name + ": expected " + str(item.expected_file_size) + " bytes, server reports " + str(content_length) + " bytes")
					if DEBUG_LOG: print("[SystemManager.download] Using server-reported size: " + str(content_length) + " bytes")
					item.expected_file_size = content_length
					# Also update the game resource if available
					if item.game_resource:
						item.game_resource.file_size = content_length
			else:
				if DEBUG_LOG: print("[SystemManager.download] Warning: Server did not provide Content-Length for " + item.name + ", using expected size: " + str(item.expected_file_size))

			_start_chunked_download(item, headers)
		else:
			print("[SystemManager.download] Server doesn't support Range, falling back to regular download for: " + item.name)
			# Fall back to regular file-based download
			item.download_info = SystemManager.network.http_download_file(
				item.url,
				item.destination_path,
				headers,
			func(success: bool, status_code: int, err: String):
				_on_file_download_complete(item, success, err, status_code),
				item.expected_file_size
			)

			if item.download_info.is_empty():
				item.status = "failed"
				item.error_message = "Failed to start download"
				_cleanup_item(item)
				download_completed.emit(item.id, false, item.error_message)
				_active_items.erase(item.id)
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
	var temp_dir = "user://temp/chunks/" + _get_chunk_temp_dir_name(item.destination_path)
	if not FSM.make_dir_recursive(temp_dir):
		push_error("[SystemManager.download] Failed to create chunk temp directory: " + temp_dir)
		item.status = "failed"
		item.error_message = "Failed to create temp directory"
		_cleanup_item(item)
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item.id)
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
	# Android: probe flush mode first (chunks are written into the destination
	# as they complete, eliminating the final copy). Fall back to streaming
	# into a temp-dir partial, then copy/move it to the destination.
	var in_place_assembly = false
	if IN_PLACE_CHUNKED_DOWNLOADS:
		if SystemManager.platform.is_android():
			if _prepare_flush_destination(chunked_info, file_size):
				chunked_info.flush_mode = true
				if DEBUG_LOG: print("[SystemManager.download] Using flush-mode chunked download for: " + item.name)
			else:
				chunked_info.partial_path = temp_dir + "/partial"
				in_place_assembly = true
				if DEBUG_LOG: print("[SystemManager.download] Flush mode unavailable, using Android temp-dir in-place assembly for: " + item.name)
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
					push_error("[SystemManager.download] Existing partial file size mismatch (" + str(partial_size) + " vs " + str(file_size) + "); restarting sparse file")
					FSM.delete_file(chunked_info.partial_path)

			if partial_ok:
				in_place_assembly = true
				if DEBUG_LOG: print("[SystemManager.download] Resuming in-place sparse assembly for: " + item.name)
			elif await _create_sparse_file_async(chunked_info.partial_path, file_size):
				in_place_assembly = true
				if DEBUG_LOG: print("[SystemManager.download] Using in-place sparse assembly for: " + item.name)
			else:
				if DEBUG_LOG: print("[SystemManager.download] In-place sparse assembly not available, using temp files for: " + item.name)
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
		if DEBUG_LOG: print("[SystemManager.download] Resuming download from state file for: " + item.name + " (" + str(state.get("chunks", []).size()) + " chunks recorded)")
	_apply_download_state(chunked_info, state)
	_save_download_state(chunked_info, true)

	# On Android, a fresh download should not inherit a stale temp partial.
	# (Resume state would have been applied above if it were valid.)
	if SystemManager.platform.is_android():
		if state.is_empty():
			if not chunked_info.partial_path.is_empty() and FSM.file_exists(chunked_info.partial_path):
				FSM.delete_file(chunked_info.partial_path)
			# Also remove any leftover legacy chunk temp files
			for chunk in chunked_info.chunks:
				if FSM.file_exists(chunk.temp_path):
					FSM.delete_file(chunk.temp_path)

		# In-place mode only: ensure the partial file exists so worker threads
		# can open it READ_WRITE. On resume the existing partial is preserved.
		if chunked_info.in_place_assembly and not FSM.file_exists(chunked_info.partial_path):
			var partial_create = FileAccess.open(chunked_info.partial_path, FileAccess.WRITE)
			if partial_create:
				partial_create.close()
			else:
				push_error("[SystemManager.download] Failed to create Android partial file: " + chunked_info.partial_path)
				item.status = "failed"
				item.error_message = "Failed to create partial file"
				_cleanup_item(item)
				download_completed.emit(item.id, false, item.error_message)
				_active_items.erase(item.id)
				queue_changed.emit()
				_process_queue()
				return

	# Flush mode resume: chunks that completed but were never flushed (crash
	# between completion and flush) still have temp files - flush them now.
	if chunked_info.flush_mode:
		for chunk in chunked_info.chunks:
			if chunk.completed and not chunk.flushed and FSM.file_exists(chunk.temp_path):
				_flush_chunk_async(item.id, chunk.index)

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

	print("[SystemManager.download] Starting chunked download with " + str(num_chunks) + " chunks for: " + item.name)
	if DEBUG_LOG: print("[SystemManager.download] Using concurrency=" + str(concurrency) + " (thread pool=" + str(thread_count) + ")")

	# If every chunk is already complete on disk, go straight to verification/reassembly
	if chunked_info.chunks_completed >= chunked_info.total_chunks:
		print("[SystemManager.download] All chunks already present on disk for: " + item.name)
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

	if DEBUG_LOG: print("[SystemManager.download] Queuing " + str(chunk_items.size()) + " pending chunks to thread pool for: " + item.name)

	# Start a watchdog that detects stuck chunk workers and falls back to single-stream.
	_start_chunked_watchdog_timer(item.id, headers)

	# Workers record byte counts under a mutex; this timer emits throttled progress.
	_start_chunked_progress_timer(item.id)

	# Use SystemManager.memory's download thread pool
	chunked_info.batch_id = await SystemManager.memory.queue_parallel_downloads(
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

	# Progress is emitted by the progress timer polling worker-recorded byte counts

## Downloads a single chunk on a worker thread using HTTPClient
## Called by the thread pool - runs on a background thread
## Uses connection pooling to reuse TLS connections across chunks
## Downloads a single chunk on a worker thread using HTTPClient.
## Returns a result dictionary with success, hashes, and retry hints.
## Called by the thread pool - runs on a background thread.
func _is_chunk_work_cancelled(item_id: String) -> bool:
	"""True when the app is shutting down or the chunked download was cleaned up (cancelled)."""
	return MemorySubManager.is_shutting_down() or not _chunked_downloads.has(item_id)

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
	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Starting chunk " + str(chunk_index) + " on thread " + str(thread_index) + " at time=" + str(chunk_start_time))

	# Parse URL to get components
	var url_parts = SystemManager.network.parse_url(url)

	# Get or create connection from pool (thread-safe access)
	var http: HTTPClient
	var _was_reused = false

	_connection_pool_mutex.lock()
	if _download_connection_pools.has(item_id):
		var connection_pool = _download_connection_pools[item_id]
		if thread_index < connection_pool.size():
			http = connection_pool[thread_index]
			var status_before = http.get_status() if http != null else -1
			if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Thread " + str(thread_index) + " connection status before check: " + str(status_before) + " (CONNECTED=" + str(HTTPClient.STATUS_CONNECTED) + ")")

			# Check for previous chunk finish time to calculate idle time
			var idle_thread_key = item_id + "_" + str(thread_index)
			var prev_finish_time = _thread_chunk_finish_times.get(idle_thread_key, 0)
			if prev_finish_time > 0:
				var idle_time = chunk_start_time - prev_finish_time
				if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Thread " + str(thread_index) + " idle time between chunks: " + str(idle_time) + "ms")

			# Check if connection is still valid WITHOUT creating a new one under lock
			var needs_new_connection = not _is_connection_valid(http)
			if not needs_new_connection:
				_was_reused = true
				if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Thread " + str(thread_index) + " reusing connection (status=" + str(http.get_status()) + ") for chunk " + str(chunk_index))
			_connection_pool_mutex.unlock()

			# Create connection OUTSIDE the mutex to avoid blocking other threads during TCP/TLS handshake
			if needs_new_connection:
				if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Thread " + str(thread_index) + " connection invalid, creating new for chunk " + str(chunk_index))
				http = _create_connection(url_parts)
				if http != null:
					_connection_pool_mutex.lock()
					connection_pool[thread_index] = http
					_connection_pool_mutex.unlock()
					if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Thread " + str(thread_index) + " created new connection (status=" + str(http.get_status()) + ")")
		else:
			push_error("[SystemManager.download] Thread index out of bounds: " + str(thread_index))
			_connection_pool_mutex.unlock()
			result.error = "Thread index out of bounds"
			return result
	else:
		# Pool was cleaned up by cancel/fallback; this task is a no-op.
		_connection_pool_mutex.unlock()
		result.error = "aborted"
		return result

	if http == null:
		push_error("[SystemManager.download] Failed to get/create connection for chunk " + str(chunk_index))
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
				var existing_hash = hasher.finish().hex_encode()
				result.actual_hash = existing_hash
				result.bytes_downloaded = partial_size

				if not expected_hash.is_empty() and existing_hash != expected_hash:
					# Existing file is corrupt; force a re-download
					result.success = false
					result.should_delete_partial = true
					result.error = "Hash mismatch on existing complete chunk"
					if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " existing file hash mismatch, will re-download")
					return result

				result.success = true
				result.expected_hash = expected_hash if not expected_hash.is_empty() else existing_hash
				var verified_thread_key = item_id + "_" + str(thread_index)
				_connection_pool_mutex.lock()
				_thread_chunk_finish_times[verified_thread_key] = Time.get_ticks_msec()
				_connection_pool_mutex.unlock()
				if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " already complete on disk, verified " + str(partial_size) + " bytes")
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
				if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " resuming from byte " + str(start_byte) + " (already have " + str(partial_size) + " bytes)")

	# Add Range header (uses possibly resumed start_byte)
	request_headers.append("Range: bytes=%d-%d" % [start_byte, end_byte])

	# Open file for writing/appending
	if in_place:
		if final_file_mutex == null:
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " in-place assembly requested without mutex")
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
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " failed to open partial file for in-place chunk write: " + partial_path)
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
		push_error("[SystemManager.download] Failed to create chunk file: " + temp_path)
		result.error = "Failed to create chunk file"
		return result

	# Mark chunk as in-progress for watchdog visibility
	if _chunked_downloads.has(item_id):
		var chunked_info = _chunked_downloads[item_id]
		if chunk_index >= 0 and chunk_index < chunked_info.chunks.size():
			chunked_info.chunks[chunk_index].in_progress = true

	# Make the request
	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " making request, connection status: " + str(http.get_status()))

	var err = http.request(HTTPClient.METHOD_GET, url_parts.path + url_parts.query, request_headers)
	if err != OK:
		push_error("[SystemManager.download] Failed to make request: " + str(err))
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
			if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " still requesting... (poll " + str(poll_count) + ")")

		if _is_chunk_work_cancelled(item_id):
			file.close()
			http.close()
			result.error = "cancelled"
			return result

		if Time.get_ticks_msec() - request_start_time > CHUNK_REQUEST_TIMEOUT_MS:
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " request phase timed out after " + str(CHUNK_REQUEST_TIMEOUT_MS) + "ms")
			file.close()
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Request phase timed out"
			return result

		OS.delay_msec(10)

	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " finished requesting after " + str(poll_count) + " polls, status: " + str(http.get_status()))

	# Get and log response headers
	var response_headers = http.get_response_headers()
	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " response headers: " + str(response_headers))

	# Check response code
	var response_code = http.get_response_code()
	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " response code: " + str(response_code))

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
		push_error("[SystemManager.download] Chunk " + str(chunk_index) + " HTTP error " + str(response_code) + ": " + error_body)
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
						if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " Content-Range validated: " + content_range_header)
					else:
						push_error("[SystemManager.download] Chunk " + str(chunk_index) + " Content-Range mismatch. Expected: bytes=" + str(start_byte) + "-" + str(end_byte) + ", Got: " + content_range_header)
				else:
					push_error("[SystemManager.download] Chunk " + str(chunk_index) + " Invalid Content-Range format: " + content_range_header)
			else:
				push_error("[SystemManager.download] Chunk " + str(chunk_index) + " Failed to compile Content-Range regex")
		else:
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " Missing Content-Range header for 206 response")

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

		if _is_chunk_work_cancelled(item_id):
			file.close()
			http.close()
			result.error = "cancelled"
			return result

		if current_time > chunk_deadline_ms:
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " exceeded max total time of " + str(CHUNK_MAX_TOTAL_TIME_MS) + "ms")
			file.close()
			_invalidate_pool_connection(http, item_id, thread_index)
			result.error = "Exceeded max total time"
			return result

		if current_time - last_byte_time > CHUNK_STALL_TIMEOUT_MS:
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " stalled: no data for " + str(CHUNK_STALL_TIMEOUT_MS) + "ms")
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

			# Record bytes for the main-thread progress timer (cheap mutex write)
			_record_chunk_bytes_downloaded(chunk_data.item_id, chunk_index, bytes_downloaded)
			if DEBUG_LOG and bytes_downloaded - last_progress_emit >= 10 * 1024 * 1024:
				last_progress_emit = bytes_downloaded
				if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " progress: " + str(bytes_downloaded / (1024.0 * 1024.0)) + "MB")
		else:
			# No data available, wait a bit before checking again
			OS.delay_usec(1000)  # 1ms micro-sleep to prevent busy-waiting

	file.close()

	# Verify downloaded size and (when possible) on-disk chunk
	if bytes_downloaded != expected_chunk_size:
		push_error("[SystemManager.download] Chunk " + str(chunk_index) + " size mismatch: expected " + str(expected_chunk_size) + " bytes, got " + str(bytes_downloaded) + " bytes")
		_invalidate_pool_connection(http, item_id, thread_index)
		result.error = "Size mismatch"
		result.should_delete_partial = not in_place
		return result

	if not in_place:
		if not FileAccess.file_exists(temp_path):
			push_error("[SystemManager.download] Chunk file not found after download: " + temp_path)
			result.error = "Chunk file not found after download"
			result.should_delete_partial = true
			return result

		var verify_file = FileAccess.open(temp_path, FileAccess.READ)
		if not verify_file:
			push_error("[SystemManager.download] Failed to open chunk file for verification: " + temp_path)
			result.error = "Failed to open chunk file for verification"
			result.should_delete_partial = true
			return result

		var actual_size = verify_file.get_length()
		verify_file.close()

		if actual_size != expected_chunk_size:
			push_error("[SystemManager.download] Chunk " + str(chunk_index) + " size mismatch: expected " + str(expected_chunk_size) + " bytes, got " + str(actual_size) + " bytes")
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
		push_error("[SystemManager.download] Chunk " + str(chunk_index) + " hash mismatch: expected " + expected_hash + ", got " + actual_hash)
		_invalidate_pool_connection(http, item_id, thread_index)
		result.error = "Hash mismatch"
		result.should_delete_partial = true
		return result

	var chunk_end_time = Time.get_ticks_msec()
	var download_duration = chunk_end_time - chunk_start_time
	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " finished body after " + str(body_poll_count) + " polls, status: " + str(http.get_status()))
	if DEBUG_LOG: print("[SystemManager.download] [DEBUG] Chunk " + str(chunk_index) + " download duration: " + str(download_duration) + "ms")

	# Track finish time for this thread for debugging connection reuse (mutex-protected)
	var thread_key = item_id + "_" + str(thread_index)
	_connection_pool_mutex.lock()
	_thread_chunk_finish_times[thread_key] = chunk_end_time
	_connection_pool_mutex.unlock()

	if bytes_downloaded == 0:
		push_error("[SystemManager.download] Downloaded 0 bytes for chunk " + str(chunk_index))
		result.error = "Downloaded 0 bytes"
		result.should_delete_partial = true
		return result

	result.success = true
	result.bytes_downloaded = bytes_downloaded
	if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " completed successfully with " + str(bytes_downloaded) + " bytes (hash=" + actual_hash + ")")
	return result

## Updates progress when a chunk completes via thread pool
func _update_chunk_download_progress(item_id: String, chunk_index: int, result: Variant):
	if not _chunked_downloads.has(item_id):
		return

	if chunk_index < 0 or chunk_index >= _chunked_downloads[item_id].chunks.size():
		push_error("[SystemManager.download] Invalid chunk index in progress update: " + str(chunk_index))
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	var chunk = chunked_info.chunks[chunk_index]

	var success = false
	var actual_hash = ""
	var expected_hash = ""
	var should_delete_partial = false
	var _bytes_downloaded = 0

	if result is Dictionary:
		success = result.get("success", false)
		actual_hash = result.get("actual_hash", "")
		expected_hash = result.get("expected_hash", "")
		should_delete_partial = result.get("should_delete_partial", false)
		_bytes_downloaded = result.get("bytes_downloaded", 0)
	elif result is bool:
		success = result
	else:
		push_error("[SystemManager.download] Unexpected chunk result type: " + str(typeof(result)))
		return

	chunk.in_progress = false

	if success:
		if not chunk.completed:
			chunk.completed = true
			chunk.failed = false
			chunk.actual_hash = actual_hash
			chunk.expected_hash = expected_hash
			chunked_info.chunks_completed += 1
			if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " completed successfully (total: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")
			if chunked_info.flush_mode:
				_flush_chunk_async(item_id, chunk_index)
	else:
		chunk.failed = true
		chunk.actual_hash = actual_hash
		chunk.expected_hash = expected_hash
		# Reset progress tracking for retry
		chunked_info.progress_mutex.lock()
		chunk.temp_bytes_downloaded = 0
		chunked_info.progress_mutex.unlock()

		# Delete corrupt/mismatched partial files so the retry starts clean
		if should_delete_partial and FSM.file_exists(chunk.temp_path):
			FSM.delete_file(chunk.temp_path)
			if DEBUG_LOG: print("[SystemManager.download] Deleted partial chunk file after failure: " + chunk.temp_path)

		if DEBUG_LOG: print("[SystemManager.download] Chunk " + str(chunk_index) + " failed (total completed: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + ")")

	# Persist the updated bitmap after every chunk status change, but coalesce
	# rapid writes to avoid disk I/O throttling fast downloads.
	_save_download_state(chunked_info)

	# Update overall progress based on actual bytes
	chunked_info.progress_mutex.lock()
	var total_downloaded_bytes = 0
	for c in chunked_info.chunks:
		if c.completed:
			total_downloaded_bytes += (c.end_byte - c.start_byte + 1)
		else:
			total_downloaded_bytes += c.temp_bytes_downloaded
	chunked_info.progress_mutex.unlock()

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

	if DEBUG_LOG: print("[SystemManager.download] Thread pool callback: " + str(chunked_info.chunks_completed) + "/" + str(chunked_info.total_chunks) + " chunks done")

	# Flush mode: chunk data is already in the destination (or in flight).
	# Skip file-based verification/reassembly; finalize once flushes settle.
	if chunked_info.flush_mode:
		if chunked_info.chunks_completed >= chunked_info.total_chunks:
			chunked_info.all_chunks_done = true
			_maybe_finalize_flush_download(item_id)
		else:
			_handle_failed_chunks_thread_pool(item_id, headers)
		return

	# Check if all chunks completed successfully
	if chunked_info.chunks_completed >= chunked_info.total_chunks:
		if DEBUG_LOG: print("[SystemManager.download] All chunks marked complete for: " + item.name + ", verifying before finalising...")

		var missing_or_bad_chunks = []
		if chunked_info.in_place_assembly:
			# For sparse in-place assembly, verify the partial file size and per-chunk hashes.
			if not FileAccess.file_exists(chunked_info.partial_path):
				push_error("[SystemManager.download] Sparse partial file missing: " + chunked_info.partial_path)
				missing_or_bad_chunks.append_array(chunked_info.chunks)
			else:
				var verify_file = FileAccess.open(chunked_info.partial_path, FileAccess.READ)
				if verify_file:
					var actual_size = verify_file.get_length()
					verify_file.close()
					if actual_size != item.expected_file_size:
						push_error("[SystemManager.download] Sparse partial file size mismatch: expected " + str(item.expected_file_size) + ", got " + str(actual_size))
						missing_or_bad_chunks.append_array(chunked_info.chunks)
				else:
					push_error("[SystemManager.download] Cannot open sparse partial file for verification: " + chunked_info.partial_path)
					missing_or_bad_chunks.append_array(chunked_info.chunks)

			if missing_or_bad_chunks.size() == 0:
				for chunk in chunked_info.chunks:
					if not chunk.expected_hash.is_empty() and not chunk.actual_hash.is_empty() and chunk.actual_hash != chunk.expected_hash:
						push_error("[SystemManager.download] Chunk " + str(chunk.index) + " hash mismatch despite being marked complete: expected " + chunk.expected_hash + ", got " + chunk.actual_hash)
						missing_or_bad_chunks.append(chunk)
		else:
			# Verify chunk files actually exist on disk and pass integrity checks
			for chunk in chunked_info.chunks:
				if not FileAccess.file_exists(chunk.temp_path):
					push_error("[SystemManager.download] Chunk file missing despite being marked complete: " + chunk.temp_path)
					missing_or_bad_chunks.append(chunk)
				else:
					var verify_file = FileAccess.open(chunk.temp_path, FileAccess.READ)
					if verify_file:
						var actual_size = verify_file.get_length()
						verify_file.close()
						var expected_size = chunk.end_byte - chunk.start_byte + 1
						if actual_size != expected_size:
							push_error("[SystemManager.download] Chunk " + str(chunk.index) + " size mismatch despite being marked complete: expected " + str(expected_size) + ", got " + str(actual_size))
							missing_or_bad_chunks.append(chunk)
						elif not chunk.expected_hash.is_empty() and not chunk.actual_hash.is_empty() and chunk.actual_hash != chunk.expected_hash:
							push_error("[SystemManager.download] Chunk " + str(chunk.index) + " hash mismatch despite being marked complete: expected " + chunk.expected_hash + ", got " + chunk.actual_hash)
							missing_or_bad_chunks.append(chunk)
					else:
						push_error("[SystemManager.download] Cannot open chunk file despite being marked complete: " + chunk.temp_path)
						missing_or_bad_chunks.append(chunk)

		if missing_or_bad_chunks.size() > 0:
			if DEBUG_LOG: print("[SystemManager.download] Found " + str(missing_or_bad_chunks.size()) + " chunks marked complete but files missing/bad. Resetting for retry...")
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
		if DEBUG_LOG: print("[SystemManager.download] Not all chunks completed, checking for retries...")
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
		if DEBUG_LOG: print("[SystemManager.download] Retrying " + str(failed_chunks.size()) + " failed chunks for: " + item.name)

		var concurrency = chunked_info.concurrency if chunked_info.concurrency > 0 else _get_max_chunk_concurrency()
		var chunk_sem = _chunk_concurrency_semaphores.get(item_id)

		# Apply exponential backoff to each failed chunk and compute the longest delay
		var max_delay = 0.0
		chunked_info.progress_mutex.lock()
		for chunk in failed_chunks:
			chunk.retry_count += 1
			chunk.failed = false
			chunk.in_progress = false
			chunk.flushed = false
			chunk.temp_bytes_downloaded = 0
			var delay = _chill(chunk)
			if delay > max_delay:
				max_delay = delay
		chunked_info.progress_mutex.unlock()

		_save_download_state(chunked_info, true)

		# Wait before retry using non-blocking timer
		await get_tree().create_timer(max_delay).timeout

		# The download may have been cancelled while we were waiting
		if not _chunked_downloads.has(item_id):
			if DEBUG_LOG: print("[SystemManager.download] Retry aborted for " + item_id + " (chunked download cleaned up)")
			return

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
		chunked_info.batch_id = await SystemManager.memory.queue_parallel_downloads(
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
			print("[SystemManager.download] Chunked download failed after " + str(MAX_CHUNK_RETRIES) + " retries (" + str(failed_chunks.size()) + " chunks still failing); falling back to single-stream for: " + item.name)
			_start_single_stream_fallback(item_id, headers)
		else:
			push_error("[SystemManager.download] Chunks failed with no retries remaining for: " + item.name)
			item.status = "failed"
			item.error_message = "Chunk download failed after " + str(MAX_CHUNK_RETRIES) + " retries"
			# Flush mode (Android) writes chunks directly into the destination;
			# without resume state that partial data must not survive.
			_cleanup_chunked_download(item_id)
			_delete_download_state(item.destination_path)
			if FSM.file_exists(item.destination_path):
				FSM.delete_file(item.destination_path)
			_cleanup_item(item)
			download_completed.emit(item_id, false, item.error_message)
			_active_items.erase(item_id)
			queue_changed.emit()
			_process_queue()

func _start_single_stream_fallback(item_id: String, headers: Array):
	"""Fall back to a single HTTPRequest download when chunked Range downloads fail."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	print("[SystemManager.download] Starting single-stream fallback for: " + item.name)
	if item.notification_id != -1:
		SystemManager.notifications.update_notification_text(
			item.notification_id,
			"Server throttling detected; switching to single-stream download..."
		)

	_cleanup_chunked_download(item_id)
	_delete_download_state(item.destination_path)

	item.download_info = SystemManager.network.http_download_file(
		item.url,
		item.destination_path,
		headers,
		func(success: bool, status_code: int, error_msg: String):
			_on_file_download_complete(item, success, error_msg, status_code),
		item.expected_file_size
	)

	if item.download_info.is_empty():
		item.status = "failed"
		item.error_message = "Failed to start single-stream fallback"
		_cleanup_item(item)
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item.id)
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

## Called from worker thread to update chunk progress in real-time
## Records per-chunk byte counts from download worker threads.
## Only touches the counter under the progress mutex; emission happens on the
## main thread via the progress timer, so no per-update deferred calls are made.
func _record_chunk_bytes_downloaded(item_id: String, chunk_index: int, bytes_downloaded: int):
	if not _chunked_downloads.has(item_id):
		return
	var chunked_info = _chunked_downloads[item_id]
	if chunk_index < 0 or chunk_index >= chunked_info.chunks.size():
		return
	chunked_info.progress_mutex.lock()
	chunked_info.chunks[chunk_index].temp_bytes_downloaded = bytes_downloaded
	chunked_info.progress_mutex.unlock()

func _start_chunked_progress_timer(item_id: String):
	"""Start a timer that polls worker-recorded byte counts and emits progress."""
	if not _chunked_downloads.has(item_id):
		return
	var chunked_info = _chunked_downloads[item_id]
	_stop_chunked_progress_timer(item_id)
	var timer := Timer.new()
	timer.wait_time = 0.25
	timer.one_shot = false
	timer.timeout.connect(_poll_chunk_progress.bind(item_id))
	add_child(timer)
	timer.start()
	chunked_info.progress_timer = timer

func _poll_chunk_progress(item_id: String):
	if not _chunked_downloads.has(item_id):
		_stop_chunked_progress_timer(item_id)
		return

	var chunked_info = _chunked_downloads[item_id]

	chunked_info.progress_mutex.lock()
	var total_downloaded_bytes = 0
	for chunk in chunked_info.chunks:
		if chunk.completed:
			total_downloaded_bytes += (chunk.end_byte - chunk.start_byte + 1)
		else:
			total_downloaded_bytes += chunk.temp_bytes_downloaded
	chunked_info.progress_mutex.unlock()

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
	if DataManager.is_settings_loaded():
		var setting = DataManager.get_setting("download_speed_profile")
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

# ============================================================================
# FLUSH MODE (Android): per-chunk positioned writes into the destination
# ============================================================================

var _flush_signal_connected: bool = false

func _ensure_flush_signal_connected() -> void:
	if _flush_signal_connected:
		return
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		return
	if not plugin.is_connected("chunk_flush_complete", _on_chunk_flush_complete):
		plugin.connect("chunk_flush_complete", _on_chunk_flush_complete)
	_flush_signal_connected = true

## Probes whether the destination supports positioned writes (direct or SAF)
## and preallocates it. Returns true if flush mode can be used.
func _prepare_flush_destination(chunked_info: ChunkedDownloadInfo, file_size: int) -> bool:
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		return false
	_ensure_flush_signal_connected()
	var ok = plugin.call("prepareChunkedDestination", chunked_info.final_path, file_size)
	# JNISingleton marshals Java boolean as int; use truthiness, not == true
	return true if ok else false

## Asks the native plugin to write a completed chunk temp file into the
## destination at its byte offset. Runs async on a Java thread; completion
## arrives via the chunk_flush_complete signal.
func _flush_chunk_async(item_id: String, chunk_index: int) -> void:
	if not _chunked_downloads.has(item_id):
		return
	var chunked_info = _chunked_downloads[item_id]
	if not chunked_info.flush_mode:
		return
	var chunk = chunked_info.chunks[chunk_index]
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		_on_chunk_flush_failed(item_id, chunk_index, "Plugin not available")
		return
	chunked_info.flushes_pending += 1
	var token = item_id + "|" + str(chunk_index)
	var absolute_chunk = ProjectSettings.globalize_path(chunk.temp_path)
	var started = plugin.call("flushChunkAsync", absolute_chunk, chunked_info.final_path, chunk.start_byte, token)
	if not started:
		chunked_info.flushes_pending = maxi(0, chunked_info.flushes_pending - 1)
		_on_chunk_flush_failed(item_id, chunk_index, "Failed to start chunk flush")

func _on_chunk_flush_complete(token: String, success: bool, error: String) -> void:
	var sep = token.rfind("|")
	if sep == -1:
		return
	var item_id = token.substr(0, sep)
	var chunk_index = int(token.substr(sep + 1))
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	if chunk_index < 0 or chunk_index >= chunked_info.chunks.size():
		return
	var chunk = chunked_info.chunks[chunk_index]
	chunked_info.flushes_pending = maxi(0, chunked_info.flushes_pending - 1)

	if success:
		chunk.flushed = true
		chunked_info.flush_retry_counts.erase(chunk_index)
		# Persist before deleting the temp file so a crash here re-flushes
		# from the temp file instead of re-downloading.
		_save_download_state(chunked_info, true)
		if FSM.file_exists(chunk.temp_path):
			FSM.delete_file(chunk.temp_path)
		_maybe_finalize_flush_download(item_id)
	else:
		push_error("[SystemManager.download] Chunk flush failed for chunk " + str(chunk_index) + ": " + error)
		var retries = int(chunked_info.flush_retry_counts.get(chunk_index, 0)) + 1
		chunked_info.flush_retry_counts[chunk_index] = retries
		if retries <= 3:
			var delay = float(retries) * 2.0
			await get_tree().create_timer(delay).timeout
			if not _chunked_downloads.has(item_id):
				return
			if chunk.flushed:
				return  # Another path already flushed it
			_flush_chunk_async(item_id, chunk_index)
		else:
			chunked_info.flush_failed = true
			_fail_flush_download(item_id, "Failed to write chunk " + str(chunk_index) + " to destination: " + error)

func _on_chunk_flush_failed(item_id: String, chunk_index: int, error: String) -> void:
	# Synchronous start failure; route through the same retry logic.
	_on_chunk_flush_complete(item_id + "|" + str(chunk_index), false, error)

## Finalizes a flush-mode download once all chunks are done and every flush
## has landed. The destination is verified by size (per-chunk hashes were
## already validated during download).
func _maybe_finalize_flush_download(item_id: String) -> void:
	if not _chunked_downloads.has(item_id):
		return
	var chunked_info = _chunked_downloads[item_id]
	if not chunked_info.flush_mode or not chunked_info.all_chunks_done:
		return
	if chunked_info.flushes_pending > 0 or chunked_info.flush_failed:
		return
	if chunked_info.chunks_completed < chunked_info.total_chunks:
		return
	for chunk in chunked_info.chunks:
		if not chunk.flushed:
			return

	var item = chunked_info.item
	var plugin = Engine.get_singleton("KyodaiBridge")
	var final_size = int(plugin.call("androidFileSize", chunked_info.final_path)) if plugin != null else -1
	if final_size != item.expected_file_size:
		push_error("[SystemManager.download] Flush-mode final size mismatch: expected " + str(item.expected_file_size) + ", got " + str(final_size))
		_fail_flush_download(item_id, "Destination size mismatch after flush")
		return

	print("[SystemManager.download] Flush-mode download finalized: " + item.name)
	_stop_chunked_progress_timer(item_id)
	_stop_chunked_watchdog_timer(item_id)
	_delete_download_state(chunked_info.final_path)
	_cleanup_chunked_download(item_id)
	_on_file_download_complete(item, true, "")

func _fail_flush_download(item_id: String, error_msg: String) -> void:
	if not _chunked_downloads.has(item_id):
		return
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item
	_stop_chunked_progress_timer(item_id)
	_stop_chunked_watchdog_timer(item_id)
	item.status = "failed"
	item.error_message = error_msg
	_cleanup_chunked_download(item_id)
	_cleanup_item(item)
	download_completed.emit(item_id, false, error_msg)
	_active_items.erase(item_id)
	queue_changed.emit()
	_process_queue()

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
	chunked_info.progress_mutex.lock()
	for chunk in chunked_info.chunks:
		if chunk.completed:
			total_bytes += chunk.end_byte - chunk.start_byte + 1
		else:
			total_bytes += chunk.temp_bytes_downloaded
			if chunk.in_progress:
				in_progress_count += 1
	chunked_info.progress_mutex.unlock()

	print("[SystemManager.download] [Watchdog] item=%s chunks=%d/%d in_progress=%d total_bytes=%d" % [
		item.name, completed_count, chunked_info.total_chunks, in_progress_count, total_bytes])

	var stalled := false
	if total_bytes > chunked_info.watchdog_last_total_bytes:
		chunked_info.watchdog_last_total_bytes = total_bytes
		chunked_info.watchdog_last_progress_time_ms = now
	elif now - chunked_info.watchdog_last_progress_time_ms > CHUNK_STALL_TIMEOUT_MS * 2:
		var elapsed_since_progress: int = now - chunked_info.watchdog_last_progress_time_ms
		if DEBUG_LOG: print("[SystemManager.download] [Watchdog] Chunked download stalled for: " + item.name + " (no progress for " + str(elapsed_since_progress) + "ms, total_bytes=" + str(total_bytes) + ", in_progress=" + str(in_progress_count) + "). Falling back to single-stream.")
		stalled = true

	if not stalled:
		var elapsed: int = now - chunked_info.start_time_ms
		var max_total_time := maxi(30 * 60 * 1000, item.expected_file_size / 2048)
		if elapsed > max_total_time:
			if DEBUG_LOG: print("[SystemManager.download] [Watchdog] Chunked download exceeded max total time for: " + item.name + " (elapsed=" + str(elapsed) + "ms, max_total_time=" + str(max_total_time) + "ms). Falling back to single-stream.")
			stalled = true

	if stalled:
		_stop_chunked_watchdog_timer(item_id)
		_start_single_stream_fallback(item_id, chunked_info.headers)

## Helper to show reassembly notification on main thread (called via call_deferred)
func _show_reassembly_notification(item_id: String, _item_name: String) -> void:
	if not _chunked_downloads.has(item_id):
		return
	var item = _chunked_downloads[item_id].item
	# Grouped (multi-disc) items fold into the shared group notification
	if item.group_id != "":
		return
	item.notification_id = SystemManager.notifications.show_notification(
		"Reassembling chunks, please wait...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),  # No progress callable - using pulsing
		Callable(),  # No text formatter
		true,  # pulsing
		true  # pinned
	)

func _reassemble_chunks(item_id: String):
	"""Reassemble all chunks into the final file - platform-specific implementation"""
	if not _chunked_downloads.has(item_id):
		push_error("[SystemManager.download] No chunked download found for item: " + item_id)
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	if DEBUG_LOG: print("[SystemManager.download] Starting chunk reassembly for: " + item.name)

	# Show reassembly notification immediately
	if not item.suppress_notification:
		if item.notification_id != -1:
			SystemManager.notifications.dismiss_notification(item.notification_id)
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
			push_error("[SystemManager.download] [Reassembly] Pre-check: chunk file missing: " + chunk.temp_path)
			missing_chunks.append(chunk)
		else:
			var verify_file = FileAccess.open(chunk.temp_path, FileAccess.READ)
			if verify_file:
				var actual_size = verify_file.get_length()
				verify_file.close()
				var expected_size = chunk.end_byte - chunk.start_byte + 1
				if actual_size != expected_size:
					push_error("[SystemManager.download] [Reassembly] Pre-check: chunk " + str(chunk.index) + " size mismatch: expected " + str(expected_size) + ", got " + str(actual_size))
					missing_chunks.append(chunk)
			else:
				push_error("[SystemManager.download] [Reassembly] Pre-check: cannot open chunk file: " + chunk.temp_path)
				missing_chunks.append(chunk)

	if missing_chunks.size() > 0:
		if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Found " + str(missing_chunks.size()) + " missing/bad chunks before reassembly. This should have been caught earlier - failing download.")
		item.status = "failed"
		item.error_message = "Chunk files missing or corrupted before reassembly"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		download_completed.emit(item_id, false, item.error_message)
		_active_items.erase(item_id)
		queue_changed.emit()
		_process_queue()
		return

	# Platform-specific reassembly
	if SystemManager.platform.is_android():
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

	if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Calling native reassembly for: " + item.name + " (" + str(chunk_paths.size()) + " chunks) -> " + output_absolute_path)

	# Call native Java reassembly on the main thread.
	# NOTE: This blocks the UI for the duration of reassembly, but a clear
	# notification is shown beforehand so the user knows what is happening.
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		push_error("[SystemManager.download] KyodaiBridge plugin not available for reassembly")
		_stop_chunked_progress_timer(item_id)
		item.status = "failed"
		item.error_message = "Plugin not available for reassembly"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item_id)
		queue_changed.emit()
		_process_queue()
		return

	var success = plugin.call("reassembleChunks", chunk_paths_json, output_absolute_path)

	if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Native reassembly returned: " + str(success) + " for: " + item.name)

	if not success:
		push_error("[SystemManager.download] Native reassembly failed for: " + item.name)
		# Clean up failed final file
		if FSM.file_exists(reassembly_temp_path):
			FSM.delete_file(reassembly_temp_path)

		_stop_chunked_progress_timer(item_id)
		item.status = "failed"
		item.error_message = "Failed to reassemble chunks"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item_id)
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
		if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Starting desktop reassembly for: " + item.name + " -> " + final_path)

		# Open final file for writing
		var final_file = FileAccess.open(final_path, FileAccess.WRITE)
		if not final_file:
			push_error("[SystemManager.download] [Reassembly] Failed to create final file: " + final_path)
			return false

		# Append each chunk to final file with buffered I/O to avoid memory spikes
		const BUFFER_SIZE = 8 * 1024 * 1024  # 8MB buffer for streaming

		for chunk_data in chunks_data:
			var chunk_path = chunk_data.temp_path

			if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Appending chunk " + str(chunk_data.index + 1) + "/" + str(chunks_data.size()) + ": " + chunk_path)

			if not FileAccess.file_exists(chunk_path):
				push_error("[SystemManager.download] [Reassembly] Chunk file missing: " + chunk_path)
				final_file.close()
				return false

			var chunk_file = FileAccess.open(chunk_path, FileAccess.READ)
			if not chunk_file:
				push_error("[SystemManager.download] [Reassembly] Failed to open chunk file: " + chunk_path)
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
			if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Finished chunk " + str(chunk_data.index + 1) + " (" + str(chunk_size) + " bytes)")

		final_file.close()

		var final_size = 0
		if FSM.file_exists(final_path):
			final_size = FSM.get_file_size(final_path)

		if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Desktop reassembly complete for: " + item.name + ". Final size: " + str(final_size) + " bytes")
		return true

	if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Queueing desktop reassembly to extraction thread for: " + item.name)

	# Queue to extraction thread - callback runs on main thread
	SystemManager.memory.queue_extraction_task(reassembly_callable, func(success: bool):
		if not _chunked_downloads.has(item_id):
			if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Reassembly callback ignored: download was cancelled or cleaned up for: " + item.name)
			return

		if not success:
			push_error("[SystemManager.download] [Reassembly] Desktop reassembly failed for: " + item.name)

			# Clean up failed final file
			if FSM.file_exists(final_path):
				FSM.delete_file(final_path)

			item.status = "failed"
			item.error_message = "Failed to reassemble chunks"
			_cleanup_chunked_download(item_id)
			_cleanup_item(item)
			download_completed.emit(item.id, false, item.error_message)
			_active_items.erase(item_id)
			queue_changed.emit()
			_process_queue()
			return

		if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Desktop reassembly callback success for: " + item.name)
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

	if DEBUG_LOG: print("[SystemManager.download] [InPlace] Renaming sparse partial to final: " + partial_path + " -> " + final_path)

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
	if DEBUG_LOG: print("[SystemManager.download] [InPlace] Move failed, falling back to copy: %s -> %s" % [partial_path, final_path])
	_copy_partial_to_final(item_id, partial_path, final_path)

func _copy_partial_to_final(item_id: String, partial_path: String, final_path: String):
	"""Copy the assembled partial file to the final destination off the main thread.
	Shows real progress in the GUI. Uses the plugin for restricted Android paths."""
	if not _chunked_downloads.has(item_id):
		return

	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	# Switch the notification to a copy progress indicator
	# (grouped multi-disc items keep the shared group notification instead)
	if item.group_id == "":
		if item.notification_id != -1:
			SystemManager.notifications.dismiss_notification(item.notification_id)

		item.notification_id = SystemManager.notifications.show_notification(
			"Copying " + item.name + "...",
			SystemManager.notifications.Type.INFO,
			null,
			0.0,
			func() -> float:
				return _final_copy_progress.get(item_id, 0.0),
			func(progress: float) -> String:
				var mb_copied = int(item.expected_file_size * progress / (1024.0 * 1024.0))
				var mb_total = int(item.expected_file_size / (1024.0 * 1024.0))
				return "Copying %s: %d/%d MB (%d%%)" % [item.name, mb_copied, mb_total, int(progress * 100)],
			false,  # pulsing
			true  # pinned
		)

	_final_copy_progress[item_id] = 0.0

	# For restricted Android paths, use the plugin's async copy.
	var use_plugin_copy = false
	if SystemManager.platform.is_android():
		var plugin = Engine.get_singleton("KyodaiBridge")
		if plugin != null:
			use_plugin_copy = plugin.call("requiresDocumentsContract", final_path)

	if use_plugin_copy:
		_plugin_copy_partial_to_final(item_id, partial_path, final_path)
	else:
		_godot_copy_partial_to_final(item_id, partial_path, final_path)

func _plugin_copy_partial_to_final(item_id: String, partial_path: String, final_path: String):
	var chunked_info = _chunked_downloads[item_id]
	var item = chunked_info.item

	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		push_error("[SystemManager.download] KyodaiBridge plugin not available for copy")
		_final_copy_progress.erase(item_id)
		item.status = "failed"
		item.error_message = "Plugin not available for copy"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)
		download_completed.emit(item_id, false, item.error_message)
		_active_items.erase(item_id)
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
			SystemManager.notifications.dismiss_notification(item.notification_id)
			item.notification_id = -1
		_final_copy_progress.erase(item_id)

		if not success:
			push_error("[SystemManager.download] [InPlace] Plugin copy failed: " + error)
			item.status = "failed"
			item.error_message = "Failed to copy download to destination"
			_cleanup_chunked_download(item_id)
			_cleanup_item(item)
			download_completed.emit(item_id, false, item.error_message)
			_active_items.erase(item_id)
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

	SystemManager.memory.queue_extraction_task(
		func() -> bool:
			return _copy_file_with_progress(partial_path, final_path, item_id),
		func(success: bool):
			if item.notification_id != -1:
				SystemManager.notifications.dismiss_notification(item.notification_id)
				item.notification_id = -1
			_final_copy_progress.erase(item_id)

			if not success:
				push_error("[SystemManager.download] [InPlace] Failed to copy partial to destination: " + partial_path + " -> " + final_path)
				item.status = "failed"
				item.error_message = "Failed to copy download to destination"
				_cleanup_chunked_download(item_id)
				_cleanup_item(item)
				download_completed.emit(item_id, false, item.error_message)
				_active_items.erase(item_id)
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
		push_error("[SystemManager.download] Failed to open source file for copy: " + source_path)
		return false

	var dest = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest:
		push_error("[SystemManager.download] Failed to open destination file for copy: " + dest_path)
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
			SystemManager.memory.queue_main_thread_callback(func():
				_final_copy_progress[item_id] = progress
			)

	source.close()
	dest.close()

	SystemManager.memory.queue_main_thread_callback(func():
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

	if DEBUG_LOG: print("[SystemManager.download] [Reassembly] Finishing reassembly success for: " + item.name + " path=" + reassembly_temp_path + " size=" + str(final_size) + " bytes")

	# Validate final size against expected size
	if item.expected_file_size > 0 and final_size != item.expected_file_size:
		push_error("[SystemManager.download] [Reassembly] Final size mismatch for: " + item.name + ". Expected: " + str(item.expected_file_size) + " bytes, Got: " + str(final_size) + " bytes")
		item.status = "failed"
		item.error_message = "Download corrupted: size mismatch (expected " + str(item.expected_file_size) + ", got " + str(final_size) + ")"
		_cleanup_chunked_download(item_id)
		_cleanup_item(item)

		# Clean up the corrupted file
		if FSM.file_exists(reassembly_temp_path):
			FSM.delete_file(reassembly_temp_path)

		if item.notification_id != -1:
			SystemManager.notifications.dismiss_notification(item.notification_id)
			item.notification_id = -1

		download_completed.emit(item_id, false, item.error_message)
		_active_items.erase(item_id)
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

	# Cancel any queued chunk tasks in the thread pool
	if chunked_info.batch_id != -1:
		SystemManager.memory.cancel_download_batch(chunked_info.batch_id)
		chunked_info.batch_id = -1

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
		# Use SystemManager.filesystem for Android external storage compatibility
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

func _on_file_download_complete(item: QueueItem, success: bool, error_msg: String, status_code: int = 0):
	# Guard against double-calls
	if item.status != "downloading":
		return

	# Stop progress timer and cleanup timeout tracking
	_cleanup_download_tracking(item.id)

	item.http_request = null

	if not success:
		# Terminal failure on the single-stream path: HTTPRequest streams the
		# response body into the destination file even for error statuses, so a
		# partial/error file must never survive (the filesystem scan matches by
		# name and would count it as a completed download).
		if FSM.file_exists(item.destination_path):
			FSM.delete_file(item.destination_path)
		if status_code == 404 and item.type == "game":
			item.error_message = "Server has no file for this ROM (HTTP 404) - it may have been removed or replaced on the server"
		else:
			item.error_message = error_msg
		item.status = "failed"
		print("[SystemManager.download] Download failed for " + item.name + ": " + item.error_message)
		_notify_download_failed(item)
		_cleanup_item(item)
		_stop_foreground_service()  # Stop foreground service on failure
		download_completed.emit(item.id, false, item.error_message)
		_active_items.erase(item.id)
		queue_changed.emit()
		_process_queue()
		return

	# Verify file exists and has content
	# Use SystemManager.filesystem (not FileAccess) for Android external storage compatibility
	if not FSM.file_exists(item.destination_path):
		item.status = "failed"
		item.error_message = "Download file not found"
		print("[SystemManager.download] Download file not found after completion: " + item.destination_path)
		_notify_download_failed(item)
		_cleanup_item(item)
		_stop_foreground_service()  # Stop foreground service on failure
		download_completed.emit(item.id, false, "Download file not found")
		_active_items.erase(item.id)
		queue_changed.emit()
		_process_queue()
		return

	# Size verification for RomM game downloads: a 200 response with the wrong
	# byte count means a truncated or substituted body (accept_gzip is disabled,
	# so sizes must match exactly).
	if item.type == "game" and item.expected_file_size > 0:
		var actual_size := FSM.get_file_size(item.destination_path)
		if actual_size != item.expected_file_size:
			FSM.delete_file(item.destination_path)
			item.status = "failed"
			item.error_message = "Downloaded size mismatch (%d of %d bytes)" % [actual_size, item.expected_file_size]
			print("[SystemManager.download] " + item.error_message + ": " + item.destination_path)
			_notify_download_failed(item)
			_cleanup_item(item)
			_stop_foreground_service()
			download_completed.emit(item.id, false, item.error_message)
			_active_items.erase(item.id)
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

	# Single-stream downloads have no resume support - a timed-out/stalled
	# partial would otherwise linger and get matched as complete by the next
	# filesystem scan. Chunked downloads (incl. Android flush mode, which
	# writes into the destination) keep their partials for resume.
	if not _chunked_downloads.has(item_id):
		if FSM.file_exists(item.destination_path):
			FSM.delete_file(item.destination_path)

	_cleanup_download_tracking(item_id)
	_cleanup_item(item)
	_stop_foreground_service()  # Stop foreground service on failure

	_notify_download_failed(item)
	download_completed.emit(item_id, false, error_msg)
	_active_items.erase(item_id)
	queue_changed.emit()
	_process_queue()

func _notify_download_failed(item: QueueItem) -> void:
	# Grouped (multi-disc) failures surface in the group summary, not per item
	if item.suppress_notification or item.group_id != "":
		return
	if item.notification_id != -1:
		SystemManager.notifications.dismiss_notification(item.notification_id)
		item.notification_id = -1
	SystemManager.notifications.show_notification(
		"Download failed: " + item.name,
		SystemManager.notifications.Type.ERROR,
		null,
		10.0
	)

func _start_extraction(item: QueueItem):
	item.status = "extracting"
	item.extracted_count = 0
	item.total_count = 0
	item.progress = 0.0
	if not _active_items.has(item.id):
		_active_items[item.id] = item

	# Foreground service is already running from _start_download() — do not
	# call _start_foreground_service() here or the active-download count will
	# never reach 0 and the Android notification will persist after extraction.

	extraction_started.emit(item.id)

	# Delegate all extraction to SystemManager.filesystem (handles its own notification)
	var archive_path = item.destination_path
	var extract_dir = item.extract_dir

	if DEBUG_LOG: print("[SystemManager.download] _start_extraction: archive_path=" + archive_path + ", extract_dir=" + extract_dir)

	FSM.extract_archive_async(
		archive_path,
		extract_dir,
		item.name,
		item.delete_after_extract,
		func(info: Dictionary):
			var extracted: int = int(info.get("extracted_files", 0))
			var total: int = int(info.get("total_files", 0))
			item.extracted_count = extracted
			item.total_count = total
			if int(info.get("total_bytes", 0)) > 0:
				item.progress = clampf(float(info.get("extracted_bytes", 0)) / float(info.get("total_bytes", 1)), 0.0, 1.0)
			elif total > 0:
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
	, not item.suppress_notification)

func _finish_download_completion(item: QueueItem):
	"""Complete the download after file operations are done"""
	# Update game resource if applicable
	if item.game_resource and item.update_game_resource:
		var downloaded_id = item.romm_id if item.romm_id != 0 else item.game_resource.romm_id
		# Per-row truth: stamp the downloaded variant's OWN row and rebuild the
		# group cache (record_variant_download also updates the resource
		# in-memory for immediate UI feedback).
		DataManager.record_variant_download(item.game_resource, downloaded_id, item.destination_path, func(persist_ok: bool):
			if not persist_ok:
				push_error("[SystemManager.download] Failed to persist download state for " + item.game_resource.title + " - game will appear undownloaded on next launch")
				if SystemManager.notifications:
					SystemManager.notifications.show_notification("Failed to record download for " + item.game_resource.get_display_name() + " - run a full sync", SystemManager.notifications.Type.ERROR)
		)

		# Generate an m3u playlist once every disc of a multi-disc game is present
		if M3USubManager.supports_m3u(item.game_resource.platform_slug) and item.game_resource.is_multi_disc():
			LaunchManager.m3u.generate_m3u_if_complete(item.game_resource)

		# Extract TitleID in background if needed
		if item.game_resource.get_active_title_id() == "" and _needs_title_id(item.game_resource):
			var game = item.game_resource
			# Extract from the file just downloaded; game.file_path can point at
			# a different sibling (or a server-relative path) instead.
			var downloaded_path := item.destination_path
			var notify_id = SystemManager.notifications.show_notification("Extracting TitleID for " + game.title + "...", SystemManager.notifications.Type.INFO, null, 3.0, Callable(), Callable(), true, true)
			SystemManager.memory.queue_extraction_task(func():
				return TitleIDParser.extract_for_game_result(game, downloaded_path)
			, func(result: Dictionary):
				SystemManager.notifications.dismiss_notification(notify_id)
				var title_id = result.get("title_id", "")
				if title_id != "":
					DataManager.update_game_title_id(game.romm_id, title_id)
					if result.get("save_id", "") != "":
						game.save_id = result.save_id
						game.save_usage = result.get("usage", "")
						DataManager.update_game_save_info(game.romm_id, game.save_id, game.save_usage)
					SystemManager.notifications.show_notification("TitleID " + title_id + " found for " + game.title + "!", SystemManager.notifications.Type.SUCCESS, null, 3.0)
					print("[SystemManager.download] TitleID extracted post-download: " + title_id + " for " + game.title)
				else:
					print("[SystemManager.download] TitleID extraction failed for " + game.title)
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
			SystemManager.notifications.dismiss_notification(item.notification_id)
			item.notification_id = -1
		_stop_foreground_service()  # Stop foreground service on completion (no extraction)
		download_completed.emit(item.id, true, item.destination_path)
		_active_items.erase(item.id)
		queue_changed.emit()
		_process_queue()

func _cleanup_item(item: QueueItem):
	if item.notification_id != -1:
		# Let notification auto-dismiss on completion/failure
		pass

# ==================== IMAGE DOWNLOADS (THROTTLED) ====================

# Track active image downloads for deduplication
var _active_image_downloads: Dictionary = {}  # url -> {callbacks: [], completed: bool, success: bool}

# Cap concurrent image HTTP requests to avoid exhausting the OS DNS resolver.
const MAX_CONCURRENT_IMAGE_DOWNLOADS: int = 16
# Bound the pending queue: an unbounded backlog pins recycled cards via
# captured callbacks and delays fresh covers behind long-irrelevant ones.
const MAX_PENDING_IMAGE_DOWNLOADS: int = 256
## Result passed to image download callbacks. DROPPED means the request never
## reached the network (queue-full backpressure or a teleport pruning stale
## work) - callers must NOT treat it as a content failure (no retry TTLs).
enum ImageResult { OK, FAILED, DROPPED }
var _active_image_download_count: int = 0
var _pending_image_downloads: Array = []
var _pending_image_downloads_mutex: Mutex = Mutex.new()

# Rate-limited logging for dropped image downloads: mass drops (e.g. a sync
# flooding the queue) must not spam thousands of warnings, but must not be
# silent either - silent drops previously surfaced only as unexplained
# "Cover download FAILED" errors downstream.
const IMAGE_DROP_LOG_LIMIT: int = 5
const IMAGE_DROP_SUMMARY_EVERY: int = 250
var _image_drop_logged: int = 0
var _image_drops_suppressed: int = 0

func _log_image_drop(url: String) -> void:
	if _image_drop_logged < IMAGE_DROP_LOG_LIMIT:
		_image_drop_logged += 1
		push_warning("[SystemManager.download] Image download dropped (queue full): %s" % _redact_url(url))
	else:
		_image_drops_suppressed += 1
		if _image_drops_suppressed % IMAGE_DROP_SUMMARY_EVERY == 0:
			push_warning("[SystemManager.download] %d further image downloads dropped (queue full)" % _image_drops_suppressed)

## Downloads an image with caching, deduplication, and limited concurrency.
## callback(result: ImageResult). High-priority downloads jump ahead of queued
## low-priority downloads (FIFO order is kept within each tier). Bulk marks
## background batch work (sync prefetch): it queues at the given priority but
## is spared by teleport pruning, which only drops user-facing low-priority
## requests whose cards were just recycled.
func download_image(url: String, cache_path: String, callback: Callable, high_priority: bool = false, bulk: bool = false) -> bool:
	# Check if already cached
	if FSM.file_exists(cache_path):
		callback.call(ImageResult.OK)
		return true

	_pending_image_downloads_mutex.lock()

	# Check if already downloading (deduplication)
	if _active_image_downloads.has(url):
		var state = _active_image_downloads[url]
		if state.completed:
			_pending_image_downloads_mutex.unlock()
			callback.call(ImageResult.OK if state.success else ImageResult.FAILED)
		else:
			state.callbacks.append(callback)
			_pending_image_downloads_mutex.unlock()
		return true

	# Throttle: queue if too many downloads are in flight.
	if _active_image_download_count >= MAX_CONCURRENT_IMAGE_DOWNLOADS:
		if _pending_image_downloads.size() >= MAX_PENDING_IMAGE_DOWNLOADS:
			if high_priority:
				# Make room by evicting the oldest low-priority item (tail).
				var evicted_idx := -1
				for i in range(_pending_image_downloads.size() - 1, -1, -1):
					if not _pending_image_downloads[i].get("high_priority", false):
						evicted_idx = i
						break
				if evicted_idx >= 0:
					var evicted = _pending_image_downloads[evicted_idx]
					_pending_image_downloads.remove_at(evicted_idx)
					_pending_image_downloads_mutex.unlock()
					_log_image_drop(evicted.url)
					if evicted.callback.is_valid():
						evicted.callback.call(ImageResult.DROPPED)
					# Retry now that a slot freed up.
					return download_image(url, cache_path, callback, high_priority, bulk)
				_pending_image_downloads_mutex.unlock()
				_log_image_drop(url)
				callback.call(ImageResult.DROPPED)
				return true
			_pending_image_downloads_mutex.unlock()
			# Dropped low-priority request: report DROPPED (backpressure, not
			# failure) so the caller doesn't record a retry-suppressing
			# failure TTL for what was really a full queue.
			_log_image_drop(url)
			callback.call(ImageResult.DROPPED)
			return true
		var item = {
			"url": url,
			"cache_path": cache_path,
			"callback": callback,
			"high_priority": high_priority,
			"bulk": bulk
		}
		if high_priority:
			# Insert after the last queued high-priority item
			var insert_idx = 0
			for i in range(_pending_image_downloads.size()):
				if _pending_image_downloads[i].get("high_priority", false):
					insert_idx = i + 1
			_pending_image_downloads.insert(insert_idx, item)
		else:
			_pending_image_downloads.append(item)
		_pending_image_downloads_mutex.unlock()
		return true

	_active_image_download_count += 1
	_active_image_downloads[url] = {
		"callbacks": [callback],
		"completed": false,
		"success": false
	}
	_pending_image_downloads_mutex.unlock()
	_start_image_download(url, cache_path)
	return true


func _process_image_download_queue() -> void:
	while true:
		_pending_image_downloads_mutex.lock()
		if _active_image_download_count >= MAX_CONCURRENT_IMAGE_DOWNLOADS or _pending_image_downloads.is_empty():
			_pending_image_downloads_mutex.unlock()
			break
		var item = _pending_image_downloads.pop_front()

		# A download for this URL may have started or finished while the item was queued.
		if _active_image_downloads.has(item.url):
			var state = _active_image_downloads[item.url]
			if state.completed:
				var queued_success = state.success
				_pending_image_downloads_mutex.unlock()
				item.callback.call(ImageResult.OK if queued_success else ImageResult.FAILED)
			else:
				state.callbacks.append(item.callback)
				_pending_image_downloads_mutex.unlock()
			continue

		_active_image_download_count += 1
		_active_image_downloads[item.url] = {
			"callbacks": [item.callback],
			"completed": false,
			"success": false
		}
		_pending_image_downloads_mutex.unlock()
		_start_image_download(item.url, item.cache_path)


## Drop queued (not in-flight) low-priority image downloads, sparing bulk work
## (sync prefetch) and anything high-priority. Used on grid teleports: queued
## covers belong to the window the user just left, so clearing them frees the
## queue for the new window instead of letting stale work crowd it out and
## trigger queue-full drops. Dropped callbacks receive ImageResult.DROPPED, so
## callers treat it as backpressure (no failure TTLs), and any card that
## scrolls back into view simply re-requests its cover.
func clear_pending_low_priority_image_downloads() -> int:
	_pending_image_downloads_mutex.lock()
	var dropped: Array = []
	var kept: Array = []
	for item in _pending_image_downloads:
		if item.get("high_priority", false) or item.get("bulk", false):
			kept.append(item)
		else:
			dropped.append(item)
	_pending_image_downloads = kept
	_pending_image_downloads_mutex.unlock()
	for item in dropped:
		_log_image_drop(item.url)
		if item.callback.is_valid():
			item.callback.call(ImageResult.DROPPED)
	return dropped.size()


static var _redact_regex: RegEx = null

## Redacts credential query params (scraper URLs embed them in plaintext).
static func _redact_url(url: String) -> String:
	if _redact_regex == null:
		_redact_regex = RegEx.new()
		_redact_regex.compile("(devid|devpassword|ssid|sspassword)=[^&]*")
	return _redact_regex.sub(url, "$1=***", true)

func _start_image_download(url: String, cache_path: String) -> void:
	# Start new HTTP request (auth headers only for URLs on the RomM host)
	SystemManager.network.http_get(url, SystemManager.network.get_auth_headers_for_url(url), func(success: bool, body: PackedByteArray, status_code: int, error_msg: String):
		if not is_instance_valid(self):
			return

		_pending_image_downloads_mutex.lock()

		# The entry may have been cleaned up or overwritten by a concurrent/follow-up request.
		if not _active_image_downloads.has(url):
			_active_image_download_count = maxi(0, _active_image_download_count - 1)
			_pending_image_downloads_mutex.unlock()
			_process_image_download_queue()
			return

		var state = _active_image_downloads[url]
		var image_ok: bool = success and not body.is_empty() and FSM.is_image_buffer(body)
		state.completed = true
		state.success = image_ok

		var callbacks = state.callbacks.duplicate()
		_active_image_download_count = maxi(0, _active_image_download_count - 1)
		_active_image_downloads.erase(url)
		_pending_image_downloads_mutex.unlock()

		if image_ok:
			FSM.write_file_bytes(cache_path, body)
		elif not success:
			push_error("[SystemManager.download] Image download FAILED: %s (HTTP %d, %s)" % [_redact_url(url), status_code, error_msg])
		elif body.is_empty():
			push_error("[SystemManager.download] Image download FAILED: %s (HTTP %d, empty body)" % [_redact_url(url), status_code])
		else:
			var body_preview := ""
			if body.size() < 256:
				body_preview = body.get_string_from_utf8()
			else:
				var preview_len := mini(64, body.size())
				var ascii_preview := ""
				for i in range(preview_len):
					var b := body[i]
					ascii_preview += char(b) if b >= 0x20 and b < 0x7F else "."
				body_preview = "hex=" + body.slice(0, preview_len).hex_encode() + " ascii=\"" + ascii_preview + "\""
			push_error("[SystemManager.download] Image download REJECTED (not an image): %s (HTTP %d, %d bytes) body: %s" % [_redact_url(url), status_code, body.size(), body_preview])

		for cb in callbacks:
			if cb.is_valid():
				cb.call(ImageResult.OK if image_ok else ImageResult.FAILED)

		_process_image_download_queue()
	)

## Helper function to recursively clean up a temp directory
func _cleanup_temp_dir(dir_path: String) -> void:
	FSM.delete_dir_recursive(dir_path)


func _exit_tree() -> void:
	Performance.remove_custom_monitor("download/image_active")
	Performance.remove_custom_monitor("download/image_pending")
	shutdown()

func shutdown() -> void:
	"""Cancel all active and queued downloads.

	Called during app shutdown so in-progress downloads don't stall tree teardown.
	"""
	# Cancel all active downloads first; this stops their timers and cleans up
	# chunked-download state.
	var active_ids := _active_items.keys()
	for item_id in active_ids:
		cancel(item_id)

	# Clear any queued items without starting them.
	for item in _queue:
		_cleanup_item(item)
	_queue.clear()

	# Close any leftover connection pools.
	_connection_pool_mutex.lock()
	for item_id in _download_connection_pools.keys():
		var pool = _download_connection_pools[item_id]
		for http in pool:
			if http != null:
				http.close()
	_download_connection_pools.clear()
	_connection_pool_mutex.unlock()

	_chunk_concurrency_semaphores.clear()
	_chunked_downloads.clear()
	_final_copy_progress.clear()
	_state_file_dirty.clear()
	_state_file_last_save_ms.clear()
