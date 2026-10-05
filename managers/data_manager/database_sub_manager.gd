extends Manager
class_name DatabaseSubManager

var data_manager: Node

const DB_PATH = "user://database/kyodai.db"
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Expected schema (table -> column -> DDL fragment). Single source of truth for
## ensure_schema_alignment(), which ALTERs in missing columns at DB open.
## A stale DB schema otherwise fails every affected statement (logged only).
const _EXPECTED_SCHEMA := {
	"games": {
		"id": "TEXT PRIMARY KEY", "romm_id": "INTEGER UNIQUE NOT NULL", "title": "TEXT NOT NULL",
		"platform": "TEXT", "platform_slug": "TEXT", "cover_url": "TEXT", "cover_path": "TEXT",
		"file_name": "TEXT", "file_path": "TEXT", "file_size": "INTEGER DEFAULT 0",
		"has_local_copy": "INTEGER DEFAULT 0", "last_updated": "TEXT", "description": "TEXT",
		"genres": "TEXT", "rating": "REAL DEFAULT 0.0", "release_date": "INTEGER DEFAULT 0",
		"siblings": "TEXT DEFAULT '[]'", "selected_sibling_id": "INTEGER DEFAULT 0",
		"is_master_entry": "INTEGER DEFAULT 1", "downloaded_sibling_ids": "TEXT DEFAULT '[]'",
		"has_cover_art": "INTEGER DEFAULT 1", "last_played": "TEXT DEFAULT ''",
		"status": "TEXT DEFAULT ''", "now_playing": "INTEGER DEFAULT 0",
		"backlogged": "INTEGER DEFAULT 0", "hidden": "INTEGER DEFAULT 0",
		"hidden_from_home": "INTEGER DEFAULT 0",
		"is_favorite": "INTEGER DEFAULT 0", "title_id": "TEXT DEFAULT ''",
		"save_id": "TEXT DEFAULT ''", "save_usage": "TEXT DEFAULT ''",
		"cover_group_id": "TEXT DEFAULT ''", "cover_group_master": "INTEGER DEFAULT 1",
		"igdb_metadata": "TEXT DEFAULT '{}'", "igdb_id": "INTEGER DEFAULT 0",
		"m3u_path": "TEXT DEFAULT ''", "unwrapped": "INTEGER DEFAULT 0",
		"screenshots": "TEXT DEFAULT '[]'",
	},
	"platforms": {
		"id": "TEXT PRIMARY KEY", "romm_id": "INTEGER UNIQUE NOT NULL", "name": "TEXT NOT NULL",
		"slug": "TEXT UNIQUE NOT NULL", "icon_url": "TEXT", "icon_path": "TEXT",
		"emulator_path": "TEXT", "extensions": "TEXT",
	},
	"game_filter_values": {"game_id": "INTEGER NOT NULL", "kind": "TEXT NOT NULL", "value": "TEXT NOT NULL"},
	"cache_metadata": {"key": "TEXT PRIMARY KEY", "value": "TEXT"},
	"save_sync": {
		"id": "INTEGER PRIMARY KEY", "romm_id": "INTEGER NOT NULL", "emulator_id": "TEXT NOT NULL",
		"file_name": "TEXT NOT NULL", "file_path": "TEXT NOT NULL", "last_synced_at": "TEXT DEFAULT ''",
		"remote_save_id": "INTEGER DEFAULT 0", "slot": "TEXT", "local_hash": "TEXT DEFAULT ''",
		"server_hash": "TEXT DEFAULT ''", "local_size": "INTEGER DEFAULT 0",
	},
	"collections": {
		"romm_id": "INTEGER PRIMARY KEY", "name": "TEXT NOT NULL", "description": "TEXT DEFAULT ''",
		"is_public": "INTEGER DEFAULT 0", "is_favorite": "INTEGER DEFAULT 0",
		"rom_count": "INTEGER DEFAULT 0", "updated_at": "TEXT DEFAULT ''",
	},
	"collection_roms": {"collection_id": "INTEGER NOT NULL", "romm_id": "INTEGER NOT NULL"},
	"pending_props_sync": {
		"romm_id": "INTEGER NOT NULL", "kind": "TEXT NOT NULL",
		"payload": "TEXT DEFAULT '{}'", "queued_at": "TEXT DEFAULT ''",
	},
}

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


## Logs failed SQL statements even when SQLite verbosity is QUIET. Silent
## statement failures (e.g. a column missing from a stale schema) have caused
## data-loss class bugs where writes simply never landed.
func _log_query_failure(query: String) -> void:
	var detail := ""
	if _db:
		var msg = _db.get("error_message")
		if msg != null and str(msg) != "":
			detail = " | error: " + str(msg)
	push_error("[DatabaseManager] SQL FAILED: " + query.strip_edges().substr(0, 120).replace("\n", " ") + detail)


func query_array(query: String, bindings: Array = []) -> Array:
	_db_lock()
	var result: Array
	var success: bool
	if bindings.is_empty():
		success = _db.query(query)
	else:
		success = _db.query_with_bindings(query, bindings)
	result = _db.query_result.duplicate() if success else []
	if not success:
		_log_query_failure(query)
	_db_unlock()
	return result


## Timeout for query_array_async. Only reachable when the DB task queue
## drops a task without invoking its callback (app-shutdown paths). Cold
## ORDER BY RANDOM() over large libraries can exceed 5 s on slow storage.
const QUERY_ASYNC_TIMEOUT_MSEC := 15000

## Materializes a query result on the DB worker thread and awaits it back on
## the caller's (main) thread. Same locking as query_array, but building the
## result set + duplicate() - tens of thousands of rows for shuffle queries -
## never blocks a frame. Returns [] when the DB is not ready or the wait
## times out.
func query_array_async(query: String, bindings: Array = []) -> Array:
	if not _is_db_ready:
		return []
	var holder := {"rows": [] as Array, "done": false}
	MemorySubManager.queue_db_task(
		func() -> Array:
			return query_array(query, bindings),
		func(result):
			holder["rows"] = result if result is Array else []
			holder["done"] = true
	)
	# The worker's callback is drained by MemorySubManager._process each frame;
	# poll rather than block the main thread.
	var deadline := Time.get_ticks_msec() + QUERY_ASYNC_TIMEOUT_MSEC
	while not holder["done"]:
		if Time.get_ticks_msec() > deadline:
			push_error("[DatabaseManager] query_array_async timed out")
			return []
		await get_tree().process_frame
	return holder["rows"]


func query_bool(query: String, bindings: Array = []) -> bool:
	_db_lock()
	var success: bool
	if bindings.is_empty():
		success = _db.query(query)
	else:
		success = _db.query_with_bindings(query, bindings)
	if not success:
		_log_query_failure(query)
	_db_unlock()
	return success


## Unlocked variants for use when caller already holds _db_mutex.
## Prevents deadlock on platforms with non-reentrant mutexes (Linux/Android).
func query_array_unlocked(query: String, bindings: Array = []) -> Array:
	var result: Array
	var success: bool
	if bindings.is_empty():
		success = _db.query(query)
	else:
		success = _db.query_with_bindings(query, bindings)
	result = _db.query_result.duplicate() if success else []
	if not success:
		_log_query_failure(query)
	return result


func query_bool_unlocked(query: String, bindings: Array = []) -> bool:
	var success: bool
	if bindings.is_empty():
		success = _db.query(query)
	else:
		success = _db.query_with_bindings(query, bindings)
	if not success:
		_log_query_failure(query)
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
		# Repair schema drift from older app versions immediately; waiting for
		# a full sync leaves every statement touching new columns broken.
		ensure_schema_alignment()
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
		hidden_from_home INTEGER DEFAULT 0,
		is_favorite INTEGER DEFAULT 0,
		title_id TEXT DEFAULT '',
			save_id TEXT DEFAULT '',
			save_usage TEXT DEFAULT '',
		cover_group_id TEXT DEFAULT '',
		cover_group_master INTEGER DEFAULT 1,
		igdb_metadata TEXT DEFAULT '{}',
		igdb_id INTEGER DEFAULT 0,
		m3u_path TEXT DEFAULT '',
		unwrapped INTEGER DEFAULT 0,
		screenshots TEXT DEFAULT '[]'
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
	query_bool("CREATE INDEX IF NOT EXISTS idx_games_last_played ON games(last_played)")

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

	# Audit trail for server-deletion reconciliation. Written inside the same
	# transaction as the deletes, so a rolled-back batch leaves no log rows.
	query_bool("""
		CREATE TABLE IF NOT EXISTS reconciliation_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			platform_slug TEXT NOT NULL,
			romm_id INTEGER NOT NULL,
			action TEXT NOT NULL,
			created_at TEXT NOT NULL
		)
	""")
	query_bool("CREATE INDEX IF NOT EXISTS idx_reconciliation_log_platform ON reconciliation_log(platform_slug)")


func is_database_ready() -> bool:
	return _is_db_ready


func is_database_init_failed() -> bool:
	return _db_init_failed


## Verifies every expected column exists and ALTERs in any that are missing.
## Called at DB open and at full-sync start: the DB is a cache, and a stale
## schema (e.g. from an older app version) makes every affected statement fail.
func ensure_schema_alignment() -> bool:
	if not _is_db_ready:
		return false
	var repaired: Array[String] = []
	_db_lock()
	for table in _EXPECTED_SCHEMA:
		var existing := {}
		for row in query_array_unlocked("PRAGMA table_info(" + table + ")"):
			existing[str(row.get("name", ""))] = true
		if existing.is_empty():
			continue  # Table absent entirely; CREATE TABLE IF NOT EXISTS covers fresh DBs
		for col in _EXPECTED_SCHEMA[table]:
			if not existing.has(col):
				if query_bool_unlocked("ALTER TABLE " + table + " ADD COLUMN " + col + " " + _EXPECTED_SCHEMA[table][col]):
					repaired.append(table + "." + col)
	_db_unlock()
	if not repaired.is_empty():
		push_warning("[DatabaseManager] Schema drift repaired - added missing columns: " + ", ".join(repaired))
		# May run on the DB worker thread; marshal the notification to the main thread.
		SystemManager.memory.queue_main_thread_callback(func():
			if SystemManager and SystemManager.notifications:
				SystemManager.notifications.show_notification("Database schema updated (" + str(repaired.size()) + " missing columns added)", SystemManager.notifications.Type.WARNING)
		)
	return true


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

const FILTER_KINDS := ["genre", "game_mode", "esrb", "pegi", "flag", "status", "company", "release_week"]

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
		for company in game.get_igdb_companies():
			if company != "":
				query_bool_unlocked(insert_sql, [game.romm_id, "company", company])


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
		elif kind == "release_week":
			# Values are the game's own release_date epoch-ms; match by calendar
			# week so the cohort is stable per week (vs a sliding ±3 day window).
			# NOTE: built via concatenation, never the % format operator — it
			# would choke on the literal %Y-%W inside the strftime pattern and
			# silently mangle the clause.
			var week_expr := "strftime('%Y-%W', ? / 1000, 'unixepoch')"
			if not include.is_empty():
				var in_parts: Array = []
				for _v in include:
					in_parts.append(week_expr)
				clause += " AND strftime('%Y-%W', games.release_date / 1000, 'unixepoch') IN (" + ", ".join(in_parts) + ")"
				bindings.append_array(include)
			if not exclude.is_empty():
				var ex_parts: Array = []
				for _v in exclude:
					ex_parts.append(week_expr)
				clause += " AND strftime('%Y-%W', games.release_date / 1000, 'unixepoch') NOT IN (" + ", ".join(ex_parts) + ")"
				bindings.append_array(exclude)
			if _verbose_sql:
				print("[DatabaseManager] release_week clause: ", clause, " bindings: ", bindings)
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
	var query = "SELECT DISTINCT gfv.kind, gfv.value FROM game_filter_values gfv JOIN games g ON g.romm_id = gfv.game_id WHERE 1=1 AND gfv.kind != 'company'" + master_clause + cover_clause + " AND g.cover_group_master = 1 ORDER BY gfv.value ASC"
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

	# Restore screenshot URLs
	if row.has("screenshots") and row["screenshots"] is String and row["screenshots"] != "":
		var json_shots = JSON.new()
		if json_shots.parse(row["screenshots"]) == OK and json_shots.data is Array:
			var shots: PackedStringArray = []
			for shot in json_shots.data:
				if shot is String:
					shots.append(shot)
			game.screenshot_urls = shots

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
	# Local-only Home hide; row.get default covers pre-migration schemas.
	game.hidden_from_home = row.get("hidden_from_home", 0) == 1
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

	# Scan results change has_local_copy / downloaded_sibling_ids.
	invalidate_downloaded_games_count_cache()

	# The whole pipeline (slim DB read, lookup build, filesystem scan, matching,
	# and the matched-row UPDATEs) runs as one DB-worker task, so the main
	# thread never materializes the library or blocks on directory IO.
	MemorySubManager.queue_db_task(
		func():
			return _scan_and_update_downloaded_games(root_folder),
		func(updated_count):
			# null when the queue dropped the task (overflow).
			if updated_count == null:
				updated_count = 0
			print("[DEBUG] Scan complete - updated %d games in DB" % updated_count)
			data_manager.scan_for_downloaded_games_completed.emit(updated_count)
			if callback.is_valid():
				callback.call(updated_count)
	)
	return


func _scan_and_update_downloaded_games(root_folder: String) -> int:
	"""DB worker: match downloaded files against the library and update rows.
	Reads only the columns matching needs; no GameResource materialization."""
	# Slim read: romm_id, platform_slug, file_name, siblings, downloaded ids.
	var rows = query_array("SELECT romm_id, platform_slug, file_name, siblings, downloaded_sibling_ids FROM games")
	if rows.is_empty():
		return 0

	# Build lookups: file -> romm_id, plus per-game sibling file -> sibling_id.
	var file_to_romm: Dictionary = {}
	var sibling_file_to_id: Dictionary = {}  # romm_id -> {file_name_lower: sibling_id}
	var main_file_lower: Dictionary = {}     # romm_id -> file_name.to_lower()
	var existing_dl_ids: Dictionary = {}     # romm_id -> Array (parsed JSON)

	for row in rows:
		var romm_id := int(row.get("romm_id", 0))
		var platform_slug := str(row.get("platform_slug", ""))
		var file_name := str(row.get("file_name", ""))
		if romm_id == 0:
			continue

		var sib_map: Dictionary = {}
		var json := JSON.new()
		if json.parse(str(row.get("siblings", "[]"))) == OK and json.data is Array:
			for sibling in json.data:
				if sibling is Dictionary:
					var sib_file := str(sibling.get("file_name", ""))
					var sib_id := int(sibling.get("id", 0))
					if sib_file != "" and sib_id != 0:
						sib_map[sib_file.to_lower()] = sib_id
						file_to_romm[platform_slug + "/" + sib_file.to_lower()] = romm_id
		sibling_file_to_id[romm_id] = sib_map

		if file_name != "":
			main_file_lower[romm_id] = file_name.to_lower()
			file_to_romm[platform_slug + "/" + file_name.to_lower()] = romm_id

		var ids: Array = []
		var id_json := JSON.new()
		if id_json.parse(str(row.get("downloaded_sibling_ids", "[]"))) == OK and id_json.data is Array:
			ids = id_json.data
		existing_dl_ids[romm_id] = ids

	# Filesystem scan on the worker: directory IO stays off the main thread.
	var found_files: Array[String] = []
	_scan_games_directory(root_folder, "", found_files)

	# Files with a sibling download-state file are interrupted/incomplete
	# downloads (possibly sparse pre-allocated) - never match them as present.
	var in_progress := {}
	for f in found_files:
		if f.ends_with(".kyodai_download"):
			in_progress[f.trim_suffix(".kyodai_download")] = true

	# Match files to games.
	var matched: Dictionary = {}  # romm_id -> {file_path: String, new_sibling_ids: Array}
	for file_path in found_files:
		if in_progress.has(file_path):
			continue

		var parts = file_path.split("/", false, 1)
		if parts.size() < 2:
			continue

		var lookup_key = parts[0] + "/" + parts[1].to_lower()
		if not file_to_romm.has(lookup_key):
			continue
		var romm_id: int = file_to_romm[lookup_key]
		if not matched.has(romm_id):
			matched[romm_id] = {"file_path": "", "new_sibling_ids": []}
		var file_lower: String = parts[1].to_lower()
		if main_file_lower.get(romm_id, "") == file_lower:
			# Main game file: record its full path.
			matched[romm_id].file_path = root_folder + "/" + file_path
		else:
			# Sibling file: record its sibling id if not already tracked.
			var sib_id := int(sibling_file_to_id[romm_id].get(file_lower, 0))
			if sib_id != 0 and not matched[romm_id].new_sibling_ids.has(sib_id) \
					and not existing_dl_ids[romm_id].has(sib_id):
				matched[romm_id].new_sibling_ids.append(sib_id)

	# Transactional update of all matched rows. file_path follows the legacy
	# behavior of writing "" when only sibling files matched.
	var updated_count := 0
	_db_lock()
	var tx_ok = query_bool_unlocked("BEGIN IMMEDIATE TRANSACTION")
	if tx_ok:
		for romm_id in matched.keys():
			var entry: Dictionary = matched[romm_id]
			var merged_ids: Array = existing_dl_ids[romm_id].duplicate()
			merged_ids.append_array(entry.new_sibling_ids)
			if query_bool_unlocked(
					"UPDATE games SET has_local_copy = 1, file_path = ?, downloaded_sibling_ids = ? WHERE romm_id = ?",
					[entry.file_path, JSON.stringify(merged_ids), romm_id]):
				updated_count += 1
			else:
				tx_ok = false
	if tx_ok:
		query_bool_unlocked("COMMIT")
	else:
		query_bool_unlocked("ROLLBACK")
		updated_count = 0
	_db_unlock()
	return updated_count


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
		func(result):
			# null when the queue dropped the task (overflow).
			if result == null:
				push_error("[Sync] Removal task dropped (DB queue overflow) for %s" % platform_slug)
				if callback.is_valid():
					callback.call(false)
				return
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
	m3u_path = ?,
	screenshots = ?
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
	JSON.stringify(Array(game.screenshot_urls)),
	game.romm_id
]
			var success = query_bool_unlocked(query, bindings)
			if success:
				replace_game_filter_values_unlocked(game)
			_db_unlock()
			return success,

		func(success):
			# null when the queue dropped the task (overflow).
			if success == null:
				success = false
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

		# success is null when the queue dropped the task (overflow).
		func(success):
			if success == null:
				success = false
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

		func(success):
			if success == null:
				success = false
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

		func(success):
			if success == null:
				success = false
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

		func(success):
			if success == null:
				success = false
			if callback.is_valid():
				callback.call(success)
	)
	return true


func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	"""Update the last_played timestamp for a game. Queued on the DB worker
	when called from the main thread; synchronous when already on it."""
	if not _is_db_ready:
		return false
	if MemorySubManager.is_db_thread():
		return query_bool("UPDATE games SET last_played = ? WHERE romm_id = ?", [timestamp, romm_id])
	MemorySubManager.queue_db_task(func():
		query_bool("UPDATE games SET last_played = ? WHERE romm_id = ?", [timestamp, romm_id]))
	return true


func update_game_unwrapped(romm_id: int, unwrapped: bool) -> bool:
	"""Update the present-wrap unwrapped flag for a game. Queued on the DB
	worker when called from the main thread; synchronous when already on it."""
	if not _is_db_ready:
		return false
	if MemorySubManager.is_db_thread():
		return query_bool("UPDATE games SET unwrapped = ? WHERE romm_id = ?", [1 if unwrapped else 0, romm_id])
	MemorySubManager.queue_db_task(func():
		query_bool("UPDATE games SET unwrapped = ? WHERE romm_id = ?", [1 if unwrapped else 0, romm_id]))
	return true


func update_game_hidden_from_home(romm_id: int, hidden_from_home: bool) -> bool:
	"""Update the local-only Home-hide flag for a game. Queued on the DB
	worker when called from the main thread; synchronous when already on it.
	Deliberately separate from update_game_user_props: this flag never syncs
	to RomM."""
	if not _is_db_ready:
		return false
	invalidate_downloaded_games_count_cache()
	if MemorySubManager.is_db_thread():
		return query_bool("UPDATE games SET hidden_from_home = ? WHERE romm_id = ?", [1 if hidden_from_home else 0, romm_id])
	MemorySubManager.queue_db_task(func():
		query_bool("UPDATE games SET hidden_from_home = ? WHERE romm_id = ?", [1 if hidden_from_home else 0, romm_id]))
	return true


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
	props keys: status, now_playing, backlogged, hidden, is_favorite, last_played.
	Queued on the DB worker when called from the main thread; synchronous when
	already on it (so worker-context batch flows keep their ordering)."""
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
	var query := "UPDATE games SET %s WHERE romm_id = ?" % ", ".join(sets)
	if MemorySubManager.is_db_thread():
		return query_bool(query, bindings)
	MemorySubManager.queue_db_task(func():
		query_bool(query, bindings))
	return true


func set_all_favorites(favorite_romm_ids: Array) -> bool:
	"""Reset is_favorite for all games, then mark the given romm_ids as favorites.
	Queued on the DB worker when called from the main thread; synchronous when
	already on it."""
	if not _is_db_ready:
		return false
	_filter_options_cache_valid = false
	_filter_options_cache.clear()
	if MemorySubManager.is_db_thread():
		return _set_all_favorites_sync(favorite_romm_ids)
	MemorySubManager.queue_db_task(func():
		_set_all_favorites_sync(favorite_romm_ids))
	return true


func _set_all_favorites_sync(favorite_romm_ids: Array) -> bool:
	# Caller must be on the DB worker thread (or otherwise serialized); the two
	# UPDATEs are atomic under one lock hold.
	_db_lock()
	var success = query_bool_unlocked("UPDATE games SET is_favorite = 0", [])
	if not favorite_romm_ids.is_empty():
		var placeholders: Array[String] = []
		for id in favorite_romm_ids:
			placeholders.append("?")
		success = query_bool_unlocked("UPDATE games SET is_favorite = 1 WHERE romm_id IN (%s)" % ",".join(placeholders), favorite_romm_ids) and success
	_db_unlock()
	return success


# ==================== PENDING PROPS SYNC QUEUE ====================

func queue_pending_props(romm_id: int, kind: String, payload: Dictionary) -> bool:
	"""Queue a failed RomM user-prop write for retry (latest state wins per rom+kind).
	Queued on the DB worker when called from the main thread; synchronous when
	already on it."""
	if not _is_db_ready:
		return false
	var timestamp = Time.get_datetime_string_from_system(false, true)
	const QUERY := "INSERT OR REPLACE INTO pending_props_sync (romm_id, kind, payload, queued_at) VALUES (?, ?, ?, ?)"
	var bindings := [romm_id, kind, JSON.stringify(payload), timestamp]
	if MemorySubManager.is_db_thread():
		return query_bool(QUERY, bindings)
	MemorySubManager.queue_db_task(func():
		query_bool(QUERY, bindings))
	return true


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
	"""Queued on the DB worker when called from the main thread; synchronous
	when already on it."""
	if not _is_db_ready:
		return false
	if MemorySubManager.is_db_thread():
		return query_bool("DELETE FROM pending_props_sync WHERE romm_id = ? AND kind = ?", [romm_id, kind])
	MemorySubManager.queue_db_task(func():
		query_bool("DELETE FROM pending_props_sync WHERE romm_id = ? AND kind = ?", [romm_id, kind]))
	return true


# ==================== SERVER-DELETION RECONCILIATION ====================

func count_platform_rows(platform_slug: String) -> int:
	"""Raw row count for a platform with no master/cover filters - used by the
	reconciliation guard to compare the server enumeration against reality."""
	if not _is_db_ready:
		return 0
	var rows = query_array("SELECT COUNT(*) AS c FROM games WHERE platform_slug = ?", [platform_slug])
	if rows.is_empty():
		return 0
	return int(rows[0].get("c", 0))


func get_reconciliation_log(platform_slug: String = "", limit: int = 100) -> Array:
	"""Most recent reconciliation log entries, newest first; optionally scoped
	to one platform."""
	if not _is_db_ready:
		return []
	if platform_slug == "":
		return query_array("SELECT platform_slug, romm_id, action, created_at FROM reconciliation_log ORDER BY id DESC LIMIT ?", [limit])
	return query_array("SELECT platform_slug, romm_id, action, created_at FROM reconciliation_log WHERE platform_slug = ? ORDER BY id DESC LIMIT ?", [platform_slug, limit])


func get_last_reconciliation_time(platform_slug: String) -> String:
	"""created_at of the most recent reconciliation for a platform, or ""."""
	if not _is_db_ready:
		return ""
	var rows = query_array("SELECT created_at FROM reconciliation_log WHERE platform_slug = ? ORDER BY id DESC LIMIT 1", [platform_slug])
	if rows.is_empty():
		return ""
	return str(rows[0].get("created_at", ""))


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


func get_most_recently_played_game() -> GameResource:
	"""Most recently played locally-available game (save-sync startup sweep).
	Targeted LIMIT 1: get_all_games() hydrates the whole library — including
	per-row JSON blobs (siblings, igdb_metadata) — which is a multi-second
	stall when all the sweep needs is the single most recent game."""
	if not _is_db_ready:
		return null
	var query_result = query_array("SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND last_played != '' AND (has_local_copy = 1 OR (downloaded_sibling_ids != '[]' AND downloaded_sibling_ids != '')) ORDER BY last_played DESC LIMIT 1")
	if query_result.is_empty():
		return null
	return _row_to_game(query_result[0])


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


## Columns for shuffle fetches: everything except the large description/
## screenshots blobs, whose per-row JSON parsing dominates bag-prep cost.
## _row_to_game tolerates the missing columns.
const _SHUFFLE_COLUMNS := "id, romm_id, title, platform, platform_slug, cover_url, cover_path, file_name, file_path, file_size, has_local_copy, last_updated, genres, rating, release_date, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art, last_played, status, now_playing, backlogged, hidden, is_favorite, title_id, save_id, save_usage, cover_group_id, cover_group_master, igdb_metadata, igdb_id, m3u_path, unwrapped"

## Shuffle-optimized platform fetch: same WHERE semantics as
## get_games_by_platform, but skips description/screenshots and drops
## ORDER BY (the bag shuffles anyway).
func get_games_for_shuffle(platform_slug: String, filters: Dictionary = {}) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var filter_parts: Array = _get_filter_clause(filters)
	var query = "SELECT " + _SHUFFLE_COLUMNS + " FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1"
	var query_result = query_array(query, [platform_slug] + filter_parts[1])
	for row in query_result:
		games.append(_row_to_game(row))
	return games


## Time budget for shuffle row conversion: a fixed row count doesn't bound
## frame cost (every row can carry two JSON columns), so convert until the
## frame has spent this many microseconds, then yield.
const SHUFFLE_ROW_BUDGET_USEC := 3000

## Shuffle candidate fetch: the query materializes on the DB worker thread
## (query_array_async) and row conversion is time-budgeted per frame, so
## building the full shuffler candidate pool (tens of thousands of rows)
## never hitches the UI.
func get_games_for_shuffle_async(platform_slug: String, filters: Dictionary = {}) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready:
		return games
	var filter_parts: Array = _get_filter_clause(filters)
	var query = "SELECT " + _SHUFFLE_COLUMNS + " FROM games WHERE platform_slug = ?" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1"
	var query_result = await query_array_async(query, [platform_slug] + filter_parts[1])
	var frame_start := Time.get_ticks_usec()
	for i in range(query_result.size()):
		games.append(_row_to_game(query_result[i]))
		if Time.get_ticks_usec() - frame_start >= SHUFFLE_ROW_BUDGET_USEC:
			await get_tree().process_frame
			frame_start = Time.get_ticks_usec()
	return games


## SQL-side random sampling for the shuffler bag: one query across all
## selected platforms returning only `limit` games. romm_id is globally
## unique, so ORDER BY RANDOM() LIMIT N matches the old pool-shuffle-take-N
## distribution without materializing the whole library in GDScript. Runs on
## the DB worker thread so session start never blocks a frame on the scan.
func get_random_games_for_shuffle_async(platforms: Array[String], filters: Dictionary, limit: int) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not _is_db_ready or platforms.is_empty() or limit <= 0:
		return games
	var placeholders := ", ".join(platforms.map(func(_p): return "?"))
	var filter_parts: Array = _get_filter_clause(filters)
	var query = "SELECT " + _SHUFFLE_COLUMNS + " FROM games WHERE platform_slug IN (" + placeholders + ")" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1 ORDER BY RANDOM() LIMIT ?"
	var bindings: Array = []
	bindings.append_array(platforms)
	bindings.append_array(filter_parts[1])
	bindings.append(limit)
	var query_result = await query_array_async(query, bindings)
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


## First-character run lengths for the library grid's A-Z letter navigation.
## Titles sharing a first character form contiguous runs under
## get_games_paginated's ORDER BY title (BINARY collation), so cumulative
## counts over these rows yield each run's first grid index. Returns
## [{letter: String, count: int}] in grid order. search_query mirrors the
## title LIKE clause used by search_games_paginated (pass "" when inactive).
func get_title_letter_runs(platform_slug: String = "", filters: Dictionary = {}, search_query: String = "") -> Array[Dictionary]:
	var runs: Array[Dictionary] = []
	if not _is_db_ready:
		return runs

	var filter_parts: Array = _get_filter_clause(filters)
	var where: String
	var bindings: Array = []
	if platform_slug.is_empty():
		where = " WHERE 1=1"
	else:
		where = " WHERE platform_slug = ?"
		bindings.append(platform_slug)
	where += _get_is_master_entry_clause() + _get_has_cover_art_clause() + filter_parts[0] + " AND cover_group_master = 1"
	bindings.append_array(filter_parts[1])
	if not search_query.is_empty():
		where += " AND title LIKE ?"
		bindings.append("%" + search_query + "%")

	var query = "SELECT substr(title, 1, 1) AS first_char, COUNT(*) AS run_count FROM games" + where + " GROUP BY first_char ORDER BY first_char"
	var query_result = query_array(query, bindings)
	for row in query_result:
		runs.append({
			"letter": str(row.get("first_char", "")),
			"count": int(row.get("run_count", 0)),
		})
	return runs


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
	var query = "SELECT COUNT(*) as count FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND hidden_from_home = 0 AND platform_slug IN (%s) AND (has_local_copy = 1 OR downloaded_sibling_ids != '[]')" % placeholders

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
	var query = "SELECT * FROM games WHERE 1=1" + _get_is_master_entry_clause() + _get_has_cover_art_clause() + " AND cover_group_master = 1 AND hidden_from_home = 0 AND platform_slug IN (%s) AND (has_local_copy = 1 OR downloaded_sibling_ids != '[]') ORDER BY last_played DESC, title ASC LIMIT ? OFFSET ?" % placeholders

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
