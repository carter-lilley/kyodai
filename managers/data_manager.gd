extends Manager

# DataManager - Self-contained data persistence and caching manager
# Combines SQLite database operations and file system image caching

signal database_ready()
signal sync_completed(success: bool, message: String)
signal sync_progress(percent: float, current: int, total: int)
signal game_added(game: GameResource)
signal game_updated(game: GameResource)
signal image_loaded(url: String, texture: Texture2D)
signal cache_cleared()

const DB_PATH = "user://database/kyodai.db"
const CACHE_FOLDER = "user://cache/covers/"
const MAX_CACHE_SIZE_MB = 500
const MAX_CACHE_SIZE_BYTES = MAX_CACHE_SIZE_MB * 1024 * 1024

var _db: SQLite = null
var _is_db_ready: bool = false
var _loading_images: Dictionary = {}
var _cache_size: int = 0
var _cache_access_count: Dictionary = {}

func _ready():
	# Initialize ThreadManager first
	_ensure_thread_manager()
	
	_initialize_database()
	_ensure_cache_folder()
	_calculate_cache_size()

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
			if success:
				game_added.emit(game)
			if callback.is_valid():
				callback.call(success)
	)
	return true

func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
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
			if success:
				game_updated.emit(game)
			if callback.is_valid():
				callback.call(success)
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
	
	var enabled_platforms = _get_enabled_platforms_setting()
	
	print("[DataManager] Starting sync for enabled platforms")
	print("[DataManager] Enabled platforms from settings: ", enabled_platforms)
	
	# Get list of enabled platform IDs from settings
	var platforms_to_sync: Array = []  # Array of {slug, id} dictionaries
	for slug in enabled_platforms.keys():
		var platform_data = enabled_platforms.get(slug)
		var is_enabled = false
		var platform_id = 0
		
		if platform_data is bool:
			is_enabled = platform_data
		elif platform_data is Dictionary:
			is_enabled = platform_data.get("enabled", false)
			platform_id = platform_data.get("id", 0)
		
		print("[DataManager] Platform ", slug, " enabled: ", is_enabled, " id: ", platform_id)
		if is_enabled and platform_id > 0:
			platforms_to_sync.append({"slug": slug, "id": platform_id})
	
	print("[DataManager] Platforms to sync: ", platforms_to_sync.map(func(p): return p.slug))
	
	# Get list of enabled slugs for filtering
	var enabled_slugs = platforms_to_sync.map(func(p): return p.slug)
	
	# Get all platform slugs that have games in the database
	var db_platform_slugs = _get_game_platform_slugs()
	print("[DataManager] Platform slugs with games in DB: ", db_platform_slugs)
	
	# Remove games from disabled platforms (platforms with games in DB but not enabled)
	for platform_slug in db_platform_slugs:
		if not platform_slug in enabled_slugs:
			print("[DataManager] Removing games from disabled platform: ", platform_slug)
			remove_platform_games(platform_slug)
	
	if platforms_to_sync.size() == 0:
		print("[DataManager] No platforms enabled for sync")
		sync_completed.emit(true, "No platforms enabled")
		if callback.is_valid():
			callback.call(true, "", 0, 0)
		return
	
	_sync_platforms_sequential(platforms_to_sync, 0, 0, 0, callback)

func _sync_platforms_sequential(platforms: Array, index: int, total_synced: int, total_games: int, callback: Callable):
	if index >= platforms.size():
		print("[DataManager] All platforms synced - Total: ", total_synced)
		sync_completed.emit(true, "Synced " + str(total_synced) + " games")
		if callback.is_valid():
			callback.call(true, "", total_synced, total_games)
		return
	
	var platform_info = platforms[index]
	var platform_id = platform_info.id
	var platform_slug = platform_info.slug
	print("[DataManager] Syncing platform: ", platform_slug, " (ID: ", platform_id, ")")
	
	sync_platform_games(platform_id, platform_slug, func(success: bool, message: String, synced: int, games: int):
		if success:
			total_synced += synced
			total_games += games
		
		# Sync next platform
		_sync_platforms_sequential(platforms, index + 1, total_synced, total_games, callback)
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
	ThreadManager.queue_db_task(
		func():
			return _db.query("DELETE FROM games WHERE platform_slug = '%s'" % platform_slug),
		func(success: bool):
			print("[DataManager] Removed games for platform: ", platform_slug, " success: ", success)
			if callback.is_valid():
				callback.call(success)
	)

func _get_enabled_platforms_setting() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

func sync_platform_games(platform_id: int, platform_slug: String, callback: Callable = Callable()) -> void:
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
			sync_completed.emit(true, "No games to sync")
			if callback.is_valid():
				callback.call(true, "", 0, 0)
			return
		
		# Process first batch asynchronously
		var first_batch_items = first_batch_data.get("items", [])
		_process_batch_async(first_batch_items, platform_slug, func(batch_count: int):
			var first_batch_total = batch_count
			sync_progress.emit(0.0, first_batch_total, total_games)
			
			# If we got all games in first batch, we're done
			if first_batch_total >= total_games:
				print("[DataManager] Sync complete - Total synced: ", first_batch_total)
				sync_completed.emit(true, "Synced " + str(first_batch_total) + " games")
				if callback.is_valid():
					callback.call(true, "", first_batch_total, total_games)
				return
			
			# Continue fetching remaining batches
			var next_offset = batch_size
			_fetch_remaining_batches(platform_id_str, platform_slug, next_offset, batch_size, total_games, first_batch_total, callback)
		)
	)

func _fetch_batch(platform_slug: String, offset: int, limit: int, callback: Callable):
	NetworkManager.fetch_games(func(data, error):
		callback.call(data, error)
	, platform_slug, offset, limit)

func _fetch_remaining_batches(platform_id: String, platform_slug: String, offset: int, batch_size: int, total_games: int, total_synced: int, callback: Callable):
	print("[DataManager] Fetching batch at offset: ", offset, ", total_synced so far: ", total_synced)
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
			
			var percent = float(new_total) / float(total_games) * 100.0
			sync_progress.emit(percent, new_total, total_games)
			print("[DataManager] Progress: ", new_total, "/", total_games, " (", int(percent), "%) ")
			
			# Check if we're done
			if new_total >= total_games or batch_count == 0:
				_finish_sync(new_total, total_games, callback)
				return
			
			# Continue with next batch - use new_total instead of updating total_synced
			var new_offset = offset + batch_size
			_fetch_remaining_batches(platform_id, platform_slug, new_offset, batch_size, total_games, new_total, callback)
		)
	)

func _process_batch_async(items: Array, platform_slug: String, complete_callback: Callable):
	var processor = SyncBatchProcessor.new(items, platform_slug)
	
	# Only emit progress at batch completion, not individual games
	processor.all_complete.connect(func(success_count: int):
		print("[DataManager] Batch processed: ", success_count, "/", items.size(), " games")
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

func _finish_sync(total_synced: int, total_games: int, callback: Callable):
	print("[DataManager] Sync complete - Total synced: ", total_synced, "/", total_games)
	set_last_sync_time(Time.get_datetime_string_from_system())
	sync_completed.emit(true, "Synced " + str(total_synced) + " games")
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

func _calculate_cache_size():
	_cache_size = 0
	var dir = DirAccess.open(CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				var file = FileAccess.open(CACHE_FOLDER + file_name, FileAccess.READ)
				if file:
					_cache_size += file.get_length()
					file.close()
			file_name = dir.get_next()
		dir.list_dir_end()

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
		_cache_access_count[cache_path] = _cache_access_count.get(cache_path, 0) + 1
		# Load directly without thread queue to avoid overhead with many cards
		var texture = _load_texture_from_disk(cache_path)
		if texture:
			if callback.is_valid():
				callback.call(texture)
			image_loaded.emit(url, texture)
		else:
			# Cache exists but failed to load - don't retry, just return null
			if callback.is_valid():
				callback.call(null)
		return
	
	# Not cached - return null (images should be cached from sync)
	if callback.is_valid():
		callback.call(null)

func _download_image(url: String, cache_path: String, callback: Callable = Callable()):
	# Use NetworkManager for all HTTP requests (async)
	NetworkManager.download_image(url, func(body: PackedByteArray):
		if body.is_empty():
			push_warning("[DataManager] Empty image body from: ", url)
			_emit_image_callbacks(url, null)
			return
		
		print("[DataManager] Downloaded image, processing on image thread: ", url)
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
					
					# Update cache size and access count on main thread
					call_deferred("_update_cache_after_save", cache_path, body.size())
				
				return texture,
			func(texture: Texture2D):
				if texture:
					print("[DataManager] Image processed successfully: ", url)
					_emit_image_callbacks(url, texture)
				else:
					push_warning("[DataManager] Failed to process image: ", url)
					_emit_image_callbacks(url, null)
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
			_cache_access_count.erase(path)
	
	return texture

func _update_cache_after_save(cache_path: String, size: int):
	# Called via call_deferred from image thread to update cache tracking on main thread
	_cache_size += size
	_cache_access_count[cache_path] = 1
	_enforce_cache_limit()

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
	
	image_loaded.emit(url, texture)

func _enforce_cache_limit():
	if _cache_size <= MAX_CACHE_SIZE_BYTES:
		return
	
	# Sort files by access count (LRU eviction)
	var files = _cache_access_count.keys()
	files.sort_custom(func(a, b): return _cache_access_count[a] < _cache_access_count[b])
	
	# Remove least accessed files until under limit
	for file_path in files:
		if _cache_size <= MAX_CACHE_SIZE_BYTES:
			break
		
		if FileAccess.file_exists(file_path):
			var file = FileAccess.open(file_path, FileAccess.READ)
			var size = 0
			if file:
				size = file.get_length()
				file.close()
			DirAccess.remove_absolute(file_path)
			_cache_size -= size
			_cache_access_count.erase(file_path)

func clear_image_cache():
	var dir = DirAccess.open(CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				DirAccess.remove_absolute(CACHE_FOLDER + file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	
	_cache_size = 0
	_cache_access_count.clear()
	cache_cleared.emit()

func get_cache_size_mb() -> float:
	return _cache_size / (1024.0 * 1024.0)

func get_max_cache_size_mb() -> int:
	return MAX_CACHE_SIZE_MB

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
