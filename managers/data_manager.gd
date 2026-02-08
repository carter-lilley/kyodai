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

const DB_PATH = "user://database/kyodai.db"
const CACHE_FOLDER = "user://cache/covers/"

var _db: SQLite = null
var _is_db_ready: bool = false
var _loading_images: Dictionary = {}
var _current_sync_progress: float = 0.0
var _current_sync_total: int = 0
var _sync_notification_id: int = -1

# Cumulative sync tracking across all platforms
var _cumulative_sync_total: int = 0
var _cumulative_sync_current: int = 0
var _current_platform_name: String = ""

# Thread operation tracking - counts pending DB and image operations
var _pending_db_operations: int = 0
var _pending_image_operations: int = 0
var _batch_completion_callback: Callable = Callable()

func _ready():
	# Initialize ThreadManager first
	_ensure_thread_manager()
	
	_initialize_database()
	_ensure_cache_folder()

func _ensure_thread_manager():
	if ThreadManager._instance == null:
		print("[DataManager] Creating ThreadManager instance")
		var tm = ThreadManager.new()
		add_child(tm)
		print("[DataManager] ThreadManager instance created and added")
	else:
		print("[DataManager] ThreadManager already exists")

# ==================== DATABASE INITIALIZATION ====================

func _initialize_database():
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("database"):
		dir.make_dir("database")
	
	_db = SQLite.new()
	_db.path = DB_PATH
	_db.verbosity_level = SQLite.VERBOSE
	
	var success = _db.open_db()
	if not success:
		push_error("Failed to open database")
		return
	
	_create_tables()
	_is_db_ready = true
	database_ready.emit()

func _create_tables():
	# Games table
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
			rating REAL DEFAULT 0.0
		)
	""")
	
	# Platforms table
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
	
	# Cache metadata table
	_db.query("""
		CREATE TABLE IF NOT EXISTS cache_metadata (
			key TEXT PRIMARY KEY,
			value TEXT
		)
	""")
	
	# Create indexes
	_db.query("CREATE INDEX IF NOT EXISTS idx_games_platform ON games(platform_slug)")
	_db.query("CREATE INDEX IF NOT EXISTS idx_games_title ON games(title)")
	_db.query("CREATE INDEX IF NOT EXISTS idx_games_local ON games(has_local_copy)")

func is_database_ready() -> bool:
	return _is_db_ready

# ==================== GAME CRUD OPERATIONS ====================

func _escape_sql(text: String) -> String:
	# Escape single quotes by doubling them (SQL standard)
	return text.replace("'", "''")

func add_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
	print("[DataManager] Queuing add_game for: ", game.title, " | Thread: ", OS.get_thread_caller_id())
	_pending_db_operations += 1
	print("[DataManager] Pending DB operations: ", _pending_db_operations)
	
	ThreadManager.queue_db_task(
		func():
			var query = """
				INSERT OR REPLACE INTO games 
				(id, romm_id, title, platform, platform_slug, cover_url, cover_path, 
				 file_name, file_path, file_size, has_local_copy, last_updated, 
				 description, genres, rating)
				VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', %d, %d, '%s', '%s', '%s', %f)
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
				game.rating
			]
			return _db.query(query),
		func(success: bool):
			_pending_db_operations -= 1
			print("[DataManager] DB operation complete. Pending: ", _pending_db_operations)
			if success:
				game_added.emit(game)
			if callback.is_valid():
				callback.call(success)
			_check_batch_completion()
	)
	return true

func _check_batch_completion():
	"""Check if all pending operations are complete and call the batch completion callback"""
	if _pending_db_operations == 0 and _pending_image_operations == 0:
		print("[DataManager] All thread operations complete")
		if _batch_completion_callback.is_valid():
			var callback = _batch_completion_callback
			_batch_completion_callback = Callable()  # Clear it
			callback.call()

func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
	_pending_db_operations += 1
	print("[DataManager] update_game queued. Pending DB operations: ", _pending_db_operations)
	
	ThreadManager.queue_db_task(
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
					rating = %f
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
				game.romm_id
			]
			return _db.query(query),
		func(success: bool):
			_pending_db_operations -= 1
			print("[DataManager] update_game complete. Pending DB operations: ", _pending_db_operations)
			if success:
				game_updated.emit(game)
			if callback.is_valid():
				callback.call(success)
			_check_batch_completion()
	)
	return true

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
	
	_db.query("SELECT * FROM games ORDER BY title")
	for row in _db.query_result:
		games.append(_row_to_game(row))
	
	return games

func get_games_by_platform(platform_slug: String) -> Array[GameResource]:
	var games: Array[GameResource] = []
	
	if not _is_db_ready:
		return games
	
	_db.query("SELECT * FROM games WHERE platform_slug = '%s' ORDER BY title" % platform_slug)
	for row in _db.query_result:
		games.append(_row_to_game(row))
	
	return games

func search_games(query: String) -> Array[GameResource]:
	var games: Array[GameResource] = []
	
	if not _is_db_ready:
		return games
	
	var search_term = "%%" + query + "%%"
	_db.query("SELECT * FROM games WHERE title LIKE '%s' ORDER BY title" % search_term)
	for row in _db.query_result:
		games.append(_row_to_game(row))
	
	return games

func _row_to_game(row: Dictionary) -> GameResource:
	var game = GameResource.new()
	game.id = row["id"]
	game.romm_id = row["romm_id"]
	game.title = row["title"]
	game.platform = row["platform"]
	game.platform_slug = row["platform_slug"]
	game.cover_url = row["cover_url"]
	game.cover_path = row["cover_path"]
	game.file_name = row["file_name"]
	game.file_path = row["file_path"]
	game.file_size = row["file_size"]
	game.has_local_copy = row["has_local_copy"] == 1
	game.last_updated = row["last_updated"]
	game.description = row["description"]
	var genres_array: Array[String] = []
	if row["genres"] and row["genres"] != "":
		for genre in row["genres"].split(","):
			genres_array.append(genre)
	game.genres = genres_array
	game.rating = row["rating"]
	return game

# ==================== PLATFORM OPERATIONS ====================

func sync_platforms_from_romm(callback: Callable = Callable()) -> void:
	if not _is_db_ready:
		push_error("[DataManager] Database not ready for sync")
		if callback.is_valid():
			callback.call(false, "Database not ready")
		return
	
	print("[DataManager] Starting platform sync from RomM...")
	NetworkManager.fetch_platforms(func(data, error):
		if error != "":
			push_error("[DataManager] Failed to fetch platforms: " + error)
			if callback.is_valid():
				callback.call(false, error)
			return
		
		if not data is Array:
			push_error("[DataManager] Unexpected platform data format")
			if callback.is_valid():
				callback.call(false, "Invalid data format")
			return
		
		print("[DataManager] Received ", data.size(), " platforms from RomM")
		var success_count = 0
		var fail_count = 0
		
		for platform_data in data:
			var platform = PlatformResource.new()
			platform.id = str(platform_data.get("id", ""))
			platform.romm_id = platform_data.get("id", 0)
			platform.name = platform_data.get("name", "")
			platform.slug = platform_data.get("slug", "")
			platform.icon_url = platform_data.get("url_logo", "")
			platform.icon_path = ""
			platform.emulator_path = ""
			platform.extensions = Array([], TYPE_STRING, &"", null)
			
			if add_platform(platform):
				success_count += 1
			else:
				fail_count += 1
		
		print("[DataManager] Platform sync complete - Success: ", success_count, " Failed: ", fail_count)
		
		# Update last sync time
		set_last_sync_time(Time.get_datetime_string_from_system())
		
		sync_completed.emit(true, "Synced " + str(success_count) + " platforms")
		if callback.is_valid():
			callback.call(true, "")
	)

func test_sync_single_game(game_id: int, callback: Callable = Callable()) -> void:
	if not _is_db_ready:
		push_error("[DataManager] Database not ready for sync")
		if callback.is_valid():
			callback.call(false, "Database not ready")
		return
	
	print("[DataManager] Starting single game sync for ID: ", game_id)
	NetworkManager.fetch_game_details(game_id, func(data, error):
		if error != "":
			push_error("[DataManager] Failed to fetch game: " + error)
			if callback.is_valid():
				callback.call(false, error)
			return
		
		if not data is Dictionary:
			push_error("[DataManager] Unexpected game data format")
			if callback.is_valid():
				callback.call(false, "Invalid data format")
			return
		
		print("[DataManager] Received game data for ID: ", game_id)
		
		var game = GameResource.new()
		game.id = str(data.get("id", ""))
		game.romm_id = data.get("id", 0)
		game.title = data.get("name", "") if data.get("name") != null else ""
		game.platform = data.get("platform_display_name", "") if data.get("platform_display_name") != null else ""
		game.platform_slug = data.get("platform_slug", "") if data.get("platform_slug") != null else ""
		game.cover_url = data.get("url_cover", "") if data.get("url_cover") != null else ""
		game.cover_path = data.get("path_cover_large", "") if data.get("path_cover_large") != null else ""
		game.file_name = data.get("fs_name", "") if data.get("fs_name") != null else ""
		game.file_path = data.get("full_path", "") if data.get("full_path") != null else ""
		game.file_size = data.get("fs_size_bytes", 0)
		game.has_local_copy = false  # Always false initially - must download first
		var updated = data.get("updated_at", "")
		game.last_updated = updated if updated != null else ""
		var summary = data.get("summary", "")
		game.description = summary if summary != null else ""
		
		var genres_array: Array[String] = []
		if data.has("metadatum") and data["metadatum"] != null and data["metadatum"] is Dictionary:
			if data["metadatum"].has("genres") and data["metadatum"]["genres"] != null and data["metadatum"]["genres"] is Array:
				for genre in data["metadatum"]["genres"]:
					if genre is String:
						genres_array.append(genre)
		game.genres = genres_array
		
		var rating = 0.0
		if data.has("metadatum") and data["metadatum"] != null and data["metadatum"] is Dictionary:
			var avg_rating = data["metadatum"].get("average_rating", 0.0)
			rating = avg_rating if avg_rating != null else 0.0
		game.rating = rating
		
		print("[DataManager] Saving game: ", game.title, " (", game.platform, ")")
		
		add_game(game, func(success: bool):
			if success:
				print("[DataManager] Game synced successfully")
				sync_completed.emit(true, "Synced game: " + game.title)
				if callback.is_valid():
					callback.call(true, "")
			else:
				push_error("[DataManager] Failed to save game")
				if callback.is_valid():
					callback.call(false, "Failed to save game")
		)
	)

func sync_enabled_platforms(callback: Callable = Callable()) -> void:
	if not _is_db_ready:
		push_error("[DataManager] Database not ready for sync")
		if callback.is_valid():
			callback.call(false, "Database not ready", 0, 0)
		return
	
	# Reset sync tracking
	_current_sync_progress = 0.0
	_current_sync_total = 0
	_cumulative_sync_total = 0
	_cumulative_sync_current = 0
	_current_platform_name = ""
	
	var enabled_platforms = _get_enabled_platforms_setting()
	
	print("[DataManager] Starting sync for enabled platforms")
	print("[DataManager] Enabled platforms from settings: ", enabled_platforms)
	
	# Get list of enabled platform IDs from settings
	var platforms_to_sync: Array = []  # Array of {slug, id, name} dictionaries
	for slug in enabled_platforms.keys():
		var platform_data = enabled_platforms.get(slug)
		var is_enabled = false
		var platform_id = 0
		var platform_name = slug.capitalize()
		
		if platform_data is bool:
			is_enabled = platform_data
		elif platform_data is Dictionary:
			is_enabled = platform_data.get("enabled", false)
			platform_id = platform_data.get("id", 0)
			platform_name = platform_data.get("name", slug.capitalize())
		
		print("[DataManager] Platform ", slug, " enabled: ", is_enabled, " id: ", platform_id)
		if is_enabled and platform_id > 0:
			platforms_to_sync.append({"slug": slug, "id": platform_id, "name": platform_name})
	
	print("[DataManager] Platforms to sync: ", platforms_to_sync.map(func(p): return p.slug))
	
	# Get list of enabled slugs for filtering
	var enabled_slugs = platforms_to_sync.map(func(p): return p.slug)
	
	# Get all platform slugs that have games in the database
	var db_platform_slugs = _get_game_platform_slugs()
	print("[DataManager] Platform slugs with games in DB: ", db_platform_slugs)
	
	# Remove games from disabled platforms (platforms with games in DB but not enabled)
	# Collect platforms to remove
	var platforms_to_remove: Array[String] = []
	for platform_slug in db_platform_slugs:
		if not platform_slug in enabled_slugs:
			platforms_to_remove.append(platform_slug)
	
	if platforms_to_remove.size() > 0:
		print("[DataManager] Removing games from ", platforms_to_remove.size(), " disabled platforms")
		_remove_disabled_platforms(platforms_to_remove, platforms_to_sync, callback)
	else:
		# No platforms to remove, proceed directly to sync
		_proceed_with_sync(platforms_to_sync, callback)

func _remove_disabled_platforms(platforms: Array[String], platforms_to_sync: Array, final_callback: Callable):
	"""Remove games from disabled platforms sequentially, then proceed with sync"""
	_remove_next_disabled_platform(platforms, 0, platforms_to_sync, final_callback)

func _remove_next_disabled_platform(platforms: Array[String], index: int, platforms_to_sync: Array, final_callback: Callable):
	if index >= platforms.size():
		# All disabled platforms removed, proceed with sync
		_proceed_with_sync(platforms_to_sync, final_callback)
		return
	
	var platform_slug = platforms[index]
	print("[DataManager] Removing games from disabled platform: ", platform_slug)
	
	remove_platform_games(platform_slug, func(success: bool):
		# Continue with next platform regardless of success
		_remove_next_disabled_platform(platforms, index + 1, platforms_to_sync, final_callback)
	)

func _proceed_with_sync(platforms_to_sync: Array, callback: Callable):
	"""Proceed with sync after disabled platforms have been removed"""
	if platforms_to_sync.size() == 0:
		print("[DataManager] No platforms enabled for sync")
		# Complete immediately with 0/0 progress
		_current_sync_progress = 100.0
		_update_sync_notification_text(0, 0)
		_finish_sync(0, 0, callback)
		return
	
	# Start sync immediately - we'll count as we go
	_cumulative_sync_total = 0  # Will be updated as we fetch batches
	_cumulative_sync_current = 0
	
	# Create the notification
	_sync_notification_id = NotificationManager.show_notification(
		"Syncing games...",
		Notification.Type.INFO,
		null,
		0.0,
		func() -> float: 
			if _cumulative_sync_total == 0:
				return 0.0
			return float(_cumulative_sync_current) / float(_cumulative_sync_total)
	)
	
	# Start syncing platforms
	_sync_platforms_sequential(platforms_to_sync, 0, 0, 0, callback)

func _sync_platforms_sequential(platforms: Array, index: int, total_synced: int, total_games: int, callback: Callable):
	if index >= platforms.size():
		print("[DataManager] All platforms synced - Total: ", total_synced)
		print("[DataManager] Final pending operations - DB: ", _pending_db_operations, ", Images: ", _pending_image_operations)
		
		# Ensure all thread operations are complete before declaring sync done
		_batch_completion_callback = func():
			print("[DataManager] All thread operations complete. Sync finished.")
			set_last_sync_time(Time.get_datetime_string_from_system())
			_current_sync_progress = 100.0
			_update_sync_notification_text(_cumulative_sync_current, _cumulative_sync_total)
			sync_completed.emit(true, "Synced " + str(total_synced) + " games")
			if callback.is_valid():
				callback.call(true, "", total_synced, total_games)
			
			# All done - sync complete (covers downloaded inline with games)
			_sync_notification_id = -1
		
		# Check if we can complete immediately
		_check_batch_completion()
		return
	
	var platform_info = platforms[index]
	var platform_id = platform_info.id
	var platform_slug = platform_info.slug
	var platform_name = platform_info.get("name", platform_slug.capitalize())
	_current_platform_name = platform_name
	
	print("[DataManager] Syncing platform: ", platform_slug, " (ID: ", platform_id, ")")
	
	# Update notification to show current platform
	_update_sync_notification_text(_cumulative_sync_current, _cumulative_sync_total)
	
	sync_platform_games(platform_id, platform_slug, platform_name, func(success: bool, message: String, synced: int, games: int):
		if success:
			total_synced += synced
			total_games += games
		
		# Wait for all thread operations to complete before moving to next platform
		print("[DataManager] Platform ", platform_slug, " complete. Waiting for thread operations...")
		_batch_completion_callback = func():
			print("[DataManager] All thread operations complete for platform ", platform_slug, ". Moving to next platform.")
			_sync_platforms_sequential(platforms, index + 1, total_synced, total_games, callback)
		
		_check_batch_completion()
	)

func _get_game_platform_slugs() -> Array[String]:
	var slugs: Array[String] = []
	if not _is_db_ready:
		return slugs
	
	# Query distinct platform_slugs from games table
	_db.query("SELECT DISTINCT platform_slug FROM games")
	for row in _db.query_result:
		var slug = row.get("platform_slug", "")
		if slug != "":
			slugs.append(slug)
	
	return slugs

func remove_platform_games(platform_slug: String, callback: Callable = Callable()):
	if not _is_db_ready:
		if callback.is_valid():
			callback.call(false)
		return
	
	print("[DataManager] Removing all games for platform: ", platform_slug)
	
	_pending_db_operations += 1
	print("[DataManager] remove_platform_games queued. Pending DB operations: ", _pending_db_operations)
	
	ThreadManager.queue_db_task(
		func():
			return _db.query("DELETE FROM games WHERE platform_slug = '%s'" % platform_slug),
		func(success: bool):
			_pending_db_operations -= 1
			print("[DataManager] remove_platform_games complete. Pending DB operations: ", _pending_db_operations)
			print("[DataManager] Removed games for platform: ", platform_slug, " success: ", success)
			
			if success:
				# Notify listeners that games were removed
				games_removed.emit(platform_slug)
			
			if callback.is_valid():
				callback.call(success)
			_check_batch_completion()
	)

func _get_enabled_platforms_setting() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

func sync_platform_games(platform_id: int, platform_slug: String, platform_name: String = "", callback: Callable = Callable()) -> void:
	if not _is_db_ready:
		push_error("[DataManager] Database not ready for sync")
		if callback.is_valid():
			callback.call(false, "Database not ready", 0, 0)
		return
	
	print("[DataManager] Starting batch game sync for platform: ", platform_slug, " (ID: ", platform_id, ")")
	
	var batch_size = 15  # Reduced from 100 to prevent UI flooding
	var offset = 0
	var total_games = 0
	
	# First fetch to get total count - use platform_id for API
	var platform_id_str = str(platform_id)
	_fetch_batch(platform_id_str, offset, batch_size, func(first_batch_data, first_batch_error):
		if first_batch_error != "":
			push_error("[DataManager] Failed to fetch first batch: " + first_batch_error)
			if callback.is_valid():
				callback.call(false, first_batch_error, 0, 0)
			return
		
		if not first_batch_data is Dictionary or not first_batch_data.has("items"):
			push_error("[DataManager] Unexpected response format")
			if callback.is_valid():
				callback.call(false, "Invalid response format", 0, 0)
			return
		
		total_games = first_batch_data.get("total", 0)
		print("[DataManager] Total games to sync: ", total_games)
		
		if total_games == 0:
			print("[DataManager] No games found for platform: ", platform_slug)
			if callback.is_valid():
				callback.call(true, "", 0, 0)
			return
		
		# Process first batch asynchronously
		var first_batch_items = first_batch_data.get("items", [])
		_cumulative_sync_total += total_games  # Accumulate across platforms
		
		# Reset pending operation counters for this batch
		_pending_db_operations = 0
		_pending_image_operations = 0
		
		_process_batch_async(first_batch_items, platform_slug, func(batch_count: int):
			var first_batch_total = batch_count
			
			# Set the completion callback - it will be called when all thread operations finish
			_batch_completion_callback = func():
				print("[DataManager] All thread operations complete for first batch")
				
				# If we got all games in first batch, we're done
				if first_batch_total >= total_games:
					print("[DataManager] Platform sync complete - Total synced: ", first_batch_total)
					if callback.is_valid():
						callback.call(true, "", first_batch_total, total_games)
					return
				
				# Continue fetching remaining batches
				var next_offset = batch_size
				_fetch_remaining_batches(platform_id_str, platform_slug, platform_name, next_offset, batch_size, total_games, first_batch_total, callback)
			
			# Don't check immediately - let the operations start first
			# _check_batch_completion() will be called when operations complete
		)
	)

func _fetch_batch(platform_id: String, offset: int, limit: int, callback: Callable):
	print("[DataManager] Fetching batch for platform_id: ", platform_id, " offset: ", offset, " limit: ", limit)
	NetworkManager.fetch_games(func(data, error):
		if error == "" and data is Dictionary:
			var total = data.get("total", 0)
			print("[DataManager] Fetched batch with total: ", total, " items")
		callback.call(data, error)
	, platform_id, offset, limit)

func _fetch_remaining_batches(platform_id: String, platform_slug: String, platform_name: String, offset: int, batch_size: int, total_games: int, total_synced: int, callback: Callable):
	print("[DataManager] Fetching batch at offset: ", offset, ", total_synced so far: ", total_synced, ", cumulative: ", _cumulative_sync_current)
	_fetch_batch(platform_id, offset, batch_size, func(batch_data, batch_error):
		if batch_error != "":
			push_error("[DataManager] Batch fetch error at offset " + str(offset) + ": " + batch_error)
			_finish_sync(total_synced, total_games, callback)
			return
		
		if not batch_data is Dictionary or not batch_data.has("items"):
			push_error("[DataManager] Invalid batch data at offset " + str(offset))
			_finish_sync(total_synced, total_games, callback)
			return
		
		var items = batch_data.get("items", [])
		print("[DataManager] Fetched ", items.size(), " items at offset ", offset)
		
		_process_batch_async(items, platform_slug, func(batch_count: int):
			var new_total = total_synced + batch_count
			
			# Progress is now tracked incrementally via game_fully_processed signal
			print("[DataManager] Batch processor reports complete: ", batch_count, " games, total synced: ", new_total, "/", total_games)
			
			# Set the completion callback - it will be called when all thread operations finish
			_batch_completion_callback = func():
				print("[DataManager] All thread operations complete for batch")
				
				# Check if we're done with this platform
				if new_total >= total_games or batch_count == 0:
					_finish_sync(new_total, total_games, callback)
					return
				
				# Continue with next batch
				var new_offset = offset + batch_size
				_fetch_remaining_batches(platform_id, platform_slug, platform_name, new_offset, batch_size, total_games, new_total, callback)
		)
	)

func _process_batch_async(items: Array, platform_slug: String, complete_callback: Callable):
	var processor = SyncBatchProcessor.new(items, platform_slug)
	
	# Emit progress as each game is fully processed
	processor.game_fully_processed.connect(func(game_id: String, success: bool):
		print("[DataManager] Game fully processed: ", game_id, " success: ", success)
		if success:
			_cumulative_sync_current += 1
			_current_sync_progress = float(_cumulative_sync_current) / float(_cumulative_sync_total) * 100.0 if _cumulative_sync_total > 0 else 0.0
			_update_sync_notification_text(_cumulative_sync_current, _cumulative_sync_total)
			sync_progress.emit(_current_sync_progress, _cumulative_sync_current, _cumulative_sync_total)
	)
	
	processor.all_complete.connect(func(success_count: int):
		print("[DataManager] Batch complete: ", success_count, " games")
		complete_callback.call(success_count)
	)
	
	processor.start()

func _process_game_batch(items: Array, platform_slug: String = "", callback: Callable = Callable()) -> int:
	# Legacy sync version - just queue all games and return immediately
	# For async processing, use _process_batch_async instead
	var count = 0
	for game_data in items:
		if not game_data is Dictionary:
			continue
		
		var game = GameResource.new()
		game.id = str(game_data.get("id", ""))
		game.romm_id = game_data.get("id", 0)
		game.title = game_data.get("name", "") if game_data.get("name") != null else ""
		game.platform = game_data.get("platform_display_name", "") if game_data.get("platform_display_name") != null else ""
		# Use the provided platform_slug instead of the one from API (which might be different)
		game.platform_slug = platform_slug if platform_slug != "" else (game_data.get("platform_slug", "") if game_data.get("platform_slug") != null else "")
		game.cover_url = game_data.get("url_cover", "") if game_data.get("url_cover") != null else ""
		game.cover_path = game_data.get("path_cover_large", "") if game_data.get("path_cover_large") != null else ""
		game.file_name = game_data.get("fs_name", "") if game_data.get("fs_name") != null else ""
		game.file_path = game_data.get("full_path", "") if game_data.get("full_path") != null else ""
		game.file_size = game_data.get("fs_size_bytes", 0)
		game.has_local_copy = false
		var updated_at = game_data.get("updated_at", "")
		game.last_updated = updated_at if updated_at != null else ""
		var desc = game_data.get("summary", "")
		game.description = desc if desc != null else ""
		
		var genres_array: Array[String] = []
		if game_data.has("metadatum") and game_data["metadatum"] != null and game_data["metadatum"] is Dictionary:
			if game_data["metadatum"].has("genres") and game_data["metadatum"]["genres"] != null and game_data["metadatum"]["genres"] is Array:
				for genre in game_data["metadatum"]["genres"]:
					if genre is String:
						genres_array.append(genre)
		game.genres = genres_array
		
		var rating = 0.0
		if game_data.has("metadatum") and game_data["metadatum"] != null and game_data["metadatum"] is Dictionary:
			var avg_rating = game_data["metadatum"].get("average_rating", 0.0)
			rating = avg_rating if avg_rating != null else 0.0
		game.rating = rating
		
		add_game(game)
		count += 1
	
	if callback.is_valid():
		callback.call(count)
	
	return count

func _update_sync_notification_text(current: int, total: int) -> void:
	if _sync_notification_id == -1:
		return
	
	var percent = 0
	if total > 0:
		percent = int(float(current) / float(total) * 100.0)
	
	# Show current platform in the sync message
	var platform_text = _current_platform_name
	if platform_text != "":
		NotificationManager.update_notification_text(_sync_notification_id, "Syncing %s %d/%d (%d%%)" % [platform_text, current, total, percent])
	else:
		NotificationManager.update_notification_text(_sync_notification_id, "Syncing games %d/%d (%d%%)" % [current, total, percent])

func _finish_sync(total_synced: int, total_games: int, callback: Callable):
	print("[DataManager] Platform sync complete - Total synced: ", total_synced, "/", total_games)
	# Don't reset _sync_notification_id here - it should persist until all platforms finish
	if callback.is_valid():
		callback.call(true, "", total_synced, total_games)

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

func get_platform_by_slug(slug: String) -> PlatformResource:
	if not _is_db_ready:
		return null
	
	_db.query("SELECT * FROM platforms WHERE slug = '%s'" % slug)
	if _db.query_result.size() > 0:
		var row = _db.query_result[0]
		var platform = PlatformResource.new()
		platform.id = row["id"]
		platform.romm_id = row["romm_id"]
		platform.name = row["name"]
		platform.slug = row["slug"]
		platform.icon_url = row["icon_url"]
		platform.icon_path = row["icon_path"]
		platform.emulator_path = row["emulator_path"]
		var ext_array2 = row["extensions"].split(",") if row["extensions"] else []
		platform.extensions = Array(ext_array2, TYPE_STRING, &"", null)
		return platform
	return null

# ==================== SYNC METADATA ====================

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
	
	_db.query("""
		INSERT OR REPLACE INTO cache_metadata (key, value) 
		VALUES ('last_sync', '%s')
	""" % timestamp)

# ==================== IMAGE CACHE OPERATIONS ====================

func _ensure_cache_folder():
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("cache"):
		dir.make_dir("cache")
	
	dir = DirAccess.open("user://cache")
	if not dir.dir_exists("covers"):
		dir.make_dir("covers")

func get_cached_image_path(url: String) -> String:
	var hash = url.md5_text()
	return CACHE_FOLDER + hash + ".jpg"

func load_image(url: String, callback: Callable = Callable()):
	if url == "" or not url.begins_with("http"):
		if callback.is_valid():
			callback.call(null)
		return
	
	var cache_path = get_cached_image_path(url)
	
	# Check if cached locally - load directly (no thread needed for file read)
	if FileAccess.file_exists(cache_path):
		var texture = _load_texture_from_disk(cache_path)
		if texture:
			if callback.is_valid():
				callback.call(texture)
			image_loaded.emit(url, texture)
			return
		else:
			# Cache exists but failed to load - remove and re-download
			push_warning("[DataManager] Cached cover failed to load, re-downloading: ", url)
			if FileAccess.file_exists(cache_path):
				DirAccess.remove_absolute(cache_path)
			# Fall through to download
	
	# Not cached or cache failed - download it
	_download_image(url, cache_path, callback)

func _download_image(url: String, cache_path: String, callback: Callable = Callable()):
	# Use NetworkManager for all HTTP requests (async)
	NetworkManager.download_image(url, func(body: PackedByteArray):
		if body.is_empty():
			push_warning("[DataManager] Empty image body from: ", url)
			_emit_image_callbacks(url, null)
			return
		
		print("[DataManager] Downloaded image, processing on image thread: ", url)
		_pending_image_operations += 1
		print("[DataManager] Pending image operations: ", _pending_image_operations)
		
		# Process image on image thread (save + create texture)
		ThreadManager.queue_image_task(
			func():
				# Verify it's a valid image
				var texture = _load_texture_from_memory(body)
				if texture == null:
					push_warning("[DataManager] Invalid image data from: ", url, " (size: ", body.size(), ")")
					return null
				
				# Save to cache on image thread
				var file = FileAccess.open(cache_path, FileAccess.WRITE)
				if file:
					file.store_buffer(body)
					file.close()
					print("[DataManager] Saved image to cache: ", cache_path)
				
				return texture,
			func(texture: Texture2D):
				_pending_image_operations -= 1
				print("[DataManager] Image operation complete. Pending: ", _pending_image_operations)
				if texture:
					print("[DataManager] Image processed successfully: ", url)
					_emit_image_callbacks(url, texture)
				else:
					push_warning("[DataManager] Failed to process image: ", url)
					_emit_image_callbacks(url, null)
				_check_batch_completion()
		)
	)

func _load_texture_from_disk(path: String) -> Texture2D:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return null
	
	var buffer = file.get_buffer(file.get_length())
	file.close()
	
	var texture = _load_texture_from_memory(buffer)
	
	# If loading failed, don't delete immediately - might be temporary issue
	# Only delete if file is obviously corrupted (too small)
	if texture == null:
		if buffer.size() < 100:
			push_warning("[DataManager] Deleting corrupted cache file (too small): ", path, " size: ", buffer.size())
			DirAccess.remove_absolute(path)
	
	return texture

func _load_texture_from_memory(buffer: PackedByteArray) -> Texture2D:
	# Check if buffer is large enough to be a valid image
	if buffer.size() < 16:
		return null
	
	# Check file signature to determine format
	var is_jpg = buffer[0] == 0xFF and buffer[1] == 0xD8 and buffer[2] == 0xFF
	var is_png = buffer[0] == 0x89 and buffer[1] == 0x50 and buffer[2] == 0x4E and buffer[3] == 0x47
	
	var image = Image.new()
	var err = FAILED
	
	if is_jpg:
		err = image.load_jpg_from_buffer(buffer)
	elif is_png:
		err = image.load_png_from_buffer(buffer)
	else:
		# Try webp as fallback (some images might be webp)
		err = image.load_webp_from_buffer(buffer)
	
	if err == OK:
		return ImageTexture.create_from_image(image)
	
	# Unknown format or failed to load
	return null

func _emit_image_callbacks(url: String, texture: Texture2D):
	if _loading_images.has(url):
		for callback in _loading_images[url]:
			if callback.is_valid():
				callback.call(texture)
		_loading_images.erase(url)
	


# ==================== UTILITY ====================

func get_downloaded_games() -> Array[GameResource]:
	var all_games = get_all_games()
	var downloaded: Array[GameResource] = []
	for game in all_games:
		if game.has_local_copy:
			downloaded.append(game)
	return downloaded

func get_undownloaded_games() -> Array[GameResource]:
	var all_games = get_all_games()
	var undownloaded: Array[GameResource] = []
	for game in all_games:
		if not game.has_local_copy:
			undownloaded.append(game)
	return undownloaded

func ensure_game_folder_structure(root_path: String) -> bool:
	if root_path == "":
		return false
	
	var dir = DirAccess.open(root_path)
	if not dir:
		return false
	
	var platforms = get_all_platforms()
	for platform in platforms:
		if not dir.dir_exists(platform.slug):
			var error = dir.make_dir(platform.slug)
			if error != OK:
				push_warning("Failed to create folder: " + platform.slug)
	
	return true

func get_game_file_path(game: GameResource, root_folder: String) -> String:
	if game.platform_slug == "" or game.file_name == "":
		return ""
	return root_folder + "/" + game.platform_slug + "/" + game.file_name
