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

## Downloads a large file directly to disk - avoids memory issues with big files
## Uses HTTPRequest's download_file property for streaming downloads
## callback(success: bool, status_code: int, error_message: String)
## Returns: Dictionary with download info {http, callback, path, completed}
func http_download_file(url: String, destination_path: String, headers: Array = [], callback: Callable = Callable(), expected_size: int = 0) -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	
	# Normalize path separators for the platform
	var normalized_path = destination_path.replace("\\", "/")
	
	print("[NetworkManager] HTTP DOWNLOAD: " + url)
	print("[NetworkManager] Destination: " + normalized_path)
	
	# Verify directory exists before starting download
	var dest_dir = normalized_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dest_dir):
		print("[NetworkManager] Creating directory: " + dest_dir)
		var err = DirAccess.make_dir_recursive_absolute(dest_dir)
		if err != OK:
			print("[NetworkManager] Failed to create directory: " + dest_dir + " (error: " + str(err) + ")")
			if callback.is_valid():
				callback.call(false, 0, "Failed to create destination directory")
			http.queue_free()
			return {}
	
	# Configure HTTPRequest for large file downloads
	http.download_file = normalized_path
	http.timeout = 0.0  # Never timeout - let DownloadManager handle this
	http.use_threads = true  # Use background thread for better performance
	http.accept_gzip = false  # Disable compression to get accurate file sizes
	http.body_size_limit = -1  # No limit
	
	# Dynamic chunk size based on expected file size
	# Note: download_file is only used for large files (games), images use http_get
	if expected_size > 1024 * 1024 * 1024:  # > 1GB
		http.download_chunk_size = 2 * 1024 * 1024  # 2MB chunks
		print("[NetworkManager] Using 2MB chunks (>1GB file)")
	elif expected_size > 100 * 1024 * 1024:  # > 100MB
		http.download_chunk_size = 1024 * 1024  # 1MB chunks
		print("[NetworkManager] Using 1MB chunks (100MB-1GB file)")
	elif expected_size > 10 * 1024 * 1024:  # > 10MB
		http.download_chunk_size = 256 * 1024  # 256KB chunks
		print("[NetworkManager] Using 256KB chunks (10-100MB file)")
	else:
		http.download_chunk_size = 64 * 1024  # 64KB chunks
		print("[NetworkManager] Using 64KB chunks (<10MB file)")
	
	var error = http.request(url, headers)
	
	if error != OK:
		print("[NetworkManager] Failed to start download: " + str(error))
		if callback.is_valid():
			callback.call(false, 0, "Failed to start download: " + str(error))
		http.queue_free()
		return {}
	
	print("[NetworkManager] Download request started successfully (threaded, no timeout)")
	
	# Store callback for later use (DownloadManager will poll for completion)
	var result = {
		"http": http,
		"callback": callback,
		"path": normalized_path,
		"completed": false
	}
	
	http.request_completed.connect(func(request_result, response_code, response_headers, body):
		print("[NetworkManager] Download request_completed fired - result: " + str(request_result) + ", code: " + str(response_code))
		
		# Check callback validity first
		if not callback.is_valid():
			print("[NetworkManager] WARNING: Callback is not valid!")
			http.queue_free()
			return
		
		if request_result != HTTPRequest.RESULT_SUCCESS:
			print("[NetworkManager] Download failed - calling callback with error")
			result["error"] = "Download failed: " + str(request_result)
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		if response_code >= 400:
			print("[NetworkManager] HTTP error %d - calling callback with error" % response_code)
			if response_code == 401:
				authentication_failed.emit()
			result["error"] = "HTTP error: " + str(response_code)
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		if not FileAccess.file_exists(normalized_path):
			print("[NetworkManager] File not created - calling callback with error")
			result["error"] = "Download file not created"
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		# Only mark as completed on success
		print("[NetworkManager] Download success - calling callback")
		result.completed = true
		callback.call(true, response_code, "")
		http.queue_free()
	)
	
	return result

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

func fetch_github_latest_release(repo: String, asset_pattern: String, callback: Callable, release_tag: String = "", api_base_url: String = ""):
	# Use GitHub as default if no api_base_url provided
	var base_url = api_base_url if api_base_url != "" else "https://api.github.com"
	
	var url = ""
	if release_tag != "" and release_tag != "latest":
		url = base_url + "/repos/" + repo + "/releases/tags/" + release_tag
	else:
		url = base_url + "/repos/" + repo + "/releases/latest"
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
