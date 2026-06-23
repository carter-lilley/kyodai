extends Manager
class_name DatabaseManager

var data_manager: Node

const DB_PATH = "user://database/kyodai.db"
const FSM = preload("res://managers/filesystem_manager.gd")

var _db: SQLite = null
var _is_db_ready: bool = false
var _db_init_failed: bool = false
var _verbose_sql: bool = false

var _db_mutex: Mutex = Mutex.new()

# Cached count of downloaded games. -1 means "not cached"; invalidate whenever
# game/download state changes (add, update, delete, sync, scan, cover folding).
var _downloaded_games_count_cache: int = -1


func _ready():
	data_manager = get_parent()


func _db_lock():
	_db_mutex.lock()


func _db_unlock():
	_db_mutex.unlock()


func lock() -> void:
	_db_lock()


func unlock() -> void:
	_db_unlock()


func query_array(query: String, bindings: Array = []) -> Array:
	_db_lock()
	var result: Array
	if bindings.is_empty():
		var success = _db.query(query)
		result = _db.query_result.duplicate() if success else []
	else:
		var success = _db.query_with_bindings(query, bindings)
		result = _db.query_result.duplicate() if success else []
	_db_unlock()
	return result


func query_bool(query: String, bindings: Array = []) -> bool:
	_db_lock()
	var success: bool
	if bindings.is_empty():
		success = _db.query(query)
	else:
		success = _db.query_with_bindings(query, bindings)
	_db_unlock()
	return success


## Unlocked variants for use when caller already holds _db_mutex.
## Prevents deadlock on platforms with non-reentrant mutexes (Linux/Android).
func query_array_unlocked(query: String, bindings: Array = []) -> Array:
	var result: Array
	if bindings.is_empty():
		var success = _db.query(query)
		result = _db.query_result.duplicate() if success else []
	else:
		var success = _db.query_with_bindings(query, bindings)
		result = _db.query_result.duplicate() if success else []
	return result


func query_bool_unlocked(query: String, bindings: Array = []) -> bool:
	var success: bool
	if bindings.is_empty():
		success = _db.query(query)
	else:
		success = _db.query_with_bindings(query, bindings)
	return success


func initialize_database():
	print("[DatabaseManager] initialize_database() starting...")
	# Database is being (re)opened; any previous count cache is no longer valid.
	invalidate_downloaded_games_count_cache()
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("database"):
		var mkerr = dir.make_dir("database")
		if mkerr != OK:
			var err_msg = "Failed to create database directory: user://database/"
			push_error("[DatabaseManager] " + err_msg)
			_db_init_failed = true
			data_manager.database_failed.emit(err_msg)
			NotificationManager.show_notification("Fatal error: " + err_msg + "\nApp cannot function without database access.", NotificationManager.Type.ERROR)
			return

	_db = SQLite.new()
	_db.path = DB_PATH
	_db.verbosity_level = SQLite.QUIET if not _verbose_sql else SQLite.VERBOSE

	if _db.open_db():
		_create_tables()
		_is_db_ready = true
		print("[DatabaseManager] Database ready - emitting signal")
		data_manager.database_ready.emit()
	else:
		var err_msg = "Failed to open database at " + DB_PATH
		push_error("[DatabaseManager] " + err_msg)
		_db_init_failed = true
		data_manager.database_failed.emit(err_msg)
		NotificationManager.show_notification("Fatal error: " + err_msg + "\nApp cannot function without database access.", NotificationManager.Type.ERROR)


func _create_tables():
	query_bool("""
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
			cover_group_master INTEGER DEFAULT 1,
			igdb_metadata TEXT DEFAULT '{}'
		)
	""")

	query_bool("""
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

	query_bool("CREATE INDEX IF NOT EXISTS idx_games_platform ON games(platform_slug)")
	query_bool("CREATE INDEX IF NOT EXISTS idx_games_title ON games(title)")
	query_bool("CREATE INDEX IF NOT EXISTS idx_games_cover_group ON games(cover_group_id)")

	# Create cache_metadata table for per-platform sync timestamps
	query_bool("""
		CREATE TABLE IF NOT EXISTS cache_metadata (
			key TEXT PRIMARY KEY,
			value TEXT
		)
	""")

	# Create save_sync table for tracking save file sync state
	query_bool("""
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
	query_bool("CREATE INDEX IF NOT EXISTS idx_save_sync_romm_emulator ON save_sync(romm_id, emulator_id)")


func is_database_ready() -> bool:
	return _is_db_ready


func is_database_init_failed() -> bool:
	return _db_init_failed


func _escape_sql(text: String) -> String:
	return text.replace("'", "''")


func invalidate_downloaded_games_count_cache() -> void:
	"""Invalidate the cached downloaded-games count so the next query reads fresh data."""
	_downloaded_games_count_cache = -1


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

	# Restore IGDB metadata blob
	if row.has("igdb_metadata") and row["igdb_metadata"] != "":
		var json_igdb = JSON.new()
		var err_igdb = json_igdb.parse(row["igdb_metadata"])
		if err_igdb == OK and json_igdb.data is Dictionary:
			game.igdb_metadata = json_igdb.data
		else:
			game.igdb_metadata = {}
	else:
		game.igdb_metadata = {}

	return game


func _get_db_platform_slugs() -> Array[String]:
	"""Get list of platform slugs that have games in the database"""
	var slugs: Array[String] = []
	if not _is_db_ready:
		return slugs

	var query_result = query_array("SELECT DISTINCT platform_slug FROM games ORDER BY platform_slug")
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


func get_enabled_platforms() -> Array:
	return _get_enabled_platforms()


func get_db_platform_slugs() -> Array[String]:
	return _get_db_platform_slugs()


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
			print("[DatabaseManager] enabled_platforms is empty; falling back to %d platform(s) found in database" % db_slugs.size())
			return db_slugs
	return slugs


# ==================== DOWNLOADED GAMES SCAN ====================

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
	# Scan results change has_local_copy / downloaded_sibling_ids.
	invalidate_downloaded_games_count_cache()
	MemoryManager.queue_db_task(
		func():
			_db_lock()
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
				var query = "UPDATE games SET has_local_copy = 1, file_path = ?, downloaded_sibling_ids = ? WHERE romm_id = ?"

				if query_bool_unlocked(query, [new_file_path, downloaded_ids_json, romm_id]):
					updated_count += 1

			_db_unlock()
			return updated_count,
		func(updated_count: int):
			print("[DEBUG] Scan complete - updated %d games in DB" % updated_count)
			data_manager.scan_for_downloaded_games_completed.emit(updated_count)
			if callback.is_valid():
				callback.call(updated_count)
	)


# ==================== PLATFORMS ====================

func add_platform(platform: PlatformResource) -> bool:
	if not _is_db_ready:
		return false

	var query = """
		INSERT OR REPLACE INTO platforms
		(id, romm_id, name, slug, icon_url, icon_path, emulator_path, extensions)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	"""
	var bindings = [
		platform.id,
		platform.romm_id,
		platform.name,
		platform.slug,
		platform.icon_url,
		platform.icon_path,
		platform.emulator_path,
		",".join(platform.extensions)
	]

	return query_bool(query, bindings)


func get_all_platforms() -> Array[PlatformResource]:
	var platforms: Array[PlatformResource] = []
	if not _is_db_ready:
		return platforms

	var query_result = query_array("SELECT * FROM platforms ORDER BY name")
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
	if not _is_db_ready:
		push_error("[Sync] ERROR: Database not ready in remove_platform_games")
		if callback.is_valid():
			callback.call(false)
		return

	# Platform removal can change the downloaded-games count.
	invalidate_downloaded_games_count_cache()

	# Queue all database operations on the DB thread to avoid race conditions
	MemoryManager.queue_db_task(
		func():
			_db_lock()
			# First, get all games for this platform to delete their covers
			var query_result = query_array_unlocked("SELECT cover_url FROM games WHERE platform_slug = ?", [platform_slug])
			var cover_urls: Array[String] = []
			for row in query_result:
				var url = row.get("cover_url", "")
				if url != "":
					cover_urls.append(url)

			# Delete games from database and get the count
			var count_before = query_result.size()
			var success = query_bool_unlocked("DELETE FROM games WHERE platform_slug = ?", [platform_slug])

			_db_unlock()
			return {
				"success": success,
				"cover_urls": cover_urls,
				"count": count_before
			},
		func(result: Dictionary):
			var success = result.get("success", false)
			var cover_urls = result.get("cover_urls", [])
			var _count = result.get("count", 0)

			if success:
				# Delete cover cache files on main thread (file system access)
				var covers_deleted = 0
				for url in cover_urls:
					var cache_path = data_manager.cover.get_cached_image_path(url)
					if FileAccess.file_exists(cache_path):
						DirAccess.remove_absolute(cache_path)
						covers_deleted += 1
				if covers_deleted > 0:
					print("[Sync] Removed %s (%d games, %d covers deleted)" % [platform_slug, _count, covers_deleted])
			elif not success:
				push_error("[Sync] Removal failed for %s" % platform_slug)

			data_manager.games_removed.emit(platform_slug)

			if callback.is_valid():
				callback.call(success)
	)


# ==================== DATABASE OPERATIONS ====================

func add_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	invalidate_downloaded_games_count_cache()

	MemoryManager.queue_db_task(
		func():
			_db_lock()
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
				game.file_path,
				game.file_size,
				1 if game.has_local_copy else 0,
				game.last_updated,
				game.description,
				",".join(game.genres),
				game.rating,
				JSON.stringify(game.siblings),
				game.selected_sibling_id,
				1 if game.is_master_entry else 0,
				JSON.stringify(game.downloaded_sibling_ids),
				1 if game.has_cover_art else 0,
				game.last_played,
				game.title_id,
				game.cover_group_id,
				1 if game.cover_group_master else 0,
				JSON.stringify(game.igdb_metadata)
			]
			var success = query_bool_unlocked(query, bindings)
			_db_unlock()
			return success,

		func(success: bool):
			if success:
				# Use batch notification during sync, individual during normal operations
				# Only notify for games with cover art (games without covers are hidden)
				# Only notify for master entries (sibling ROMs are hidden from library view)
				# AND only if it's a cover group master (or not in a cover group)
				if data_manager.sync.is_sync_in_progress():
					if game.has_cover_art and game.is_master_entry and game.cover_group_master:
						data_manager.sync.queue_batch_notification(game)
				else:
					data_manager.game_added.emit(game)
			if callback.is_valid():
				callback.call(success)
	)
	return true


func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	invalidate_downloaded_games_count_cache()

	MemoryManager.queue_db_task(
		func():
			_db_lock()
			var query = """
				UPDATE games SET
					title = ?,
					platform = ?,
					platform_slug = ?,
					cover_url = ?,
					cover_path = ?,
					file_name = ?,
					file_path = ?,
					file_size = ?,
					has_local_copy = ?,
					last_updated = ?,
					description = ?,
					genres = ?,
					rating = ?,
					siblings = ?,
					selected_sibling_id = ?,
					is_master_entry = ?,
					downloaded_sibling_ids = ?,
					has_cover_art = ?,
					last_played = ?,
					title_id = ?,
					cover_group_id = ?,
					cover_group_master = ?,
					igdb_metadata = ?
				WHERE romm_id = ?
			"""
			var bindings = [
				game.title,
				game.platform,
				game.platform_slug,
				game.cover_url,
				game.cover_path,
				game.file_name,
				game.file_path,
				game.file_size,
				1 if game.has_local_copy else 0,
				game.last_updated,
				game.description,
				",".join(game.genres),
				game.rating,
				JSON.stringify(game.siblings),
				game.selected_sibling_id,
				1 if game.is_master_entry else 0,
				JSON.stringify(game.downloaded_sibling_ids),
				1 if game.has_cover_art else 0,
				game.last_played,
				game.title_id,
				game.cover_group_id,
				1 if game.cover_group_master else 0,
				JSON.stringify(game.igdb_metadata),
				game.romm_id
			]
			var success = query_bool_unlocked(query, bindings)
			_db_unlock()
			return success,

		func(success: bool):
			if success:
				data_manager.game_updated.emit(game)
			if callback.is_valid():
				callback.call(success)
	)
	return true


func update_game_title_id(romm_id: int, title_id: String, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	MemoryManager.queue_db_task(
		func():
			_db_lock()
			var success = query_bool_unlocked("UPDATE games SET title_id = ? WHERE romm_id = ?", [title_id, romm_id])
			_db_unlock()
			return success,

		func(success: bool):
			if success:
				pass
			if callback.is_valid():
				callback.call(success)
	)
	return true


func update_game_siblings(romm_id: int, siblings: Array[Dictionary], callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	MemoryManager.queue_db_task(
		func():
			_db_lock()
			var success = query_bool_unlocked("UPDATE games SET siblings = ? WHERE romm_id = ?", [JSON.stringify(siblings), romm_id])
			_db_unlock()
			return success,

		func(success: bool):
			if success:
				pass
			if callback.is_valid():
				callback.call(success)
	)
	return true


func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	"""Update the last_played timestamp for a game."""
	if not _is_db_ready:
		return false

	return query_bool("UPDATE games SET last_played = ? WHERE romm_id = ?", [timestamp, romm_id])


func get_game_by_id(romm_id: int) -> GameResource:
	if not _is_db_ready:
		return null
	var query_result = query_array("SELECT * FROM games WHERE romm_id = ?", [romm_id])
	if query_result.size() > 0:
		return _row_to_game(query_result[0])
	return null


func get_all_games() -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var query_result = query_array("SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY title")
	for row in query_result:
		games.append(_row_to_game(row))
	return games


func get_games_by_platform(platform_slug: String) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var query = "SELECT * FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY title"
	var query_result = query_array(query, [platform_slug])
	for row in query_result:
		games.append(_row_to_game(row))
	return games


func get_games_paginated(offset: int, limit: int, sort_field: String = "title", ascending: bool = true, platform_slug: String = "") -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games

	# Whitelist allowed sort fields to prevent SQL injection
	var allowed_sort_fields = {"title": true, "romm_id": true, "rating": true, "last_played": true, "platform": true}
	var safe_sort_field = sort_field if allowed_sort_fields.has(sort_field) else "title"
	var order = "ASC" if ascending else "DESC"
	var query: String
	var bindings: Array = []

	if platform_slug.is_empty():
		query = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY %s %s LIMIT ? OFFSET ?" % [safe_sort_field, order]
		bindings = [limit, offset]
	else:
		query = "SELECT * FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY %s %s LIMIT ? OFFSET ?" % [safe_sort_field, order]
		bindings = [platform_slug, limit, offset]

	var query_result = query_array(query, bindings)

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

	var query_result = query_array(query)
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
	var bindings: Array = []
	if platform_slug.is_empty():
		query = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1"
	else:
		query = "SELECT COUNT(*) as count FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1"
		bindings = [platform_slug]

	var query_result = query_array(query, bindings)
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

	var pattern = "%" + query + "%"
	var sql = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND title LIKE ? ORDER BY title ASC LIMIT ? OFFSET ?"

	var query_result = query_array(sql, [pattern, limit, offset])
	for row in query_result:
		games.append(_row_to_game(row))

	return games


func get_search_results_count(query: String) -> int:
	"""Get count of search results."""
	if not _is_db_ready:
		return 0

	var pattern = "%" + query + "%"
	var sql = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND title LIKE ?"

	var query_result = query_array(sql, [pattern])
	if query_result.size() > 0:
		var row = query_result[0]
		if row.has("count"):
			return int(row["count"])
	return 0


func get_downloaded_games_count() -> int:
	"""Get count of downloaded games from synced platforms.

	Uses a cached value when available to avoid repeated COUNT(*) queries.
	The cache is invalidated whenever game/download state changes.
	"""
	if not _is_db_ready:
		return 0

	if _downloaded_games_count_cache >= 0:
		return _downloaded_games_count_cache

	var enabled_slugs = _get_enabled_platform_slugs()
	if enabled_slugs.size() == 0:
		return 0

	var placeholders = ", ".join(enabled_slugs.map(func(_s): return "?"))
	var query = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND platform_slug IN (%s) AND (has_local_copy = 1 OR downloaded_sibling_ids != '[]')" % placeholders

	var query_result = query_array(query, enabled_slugs)
	if query_result.size() > 0:
		var row = query_result[0]
		if row.has("count"):
			var count = int(row["count"])
			_downloaded_games_count_cache = count
			print("[DatabaseManager] get_downloaded_games_count: " + str(count))
			return count
	return 0


func get_downloaded_games_paginated(offset: int, limit: int) -> Array[GameResource]:
	"""Get downloaded games from synced platforms, sorted by most recently played."""
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games

	var enabled_slugs = _get_enabled_platform_slugs()
	if enabled_slugs.size() == 0:
		return games

	var placeholders = ", ".join(enabled_slugs.map(func(_s): return "?"))
	var query = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND platform_slug IN (%s) AND (has_local_copy = 1 OR downloaded_sibling_ids != '[]') ORDER BY last_played DESC, title ASC LIMIT ? OFFSET ?" % placeholders

	var bindings: Array = []
	bindings.append_array(enabled_slugs)
	bindings.append(limit)
	bindings.append(offset)
	var query_result = query_array(query, bindings)
	for row in query_result:
		games.append(_row_to_game(row))
	return games


func get_random_game() -> GameResource:
	"""Get a random game from the database."""
	if not _is_db_ready:
		return null

	# Get a random game that has a cover and is a master entry
	var query_result = query_array("SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY RANDOM() LIMIT 1")
	if query_result.size() > 0:
		return _row_to_game(query_result[0])
	return null


# ==================== SYNC TIMESTAMPS / DEVICE ID ====================

func get_last_sync_time(platform_slug: String = "") -> String:
	if not _is_db_ready:
		return ""
	var key = "last_sync_" + platform_slug if platform_slug != "" else "last_sync"
	var query_result = query_array("SELECT value FROM cache_metadata WHERE key = ?", [key])
	if query_result.size() > 0:
		return query_result[0]["value"]
	return ""


func set_last_sync_time(platform_slug: String, timestamp: String):
	if not _is_db_ready:
		return
	var key = "last_sync_" + platform_slug if platform_slug != "" else "last_sync"
	query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES (?, ?)", [key, timestamp])


func get_romm_device_id() -> String:
	"""Get the registered RomM device ID."""
	if not _is_db_ready:
		return ""
	var query_result = query_array("SELECT value FROM cache_metadata WHERE key = 'romm_device_id'")
	if query_result.size() > 0:
		return query_result[0].get("value", "")
	return ""


func set_romm_device_id(device_id: String) -> void:
	"""Store the registered RomM device ID."""
	if not _is_db_ready:
		return
	query_bool("INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('romm_device_id', ?)", [device_id])


func clear_romm_device_id() -> void:
	"""Clear the stored RomM device ID (e.g. if server no longer recognizes it)."""
	if not _is_db_ready:
		return
	query_bool("DELETE FROM cache_metadata WHERE key = 'romm_device_id'")


# ==================== SETTINGS CHANGE HANDLER ====================

func _on_setting_changed(value, setting):
	if setting.property_name == "hide_games_without_covers":
		print("[DatabaseManager] Hide no-cover setting changed to %s" % value)
		invalidate_downloaded_games_count_cache()
	elif setting.property_name == "fold_romm_siblings":
		print("[DatabaseManager] Fold RomM siblings setting changed to %s" % value)
		invalidate_downloaded_games_count_cache()
	elif setting.property_name == "enabled_platforms":
		invalidate_downloaded_games_count_cache()
