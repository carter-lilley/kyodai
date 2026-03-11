extends Node

## Manager for GameNative integration - handles loading/saving game list and fetching Steam metadata

const CONFIG_PATH = "user://gamenative_games.json"
const STEAM_CDN_URL = "https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/header.jpg"

## Signal emitted when games list changes
signal games_updated()

var _games_data: Array[Dictionary] = []
var _http_request: HTTPRequest

func _ready():
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.request_completed.connect(_on_http_request_completed)
	_load_games()

func _load_games() -> void:
	"""Load GameNative games from JSON file."""
	print("[GameNativeManager] Loading games from: " + CONFIG_PATH)
	
	if not FileAccess.file_exists(CONFIG_PATH):
		print("[GameNativeManager] Config file does not exist")
		_games_data = []
		return
	
	var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if not file:
		print("[GameNativeManager] Failed to open config file")
		_games_data = []
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	print("[GameNativeManager] Loaded JSON text: " + json_text)
	
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		push_error("[GameNativeManager] Failed to parse games JSON: " + json.get_error_message())
		_games_data = []
		return
	
	var data = json.get_data()
	print("[GameNativeManager] Parsed data type: " + typeof(data))
	
	if data is Array:
		# Convert to typed array
		_games_data.clear()
		for item in data:
			if item is Dictionary:
				_games_data.append(item)
		print("[GameNativeManager] Loaded " + str(_games_data.size()) + " games")
	else:
		print("[GameNativeManager] Data is not an array, clearing")
		_games_data = []

func _save_games() -> void:
	"""Save GameNative games to JSON file."""
	var file = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if not file:
		push_error("[GameNativeManager] Failed to save games JSON")
		return
	
	var json_text = JSON.stringify(_games_data)
	file.store_string(json_text)
	file.close()
	print("[GameNativeManager] Saved " + str(_games_data.size()) + " games to JSON")
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

func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
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
	http.request_completed.connect(func(result, response_code, headers, body):
		var game_name = "Steam Game %d" % app_id
		
		if response_code == 200:
			var json = JSON.new()
			var error = json.parse(body.get_string_from_utf8())
			if error == OK:
				var data = json.get_data()
				if data is Dictionary:
					var app_data = data.get(str(app_id), {})
					if app_data is Dictionary and app_data.get("success", false):
						var game_data = app_data.get("data", {})
						if game_data is Dictionary:
							var name = game_data.get("name", "")
							if name != "":
								game_name = name
		
		# Add game to list
		_games_data.append({
			"app_id": app_id,
			"name": game_name,
			"source": "STEAM",
			"added_at": Time.get_datetime_string_from_system()
		})
		_save_games()
		
		if callback.is_valid():
			callback.call(true, game_name)
		
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
		var name = game_data.get("name", "Steam Game %d" % app_id)
		
		var game = GameResource.new()
		game.id = "gamenative_%d" % app_id
		game.romm_id = -app_id  # Negative to avoid conflicts with RomM IDs
		game.title = name
		game.platform = "Steam (GameNative)"
		game.platform_slug = "gamenative"
		game.cover_url = STEAM_CDN_URL.format({"appid": app_id})
		game.file_name = ""
		game.file_path = ""
		game.has_local_copy = true  # Always playable if GameNative is installed
		game.has_cover_art = true
		game.is_master_entry = true
		game.source = "gamenative"
		game.steam_app_id = app_id
		
		games.append(game)
	
	return games

func get_game_count() -> int:
	"""Get number of GameNative games."""
	var count = _games_data.size()
	print("[GameNativeManager] get_game_count() returning: " + str(count))
	return count

func has_games() -> bool:
	"""Check if any GameNative games are configured."""
	var has = _games_data.size() > 0
	print("[GameNativeManager] has_games() returning: " + str(has) + " (count: " + str(_games_data.size()) + ")")
	return has

func is_game_native_installed() -> bool:
	"""Check if GameNative app is installed on Android."""
	if not PlatformManager.is_android():
		return false
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		return false
	
	return plugin.call("isPackageInstalled", "app.gamenative")

func launch_game(app_id: int) -> bool:
	"""Launch a GameNative game by Steam App ID."""
	if not PlatformManager.is_android():
		push_error("[GameNativeManager] Cannot launch GameNative game on non-Android platform")
		return false
	
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_error("[GameNativeManager] PackageChecker plugin not available")
		return false
	
	return plugin.call("launchGameNativeGame", app_id)
