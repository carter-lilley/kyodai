extends Manager
class_name GameNativeSubManager

## Manager for GameNative integration - handles loading/saving game list and fetching Steam metadata

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

const STEAM_CDN_URL = "https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/header.jpg"

## Signal emitted when games list changes
signal games_updated()

var _games_data: Array[Dictionary] = []
var _http_request: HTTPRequest
var _pending_scan_app_ids: Array[int] = []

func _ready():
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_http_request_completed)
	_load_games()
	# On Android, discover any .steam files placed in {games_root_folder}/steam and
	# add them as permanent GameNative entries just like manually-added games.
	call_deferred("_scan_steam_folder")

func _scan_steam_folder() -> void:
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
		
		# The .steam file should contain only the Steam App ID.
		var app_id_str := content.strip_edges().get_slice("\n", 0).strip_edges()
		if not app_id_str.is_valid_int():
			continue
		var app_id := int(app_id_str)
		if app_id <= 0:
			continue
		
		# Skip IDs already in the persisted GameNative list.
		var already_exists := false
		for game in _games_data:
			if game.get("app_id", 0) == app_id:
				already_exists = true
				break
		if already_exists:
			continue
		
		_pending_scan_app_ids.append(app_id)
	
	_process_scan_queue()

func _process_scan_queue() -> void:
	if _pending_scan_app_ids.is_empty():
		return
	if _is_validating:
		return
	var app_id: int = _pending_scan_app_ids.pop_front()
	add_game(app_id, func(_success: bool, _message: String):
		# Continue to the next .steam file once this one finishes.
		call_deferred("_process_scan_queue")
	)

func _load_games() -> void:
	"""Load GameNative games from Settings."""
	var setting = DataManager.get_setting("gamenative_games")
	
	if setting and setting.value is Array:
		# Convert to typed array of dictionaries
		_games_data.clear()
		for item in setting.value:
			if item is Dictionary:
				_games_data.append(item)
	else:
		_games_data = []

func _save_games() -> void:
	"""Save GameNative games to Settings."""
	# Create a deep copy of the array to ensure it gets saved properly
	var games_array: Array = []
	for game in _games_data:
		games_array.append(game.duplicate())
	
	var setting = DataManager.get_setting("gamenative_games")
	if setting:
		# Use set_setting so the dirty flag is set and save_settings actually persists.
		DataManager.set_setting(games_array, setting)
		DataManager.save_settings()
	
	games_updated.emit()

func add_game(app_id: int, callback: Callable = Callable()) -> void:
	"""Add a new GameNative game by Steam App ID.
	
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

func _on_http_request_completed(_result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
	if not _is_validating:
		return
	
	_is_validating = false
	
	if response_code != 200:
		if _validation_callback.is_valid():
			_validation_callback.call(false, "Invalid Steam App ID (store page not found)")
		return
	
	# App ID is valid, fetch game name from Steam API
	_fetch_game_name(_validation_app_id, _validation_callback)

func _fetch_game_name(app_id: int, callback: Callable) -> void:
	"""Fetch game name from Steam Store API."""
	# Steam Store API endpoint for app details
	var api_url = "https://store.steampowered.com/api/appdetails?appids=%d&filters=basic" % app_id
	
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		var game_name = "Steam Game %d" % app_id
		
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
		
		# Download cover image before saving
		var cover_url = STEAM_CDN_URL.format({"appid": app_id})
		var cover_path = DataManager.get_cached_image_path(cover_url)
		
		# Download the cover image
		SystemManager.download.download_image(cover_url, cover_path, func(success: bool):
			var cover_path_ref = [cover_path]
			if not success:
				cover_path_ref[0] = ""  # Will fall back to placeholder
			
			# Add game to list with cover path
			_games_data.append({
				"app_id": app_id,
				"name": game_name,
				"source": "STEAM",
				"added_at": Time.get_datetime_string_from_system(),
				"cover_path": cover_path_ref[0],
				"last_played": "1970-01-01T00:00:00"
			})
			_save_games()
			
			if callback.is_valid():
				callback.call(true, game_name)
		)
		
		http.queue_free()
	)
	
	var error = http.request(api_url)
	if error != OK:
		http.queue_free()
		if callback.is_valid():
			callback.call(false, "Failed to fetch game name")

func remove_game(app_id: int) -> void:
	"""Remove a game by Steam App ID."""
	for i in range(_games_data.size()):
		if _games_data[i].get("app_id", 0) == app_id:
			_games_data.remove_at(i)
			_save_games()
			return

func get_games() -> Array[Dictionary]:
	"""Get list of all GameNative games."""
	return _games_data.duplicate()

func create_game_resources() -> Array[GameResource]:
	"""Create GameResource objects for all GameNative games.
	
	These are temporary objects not stored in the database.
	"""
	var games: Array[GameResource] = []
	
	for game_data in _games_data:
		var app_id = game_data.get("app_id", 0)
		var game_title = game_data.get("name", "Steam Game %d" % app_id)
		var cover_path = game_data.get("cover_path", "")
		
		var game = GameResource.new()
		game.id = "gamenative_%d" % app_id
		game.romm_id = -app_id  # Negative to avoid conflicts with RomM IDs
		game.title = game_title
		game.platform = "Steam (GameNative)"
		game.platform_slug = "gamenative"
		game.cover_url = STEAM_CDN_URL.format({"appid": app_id})
		game.cover_path = cover_path  # Use cached cover path
		game.file_name = ""
		game.file_path = ""
		game.has_local_copy = true  # Always playable if GameNative is installed
		game.has_cover_art = true
		game.is_master_entry = true
		game.source = "gamenative"
		game.steam_app_id = app_id
		# Use persisted last_played so the recent order survives app restarts.
		game.last_played = game_data.get("last_played", "1970-01-01T00:00:00")
		game.unwrapped = game_data.get("unwrapped", false)
		
		games.append(game)
	
	return games

func update_last_played(app_id: int, timestamp: String) -> void:
	"""Persist the last_played timestamp for a GameNative game."""
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			game["last_played"] = timestamp
			_save_games()
			return

func update_unwrapped(app_id: int, unwrapped: bool) -> void:
	"""Persist the present-wrap unwrapped flag for a GameNative game."""
	for game in _games_data:
		if game.get("app_id", 0) == app_id:
			game["unwrapped"] = unwrapped
			_save_games()
			return

func get_game_count() -> int:
	"""Get number of GameNative games."""
	return _games_data.size()

func has_games() -> bool:
	"""Check if any GameNative games are configured."""
	return _games_data.size() > 0

func is_game_native_installed() -> bool:
	"""Check if GameNative app is installed on Android."""
	if not SystemManager.platform.is_android():
		return false
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		return false
	
	return plugin.call("isPackageInstalled", "app.gamenative")

func launch_game(app_id: int) -> bool:
	"""Launch a GameNative game by Steam App ID."""
	if not SystemManager.platform.is_android():
		push_error("[GameNativeSubManager] Cannot launch GameNative game on non-Android platform")
		return false
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_error("[GameNativeSubManager] PackageChecker plugin not available")
		return false
	
	return plugin.call("launchGameNativeGame", app_id)
