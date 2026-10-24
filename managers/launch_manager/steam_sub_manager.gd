extends Manager
class_name SteamSubManager

## Manager for Steam support on Android - scans exported .steam shortcut files,
## fetches Steam metadata, and launches via installed Steam frontend apps
## (GameNative, DroidDeck).

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

const STEAM_CDN_URL = "https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/header.jpg"

## Steam launch backends. Both accept an explicit-component LAUNCH_GAME intent
## with an int "app_id" extra on their main activity; DroidDeck additionally
## accepts GameNative's own action when retargeted to its component.
## "packages" lists every known applicationId, canonical first: DroidDeck ships
## benchmark-spoof variants (tools/release/variants.txt) so OEM game modes
## boost clocks, and dev builds use the .xr applicationIdSuffix.
const BACKEND_GAMENATIVE := "gamenative"
const BACKEND_DROIDDECK := "droiddeck"
const BACKENDS := {
	BACKEND_GAMENATIVE: {
		"label": "GameNative",
		"packages": ["app.gamenative"],
		"activity": "app.gamenative.MainActivity",
		"action": "app.gamenative.LAUNCH_GAME",
	},
	BACKEND_DROIDDECK: {
		"label": "DroidDeck",
		"packages": [
			"com.droiddeck.launcher",
			"com.droiddeck.launcher.xr",      # dev/preview builds
			"com.antutu.benchmark.full",      # antutu spoof variant
			"com.tencent.ig",                 # pubg spoof variant
			"com.ludashi.benchmark",          # ludashi spoof variant
		],
		"activity": "com.droiddeck.launcher.MainActivity",
		"action": "com.droiddeck.launcher.LAUNCH_GAME",
	},
}

## Inventory file DroidDeck writes into its game-files sync folder. GameNative
## writes no marker, so its presence identifies a DroidDeck-managed folder.
const DROIDDECK_SYNC_MARKER := ".droiddeck-sync.json"

## Signal emitted when games list changes
signal games_updated()

## Minimum interval between resume-triggered folder rescans. RESUMED can fire
## in bursts (permission dialogs, quick app switches); the scan itself is cheap
## but re-reads every .steam file.
const RESCAN_DEBOUNCE_MS := 5000

var _games_data: Array[Dictionary] = []
var _http_request: HTTPRequest
var _pending_scan_app_ids: Array[int] = []
## Backend recorded per scanned app_id (from the folder marker), keyed by app_id.
var _pending_scan_backend: Dictionary = {}
var _scan_in_progress: bool = false
var _last_scan_msec: int = 0

func _ready():
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_http_request_completed)
	_load_games()
	# On Android, discover any .steam files placed in {games_root_folder}/steam
	# and import them as Steam entries.
	call_deferred("_scan_steam_folder")

## Re-scan the .steam export folder on app resume (games installed/uninstalled
## in GameNative/DroidDeck while backgrounded). Debounced; the in-flight guard
## lives in _scan_steam_folder itself so the startup scan is covered too.
func rescan() -> void:
	if not SystemManager.platform.is_android():
		return
	var now := Time.get_ticks_msec()
	if now - _last_scan_msec < RESCAN_DEBOUNCE_MS:
		return
	_last_scan_msec = now
	_scan_steam_folder()

func _scan_steam_folder() -> void:
	if not SystemManager.platform.is_android():
		return
	# Skip while a scan or manual add is in flight; re-entering would
	# double-queue app ids before the first add completes.
	if _scan_in_progress or _is_validating or not _pending_scan_app_ids.is_empty():
		return

	var root_setting = DataManager.get_setting("games_root_folder")
	if not root_setting or root_setting.value == "":
		return

	var steam_folder := FSM.join_paths(root_setting.value, "steam")
	if not FSM.dir_exists(steam_folder):
		return

	# Folder heuristic: DroidDeck-managed sync folders carry an inventory file.
	# Record it so imported games prefer the backend that exported them.
	var folder_backend := detect_folder_backend(steam_folder)

	# Every valid app id currently in the folder (drives removal reconcile).
	var found_ids: Array[int] = []

	for filename in FSM.get_files(steam_folder):
		if not filename.ends_with(".steam"):
			continue
		var file_path := FSM.join_paths(steam_folder, filename)
		var content := FSM.read_file(file_path)
		if content == "":
			continue

		# The .steam file should contain only the Steam App ID.
		var app_id_str := content.strip_edges().get_slice("\n", 0).strip_edges()
		if not app_id_str.is_valid_int():
			continue
		var app_id := int(app_id_str)
		if app_id <= 0:
			continue

		found_ids.append(app_id)

		# Skip IDs already in the persisted Steam list.
		var already_exists := false
		for game in _games_data:
			if game.get("app_id", 0) == app_id:
				already_exists = true
				break
		if already_exists:
			_backfill_origin(app_id, folder_backend)
			continue

		_pending_scan_app_ids.append(app_id)
		if folder_backend != "":
			_pending_scan_backend[app_id] = folder_backend

	if _provenance_dirty:
		_provenance_dirty = false
		_save_games(false)

	# Mirror the backend: entries imported from a file whose file vanished
	# (uninstalled in the backend) are removed. Entries without an origin flag
	# (added before origin tracking) are never auto-removed.
	var removed := _reconcile_removed_files(found_ids)

	if _pending_scan_app_ids.is_empty():
		if removed:
			games_updated.emit()
	else:
		_scan_in_progress = true
		_process_scan_queue()

## Remove file-origin games whose .steam file no longer exists. Silent save:
## the caller owns the single games_updated emit for the whole scan.
func _reconcile_removed_files(found_ids: Array[int]) -> bool:
	var removed := false
	for i in range(_games_data.size() - 1, -1, -1):
		var game := _games_data[i]
		if game.get("origin", "") != "file":
			continue
		if not found_ids.has(game.get("app_id", 0)):
			_games_data.remove_at(i)
			removed = true
	if removed:
		_save_games(false)
	return removed

var _provenance_dirty: bool = false

## Entries scanned in before origin tracking get the flag when their file is
## still present, so the reconcile pass covers them too. Silent: origin is
## not user-visible, so no games_updated emit.
func _backfill_origin(app_id: int, folder_backend: String) -> void:
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			if game.get("origin", "") == "":
				game["origin"] = "file"
				if folder_backend != "" and game.get("backend", "") == "":
					game["backend"] = folder_backend
				_provenance_dirty = true
			return

## Detect which backend manages a .steam export folder. Only DroidDeck leaves
## a marker (its sync inventory); anything else is assumed GameNative/origin-
## unknown and returns "".
func detect_folder_backend(steam_folder: String) -> String:
	if FSM.file_exists(FSM.join_paths(steam_folder, DROIDDECK_SYNC_MARKER)):
		return BACKEND_DROIDDECK
	return ""

func _process_scan_queue() -> void:
	if _pending_scan_app_ids.is_empty():
		return
	if _is_validating:
		return
	var app_id: int = _pending_scan_app_ids.pop_front()
	# Suppress per-add games_updated emits during the scan; emit once when the
	# queue drains so the grid rebuilds a single time instead of N times.
	add_game(app_id, func(success: bool, _message: String):
		if success:
			# File-sourced entries get an origin flag so the reconcile pass can
			# auto-remove them when the backend deletes their .steam file.
			var fields := { "origin": "file" }
			if _pending_scan_backend.has(app_id):
				fields["backend"] = _pending_scan_backend[app_id]
			_set_game_fields(app_id, fields)
		_pending_scan_backend.erase(app_id)
		if _pending_scan_app_ids.is_empty():
			_scan_in_progress = false
			games_updated.emit()
		else:
			# Continue to the next .steam file once this one finishes.
			call_deferred("_process_scan_queue")
	, false)

func _set_game_fields(app_id: int, fields: Dictionary) -> void:
	"""Record scan provenance on a game entry (origin, exporting backend).
	Silent save: the scan emits games_updated once when the queue drains."""
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			for key in fields:
				game[key] = fields[key]
			_save_games(false)
			return

func _load_games() -> void:
	"""Load Steam games from Settings."""
	var setting = DataManager.get_setting("steam_games")
	
	if setting and setting.value is Array:
		# Convert to typed array of dictionaries
		_games_data.clear()
		for item in setting.value:
			if item is Dictionary:
				_games_data.append(item)
	else:
		_games_data = []

func _save_games(notify: bool = true) -> void:
	"""Save Steam games to Settings."""
	# Create a deep copy of the array to ensure it gets saved properly
	var games_array: Array = []
	for game in _games_data:
		games_array.append(game.duplicate())

	var setting = DataManager.get_setting("steam_games")
	if setting:
		# Use set_setting so the dirty flag is set and save_settings actually persists.
		DataManager.set_setting(games_array, setting)
		DataManager.save_settings()

	if notify:
		games_updated.emit()

func add_game(app_id: int, callback: Callable = Callable(), notify: bool = true) -> void:
	"""Add a new Steam game by App ID.

	Validates the App ID by checking Steam store, fetches game name from Steam API.
	"""
	# Check if already exists
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			if callback.is_valid():
				callback.call(false, "Game already in list")
			return
	
	# First validate the app exists on Steam
	_is_validating = true
	_validation_callback = callback
	_validation_app_id = app_id
	_validation_notify = notify
	
	# Check Steam store page exists (HEAD request)
	var store_url = "https://store.steampowered.com/app/%d" % app_id
	var error = _http_request.request(store_url, [], HTTPClient.METHOD_HEAD)
	if error != OK:
		_is_validating = false
		if callback.is_valid():
			callback.call(false, "Failed to validate App ID")

var _is_validating: bool = false
var _validation_callback: Callable
var _validation_app_id: int
var _validation_notify: bool = true

func _on_http_request_completed(_result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
	if not _is_validating:
		return
	
	_is_validating = false
	
	if response_code != 200:
		if _validation_callback.is_valid():
			_validation_callback.call(false, "Invalid Steam App ID (store page not found)")
		return
	
	# App ID is valid, fetch game name from Steam API
	_fetch_game_name(_validation_app_id, _validation_callback, _validation_notify)

func _fetch_game_name(app_id: int, callback: Callable, notify: bool = true) -> void:
	"""Fetch game name and cover URL from Steam Store API."""
	# Steam Store API endpoint for app details
	var api_url = "https://store.steampowered.com/api/appdetails?appids=%d&filters=basic" % app_id

	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		var game_name = "Steam Game %d" % app_id
		# Newer store pages only serve artwork from the hashed
		# store_item_assets path (the legacy /steam/apps/{id}/header.jpg
		# pattern 404s for them), so prefer the canonical header_image URL
		# the API returns and fall back to the legacy pattern.
		var cover_url := STEAM_CDN_URL.format({"appid": app_id})

		if response_code == 200:
			var json = JSON.new()
			var parse_error = json.parse(body.get_string_from_utf8())
			if parse_error == OK:
				var data = json.get_data()
				if data is Dictionary:
					var app_data = data.get(str(app_id), {})
					if app_data is Dictionary and app_data.get("success", false):
						var game_data = app_data.get("data", {})
						if game_data is Dictionary:
							var steam_name = game_data.get("name", "")
							if steam_name != "":
								game_name = steam_name
							var header_image = game_data.get("header_image", "")
							if header_image is String and header_image.begins_with("http"):
								# Strip the ?t= asset-version query so Steam's
								# cache-busting bumps don't duplicate cache entries.
								cover_url = header_image.split("?")[0]

		var cover_path = DataManager.get_cached_image_path(cover_url)

		# Download the cover image
		# Bulk (true): sync prefetch is background batch work and must survive
		# grid-teleport pruning of user-facing queue entries.
		SystemManager.download.download_image(cover_url, cover_path, func(result):
			var cover_path_ref = [cover_path]
			if result != DownloadSubManager.ImageResult.OK:
				cover_path_ref[0] = ""  # Will fall back to placeholder

			# Add game to list with cover path
			_games_data.append({
				"app_id": app_id,
				"name": game_name,
				"source": "STEAM",
				"added_at": Time.get_datetime_string_from_system(),
				"cover_url": cover_url,
				"cover_path": cover_path_ref[0],
				"last_played": "1970-01-01T00:00:00"
			})
			_save_games(notify)

			if callback.is_valid():
				callback.call(true, game_name)
		, false, true)

		http.queue_free()
	)
	
	var error = http.request(api_url)
	if error != OK:
		http.queue_free()
		if callback.is_valid():
			callback.call(false, "Failed to fetch game name")

func remove_game(app_id: int) -> void:
	"""Remove a game by Steam App ID. Also deletes the matching .steam export
	file so the startup scan doesn't re-import it on next launch. The backend
	(GameNative/DroidDeck) will recreate the file on its next sync while the
	game is still installed there, which then re-imports it here - the
	backend's library remains the source of truth."""
	for i in range(_games_data.size()):
		if _games_data[i].get("app_id", 0) == app_id:
			_games_data.remove_at(i)
			_save_games()
			_delete_steam_file(app_id)
			return

func _delete_steam_file(app_id: int) -> void:
	"""Delete any {games_root_folder}/steam/*.steam file whose content is this
	app id. Mirrors the scan's parsing exactly."""
	if not SystemManager.platform.is_android():
		return

	var root_setting = DataManager.get_setting("games_root_folder")
	if not root_setting or root_setting.value == "":
		return

	var steam_folder := FSM.join_paths(root_setting.value, "steam")
	if not FSM.dir_exists(steam_folder):
		return

	for filename in FSM.get_files(steam_folder):
		if not filename.ends_with(".steam"):
			continue
		var file_path := FSM.join_paths(steam_folder, filename)
		var content := FSM.read_file(file_path)
		if content == "":
			continue
		var app_id_str := content.strip_edges().get_slice("\n", 0).strip_edges()
		if app_id_str.is_valid_int() and int(app_id_str) == app_id:
			FSM.delete_file(file_path)

func get_games() -> Array[Dictionary]:
	"""Get list of all Steam games."""
	return _games_data.duplicate()

func get_game_data(app_id: int) -> Dictionary:
	"""Persisted data for one game, or {} when not in the list."""
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			return game
	return {}

func create_game_resources() -> Array[GameResource]:
	"""Create GameResource objects for all Steam games.

	These are temporary objects not stored in the database.
	"""
	var games: Array[GameResource] = []
	
	for game_data in _games_data:
		var app_id = game_data.get("app_id", 0)
		var game_title = game_data.get("name", "Steam Game %d" % app_id)
		var cover_path = game_data.get("cover_path", "")
		# Entries added before header_image persistence only have the legacy
		# CDN pattern; keep it as the fallback.
		var cover_url = game_data.get("cover_url", "")
		if cover_url == "":
			cover_url = STEAM_CDN_URL.format({"appid": app_id})

		var game = GameResource.new()
		game.id = "steam_%d" % app_id
		game.romm_id = -app_id  # Negative to avoid conflicts with RomM IDs
		game.title = game_title
		game.platform = "Steam"
		game.platform_slug = "steam"
		game.cover_url = cover_url
		game.cover_path = cover_path  # Use cached cover path
		game.file_name = ""
		game.file_path = ""
		game.has_local_copy = true  # Always playable if a Steam frontend is installed
		game.has_cover_art = true
		game.is_master_entry = true
		game.source = "steam"
		game.steam_app_id = app_id
		# Use persisted last_played so the recent order survives app restarts.
		game.last_played = game_data.get("last_played", "1970-01-01T00:00:00")
		game.unwrapped = game_data.get("unwrapped", false)
		
		games.append(game)
	
	return games

func update_last_played(app_id: int, timestamp: String) -> void:
	"""Persist the last_played timestamp for a Steam game.
	Silent save: HomeView._on_game_launched already re-sorts and reloads the
	grid on game_launched, so the games_updated emit would cause a redundant
	second full grid reload per launch."""
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			game["last_played"] = timestamp
			_save_games(false)
			return

func update_unwrapped(app_id: int, unwrapped: bool) -> void:
	"""Persist the present-wrap unwrapped flag for a Steam game.
	Silent save: the flag doesn't affect grid order/contents, so skip the
	games_updated emit (it triggers a full grid reload mid-unwrap-animation)."""
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			game["unwrapped"] = unwrapped
			_save_games(false)
			return

func get_game_count() -> int:
	"""Get number of Steam games."""
	return _games_data.size()

func has_games() -> bool:
	"""Check if any Steam games are configured."""
	return _games_data.size() > 0

func get_installed_package(backend: String) -> String:
	"""First package from the backend's known applicationIds that is installed
	on this device, or "" when none is."""
	if not SystemManager.platform.is_android():
		return ""
	if not BACKENDS.has(backend):
		return ""

	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		return ""

	for package in BACKENDS[backend]["packages"]:
		if plugin.call("isPackageInstalled", package):
			return package
	return ""

func is_backend_installed(backend: String) -> bool:
	"""Check if a Steam launch backend app is installed on Android."""
	return get_installed_package(backend) != ""

func get_installed_backends() -> Array[String]:
	"""All Steam launch backends currently installed, in registry order."""
	var installed: Array[String] = []
	for backend in BACKENDS:
		if is_backend_installed(backend):
			installed.append(backend)
	return installed

func get_backend_label(backend: String) -> String:
	return BACKENDS.get(backend, {}).get("label", backend)

func get_preferred_backend() -> String:
	"""User's saved backend preference: a backend id, or "" for auto."""
	var setting = DataManager.get_setting("steam_backend")
	if setting and setting.value is String and BACKENDS.has(setting.value):
		return setting.value
	return ""

func set_preferred_backend(backend: String) -> void:
	"""Persist the backend preference ("" resets to auto)."""
	var setting = DataManager.get_setting("steam_backend")
	if not setting:
		return
	DataManager.set_setting(backend if backend != "" else "auto", setting)
	DataManager.save_settings()

func _get_game_backend(app_id: int) -> String:
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			return game.get("backend", "")
	return ""

## Resolve which backend should launch a game. Returns a backend id, or "" when
## no unambiguous choice exists (none installed, or both installed with no
## per-game/folder/user preference). Precedence: per-game recorded backend ->
## saved user preference -> folder marker -> the single installed backend.
func resolve_backend(app_id: int) -> String:
	var installed := get_installed_backends()
	if installed.is_empty():
		return ""

	var game_backend := _get_game_backend(app_id)
	if game_backend != "" and installed.has(game_backend):
		return game_backend

	var preferred := get_preferred_backend()
	if preferred != "" and installed.has(preferred):
		return preferred

	var root_setting = DataManager.get_setting("games_root_folder")
	if root_setting and root_setting.value != "":
		var folder_backend := detect_folder_backend(FSM.join_paths(root_setting.value, "steam"))
		if folder_backend != "" and installed.has(folder_backend):
			return folder_backend

	if installed.size() == 1:
		return installed[0]

	return ""

## Resolve which backend should launch a game, asking the user when both
## backends are installed and nothing disambiguates them. on_result receives
## (backend: String, message: String); backend == "" means do not launch
## (silent cancel when message == "", otherwise an error to report).
func resolve_backend_interactive(app_id: int, on_result: Callable) -> void:
	if not SystemManager.platform.is_android():
		if on_result.is_valid():
			on_result.call("", "Steam games only available on Android")
		return

	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		push_error("[SteamSubManager] KyodaiBridge plugin not available")
		if on_result.is_valid():
			on_result.call("", "Android bridge unavailable")
		return

	var backend := resolve_backend(app_id)
	if backend != "":
		if on_result.is_valid():
			on_result.call(backend, "")
		return

	var installed := get_installed_backends()
	if installed.is_empty():
		if on_result.is_valid():
			on_result.call("", "No Steam launcher installed. Install GameNative or DroidDeck.")
		return

	# Both backends installed and nothing disambiguates them: ask once, then
	# remember the choice so future launches go straight to it.
	_show_backend_picker(installed, on_result)

## Launch via a previously resolved backend.
func launch_with_backend(backend: String, app_id: int) -> bool:
	if not BACKENDS.has(backend):
		return false
	return _do_launch(backend, app_id)

func _show_backend_picker(installed: Array[String], on_result: Callable) -> void:
	var dialog = M3Dialog.new()
	dialog.title_text = "Launch Steam Game"
	dialog.body_text = "Both GameNative and DroidDeck are installed. Choose which app to launch Steam games with - your choice is remembered for future launches."

	var chosen := { "picked": false }
	for backend in installed:
		var label: String = get_backend_label(backend)
		dialog.add_action(label, func():
			chosen["picked"] = true
			set_preferred_backend(backend)
			dialog.dismiss()
			if on_result.is_valid():
				on_result.call(backend, "")
		, backend == installed[0])

	# Dismissal without a choice (scrim tap / close button / back) cancels
	# silently; after a choice the action callback already reported.
	dialog.dismissed.connect(func():
		if not chosen["picked"] and on_result.is_valid():
			on_result.call("", "")
	)

	M3Dialog.show_dialog(dialog)

func _do_launch(backend: String, app_id: int) -> bool:
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin == null:
		return false
	var info: Dictionary = BACKENDS[backend]
	var package := get_installed_package(backend)
	if package == "":
		return false
	# has_method() doesn't work on Android plugin singletons, so staleness is
	# detected by calling: a missing plugin method logs an error and returns
	# null, while the real methods return the Java boolean (which crosses the
	# JNI bridge as int 0/1 on some engine versions). Fall back to the legacy
	# method for GameNative (the only backend it can target).
	var result = plugin.call("launchSteamGame", package, info["activity"], info["action"], app_id)
	if result == null:
		push_error("[SteamSubManager] KyodaiBridge plugin is outdated (missing launchSteamGame). Rebuild the Android plugin and re-export the app.")
		if backend == BACKEND_GAMENATIVE:
			result = plugin.call("launchGameNativeGame", app_id)
	if result is bool:
		return result
	return result is int and result != 0
