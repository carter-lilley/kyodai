extends Manager
class_name SyncSubManager

var data_manager: Node

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

# Sync state machine
enum SyncState {
	IDLE,
	PRECHECK_DISABLED,      # Remove games from disabled platforms
	CALCULATING_TOTALS,     # Pre-calculate game counts
	PLATFORM_ITERATING,     # Iterate through platforms
	PLATFORM_FETCHING,      # Fetch batch from current platform
	PLATFORM_PROCESSING,    # Process fetched batch
	PLATFORM_BATCHING,      # Fetch more batches if needed
	COVER_FOLDING,          # Apply cover folding
	COMPLETING,             # Final cleanup
	ERROR                   # Error state
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

# Batch notification system for incremental UI updates
var _sync_batch_mode: bool = false
var _sync_batch_pending: Array[GameResource] = []
var _sync_batch_pending_mutex: Mutex = Mutex.new()  # Thread-safe access
var _sync_batch_timer: Timer = null
var _sync_batch_last_emit_time: int = 0
const BATCH_EMIT_INTERVAL_MS: int = 800  # Emit every 800ms during sync

# Cover URLs collected during sync for batch downloading on main thread
var _sync_covers_pending: Array[String] = []
var _sync_covers_pending_set: Dictionary = {}  # Set of URLs already in _sync_covers_pending
var _sync_covers_mutex: Mutex = Mutex.new()

# Tracks how many cover-dispatch batches are in flight so the sync thread can wait
# until every deferred main-thread download call has finished scheduling.
var _sync_covers_dispatched_count: int = 0
var _sync_covers_processed_count: int = 0
var _sync_covers_dispatch_semaphore: Semaphore = Semaphore.new()

# Map of cover URL to games that share it, used for logo box caching during sync
var _sync_cover_url_to_games: Dictionary = {}  # String -> Array[GameResource]
var _sync_cover_url_to_games_mutex: Mutex = Mutex.new()

# Tracks cover downloads and logo box detections that are still in flight so
# the sync can wait for them before completing.
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

func _emit_sync_started():
	data_manager.sync_started.emit()


func _emit_sync_progress(percent: float, current: int, total: int):
	data_manager.sync_progress.emit(percent, current, total)


func _emit_sync_completed(success: bool, message: String):
	data_manager.sync_completed.emit(success, message)


func _emit_game_added(game: GameResource):
	data_manager.game_added.emit(game)


func _emit_games_batch_added(platform_slug: String, start_index: int, games: Array[GameResource]):
	data_manager.games_batch_added.emit(platform_slug, start_index, games)


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
	var name = platform_name if platform_name != "" else _sync_platform
	SystemManager.platform.update_sync_foreground_service(name, current, total)


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
		true  # pulsing
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

	# Reset cover download tracking and logo box mapping
	_sync_covers_mutex.lock()
	_sync_covers_pending.clear()
	_sync_covers_pending_set.clear()
	_sync_covers_dispatched_count = 0
	_sync_covers_processed_count = 0
	_sync_covers_mutex.unlock()
	_sync_cover_url_to_games_mutex.lock()
	_sync_cover_url_to_games.clear()
	_sync_cover_url_to_games_mutex.unlock()
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
	SystemManager.memory.queue_sync_task(
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
		if _sync_state == SyncState.ERROR:
			break

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

		while not platform_complete and _sync_state != SyncState.ERROR:

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
				print("[SyncThread] Error fetching platform '%s': %s (fetch took %dms)" % [platform.name, result.error, fetch_time])
				var current_time = Time.get_datetime_string_from_system(true)
				_set_last_sync_time_sync(platform.slug, current_time)
				platform_complete = true
				continue

			var total = int(result.data.get("total", 0))
			var items = result.data.get("items", [])

			if total == 0 or items.size() == 0:
				if _sync_current_offset == 0 and _sync_current_updated_after != "":
					_sync_current += _sync_precalc_platform_total
					call_deferred("_update_sync_fg_service", platform.name, _sync_current, _sync_total)

				var current_time = Time.get_datetime_string_from_system(true)
				_set_last_sync_time_sync(platform.slug, current_time)
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

	# 7. Cache logo boxes for all covers collected during sync (and backfill
	#    existing covers) as a visible sync phase with its own progress.
	print("[SyncThread] All platforms processed, starting logo box caching phase...")
	_process_cover_work_phase()

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

	# Flush any remaining batch notifications
	_flush_batch_notifications()

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


func _process_cover_work_phase() -> void:
	"""Cache logo boxes for all collected and backfill covers as a sync phase.

	Runs on the sync thread. Downloads happen on the main thread, detection on the
	background worker thread, and progress is updated as each cover completes.
	"""
	if not data_manager.logo_box:
		return
	if not data_manager.database.is_database_ready():
		return

	# 1. Query existing games with covers but no cached logo box and merge them
	#    into the cover URL map. This is the backfill portion of the phase.
	var rows = _wait_for_async(func(callback: Callable):
		SystemManager.memory.queue_db_task(
			func():
				return data_manager.database.query_array(
					"SELECT romm_id, cover_url, title FROM games WHERE cover_url != '' AND cover_url IS NOT NULL AND (logo_box = '' OR logo_box = '{}')"
				),
			func(result: Array):
				callback.call(result)
		)
	, 120000)

	if rows == null:
		rows = []

	_sync_cover_url_to_games_mutex.lock()
	for row in rows:
		var url = row.get("cover_url", "")
		var title = row.get("title", "")
		var romm_id = row.get("romm_id", 0)
		if url == "" or romm_id <= 0:
			continue
		if not _sync_cover_url_to_games.has(url):
			_sync_cover_url_to_games[url] = [] as Array[GameResource]
			_sync_total += 1  # Each unique backfill cover is also a work unit
		var already_present = false
		for g in _sync_cover_url_to_games[url]:
			if g.romm_id == romm_id:
				already_present = true
				break
		if not already_present:
			var game = GameResource.new()
			game.romm_id = romm_id
			game.title = title
			game.cover_url = url
			_sync_cover_url_to_games[url].append(game)

	var cover_total = _sync_cover_url_to_games.size()
	var url_to_games: Dictionary = {}
	for url in _sync_cover_url_to_games.keys():
		url_to_games[url] = _sync_cover_url_to_games[url].duplicate()
	_sync_cover_url_to_games_mutex.unlock()

	if cover_total == 0:
		return

	_sync_platform = "Logo boxes"
	_sync_platform_index = _sync_platform_count + 1
	print("[SyncThread] Logo box phase: %d unique covers to process" % cover_total)

	# Emit progress so the total includes the new cover work.
	var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
	call_deferred("_update_sync_fg_service", _sync_platform, _sync_current, _sync_total)
	call_deferred("_emit_sync_progress", progress_pct * 0.01, _sync_current, _sync_total)

	# 2. Process already-cached covers immediately and queue missing covers for
	#    download on the main thread. Each cover calls back as it finishes.
	var missing_urls: Array[String] = []
	for url in url_to_games.keys():
		var games: Array[GameResource] = url_to_games[url]
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			data_manager.logo_box.process_cover_url(url, games, _on_cover_processed)
		else:
			_sync_covers_mutex.lock()
			if not _sync_covers_pending_set.has(url):
				_sync_covers_pending.append(url)
				_sync_covers_pending_set[url] = true
			_sync_covers_mutex.unlock()

	_dispatch_covers_to_main_thread()

	# 3. Block the sync thread until all downloads and detections complete.
	#    The main thread and worker thread handle the actual work.
	_wait_for_all_cover_processing()


const COVER_PROGRESS_EVERY: int = 5

func _on_cover_processed() -> void:
	"""Called on the main thread when a cover has been processed by the worker."""
	_sync_current += 1
	if _sync_current % COVER_PROGRESS_EVERY == 0 or _sync_current == _sync_total:
		var progress_pct = float(_sync_current) / float(_sync_total) * 100.0 if _sync_total > 0 else 0.0
		_emit_sync_progress(progress_pct * 0.01, _sync_current, _sync_total)
		_update_sync_fg_service(_sync_platform, _sync_current, _sync_total)


func _wait_for_all_cover_processing() -> void:
	"""Wait for all cover downloads and queued logo box detections to finish.

	Blocks the sync thread but leaves the main thread and UI responsive.
	"""
	print("[SyncThread] Waiting for cover downloads and logo box detections to finish...")

	# Wait for any remaining cover downloads to dispatch and complete.
	while true:
		_sync_covers_mutex.lock()
		var still_pending = _sync_covers_pending.size() > 0
		var dispatched = _sync_covers_dispatched_count
		var processed = _sync_covers_processed_count
		_sync_covers_mutex.unlock()
		if still_pending:
			_dispatch_covers_to_main_thread()
			OS.delay_msec(10)
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

	if data_manager.logo_box:
		data_manager.logo_box.wait_for_all()

	print("[SyncThread] Cover processing complete")


func _dispatch_covers_to_main_thread():
	"""Dispatch collected cover URLs to main thread for async download."""
	_sync_covers_mutex.lock()
	if _sync_covers_pending.is_empty():
		_sync_covers_mutex.unlock()
		return

	var urls = _sync_covers_pending.duplicate()
	_sync_covers_pending.clear()
	_sync_covers_pending_set.clear()
	_sync_covers_dispatched_count += 1
	_sync_covers_mutex.unlock()

	# Capture the game mapping for these URLs while we hold the mutex
	var url_to_games := {}
	_sync_cover_url_to_games_mutex.lock()
	for url in urls:
		if _sync_cover_url_to_games.has(url):
			url_to_games[url] = _sync_cover_url_to_games[url].duplicate()
	_sync_cover_url_to_games_mutex.unlock()

	call_deferred("_download_covers_on_main_thread", urls, url_to_games, _on_cover_processed)


func _download_covers_on_main_thread(urls: Array[String], url_to_games: Dictionary = {}, on_complete: Callable = Callable()):
	"""Download covers on main thread using existing async infrastructure.

	Called via call_deferred from sync thread. Queues each cover to
	SystemManager.download for parallel async download. After each download
	finishes, the cover is handed to the logo box cache manager.
	"""

	for url in urls:
		var cache_path = data_manager.cover.get_cached_image_path(url)
		if FSM.file_exists(cache_path):
			# Already cached: send directly to logo box worker; no network wait.
			var cached_games: Array[GameResource] = url_to_games.get(url, [] as Array[GameResource])
			if cached_games:
				data_manager.logo_box.process_cover_url(url, cached_games, on_complete)
			continue

		# Track pending download
		_sync_pending_downloads_mutex.lock()
		_sync_pending_downloads += 1
		_sync_pending_downloads_mutex.unlock()

		# Use existing async download path
		data_manager.cover.download_cover(url, func(_ok):
			var downloaded_games: Array[GameResource] = url_to_games.get(url, [] as Array[GameResource])
			if downloaded_games:
				data_manager.logo_box.process_cover_url(url, downloaded_games, on_complete)

			_sync_pending_downloads_mutex.lock()
			_sync_pending_downloads -= 1
			var downloads_done = _sync_pending_downloads == 0
			_sync_pending_downloads_mutex.unlock()
			if downloads_done:
				_sync_pending_downloads_semaphore.post()
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
		SystemManager.memory.queue_db_task(
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
		SystemManager.memory.queue_db_task(
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
		SystemManager.memory.queue_db_task(
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


func _precalculate_totals_sync(platforms: Array) -> int:
	"""Pre-calculate total games for all platforms - sync thread version."""
	_precalc_platform_totals.clear()
	var grand_total = 0

	for platform in platforms:
		var platform_id = str(platform.id)
		var fetch_start = Time.get_ticks_msec()
		var result = SystemManager.network.fetch_games_sync(platform_id, 0, 1)
		var fetch_time = Time.get_ticks_msec() - fetch_start
		if result.success and result.data is Dictionary:
			var platform_total = int(result.data.get("total", 0))
			grand_total += platform_total
			_precalc_platform_totals[platform_id] = platform_total
			print("[SyncThread] Pre-calc: %s = %d games (%dms)" % [platform.name, platform_total, fetch_time])
		OS.delay_usec(1000)

	return grand_total


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
	var db_time = Time.get_ticks_msec() - db_start

	# Phase 3: Collect unique cover URLs for later logo box caching.
	var cover_start = Time.get_ticks_msec()
	_sync_cover_url_to_games_mutex.lock()
	for game in games:
		if game.has_cover_art and game.cover_url != "" and game.cover_url.begins_with("http"):
			if not _sync_cover_url_to_games.has(game.cover_url):
				_sync_cover_url_to_games[game.cover_url] = [] as Array[GameResource]
				_sync_total += 1  # Each unique cover is a logo box work unit
			_sync_cover_url_to_games[game.cover_url].append(game)
	_sync_cover_url_to_games_mutex.unlock()
	var cover_time = Time.get_ticks_msec() - cover_start

	var total_time = Time.get_ticks_msec() - batch_start
	# Batch timing logging removed for cleaner sync output

	return inserted


func _check_and_insert_games_sync(games: Array[GameResource]) -> int:
	"""Check siblings and insert games in a single DB task.

	This combines what used to be two separate DB tasks (sibling check + insert)
	into one, halving the DB queue pressure.
	"""
	if games.is_empty() or not data_manager.database.is_database_ready():
		return 0

	var result = _wait_for_async(func(callback: Callable):
		SystemManager.memory.queue_db_task(
			func():
				# Step 1: Check siblings for all games
				for game in games:
					if game.siblings.size() > 0:
						var has_sibling = _check_siblings_in_db(game.romm_id, game.siblings)
						game.is_master_entry = not has_sibling

				# Step 2: Insert all games in one transaction
				var success = _insert_games_transaction(games)
				return success,
			func(success: bool):
				callback.call(success)
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

		var insert_data = _build_insert_query(game)
		var insert_result = data_manager.database.query_bool_unlocked(insert_data.query, insert_data.bindings)
		if not insert_result:
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
			return float(_sync_current) / float(_sync_total),
		func(progress: float) -> String:
			var pct = int(progress * 100)
			if _sync_platform != "":
				return "Platform %d/%d: %s - %d/%d (%d%%)" % [_sync_platform_index, _sync_platform_count, _sync_platform, _sync_current, _sync_total, pct]
			return "Syncing %d/%d (%d%%)" % [_sync_current, _sync_total, pct]
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


func _ensure_consistent_masters_in_batch(games: Array[GameResource]):
	"""Ensure that only the game with the lowest ID in each sibling group is marked as master.

	This handles the race condition where multiple siblings from the same group are processed
	in the same batch and all pass the database sibling check."""

	# Build a map of sibling group IDs to the lowest ID in that group within this batch
	var sibling_group_lowest: Dictionary = {}

	for game in games:
		# Build list of all IDs in this sibling group (including the game itself)
		var all_ids_in_group = [game.romm_id]
		for sibling in game.siblings:
			var sid = sibling.get("id", 0)
			if sid != 0:
				all_ids_in_group.append(sid)

		# Find the lowest ID in this group
		var lowest_id = all_ids_in_group.min()

		# Use a unique key for this sibling group (sorted IDs to ensure consistency)
		all_ids_in_group.sort()
		var group_key = ",".join(all_ids_in_group.map(func(id): return str(id)))

		# Track the lowest ID for this group
		if not sibling_group_lowest.has(group_key):
			sibling_group_lowest[group_key] = lowest_id
		else:
			sibling_group_lowest[group_key] = min(sibling_group_lowest[group_key], lowest_id)

	# Now apply consistent master selection
	for game in games:
		# Skip if already marked as non-master due to DB check
		if not game.is_master_entry:
			continue

		# Build the same group key
		var all_ids_in_group = [game.romm_id]
		for sibling in game.siblings:
			var sid = sibling.get("id", 0)
			if sid != 0:
				all_ids_in_group.append(sid)

		all_ids_in_group.sort()
		var group_key = ",".join(all_ids_in_group.map(func(id): return str(id)))

		# Only keep as master if this game has the lowest ID in its group
		var lowest_id = sibling_group_lowest.get(group_key, game.romm_id)
		if game.romm_id != lowest_id:
			game.is_master_entry = false


func _group_games_by_cover_url(games: Array[GameResource]):
	"""Group games with identical cover URLs as siblings.

	This function identifies games that share the same cover URL and adds them
	to each other's sibling lists. RomM siblings take precedence, so we only
	add cover-based siblings that aren't already romm siblings."""

	if games.size() < 2:
		return

	# Build a map of cover URL -> Array of game indices
	var cover_groups: Dictionary = {}

	for i in range(games.size()):
		var game = games[i]
		if game.cover_url == "":
			continue

		if not cover_groups.has(game.cover_url):
			cover_groups[game.cover_url] = []
		cover_groups[game.cover_url].append(i)

	# For each cover group with 2+ games, cross-reference them as siblings
	for cover_url in cover_groups.keys():
		var indices = cover_groups[cover_url]
		if indices.size() < 2:
			continue

		# Pre-build sibling entries once per group (shared references, no inner-loop alloc)
		var all_entries: Array[Dictionary] = []
		for idx in indices:
			var g = games[idx]
			all_entries.append({
				"id": g.romm_id,
				"name": g.title,
				"file_name": g.file_name,
				"file_size": g.file_size
			})

		# For each game, add all group entries except self and existing romm siblings
		for i in range(indices.size()):
			var current_game = games[indices[i]]
			var current_id = current_game.romm_id

			# Fast lookup of existing sibling IDs
			var existing: Dictionary = {}
			for sibling in current_game.siblings:
				existing[sibling.get("id", 0)] = true

			# Append pre-built entries (skips self + existing romm siblings)
			for entry in all_entries:
				var other_id = entry.get("id", 0)
				if other_id == current_id or existing.has(other_id):
					continue
				current_game.siblings.append(entry)
				existing[other_id] = true


func _create_game_from_data(data: Dictionary, platform_slug: String, check_siblings: bool = true) -> GameResource:
	var game = GameResource.new()
	game.id = str(data.get("id", ""))
	game.romm_id = data.get("id", 0)
	game.title = str(data.get("name", ""))
	game.platform = str(data.get("platform_display_name", ""))
	game.platform_slug = platform_slug if platform_slug != "" else str(data.get("platform_slug", ""))
	game.cover_url = str(data.get("url_cover", ""))
	game.cover_path = str(data.get("path_cover_large", ""))
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

	# Extract siblings from API response
	var siblings: Array[Dictionary] = []
	if data.has("siblings") and data["siblings"] is Array:
		for sibling_data in data["siblings"]:
			if sibling_data is Dictionary:
				# Note: Sibling data from API only has basic info (id, name, fs_name_no_ext, etc.)
				# Full details (including proper file name with extension) will be fetched on-demand
				# when the user selects the sibling in the game details view

				var sibling = {
					"id": sibling_data.get("id", 0),
					"name": str(sibling_data.get("name", "")),
					"file_name": str(sibling_data.get("fs_name_no_ext", "")),  # Will be updated on-demand
					"file_size": sibling_data.get("fs_size_bytes", 0),
					"title_id": ""  # Will be extracted on launch
				}
				siblings.append(sibling)
	else:
		pass
	game.siblings = siblings

	# Determine if this should be a master entry
	# A game is a master if none of its siblings already exist in our database
	# This will be checked in batch during sync, or set to true for individual adds
	if check_siblings:
		game.is_master_entry = not _has_sibling_in_database(game.romm_id, siblings)
	else:
		# During batch sync, we'll check siblings separately
		game.is_master_entry = true  # Default, will be updated by batch check

	# Mark games without cover art so filtering can be applied dynamically
	if game.cover_url == "" or game.cover_url == "null" or game.cover_url == "<null>" or game.cover_url == "None":
		game.has_cover_art = false

	return game


func _has_sibling_in_database(romm_id: int, siblings: Array[Dictionary]) -> bool:
	"""Check if any sibling (NOT including self) already exists as a master entry in the database"""
	if not data_manager.database.is_database_ready():
		return false

	# Build list of sibling IDs to check (excluding self - we only want to check siblings)
	var ids_to_check = []
	for sibling in siblings:
		var sid = sibling.get("id", 0)
		if sid != 0 and sid != romm_id:  # Exclude self
			ids_to_check.append(sid)

	# If no siblings to check, return false
	if ids_to_check.size() == 0:
		return false

	# Check if any siblings already exist as master entries
	var placeholders = ", ".join(ids_to_check.map(func(_id): return "?"))
	var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % placeholders
	var query_result = data_manager.database.query_array(query, ids_to_check)

	if query_result.size() > 0:
		var count = query_result[0]["count"]
		return count > 0

	return false


func _build_insert_query(game: GameResource) -> Dictionary:
	"""Build SQL INSERT query and bindings for a game - used for batch processing.

	PRESERVES existing has_local_copy, downloaded_sibling_ids, and file_path
	if the game already exists in the database. This prevents downloaded games
	from disappearing after a re-sync."""

	# Check if game already exists and preserve download status
	var has_local_copy = 1 if game.has_local_copy else 0
	var downloaded_sibling_ids = JSON.stringify(game.downloaded_sibling_ids)
	var file_path = game.file_path

	if data_manager.database.is_database_ready() and game.romm_id > 0:
		var check_query = "SELECT has_local_copy, downloaded_sibling_ids, file_path, cover_group_id, cover_group_master FROM games WHERE romm_id = ?"
		var query_result = data_manager.database.query_array_unlocked(check_query, [game.romm_id])
		if query_result.size() > 0:
			var existing = query_result[0]
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

	var query = """
		INSERT OR REPLACE INTO games
		(id, romm_id, title, platform, platform_slug, cover_url, cover_path,
		 file_name, file_path, file_size, has_local_copy, last_updated,
		 description, genres, rating, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played, title_id, cover_group_id, cover_group_master, igdb_metadata)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
		JSON.stringify(game.siblings),
		game.selected_sibling_id,
		1 if game.is_master_entry else 0,
		downloaded_sibling_ids,
		1 if game.has_cover_art else 0,
		game.last_played,
		game.title_id,
		game.cover_group_id,
		1 if game.cover_group_master else 0,
		JSON.stringify(game.igdb_metadata)
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


# ==================== BATCH NOTIFICATION SYSTEM ====================

func _start_sync_batch_mode():
	"""Start batching game_added signals for efficient UI updates."""
	_sync_batch_mode = true
	_sync_batch_pending.clear()
	_sync_batch_last_emit_time = Time.get_ticks_msec()

	# Notify listeners that sync is starting - allows UI to clear cache before new data arrives
	data_manager.sync_started.emit()

	# Create timer to periodically flush notifications
	if _sync_batch_timer:
		_sync_batch_timer.queue_free()
	_sync_batch_timer = Timer.new()
	_sync_batch_timer.wait_time = BATCH_EMIT_INTERVAL_MS / 1000.0  # Convert ms to seconds
	_sync_batch_timer.one_shot = false
	_sync_batch_timer.timeout.connect(_flush_batch_notifications)
	add_child(_sync_batch_timer)
	_sync_batch_timer.start()


func _stop_sync_batch_mode():
	"""Stop batch mode and flush any remaining notifications."""
	_sync_batch_mode = false

	# Stop the timer first
	if _sync_batch_timer:
		_sync_batch_timer.stop()
		_sync_batch_timer.queue_free()
		_sync_batch_timer = null

	# Flush any remaining notifications
	_sync_batch_pending_mutex.lock()
	var has_pending = _sync_batch_pending.size() > 0
	_sync_batch_pending_mutex.unlock()

	if has_pending:
		_flush_batch_notifications()


func is_sync_in_progress() -> bool:
	"""Check if a sync is currently in progress."""
	return _sync_batch_mode


func queue_batch_notification(game: GameResource):
	"""Public entry point to queue a game notification during batch mode."""
	_queue_batch_notification(game)


func _queue_batch_notification(game: GameResource):
	"""Queue a game notification during batch mode. Called via call_deferred from DB thread."""
	_sync_batch_pending_mutex.lock()
	_sync_batch_pending.append(game)
	_sync_batch_pending_mutex.unlock()


func _flush_batch_notifications():
	"""Emit batched games and clear the pending list."""
	_sync_batch_pending_mutex.lock()
	if _sync_batch_pending.size() == 0:
		_sync_batch_pending_mutex.unlock()
		return

	var games = _sync_batch_pending.duplicate()
	_sync_batch_pending.clear()
	_sync_batch_pending_mutex.unlock()

	var start_index = _sync_current - games.size()

	data_manager.games_batch_added.emit(_sync_platform, start_index, games)

	_sync_batch_last_emit_time = Time.get_ticks_msec()


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
		SyncState.CALCULATING_TOTALS:
			return "CALCULATING_TOTALS"
		SyncState.PLATFORM_ITERATING:
			return "PLATFORM_ITERATING"
		SyncState.PLATFORM_FETCHING:
			return "PLATFORM_FETCHING"
		SyncState.PLATFORM_PROCESSING:
			return "PLATFORM_PROCESSING"
		SyncState.PLATFORM_BATCHING:
			return "PLATFORM_BATCHING"
		SyncState.COVER_FOLDING:
			return "COVER_FOLDING"
		SyncState.COMPLETING:
			return "COMPLETING"
		SyncState.ERROR:
			return "ERROR"
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
