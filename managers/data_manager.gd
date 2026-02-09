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
var _sync_notification_id: int = -1

# Logging control
var _verbose_sql: bool = false  # Set to true to see SQL queries

# Sync state
var _sync_current: int = 0
var _sync_total: int = 0
var _sync_platform: String = ""
var _sync_platform_index: int = 0  # Current platform number (1-based)
var _sync_platform_count: int = 0  # Total platforms
var _sync_platform_total: int = 0  # Total games in current platform

# Batch processing state
var _batch_remaining: int = 0
var _batch_callback: Callable = Callable()
var _batch_success_count: int = 0

# Pre-calculation state (avoid closures)
var _precalc_pending: int = 0
var _precalc_total: int = 0
var _precalc_callback: Callable = Callable()

func _ready():
	_ensure_thread_manager()
	_initialize_database()
	_ensure_cache_folder()

func _ensure_thread_manager():
	if ThreadManager._instance == null:
		var tm = ThreadManager.new()
		add_child(tm)

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
			rating REAL DEFAULT 0.0
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
		sync_completed.emit(true, "Synced " + str(total_synced) + " games")
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
	
	var batch_size = 15
	
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
	"""Process a batch of games. Calls on_complete with success count when all done."""
	var total = items.size()
	if total == 0:
		on_complete.call(0)
		return
	
	# Reset batch tracking state
	_batch_remaining = total
	_batch_callback = on_complete
	_batch_success_count = 0
	
	# Process each game
	for game_data in items:
		_process_game(game_data, platform_slug)

func _process_game(game_data: Dictionary, platform_slug: String):
	"""Process a single game - DB + cover in parallel."""
	var game = _create_game_from_data(game_data, platform_slug)
	
	# Reset sync tracking fields
	game._sync_db_done = false
	game._sync_cover_done = false
	game._sync_db_success = false
	
	print("[DataManager] Processing: ", game.title)
	
	# DB callback
	add_game(game, func(success: bool):
		game._sync_db_done = true
		game._sync_db_success = success
		_check_game_complete(game)
	)
	
	# Cover callback
	var cover_url = game.cover_url
	if cover_url != "" and cover_url.begins_with("http"):
		_download_cover(cover_url, func(_ok: bool):
			game._sync_cover_done = true
			_check_game_complete(game)
		)
	else:
		game._sync_cover_done = true
		_check_game_complete(game)

func _check_game_complete(game: GameResource):
	if not (game._sync_db_done and game._sync_cover_done):
		return
	
	_batch_remaining -= 1
	if game._sync_db_success:
		_sync_current += 1
		_batch_success_count += 1
	
	print("[DataManager] Complete: ", game.title)
	
	if _batch_remaining <= 0 and _batch_callback.is_valid():
		print("[DataManager] Batch complete: ", _batch_success_count, " games")
		var cb = _batch_callback
		_batch_callback = Callable()
		cb.call(_batch_success_count)

func _create_game_from_data(data: Dictionary, platform_slug: String) -> GameResource:
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
	
	return game

# ==================== DATABASE OPERATIONS ====================

func add_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false
	
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
	var genres: Array[String] = []
	if row["genres"] and row["genres"] != "":
		for g in row["genres"].split(","):
			genres.append(g)
	game.genres = genres
	game.rating = row["rating"]
	return game

# ==================== COVER DOWNLOAD ====================

func _download_cover(url: String, callback: Callable):
	var cache_path = get_cached_image_path(url)
	
	if FileAccess.file_exists(cache_path):
		callback.call(true)
		return
	
	NetworkManager.download_image(url, func(body: PackedByteArray):
		if body.is_empty():
			callback.call(false)
			return
		
		ThreadManager.queue_image_task(
			func():
				var texture = _load_texture_from_memory(body)
				if texture:
					var file = FileAccess.open(cache_path, FileAccess.WRITE)
					if file:
						file.store_buffer(body)
						file.close()
				return texture,
			func(texture: Texture2D):
				callback.call(texture != null)
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
	
	# Try cache first
	if FileAccess.file_exists(cache_path):
		var file = FileAccess.open(cache_path, FileAccess.READ)
		if file:
			var buffer = file.get_buffer(file.get_length())
			file.close()
			var texture = _load_texture_from_memory(buffer)
			if texture:
				if callback.is_valid():
					callback.call(texture)
				image_loaded.emit(url, texture)
				return
	
	# Download
	_download_cover(url, func(_ok):
		var file = FileAccess.open(cache_path, FileAccess.READ)
		if file:
			var buffer = file.get_buffer(file.get_length())
			file.close()
			var texture = _load_texture_from_memory(buffer)
			if callback.is_valid():
				callback.call(texture)
			if texture:
				image_loaded.emit(url, texture)
		else:
			if callback.is_valid():
				callback.call(null)
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
	
	# Get all games for this platform to delete their covers
	var games_to_remove = get_games_by_platform(platform_slug)
	
	# Delete cover cache files
	var covers_deleted = 0
	for game in games_to_remove:
		if game.cover_url != "":
			var cache_path = get_cached_image_path(game.cover_url)
			if FileAccess.file_exists(cache_path):
				DirAccess.remove_absolute(cache_path)
				covers_deleted += 1
	
	# Delete games from database
	ThreadManager.queue_db_task(
		func():
			return _db.query("DELETE FROM games WHERE platform_slug = '%s'" % platform_slug),
		func(success: bool):
			if success:
				print("[DataManager] Removed ", games_to_remove.size(), " games from ", platform_slug)
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
