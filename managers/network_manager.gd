extends Manager

# NetworkManager - Basic HTTP operations only
# Handles all HTTP requests: RomM API calls, returns raw responses
# All download logic moved to DownloadManager

signal network_status_changed(online: bool)
signal authentication_failed()
signal api_request_completed(endpoint: String, success: bool, data: Variant)

var _base_url: String = ""
var _username: String = ""
var _password: String = ""
var _is_online: bool = false
var _is_configured: bool = false

func _ready():
	SettingsManager.setting_changed.connect(_on_setting_changed)
	_load_credentials()

func _on_setting_changed(value, setting):
	print("[NetworkManager] Setting changed: ", setting.property_name)
	if setting.property_name == "romm_url":
		_base_url = value if value else ""
		_load_credentials()
	elif setting.property_name == "romm_username":
		_username = value if value else ""
		_load_credentials()
	elif setting.property_name == "romm_password":
		_password = value if value else ""
		_load_credentials()

func _load_credentials():
	# Load credentials from settings
	if _base_url.is_empty():
		var url_setting = SettingsManager.get_setting("romm_url")
		if url_setting:
			_base_url = url_setting.value if url_setting.value else ""
	
	if _username.is_empty():
		var user_setting = SettingsManager.get_setting("romm_username")
		if user_setting:
			_username = user_setting.value if user_setting.value else ""
	
	if _password.is_empty():
		var pass_setting = SettingsManager.get_setting("romm_password")
		if pass_setting:
			_password = pass_setting.value if pass_setting.value else ""
	
	print("[NetworkManager] Credentials loaded - URL: '", _base_url, "' Username: '", _username, "' Password set: ", not _password.is_empty())
	_check_configuration()

func _check_configuration():
	_is_configured = _base_url != "" and _username != "" and _password != ""
	print("[NetworkManager] Configuration check - Configured: ", _is_configured, " (URL: ", _base_url != "", " User: ", _username != "", " Pass: ", _password != "")
	if _is_configured:
		_check_connection()

func _get_auth_header() -> String:
	var credentials = _username + ":" + _password
	var encoded = Marshalls.utf8_to_base64(credentials)
	return "Basic " + encoded

func is_configured() -> bool:
	return _is_configured

func is_online() -> bool:
	return _is_online

func _check_connection():
	if not _is_configured:
		_is_online = false
		network_status_changed.emit(false)
		return
	
	# Try to fetch platforms to verify connection
	fetch_platforms(func(data, error):
		var was_online = _is_online
		_is_online = error == ""
		
		if was_online != _is_online:
			network_status_changed.emit(_is_online)
	)

# ==================== CORE HTTP METHOD ====================

func make_request(endpoint: String, callback: Callable, authenticated: bool = true):
	var http = HTTPRequest.new()
	add_child(http)
	
	var url = _base_url.rstrip("/") + "/api" + endpoint
	print("[NetworkManager] Making request to: ", url)
	
	var headers = []
	if authenticated:
		var auth_header = _get_auth_header()
		headers.append("Authorization: " + auth_header)
		print("[NetworkManager] Auth header: ", auth_header.substr(0, 20), "...")
	
	var error = http.request(url, headers, HTTPClient.METHOD_GET)
	
	if error != OK:
		print("[NetworkManager] Failed to start request: ", error)
		callback.call({}, "Failed to start request: " + str(error))
		http.queue_free()
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		print("[NetworkManager] Response received - Result: ", result, " Code: ", response_code)
		http.queue_free()
		
		if response_code == 401:
			print("[NetworkManager] Authentication failed (401)")
			authentication_failed.emit()
			callback.call({}, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			print("[NetworkManager] Request failed with result: ", result)
			callback.call({}, "Request failed with result: " + str(result))
			return
		
		if response_code != 200:
			print("[NetworkManager] HTTP error: ", response_code)
			callback.call({}, "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		print("[NetworkManager] Response body length: ", body_text.length())
		
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		
		if parse_result != OK:
			print("[NetworkManager] Failed to parse JSON: ", json.get_error_message())
			callback.call({}, "Failed to parse JSON: " + json.get_error_message())
			return
		
		print("[NetworkManager] Request successful")
		callback.call(json.data, "")
	)

# ==================== ROMM API OPERATIONS ====================

func fetch_games(callback: Callable, platform_slug: String = "", offset: int = 0, limit: int = 100):
	if not _is_online:
		callback.call({}, "Not connected")
		return
	
	var endpoint = "/roms?offset=%d&limit=%d" % [offset, limit]
	if platform_slug != "":
		endpoint += "&platform_ids=" + platform_slug
	
	make_request(endpoint, func(data, error):
		var success = error == ""
		api_request_completed.emit("games", success, data if success else error)
		callback.call(data, error)
	)

func fetch_platforms(callback: Callable):
	print("[NetworkManager] fetch_platforms called, configured: ", _is_configured)
	if not _is_configured:
		print("[NetworkManager] Cannot fetch platforms - not configured")
		callback.call({}, "Not configured")
		return
	
	print("[NetworkManager] Fetching platforms...")
	make_request("/platforms", func(data, error):
		var success = error == ""
		print("[NetworkManager] Platforms fetch result - Success: ", success, " Error: ", error)
		api_request_completed.emit("platforms", success, data if success else error)
		callback.call(data, error)
	)

func fetch_game_details(game_id: int, callback: Callable):
	if not _is_online:
		callback.call({}, "Not connected")
		return
	
	make_request("/roms/" + str(game_id), func(data, error):
		var success = error == ""
		api_request_completed.emit("game_details", success, data if success else error)
		callback.call(data, error)
	)

# ==================== BASIC HTTP OPERATIONS ====================

## Makes a generic HTTP GET request - returns body bytes and status via callback
## callback(success: bool, body: PackedByteArray, status_code: int, error_message: String)
func http_get(url: String, headers: Array = [], callback: Callable = Callable()) -> HTTPRequest:
	var http = HTTPRequest.new()
	add_child(http)
	
	print("[NetworkManager] HTTP GET: " + url)
	
	var error = http.request(url, headers)
	
	if error != OK:
		print("[NetworkManager] Failed to start request: " + str(error))
		if callback.is_valid():
			callback.call(false, PackedByteArray(), 0, "Failed to start request: " + str(error))
		http.queue_free()
		return null
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		http.queue_free()
		
		if not callback.is_valid():
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call(false, PackedByteArray(), response_code, "Request failed: " + str(result))
			return
		
		if response_code >= 400:
			if response_code == 401:
				authentication_failed.emit()
			callback.call(false, body, response_code, "HTTP error: " + str(response_code))
			return
		
		callback.call(true, body, response_code, "")
	)
	
	return http

## Gets the RomM download URL for a game (DownloadManager will handle the actual download)
func get_romm_download_url(game_id: int, file_name: String) -> String:
	var encoded_filename = file_name.uri_encode()
	return _base_url.rstrip("/") + "/api/roms/" + str(game_id) + "/content/" + encoded_filename

## Returns the authentication header for RomM requests
func get_auth_header() -> String:
	return _get_auth_header()

## Returns true if connected to RomM
func is_romm_connected() -> bool:
	return _is_online

# ==================== UTILITY ====================

func test_connection(callback: Callable = Callable()):
	print("[NetworkManager] test_connection called")
	print("[NetworkManager] Current state - URL: '", _base_url, "' User: '", _username, "' Pass set: ", not _password.is_empty())
	print("[NetworkManager] Configured: ", _is_configured, " Online: ", _is_online)
	_check_connection()
	
	var timer = Timer.new()
	timer.wait_time = 1.0
	timer.one_shot = true
	timer.timeout.connect(func():
		print("[NetworkManager] test_connection result - is_online: ", _is_online)
		if callback.is_valid():
			callback.call(_is_online)
		timer.queue_free()
	)
	add_child(timer)
	timer.start()

func format_bytes(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	elif bytes < 1024 * 1024:
		return str(bytes / 1024) + " KB"
	elif bytes < 1024 * 1024 * 1024:
		return str(bytes / (1024 * 1024)) + " MB"
	else:
		return str(bytes / (1024 * 1024 * 1024)) + " GB"

func fetch_github_latest_release(repo: String, asset_pattern: String, callback: Callable):
	var url = "https://api.github.com/repos/" + repo + "/releases/latest"
	var headers = ["Accept: application/vnd.github.v3+json", "User-Agent: Kyodai-Launcher"]
	
	var http = HTTPRequest.new()
	add_child(http)
	
	print("[NetworkManager] Fetching GitHub release: " + url)
	
	var error = http.request(url, headers)
	
	if error != OK:
		print("[NetworkManager] Failed to fetch GitHub release: " + str(error))
		callback.call("", "Failed to start request: " + str(error))
		http.queue_free()
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		http.queue_free()
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call("", "Request failed: " + str(result))
			return
		
		if response_code != 200:
			callback.call("", "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		
		if parse_result != OK:
			callback.call("", "Failed to parse JSON: " + json.get_error_message())
			return
		
		var data = json.data
		if not data.has("assets"):
			callback.call("", "No assets in release")
			return
		
		var regex = RegEx.new()
		regex.compile(asset_pattern)
		
		for asset in data.assets:
			var name = asset.get("name", "")
			if regex.search(name) != null:
				var download_url = asset.get("browser_download_url", "")
				print("[NetworkManager] Found matching asset: " + name + " -> " + download_url)
				callback.call(download_url, "")
				return
		
		callback.call("", "No asset matched pattern: " + asset_pattern)
	)

func fetch_scraped_release(scrape_url: String, version_pattern: String, url_template: String, callback: Callable):
	var http = HTTPRequest.new()
	add_child(http)
	
	print("[NetworkManager] Scraping release from: " + scrape_url)
	
	var error = http.request(scrape_url, ["User-Agent: Kyodai-Launcher"])
	
	if error != OK:
		print("[NetworkManager] Failed to scrape page: " + str(error))
		callback.call("", "Failed to start request: " + str(error))
		http.queue_free()
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		http.queue_free()
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call("", "Request failed: " + str(result))
			return
		
		if response_code != 200:
			callback.call("", "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		
		var regex = RegEx.new()
		regex.compile(version_pattern)
		
		var match_result = regex.search(body_text)
		
		if match_result == null:
			callback.call("", "Could not find version pattern in page")
			return
		
		var version = match_result.get_string(1)
		var download_url = url_template.replace("{version}", version)
		
		print("[NetworkManager] Found version: " + version + " -> " + download_url)
		callback.call(download_url, "")
	)
