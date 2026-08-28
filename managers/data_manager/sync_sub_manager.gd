extends Manager
class_name SyncSubManager

var data_manager: Node

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

# Sync state machine
enum SyncState {
	IDLE,
	PRECHECK_DISABLED,      # Remove games from disabled platforms
	PLATFORM_ITERATING,     # Iterate through platforms
	PLATFORM_FETCHING,      # Fetch batch from current platform
	PLATFORM_PROCESSING,    # Process fetched batch
	PLATFORM_BATCHING,      # Fetch more batches if needed
	COMPLETING              # Final cleanup
}

var _sync_state: SyncState = SyncState.IDLE
var _sync_platforms_list: Array = []        # Platforms to sync
var _sync_current_platform_idx: int = 0     # Current platform index (0-based)
var _sync_current_platform_data: Dictionary = {}  # Current platform info
var _sync_current_offset: int = 0           # Current batch offset
var _sync_current_total: int = 0            # Total games in current platform
var _sync_precalc_platform_total: int = 0   # Pre-calculated total for current platform
var _sync_current_synced: int = 0           # Games synced in current platform
var _sync_total_synced: int = 0             # Total synced across all platforms
var _sync_final_callback: Callable = Callable()

# Incremental sync state
var _sync_force_full: bool = false          # Force full sync flag
var _sync_current_updated_after: String = ""  # updated_after timestamp for current platform

# Progress tracking state
var _sync_current: int = 0
var _sync_total: int = 0
var _sync_platform: String = ""
var _sync_platform_index: int = 0  # Current platform number (1-based)
var _sync_platform_count: int = 0  # Total platforms
var _sync_platform_total: int = 0  # Games in current platform

# Tracks whether a sync is running (used to suppress per-card cover downloads)
var _sync_batch_mode: bool = false

# Cover URLs collected during sync for batch downloading on main thread
var _sync_covers_pending: Array[String] = []
var _sync_covers_pending_set: Dictionary = {}  # Set of URLs already in _sync_covers_pending
var _sync_covers_mutex: Mutex = Mutex.new()

# Tracks how many cover-dispatch batches are in flight so the sync thread can wait
# until every deferred main-thread download call has finished scheduling.
var _sync_covers_dispatched_count: int = 0
var _sync_covers_processed_count: int = 0
var _sync_covers_dispatch_semaphore: Semaphore = Semaphore.new()

# Cover download outcome counters for end-of-phase diagnostics
var _sync_covers_cached_count: int = 0
var _sync_covers_downloaded_count: int = 0
var _sync_covers_failed_count: int = 0

# Interleaved cover dispatch: throttle and once-per-URL progress counting
const COVER_DISPATCH_INTERVAL_MS: int = 2000
# Max sync covers allowed in the download queue at once. Kept well below
# DownloadSubManager's pending cap so onscreen card loads (high priority)
# always have headroom and sync covers are never dropped by the queue limit.
const COVER_DISPATCH_MAX_IN_FLIGHT: int = 128
var _sync_last_cover_dispatch_ms: int = 0
var _sync_covers_counted_set: Dictionary = {}

# Every cover URL collected during this sync (pending, dispatched, or done)
var _sync_covers_seen_set: Dictionary = {}

# Tracks cover downloads that are still in flight so the sync can wait for
# them before completing.
var _sync_pending_downloads: int = 0
var _sync_pending_downloads_mutex: Mutex = Mutex.new()
var _sync_pending_downloads_semaphore: Semaphore = Semaphore.new()

# Platform pre-calculation totals
var _precalc_platform_totals: Dictionary = {}  # platform_id -> total count

var _sync_notification_id: int = -1
var _removal_notification_id: int = -1

# Android sync foreground service tracking
var _sync_fg_service_active: bool = false


func _ready():
	data_manager = get_parent()


# ==================== SYNC THREAD SIGNAL WRAPPERS ====================
# These are called via call_deferred from the sync thread to safely emit signals on the main thread

func _emit_sync_progress(percent: float, current: int, total: int):
	data_manager.sync_progress.emit(percent, current, total)


func _emit_sync_completed(success: bool, message: String):
	data_manager.sync_completed.emit(success, message)


# Wrapper for calling _sync_final_callback via call_deferred
func _invoke_sync_callback(success: bool, message: String, count: int, error_code: int):
	if _sync_final_callback.is_valid():
		_sync_final_callback.call(success, message, count, error_code)


## Generic helper to wait for an async callback.
## Polls at 10ms intervals with a fast-path exit to minimize latency.
func _wait_for_async(task_func: Callable, timeout_ms: int = 60000):
	var state = {"completed": false, "result": null}

	var wrapped_callback = func(result = null):
		state.result = result
		state.completed = true

	task_func.call(wrapped_callback)

	# Fast-path: if callback fired synchronously, return immediately
	if state.completed:
		return state.result

	# Poll at 10ms intervals (matching pre-refactor latency)
	var elapsed = 0
	var check_interval = 10  # 10ms
	while not state.completed and elapsed < timeout_ms:
		if MemorySubManager.is_shutting_down():
			return null
		OS.delay_msec(check_interval)
		elapsed += check_interval

	return state.result if state.completed else null


# ==================== ANDROID SYNC FOREGROUND SERVICE ====================

func _start_sync_fg_service(platform_name: String = "Game Library", current: int = 0, total: int = 0) -> void:
	print("[SyncManager] Starting sync foreground service: %s (%d/%d)" % [platform_name, current, total])
	if SystemManager.platform.start_sync_foreground_service(platform_name, current, total):
		_sync_fg_service_active = true


func _update_sync_fg_service(platform_name: String = "", current: int = 0, total: int = 0) -> void:
	if not _sync_fg_service_active:
		return
	var service_name = platform_name if platform_name != "" else _sync_platform
	SystemManager.platform.update_sync_foreground_service(service_name, current, total)


func _stop_sync_fg_service() -> void:
	if not _sync_fg_service_active:
		return
	print("[SyncManager] Stopping sync foreground service")
	if SystemManager.platform.stop_sync_foreground_service():
		_sync_fg_service_active = false


# ==================== REMOVAL PROGRESS NOTIFICATION ====================

func _show_removal_notification(total: int) -> void:
	_removal_notification_id = SystemManager.notifications.show_notification(
		"Removing %d platforms..." % total,
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true,  # pulsing
		true  # pinned
	)


func _update_removal_notification(current: int, total: int, slug: String) -> void:
	if _removal_notification_id != -1:
		SystemManager.notifications.update_notification_text(
			_removal_notification_id,
			"Removing platform %d/%d: %s" % [current, total, slug]
		)


func _dismiss_removal_notification() -> void:
	if _removal_notification_id != -1:
		SystemManager.notifications.dismiss_notification(_removal_notification_id)
		_removal_notification_id = -1


# ==================== SYNC (ITERATIVE STATE MACHINE) ====================

func sync_enabled_platforms(callback: Callable = Callable(), force_full_sync: bool = false) -> void:
	print("[Sync] ==========================================")
	print("[Sync] sync_enabled_platforms called")
	print("[Sync] Current state: %s" % get_sync_state_name())
	print("[Sync] Force full sync: %s" % force_full_sync)
	print("[Sync] Callback valid: %s" % callback.is_valid())
	print("[Sync] ==========================================")

	# Dismiss any existing sync notification from previous syncs
	if _sync_notification_id != -1:
		print("[Sync] Dismissing existing notification ID: %d" % _sync_notification_id)
		SystemManager.notifications.dismiss_notification(_sync_notification_id)
		_sync_notification_id = -1

	if not data_manager.database.is_database_ready():
		var err_msg = "Database initialization failed. App cannot function without database access." if data_manager.database.is_database_init_failed() else "Database not ready"
		print("[Sync] ERROR: " + err_msg)
		if callback.is_valid():
			callback.call(false, err_msg, 0, 0)
		return

	# Reset sync state
	_sync_current = 0
	_sync_total = 0
	_sync_platform = ""
	_sync_state = SyncState.PRECHECK_DISABLED
	_sync_platforms_list = []
	_sync_current_platform_idx = 0
	_sync_current_offset = 0
	_sync_current_total = 0
	_sync_current_synced = 0
	_sync_total_synced = 0
	_sync_final_callback = callback
	_sync_force_full = force_full_sync
	_sync_current_updated_after = ""

	# Reset cover download tracking
	_sync_covers_mutex.lock()
	_sync_covers_pending.clear()
	_sync_covers_pending_set.clear()
	_sync_covers_dispatched_count = 0
	_sync_covers_processed_count = 0
	_sync_covers_cached_count = 0
	_sync_covers_downloaded_count = 0
	_sync_covers_failed_count = 0
	_sync_last_cover_dispatch_ms = 0
	_sync_covers_counted_set.clear()
	_sync_covers_seen_set.clear()
	_sync_covers_mutex.unlock()
	_sync_pending_downloads_mutex.lock()
	_sync_pending_downloads = 0
	_sync_pending_downloads_mutex.unlock()

	var enabled = data_manager.database.get_enabled_platforms()
	print("[Sync] Enabled platforms: %d" % enabled.size())

	# Get all platforms that currently have games in the database
	var db_platforms = data_manager.database.get_db_platform_slugs()
	print("[Sync] Platforms with games in DB: %d" % db_platforms.size())

	var enabled_slugs = enabled.map(func(p): return p.slug)

	# Find platforms that have games but are now disabled
	var disabled_platforms: Array[String] = []
	for slug in db_platforms:
		if not slug in enabled_slugs:
			disabled_platforms.append(slug)

	print("[Sync] Platforms to disable: %d" % disabled_platforms.size())

	# Queue the entire sync to the background sync thread
	# This allows sync to continue even when the app is backgrounded on Android
	print("[Sync] Queuing sync to background thread...")
	MemorySubManager.queue_sync_task(
		func():
			_run_sync_threaded(enabled, disabled_platforms, force_full_sync)
			return true,
		func(_result):
			print("[Sync] Sync thread task completed")
	)


func _run_sync_threaded(enabled_platforms: Array, disabled_platforms: Array[String], force_full_sync: bool):
	"""Main sync worker that runs on the sync thread."""
	print("[SyncThread] Sync started on background thread")

	# 1. Remove disabled platforms
	if disabled_platforms.size() > 0:
		print("[SyncThread] Removing %d disabled platforms..." % disabled_platforms.size())
		call_deferred("_show_removal_notification", disabled_platforms.size())
		for i in range(disabled_platforms.size()):
			var slug = disabled_platforms[i]
			print("[SyncThread] Removing platform %d/%d: %s" % [i + 1, disabled_platforms.size(), slug])
			call_deferred("_update_removal_notification", i + 1, disabled_platforms.size(), slug)
			_remove_platform_sync_threaded(slug)
			# Small yield to prevent blocking other sync thread tasks
			OS.delay_usec(1000)
		call_deferred("_dismiss_removal_notification")

	# 2. Check if there are platforms to sync
	if enabled_platforms.size() == 0:
		print("[SyncThread] No platforms enabled, completing immediately")
		call_deferred("_emit_sync_completed", true, "No platforms enabled")
		call_deferred("_invoke_sync_callback", true, "", 0, 0)
		return

	# 3. Start batch mode and foreground service on main thread
	call_deferred("_start_sync_batch_mode")
	call_deferred("_start_sync_fg_service", "Game Library", 0, 0)

	# 4. Start sync immediately - skip pre-calculation to save 20+ seconds
	# We'll discover per-platform totals as we fetch the first batch of each
	print("[SyncThread] Starting sync of %d platforms..." % enabled_platforms.size())
	_sync_state = SyncState.PLATFORM_ITERATING
	_sync_platforms_list = enabled_platforms
	_sync_platform_count = enabled_platforms.size()
	_sync_current_platform_idx = 0
	_sync_current = 0
	_sync_total = 0  # Will accumulate as we discover totals
	_sync_total_synced = 0

	# Start sync notification on main thread
	call_deferred("_show_sync_notification")

	# Pre-calculate totals in background without blocking
	# Fire off all pre-calc requests but don't wait for them
	var platform_totals_discovered = 0
	for platform in enabled_platforms:
		var platform_id = str(platform.id)
		var result = SystemManager.network.fetch_games_sync(platform_id, 0, 1)
		if result.success and result.data is Dictionary:
			var platform_total = int(result.data.get("total", 0))
			_precalc_platform_totals[platform_id] = platform_total
			_sync_total += platform_total
			platform_totals_discovered += 1
		# Don't block - just keep going
		OS.delay_usec(500)

	print("[SyncThread] Discovered %d/%d platform totals, ~%d total games" % [platform_totals_discovered, enabled_platforms.size(), _sync_total])

	for platform_idx in range(enabled_platforms.size()):
		_sync_current_platform_idx = platform_idx
		var platform = enabled_platforms[platform_idx]
		_sync_platform = platform.name
		_sync_platform_index = platform_idx + 1

		# Look up platform ID
		var platform_id = platform.id
		if platform_id == 0 and data_manager.database.is_database_ready():
			platform_id = _lookup_platform_id_sync(platform.slug)

		if platform_id == 0:
			print("[SyncThread] Skipping platform '%s' - no ID found" % platform.name)
			continue

		_sync_current_platform_data = {
			"id": platform_id,
			"slug": platform.slug,
			"name": platform.name
		}

		# Update foreground service
		call_deferred("_update_sync_fg_service", platform.name, _sync_current, _sync_total)

		# Determine sync mode
		_sync_current_updated_after = ""
		if not force_full_sync:
			var last_sync = _get_last_sync_time_sync(platform.slug)
			if last_sync != "":
				var last_sync_time = DataManager.parse_iso_timestamp(last_sync)
				var one_week_ago = Time.get_unix_time_from_system() - (7 * 24 * 60 * 60)
				if last_sync_time > one_week_ago:
					_sync_current_updated_after = last_sync
					print("[SyncThread] Platform '%s' - incremental sync (after: %s)" % [platform.name, last_sync])
				else:
					print("[SyncThread] Platform '%s' - full sync (last sync over a week ago)" % platform.name)
			else:
				print("[SyncThread] Platform '%s' - full sync (no previous sync)" % platform.name)
		else:
			print("[SyncThread] Platform '%s' - force full sync" % platform.name)

		# Fetch and process this platform
		_sync_state = SyncState.PLATFORM_FETCHING
		_sync_current_offset = 0
		_sync_current_synced = 0
		_sync_precalc_platform_total = _precalc_platform_totals.get(str(platform_id), 0)

		var platform_complete = false
		var platform_batch_count = 0
		var batch_size = 250 if not SystemManager.platform.is_android() else 150

		# Parallel fetch state
		var parallel_fetch = {
			"thread": null,
			"mutex": Mutex.new(),
			"result": null,
			"completed": false,
			"offset": 0
		}

		while not platform_complete:

			# Fetch batch (or wait for parallel fetch)
			var fetch_start = Time.get_ticks_msec()
			var result = null
			var fetch_time = 0

			if parallel_fetch.completed and parallel_fetch.offset == _sync_current_offset:
				# Use pre-fetched result
				parallel_fetch.mutex.lock()
				result = parallel_fetch.result
				parallel_fetch.completed = false
				parallel_fetch.result = null
				parallel_fetch.mutex.unlock()
				fetch_time = Time.get_ticks_msec() - fetch_start
				print("[SyncThread] Using pre-fetched batch at offset %d" % _sync_current_offset)
			else:
				# Fetch synchronously
				result = SystemManager.network.fetch_games_sync(str(platform_id), _sync_current_offset, batch_size, _sync_current_updated_after)
				fetch_time = Time.get_ticks_msec() - fetch_start

			if not result.success:
				# Do NOT update last_sync here: the failed window must be retried
				# by the next sync instead of being permanently skipped.
				print("[SyncThread] Error fetching platform '%s': %s (fetch took %dms) - last_sync NOT updated" % [platform.name, result.error, fetch_time])
				platform_complete = true
				continue

			var total = int(result.data.get("total", 0))
			var items = result.data.get("items", [])

			if total == 0 or items.size() == 0:
				if _sync_current_offset == 0:
					# Nothing changed (incremental) or platform is genuinely empty:
					# safe to advance the sync window.
					if _sync_current_updated_after != "":
						_sync_current += _sync_precalc_platform_total
						call_deferred("_update_sync_fg_service", platform.name, _sync_current, _sync_total)

					var current_time = Time.get_datetime_string_from_system(true)
					_set_last_sync_time_sync(platform.slug, current_time)
				else:
					# Paged past the end with games still unprocessed (a batch
					# failed or the server total drifted): leave last_sync alone
					# so the next sync retries the full window.
					print("[SyncThread] Platform '%s' ended early at offset %d (%d/%d synced) - last_sync NOT updated" % [platform.name, _sync_current_offset, _sync_current_synced, _sync_current_total])
				platform_complete = true
				continue

			_sync_current_total = total
			_sync_platform_total = total

			# Start fetching next batch in parallel while we process this one
			var next_offset = _sync_current_offset + batch_size
			if next_offset < total and not platform_complete:
				parallel_fetch.offset = next_offset
				parallel_fetch.completed = false
				parallel_fetch.result = null

				parallel_fetch.thread = Thread.new()
				parallel_fetch.thread.start(func():
					var next_result = SystemManager.network.fetch_games_sync(str(platform_id), next_offset, batch_size, _sync_current_updated_after)
					parallel_fetch.mutex.lock()
					parallel_fetch.result = next_result
					parallel_fetch.completed = true
					parallel_fetch.mutex.unlock()
				)

			# Process batch with incremental progress
			_sync_state = SyncState.PLATFORM_PROCESSING
			var batch_start = Time.get_ticks_msec()
			var succeeded = _process_batch_sync(items, platform.slug, true)
			var batch_time = Time.get_ticks_msec() - batch_start
			_sync_current_synced += succeeded
			_sync_total_synced += succeeded
			_sync_current += succeeded
			platform_batch_count += 1

			# Update progress
			call_deferred("_update_sync_fg_service", platform.name, _sync_current, _sync_total)
			var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
			call_deferred("_emit_sync_progress", progress_pct * 0.01, _sync_current, _sync_total)

			print("[SyncThread] Progress: %d/%d games (%d%%) | Platform %d/%d: %s | Batch %d: fetch=%dms process=%dms" % [
				_sync_current, _sync_total, int(progress_pct),
				_sync_platform_index, _sync_platform_count, platform.name,
				platform_batch_count, fetch_time, batch_time
			])

			# Wait for parallel fetch to finish before next iteration
			if parallel_fetch.thread != null and parallel_fetch.thread.is_alive():
				parallel_fetch.thread.wait_to_finish()

			if _sync_current_synced >= _sync_current_total:
				var current_time = Time.get_datetime_string_from_system(true)
				_set_last_sync_time_sync(platform.slug, current_time)
				platform_complete = true
			else:
				_sync_current_offset += batch_size
				_sync_state = SyncState.PLATFORM_BATCHING
				OS.delay_usec(10000)  # 10ms yield to prevent blocking and reduce CPU

		print("[SyncThread] Platform '%s' complete (%d batches, %d/%d games)" % [platform.name, platform_batch_count, _sync_current_synced, _sync_current_total])

	# 7. Download any remaining covers collected during sync (and backfill
	#    existing uncached covers) as a visible sync phase with its own progress.
	print("[SyncThread] All platforms processed, starting cover download phase...")
	_process_cover_download_phase()

	# 8. Complete sync - defer ALL UI work to main thread
	print("[SyncThread] All platforms complete, finishing...")
	_sync_state = SyncState.COMPLETING

	# Get cache stats before clearing
	var cache_stats = SystemManager.network.get_and_reset_cache_stats()
	var games_from_cache = cache_stats.get("games_from_cache", 0)

	print("[SyncThread] Sync complete: %d games synced, %d from cache" % [_sync_total_synced, games_from_cache])

	# Defer the entire completion sequence to main thread
	# This avoids calling scene-tree methods from the sync thread
	call_deferred("_complete_sync_on_main_thread", _sync_total_synced, games_from_cache)


func _complete_sync_on_main_thread(total_synced: int, games_from_cache: int):
	"""Complete sync on main thread - safe for UI operations."""
	print("[Sync] Completing on main thread...")

	# Ensure the progress notification reaches 100% so it auto-dismisses.
	if _sync_total == 0:
		_sync_total = 1
	_sync_current = _sync_total

	# Clean up
	_stop_sync_batch_mode()
	_stop_sync_fg_service()

	# Apply cover folding and emit completion
	data_manager.cover.apply_cover_folding_to_database(func(folded_count: int):
		var completion_msg = "Synced " + str(total_synced) + " games"
		if games_from_cache > 0:
			completion_msg += " (" + str(games_from_cache) + " checked from cache"
			if folded_count > 0:
				completion_msg += ", " + str(folded_count) + " folded by cover"
			completion_msg += ")"
		elif folded_count > 0:
			completion_msg += " (" + str(folded_count) + " folded by cover)"

		_sync_state = SyncState.IDLE
		data_manager.sync_completed.emit(true, completion_msg)
		_invoke_sync_callback(true, completion_msg, total_synced, 0)
	)


func _process_cover_download_phase() -> void:
	"""Download all collected and backfill covers as a sync phase.

	Runs on the sync thread. Downloads happen on the main thread and progress
	is updated as each cover completes.
	"""
	if not data_manager.database.is_database_ready():
		return

	# 1. Query distinct cover URLs already in the library whose image files are
	#    not cached on disk. Covers collected during the sync were already
	#    dispatched incrementally by _process_batch_sync.
	var rows = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.query_array(
					"SELECT DISTINCT cover_url FROM games WHERE cover_url != '' AND cover_url IS NOT NULL"
				),
			func(result: Array):
				callback.call(result)
		)
	, 120000)

	if rows == null:
		rows = []

	# Only count URLs not already collected during the sync toward the
	# progress total.
	var backfill_urls: Array[String] = []
	_sync_covers_mutex.lock()
	for row in rows:
		var url = row.get("cover_url", "")
		if url == "" or not url.begins_with("http"):
			continue
		if _sync_covers_seen_set.has(url):
			continue
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			continue
		_sync_covers_seen_set[url] = true
		_sync_total += 1  # Each unique backfill cover is also a work unit
		backfill_urls.append(url)
	_sync_covers_mutex.unlock()

	var cover_total = backfill_urls.size()

	_sync_platform = "Covers"
	_sync_platform_index = _sync_platform_count + 1
	print("[SyncThread] Cover download phase: %d backfill covers to process" % cover_total)

	# Emit progress so the total includes the new cover work.
	var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
	call_deferred("_update_sync_fg_service", _sync_platform, _sync_current, _sync_total)
	call_deferred("_emit_sync_progress", progress_pct * 0.01, _sync_current, _sync_total)

	# 2. Queue missing covers for download on the main thread.
	_sync_covers_mutex.lock()
	for url in backfill_urls:
		if not _sync_covers_pending_set.has(url):
			_sync_covers_pending.append(url)
			_sync_covers_pending_set[url] = true
	_sync_covers_mutex.unlock()

	_dispatch_covers_to_main_thread()

	# 3. Block the sync thread until all downloads complete.
	#    The main thread handles the actual work.
	_wait_for_all_cover_downloads()


const COVER_PROGRESS_EVERY: int = 5

func _on_cover_processed() -> void:
	"""Called on the main thread when a cover has been processed by the worker."""
	_sync_current += 1
	if _sync_current % COVER_PROGRESS_EVERY == 0 or _sync_current == _sync_total:
		var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
		_emit_sync_progress(progress_pct * 0.01, _sync_current, _sync_total)
		_update_sync_fg_service(_sync_platform, _sync_current, _sync_total)


func _wait_for_all_cover_downloads() -> void:
	"""Wait for all cover downloads to finish.

	Blocks the sync thread but leaves the main thread and UI responsive.
	"""
	print("[SyncThread] Waiting for cover downloads to finish...")

	# Wait for any remaining cover downloads to dispatch and complete.
	while true:
		_sync_covers_mutex.lock()
		var still_pending = _sync_covers_pending.size() > 0
		var dispatched = _sync_covers_dispatched_count
		var processed = _sync_covers_processed_count
		_sync_covers_mutex.unlock()
		if still_pending:
			# Self-throttled: no-op while the in-flight cap is reached.
			_dispatch_covers_to_main_thread()
			OS.delay_msec(50)
			continue

		# Wait until all deferred main-thread download calls have finished scheduling.
		if processed < dispatched:
			_sync_covers_dispatch_semaphore.wait()
			continue

		_sync_pending_downloads_mutex.lock()
		var download_count = _sync_pending_downloads
		_sync_pending_downloads_mutex.unlock()
		if download_count == 0:
			break

		_sync_pending_downloads_semaphore.wait()

	print("[SyncThread] Cover downloads complete: %d cached, %d downloaded, %d FAILED" % [_sync_covers_cached_count, _sync_covers_downloaded_count, _sync_covers_failed_count])


func _dispatch_covers_to_main_thread():
	"""Dispatch collected cover URLs to main thread for async download.

	Self-throttles to COVER_DISPATCH_MAX_IN_FLIGHT outstanding downloads so a
	large backfill can't flood the download queue past its pending cap and get
	covers silently dropped. Leftover URLs stay pending for the next dispatch
	once in-flight downloads settle.
	"""
	_sync_pending_downloads_mutex.lock()
	var headroom: int = COVER_DISPATCH_MAX_IN_FLIGHT - _sync_pending_downloads
	_sync_pending_downloads_mutex.unlock()
	if headroom <= 0:
		return

	_sync_covers_mutex.lock()
	if _sync_covers_pending.is_empty():
		_sync_covers_mutex.unlock()
		return

	var take: int = mini(headroom, _sync_covers_pending.size())
	var urls: Array[String] = []
	for i in range(take):
		var url := _sync_covers_pending[i]
		urls.append(url)
		_sync_covers_pending_set.erase(url)
	_sync_covers_pending = _sync_covers_pending.slice(take)
	_sync_covers_dispatched_count += 1
	_sync_last_cover_dispatch_ms = Time.get_ticks_msec()
	_sync_covers_mutex.unlock()

	call_deferred("_download_covers_on_main_thread", urls, _on_cover_processed)
	print("[SyncThread] Cover dispatch: %d urls (cached=%d downloaded=%d failed=%d pending_dl=%d)" % [urls.size(), _sync_covers_cached_count, _sync_covers_downloaded_count, _sync_covers_failed_count, _sync_pending_downloads])


func _download_covers_on_main_thread(urls: Array[String], on_complete: Callable = Callable()):
	"""Download covers on main thread using existing async infrastructure.

	Called via call_deferred from sync thread. Queues each cover to
	SystemManager.download for parallel async download.
	"""

	for url in urls:
		var counted_cb := _make_cover_counted_callback(url, on_complete)
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			# Already cached: no network wait.
			_sync_covers_cached_count += 1
			counted_cb.call()
			continue

		# Track pending download
		_sync_pending_downloads_mutex.lock()
		_sync_pending_downloads += 1
		_sync_pending_downloads_mutex.unlock()

		# Use existing async download path. Sync covers queue at normal priority:
		# high priority is reserved for on/near-screen card loads, and dispatch
		# throttling (COVER_DISPATCH_MAX_IN_FLIGHT) keeps the queue from
		# dropping these.
		data_manager.cover.download_cover(url, func(ok):
			if ok:
				_sync_covers_downloaded_count += 1
			else:
				_sync_covers_failed_count += 1
				push_error("[SyncThread] Cover download FAILED: %s" % DownloadSubManager._redact_url(url))
			counted_cb.call()

			_sync_pending_downloads_mutex.lock()
			_sync_pending_downloads -= 1
			var download_batch_done = _sync_pending_downloads == 0
			_sync_pending_downloads_mutex.unlock()
			if download_batch_done:
				_sync_pending_downloads_semaphore.post()
				# Also wake the dispatch wait path; without this a wait that
				# started while downloads were in flight never gets re-signaled.
				_sync_covers_dispatch_semaphore.post()
		)

	# Mark this dispatch batch as processed and signal waiters if everything is done.
	_sync_covers_mutex.lock()
	_sync_covers_processed_count += 1
	var all_dispatched = _sync_covers_processed_count == _sync_covers_dispatched_count
	_sync_covers_mutex.unlock()

	_sync_pending_downloads_mutex.lock()
	var downloads_done = _sync_pending_downloads == 0
	_sync_pending_downloads_mutex.unlock()

	if all_dispatched and downloads_done:
		_sync_pending_downloads_semaphore.post()
	_sync_covers_dispatch_semaphore.post()


func _remove_platform_sync_threaded(platform_slug: String) -> bool:
	"""Synchronous platform removal for sync thread (uses Semaphore, no busy-wait)."""
	var result = _wait_for_async(func(callback: Callable):
		data_manager.database.remove_platform_games(platform_slug, func(success: bool):
			callback.call(success)
		)
	, 60000)
	if result == null:
		print("[SyncThread] ERROR: Timeout removing platform %s" % platform_slug)
		return false
	return result if result is bool else false


func _lookup_platform_id_sync(platform_slug: String) -> int:
	"""Lookup platform ID from DB - queues to DB thread for thread safety."""
	if not data_manager.database.is_database_ready():
		return 0

	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				var query_result = data_manager.database.query_array("SELECT romm_id FROM platforms WHERE slug = ?", [platform_slug])
				if query_result.size() > 0:
					return query_result[0].get("romm_id", 0)
				return 0,
			func(romm_id: int):
				callback.call(romm_id)
		)
	, 60000)

	if result == null:
		print("[SyncThread] ERROR: Timeout looking up platform ID for %s" % platform_slug)
		return 0
	return result if result is int else 0


func _get_last_sync_time_sync(platform_slug: String) -> String:
	"""Get last sync time - queues to DB thread for thread safety."""
	if not data_manager.database.is_database_ready():
		return ""

	var key = "last_sync_" + platform_slug
	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				var query_result = data_manager.database.query_array("SELECT value FROM cache_metadata WHERE key = ?", [key])
				if query_result.size() > 0:
					return query_result[0].get("value", "")
				return "",
			func(value: String):
				callback.call(value)
		)
	, 60000)

	if result == null:
		print("[SyncThread] ERROR: Timeout getting last sync time for %s" % platform_slug)
		return ""
	return result if result is String else ""


func _set_last_sync_time_sync(platform_slug: String, timestamp: String):
	"""Set last sync time - queues to DB thread for thread safety."""
	if not data_manager.database.is_database_ready():
		return

	var key = "last_sync_" + platform_slug
	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				return data_manager.database.query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES (?, ?)", [key, timestamp]),
			func(success: bool):
				callback.call(success)
		)
	, 60000)

	if result == null:
		print("[SyncThread] ERROR: Timeout setting last sync time for %s" % platform_slug)
	elif not (result is bool and result):
		print("[SyncThread] ERROR: Failed to set last sync time for %s" % platform_slug)


func _process_batch_sync(items: Array, platform_slug: String, emit_incremental_progress: bool = false) -> int:
	"""Process a batch of games on the sync thread.

	Phases:
	1. Create GameResources (sync thread CPU work)
	2. Sibling checks + DB inserts (single combined DB task per batch)
	3. Collect cover URLs and dispatch to main thread for async download
	4. Optional: Emit incremental progress updates during processing
	"""
	if items.is_empty():
		return 0

	var batch_start = Time.get_ticks_msec()
	var base_count = _sync_current  # Starting count before this batch

	# Phase 1: Create GameResources with incremental progress
	var games: Array[GameResource] = []
	var progress_chunk_size = 25  # Emit progress every 25 games

	for i in range(items.size()):
		var game = _create_game_from_data(items[i], platform_slug, false)
		if game != null:
			games.append(game)

		# Emit incremental progress every 25 games
		if emit_incremental_progress and i > 0 and i % progress_chunk_size == 0:
			var partial_current = base_count + i
			var partial_pct = float(partial_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
			call_deferred("_emit_sync_progress", partial_pct * 0.01, partial_current, _sync_total)

	if games.is_empty():
		return 0

	# Phase 2: Sibling checks + DB inserts in ONE combined DB task
	var db_start = Time.get_ticks_msec()
	var inserted = _check_and_insert_games_sync(games)
	var _db_time = Time.get_ticks_msec() - db_start

	# Phase 3: Collect unique cover URLs and queue them for interleaved
	# dispatch during the sync.
	var cover_start = Time.get_ticks_msec()
	var new_urls: Array[String] = []
	_sync_covers_mutex.lock()
	for game in games:
		if game.has_cover_art and game.cover_url != "" and game.cover_url.begins_with("http"):
			if not _sync_covers_seen_set.has(game.cover_url):
				_sync_covers_seen_set[game.cover_url] = true
				_sync_total += 1  # Each unique cover is a download work unit
				new_urls.append(game.cover_url)
	for url in new_urls:
		if not _sync_covers_pending_set.has(url):
			_sync_covers_pending.append(url)
			_sync_covers_pending_set[url] = true
	_sync_covers_mutex.unlock()
	var _cover_time = Time.get_ticks_msec() - cover_start

	# Interleave cover downloads with the sync instead of doing it all at the
	# end: dispatch pending covers every few seconds so network work overlaps
	# the sync's network waits.
	if Time.get_ticks_msec() - _sync_last_cover_dispatch_ms > COVER_DISPATCH_INTERVAL_MS:
		_dispatch_covers_to_main_thread()

	var _total_time = Time.get_ticks_msec() - batch_start
	# Batch timing logging removed for cleaner sync output

	return inserted


## Wraps the per-cover completion callback so sync progress is counted at most
## once per unique cover URL, even if a cover is processed more than once
## (e.g. dispatched in an early batch, then re-queued for late-added games).
func _make_cover_counted_callback(url: String, on_complete: Callable) -> Callable:
	return func():
		_sync_covers_mutex.lock()
		var already := _sync_covers_counted_set.has(url)
		if not already:
			_sync_covers_counted_set[url] = true
		_sync_covers_mutex.unlock()
		if not already and on_complete.is_valid():
			on_complete.call()


func _check_and_insert_games_sync(games: Array[GameResource]) -> int:
	"""Check siblings and insert games in a single DB task.

	This combines what used to be two separate DB tasks (sibling check + insert)
	into one, halving the DB queue pressure.
	"""
	if games.is_empty() or not data_manager.database.is_database_ready():
		return 0

	var result = _wait_for_async(func(callback: Callable):
		MemorySubManager.queue_db_task(
			func():
				# Step 1: Assign master entries per sibling group. Siblings in the
				# same batch must see each other - checking everything before
				# inserting made every same-batch sibling a master, so folding
				# only worked for groups split across batches.
				_assign_sibling_masters(games)

				# Step 2: Insert all games in one transaction
				var insert_success = _insert_games_transaction(games)
				return insert_success,
			func(db_success: bool):
				callback.call(db_success)
		)
	, 120000)

	if result == null:
		print("[SyncThread] ERROR: Timeout waiting for DB check+insert (%d games)" % games.size())
		return 0

	var success = result if result is bool else false
	if success:
		# Skip all UI emissions during sync for performance
		# LibraryView will refresh when sync_completed is emitted
		return games.size()
	else:
		print("[SyncThread] ERROR: DB check+insert failed for %d games" % games.size())
		return 0


func _insert_games_transaction(games: Array[GameResource]) -> bool:
	"""Insert multiple games within a single database transaction.

	This provides 10-50x speedup over individual inserts by reducing
	disk sync operations. All games in the batch succeed or fail together.
	"""
	if not data_manager.database.is_database_ready() or games.is_empty():
		return false
	data_manager.database.lock()

	# Prefetch existing rows for the whole batch in ONE query so
	# _build_insert_query doesn't do a per-game SELECT (N+1).
	var romm_ids: Array = []
	for game in games:
		if game != null and game.romm_id > 0:
			romm_ids.append(game.romm_id)
	var existing_rows: Dictionary = {}
	if romm_ids.size() > 0:
		var placeholders = ", ".join(romm_ids.map(func(_id): return "?"))
		var existing_result = data_manager.database.query_array_unlocked(
			"SELECT romm_id, has_local_copy, downloaded_sibling_ids, file_path, cover_group_id, cover_group_master, last_played, title_id, m3u_path, is_favorite, unwrapped FROM games WHERE romm_id IN (%s)" % placeholders,
			romm_ids
		)
		for row in existing_result:
			existing_rows[row.get("romm_id", 0)] = row

	# Start transaction
	var begin_result = data_manager.database.query_bool_unlocked("BEGIN TRANSACTION")
	if not begin_result:
		print("[DatabaseManager] ERROR: Failed to begin transaction")
		data_manager.database.unlock()
		return false

	var success = true
	var error_count = 0

	# Insert all games in this batch
	for game in games:
		if game == null:
			continue

		var insert_data = _build_insert_query(game, existing_rows.get(game.romm_id, {}))
		var insert_result = data_manager.database.query_bool_unlocked(insert_data.query, insert_data.bindings)
		if insert_result:
			data_manager.database.replace_game_filter_values_unlocked(game)
		else:
			success = false
			error_count += 1
			print("[DatabaseManager] ERROR: Failed to insert game '%s' (ID: %d)" % [game.title, game.romm_id])
			# Continue trying to insert others - we'll rollback at the end

	# Commit or rollback based on success
	if success:
		var commit_result = data_manager.database.query_bool_unlocked("COMMIT")
		if commit_result:
			data_manager.database.unlock()
			return true
		else:
			print("[DatabaseManager] ERROR: Failed to commit transaction")
			data_manager.database.query_bool_unlocked("ROLLBACK")
			data_manager.database.unlock()
			return false
	else:
		print("[DatabaseManager] ERROR: Transaction failed with %d errors, rolling back %d games" % [error_count, games.size()])
		data_manager.database.query_bool_unlocked("ROLLBACK")
		data_manager.database.unlock()
		return false


func _show_sync_notification():
	"""Show sync notification on main thread."""
	_sync_notification_id = SystemManager.notifications.show_notification(
		"Syncing...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		func() -> float:
			if _sync_total == 0:
				return 0.0
			var frac = float(_sync_current) / float(_sync_total)
			# Cap below 1.0 until the sync is actually completing so the pinned
			# notification isn't auto-dismissed by transient catch-up mid-sync.
			if _sync_state != SyncState.COMPLETING and _sync_state != SyncState.IDLE:
				return minf(frac, 0.99)
			return frac,
		func(progress: float) -> String:
			var pct = int(progress * 100)
			if _sync_platform != "":
				return "Platform %d/%d: %s - %d/%d (%d%%)" % [_sync_platform_index, _sync_platform_count, _sync_platform, _sync_current, _sync_total, pct]
			return "Syncing %d/%d (%d%%)" % [_sync_current, _sync_total, pct],
		false,  # pulsing
		true  # pinned
	)


func _check_siblings_in_db(romm_id: int, siblings: Array[Dictionary]) -> bool:
	"""Check if any sibling (NOT including self) exists in DB - to be run on DB thread."""
	if not data_manager.database.is_database_ready():
		return false

	# Build list of sibling IDs to check (excluding self)
	var ids_to_check = []
	for sibling in siblings:
		var sid = sibling.get("id", 0)
		if sid != 0 and sid != romm_id:  # Exclude self
			ids_to_check.append(sid)

	if ids_to_check.is_empty():
		return false

	# Check if any siblings already exist as master entries
	var placeholders = ", ".join(ids_to_check.map(func(_id): return "?"))
	var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % placeholders

	var query_result = data_manager.database.query_array(query, ids_to_check)
	if query_result.size() > 0:
		return query_result[0]["count"] > 0

	return false


func _assign_sibling_masters(games: Array[GameResource]) -> void:
	"""Pick exactly one master entry per sibling group in this batch.

	Master preference: RomM's own is_main_sibling flag, then an existing DB
	master from the same group, then the lowest romm_id. All other members
	are folded (is_master_entry = false). To be run on the DB thread."""
	var parent := {}
	var games_by_id := {}

	for game in games:
		if game == null or game.siblings.is_empty():
			continue
		games_by_id[game.romm_id] = game
		_uf_add(parent, game.romm_id)
		for sibling in game.siblings:
			var sid: int = sibling.get("id", 0)
			if sid != 0:
				_uf_add(parent, sid)
				_uf_union(parent, game.romm_id, sid)

	# Bucket batch games by group root
	var groups := {}
	for game in games_by_id.values():
		var root := _uf_find(parent, game.romm_id)
		if not groups.has(root):
			groups[root] = []
		groups[root].append(game)

	for root in groups:
		_assign_group_master(groups[root], parent, root)


func _assign_group_master(members: Array, parent: Dictionary, root: int) -> void:
	# All romm_ids belonging to this group, including siblings not in this batch
	var member_ids: Array = []
	for id in parent.keys():
		if _uf_find(parent, id) == root:
			member_ids.append(id)

	# 1) RomM-flagged main sibling among batch members wins
	var master: GameResource = null
	for game in members:
		if game.romm_is_main_sibling:
			master = game
			break

	# 2) Otherwise keep an existing DB master from this group, if any
	if master == null:
		var db_master_id := _get_db_master_id(member_ids)
		if db_master_id != 0:
			for game in members:
				if game.romm_id == db_master_id:
					master = game
					break
			if master == null:
				# Master lives in the DB but isn't in this batch - fold all members under it
				for game in members:
					game.is_master_entry = false
				return

	# 3) Fallback: deterministic pick (lowest romm_id)
	if master == null:
		master = members[0]
		for game in members:
			if game.romm_id < master.romm_id:
				master = game

	for game in members:
		game.is_master_entry = (game == master)

	# Demote any stale DB master in this group that disagrees with our pick
	# (repairs groups folded incorrectly by older sync logic on re-sync)
	_demote_stale_db_masters(member_ids, master.romm_id)


func _get_db_master_id(member_ids: Array) -> int:
	"""Return the romm_id of an existing DB master in this group, or 0."""
	if member_ids.is_empty() or not data_manager.database.is_database_ready():
		return 0
	var placeholders = ", ".join(member_ids.map(func(_id): return "?"))
	var query = "SELECT romm_id FROM games WHERE romm_id IN (%s) AND is_master_entry = 1 LIMIT 1" % placeholders
	var result = data_manager.database.query_array(query, member_ids)
	if result.size() > 0:
		return result[0].get("romm_id", 0)
	return 0


func _demote_stale_db_masters(member_ids: Array, keep_master_id: int) -> void:
	"""Clear is_master_entry on any DB row in this group that isn't the chosen master."""
	if member_ids.is_empty() or not data_manager.database.is_database_ready():
		return
	var placeholders = ", ".join(member_ids.map(func(_id): return "?"))
	var query = "UPDATE games SET is_master_entry = 0 WHERE romm_id IN (%s) AND is_master_entry = 1 AND romm_id != ?" % placeholders
	var bindings = member_ids.duplicate()
	bindings.append(keep_master_id)
	data_manager.database.query_bool(query, bindings)


func _uf_add(parent: Dictionary, id: int) -> void:
	if not parent.has(id):
		parent[id] = id


func _uf_find(parent: Dictionary, id: int) -> int:
	var root := id
	while parent.get(root, root) != root:
		root = parent[root]
	# Path compression
	var cur := id
	while parent.get(cur, cur) != cur:
		var next: int = parent[cur]
		parent[cur] = root
		cur = next
	return root


func _uf_union(parent: Dictionary, a: int, b: int) -> void:
	var ra := _uf_find(parent, a)
	var rb := _uf_find(parent, b)
	if ra != rb:
		parent[rb] = ra


func _create_game_from_data(data: Dictionary, platform_slug: String, check_siblings: bool = true) -> GameResource:
	var game = GameResource.new()
	game.id = str(data.get("id", ""))
	game.romm_id = data.get("id", 0)
	game.title = str(data.get("name", ""))
	game.platform = str(data.get("platform_display_name", ""))
	game.platform_slug = platform_slug if platform_slug != "" else str(data.get("platform_slug", ""))
	# Always use RomM-proxied cover media (path_cover_large), never the external
	# scraper URL (url_cover) - the proxy works with the app's RomM credentials
	# and avoids scraper rate limits/logins. Mirrors argosy-launcher.
	var path_cover_large := str(data.get("path_cover_large", ""))
	if path_cover_large != "" and path_cover_large != "null" and path_cover_large != "<null>" and path_cover_large != "None":
		game.cover_url = SystemManager.network.build_media_url(path_cover_large)
	else:
		game.cover_url = ""
	game.cover_path = path_cover_large
	game.file_name = str(data.get("fs_name", ""))
	game.file_path = str(data.get("full_path", ""))
	game.file_size = data.get("fs_size_bytes", 0)
	game.has_local_copy = false
	game.last_updated = str(data.get("updated_at", ""))
	game.description = str(data.get("summary", ""))

	var genres: Array[String] = []
	if data.has("metadatum") and data["metadatum"] is Dictionary:
		if data["metadatum"].has("genres") and data["metadatum"]["genres"] is Array:
			for g in data["metadatum"]["genres"]:
				if g is String:
					genres.append(g)
	game.genres = genres

	if data.has("metadatum") and data["metadatum"] is Dictionary:
		var rating_val = data["metadatum"].get("average_rating", 0.0)
		game.rating = rating_val if rating_val != null else 0.0

	# Extract raw IGDB metadata blob from RomM if present
	if data.has("igdb_metadata") and data["igdb_metadata"] is Dictionary:
		game.igdb_metadata = data["igdb_metadata"].duplicate()
	else:
		game.igdb_metadata = {}

	# Release date: RomM exposes first_release_date as unix seconds; fall back
	# to the IGDB blob (also unix seconds) when the top-level field is missing.
	game.release_date = 0
	var raw_release = data.get("first_release_date", 0)
	if raw_release != null:
		game.release_date = int(raw_release) * 1000
	if game.release_date <= 0 and game.igdb_metadata.has("first_release_date"):
		var igdb_release = game.igdb_metadata.get("first_release_date", 0)
		if igdb_release != null:
			game.release_date = int(igdb_release) * 1000

	# Extract siblings from API response
	# Current RomM versions expose this as "sibling_roms" (SiblingRomSchema);
	# older versions used "siblings". Support both.
	var siblings: Array[Dictionary] = []
	var siblings_raw: Array = []
	if data.has("sibling_roms") and data["sibling_roms"] is Array:
		siblings_raw = data["sibling_roms"]
	elif data.has("siblings") and data["siblings"] is Array:
		siblings_raw = data["siblings"]
	for sibling_data in siblings_raw:
		if sibling_data is Dictionary:
			# Note: Sibling data from API only has basic info (id, name, fs_name_no_ext, etc.)
			# Full details (including proper file name with extension) will be fetched on-demand
			# when the user selects the sibling in the game details view

			var sibling = {
				"id": sibling_data.get("id", 0),
				"name": str(sibling_data.get("name", "")),
				"file_name": str(sibling_data.get("fs_name_no_ext", "")),  # Will be updated on-demand
				"file_size": sibling_data.get("fs_size_bytes", 0),
				"title_id": "",  # Will be extracted on launch
			"is_main_sibling": sibling_data.get("is_main_sibling", false) == true,
			"sort_comparator": str(sibling_data.get("sort_comparator", "")),
			"disc_number": GameResource.parse_disc_number(str(sibling_data.get("fs_name_no_ext", "")))
		}
			siblings.append(sibling)
	game.siblings = siblings

	# RomM marks the representative rom of a sibling group via rom_user.is_main_sibling
	var rom_user = data.get("rom_user", {})
	game.romm_is_main_sibling = rom_user is Dictionary and rom_user.get("is_main_sibling", false) == true

	# RomM per-user play state (rom_user); status may be null when unset
	if rom_user is Dictionary:
		var raw_status = rom_user.get("status", null)
		game.status = str(raw_status) if raw_status != null else ""
		game.now_playing = rom_user.get("now_playing", false) == true
		game.backlogged = rom_user.get("backlogged", false) == true
		game.hidden = rom_user.get("hidden", false) == true

	# Determine if this should be a master entry
	# A game is a master if RomM flags it as the main sibling, or if none of
	# its siblings already exist in our database as a master entry
	if check_siblings:
		game.is_master_entry = game.romm_is_main_sibling or not _check_siblings_in_db(game.romm_id, siblings)
	else:
		# During batch sync, we'll check siblings separately
		game.is_master_entry = true  # Default, will be updated by batch check

	# Mark games without cover art so filtering can be applied dynamically
	if game.cover_url == "" or game.cover_url == "null" or game.cover_url == "<null>" or game.cover_url == "None":
		game.has_cover_art = false

	return game


func _build_insert_query(game: GameResource, existing_row: Dictionary = {}) -> Dictionary:
	"""Build SQL INSERT query and bindings for a game - used for batch processing.

	PRESERVES existing has_local_copy, downloaded_sibling_ids, file_path,
	last_played, and title_id if the game already exists in the
	database. This prevents downloaded games and local progress from
	disappearing after a re-sync. Pass existing_row (batch-prefetched) to
	avoid a per-game SELECT; direct callers fall back to fetching on demand."""

	# Check if game already exists and preserve download status
	var has_local_copy = 1 if game.has_local_copy else 0
	var downloaded_sibling_ids = JSON.stringify(game.downloaded_sibling_ids)
	var file_path = game.file_path
	var last_played = game.last_played
	var title_id = game.title_id
	var is_favorite = 1 if game.is_favorite else 0
	var unwrapped = 1 if game.unwrapped else 0

	var existing = existing_row
	if existing.is_empty() and data_manager.database.is_database_ready() and game.romm_id > 0:
		var check_query = "SELECT has_local_copy, downloaded_sibling_ids, file_path, cover_group_id, cover_group_master, last_played, title_id, m3u_path, is_favorite, unwrapped FROM games WHERE romm_id = ?"
		var query_result = data_manager.database.query_array_unlocked(check_query, [game.romm_id])
		if query_result.size() > 0:
			existing = query_result[0]

	if not existing.is_empty():
		# Preserve download status from existing record
		if existing.get("has_local_copy", 0) == 1:
			has_local_copy = 1
		# Preserve downloaded siblings
		var existing_siblings = existing.get("downloaded_sibling_ids", "[]")
		if existing_siblings != "[]" and existing_siblings != "":
			downloaded_sibling_ids = existing_siblings
		# Preserve file path
		var existing_path = existing.get("file_path", "")
		if existing_path != "":
			file_path = existing_path
		# Preserve cover group fields (they're managed separately from sync)
		var existing_cover_group_id = existing.get("cover_group_id", "")
		if existing_cover_group_id != "":
			game.cover_group_id = existing_cover_group_id
			game.cover_group_master = existing.get("cover_group_master", 1) == 1
		# Preserve locally-managed fields the server payload never provides
		var existing_last_played = existing.get("last_played", "")
		if existing_last_played != "":
			last_played = existing_last_played
		var existing_title_id = existing.get("title_id", "")
		if existing_title_id != "":
			title_id = existing_title_id
		# Preserve locally generated m3u playlist (the server payload never provides it)
		var existing_m3u_path = existing.get("m3u_path", "")
		if existing_m3u_path != "":
			game.m3u_path = existing_m3u_path
		# Preserve favorite flag (synced separately via the favourites virtual collection)
		is_favorite = 1 if existing.get("is_favorite", 0) == 1 else 0
		# Preserve present-wrap state (the server payload never provides it)
		unwrapped = 1 if existing.get("unwrapped", 0) == 1 else 0

	var query = """
		INSERT OR REPLACE INTO games
		(id, romm_id, title, platform, platform_slug, cover_url, cover_path,
		 file_name, file_path, file_size, has_local_copy, last_updated,
		 description, genres, rating, release_date, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played, title_id, cover_group_id, cover_group_master, igdb_metadata, m3u_path, status, now_playing, backlogged, hidden, is_favorite, unwrapped)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	"""

	var bindings = [
		game.id,
		game.romm_id,
		game.title,
		game.platform,
		game.platform_slug,
		game.cover_url,
		game.cover_path,
		game.file_name,
		file_path,
		game.file_size,
		has_local_copy,
		game.last_updated,
		game.description,
		",".join(game.genres),
		game.rating,
		game.release_date,
		JSON.stringify(game.siblings),
		game.selected_sibling_id,
		1 if game.is_master_entry else 0,
		downloaded_sibling_ids,
		1 if game.has_cover_art else 0,
		last_played,
		title_id,
		game.cover_group_id,
		1 if game.cover_group_master else 0,
		JSON.stringify(game.igdb_metadata),
		game.m3u_path,
		game.status,
		1 if game.now_playing else 0,
		1 if game.backlogged else 0,
		1 if game.hidden else 0,
		is_favorite,
		unwrapped
	]

	return {"query": query, "bindings": bindings}


# ==================== PLATFORMS ====================

func sync_platforms_from_romm(callback: Callable = Callable()):
	if not data_manager.database.is_database_ready():
		var err_msg = "Database initialization failed. App cannot function without database access." if data_manager.database.is_database_init_failed() else "Database not ready"
		if callback.is_valid():
			callback.call(false, err_msg)
		return

	SystemManager.network.fetch_platforms(func(data, error):
		if error != "" or not data is Array:
			if callback.is_valid():
				callback.call(false, error if error else "Invalid data")
			return

		var count = 0
		for platform_data in data:
			var platform = PlatformResource.new()
			platform.id = str(platform_data.get("id", ""))
			platform.romm_id = platform_data.get("id", 0)
			platform.name = platform_data.get("name", "")
			platform.slug = platform_data.get("slug", "")
			platform.icon_url = platform_data.get("url_logo", "")
			data_manager.database.add_platform(platform)
			count += 1

		data_manager.sync_completed.emit(true, "Synced " + str(count) + " platforms")
		if callback.is_valid():
			callback.call(true, "")
	)


func _start_sync_batch_mode():
	"""Mark sync as in progress (suppresses per-card cover downloads)."""
	_sync_batch_mode = true


func _stop_sync_batch_mode():
	"""Mark sync as finished."""
	_sync_batch_mode = false


func is_sync_in_progress() -> bool:
	"""Check if a sync is currently in progress."""
	return _sync_batch_mode


func get_sync_state() -> int:
	"""Get the current sync state for debugging/monitoring."""
	return _sync_state


func get_sync_state_name() -> String:
	"""Get the current sync state as a readable string."""
	match _sync_state:
		SyncState.IDLE:
			return "IDLE"
		SyncState.PRECHECK_DISABLED:
			return "PRECHECK_DISABLED"
		SyncState.PLATFORM_ITERATING:
			return "PLATFORM_ITERATING"
		SyncState.PLATFORM_FETCHING:
			return "PLATFORM_FETCHING"
		SyncState.PLATFORM_PROCESSING:
			return "PLATFORM_PROCESSING"
		SyncState.PLATFORM_BATCHING:
			return "PLATFORM_BATCHING"
		SyncState.COMPLETING:
			return "COMPLETING"
		_:
			return "UNKNOWN"


func get_current_platform_progress() -> Dictionary:
	"""Get progress information for the current platform being synced."""
	return {
		"platform_index": _sync_platform_index,
		"total_platforms": _sync_platform_count,
		"platform_name": _sync_platform,
		"games_synced": _sync_current_synced,
		"games_total": _sync_current_total,
		"batch_offset": _sync_current_offset
	}
