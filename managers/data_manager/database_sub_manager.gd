extends Manager
class_name DatabaseSubManager

var data_manager: Node

const DB_PATH = "user://database/kyodai.db"
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

var _db: SQLite = null
var _is_db_ready: bool = false
var _db_init_failed: bool = false
var _verbose_sql: bool = false

var _db_mutex: Mutex = Mutex.new()

# Cached count of downloaded games. -1 means "not cached"; invalidate whenever
# game/download state changes (add, update, delete, sync, scan, cover folding).
var _downloaded_games_count_cache: int = -1

# Cached platforms-with-games list (Library platform indicator). Same
# invalidation rule as the count cache above.
var _platforms_with_games_cache: Array[Dictionary] = []
var _platforms_with_games_cache_valid: bool = false

# Cached distinct filter values (Library filter sheet chips). Same
# invalidation rule as the count cache above.
var _filter_options_cache: Dictionary = {}
var _filter_options_cache_valid: bool = false


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


## Opens the database and creates tables. Runs on the DB worker thread (queued
## by DataManager._ready); returns true on success. Signal emission and UI
## notifications happen in the main-thread callback, not here.
func initialize_database() -> bool:
	print("[DatabaseManager] initialize_database() starting...")
	# Database is being (re)opened; any previous count cache is no longer valid.
	invalidate_downloaded_games_count_cache()
	if not FSM.make_dir_recursive("user://database"):
		push_error("[DatabaseManager] Failed to create database directory: user://database/")
		_db_init_failed = true
		return false

	_db = SQLite.new()
	_db.path = DB_PATH
	_db.verbosity_level = SQLite.QUIET if not _verbose_sql else SQLite.VERBOSE

	if _db.open_db():
		_create_tables()
		_is_db_ready = true
		return true

	push_error("[DatabaseManager] Failed to open database at " + DB_PATH)
	_db_init_failed = true
	return false


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
		release_date INTEGER DEFAULT 0,
			siblings TEXT DEFAULT '[]',
			selected_sibling_id INTEGER DEFAULT 0,
			is_master_entry INTEGER DEFAULT 1,
			downloaded_sibling_ids TEXT DEFAULT '[]',
			has_cover_art INTEGER DEFAULT 1,
		last_played TEXT DEFAULT '',
		status TEXT DEFAULT '',
		now_playing INTEGER DEFAULT 0,
		backlogged INTEGER DEFAULT 0,
		hidden INTEGER DEFAULT 0,
		is_favorite INTEGER DEFAULT 0,
		title_id TEXT DEFAULT '',
			save_id TEXT DEFAULT '',
			save_usage TEXT DEFAULT '',
		cover_group_id TEXT DEFAULT '',
		cover_group_master INTEGER DEFAULT 1,
		igdb_metadata TEXT DEFAULT '{}',
		igdb_id INTEGER DEFAULT 0,
		m3u_path TEXT DEFAULT '',
		unwrapped INTEGER DEFAULT 0
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

	# Normalized filter values derived from IGDB metadata (genres, game modes,
	# age ratings) so library filtering uses indexed lookups instead of JSON scans.
	query_bool("""
		CREATE TABLE IF NOT EXISTS game_filter_values (
			game_id INTEGER NOT NULL,
			kind TEXT NOT NULL,
			value TEXT NOT NULL,
			PRIMARY KEY (game_id, kind, value)
		)
	""")
	query_bool("CREATE INDEX IF NOT EXISTS idx_gfv_kind_value ON game_filter_values(kind, value)")

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
		slot TEXT,
		local_hash TEXT DEFAULT '',
		server_hash TEXT DEFAULT '',
		local_size INTEGER DEFAULT 0
	)
	""")
	query_bool("CREATE INDEX IF NOT EXISTS idx_save_sync_romm_emulator ON save_sync(romm_id, emulator_id)")

	# Collections synced from RomM
	query_bool("""
		CREATE TABLE IF NOT EXISTS collections (
			romm_id INTEGER PRIMARY KEY,
			name TEXT NOT NULL,
			description TEXT,
			is_public INTEGER DEFAULT 0,
			is_favorite INTEGER DEFAULT 0,
			rom_count INTEGER DEFAULT 0,
			updated_at TEXT DEFAULT ''
		)
	""")

	# Many-to-many link between collections and ROMs
	query_bool("""
		CREATE TABLE IF NOT EXISTS collection_roms (
			collection_id INTEGER NOT NULL,
			romm_id INTEGER NOT NULL,
			PRIMARY KEY (collection_id, romm_id),
			FOREIGN KEY (collection_id) REFERENCES collections(romm_id) ON DELETE CASCADE
		)
	""")
	query_bool("CREATE INDEX IF NOT EXISTS idx_collection_roms_collection ON collection_roms(collection_id)")
	query_bool("CREATE INDEX IF NOT EXISTS idx_collection_roms_romm ON collection_roms(romm_id)")

	# Queued RomM user-prop writes that failed (offline etc.) and retry on reconnect.
	# kind: "props" (PUT /roms/{id}/props) or "fav" (favourites collection membership)
	query_bool("""
		CREATE TABLE IF NOT EXISTS pending_props_sync (
			romm_id INTEGER NOT NULL,
			kind TEXT NOT NULL,
			payload TEXT DEFAULT '{}',
			queued_at TEXT DEFAULT '',
			PRIMARY KEY (romm_id, kind)
		)
	""")


func is_database_ready() -> bool:
	return _is_db_ready


func is_database_init_failed() -> bool:
	return _db_init_failed


func _escape_sql(text: String) -> String:
	return text.replace("'", "''")


func invalidate_downloaded_games_count_cache() -> void:
	"""Invalidate the cached downloaded-games count so the next query reads fresh data."""
	_downloaded_games_count_cache = -1
	_platforms_with_games_cache_valid = false
	_platforms_with_games_cache.clear()
	_filter_options_cache_valid = false
	_filter_options_cache.clear()


## True when the downloaded-games count is already cached, so a synchronous
## call won't trigger a full-table scan on the caller's thread.
func has_cached_downloaded_count() -> bool:
	return _downloaded_games_count_cache >= 0


func _should_hide_no_cover_games() -> bool:
	var setting = DataManager.get_setting("hide_games_without_covers")
	if setting:
		return setting.value
	return true


func _should_fold_romm_siblings() -> bool:
	var setting = DataManager.get_setting("fold_romm_siblings")
	if setting:
		return setting.value
	return true


func _get_has_cover_art_clause() -> String:
	return " AND has_cover_art = 1" if _should_hide_no_cover_games() else ""


func _get_is_master_entry_clause() -> String:
	return " AND is_master_entry = 1" if _should_fold_romm_siblings() else ""


# ==================== LIBRARY FILTERS ====================

const FILTER_KINDS := ["genre", "game_mode", "esrb", "pegi", "flag", "status"]

## Play-state flag chips map to live per-user columns on games (whitelist).
## Filtered directly instead of via game_filter_values since they change
## without a re-sync (favorite toggles, RomM props sync).
const FILTER_FLAG_COLUMNS := {
	"Favorites": "is_favorite",
	"Now Playing": "now_playing",
	"Backlogged": "backlogged",
	"Hidden": "hidden",
}

## Rebuild the normalized filter rows for a game from its genres + IGDB blob.
## Caller must already hold the DB lock (used inside sync transactions).
func replace_game_filter_values_unlocked(game: GameResource) -> void:
	query_bool_unlocked("DELETE FROM game_filter_values WHERE game_id = ?", [game.romm_id])
	var insert_sql := "INSERT OR IGNORE INTO game_filter_values (game_id, kind, value) VALUES (?, ?, ?)"
	if game.igdb_metadata is Dictionary:
		# Genres come from the IGDB blob, not the genres column: RomM merges
		# multiple scraper taxonomies into the column (147 messy values),
		# while the IGDB list is the clean canonical 23.
		var genres = game.igdb_metadata.get("genres", [])
		if genres is Array:
			for genre in genres:
				if genre is String and genre != "":
					query_bool_unlocked(insert_sql, [game.romm_id, "genre", genre])
		var modes = game.igdb_metadata.get("game_modes", [])
		if modes is Array:
			for mode in modes:
				if mode is String and mode != "":
					query_bool_unlocked(insert_sql, [game.romm_id, "game_mode", mode])
		var ratings = game.igdb_metadata.get("age_ratings", [])
		if ratings is Array:
			for rating in ratings:
				if rating is Dictionary:
					var category := str(rating.get("category", ""))
					var value := str(rating.get("rating", ""))
					if value == "":
						continue
					if category == "ESRB":
						query_bool_unlocked(insert_sql, [game.romm_id, "esrb", value])
					elif category == "PEGI":
						query_bool_unlocked(insert_sql, [game.romm_id, "pegi", value])


## Builds [sql_clause, bindings] for active library filters.
## Filter shape: {kind: {"include": [...], "exclude": [...]}}.
## Includes OR within a kind; excludes reject any match; kinds AND together.
## Clauses reference the games table unaliased, matching the library query
## functions below.
func _get_filter_clause(filters: Dictionary) -> Array:
	var clause := ""
	var bindings: Array = []
	for kind in FILTER_KINDS:
		var spec = filters.get(kind, {})
		if not spec is Dictionary:
			continue
		var include: Array = spec.get("include", [])
		var exclude: Array = spec.get("exclude", [])
		if kind == "flag":
			var inc_flags: Array[String] = []
			var exc_flags: Array[String] = []
			for value in include:
				var column = FILTER_FLAG_COLUMNS.get(str(value), "")
				if column != "":
					inc_flags.append("games.%s = 1" % column)
			for value in exclude:
				var column = FILTER_FLAG_COLUMNS.get(str(value), "")
				if column != "":
					exc_flags.append("games.%s = 0" % column)
			if not inc_flags.is_empty():
				clause += " AND (%s)" % " OR ".join(inc_flags)
			if not exc_flags.is_empty():
				clause += " AND (%s)" % " AND ".join(exc_flags)
		elif kind == "status":
			if not include.is_empty():
				clause += " AND games.status IN (%s)" % ", ".join(include.map(func(_v): return "?"))
				bindings.append_array(include)
			if not exclude.is_empty():
				clause += " AND games.status NOT IN (%s)" % ", ".join(exclude.map(func(_v): return "?"))
				bindings.append_array(exclude)
		else:
			if not include.is_empty():
				var placeholders = ", ".join(include.map(func(_v): return "?"))
				clause += " AND EXISTS (SELECT 1 FROM game_filter_values gfv WHERE gfv.game_id = games.romm_id AND gfv.kind = ? AND gfv.value IN (%s))" % placeholders
				bindings.append(kind)
				bindings.append_array(include)
			if not exclude.is_empty():
				var ex_placeholders = ", ".join(exclude.map(func(_v): return "?"))
				clause += " AND NOT EXISTS (SELECT 1 FROM game_filter_values gfv WHERE gfv.game_id = games.romm_id AND gfv.kind = ? AND gfv.value IN (%s))" % ex_placeholders
				bindings.append(kind)
				bindings.append_array(exclude)
	return [clause, bindings]


## Distinct filter values present in the visible library, keyed by kind.
## Cached in memory; invalidated alongside the platforms/count caches.
func get_filter_options() -> Dictionary:
	if _filter_options_cache_valid:
		return _filter_options_cache.duplicate(true)
	var options: Dictionary = {}
	for kind in FILTER_KINDS:
		options[kind] = []
	if not _is_db_ready:
		return options
	var cover_clause = _get_has_cover_art_clause().replace("has_cover_art", "g.has_cover_art")
	var master_clause = _get_is_master_entry_clause().replace("is_master_entry", "g.is_master_entry")
	var query = "SELECT DISTINCT gfv.kind, gfv.value FROM game_filter_values gfv JOIN games g ON g.romm_id = gfv.game_id WHERE 1=1" + master_clause + cover_clause + " AND g.cover_group_master = 1 ORDER BY gfv.value ASC"
	for row in query_array(query):
		var kind := str(row.get("kind", ""))
		if options.has(kind):
			options[kind].append(str(row.get("value", "")))
	# Play states come from live games columns, not the normalized table.
	options["flag"] = FILTER_FLAG_COLUMNS.keys()
	var status_query = "SELECT DISTINCT g.status FROM games g WHERE g.status != ''" + master_clause + cover_clause + " AND g.cover_group_master = 1 ORDER BY g.status ASC"
	for row in query_array(status_query):
		options["status"].append(str(row.get("status", "")))
	_filter_options_cache = options.duplicate(true)
	_filter_options_cache_valid = true
	return options


func count_folded_sibling_entries() -> int:
	"""Number of library entries currently hidden by RomM sibling folding."""
	if not is_database_ready():
		return 0
	var result = query_array("SELECT COUNT(*) as count FROM games WHERE is_master_entry = 0")
	if result.size() > 0:
		return result[0].get("count", 0)
	return 0


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
	# NOTE: no "or 0" coalesce here — GDScript's "or" returns a bool, so
	# "value or 0" evaluates to true and int(true) = 1 for any nonzero value.
	var release_date_value = row.get("release_date", 0)
	game.release_date = int(release_date_value) if release_date_value != null else 0
	var igdb_id_value = row.get("igdb_id", 0)
	game.igdb_id = int(igdb_id_value) if igdb_id_value != null else 0

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

	# Restore present-wrap state
	game.unwrapped = row.get("unwrapped", 0) == 1

	# Restore RomM per-user play state
	game.status = row.get("status", "")
	game.now_playing = row.get("now_playing", 0) == 1
	game.backlogged = row.get("backlogged", 0) == 1
	game.hidden = row.get("hidden", 0) == 1
	game.is_favorite = row.get("is_favorite", 0) == 1

	# Restore title_id
	game.title_id = row.get("title_id", "")

	# Restore sigil save identity
	game.save_id = row.get("save_id", "")
	game.save_usage = row.get("save_usage", "")

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

	# Restore m3u playlist path
	game.m3u_path = row.get("m3u_path", "")

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
	var setting = DataManager.get_setting("enabled_platforms")
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

	var root_folder_setting = DataManager.get_setting("games_root_folder")
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
		full_path = FSM.join_paths(root_path, sub_path)

	var entries = FSM.list_dir(full_path)
	if entries.is_empty() and not FSM.dir_exists(full_path):
		return

	for file_name in entries:
		if file_name == "." or file_name == "..":
			continue

		var current_path = sub_path
		if current_path != "":
			current_path += "/"
		current_path += file_name

		var child_full_path = FSM.join_paths(full_path, file_name)
		if FSM.is_dir(child_full_path):
			# Recurse into subdirectory
			_scan_games_directory(root_path, current_path, results)
		else:
			# It's a file - add to results
			results.append(current_path)


func _update_matched_games_in_db(matched_games: Dictionary, callback: Callable) -> void:
	"""Update database entries for matched games."""
	print("[DEBUG] _update_matched_games_in_db called with %d matched games" % matched_games.size())
	# Scan results change has_local_copy / downloaded_sibling_ids.
	invalidate_downloaded_games_count_cache()
	MemorySubManager.queue_db_task(
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
	MemorySubManager.queue_db_task(
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
			query_bool_unlocked("DELETE FROM game_filter_values WHERE game_id IN (SELECT romm_id FROM games WHERE platform_slug = ?)", [platform_slug])
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
					if FSM.file_exists(cache_path):
						if FSM.delete_file(cache_path):
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

func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	invalidate_downloaded_games_count_cache()

	MemorySubManager.queue_db_task(
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
				release_date = ?,
				siblings = ?,
					selected_sibling_id = ?,
					is_master_entry = ?,
					downloaded_sibling_ids = ?,
					has_cover_art = ?,
				last_played = ?,
				title_id = ?,
				save_id = ?,
				save_usage = ?,
		cover_group_id = ?,
		cover_group_master = ?,
		igdb_metadata = ?,
		igdb_id = ?,
		m3u_path = ?
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
			game.release_date,
			JSON.stringify(game.siblings),
				game.selected_sibling_id,
				1 if game.is_master_entry else 0,
				JSON.stringify(game.downloaded_sibling_ids),
				1 if game.has_cover_art else 0,
			game.last_played,
			game.title_id,
			game.save_id,
			game.save_usage,
		game.cover_group_id,
			1 if game.cover_group_master else 0,
	JSON.stringify(game.igdb_metadata),
	game.igdb_id,
	game.m3u_path,
	game.romm_id
]
			var success = query_bool_unlocked(query, bindings)
			if success:
				replace_game_filter_values_unlocked(game)
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

	MemorySubManager.queue_db_task(
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


func update_game_save_info(romm_id: int, save_id: String, save_usage: String, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	MemorySubManager.queue_db_task(
		func():
			_db_lock()
			var success = query_bool_unlocked("UPDATE games SET save_id = ?, save_usage = ? WHERE romm_id = ?", [save_id, save_usage, romm_id])
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

	MemorySubManager.queue_db_task(
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


func update_game_m3u_path(romm_id: int, m3u_path: String, callback: Callable = Callable()) -> bool:
	if not _is_db_ready:
		return false

	MemorySubManager.queue_db_task(
		func():
			_db_lock()
			var success = query_bool_unlocked("UPDATE games SET m3u_path = ? WHERE romm_id = ?", [m3u_path, romm_id])
			_db_unlock()
			return success,

		func(success: bool):
			if callback.is_valid():
				callback.call(success)
	)
	return true


func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	"""Update the last_played timestamp for a game."""
	if not _is_db_ready:
		return false

	return query_bool("UPDATE games SET last_played = ? WHERE romm_id = ?", [timestamp, romm_id])


func update_game_unwrapped(romm_id: int, unwrapped: bool) -> bool:
	"""Update the present-wrap unwrapped flag for a game."""
	if not _is_db_ready:
		return false

	return query_bool("UPDATE games SET unwrapped = ? WHERE romm_id = ?", [1 if unwrapped else 0, romm_id])


## Whitelist of user-prop columns that update_game_user_props may write.
const USER_PROP_COLUMNS := {
	"status": "status",
	"now_playing": "now_playing",
	"backlogged": "backlogged",
	"hidden": "hidden",
	"is_favorite": "is_favorite",
	"last_played": "last_played",
}

func update_game_user_props(romm_id: int, props: Dictionary) -> bool:
	"""Update one or more RomM per-user prop columns for a game.
	props keys: status, now_playing, backlogged, hidden, is_favorite, last_played"""
	if not _is_db_ready or props.is_empty():
		return false

	var sets: Array[String] = []
	var bindings: Array = []
	for key in props.keys():
		if not USER_PROP_COLUMNS.has(key):
			continue
		var value = props[key]
		if value == null:
			value = ""
		elif value is bool:
			value = 1 if value else 0
		sets.append(USER_PROP_COLUMNS[key] + " = ?")
		bindings.append(value)

	if sets.is_empty():
		return false

	bindings.append(romm_id)
	_filter_options_cache_valid = false
	_filter_options_cache.clear()
	return query_bool("UPDATE games SET %s WHERE romm_id = ?" % ", ".join(sets), bindings)


func set_all_favorites(favorite_romm_ids: Array) -> bool:
	"""Reset is_favorite for all games, then mark the given romm_ids as favorites."""
	if not _is_db_ready:
		return false
	_filter_options_cache_valid = false
	_filter_options_cache.clear()
	var success = query_bool("UPDATE games SET is_favorite = 0", [])
	if favorite_romm_ids.is_empty():
		return success
	var placeholders: Array[String] = []
	for id in favorite_romm_ids:
		placeholders.append("?")
	success = query_bool("UPDATE games SET is_favorite = 1 WHERE romm_id IN (%s)" % ",".join(placeholders), favorite_romm_ids) and success
	return success


# ==================== PENDING PROPS SYNC QUEUE ====================

func queue_pending_props(romm_id: int, kind: String, payload: Dictionary) -> bool:
	"""Queue a failed RomM user-prop write for retry (latest state wins per rom+kind)."""
	if not _is_db_ready:
		return false
	var timestamp = Time.get_datetime_string_from_system(false, true)
	return query_bool(
		"INSERT OR REPLACE INTO pending_props_sync (romm_id, kind, payload, queued_at) VALUES (?, ?, ?, ?)",
		[romm_id, kind, JSON.stringify(payload), timestamp]
	)


func get_pending_props_sync() -> Array[Dictionary]:
	"""Return all queued writes: [{romm_id, kind, payload}, ...] oldest first."""
	var result: Array[Dictionary] = []
	if not _is_db_ready:
		return result
	var rows = query_array("SELECT romm_id, kind, payload FROM pending_props_sync ORDER BY queued_at ASC")
	for row in rows:
		var json = JSON.new()
		var payload: Dictionary = {}
		if json.parse(str(row.get("payload", "{}"))) == OK and json.data is Dictionary:
			payload = json.data
		result.append({
			"romm_id": int(row.get("romm_id", 0)),
			"kind": str(row.get("kind", "")),
			"payload": payload,
		})
	return result


func clear_pending_props(romm_id: int, kind: String) -> bool:
	if not _is_db_ready:
		return false
	return query_bool("DELETE FROM pending_props_sync WHERE romm_id = ? AND kind = ?", [romm_id, kind])


func get_game_by_id(romm_id: int) -> GameResource:
	if not _is_db_ready:
		return null
	var query_result = query_array("SELECT * FROM games WHERE romm_id = ?", [romm_id])
	if query_result.size() > 0:
		return _row_to_game(query_result[0])
	return null


## Map IGDB ids to library games: {igdb_id: romm_id} for ids present in the
## library. Used by the details sheet to link related games to owned entries.
func get_games_by_igdb_ids(igdb_ids: Array) -> Dictionary:
	var result: Dictionary = {}
	if not _is_db_ready or igdb_ids.is_empty():
		return result
	var placeholders = ", ".join(igdb_ids.map(func(_id): return "?"))
	var rows = query_array("SELECT igdb_id, romm_id FROM games WHERE igdb_id IN (%s)" % placeholders, igdb_ids)
	for row in rows:
		var igdb_id = row.get("igdb_id", 0)
		if igdb_id != null and int(igdb_id) > 0:
			result[int(igdb_id)] = int(row.get("romm_id", 0))
	return result


## Title fallback for related games whose library entry has no igdb_id.
## Returns {lower_title: romm_id} for exact (case-insensitive) matches.
func get_games_by_titles(titles: Array) -> Dictionary:
	var result: Dictionary = {}
	if not _is_db_ready or titles.is_empty():
		return result
	var placeholders = ", ".join(titles.map(func(_t): return "?"))
	var bindings = titles.map(func(t): return str(t).to_lower())
	var rows = query_array("SELECT LOWER(title) AS ltitle, romm_id FROM games WHERE LOWER(title) IN (%s)" % placeholders, bindings)
	for row in rows:
		result[str(row.get("ltitle", ""))] = int(row.get("romm_id", 0))
	return result


func get_all_games() -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var query_result = query_array("SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 ORDER BY title")
	for row in query_result:
		games.append(_row_to_game(row))
	return games


func get_games_by_platform(platform_slug: String, filters: Dictionary = {}) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var filter_parts: Array = _get_filter_clause(filters)
	var query = "SELECT * FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1 ORDER BY title"
	var query_result = query_array(query, [platform_slug] + filter_parts[1])
	for row in query_result:
		games.append(_row_to_game(row))
	return games


func get_games_paginated(offset: int, limit: int, sort_field: String = "title", ascending: bool = true, platform_slug: String = "", filters: Dictionary = {}) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games

	# Whitelist allowed sort fields to prevent SQL injection
	var allowed_sort_fields = {"title": true, "romm_id": true, "rating": true, "last_played": true, "platform": true}
	var safe_sort_field = sort_field if allowed_sort_fields.has(sort_field) else "title"
	var order = "ASC" if ascending else "DESC"
	var filter_parts: Array = _get_filter_clause(filters)
	var query: String
	var bindings: Array = []

	if platform_slug.is_empty():
		query = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1 ORDER BY %s %s LIMIT ? OFFSET ?" % [safe_sort_field, order]
		bindings = filter_parts[1] + [limit, offset]
	else:
		query = "SELECT * FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1 ORDER BY %s %s LIMIT ? OFFSET ?" % [safe_sort_field, order]
		bindings = [platform_slug] + filter_parts[1] + [limit, offset]

	var query_result = query_array(query, bindings)

	for row in query_result:
		games.append(_row_to_game(row))
	return games


func get_platforms_with_games() -> Array[Dictionary]:
	"""Get list of platforms that have games, sorted alphabetically with game counts."""
	if _platforms_with_games_cache_valid:
		return _platforms_with_games_cache.duplicate(true)
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

	_platforms_with_games_cache = platforms.duplicate(true)
	_platforms_with_games_cache_valid = true
	return platforms


func get_total_games_count(platform_slug: String = "", filters: Dictionary = {}) -> int:
	if not _is_db_ready:
		return 0

	var filter_parts: Array = _get_filter_clause(filters)
	var query: String
	var bindings: Array = []
	if platform_slug.is_empty():
		query = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1"
		bindings = filter_parts[1]
	else:
		query = "SELECT COUNT(*) as count FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1"
		bindings = [platform_slug] + filter_parts[1]

	var query_result = query_array(query, bindings)
	if query_result.size() > 0:
		var result = query_result
		if result != null and result.size() > 0:
			var row = result[0]
			if row != null and row.has("count"):
				return int(row["count"])
	return 0


func search_games_paginated(query: String, offset: int, limit: int, filters: Dictionary = {}) -> Array[GameResource]:
	"""Search games by title with pagination."""
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games

	var pattern = "%" + query + "%"
	var filter_parts: Array = _get_filter_clause(filters)
	var sql = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1 AND title LIKE ? ORDER BY title ASC LIMIT ? OFFSET ?"

	var query_result = query_array(sql, filter_parts[1] + [pattern, limit, offset])
	for row in query_result:
		games.append(_row_to_game(row))

	return games


func get_search_results_count(query: String, filters: Dictionary = {}) -> int:
	"""Get count of search results."""
	if not _is_db_ready:
		return 0

	var pattern = "%" + query + "%"
	var filter_parts: Array = _get_filter_clause(filters)
	var sql = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1 AND title LIKE ?"

	var query_result = query_array(sql, filter_parts[1] + [pattern])
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


# ==================== COLLECTIONS ====================

func save_collection(collection: Dictionary) -> void:
	"""Insert or update a collection synced from RomM."""
	if not _is_db_ready:
		return
	query_bool("""
		INSERT OR REPLACE INTO collections (romm_id, name, description, is_public, is_favorite, rom_count, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	""", [
		collection.get("id", 0),
		collection.get("name", ""),
		collection.get("description", ""),
		1 if collection.get("is_public", false) else 0,
		1 if collection.get("is_favorite", false) else 0,
		collection.get("rom_count", 0),
		collection.get("updated_at", "")
	])


func clear_collection_roms(collection_id: int) -> void:
	"""Remove all ROM links for a collection."""
	if not _is_db_ready:
		return
	query_bool("DELETE FROM collection_roms WHERE collection_id = ?", [collection_id])


func remove_collection_rom(collection_id: int, romm_id: int) -> void:
	"""Remove a single ROM link from a collection."""
	if not _is_db_ready:
		return
	query_bool("DELETE FROM collection_roms WHERE collection_id = ? AND romm_id = ?", [collection_id, romm_id])


func get_favorite_collection_id() -> int:
	"""Return the romm_id of the user's favorite collection (is_favorite=1), or 0."""
	if not _is_db_ready:
		return 0
	var query_result = query_array("SELECT romm_id FROM collections WHERE is_favorite = 1 LIMIT 1")
	if query_result.size() > 0:
		return int(query_result[0].get("romm_id", 0))
	return 0


func add_collection_roms(collection_id: int, rom_ids: Array) -> void:
	"""Link ROMs to a collection."""
	if not _is_db_ready:
		return
	if rom_ids.is_empty():
		return
	_db_lock()
	for rom_id in rom_ids:
		query_bool_unlocked("INSERT OR IGNORE INTO collection_roms (collection_id, romm_id) VALUES (?, ?)", [collection_id, rom_id])
	_db_unlock()


func clear_all_collections() -> void:
	"""Delete all collections and their ROM links (used before a full re-sync)."""
	if not _is_db_ready:
		return
	query_bool("DELETE FROM collection_roms")
	query_bool("DELETE FROM collections")


func delete_collection(romm_id: int) -> void:
	"""Delete a collection and its ROM links."""
	if not _is_db_ready:
		return
	query_bool("DELETE FROM collection_roms WHERE collection_id = ?", [romm_id])
	query_bool("DELETE FROM collections WHERE romm_id = ?", [romm_id])


func get_collections() -> Array[Dictionary]:
	var collections: Array[Dictionary] = []
	if not _is_db_ready:
		return collections
	var query_result = query_array("SELECT * FROM collections ORDER BY name COLLATE NOCASE")
	for row in query_result:
		collections.append({
			"id": row.get("romm_id", 0),
			"name": row.get("name", ""),
			"description": row.get("description", ""),
			"is_public": row.get("is_public", 0) == 1,
			"is_favorite": row.get("is_favorite", 0) == 1,
			"rom_count": row.get("rom_count", 0),
			"updated_at": row.get("updated_at", "")
		})
	return collections


func get_collection(romm_id: int) -> Dictionary:
	if not _is_db_ready:
		return {}
	var query_result = query_array("SELECT * FROM collections WHERE romm_id = ?", [romm_id])
	if query_result.size() > 0:
		var row = query_result[0]
		return {
			"id": row.get("romm_id", 0),
			"name": row.get("name", ""),
			"description": row.get("description", ""),
			"is_public": row.get("is_public", 0) == 1,
			"is_favorite": row.get("is_favorite", 0) == 1,
			"rom_count": row.get("rom_count", 0),
			"updated_at": row.get("updated_at", "")
		}
	return {}


func get_romm_ids_for_collection(romm_id: int) -> Array[int]:
	var rom_ids: Array[int] = []
	if not _is_db_ready:
		return rom_ids
	var query_result = query_array("SELECT romm_id FROM collection_roms WHERE collection_id = ?", [romm_id])
	for row in query_result:
		rom_ids.append(int(row.get("romm_id", 0)))
	return rom_ids


func get_collection_ids_for_rom(romm_id: int) -> Array[int]:
	"""Return ids of collections that already contain this ROM."""
	var collection_ids: Array[int] = []
	if not _is_db_ready:
		return collection_ids
	var query_result = query_array("SELECT collection_id FROM collection_roms WHERE romm_id = ?", [romm_id])
	for row in query_result:
		collection_ids.append(int(row.get("collection_id", 0)))
	return collection_ids


func get_games_for_collection_count(romm_id: int) -> int:
	"""Count how many synced games are in this collection."""
	if not _is_db_ready:
		return 0
	var query = """
		SELECT COUNT(*) as count FROM games g
		INNER JOIN collection_roms cr ON g.romm_id = cr.romm_id
		WHERE cr.collection_id = ?
	""" + _get_is_master_entry_clause().replace("games", "g") + _get_has_cover_art_clause().replace("games", "g") + " AND g.cover_group_master = 1"
	var query_result = query_array(query, [romm_id])
	if query_result.size() > 0 and query_result[0].has("count"):
		return int(query_result[0]["count"])
	return 0


func get_games_for_collection_paginated(romm_id: int, offset: int, limit: int, sort_field: String = "title", ascending: bool = true) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games

	var allowed_sort_fields = {"title": true, "romm_id": true, "rating": true, "last_played": true, "platform": true}
	var safe_sort_field = sort_field if allowed_sort_fields.has(sort_field) else "title"
	var order = "ASC" if ascending else "DESC"
	var query = """
		SELECT g.* FROM games g
		INNER JOIN collection_roms cr ON g.romm_id = cr.romm_id
		WHERE cr.collection_id = ?
	""" + _get_is_master_entry_clause().replace("games", "g") + _get_has_cover_art_clause().replace("games", "g") + " AND g.cover_group_master = 1 ORDER BY g.%s %s LIMIT ? OFFSET ?" % [safe_sort_field, order]
	var query_result = query_array(query, [romm_id, limit, offset])
	for row in query_result:
		games.append(_row_to_game(row))
	return games


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
