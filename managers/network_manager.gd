extends Manager

# NetworkManager - Unified network operations manager
# Handles all HTTP requests: RomM API, image downloads, ROM downloads

signal network_status_changed(online: bool)
signal authentication_failed()
signal download_progress_update(game_id: int, progress_percent: float)
signal download_finished(game_id: int, success: bool, file_path: String)
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

# ==================== DOWNLOAD OPERATIONS ====================

func download_image(url: String, callback: Callable):
	# Image downloads don't need authentication
	var http = HTTPRequest.new()
	add_child(http)
	
	var error = http.request(url)
	
	if error != OK:
		callback.call(PackedByteArray())
		http.queue_free()
		return http
	
	http.request_completed.connect(func(result, response_code, headers, body):
		http.queue_free()
		
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			callback.call(PackedByteArray())
			return
		
		callback.call(body)
	)
	
	return http

func download_rom(game_id: int, file_name: String, destination_path: String, progress_callback: Callable, completion_callback: Callable):
	if not _is_online:
		completion_callback.call(false, "Not connected")
		return null
	
	var http = HTTPRequest.new()
	add_child(http)
	
	# RomM download endpoint: /api/roms/{id}/content/{file_name}
	var encoded_filename = file_name.uri_encode()
	var url = _base_url.rstrip("/") + "/api/roms/" + str(game_id) + "/content/" + encoded_filename
	
	print("[NetworkManager] Downloading from: ", url)
	
	var error = http.request(url, ["Authorization: " + _get_auth_header()], HTTPClient.METHOD_GET)
	
	if error != OK:
		completion_callback.call(false, "Failed to start download: " + str(error))
		http.queue_free()
		return http
	
	download_progress_update.emit(game_id, 0.0)
	
	http.request_completed.connect(func(result, response_code, headers, body):
		http.queue_free()
		
		if response_code == 401:
			authentication_failed.emit()
			completion_callback.call(false, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			completion_callback.call(false, "Download failed: " + str(result))
			return
		
		if response_code != 200:
			completion_callback.call(false, "HTTP error: " + str(response_code))
			return
		
		var file = FileAccess.open(destination_path, FileAccess.WRITE)
		if file:
			file.store_buffer(body)
			file.close()
			completion_callback.call(true, destination_path)
		else:
			completion_callback.call(false, "Failed to write file")
		
		download_finished.emit(game_id, result == HTTPRequest.RESULT_SUCCESS and response_code == 200, destination_path)
	)
	
	return http

# ==================== GENERIC FILE DOWNLOAD ====================

func download_file(url: String, destination_path: String, progress_callback: Callable, completion_callback: Callable) -> HTTPRequest:
	var http = HTTPRequest.new()
	add_child(http)
	
	print("[NetworkManager] Downloading file from: " + url)
	
	var error = http.request(url)
	
	if error != OK:
		completion_callback.call(false, "Failed to start download: " + str(error))
		http.queue_free()
		return null
	
	# Track download progress
	var last_bytes = 0
	
	# Use a timer to periodically check download progress
	var progress_timer = Timer.new()
	progress_timer.wait_time = 0.5
	progress_timer.autostart = true
	add_child(progress_timer)
	
	progress_timer.timeout.connect(func():
		if http and is_instance_valid(http):
			var body_size = http.get_body_size()
			var downloaded_bytes = http.get_downloaded_bytes()
			if body_size > 0:
				progress_callback.call(downloaded_bytes, body_size)
	)
	
	http.request_completed.connect(func(result, response_code, headers, body):
		progress_timer.stop()
		progress_timer.queue_free()
		http.queue_free()
		
		if result != HTTPRequest.RESULT_SUCCESS:
			completion_callback.call(false, "Download failed: " + str(result))
			return
		
		if response_code != 200:
			completion_callback.call(false, "HTTP error: " + str(response_code))
			return
		
		var file = FileAccess.open(destination_path, FileAccess.WRITE)
		if file:
			file.store_buffer(body)
			file.close()
			completion_callback.call(true, destination_path)
		else:
			completion_callback.call(false, "Failed to write file")
	)
	
	return http

func queue_game_download(game: GameResource) -> bool:
	if not _is_online:
		NotificationManager.show_notification("Cannot download: not connected", Notification.Type.ERROR)
		return false
	
	return DownloadManager.queue_download(game)

func cancel_game_download(game_id: int) -> bool:
	return DownloadManager.cancel_download(game_id)

func is_game_downloading(game_id: int) -> bool:
	return DownloadManager.is_downloading(game_id)

func is_game_queued(game_id: int) -> bool:
	return DownloadManager.is_queued(game_id)

func get_active_downloads() -> Array:
	return DownloadManager.get_active_downloads()

func get_queued_downloads() -> Array:
	return DownloadManager.get_queued_downloads()

func get_download_queue_size() -> int:
	return DownloadManager.get_queued_downloads().size() + DownloadManager.get_active_downloads().size()

func cancel_all_downloads():
	var active = DownloadManager.get_active_downloads()
	var queued = DownloadManager.get_queued_downloads()
	
	for item in active:
		DownloadManager.cancel_download(item.game.romm_id)
	
	for item in queued:
		DownloadManager.cancel_download(item.game.romm_id)

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
