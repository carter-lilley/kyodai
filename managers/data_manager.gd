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
signal sync_started()  # Emitted when a sync begins - allows UI to clear cache

const DB_PATH = "user://database/kyodai.db"
const CACHE_FOLDER = "user://cache/covers/"
const FSM = preload("res://managers/filesystem_manager.gd")

var _db: SQLite = null
var _is_db_ready: bool = false

var _db_mutex: Mutex = Mutex.new()

func _db_lock():
	_db_mutex.lock()

func _db_unlock():
	_db_mutex.unlock()

func _db_query_array(query: String) -> Array:
	_db_lock()
	var success = _db.query(query)
	var result = _db.query_result.duplicate() if success else []
	_db_unlock()
	return result

func _db_query_bool(query: String) -> bool:
	_db_lock()
	var success = _db.query(query)
	_db_unlock()
	return success
var _sync_notification_id: int = -1

# Android sync foreground service tracking
var _sync_fg_service_active: bool = false

# Logging control
var _verbose_sql: bool = false  # Set to true to see SQL queries

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

# NEW: Incremental sync state
var _sync_force_full: bool = false          # Force full sync flag
var _sync_current_updated_after: String = ""  # updated_after timestamp for current platform

# Legacy sync state (for compatibility)
var _sync_current: int = 0
var _sync_total: int = 0
var _sync_platform: String = ""
var _sync_platform_index: int = 0  # Current platform number (1-based)
var _sync_platform_count: int = 0  # Total platforms
var _sync_platform_total: int = 0  # Games in current platform

# NEW: Batch notification system for incremental UI updates
var _sync_batch_mode: bool = false
var _sync_batch_pending: Array[GameResource] = []
var _sync_batch_pending_mutex: Mutex = Mutex.new()  # Thread-safe access
var _sync_batch_timer: Timer = null
var _sync_batch_last_emit_time: int = 0
const BATCH_EMIT_INTERVAL_MS: int = 800  # Emit every 800ms during sync

# Pre-calculation state (avoid closures)
var _precalc_pending: int = 0
var _precalc_total: int = 0
var _precalc_callback: Callable = Callable()
var _precalc_platform_totals: Dictionary = {}  # platform_id -> total count

# Cover download deduplication - tracks in-flight downloads across entire sync
var _active_downloads: Dictionary = {}  # url -> {callbacks: Array[Callable], completed: bool, success: bool}
var _active_downloads_mutex: Mutex = Mutex.new()  # Thread-safe access to _active_downloads

# Cover URLs collected during sync for batch downloading on main thread
var _sync_covers_pending: Array[String] = []
var _sync_covers_mutex: Mutex = Mutex.new()

# Performance tracking for background thread optimization
var _perf_batch_start_time: int = 0
var _perf_phase1_duration: int = 0  # GameResource creation (now on background thread)
var _perf_phase2_duration: int = 0  # Sibling checks
var _perf_phase3_duration: int = 0  # DB inserts
var _perf_total_batches: int = 0

func _ready():
	_ensure_memory_manager()
	_initialize_database()
	_ensure_cache_folder()
	
	# Connect to setting changes for dynamic cover folding
	SettingsManager.setting_changed.connect(_on_setting_changed)

func _ensure_memory_manager():
	if MemoryManager._instance == null:
		var mm = MemoryManager.new()
		add_child(mm)

# ==================== SYNC THREAD SIGNAL WRAPPERS ====================
# These are called via call_deferred from the sync thread to safely emit signals on the main thread

func _emit_sync_started():
	sync_started.emit()

func _emit_sync_progress(percent: float, current: int, total: int):
	sync_progress.emit(percent, current, total)

func _emit_sync_completed(success: bool, message: String):
	sync_completed.emit(success, message)

func _emit_game_added(game: GameResource):
	game_added.emit(game)

func _emit_games_batch_added(platform_slug: String, start_index: int, games: Array[GameResource]):
	games_batch_added.emit(platform_slug, start_index, games)

# Wrapper for calling _sync_final_callback via call_deferred
func _invoke_sync_callback(success: bool, message: String, count: int, error_code: int):
	if _sync_final_callback.is_valid():
		_sync_final_callback.call(success, message, count, error_code)

# ==================== ANDROID SYNC FOREGROUND SERVICE ====================

func _start_sync_fg_service(platform_name: String = "Game Library", current: int = 0, total: int = 0) -> void:
	if not PlatformManager.is_android():
		return
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_warning("[DataManager] PackageChecker plugin not available for sync foreground service")
		return
	
	print("[DataManager] Starting sync foreground service: %s (%d/%d)" % [platform_name, current, total])
	plugin.startSyncForegroundService(platform_name, current, total)
	_sync_fg_service_active = true

func _update_sync_fg_service(platform_name: String = "", current: int = 0, total: int = 0) -> void:
	if not PlatformManager.is_android() or not _sync_fg_service_active:
		return
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		return
	
	# Use current platform name if not provided
	var name = platform_name if platform_name != "" else _sync_platform
	plugin.updateSyncForegroundService(name, current, total)

func _stop_sync_fg_service() -> void:
	if not PlatformManager.is_android() or not _sync_fg_service_active:
		return
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		return
	
	print("[DataManager] Stopping sync foreground service")
	plugin.stopSyncForegroundService()
	_sync_fg_service_active = false

# ==================== SETTINGS CHANGE HANDLER ====================

func _on_setting_changed(value, setting):
	if setting.property_name == "fold_duplicate_covers":
		if value:
			print("[CoverFolding] Setting enabled - applying cover folding...")
			apply_cover_folding_to_database(func(folded_count: int):
				print("[CoverFolding] Applied cover folding to %d games" % folded_count)
				# Trigger grid refresh
				sync_completed.emit(true, "Cover folding enabled - folded %d games" % folded_count)
			)
		else:
			print("[CoverFolding] Setting disabled - removing cover-based siblings...")
			_remove_cover_based_siblings()
	elif setting.property_name == "hide_games_without_covers":
		print("[DataManager] Hide no-cover setting changed to %s" % value)
		# Trigger grid refresh so library view updates filtering
		sync_completed.emit(true, "Hide no-cover games %s" % ("enabled" if value else "disabled"))
	elif setting.property_name == "fold_romm_siblings":
		print("[DataManager] Fold RomM siblings setting changed to %s" % value)
		# Trigger grid refresh so library view updates filtering
		sync_completed.emit(true, "RomM sibling folding %s" % ("enabled" if value else "disabled"))

func _should_hide_no_cover_games() -> bool:
	var setting = SettingsManager.get_setting("hide_games_without_covers")
	if setting:
		return setting.value
	return true

func _should_fold_romm_siblings() -> bool:
	var setting = SettingsManager.get_setting("fold_romm_siblings")
	if setting:
		return setting.value
	return true

func _get_has_cover_art_clause() -> String:
	return " AND has_cover_art = 1" if _should_hide_no_cover_games() else ""

func _get_is_master_entry_clause() -> String:
	return " AND is_master_entry = 1" if _should_fold_romm_siblings() else ""

func _remove_cover_based_siblings():
	"""Unfold all games by setting cover_group_master = 1 for all games in cover groups.
	
	This is the simple inverse of apply_cover_folding_to_database. Since cover_group_id
	is preserved during sync, we just need to set cover_group_master = 1 for all games
	that are in a cover group (cover_group_id != '').
	"""
	if not _is_db_ready:
		return
	
	MemoryManager.queue_db_task(
		func():
			# Simple: set cover_group_master = 1 for all games in any cover group
			var query = "UPDATE games SET cover_group_master = 1 WHERE cover_group_id != ''"
			var success = _db_query_bool(query)
			
			# Get count of affected games
			var count_query = "SELECT changes() as count"
			var unfolded_count = 0
			var query_result = _db_query_array(count_query)
			if success and query_result.size() > 0:
				unfolded_count = query_result[0].get("count", 0)
			
			return unfolded_count,
		func(unfolded_count: int):
			print("[CoverFolding] Unfolded %d games" % unfolded_count)
			# Notify listeners that library needs refresh
			sync_completed.emit(true, "Cover folding disabled - unfolded %d games" % unfolded_count)
	)

func _initialize_database():
	print("[DataManager] _initialize_database() starting...")
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("database"):
		dir.make_dir("database")
	
	_db = SQLite.new()
	_db.path = DB_PATH
	_db.verbosity_level = SQLite.QUIET if not _verbose_sql else SQLite.VERBOSE
	
	if _db.open_db():
		_create_tables()
		_is_db_ready = true
		print("[DataManager] Database ready - emitting signal")
		database_ready.emit()
	else:
		print("[DataManager] ERROR: Failed to open database")

func _create_tables():
	_db_query_bool("""
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
			last_played TEXT DEFAULT '',
			title_id TEXT DEFAULT '',
			cover_group_id TEXT DEFAULT '',
			cover_group_master INTEGER DEFAULT 1
		)
	""")
	
	_db_query_bool("""
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
	
	_db_query_bool("CREATE INDEX IF NOT EXISTS idx_games_platform ON games(platform_slug)")
	_db_query_bool("CREATE INDEX IF NOT EXISTS idx_games_title ON games(title)")
	_db_query_bool("CREATE INDEX IF NOT EXISTS idx_games_cover_group ON games(cover_group_id)")
	
	# Create cache_metadata table for per-platform sync timestamps
	_db_query_bool("""
		CREATE TABLE IF NOT EXISTS cache_metadata (
			key TEXT PRIMARY KEY,
			value TEXT
		)
	""")
	
	# Create save_sync table for tracking save file sync state
	_db_query_bool("""
		CREATE TABLE IF NOT EXISTS save_sync (
			id INTEGER PRIMARY KEY,
			romm_id INTEGER NOT NULL,
			emulator_id TEXT NOT NULL,
			file_name TEXT NOT NULL,
			file_path TEXT NOT NULL,
			last_synced_at TEXT DEFAULT '',
			remote_save_id INTEGER DEFAULT 0,
			slot TEXT
		)
	""")
	_db_query_bool("CREATE INDEX IF NOT EXISTS idx_save_sync_romm_emulator ON save_sync(romm_id, emulator_id)")
	
	# Migrate old cover_folded column to new cover_group system if needed
	_migrate_cover_folding_schema()

func _migrate_cover_folding_schema():
	"""Migrate from old cover_folded column to new cover_group system.
	
	This handles databases created before the cover_group system was implemented.
	It converts cover_folded=1 games to have a cover_group_id and cover_group_master=0.
	"""
	# Check if old cover_folded column exists
	var check_query = "PRAGMA table_info(games)"
	var query_result = _db_query_array(check_query)
	if query_result.is_empty():
		return
	var has_cover_folded = false
	var has_cover_group_id = false
	var has_cover_group_master = false
	
	for row in query_result:
		var col_name = row.get("name", "")
		if col_name == "cover_folded":
			has_cover_folded = true
		elif col_name == "cover_group_id":
			has_cover_group_id = true
		elif col_name == "cover_group_master":
			has_cover_group_master = true
	
	# If we have new columns but not old, migration already done
	if has_cover_group_id and has_cover_group_master and not has_cover_folded:
		return
	
	# If we have old column but not new ones, migrate
	if has_cover_folded and not has_cover_group_id:
		print("[DataManager] Migrating cover folding schema...")
		
		# Add new columns
		_db_query_bool("ALTER TABLE games ADD COLUMN cover_group_id TEXT DEFAULT ''")
		_db_query_bool("ALTER TABLE games ADD COLUMN cover_group_master INTEGER DEFAULT 1")
		
		# Migrate data: games with cover_folded=1 get a cover_group_id based on their cover_url
		var query = """
			SELECT romm_id, cover_url, cover_folded 
			FROM games 
			WHERE cover_folded = 1 AND cover_url != '' AND cover_url IS NOT NULL
		"""
		if _db_query_bool(query):
			# Group by cover_url
			var cover_groups: Dictionary = {}
			for row in query_result:
				var cover_url = row.get("cover_url", "")
				var romm_id = row.get("romm_id", 0)
				if cover_url != "" and romm_id != 0:
					if not cover_groups.has(cover_url):
						cover_groups[cover_url] = []
					cover_groups[cover_url].append(romm_id)
			
			# For each group, set cover_group_id and determine master
			for cover_url in cover_groups.keys():
				var ids = cover_groups[cover_url]
				if ids.size() < 2:
					continue
				
				var group_id = cover_url.md5_text()
				var lowest_id = ids.min()
				
				for game_id in ids:
					var is_master = 1 if game_id == lowest_id else 0
					var update = """
						UPDATE games 
						SET cover_group_id = '%s', cover_group_master = %d
						WHERE romm_id = %d
					""" % [group_id, is_master, game_id]
					_db_query_bool(update)
		
		print("[DataManager] Cover folding schema migration complete")
	
	# Drop old column if it exists (optional - can keep for backwards compatibility)
	# _db.query("ALTER TABLE games DROP COLUMN cover_folded")

func is_database_ready() -> bool:
	return _is_db_ready

func _escape_sql(text: String) -> String:
	return text.replace("'", "''")

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
		NotificationManager.dismiss_notification(_sync_notification_id)
		_sync_notification_id = -1
	
	if not _is_db_ready:
		print("[Sync] ERROR: Database not ready")
		if callback.is_valid():
			callback.call(false, "Database not ready", 0, 0)
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
	
	var enabled = _get_enabled_platforms()
	print("[Sync] Enabled platforms: %d" % enabled.size())
	
	# Get all platforms that currently have games in the database
	var db_platforms = _get_db_platform_slugs()
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
	MemoryManager.queue_sync_task(
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
		for i in range(disabled_platforms.size()):
			var slug = disabled_platforms[i]
			print("[SyncThread] Removing platform %d/%d: %s" % [i + 1, disabled_platforms.size(), slug])
			_remove_platform_sync_threaded(slug)
			# Small yield to prevent blocking other sync thread tasks
			OS.delay_usec(1000)
	
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
	
	# Start foreground service and notification immediately
	call_deferred("_start_sync_fg_service", "Game Library", 0, 0)
	call_deferred("_show_sync_notification")
	
	# Pre-calculate totals in background without blocking
	# Fire off all pre-calc requests but don't wait for them
	var platform_totals_discovered = 0
	for platform in enabled_platforms:
		var platform_id = str(platform.id)
		var result = NetworkManager.fetch_games_sync(platform_id, 0, 1)
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
		if platform_id == 0 and _is_db_ready:
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
				var last_sync_time = Time.get_unix_time_from_datetime_string(last_sync)
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
		while not platform_complete and _sync_state != SyncState.ERROR:
			var batch_size = 250 if not PlatformManager.is_android() else 150
			
			# Fetch batch
			var fetch_start = Time.get_ticks_msec()
			var result = NetworkManager.fetch_games_sync(str(platform_id), _sync_current_offset, batch_size, _sync_current_updated_after)
			var fetch_time = Time.get_ticks_msec() - fetch_start
			
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
			
			# Process batch
			_sync_state = SyncState.PLATFORM_PROCESSING
			var batch_start = Time.get_ticks_msec()
			var succeeded = _process_batch_sync(items, platform.slug)
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
			
			if _sync_current_synced >= _sync_current_total:
				var current_time = Time.get_datetime_string_from_system(true)
				_set_last_sync_time_sync(platform.slug, current_time)
				platform_complete = true
			else:
				_sync_current_offset += batch_size
				_sync_state = SyncState.PLATFORM_BATCHING
				OS.delay_usec(10000)  # 10ms yield to prevent blocking and reduce CPU
		
		print("[SyncThread] Platform '%s' complete (%d batches, %d/%d games)" % [platform.name, platform_batch_count, _sync_current_synced, _sync_current_total])
		
		# Dispatch any remaining covers for this platform
		_dispatch_covers_to_main_thread()
	
	# 7. Complete sync - defer ALL UI work to main thread
	print("[SyncThread] All platforms complete, finishing...")
	_sync_state = SyncState.COMPLETING
	
	# Get cache stats before clearing
	var cache_stats = NetworkManager.get_and_reset_cache_stats()
	var games_from_cache = cache_stats.get("games_from_cache", 0)
	
	print("[SyncThread] Sync complete: %d games synced, %d from cache" % [_sync_total_synced, games_from_cache])
	
	# Dispatch any remaining covers before completing
	_dispatch_covers_to_main_thread()
	
	# Defer the entire completion sequence to main thread
	# This avoids calling scene-tree methods from the sync thread
	call_deferred("_complete_sync_on_main_thread", _sync_total_synced, games_from_cache)

func _complete_sync_on_main_thread(total_synced: int, games_from_cache: int):
	"""Complete sync on main thread - safe for UI operations."""
	print("[Sync] Completing on main thread...")
	
	# Flush any remaining batch notifications
	_flush_batch_notifications()
	
	# Clean up
	_stop_sync_batch_mode()
	_stop_sync_fg_service()
	_active_downloads.clear()
	
	# Apply cover folding and emit completion
	apply_cover_folding_to_database(func(folded_count: int):
		var completion_msg = "Synced " + str(total_synced) + " games"
		if games_from_cache > 0:
			completion_msg += " (" + str(games_from_cache) + " checked from cache"
			if folded_count > 0:
				completion_msg += ", " + str(folded_count) + " folded by cover"
			completion_msg += ")"
		elif folded_count > 0:
			completion_msg += " (" + str(folded_count) + " folded by cover)"
		
		_sync_state = SyncState.IDLE
		sync_completed.emit(true, completion_msg)
		_invoke_sync_callback(true, completion_msg, total_synced, 0)
	)

func _remove_platform_sync_threaded(platform_slug: String) -> bool:
	"""Synchronous platform removal for sync thread."""
	var state = {"success": false, "completed": false}
	
	remove_platform_games(platform_slug, func(result):
		state.success = result
		state.completed = true
	)
	
	var timeout = 0
	while not state.completed:
		OS.delay_usec(10000)  # 10ms sleep
		timeout += 1
		if timeout > 6000:  # 60 seconds
			print("[SyncThread] ERROR: Timeout removing platform %s" % platform_slug)
			return false
	
	return state.success

func _lookup_platform_id_sync(platform_slug: String) -> int:
	"""Lookup platform ID from DB - must be called on sync thread with care."""
	if not _is_db_ready:
		return 0
	var query_result = _db_query_array("SELECT romm_id FROM platforms WHERE slug = '%s'" % _escape_sql(platform_slug))
	if query_result.size() > 0:
		return query_result[0].get("romm_id", 0)
	return 0

func _get_last_sync_time_sync(platform_slug: String) -> String:
	"""Get last sync time - thread-safe version."""
	if not _is_db_ready:
		return ""
	var query_result = _db_query_array("SELECT value FROM cache_metadata WHERE key = 'last_sync_%s'" % _escape_sql(platform_slug))
	if query_result.size() > 0:
		return query_result[0].get("value", "")
	return ""

func _set_last_sync_time_sync(platform_slug: String, timestamp: String):
	"""Set last sync time - thread-safe version."""
	if not _is_db_ready:
		return
	_db_query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('last_sync_%s', '%s')" % [_escape_sql(platform_slug), timestamp])

func _precalculate_totals_sync(platforms: Array) -> int:
	"""Pre-calculate total games for all platforms - sync thread version."""
	_precalc_platform_totals.clear()
	var grand_total = 0
	
	for platform in platforms:
		var platform_id = str(platform.id)
		var fetch_start = Time.get_ticks_msec()
		var result = NetworkManager.fetch_games_sync(platform_id, 0, 1)
		var fetch_time = Time.get_ticks_msec() - fetch_start
		if result.success and result.data is Dictionary:
			var platform_total = int(result.data.get("total", 0))
			grand_total += platform_total
			_precalc_platform_totals[platform_id] = platform_total
			print("[SyncThread] Pre-calc: %s = %d games (%dms)" % [platform.name, platform_total, fetch_time])
		else:
			print("[SyncThread] Pre-calc: %s = FAILED (%dms) - %s" % [platform.name, fetch_time, result.error])
		OS.delay_usec(1000)
	
	return grand_total

func _process_batch_sync(items: Array, platform_slug: String) -> int:
	"""Process a batch of games on the sync thread.
	
	Phases:
	1. Create GameResources (sync thread CPU work)
	2. Sibling checks + DB inserts (single combined DB task per batch)
	3. Collect cover URLs and dispatch to main thread for async download
	"""
	if items.is_empty():
		return 0
	
	var batch_start = Time.get_ticks_msec()
	
	# Phase 1: Create GameResources
	var games: Array[GameResource] = []
	for item in items:
		var game = _create_game_from_data(item, platform_slug, false)
		if game != null:
			games.append(game)
	
	if games.is_empty():
		return 0
	
	# Phase 2: Sibling checks + DB inserts in ONE combined DB task
	var db_start = Time.get_ticks_msec()
	var inserted = _check_and_insert_games_sync(games)
	var db_time = Time.get_ticks_msec() - db_start
	
	# Phase 3: Collect cover URLs for async download on main thread
	var cover_start = Time.get_ticks_msec()
	var cover_count = 0
	for game in games:
		if game.has_cover_art and game.cover_url != "" and game.cover_url.begins_with("http"):
			var cache_path = get_cached_image_path(game.cover_url)
			if not FileAccess.file_exists(cache_path):
				_sync_covers_mutex.lock()
				_sync_covers_pending.append(game.cover_url)
				var pending_count = _sync_covers_pending.size()
				_sync_covers_mutex.unlock()
				cover_count += 1
				# Dispatch covers to main thread every 50 collected
				if pending_count >= 50:
					_dispatch_covers_to_main_thread()
	var cover_time = Time.get_ticks_msec() - cover_start
	
	var total_time = Time.get_ticks_msec() - batch_start
	if total_time > 100:
		print("[SyncThread] Batch: %d games -> %d inserted, %d covers queued (DB: %dms, covers: %dms, total: %dms)" % [games.size(), inserted, cover_count, db_time, cover_time, total_time])
	
	return inserted

func _dispatch_covers_to_main_thread():
	"""Dispatch collected cover URLs to main thread for async download."""
	_sync_covers_mutex.lock()
	if _sync_covers_pending.is_empty():
		_sync_covers_mutex.unlock()
		return
	
	var urls = _sync_covers_pending.duplicate()
	_sync_covers_pending.clear()
	_sync_covers_mutex.unlock()
	
	print("[SyncThread] Dispatching %d covers to main thread" % urls.size())
	call_deferred("_download_covers_on_main_thread", urls)

func _download_covers_on_main_thread(urls: Array[String]):
	"""Download covers on main thread using existing async infrastructure.
	
	Called via call_deferred from sync thread. Queues each cover to
	DownloadManager for parallel async download.
	"""
	var queued = 0
	var already_cached = 0
	
	for url in urls:
		var cache_path = get_cached_image_path(url)
		if FileAccess.file_exists(cache_path):
			already_cached += 1
			continue
		
		# Use existing async download path
		_download_cover(url, func(_ok): pass)
		queued += 1
	
	if queued > 0:
		print("[Covers] Queued %d covers for async download (%d already cached)" % [queued, already_cached])

func _check_and_insert_games_sync(games: Array[GameResource]) -> int:
	"""Check siblings and insert games in a single DB task.
	
	This combines what used to be two separate DB tasks (sibling check + insert)
	into one, halving the DB queue pressure.
	"""
	if games.is_empty() or not _is_db_ready:
		return 0
	
	var state = {"success": false, "inserted": 0, "completed": false}
	
	MemoryManager.queue_db_task(
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
			state.success = success
			state.inserted = games.size() if success else 0
			state.completed = true
	)
	
	# Poll with longer delay to reduce CPU usage (10ms instead of 1ms)
	var timeout = 0
	while not state.completed:
		OS.delay_usec(10000)  # 10ms sleep
		timeout += 1
		if timeout > 12000:  # 120 second timeout (12000 * 10ms)
			print("[SyncThread] ERROR: Timeout waiting for DB check+insert (%d games)" % games.size())
			break
	
	if state.success:
		# During sync, we skip individual game_added signals to avoid FPS crawl
		# The library view will refresh when sync_completed is emitted
		# Only emit if NOT in batch mode (i.e., individual additions outside sync)
		if not _sync_batch_mode:
			for game in games:
				if game.is_master_entry:
					call_deferred("_emit_game_added", game)
		return state.inserted
	else:
		print("[SyncThread] ERROR: DB check+insert failed for %d games" % games.size())
		return 0

func _show_sync_notification():
	"""Show sync notification on main thread."""
	_sync_notification_id = NotificationManager.show_notification(
		"Syncing...",
		NotificationManager.Type.INFO,
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

func _get_db_platform_slugs() -> Array[String]:
	"""Get list of platform slugs that have games in the database"""
	var slugs: Array[String] = []
	if not _is_db_ready:
		return slugs
	
	var query_result = _db_query_array("SELECT DISTINCT platform_slug FROM games ORDER BY platform_slug")
	for row in query_result:
		var slug = row.get("platform_slug", "")
		if slug != "":
			slugs.append(slug)
	
	return slugs

func _get_enabled_platforms() -> Array:
	var result = []
	var setting = SettingsManager.get_setting("enabled_platforms")
	if not setting or not setting.value is Dictionary:
		return result
	
	for slug in setting.value.keys():
		var data = setting.value[slug]
		var enabled = false
		var id = 0
		var game_name = slug.capitalize()
		
		if data is bool:
			enabled = data
		elif data is Dictionary:
			enabled = data.get("enabled", false)
			id = data.get("id", 0)
			game_name = data.get("name", slug.capitalize())
		
		if enabled:
			# Include all enabled platforms regardless of ID
			# ID will be looked up during sync if needed
			result.append({"slug": slug, "id": id, "name": game_name})
	
	return result

func _precalculate_totals(platforms: Array, callback: Callable):
	"""Fetch total game count for all platforms upfront using instance vars (no closures)"""
	_precalc_pending = platforms.size()
	_precalc_total = 0
	_precalc_platform_totals.clear()
	_precalc_callback = callback
	
	if _precalc_pending == 0:
		callback.call(0)
		return
	
	for platform in platforms:
		var platform_id = str(platform.id)
		# Fetch just the total count (offset=0, limit=1) - don't cache pre-calc calls
		_fetch_batch(platform_id, 0, 1, false, "", func(data, error):
			if error == "" and data is Dictionary:
				var platform_total = int(data.get("total", 0))
				_precalc_total += platform_total
				_precalc_platform_totals[platform_id] = platform_total
			
			_precalc_pending -= 1
			if _precalc_pending <= 0:
				var cb = _precalc_callback
				_precalc_callback = Callable()
				cb.call(_precalc_total)
		)

func _fetch_batch(platform_id: String, offset: int, limit: int, use_cache: bool, updated_after: String, callback: Callable):
	NetworkManager.fetch_games(callback, platform_id, offset, limit, use_cache, updated_after)

# ==================== BATCH PROCESSING (BACKGROUND THREAD) ====================

func _process_batch(items: Array, platform_slug: String, on_complete: Callable):
	"""Process a batch of games using the MemoryManager batch scheduler.
	
	NEW: Phase 1 (GameResource creation) now runs on background thread to prevent UI lag.
	Phases 2-3 continue to run asynchronously as before.
	"""
	var total = items.size()
	if total == 0:
		on_complete.call(0)
		return
	
	# Performance tracking
	_perf_batch_start_time = Time.get_ticks_msec()
	_perf_total_batches += 1
	
	# NEW: Phase 1 - Create GameResources on BACKGROUND thread (was on main thread)
	# This prevents UI lag when processing large batches
	print("[DataManager] Batch %d: Starting Phase 1 (GameResource creation) on background thread for %d games" % [_perf_total_batches, total])
	
	var game_creation_data: Array[Dictionary] = []
	for i in range(items.size()):
		game_creation_data.append({
			"index": i,
			"data": items[i],
			"platform_slug": platform_slug
		})
	
	# Use DB thread for GameResource creation (CPU-bound work)
	var phase1_start = Time.get_ticks_msec()
	var _phase1_batch_id = MemoryManager.start_batch(
		game_creation_data,
		func(item: Dictionary, _idx: int) -> Dictionary:
			# This runs on BACKGROUND thread
			var game_data = item["data"]
			var slug = item["platform_slug"]
			var game = _create_game_from_data(game_data, slug, false)
			return {
				"game": game,
				"index": item["index"],
				"romm_id": game.romm_id if game else 0,
				"siblings": game.siblings if game else []
			},
		MemoryManager.BatchMode.DB_THREAD,
		20 if not PlatformManager.is_android() else 15,  # Process 20 games per frame (tune based on performance)
		func(processed: int, total_count: int):
			# Progress callback - minimal work, just signal progress
			var percent = float(processed) / float(total_count) * 100.0
			emit_signal("sync_progress", percent * 0.1, processed, total_count),  # Phase 1 is 10% of total progress
		func(phase1_results: Array):
			# Phase 1 complete - track timing
			_perf_phase1_duration = Time.get_ticks_msec() - phase1_start
			print("[DataManager] Batch %d: Phase 1 complete in %dms (%.1fms per game) - now on main thread" % [
				_perf_total_batches, 
				_perf_phase1_duration, 
				float(_perf_phase1_duration) / float(total)
			])
			# Free large transient arrays immediately to help GC on Android
			items.clear()
			game_creation_data.clear()
			# Continue with Phases 2-3
			_process_phase2_sibling_checks(phase1_results, platform_slug, on_complete)
	)

func _process_phase2_sibling_checks(phase1_results: Array, _platform_slug: String, on_complete: Callable):
	"""Phase 2: Batch sibling checks (async, spread across frames).
	
	Called after Phase 1 (GameResource creation) completes on background thread.
	"""
	# Filter out null games and build data structures
	var games: Array[GameResource] = []
	var sibling_check_data: Array[Dictionary] = []
	
	for result in phase1_results:
		if result is Dictionary and result.has("game"):
			var game = result["game"]
			if game != null:
				games.append(game)
				sibling_check_data.append({
					"index": result["index"],
					"romm_id": result["romm_id"],
					"siblings": result["siblings"]
				})
	
	# Clear the large input array to help GC reclaim GameResource references sooner
	phase1_results.clear()
	
	if games.is_empty():
		print("[DataManager] Batch %d: Phase 1 complete, no valid games to process" % _perf_total_batches)
		on_complete.call(0)
		return
	
	print("[DataManager] Batch %d: Starting Phase 2 (sibling checks) for %d games" % [_perf_total_batches, games.size()])
	
	# Phase 2: Batch sibling checks (async, spread across frames)
	var phase2_start = Time.get_ticks_msec()
	var _sibling_batch_id = MemoryManager.start_batch(
		sibling_check_data,
		func(item: Dictionary, _idx: int) -> bool:
			return _check_siblings_in_db(item["romm_id"], item["siblings"]),
		MemoryManager.BatchMode.DB_THREAD,
		15,  # 15 sibling checks per frame
		func(_processed: int, _total_count: int):
			pass,  # Progress tracked in Phase 3
		func(sibling_results: Array):
			# Phase 2 complete - track timing
			_perf_phase2_duration = Time.get_ticks_msec() - phase2_start
			print("[DataManager] Batch %d: Phase 2 complete in %dms" % [_perf_total_batches, _perf_phase2_duration])
			
			# Apply sibling results to games
			for i in range(sibling_results.size()):
				if i < games.size():
					var has_sibling = sibling_results[i]
					games[i].is_master_entry = not has_sibling
			
			# Apply consistent master selection by lowest ID within the batch
			_ensure_consistent_masters_in_batch(games)
			
			# Phase 3: Batch DB inserts (async, spread across frames)
			print("[DataManager] Batch %d: Starting Phase 3 (DB inserts)" % _perf_total_batches)
			_db_insert_batch(games, on_complete)
	)

# ==================== OLD SYNC PROCESSING (DEPRECATED) ====================
# The old _process_batch implementation that ran on main thread is removed.
# All batch processing now uses background threads for Phase 1.

func _insert_games_transaction(games: Array[GameResource]) -> bool:
	"""Insert multiple games within a single database transaction.
	
	This provides 10-50x speedup over individual inserts by reducing
	disk sync operations. All games in the batch succeed or fail together.
	
	Args:
		games: Array of GameResource objects to insert (max 250 recommended)
	
	Returns:
		bool: true if all inserts succeeded, false if transaction rolled back
	"""
	if not _is_db_ready or games.is_empty():
		return false
	_db_lock()
	
	# Start transaction
	var begin_result = _db.query("BEGIN TRANSACTION")
	if not begin_result:
		print("[DataManager] ERROR: Failed to begin transaction")
		_db_unlock()
		return false
	
	var success = true
	var error_count = 0
	
	# Insert all games in this batch
	for game in games:
		if game == null:
			continue
		
		var query = _build_insert_query(game)
		if not _db.query(query):
			success = false
			error_count += 1
			print("[DataManager] ERROR: Failed to insert game '%s' (ID: %d)" % [game.title, game.romm_id])
			# Continue trying to insert others - we'll rollback at the end
	
	# Commit or rollback based on success
	if success:
		var commit_result = _db.query("COMMIT")
		if commit_result:
			_db_unlock()
			return true
		else:
			print("[DataManager] ERROR: Failed to commit transaction")
			_db.query("ROLLBACK")
			_db_unlock()
			return false
	else:
		print("[DataManager] ERROR: Transaction failed with %d errors, rolling back %d games" % [error_count, games.size()])
		_db.query("ROLLBACK")
		_db_unlock()
		return false

func _db_insert_batch(games: Array[GameResource], on_complete: Callable):
	"""Batch insert games into DB using transactions for optimal performance.
	
	Games are inserted in transaction batches of 250 for 10-50x speedup.
	Each transaction batch is processed across frames to maintain UI responsiveness.
	"""
	if games.is_empty():
		on_complete.call(0)
		return
	
	# Phase 3 timing
	var phase3_start = Time.get_ticks_msec()
	
	# Chunk games into transaction-sized batches (smaller on Android to reduce memory pressure)
	var transaction_batch_size: int = 250 if not PlatformManager.is_android() else 150
	var transaction_batches: Array[Array] = []
	var current_batch: Array[GameResource] = []
	
	for game in games:
		current_batch.append(game)
		if current_batch.size() >= transaction_batch_size:
			transaction_batches.append(current_batch.duplicate())
			current_batch.clear()
	
	# Add remaining games
	if current_batch.size() > 0:
		transaction_batches.append(current_batch)
	
	# Track progress across all transaction batches
	var total_games: int = games.size()
	var _processed_games: int = 0
	var games_with_covers: Array[GameResource] = []
	var _games_with_covers_mutex = Mutex.new()
	var had_error: bool = false
	var _error_message: String = ""
	
	print("[DataManager] Batch %d: Inserting %d games in %d transaction batches of max %d" % [_perf_total_batches, total_games, transaction_batches.size(), transaction_batch_size])
	
	# Process each transaction batch
	var db_batches_per_frame: int = 2
	var _batch_id = MemoryManager.start_batch(
		transaction_batches,
		func(batch: Array[GameResource], _idx: int) -> bool:
			if had_error:
				return false
			
			return _insert_games_transaction(batch),
		MemoryManager.BatchMode.DB_THREAD,
		db_batches_per_frame,  # Process transaction batches per frame
		func(completed_batches: int, _total_batches: int):
			# Progress callback - update sync progress
			var completed_games = mini(completed_batches * transaction_batch_size, total_games)
			var percent = float(completed_games) / float(total_games) * 100.0
			emit_signal("sync_progress", percent, completed_games, total_games),
		func(results: Array):
			# Phase 3 complete - track timing
			_perf_phase3_duration = Time.get_ticks_msec() - phase3_start
			
			# Check if any batch failed
			var all_success = true
			for result in results:
				if result == false:
					all_success = false
					break
			
			if not all_success:
				# Transaction failed - this is a critical error
				_stop_sync_fg_service()
				sync_completed.emit(false, "Database transaction failed during sync")
				on_complete.call(0)
				return
			
			# All batches successful - collect games with covers for next phase
			# Queue this work to DB thread to ensure all transactions are truly committed
			# and to avoid race conditions with main thread DB access
			MemoryManager.queue_db_task(
				func():
					# Re-query the database to get the actual inserted games
					# This ensures we're working with committed data
					var inserted_games: Array[GameResource] = []
					for game in games:
						if game.has_cover_art and game.is_master_entry:
							inserted_games.append(game)
					return inserted_games,
				func(inserted_games: Array[GameResource]):
					# Now safe to access covers and notify UI from main thread
					for game in inserted_games:
						games_with_covers.append(game)
						if _sync_batch_mode:
							_queue_batch_notification(game)
						else:
							emit_signal("game_added", game)
					
					# Update sync current count
					_sync_current += games.size()
					
					# Update Android foreground service with current progress
					_update_sync_fg_service(_sync_platform, _sync_current, _sync_total)
					
					# Print performance summary
					var total_batch_time = Time.get_ticks_msec() - _perf_batch_start_time
					print("[DataManager] Batch %d: COMPLETE - Total: %dms | Phase1 (Resource Creation): %dms | Phase2 (Sibling Checks): %dms | Phase3 (DB Inserts): %dms | Games: %d" % [
						_perf_total_batches,
						total_batch_time,
						_perf_phase1_duration,
						_perf_phase2_duration,
						_perf_phase3_duration,
						games.size()
					])
					
					# Phase 4: Batch cover downloads
					_cover_download_batch(games_with_covers, on_complete)
			)
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
		on_complete.call(games.size())
		return
	
	var _completed_count: int = 0
	
	var _cover_batch_id = MemoryManager.start_batch(
		cover_data,
		func(item: Dictionary, _idx: int) -> bool:
			# Queue download via DownloadManager
			var success = false
			_download_cover_sync(item["url"], item["cache_path"])
			return success,
		MemoryManager.BatchMode.SYNC,  # Downloads are already async via DownloadManager
		15,  # 15 covers queued per frame (increased for better performance)
		func(_processed: int, _total_count: int):
			pass,
		func(_results: Array):
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
	"""Check if any sibling (NOT including self) exists in DB - to be run on DB thread."""
	if _db == null:
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
	var id_list = ", ".join(ids_to_check.map(func(id): return str(id)))
	var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % id_list
	
	var query_result = _db_query_array(query)
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
		
		# Get all romm_ids in this cover group
		var cover_group_ids: Array[int] = []
		for idx in indices:
			cover_group_ids.append(games[idx].romm_id)
		
		# For each game in the group, add other games as siblings (if not already)
		for i in range(indices.size()):
			var current_game = games[indices[i]]
			var _current_id = current_game.romm_id
			
			# Build set of existing sibling IDs (romm siblings + any already added)
			var existing_sibling_ids: Dictionary = {}
			for sibling in current_game.siblings:
				existing_sibling_ids[sibling.get("id", 0)] = true
			
			# Add each other game in the cover group as a sibling if not already
			for j in range(indices.size()):
				if i == j:
					continue
				
				var other_game = games[indices[j]]
				var other_id = other_game.romm_id
				
				# Skip if already a sibling (romm sibling takes precedence)
				if existing_sibling_ids.has(other_id):
					continue
				
				# Add as a cover-based sibling
				var sibling_entry = {
					"id": other_id,
					"name": other_game.title,
					"file_name": other_game.file_name,
					"file_size": other_game.file_size
				}
				current_game.siblings.append(sibling_entry)
				existing_sibling_ids[other_id] = true

# ==================== COMPREHENSIVE COVER FOLDING ====================

func apply_cover_folding_to_database(callback: Callable = Callable()):
	"""Apply cover folding globally across all games in the database.
	
	This runs after all syncs complete and groups games with identical covers
	across all batches and platforms. Skips games that are already RomM siblings.
	
	NEW TWO-TIER SYSTEM:
	- Games with identical covers get the same cover_group_id (hash of cover_url)
	- Within each cover group, only the game with the lowest romm_id is visible (cover_group_master = 1)
	- RomM siblings remain untouched (they have their own is_master_entry system)
	"""
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(0)
		return
	
	# Check if cover folding is enabled
	var fold_covers_setting = SettingsManager.get_setting("fold_duplicate_covers")
	if not fold_covers_setting or not fold_covers_setting.value:
		if callback.is_valid():
			callback.call(0)
		return
	
	print("[CoverFolding] Starting global cover folding...")
	
	# Show pulsing notification
	var notification_id = NotificationManager.show_notification(
		"Folding duplicate covers...",
		NotificationManager.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true  # pulsing
	)
	
	MemoryManager.queue_db_task(
		func():
			# Query all games with cover URLs that don't have RomM siblings
			# We exclude games that already have siblings in the RomM system
			var query = """
				SELECT id, romm_id, title, file_name, file_size, cover_url, siblings
				FROM games
				WHERE cover_url != '' AND cover_url IS NOT NULL
			"""
			
			var query_result = _db_query_array(query)
			if query_result.is_empty():
				return 0
			var rows = query_result
			
			# Build cover groups from games WITHOUT RomM siblings
			var cover_groups: Dictionary = {}
			var games_with_romm_siblings: Dictionary = {}
			
			for row in rows:
				var romm_id = row.get("romm_id", 0)
				var cover_url = row.get("cover_url", "")
				var siblings_json = row.get("siblings", "[]")
				
				if cover_url == "" or romm_id == 0:
					continue
				
				# Check if this game has RomM siblings (not just cover siblings)
				var has_romm_siblings = false
				var json = JSON.new()
				var err = json.parse(siblings_json)
				if err == OK and json.data is Array:
					for sibling in json.data:
						if sibling is Dictionary:
							var sibling_id = sibling.get("id", 0)
							# Check if this sibling exists in DB as master (RomM sibling)
							if sibling_id != 0 and sibling_id != romm_id:
								var check_query = "SELECT COUNT(*) as count FROM games WHERE romm_id = %d AND is_master_entry = 1" % sibling_id
								var sibling_result = _db_query_array(check_query)
								if sibling_result.size() > 0:
									if sibling_result[0].get("count", 0) > 0:
										has_romm_siblings = true
										break
				
				if has_romm_siblings:
					# Don't process games with RomM siblings
					games_with_romm_siblings[romm_id] = true
					continue
				
				# Add to cover group
				if not cover_groups.has(cover_url):
					cover_groups[cover_url] = []
				
				cover_groups[cover_url].append({
					"romm_id": romm_id
				})
			
			var groups_processed = 0
			var games_folded = 0
			
			# Process each cover group with 2+ games
			for cover_url in cover_groups.keys():
				var games = cover_groups[cover_url]
				if games.size() < 2:
					continue
				
				groups_processed += 1
				
				# Generate group ID from cover URL hash
				var group_id = cover_url.md5_text()
				
				# Find the lowest romm_id in this group (will be the master)
				var lowest_id = games[0].romm_id
				for game in games:
					if game.romm_id < lowest_id:
						lowest_id = game.romm_id
				
				# Update all games in this group
				for game in games:
					var is_master = 1 if game.romm_id == lowest_id else 0
					
					var update_query = """
						UPDATE games 
						SET cover_group_id = '%s', cover_group_master = %d
						WHERE romm_id = %d
					""" % [group_id, is_master, game.romm_id]
					
					_db_query_bool(update_query)
					
					# Count non-master games as folded
					if game.romm_id != lowest_id:
						games_folded += 1
			
			print("[CoverFolding] Processed %d cover groups, folded %d games" % [groups_processed, games_folded])
			return games_folded,
		func(folded_count: int):
			NotificationManager.dismiss_notification(notification_id)
			
			if folded_count > 0:
				NotificationManager.show_notification(
					"Folded %d duplicate covers" % folded_count,
					NotificationManager.Type.SUCCESS
				)
			
			print("[CoverFolding] Complete - folded %d games" % folded_count)
			if callback.is_valid():
				callback.call(folded_count)
	)

# ==================== BATCH NOTIFICATION SYSTEM ====================

func _start_sync_batch_mode():
	"""Start batching game_added signals for efficient UI updates."""
	_sync_batch_mode = true
	_sync_batch_pending.clear()
	_sync_batch_last_emit_time = Time.get_ticks_msec()
	
	# Notify listeners that sync is starting - allows UI to clear cache before new data arrives
	sync_started.emit()
	
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
	if not _is_db_ready:
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
	var id_list = ", ".join(ids_to_check.map(func(id): return str(id)))
	var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % id_list
	var query_result = _db_query_array(query)
	
	if query_result.size() > 0:
		var count = query_result[0]["count"]
		return count > 0
	
	return false

func _build_insert_query(game: GameResource) -> String:
	"""Build SQL INSERT query for a game - used for batch processing.
	
	PRESERVES existing has_local_copy, downloaded_sibling_ids, and file_path 
	if the game already exists in the database. This prevents downloaded games
	from disappearing after a re-sync."""
	
	# Check if game already exists and preserve download status
	var has_local_copy = 1 if game.has_local_copy else 0
	var downloaded_sibling_ids = _escape_sql(JSON.stringify(game.downloaded_sibling_ids))
	var file_path = _escape_sql(game.file_path)
	
	if _is_db_ready and game.romm_id > 0:
		var check_query = "SELECT has_local_copy, downloaded_sibling_ids, file_path, cover_group_id, cover_group_master FROM games WHERE romm_id = %d" % game.romm_id
		var query_result = _db_query_array(check_query)
		if query_result.size() > 0:
			var existing = query_result[0]
			# Preserve download status from existing record
			if existing.get("has_local_copy", 0) == 1:
				has_local_copy = 1
			# Preserve downloaded siblings
			var existing_siblings = existing.get("downloaded_sibling_ids", "[]")
			if existing_siblings != "[]" and existing_siblings != "":
				downloaded_sibling_ids = _escape_sql(existing_siblings)
			# Preserve file path
			var existing_path = existing.get("file_path", "")
			if existing_path != "":
				file_path = _escape_sql(existing_path)
			# Preserve cover group fields (they're managed separately from sync)
			var existing_cover_group_id = existing.get("cover_group_id", "")
			if existing_cover_group_id != "":
				game.cover_group_id = existing_cover_group_id
				game.cover_group_master = existing.get("cover_group_master", 1) == 1
	
	return """
		INSERT OR REPLACE INTO games 
		(id, romm_id, title, platform, platform_slug, cover_url, cover_path, 
		 file_name, file_path, file_size, has_local_copy, last_updated, 
		 description, genres, rating, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played, title_id, cover_group_id, cover_group_master)
		VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', %d, %d, '%s', '%s', '%s', %f, '%s', %d, %d, '%s', %d, '%s', '%s', '%s', %d)
	""" % [
		_escape_sql(game.id),
		game.romm_id,
		_escape_sql(game.title),
		_escape_sql(game.platform),
		_escape_sql(game.platform_slug),
		_escape_sql(game.cover_url),
		_escape_sql(game.cover_path),
		_escape_sql(game.file_name),
		file_path,
		game.file_size,
		has_local_copy,
		_escape_sql(game.last_updated),
		_escape_sql(game.description),
		_escape_sql(",".join(game.genres)),
		game.rating,
		_escape_sql(JSON.stringify(game.siblings)),
		game.selected_sibling_id,
		1 if game.is_master_entry else 0,
		downloaded_sibling_ids,
		1 if game.has_cover_art else 0,
		_escape_sql(game.last_played),
		_escape_sql(game.title_id),
		_escape_sql(game.cover_group_id),
		1 if game.cover_group_master else 0
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
				 description, genres, rating, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played, title_id, cover_group_id, cover_group_master)
				VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', %d, %d, '%s', '%s', '%s', %f, '%s', %d, %d, '%s', %d, '%s', '%s', '%s', %d)
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
				_escape_sql(game.last_played),
				_escape_sql(game.title_id),
				_escape_sql(game.cover_group_id),
				1 if game.cover_group_master else 0
			]
			return _db_query_bool(query),

		func(success: bool):
			if success:
				# Use batch notification during sync, individual during normal operations
				# Only notify for games with cover art (games without covers are hidden)
				# Only notify for master entries (sibling ROMs are hidden from library view)
				# AND only if it's a cover group master (or not in a cover group)
				if _sync_batch_mode:
					if game.has_cover_art and game.is_master_entry and game.cover_group_master:
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
					last_played = '%s',
					title_id = '%s',
					cover_group_id = '%s',
					cover_group_master = %d
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
				_escape_sql(game.title_id),
				_escape_sql(game.cover_group_id),
				1 if game.cover_group_master else 0,
				game.romm_id
			]
			return _db_query_bool(query),

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
	var root_path = root_folder.value if root_folder else "user://roms/"
	var abs_path = root_path + "/" + game.platform_slug + "/" + active_file_name
	
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
		else:
			error_msg = "DirAccess.remove failed with error: " + str(err)
	else:
		error_msg = "Failed to open directory: " + parent_dir
	
	# Method 2: If first method failed, try remove_absolute
	if not file_deleted:
		var err = DirAccess.remove_absolute(abs_path)
		if err == OK:
			file_deleted = true
		else:
			error_msg += " | remove_absolute failed with error: " + str(err)
	
	# If file deletion failed, don't update the database
	if not file_deleted:
		push_error("[DataManager] Failed to delete file: " + abs_path + " | " + error_msg)
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Verify file was actually deleted
	var file_still_exists = FileAccess.file_exists(abs_path)
	
	if file_still_exists:
		push_error("[DataManager] File still exists after deletion attempt: " + abs_path)
		if callback.is_valid():
			callback.call(false)
		return false
	
	# Update game state only after successful deletion
	if active_id == game.romm_id:
		# Main game
		game.has_local_copy = false
		game.file_path = ""
	else:
		# Sibling - remove from downloaded list
		game.downloaded_sibling_ids.erase(active_id)
	
	# Clean up extracted game files for platforms that extract during launch
	_cleanup_extracted_game_files(game)
	
	# Persist to database
	return update_game(game, callback)


## Cleans up extracted game files when a game is deleted
## Platforms that extract: PS3 (RPCS3), Vita (Vita3K)
func _cleanup_extracted_game_files(game: GameResource) -> void:
	if not game or game.title_id == "":
		return
	
	var title_id = game.title_id
	
	match game.platform_slug:
		"ps3":
			# PS3 games are extracted to emulator directories
			var emulator_dir = _get_emulator_directory("rpcs3")
			if emulator_dir != "":
				# Check both disc and digital locations
				var disc_path = emulator_dir + "/games/" + title_id
				var digital_path = emulator_dir + "/dev_hdd0/game/" + title_id
				
				if FSM.dir_exists(disc_path):
					print("[DataManager] Cleaning up extracted PS3 disc game: " + disc_path)
					FSM.delete_dir_recursive(disc_path)
				
				if FSM.dir_exists(digital_path):
					print("[DataManager] Cleaning up extracted PS3 digital game: " + digital_path)
					FSM.delete_dir_recursive(digital_path)
		
		"psvita":
			# Vita games are extracted to ux0/app/TITLEID
			var emulator_dir = _get_emulator_directory("vita3k")
			if emulator_dir != "":
				var vita_path = emulator_dir + "/ux0/app/" + title_id
				
				if FSM.dir_exists(vita_path):
					print("[DataManager] Cleaning up extracted Vita game: " + vita_path)
					FSM.delete_dir_recursive(vita_path)


## Gets the emulator directory (helper to avoid circular dependency with LaunchManager)
func _get_emulator_directory(emulator_id: String) -> String:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var install_path = LaunchManager.get_emulator_install_path(emulator_id)
	if install_path == "":
		return ""
	
	return install_path.get_base_dir()

## Updates only the title_id field for a game (used by Vita3K during launch)
## This avoids overwriting other fields like file_path and has_local_copy
func update_game_title_id(romm_id: int, title_id: String, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
	MemoryManager.queue_db_task(
		func():
			var query = """
				UPDATE games SET
					title_id = '%s'
				WHERE romm_id = %d
			""" % [_escape_sql(title_id), romm_id]
			return _db_query_bool(query),

		func(success: bool):
			if success:
				pass
			if callback.is_valid():
				callback.call(success)
	)
	return true

## Updates only the siblings field for a game (used to persist sibling title_ids)
func update_game_siblings(romm_id: int, siblings: Array[Dictionary], callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
	MemoryManager.queue_db_task(
		func():
			var query = """
				UPDATE games SET
					siblings = '%s'
				WHERE romm_id = %d
			""" % [_escape_sql(JSON.stringify(siblings)), romm_id]
			return _db_query_bool(query),

		func(success: bool):
			if success:
				pass
			if callback.is_valid():
				callback.call(success)
	)
	return true

func get_game_by_id(romm_id: int) -> GameResource:
	if not _is_db_ready:
		return null
	var query_result = _db_query_array("SELECT * FROM games WHERE romm_id = %d" % romm_id)
	if query_result.size() > 0:
		return _row_to_game(query_result[0])
	return null

func get_all_games() -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var query_result = _db_query_array("SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY title")
	for row in query_result:
		games.append(_row_to_game(row))
	return games

func get_games_by_platform(platform_slug: String) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var query_result = _db_query_array("SELECT * FROM games WHERE platform_slug = '%s'" % platform_slug + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY title")
	for row in query_result:
		games.append(_row_to_game(row))
	return games

func get_games_paginated(offset: int, limit: int, sort_field: String = "title", ascending: bool = true, platform_slug: String = "") -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	
	var order = "ASC" if ascending else "DESC"
	var query: String
	
	if platform_slug.is_empty():
		query = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY %s %s LIMIT %d OFFSET %d" % [sort_field, order, limit, offset]
	else:
		query = "SELECT * FROM games WHERE platform_slug = '%s'" % platform_slug + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY %s %s LIMIT %d OFFSET %d" % [sort_field, order, limit, offset]
	
	var query_result = _db_query_array(query)
	
	for row in query_result:
		games.append(_row_to_game(row))
	return games

func get_platforms_with_games() -> Array[Dictionary]:
	"""Get list of platforms that have games, sorted alphabetically with game counts."""
	var platforms: Array[Dictionary] = []
	if not _is_db_ready:
		return platforms
	
	# Query for platforms with their game counts, sorted alphabetically
	var cover_clause = _get_has_cover_art_clause().replace("has_cover_art", "g.has_cover_art")
	var master_clause = _get_is_master_entry_clause().replace("is_master_entry", "g.is_master_entry")
	var query = "SELECT g.platform_slug, p.name, COUNT(*) as game_count FROM games g LEFT JOIN platforms p ON g.platform_slug = p.slug WHERE 1=1" + master_clause + cover_clause + " AND g.cover_group_master = 1 GROUP BY g.platform_slug HAVING game_count > 0 ORDER BY g.platform_slug ASC"
	
	var query_result = _db_query_array(query)
	for row in query_result:
		var slug = row.get("platform_slug", "")
		var game_name = row.get("name", "")
		var _count = int(row.get("game_count", 0))
		
		# Fallback to capitalized slug if no name in platforms table
		if game_name == null or game_name == "":
			game_name = slug.capitalize()
		
		platforms.append({
			"slug": slug,
			"name": game_name,
			"count": _count
		})

	return platforms

func get_total_games_count(platform_slug: String = "") -> int:
	if not _is_db_ready:
		return 0
	
	var query: String
	if platform_slug.is_empty():
		query = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1"
	else:
		query = "SELECT COUNT(*) as count FROM games WHERE platform_slug = '%s'" % platform_slug + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1"
	
	var query_result = _db_query_array(query)
	if query_result.size() > 0:
		var result = query_result
		if result != null and result.size() > 0:
			var row = result[0]
			if row != null and row.has("count"):
				return int(row["count"])
	return 0

func search_games_paginated(query: String, offset: int, limit: int) -> Array[GameResource]:
	"""Search games by title with pagination."""
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	
	# Sanitize query to prevent SQL injection
	var sanitized_query = query.replace("'", "''")
	
	var sql = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND title LIKE '%%%s%%' ORDER BY title ASC LIMIT %d OFFSET %d" % [sanitized_query, limit, offset]
	
	var query_result = _db_query_array(sql)
	for row in query_result:
		games.append(_row_to_game(row))

	return games

func get_search_results_count(query: String) -> int:
	"""Get count of search results."""
	if not _is_db_ready:
		return 0
	
	# Sanitize query to prevent SQL injection
	var sanitized_query = query.replace("'", "''")
	
	var sql = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND title LIKE '%%%s%%'" % sanitized_query
	
	var query_result = _db_query_array(sql)
	if query_result.size() > 0:
		var row = query_result[0]
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
	var query = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND platform_slug IN (%s) AND (has_local_copy = 1 OR downloaded_sibling_ids != '[]')" % slug_list
	
	var query_result = _db_query_array(query)
	if query_result.size() > 0:
		var row = query_result[0]
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
	var query = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND platform_slug IN (%s) AND (has_local_copy = 1 OR downloaded_sibling_ids != '[]') ORDER BY last_played DESC, title ASC LIMIT %d OFFSET %d" % [slug_list, limit, offset]
	
	var query_result = _db_query_array(query)
	for row in query_result:
		games.append(_row_to_game(row))
	return games

func _get_enabled_platform_slugs() -> Array[String]:
	"""Get list of platform slugs that are currently enabled for sync."""
	var slugs: Array[String] = []
	var enabled = _get_enabled_platforms()
	for platform in enabled:
		slugs.append(platform.slug)
	
	# Android/fallback: if no platforms are enabled in settings but we have games in the DB,
	# return all distinct platform slugs from the database so home view isn't empty.
	if slugs.size() == 0 and _is_db_ready:
		var db_slugs = _get_db_platform_slugs()
		if db_slugs.size() > 0:
			print("[DataManager] enabled_platforms is empty; falling back to %d platform(s) found in database" % db_slugs.size())
			return db_slugs
	return slugs

func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	"""Update the last_played timestamp for a game."""
	if not _is_db_ready:
		return false
	
	var query = """
		UPDATE games SET last_played = '%s'
		WHERE romm_id = %d
	""" % [_escape_sql(timestamp), romm_id]
	
	return _db_query_bool(query)

func get_romm_device_id() -> String:
	"""Get the registered RomM device ID."""
	if not _is_db_ready:
		return ""
	var query_result = _db_query_array("SELECT value FROM cache_metadata WHERE key = 'romm_device_id'")
	if query_result.size() > 0:
		return query_result[0].get("value", "")
	return ""

func set_romm_device_id(device_id: String) -> void:
	"""Store the registered RomM device ID."""
	if not _is_db_ready:
		return
	_db_query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('romm_device_id', '%s')" % device_id)

func clear_romm_device_id() -> void:
	"""Clear the stored RomM device ID (e.g. if server no longer recognizes it)."""
	if not _is_db_ready:
		return
	_db_query_bool("DELETE FROM cache_metadata WHERE key = 'romm_device_id'")

func get_save_sync_records(romm_id: int, emulator_id: String = "") -> Array[Dictionary]:
	"""Get save sync records for a game. Optionally filter by emulator."""
	if not _is_db_ready:
		return []
	var query = "SELECT * FROM save_sync WHERE romm_id = %d" % romm_id
	if emulator_id != "":
		query += " AND emulator_id = '%s'" % _escape_sql(emulator_id)
	var query_result = _db_query_array(query)
	return query_result.duplicate()

func update_save_sync_record(romm_id: int, emulator_id: String, file_name: String, file_path: String, last_synced_at: String, remote_save_id: int, slot: String = "") -> bool:
	"""Insert or update a save sync record."""
	if not _is_db_ready:
		return false
	
	var delete_query = "DELETE FROM save_sync WHERE romm_id = %d AND emulator_id = '%s' AND file_name = '%s'" % [romm_id, _escape_sql(emulator_id), _escape_sql(file_name)]
	if slot != "":
		delete_query += " AND slot = '%s'" % _escape_sql(slot)
	else:
		delete_query += " AND (slot IS NULL OR slot = '')"
	_db_query_bool(delete_query)
	
	var insert_query = """
		INSERT INTO save_sync (romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, slot)
		VALUES (%d, '%s', '%s', '%s', '%s', %d, %s)
	""" % [romm_id, _escape_sql(emulator_id), _escape_sql(file_name), _escape_sql(file_path), _escape_sql(last_synced_at), remote_save_id, ("'%s'" % _escape_sql(slot)) if slot != "" else "NULL"]
	return _db_query_bool(insert_query)

func delete_save_sync_record(romm_id: int, emulator_id: String, file_name: String, slot: String = "") -> bool:
	"""Delete a save sync record."""
	if not _is_db_ready:
		return false
	var query = "DELETE FROM save_sync WHERE romm_id = %d AND emulator_id = '%s' AND file_name = '%s'" % [romm_id, _escape_sql(emulator_id), _escape_sql(file_name)]
	if slot != "":
		query += " AND slot = '%s'" % _escape_sql(slot)
	else:
		query += " AND (slot IS NULL OR slot = '')"
	return _db_query_bool(query)

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
	game.rating = row.get("rating", "")
	
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
		else:
			game.siblings = [] as Array[Dictionary]
	else:
		game.siblings = [] as Array[Dictionary]
	
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
			game.downloaded_sibling_ids = [] as Array[int]
	else:
		game.downloaded_sibling_ids = [] as Array[int]
	
	# Restore last_played timestamp
	game.last_played = row.get("last_played", "")
	
	# Restore title_id
	game.title_id = row.get("title_id", "")
	
	# Restore cover group fields
	if row.has("cover_group_id"):
		game.cover_group_id = row.get("cover_group_id", "")
	else:
		game.cover_group_id = ""
	
	if row.has("cover_group_master"):
		game.cover_group_master = row.get("cover_group_master", 1) == 1
	else:
		game.cover_group_master = true
	
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
	var _should_return = false
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
				return _load_image_from_memory(buffer, cache_path),
			func(image):
				var load_success = image != null
				# During sync, skip creating ImageTexture to avoid GPU memory pressure.
				# The texture will be created on-demand when the game card is displayed.
				if load_success and not _sync_batch_mode:
					var texture = ImageTexture.create_from_image(image)
					load_success = texture != null
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
	# Extract extension from URL, default to jpg if not found
	var extension = "jpg"
	var query_start = url.find("?")
	var url_without_query = url
	if query_start != -1:
		url_without_query = url.substr(0, query_start)
	
	var last_dot = url_without_query.rfind(".")
	if last_dot != -1 and last_dot < url_without_query.length() - 1:
		var ext = url_without_query.substr(last_dot + 1).to_lower()
		if ext in ["jpg", "jpeg", "png", "webp"]:
			extension = ext
			if extension == "jpeg":
				extension = "jpg"
	
	return CACHE_FOLDER + url.md5_text() + "." + extension

func _load_image_from_memory(buffer: PackedByteArray, _cache_path: String = "") -> Image:
	if buffer.size() < 16:
		return null
	
	var err = FAILED
	var image = Image.new()
	
	# Always use magic bytes to detect actual format, regardless of file extension
	# This handles cases where the extension doesn't match the actual content
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		# JPEG magic bytes
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		# PNG magic bytes (0x89 0x50 0x4E 0x47)
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49:
		# WebP magic bytes (RIFF header)
		err = image.load_webp_from_buffer(buffer)
	else:
		# Try all formats as fallback
		err = image.load_jpg_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_png_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_webp_from_buffer(buffer)
	
	if err == OK:
		return image
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
					return _load_image_from_memory(buffer, cache_path)
				return null,
			func(image):
				if image:
					var texture = ImageTexture.create_from_image(image)
					if texture:
						if callback.is_valid():
							callback.call(texture)
						image_loaded.emit(url, texture)
					else:
						# Cache file exists but failed to load, try downloading fresh
						_load_image_from_network(url, cache_path, callback)
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
					return _load_image_from_memory(buffer, cache_path)
				return null,
			func(image):
				if image:
					var texture = ImageTexture.create_from_image(image)
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
	
	return _db_query_bool(query)

func get_all_platforms() -> Array[PlatformResource]:
	var platforms: Array[PlatformResource] = []
	if not _is_db_ready:
		return platforms
	
	var query_result = _db_query_array("SELECT * FROM platforms ORDER BY name")
	for row in query_result:
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
	print("[Sync] remove_platform_games called for: %s" % platform_slug)
	if not _is_db_ready:
		print("[Sync] ERROR: Database not ready in remove_platform_games")
		if callback.is_valid():
			callback.call(false)
		return
	
	print("[Sync] Queueing DB task for platform removal...")
	# Queue all database operations on the DB thread to avoid race conditions
	MemoryManager.queue_db_task(
		func():
			print("[Sync] DB task executing for %s" % platform_slug)
			_db_lock()
			# First, get all games for this platform to delete their covers
			var query_result = _db_query_array("SELECT cover_url FROM games WHERE platform_slug = '%s'" % platform_slug)
			var cover_urls: Array[String] = []
			for row in query_result:
				var url = row.get("cover_url", "")
				if url != "":
					cover_urls.append(url)
			
			print("[Sync] Found %d games to remove for %s" % [query_result.size(), platform_slug])
			
			# Delete games from database and get the count
			var count_before = query_result.size()
			var success = _db.query("DELETE FROM games WHERE platform_slug = '%s'" % platform_slug)
			
			print("[Sync] DB delete result: %s" % success)
			
			_db_unlock()
			return {
				"success": success,
				"cover_urls": cover_urls,
				"count": count_before
			},
		func(result: Dictionary):
			print("[Sync] remove_platform_games callback executing")
			var success = result.get("success", false)
			var cover_urls = result.get("cover_urls", [])
			var _count = result.get("count", 0)
			
			if success:
				# Delete cover cache files on main thread (file system access)
				var covers_deleted = 0
				for url in cover_urls:
					var cache_path = get_cached_image_path(url)
					if FileAccess.file_exists(cache_path):
						DirAccess.remove_absolute(cache_path)
						covers_deleted += 1
				print("[Sync] Deleted %d/%d cover files for %s" % [covers_deleted, cover_urls.size(), platform_slug])
			else:
				print("[Sync] Removal failed for %s, not deleting covers" % platform_slug)
			
			print("[Sync] Emitting games_removed signal for %s" % platform_slug)
			games_removed.emit(platform_slug)
			
			print("[Sync] remove_platform_games callback valid: %s" % callback.is_valid())
			if callback.is_valid():
				print("[Sync] Calling callback with success=%s" % success)
				callback.call(success)
			else:
				print("[Sync] WARNING: Callback is not valid in remove_platform_games!")
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
	var query_result = _db_query_array("SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY RANDOM() LIMIT 1")
	if query_result.size() > 0:
		return _row_to_game(query_result[0])
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
		if not dir.current_is_dir() and (file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg") or file_name.ends_with(".webp")):
			image_files.append(CACHE_FOLDER + file_name)
		file_name = dir.get_next()
	
	if image_files.size() > 0:
		return image_files[randi() % image_files.size()]
	return ""

func get_last_sync_time(platform_slug: String = "") -> String:
	if not _is_db_ready:
		return ""
	var key = "last_sync_" + platform_slug if platform_slug != "" else "last_sync"
	var query_result = _db_query_array("SELECT value FROM cache_metadata WHERE key = '%s'" % key)
	if query_result.size() > 0:
		return query_result[0]["value"]
	return ""

func set_last_sync_time(platform_slug: String, timestamp: String):
	if not _is_db_ready:
		return
	var key = "last_sync_" + platform_slug if platform_slug != "" else "last_sync"
	_db_query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('%s', '%s')" % [key, timestamp])

# ==================== DOWNLOADED GAMES SCAN ====================

signal scan_for_downloaded_games_completed(found_count: int)

func scan_for_downloaded_games(callback: Callable = Callable()) -> void:
	"""Scan the games folder for downloaded ROMs and update database entries.
	
	Matches files against database entries by file_name and platform_slug.
	Updates has_local_copy and downloaded_sibling_ids for matched games.
	"""
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(0)
		return
	
	var root_folder_setting = SettingsManager.get_setting("games_root_folder")
	if not root_folder_setting or root_folder_setting.value == "":
		if callback.is_valid():
			callback.call(0)
		return
	
	var root_folder = root_folder_setting.value
	
	# Get all games from database to match against
	var all_games = get_all_games()
	if all_games.size() == 0:
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
	
	# Scan filesystem
	var found_files: Array[String] = []
	_scan_games_directory(root_folder, "", found_files)
	
	# Match files to games
	var matched_games: Dictionary = {}  # romm_id -> {game, matched_siblings: [], file_path: ""}
	var _matched_count: int = 0
	
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
			
			_matched_count += 1
	
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
	print("[DEBUG] _update_matched_games_in_db called with %d matched games" % matched_games.size())
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
				
				if _db_query_bool(query):
					updated_count += 1

			return updated_count,
		func(updated_count: int):
			print("[DEBUG] Scan complete - updated %d games in DB" % updated_count)
			scan_for_downloaded_games_completed.emit(updated_count)
			if callback.is_valid():
				callback.call(updated_count)
	)

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
