extends Manager

# DataManager - Self-contained data persistence and caching manager
# Combines SQLite database operations and file system image caching

signal database_ready()
signal sync_completed(success: bool, message: String)
signal sync_progress(percent: float, current: int, total: int)
signal game_added(game: GameResource)
signal game_updated(game: GameResource)
signal games_removed(platform_slug: String)
signal image_loaded(url: String, texture: Texture2D)
signal cache_cleared()

# NEW: Batch notification signals for efficient UI updates
signal games_batch_added(platform_slug: String, start_index: int, games: Array[GameResource])

const DB_PATH = "user://database/kyodai.db"
const CACHE_FOLDER = "user://cache/covers/"

var _db: SQLite = null
var _is_db_ready: bool = false
var _loading_images: Dictionary = {}
var _sync_notification_id: int = -1

# Logging control
var _verbose_sql: bool = false  # Set to true to see SQL queries

# Debug toggle - hide games without cover art during sync
const _DEBUG_HIDE_GAMES_WITHOUT_COVERS: bool = true  # Set to true to skip games without cover art
var _sync_skipped_no_cover: int = 0  # Counter for skipped games

# Sync state
var _sync_current: int = 0
var _sync_total: int = 0
var _sync_platform: String = ""
var _sync_platform_index: int = 0  # Current platform number (1-based)
var _sync_platform_count: int = 0  # Total platforms
var _sync_platform_total: int = 0  # Total games in current platform

# NEW: Batch notification system for incremental UI updates
var _sync_batch_mode: bool = false
var _sync_batch_pending: Array[GameResource] = []
var _sync_batch_pending_mutex: Mutex = Mutex.new()  # Thread-safe access
var _sync_batch_timer: Timer = null
var _sync_batch_last_emit_time: int = 0
const BATCH_EMIT_INTERVAL_MS: int = 800  # Emit every 500ms during sync

# Batch processing state
var _batch_remaining: int = 0
var _batch_callback: Callable = Callable()
var _batch_success_count: int = 0

# Pre-calculation state (avoid closures)
var _precalc_pending: int = 0
var _precalc_total: int = 0
var _precalc_callback: Callable = Callable()

# Cover download deduplication - tracks in-flight downloads across entire sync
var _active_downloads: Dictionary = {}  # url -> {callbacks: Array[Callable], completed: bool, success: bool}
var _active_downloads_mutex: Mutex = Mutex.new()  # Thread-safe access to _active_downloads

func _ready():
	_ensure_memory_manager()
	_initialize_database()
	_ensure_cache_folder()

func _ensure_memory_manager():
	if MemoryManager._instance == null:
		var mm = MemoryManager.new()
		add_child(mm)

func _initialize_database():
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("database"):
		dir.make_dir("database")
	
	_db = SQLite.new()
	_db.path = DB_PATH
	_db.verbosity_level = SQLite.QUIET if not _verbose_sql else SQLite.VERBOSE
	
	if _db.open_db():
		_create_tables()
		_is_db_ready = true
		database_ready.emit()

func _create_tables():
	_db.query("""
		CREATE TABLE IF NOT EXISTS games (
			id TEXT PRIMARY KEY,
			romm_id INTEGER UNIQUE NOT NULL,
			title TEXT NOT NULL,
			platform TEXT,
			platform_slug TEXT,
			cover_url TEXT,
			cover_path TEXT,
			file_name TEXT,
			file_path TEXT,
			file_size INTEGER DEFAULT 0,
			has_local_copy INTEGER DEFAULT 0,
			last_updated TEXT,
			description TEXT,
			genres TEXT,
			rating REAL DEFAULT 0.0,
			siblings TEXT DEFAULT '[]',
			selected_sibling_id INTEGER DEFAULT 0,
			is_master_entry INTEGER DEFAULT 1,
			downloaded_sibling_ids TEXT DEFAULT '[]',
			has_cover_art INTEGER DEFAULT 1,
			last_played TEXT DEFAULT ''
		)
	""")
	
	_db.query("""
		CREATE TABLE IF NOT EXISTS platforms (
			id TEXT PRIMARY KEY,
			romm_id INTEGER UNIQUE NOT NULL,
			name TEXT NOT NULL,
			slug TEXT UNIQUE NOT NULL,
			icon_url TEXT,
			icon_path TEXT,
			emulator_path TEXT,
			extensions TEXT
		)
	""")
	
	_db.query("CREATE INDEX IF NOT EXISTS idx_games_platform ON games(platform_slug)")
	_db.query("CREATE INDEX IF NOT EXISTS idx_games_title ON games(title)")

func is_database_ready() -> bool:
	return _is_db_ready

func _escape_sql(text: String) -> String:
	return text.replace("'", "''")

# ==================== SYNC ====================

func sync_enabled_platforms(callback: Callable = Callable()) -> void:
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(false, "Database not ready", 0, 0)
		return
	
	_sync_current = 0
	_sync_total = 0
	_sync_platform = ""
	
	var enabled = _get_enabled_platforms()
	# Get all platforms that currently have games in the database
	var db_platforms = _get_db_platform_slugs()
	var enabled_slugs = enabled.map(func(p): return p.slug)
	
	# Find platforms that have games but are now disabled
	var disabled_platforms: Array[String] = []
	for slug in db_platforms:
		if not slug in enabled_slugs:
			disabled_platforms.append(slug)
	
	if disabled_platforms.size() > 0:
		print("[DataManager] Removing ", disabled_platforms.size(), " disabled platforms")
		_remove_disabled_platforms(disabled_platforms, enabled, callback)
	else:
		_start_sync(enabled, callback)

func _remove_disabled_platforms(platforms: Array[String], enabled_platforms: Array, final_callback: Callable):
	"""Remove games from disabled platforms one by one, then start sync"""
	_remove_next_disabled(platforms, 0, enabled_platforms, final_callback)

func _remove_next_disabled(platforms: Array[String], index: int, enabled_platforms: Array, final_callback: Callable):
	if index >= platforms.size():
		# All disabled platforms removed, start the sync
		_start_sync(enabled_platforms, final_callback)
		return
	
	var platform_slug = platforms[index]
	
	remove_platform_games(platform_slug, func(_success):
		# Continue to next platform regardless of success
		_remove_next_disabled(platforms, index + 1, enabled_platforms, final_callback)
	)

func _get_db_platform_slugs() -> Array[String]:
	"""Get list of platform slugs that have games in the database"""
	var slugs: Array[String] = []
	if not _is_db_ready:
		return slugs
	
	_db.query("SELECT DISTINCT platform_slug FROM games")
	for row in _db.query_result:
		var slug = row.get("platform_slug", "")
		if slug != "":
			slugs.append(slug)
	
	return slugs

func _start_sync(enabled: Array, callback: Callable):
	"""Start the actual sync after cleaning up disabled platforms"""
	if enabled.size() == 0:
		# Emit sync_completed so LibraryView refreshes even if no platforms to sync
		sync_completed.emit(true, "No platforms enabled")
		if callback.is_valid():
			callback.call(true, "", 0, 0)
		return
	
	print("[DataManager] Syncing ", enabled.size(), " platforms")
	
	# Reset sync state
	_sync_current = 0
	_sync_platform_index = 0
	_sync_platform_count = enabled.size()
	_sync_skipped_no_cover = 0  # Reset skipped games counter
	
	# Start batch mode for efficient UI updates
	_start_sync_batch_mode()
	
	# Pre-calculate total games across all platforms
	_precalculate_totals(enabled, func(grand_total: int):
		_sync_total = grand_total
		print("[DataManager] Total games to sync: ", grand_total)
		
		# Show notification with grand total
		_sync_notification_id = NotificationManager.show_notification(
			"Syncing...",
			Notification.Type.INFO,
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
		
		_sync_platforms(enabled, 0, 0, callback)
	)

func _precalculate_totals(platforms: Array, callback: Callable):
	"""Fetch total game count for all platforms upfront using instance vars (no closures)"""
	_precalc_pending = platforms.size()
	_precalc_total = 0
	_precalc_callback = callback
	
	if _precalc_pending == 0:
		callback.call(0)
		return
	
	for platform in platforms:
		# Fetch just the total count (offset=0, limit=1)
		_fetch_batch(str(platform.id), 0, 1, func(data, error):
			if error == "" and data is Dictionary:
				_precalc_total += int(data.get("total", 0))
			
			_precalc_pending -= 1
			if _precalc_pending <= 0:
				var cb = _precalc_callback
				_precalc_callback = Callable()
				cb.call(_precalc_total)
		)

func _get_enabled_platforms() -> Array:
	var result = []
	var setting = SettingsManager.get_setting("enabled_platforms")
	if not setting or not setting.value is Dictionary:
		return result
	
	for slug in setting.value.keys():
		var data = setting.value[slug]
		var enabled = false
		var id = 0
		var name = slug.capitalize()
		
		if data is bool:
			enabled = data
		elif data is Dictionary:
			enabled = data.get("enabled", false)
			id = data.get("id", 0)
			name = data.get("name", slug.capitalize())
		
		if enabled and id > 0:
			result.append({"slug": slug, "id": id, "name": name})
	
	return result

func _sync_platforms(platforms: Array, index: int, total_synced: int, callback: Callable):
	if index >= platforms.size():
		print("[DataManager] Sync complete: ", total_synced, " games")
		if _DEBUG_HIDE_GAMES_WITHOUT_COVERS and _sync_skipped_no_cover > 0:
			print("[DataManager] DEBUG: ", _sync_skipped_no_cover, " games hidden (no cover art)")
		
		# Flush any remaining batch notifications before stopping
		_flush_batch_notifications()
		
		# Stop batch mode
		_stop_sync_batch_mode()
		
		# Clean up download tracking to free memory
		_active_downloads.clear()
		var completion_msg = "Synced " + str(total_synced) + " games"
		if _DEBUG_HIDE_GAMES_WITHOUT_COVERS and _sync_skipped_no_cover > 0:
			completion_msg += " (" + str(_sync_skipped_no_cover) + " hidden, no covers)"
		sync_completed.emit(true, completion_msg)
		if callback.is_valid():
			callback.call(true, "", total_synced, 0)
		return
	
	var platform = platforms[index]
	_sync_platform = platform.name
	_sync_platform_index = index + 1  # 1-based index for display
	
	sync_platform_games(platform.id, platform.slug, platform.name, func(success, msg, synced, total):
		if success:
			total_synced += synced
		_sync_platforms(platforms, index + 1, total_synced, callback)
	)

func sync_platform_games(platform_id: int, platform_slug: String, platform_name: String, callback: Callable):
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(false, "Database not ready", 0, 0)
		return
	
	var batch_size = 100
	
	# Fetch first batch
	_fetch_batch(str(platform_id), 0, batch_size, func(data, error):
		if error != "" or not data is Dictionary:
			if callback.is_valid():
				callback.call(false, error if error else "Invalid data", 0, 0)
			return
		
		var total = int(data.get("total", 0))
		var items = data.get("items", [])
		
		if total == 0:
			if callback.is_valid():
				callback.call(true, "", 0, 0)
			return
		
		_process_batch(items, platform_slug, func(succeeded):
			if succeeded >= total:
				# All games in one batch
				if callback.is_valid():
					callback.call(true, "", succeeded, total)
			else:
				# Need more batches
				_fetch_more_batches(platform_id, platform_slug, batch_size, total, succeeded, batch_size, callback)
		)
	)

func _fetch_more_batches(platform_id: int, platform_slug: String, batch_size: int, total: int, synced: int, offset: int, callback: Callable):
	_fetch_batch(str(platform_id), offset, batch_size, func(data, error):
		if error != "" or not data is Dictionary:
			if callback.is_valid():
				callback.call(true, "", synced, total)
			return
		
		var items = data.get("items", [])
		if items.size() == 0:
			if callback.is_valid():
				callback.call(true, "", synced, total)
			return
		
		_process_batch(items, platform_slug, func(succeeded):
			var new_synced = synced + succeeded
			if new_synced >= total:
				if callback.is_valid():
					callback.call(true, "", new_synced, total)
			else:
				_fetch_more_batches(platform_id, platform_slug, batch_size, total, new_synced, offset + batch_size, callback)
		)
	)

func _fetch_batch(platform_id: String, offset: int, limit: int, callback: Callable):
	NetworkManager.fetch_games(callback, platform_id, offset, limit)

func _process_batch(items: Array, platform_slug: String, on_complete: Callable):
	"""Process a batch of games using the MemoryManager batch scheduler."""
	var total = items.size()
	if total == 0:
		on_complete.call(0)
		return
	
	# Phase 1: Create GameResources (fast, on main thread)
	var games: Array[GameResource] = []
	var sibling_check_data: Array[Dictionary] = []
	
	for i in range(items.size()):
		var game_data = items[i]
		var game = _create_game_from_data(game_data, platform_slug, false)  # false = don't check siblings yet
		
		if game != null:
			games.append(game)
			sibling_check_data.append({
				"index": i,
				"romm_id": game.romm_id,
				"siblings": game.siblings
			})
	
	if games.is_empty():
		on_complete.call(0)
		return
	
	print("[DataManager] Processing batch of %d games with batched sibling checks..." % games.size())
	
	# Phase 2: Batch sibling checks (async, spread across frames)
	var sibling_batch_id = MemoryManager.start_batch(
		sibling_check_data,
		func(item: Dictionary, _idx: int) -> bool:
			return _check_siblings_in_db(item["romm_id"], item["siblings"]),
		MemoryManager.BatchMode.DB_THREAD,
		5,  # 5 sibling checks per frame
		func(processed: int, total_count: int):
			print("[DataManager] Sibling checks: %d/%d" % [processed, total_count]),
		func(sibling_results: Array):
			# Apply sibling results to games
			for i in range(sibling_results.size()):
				if i < games.size():
					var has_sibling = sibling_results[i]
					games[i].is_master_entry = not has_sibling
			
			# Apply consistent master selection by lowest ID within the batch
			# This handles the case where multiple siblings are processed in the same batch
			_ensure_consistent_masters_in_batch(games)
			
			print("[DataManager] Sibling checks complete, starting DB inserts...")
			
			# Phase 3: Batch DB inserts (async, spread across frames)
			_db_insert_batch(games, on_complete)
	)

func _db_insert_batch(games: Array[GameResource], on_complete: Callable):
	"""Batch insert games into DB."""
	# Use a thread-safe container for collecting games with covers
	var games_with_covers_mutex = Mutex.new()
	var games_with_covers: Array[GameResource] = []
	
	var db_batch_id = MemoryManager.start_batch(
		games,
		func(game: GameResource, _idx: int) -> bool:
			if game == null:
				return false
			
			var query = _build_insert_query(game)
			var success = _db.query(query)
			
			if success and game.has_cover_art:
				# Collect for cover downloads (thread-safe)
				games_with_covers_mutex.lock()
				games_with_covers.append(game)
				games_with_covers_mutex.unlock()
				
				# Queue for UI notification on main thread - ONLY for master entries
				# This prevents sibling ROMs from showing in library during progressive sync
				if game.is_master_entry:
					if _sync_batch_mode:
						call_deferred("_queue_batch_notification", game)
					else:
						call_deferred("emit_signal", "game_added", game)
			
			if success:
				_sync_current += 1
			
			return success,
		MemoryManager.BatchMode.DB_THREAD,
		10,  # 10 DB inserts per frame
		func(processed: int, total_count: int):
			print("[DataManager] DB inserts: %d/%d" % [processed, total_count]),
		func(_results: Array):
			print("[DataManager] DB inserts complete, starting cover downloads...")
			
			# Phase 4: Batch cover downloads (async, spread across frames)
			_cover_download_batch(games_with_covers, on_complete)
	)

func _cover_download_batch(games: Array[GameResource], on_complete: Callable):
	"""Batch download covers."""
	var cover_data: Array[Dictionary] = []
	for game in games:
		if game.cover_url != "" and game.cover_url.begins_with("http"):
			cover_data.append({
				"url": game.cover_url,
				"cache_path": get_cached_image_path(game.cover_url)
			})
	
	if cover_data.is_empty():
		print("[DataManager] No covers to download")
		on_complete.call(games.size())
		return
	
	var completed_count: int = 0
	
	var cover_batch_id = MemoryManager.start_batch(
		cover_data,
		func(item: Dictionary, _idx: int) -> bool:
			# Queue download via DownloadManager
			var success = false
			_download_cover_sync(item["url"], item["cache_path"])
			return success,
		MemoryManager.BatchMode.SYNC,  # Downloads are already async via DownloadManager
		5,  # 5 covers queued per frame
		func(processed: int, total_count: int):
			print("[DataManager] Cover downloads queued: %d/%d" % [processed, total_count]),
		func(_results: Array):
			print("[DataManager] Cover downloads complete")
			on_complete.call(games.size())
	)

func _download_cover_sync(url: String, cache_path: String) -> bool:
	"""Synchronous wrapper for cover download - actually queues async download."""
	# Check if already cached
	if FileAccess.file_exists(cache_path):
		return true
	
	# This is a placeholder - actual download happens via _download_cover
	# which uses DownloadManager
	_download_cover(url, func(_ok): pass)
	return true  # Return true to indicate download was initiated

func _check_siblings_in_db(romm_id: int, siblings: Array[Dictionary]) -> bool:
	"""Check if any sibling exists in DB - to be run on DB thread."""
	if _db == null:
		return false
	
	# Build list of all IDs to check (self + siblings)
	var ids_to_check = [romm_id]
	for sibling in siblings:
		var sid = sibling.get("id", 0)
		if sid != 0:
			ids_to_check.append(sid)
	
	if ids_to_check.is_empty():
		return false
	
	# Check if any of these IDs already exist as master entries
	var id_list = ", ".join(ids_to_check.map(func(id): return str(id)))
	var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % id_list
	
	var success = _db.query(query)
	if success and _db.query_result.size() > 0:
		return _db.query_result[0]["count"] > 0
	
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
			print("[DataManager] Marking game '%s' (ID: %d) as non-master - sibling with lower ID (%d) exists in batch" % [game.title, game.romm_id, lowest_id])
			game.is_master_entry = false

# ==================== BATCH NOTIFICATION SYSTEM ====================

func _start_sync_batch_mode():
	"""Start batching game_added signals for efficient UI updates."""
	_sync_batch_mode = true
	_sync_batch_pending.clear()
	_sync_batch_last_emit_time = Time.get_ticks_msec()
	
	# Create timer to periodically flush notifications
	if _sync_batch_timer:
		_sync_batch_timer.queue_free()
	_sync_batch_timer = Timer.new()
	_sync_batch_timer.wait_time = BATCH_EMIT_INTERVAL_MS / 1000.0  # Convert ms to seconds
	_sync_batch_timer.one_shot = false
	_sync_batch_timer.timeout.connect(_flush_batch_notifications)
	add_child(_sync_batch_timer)
	_sync_batch_timer.start()
	
	print("[DataManager] Batch mode started with timer")

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
	
	print("[DataManager] Batch mode stopped")

func _queue_batch_notification(game: GameResource):
	"""Queue a game notification during batch mode. Called via call_deferred from DB thread."""
	_sync_batch_pending_mutex.lock()
	_sync_batch_pending.append(game)
	var current_size = _sync_batch_pending.size()
	_sync_batch_pending_mutex.unlock()
	
	print("[DataManager] Queued game for batch notification: %s (pending: %d)" % [game.title, current_size])

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
	
	print("[DataManager] Emitting batch of %d games for %s" % [games.size(), _sync_platform])
	games_batch_added.emit(_sync_platform, start_index, games)
	
	_sync_batch_last_emit_time = Time.get_ticks_msec()

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
	
	# Extract siblings from API response
	var siblings: Array[Dictionary] = []
	if data.has("siblings") and data["siblings"] is Array:
		print("[DataManager] Found siblings array for game '%s' (ID: %d) with %d items" % [game.title, game.romm_id, data["siblings"].size()])
		
		for sibling_data in data["siblings"]:
			if sibling_data is Dictionary:
				# Note: Sibling data from API only has basic info (id, name, fs_name_no_ext, etc.)
				# Full details (including proper file name with extension) will be fetched on-demand
				# when the user selects the sibling in the game details view
				
				var sibling = {
					"id": sibling_data.get("id", 0),
					"name": str(sibling_data.get("name", "")),
					"file_name": str(sibling_data.get("fs_name_no_ext", "")),  # Will be updated on-demand
					"file_size": sibling_data.get("fs_size_bytes", 0)
				}
				siblings.append(sibling)
				print("[DataManager]   Sibling: id=%d, name='%s' (details will be fetched on-demand)" % [sibling.id, sibling.name])
	else:
		if data.has("siblings"):
			print("[DataManager] Game '%s' has siblings field but it's not an array (type: %s)" % [game.title, typeof(data["siblings"])])
		else:
			print("[DataManager] Game '%s' (ID: %d) has no siblings field" % [game.title, game.romm_id])
	game.siblings = siblings
	
	if siblings.size() > 0:
		print("[DataManager] Stored %d siblings for game '%s' (ID: %d)" % [siblings.size(), game.title, game.romm_id])
	
	# Determine if this should be a master entry
	# A game is a master if none of its siblings already exist in our database
	# This will be checked in batch during sync, or set to true for individual adds
	if check_siblings:
		game.is_master_entry = not _has_sibling_in_database(game.romm_id, siblings)
	else:
		# During batch sync, we'll check siblings separately
		game.is_master_entry = true  # Default, will be updated by batch check
	
	# Debug: Mark games without cover art as hidden if toggle is enabled
	if _DEBUG_HIDE_GAMES_WITHOUT_COVERS:
		print("[DataManager] DEBUG: Checking cover for '%s' - cover_url: '%s'" % [game.title, game.cover_url])
		if game.cover_url == "" or game.cover_url == "null" or game.cover_url == "<null>" or game.cover_url == "None":
			print("[DataManager] DEBUG: Marking game '%s' (ID: %d) as hidden - no cover art" % [game.title, game.romm_id])
			game.has_cover_art = false
			_sync_skipped_no_cover += 1
	
	return game

func _has_sibling_in_database(romm_id: int, siblings: Array[Dictionary]) -> bool:
	"""Check if any sibling (including self) already exists as a master entry in the database"""
	if not _is_db_ready:
		print("[DataManager] _has_sibling_in_database: DB not ready, returning false")
		return false
	
	# Build list of all IDs to check (self + siblings)
	var ids_to_check = [romm_id]
	for sibling in siblings:
		var sid = sibling.get("id", 0)
		if sid != 0:
			ids_to_check.append(sid)
	
	print("[DataManager] Checking if any sibling exists in DB for IDs: " + str(ids_to_check))
	
	# Check if any of these IDs already exist as master entries
	var id_list = ", ".join(ids_to_check.map(func(id): return str(id)))
	var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % id_list
	_db.query(query)
	
	if _db.query_result.size() > 0:
		var count = _db.query_result[0]["count"]
		print("[DataManager] Found %d existing master entries for these IDs" % count)
		return count > 0
	
	print("[DataManager] No existing master entries found")
	return false

func _build_insert_query(game: GameResource) -> String:
	"""Build SQL INSERT query for a game - used for batch processing."""
	return """
		INSERT OR REPLACE INTO games 
		(id, romm_id, title, platform, platform_slug, cover_url, cover_path, 
		 file_name, file_path, file_size, has_local_copy, last_updated, 
		 description, genres, rating, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played)
		VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', %d, %d, '%s', '%s', '%s', %f, '%s', %d, %d, '%s', %d, '%s')
	""" % [
		_escape_sql(game.id),
		game.romm_id,
		_escape_sql(game.title),
		_escape_sql(game.platform),
		_escape_sql(game.platform_slug),
		_escape_sql(game.cover_url),
		_escape_sql(game.cover_path),
		_escape_sql(game.file_name),
		_escape_sql(game.file_path),
		game.file_size,
		1 if game.has_local_copy else 0,
		_escape_sql(game.last_updated),
		_escape_sql(game.description),
		_escape_sql(",".join(game.genres)),
		game.rating,
		_escape_sql(JSON.stringify(game.siblings)),
		game.selected_sibling_id,
		1 if game.is_master_entry else 0,
		_escape_sql(JSON.stringify(game.downloaded_sibling_ids)),
		1 if game.has_cover_art else 0,
		_escape_sql(game.last_played)
	]

# ==================== DATABASE OPERATIONS ====================

func add_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
	MemoryManager.queue_db_task(
		func():
			var query = """
				INSERT OR REPLACE INTO games 
				(id, romm_id, title, platform, platform_slug, cover_url, cover_path, 
				 file_name, file_path, file_size, has_local_copy, last_updated, 
				 description, genres, rating, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played)
				VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', %d, %d, '%s', '%s', '%s', %f, '%s', %d, %d, '%s', %d, '%s')
			""" % [
				_escape_sql(game.id),
				game.romm_id,
				_escape_sql(game.title),
				_escape_sql(game.platform),
				_escape_sql(game.platform_slug),
				_escape_sql(game.cover_url),
				_escape_sql(game.cover_path),
				_escape_sql(game.file_name),
				_escape_sql(game.file_path),
				game.file_size,
				1 if game.has_local_copy else 0,
				_escape_sql(game.last_updated),
				_escape_sql(game.description),
				_escape_sql(",".join(game.genres)),
				game.rating,
				_escape_sql(JSON.stringify(game.siblings)),
				game.selected_sibling_id,
				1 if game.is_master_entry else 0,
				_escape_sql(JSON.stringify(game.downloaded_sibling_ids)),
				1 if game.has_cover_art else 0,
				_escape_sql(game.last_played)
			]
			return _db.query(query),
		func(success: bool):
			if success:
				# Use batch notification during sync, individual during normal operations
				# Only notify for games with cover art (games without covers are hidden)
				# Only notify for master entries (sibling ROMs are hidden from library view)
				if _sync_batch_mode:
					if game.has_cover_art and game.is_master_entry:
						_queue_batch_notification(game)
				else:
					game_added.emit(game)
			if callback.is_valid():
				callback.call(success)
	)
	return true

func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
	MemoryManager.queue_db_task(
		func():
			var query = """
				UPDATE games SET
					title = '%s',
					platform = '%s',
					platform_slug = '%s',
					cover_url = '%s',
					cover_path = '%s',
					file_name = '%s',
					file_path = '%s',
					file_size = %d,
					has_local_copy = %d,
					last_updated = '%s',
					description = '%s',
					genres = '%s',
					rating = %f,
					siblings = '%s',
					selected_sibling_id = %d,
					is_master_entry = %d,
					downloaded_sibling_ids = '%s',
					has_cover_art = %d,
					last_played = '%s'
				WHERE romm_id = %d
			""" % [
				_escape_sql(game.title),
				_escape_sql(game.platform),
				_escape_sql(game.platform_slug),
				_escape_sql(game.cover_url),
				_escape_sql(game.cover_path),
				_escape_sql(game.file_name),
				_escape_sql(game.file_path),
				game.file_size,
				1 if game.has_local_copy else 0,
				_escape_sql(game.last_updated),
				_escape_sql(game.description),
				_escape_sql(",".join(game.genres)),
				game.rating,
				_escape_sql(JSON.stringify(game.siblings)),
				game.selected_sibling_id,
				1 if game.is_master_entry else 0,
				_escape_sql(JSON.stringify(game.downloaded_sibling_ids)),
				1 if game.has_cover_art else 0,
				_escape_sql(game.last_played),
				game.romm_id
			]
			return _db.query(query),
		func(success: bool):
			if success:
				game_updated.emit(game)
			if callback.is_valid():
				callback.call(success)
	)
	return true

func delete_game_download(game: GameResource, callback: Callable = Callable()) -> bool:
	"""Delete a downloaded game file and update the database."""
	if not _is_db_ready or not game:
		push_error("[DataManager] Cannot delete: DB not ready or game is null")
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Get the file path to delete - construct it from components (like launch_manager does)
	var active_id = game.get_active_game_id()
	var active_file_name = ""
	
	if active_id == game.romm_id:
		active_file_name = game.file_name
	else:
		# Get sibling file name
		for sibling in game.siblings:
			if sibling.get("id", 0) == active_id:
				active_file_name = sibling.get("file_name", "")
				break
	
	if active_file_name == "":
		push_error("[DataManager] Cannot delete: empty file name")
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Construct the full path (same as launch_manager.gd line 1162)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	var root_path = root_folder.value if root_folder else "user://games"
	var abs_path = root_path + "/" + game.platform_slug + "/" + active_file_name
	
	print("[DataManager] Deleting file at constructed path: " + abs_path)
	
	# Check if file exists
	if not FileAccess.file_exists(abs_path):
		push_error("[DataManager] File does not exist: " + abs_path)
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Attempt to delete the file
	var file_deleted = false
	var error_msg = ""
	
	# Method 1: Try using DirAccess with the parent directory
	var parent_dir = abs_path.get_base_dir()
	var file_name = abs_path.get_file()
	var dir = DirAccess.open(parent_dir)
	
	if dir:
		var err = dir.remove(file_name)
		if err == OK:
			file_deleted = true
			print("[DataManager] Successfully deleted file using DirAccess: " + abs_path)
		else:
			error_msg = "DirAccess.remove failed with error: " + str(err)
	else:
		error_msg = "Failed to open directory: " + parent_dir
	
	# Method 2: If first method failed, try remove_absolute
	if not file_deleted:
		print("[DataManager] Trying remove_absolute for: " + abs_path)
		var err = DirAccess.remove_absolute(abs_path)
		if err == OK:
			file_deleted = true
			print("[DataManager] Successfully deleted file using remove_absolute: " + abs_path)
		else:
			error_msg += " | remove_absolute failed with error: " + str(err)
	
	# If file deletion failed, don't update the database
	if not file_deleted:
		push_error("[DataManager] Failed to delete file: " + abs_path + " | " + error_msg)
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Verify file was actually deleted
	if FileAccess.file_exists(abs_path):
		push_error("[DataManager] File still exists after deletion attempt: " + abs_path)
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Update game state only after successful deletion
	print("[DataManager] Updating game state after successful deletion")
	if active_id == game.romm_id:
		# Main game
		game.has_local_copy = false
		game.file_path = ""
	else:
		# Sibling - remove from downloaded list
		game.downloaded_sibling_ids.erase(active_id)
	
	# Persist to database
	return update_game(game, callback)

func get_game_by_id(romm_id: int) -> GameResource:
	if not _is_db_ready:
		return null
	_db.query("SELECT * FROM games WHERE romm_id = %d" % romm_id)
	if _db.query_result.size() > 0:
		return _row_to_game(_db.query_result[0])
	return null

func get_all_games() -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	_db.query("SELECT * FROM games WHERE is_master_entry = 1 AND has_cover_art = 1 ORDER BY title")
	for row in _db.query_result:
		games.append(_row_to_game(row))
	return games

func get_games_by_platform(platform_slug: String) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	_db.query("SELECT * FROM games WHERE platform_slug = '%s' AND is_master_entry = 1 AND has_cover_art = 1 ORDER BY title" % platform_slug)
	for row in _db.query_result:
		games.append(_row_to_game(row))
	return games

func get_games_paginated(offset: int, limit: int, sort_field: String = "title", ascending: bool = true) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		print("[DataManager] DB not ready for pagination query")
		return games
	
	var order = "ASC" if ascending else "DESC"
	var query = "SELECT * FROM games WHERE is_master_entry = 1 AND has_cover_art = 1 ORDER BY %s %s LIMIT %d OFFSET %d" % [sort_field, order, limit, offset]
	print("[DataManager] Executing query: %s" % query)
	_db.query(query)
	print("[DataManager] Query returned %d rows" % _db.query_result.size())
	
	for row in _db.query_result:
		games.append(_row_to_game(row))
	return games

func get_total_games_count() -> int:
	if not _is_db_ready:
		return 0
	var success = _db.query("SELECT COUNT(*) as count FROM games WHERE is_master_entry = 1 AND has_cover_art = 1")
	if success and _db.query_result.size() > 0:
		var row = _db.query_result[0]
		if row.has("count"):
			return int(row["count"])
	return 0

func get_downloaded_games_count() -> int:
	"""Get count of downloaded games from synced platforms."""
	if not _is_db_ready:
		return 0
	
	var enabled_slugs = _get_enabled_platform_slugs()
	if enabled_slugs.size() == 0:
		return 0
	
	var slug_list = "'" + "','".join(enabled_slugs) + "'"
	var query = """
		SELECT COUNT(*) as count FROM games 
		WHERE is_master_entry = 1 
		AND has_cover_art = 1
		AND platform_slug IN (%s)
		AND (
			has_local_copy = 1 
			OR downloaded_sibling_ids != '[]'
		)
	""" % slug_list
	
	var success = _db.query(query)
	if success and _db.query_result.size() > 0:
		var row = _db.query_result[0]
		if row.has("count"):
			return int(row["count"])
	return 0

func get_downloaded_games_paginated(offset: int, limit: int) -> Array[GameResource]:
	"""Get downloaded games from synced platforms, sorted by most recently played."""
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	
	var enabled_slugs = _get_enabled_platform_slugs()
	if enabled_slugs.size() == 0:
		return games
	
	var slug_list = "'" + "','".join(enabled_slugs) + "'"
	var query = """
		SELECT * FROM games 
		WHERE is_master_entry = 1 
		AND has_cover_art = 1
		AND platform_slug IN (%s)
		AND (
			has_local_copy = 1 
			OR downloaded_sibling_ids != '[]'
		)
		ORDER BY last_played DESC, title ASC
		LIMIT %d OFFSET %d
	""" % [slug_list, limit, offset]
	
	_db.query(query)
	for row in _db.query_result:
		games.append(_row_to_game(row))
	return games

func _get_enabled_platform_slugs() -> Array[String]:
	"""Get list of platform slugs that are currently enabled for sync."""
	var slugs: Array[String] = []
	var enabled = _get_enabled_platforms()
	for platform in enabled:
		slugs.append(platform.slug)
	return slugs

func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	"""Update the last_played timestamp for a game."""
	if not _is_db_ready:
		return false
	
	var query = """
		UPDATE games SET last_played = '%s'
		WHERE romm_id = %d
	""" % [_escape_sql(timestamp), romm_id]
	
	return _db.query(query)

func _row_to_game(row: Dictionary) -> GameResource:
	var game = GameResource.new()
	game.id = row.get("id", "")
	game.romm_id = row.get("romm_id", 0)
	game.title = row.get("title", "")
	game.platform = row.get("platform", "")
	game.platform_slug = row.get("platform_slug", "")
	game.cover_url = row.get("cover_url", "")
	game.cover_path = row.get("cover_path", "")
	game.file_name = row.get("file_name", "")
	game.file_path = row.get("file_path", "")
	game.file_size = row.get("file_size", 0)
	game.has_local_copy = row.get("has_local_copy", 0) == 1
	game.last_updated = row.get("last_updated", "")
	game.description = row.get("description", "")
	var genres: Array[String] = []
	if row.get("genres") and row.get("genres") != "":
		for g in row["genres"].split(","):
			genres.append(g)
	game.genres = genres
	game.rating = row["rating"]
	
	# Restore sibling data
	if row.has("siblings") and row["siblings"] != "":
		var json = JSON.new()
		var err = json.parse(row["siblings"])
		if err == OK and json.data is Array:
			var siblings: Array[Dictionary] = []
			for item in json.data:
				if item is Dictionary:
					siblings.append(item)
			game.siblings = siblings
			if siblings.size() > 0:
				print("[DataManager] Loaded %d siblings for game '%s' from DB" % [siblings.size(), game.title])
		else:
			game.siblings = []
	else:
		game.siblings = []
	
	if row.has("selected_sibling_id"):
		game.selected_sibling_id = row["selected_sibling_id"]
	else:
		game.selected_sibling_id = 0
	
	if row.has("is_master_entry"):
		game.is_master_entry = row["is_master_entry"] == 1
	else:
		game.is_master_entry = true
	
	# Restore has_cover_art flag
	if row.has("has_cover_art"):
		game.has_cover_art = row["has_cover_art"] == 1
	else:
		game.has_cover_art = true
	
	# Restore downloaded sibling IDs
	if row.has("downloaded_sibling_ids") and row["downloaded_sibling_ids"] != "":
		var json_ids = JSON.new()
		var err_ids = json_ids.parse(row["downloaded_sibling_ids"])
		if err_ids == OK and json_ids.data is Array:
			var downloaded_ids: Array[int] = []
			for item in json_ids.data:
				if item is int or item is float:
					downloaded_ids.append(int(item))
			game.downloaded_sibling_ids = downloaded_ids
		else:
			game.downloaded_sibling_ids = []
	else:
		game.downloaded_sibling_ids = []
	
	# Restore last_played timestamp
	if row.has("last_played"):
		game.last_played = row.get("last_played", "")
	else:
		game.last_played = ""
	
	return game

# ==================== COVER DOWNLOAD ====================

func _download_cover(url: String, callback: Callable):
	var cache_path = get_cached_image_path(url)
	
	# Check if already cached
	if FileAccess.file_exists(cache_path):
		callback.call(true)
		return
	
	# Check if already downloading (deduplication) - thread-safe
	_active_downloads_mutex.lock()
	var should_return = false
	var download_state = null
	
	if _active_downloads.has(url):
		download_state = _active_downloads[url]
		if download_state.completed:
			# Download finished while we were checking - use cached result
			var result = download_state.success
			_active_downloads_mutex.unlock()
			callback.call(result)
			return
		else:
			# Still downloading - queue this callback
			download_state.callbacks.append(callback)
			_active_downloads_mutex.unlock()
			return
	
	# Start new download
	_active_downloads[url] = {
		"callbacks": [callback],
		"completed": false,
		"success": false
	}
	_active_downloads_mutex.unlock()
	
	DownloadManager.download_image(url, cache_path, func(success: bool):
		if not success:
			# Download failed - notify all waiting callbacks
			_active_downloads_mutex.lock()
			if _active_downloads.has(url):
				var state = _active_downloads[url]
				state.completed = true
				state.success = false
				var callbacks = state.callbacks.duplicate()
				_active_downloads_mutex.unlock()
				
				for cb in callbacks:
					cb.call(false)
			else:
				_active_downloads_mutex.unlock()
			return
		
		# Load the cached image
		MemoryManager.queue_image_task(
			func():
				var file = FileAccess.open(cache_path, FileAccess.READ)
				if not file:
					return null
				var buffer = file.get_buffer(file.get_length())
				file.close()
				return _load_texture_from_memory(buffer),
			func(texture: Texture2D):
				var load_success = texture != null
				# Notify all waiting callbacks - thread-safe
				_active_downloads_mutex.lock()
				if _active_downloads.has(url):
					var state = _active_downloads[url]
					state.completed = true
					state.success = load_success
					var callbacks = state.callbacks.duplicate()
					_active_downloads_mutex.unlock()
					
					for cb in callbacks:
						cb.call(load_success)
					
					# Clean up after a short delay to allow any late callbacks
					await get_tree().create_timer(5.0).timeout
					
					_active_downloads_mutex.lock()
					_active_downloads.erase(url)
					_active_downloads_mutex.unlock()
				else:
					_active_downloads_mutex.unlock()
		)
	)

func get_cached_image_path(url: String) -> String:
	return CACHE_FOLDER + url.md5_text() + ".jpg"

func _load_texture_from_memory(buffer: PackedByteArray) -> Texture2D:
	if buffer.size() < 16:
		return null
	
	var image = Image.new()
	var err = FAILED
	
	# Check magic bytes
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		err = image.load_png_from_buffer(buffer)
	else:
		err = image.load_webp_from_buffer(buffer)
	
	if err == OK:
		return ImageTexture.create_from_image(image)
	return null

func load_image(url: String, callback: Callable = Callable()):
	if url == "" or not url.begins_with("http"):
		if callback.is_valid():
			callback.call(null)
		return
	
	var cache_path = get_cached_image_path(url)
	
	# Try cache first - using background thread
	if FileAccess.file_exists(cache_path):
		MemoryManager.queue_image_task(
			func():
				var file = FileAccess.open(cache_path, FileAccess.READ)
				if file:
					var buffer = file.get_buffer(file.get_length())
					file.close()
					return _load_texture_from_memory(buffer)
				return null,
			func(texture):
				if texture:
					if callback.is_valid():
						callback.call(texture)
					image_loaded.emit(url, texture)
				else:
					# Cache file exists but failed to load, try downloading fresh
					_load_image_from_network(url, cache_path, callback)
		)
		return
	
	# Download if not cached
	_load_image_from_network(url, cache_path, callback)

func _load_image_from_network(url: String, cache_path: String, callback: Callable):
	"""Download and load image from network using background thread."""
	_download_cover(url, func(_ok):
		# Check if file was downloaded successfully
		if not FileAccess.file_exists(cache_path):
			if callback.is_valid():
				callback.call(null)
			return
		
		MemoryManager.queue_image_task(
			func():
				var file = FileAccess.open(cache_path, FileAccess.READ)
				if file:
					var buffer = file.get_buffer(file.get_length())
					file.close()
					return _load_texture_from_memory(buffer)
				return null,
			func(texture):
				if callback.is_valid():
					callback.call(texture)
				if texture:
					image_loaded.emit(url, texture)
		)
	)

# ==================== PLATFORMS ====================

func sync_platforms_from_romm(callback: Callable = Callable()):
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(false, "Database not ready")
		return
	
	NetworkManager.fetch_platforms(func(data, error):
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
			add_platform(platform)
			count += 1
		
		sync_completed.emit(true, "Synced " + str(count) + " platforms")
		if callback.is_valid():
			callback.call(true, "")
	)

func add_platform(platform: PlatformResource) -> bool:
	if not _is_db_ready:
		return false
	
	var query = """
		INSERT OR REPLACE INTO platforms 
		(id, romm_id, name, slug, icon_url, icon_path, emulator_path, extensions)
		VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s')
	""" % [
		_escape_sql(platform.id),
		platform.romm_id,
		_escape_sql(platform.name),
		_escape_sql(platform.slug),
		_escape_sql(platform.icon_url),
		_escape_sql(platform.icon_path),
		_escape_sql(platform.emulator_path),
		_escape_sql(",".join(platform.extensions))
	]
	
	return _db.query(query)

func get_all_platforms() -> Array[PlatformResource]:
	var platforms: Array[PlatformResource] = []
	if not _is_db_ready:
		return platforms
	
	_db.query("SELECT * FROM platforms ORDER BY name")
	for row in _db.query_result:
		var platform = PlatformResource.new()
		platform.id = row["id"]
		platform.romm_id = row["romm_id"]
		platform.name = row["name"]
		platform.slug = row["slug"]
		platform.icon_url = row["icon_url"]
		platform.icon_path = row["icon_path"]
		platform.emulator_path = row["emulator_path"]
		var ext_array = row["extensions"].split(",") if row["extensions"] else []
		platform.extensions = Array(ext_array, TYPE_STRING, &"", null)
		platforms.append(platform)
	
	return platforms

func remove_platform_games(platform_slug: String, callback: Callable = Callable()):
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(false)
		return
	
	# Queue all database operations on the DB thread to avoid race conditions
	MemoryManager.queue_db_task(
		func():
			# First, get all games for this platform to delete their covers
			_db.query("SELECT cover_url FROM games WHERE platform_slug = '%s'" % platform_slug)
			var cover_urls: Array[String] = []
			for row in _db.query_result:
				var url = row.get("cover_url", "")
				if url != "":
					cover_urls.append(url)
			
			# Delete games from database and get the count
			var count_before = _db.query_result.size()
			var success = _db.query("DELETE FROM games WHERE platform_slug = '%s'" % platform_slug)
			
			return {
				"success": success,
				"cover_urls": cover_urls,
				"count": count_before
			},
		func(result: Dictionary):
			var success = result.get("success", false)
			var cover_urls = result.get("cover_urls", [])
			var count = result.get("count", 0)
			
			if success:
				# Delete cover cache files on main thread (file system access)
				var covers_deleted = 0
				for url in cover_urls:
					var cache_path = get_cached_image_path(url)
					if FileAccess.file_exists(cache_path):
						DirAccess.remove_absolute(cache_path)
						covers_deleted += 1
				
				print("[DataManager] Removed ", count, " games from ", platform_slug, ", deleted ", covers_deleted, " covers")
				games_removed.emit(platform_slug)
			
			if callback.is_valid():
				callback.call(success)
	)

# ==================== CACHE ====================

func _ensure_cache_folder():
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("cache"):
		dir.make_dir("cache")
	if not dir.dir_exists("cache/covers"):
		dir.make_dir("cache/covers")

func clear_cache():
	var dir = DirAccess.open(CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				dir.remove(file_name)
			file_name = dir.get_next()
	cache_cleared.emit()

func get_cache_size() -> int:
	var total_size = 0
	var dir = DirAccess.open(CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				total_size += dir.get_space_left()
			file_name = dir.get_next()
	return total_size

func get_random_game() -> GameResource:
	"""Get a random game from the database."""
	if not _is_db_ready:
		return null
	
	# Get a random game that has a cover and is a master entry
	_db.query("SELECT * FROM games WHERE is_master_entry = 1 AND has_cover_art = 1 ORDER BY RANDOM() LIMIT 1")
	if _db.query_result.size() > 0:
		return _row_to_game(_db.query_result[0])
	return null

func get_random_cached_cover_path() -> String:
	"""Get a random cover image from the cache folder."""
	var dir = DirAccess.open(CACHE_FOLDER)
	if not dir:
		return ""
	
	var image_files: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and (file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg")):
			image_files.append(CACHE_FOLDER + file_name)
		file_name = dir.get_next()
	
	if image_files.size() > 0:
		return image_files[randi() % image_files.size()]
	return ""

func get_last_sync_time() -> String:
	if not _is_db_ready:
		return ""
	_db.query("SELECT value FROM cache_metadata WHERE key = 'last_sync'")
	if _db.query_result.size() > 0:
		return _db.query_result[0]["value"]
	return ""

func set_last_sync_time(timestamp: String):
	if not _is_db_ready:
		return
	_db.query("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('last_sync', '%s')" % timestamp)

# ==================== DOWNLOADED GAMES SCAN ====================

signal scan_for_downloaded_games_completed(found_count: int)

func scan_for_downloaded_games(callback: Callable = Callable()) -> void:
	"""Scan the games folder for downloaded ROMs and update database entries.
	
	Matches files against database entries by file_name and platform_slug.
	Updates has_local_copy and downloaded_sibling_ids for matched games.
	"""
	if not _is_db_ready:
		print("[DataManager] Cannot scan - database not ready")
		if callback.is_valid():
			callback.call(0)
		return
	
	var root_folder_setting = SettingsManager.get_setting("games_root_folder")
	if not root_folder_setting or root_folder_setting.value == "":
		print("[DataManager] Cannot scan - games_root_folder not set")
		if callback.is_valid():
			callback.call(0)
		return
	
	var root_folder = root_folder_setting.value
	print("[DataManager] Scanning for downloaded games in: " + root_folder)
	
	# Get all games from database to match against
	var all_games = get_all_games()
	if all_games.size() == 0:
		print("[DataManager] No games in database to match against")
		if callback.is_valid():
			callback.call(0)
		return
	
	# Build lookup dictionary: file_name -> game
	var game_lookup: Dictionary = {}
	for game in all_games:
		# Add main game file
		if game.file_name != "":
			var key = game.platform_slug + "/" + game.file_name.to_lower()
			game_lookup[key] = game
		
		# Add sibling files
		for sibling in game.siblings:
			var sibling_file_name = sibling.get("file_name", "")
			if sibling_file_name != "":
				var sibling_key = game.platform_slug + "/" + sibling_file_name.to_lower()
				game_lookup[sibling_key] = game
	
	print("[DataManager] Built lookup with %d game entries" % game_lookup.size())
	
	# Scan filesystem
	var found_files: Array[String] = []
	_scan_games_directory(root_folder, "", found_files)
	
	print("[DataManager] Found %d files in games directory" % found_files.size())
	
	# Match files to games
	var matched_games: Dictionary = {}  # romm_id -> {game, matched_siblings: [], file_path: ""}
	var matched_count: int = 0
	
	for file_path in found_files:
		var parts = file_path.split("/", false, 1)
		if parts.size() < 2:
			continue
		
		var platform_slug = parts[0]
		var file_name = parts[1]
		var lookup_key = platform_slug + "/" + file_name.to_lower()
		
		if game_lookup.has(lookup_key):
			var game = game_lookup[lookup_key]
			
			if not matched_games.has(game.romm_id):
				matched_games[game.romm_id] = {
					"game": game,
					"matched_siblings": [],
					"file_path": ""
				}
			
			var full_file_path = root_folder + "/" + file_path
			
			# Check if it's the main game file or a sibling
			if file_name.to_lower() == game.file_name.to_lower():
				# It's the main game file - update file_path
				matched_games[game.romm_id].file_path = full_file_path
			else:
				# It's a sibling - find the sibling ID
				for sibling in game.siblings:
					var sibling_file = sibling.get("file_name", "")
					if sibling_file.to_lower() == file_name.to_lower():
						var sibling_id = sibling.get("id", 0)
						if sibling_id != 0 and not matched_games[game.romm_id].matched_siblings.has(sibling_id):
							matched_games[game.romm_id].matched_siblings.append(sibling_id)
							break
			
			matched_count += 1
			print("[DataManager] Matched file: %s -> %s" % [file_path, game.title])
	
	print("[DataManager] Matched %d files to %d unique games" % [matched_count, matched_games.size()])
	
	# Update database for matched games
	if matched_games.size() > 0:
		_update_matched_games_in_db(matched_games, callback)
	else:
		if callback.is_valid():
			callback.call(0)

func _scan_games_directory(root_path: String, sub_path: String, results: Array[String]) -> void:
	"""Recursively scan the games directory for ROM files."""
	var full_path = root_path
	if sub_path != "":
		full_path = root_path + "/" + sub_path
	
	var dir = DirAccess.open(full_path)
	if not dir:
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		
		var current_path = sub_path
		if current_path != "":
			current_path += "/"
		current_path += file_name
		
		if dir.current_is_dir():
			# Recurse into subdirectory
			_scan_games_directory(root_path, current_path, results)
		else:
			# It's a file - add to results
			results.append(current_path)
		
		file_name = dir.get_next()

func _update_matched_games_in_db(matched_games: Dictionary, callback: Callable) -> void:
	"""Update database entries for matched games."""
	MemoryManager.queue_db_task(
		func():
			var updated_count: int = 0
			
			for romm_id in matched_games.keys():
				var match_data = matched_games[romm_id]
				var game: GameResource = match_data.game
				var matched_siblings: Array = match_data.matched_siblings
				var new_file_path: String = match_data.file_path
				
				# Update game object
				game.has_local_copy = true
				if new_file_path != "":
					game.file_path = new_file_path
				for sibling_id in matched_siblings:
					if not sibling_id in game.downloaded_sibling_ids:
						game.downloaded_sibling_ids.append(sibling_id)
				
				# Update database
				var downloaded_ids_json = JSON.stringify(game.downloaded_sibling_ids)
				var query = """
					UPDATE games SET
						has_local_copy = 1,
						file_path = '%s',
						downloaded_sibling_ids = '%s'
					WHERE romm_id = %d
				""" % [_escape_sql(new_file_path), _escape_sql(downloaded_ids_json), romm_id]
				
				print("[DataManager] Updating game %d (%s): file_path=%s, has_local_copy=1" % [romm_id, game.title, new_file_path])
				
				if _db.query(query):
					updated_count += 1
					print("[DataManager] Successfully updated game %d" % romm_id)
				else:
					print("[DataManager] FAILED to update game %d" % romm_id)
			
			return updated_count,
		func(updated_count: int):
			print("[DataManager] Updated %d games as downloaded" % updated_count)
			scan_for_downloaded_games_completed.emit(updated_count)
			if callback.is_valid():
				callback.call(updated_count)
	)
