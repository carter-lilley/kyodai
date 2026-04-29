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

# HTTP Request Pool for efficient reuse during batch operations
# Note: Pooling is disabled on Android to save memory, enabled on desktop for performance
var _request_pool: Array[HTTPRequest] = []
var _max_pool_size: int = 6
var _active_request_count: int = 0

# Response cache for client-side hash-based caching
# endpoint -> {hash, data}
var _response_cache: Dictionary = {}

# Cache statistics for sync reporting
var _cache_hits: int = 0
var _cache_misses: int = 0
var _games_from_cache: int = 0  # Number of games served from cache

func _use_pooling() -> bool:
	"""Check if we should use HTTP request pooling. Disabled on Android to save memory."""
	return not PlatformManager.is_android()

func _ready():
	SettingsManager.setting_changed.connect(_on_setting_changed)
	_load_credentials()

func _on_setting_changed(value, setting):
	match setting.property_name:
		"romm_url":
			_base_url = value if value else ""
			_load_credentials()
		"romm_username":
			_username = value if value else ""
			_load_credentials()
		"romm_password":
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
	
	_check_configuration()

func _check_configuration():
	_is_configured = _base_url != "" and _username != "" and _password != ""
	if _is_configured:
		_check_connection()

# ==================== HTTP REQUEST POOLING ====================
# Pooling is enabled on desktop for better performance (connection reuse)
# Pooling is disabled on Android to save memory (fresh connections)

func _get_pooled_request() -> HTTPRequest:
	"""Get an HTTPRequest from the pool or create a new one."""
	if _use_pooling() and _request_pool.size() > 0:
		var http = _request_pool.pop_back()
		# Cancel any pending requests on reused node
		http.cancel_request()
		# Reset all stateful properties so a prior file download doesn't leak into buffer-based requests
		http.download_file = ""
		http.download_chunk_size = 65536
		http.body_size_limit = -1
		http.timeout = 0.0
		http.accept_gzip = true
		http.use_threads = false
		return http
	
	var http = HTTPRequest.new()
	add_child(http)
	return http

func _return_request(http: HTTPRequest) -> void:
	"""Return an HTTPRequest to the pool for reuse (desktop only)."""
	if http == null or not is_instance_valid(http):
		return
	
	# Always free on Android to save memory
	if not _use_pooling():
		http.queue_free()
		return
	
	# On desktop, try to pool it
	for conn in http.request_completed.get_connections():
		http.request_completed.disconnect(conn.callable)
	
	if _request_pool.size() < _max_pool_size:
		_request_pool.append(http)
	else:
		http.queue_free()

func _create_http_request() -> HTTPRequest:
	"""Deprecated: Use _get_pooled_request() instead."""
	return _get_pooled_request()

func _cleanup_http_request(http: HTTPRequest) -> void:
	"""Deprecated: Use _return_request() instead."""
	_return_request(http)

func _get_auth_header() -> String:
	var credentials = _username + ":" + _password
	var encoded = Marshalls.utf8_to_base64(credentials)
	return "Basic " + encoded

# ==================== CACHE HELPERS ====================

func _get_cache_key(endpoint: String) -> String:
	"""Generate a cache key for an endpoint."""
	return endpoint

func _get_cached_response(endpoint: String) -> Dictionary:
	"""Get cached response data for an endpoint if it exists."""
	var key = _get_cache_key(endpoint)
	if _response_cache.has(key):
		return _response_cache[key]
	return {}

func _store_cached_response(endpoint: String, hash: String, data: Variant):
	"""Store response data in cache with its hash."""
	var key = _get_cache_key(endpoint)
	_response_cache[key] = {
		"hash": hash,
		"data": data
	}

func _extract_header(headers: PackedStringArray, header_name: String) -> String:
	"""Extract a specific header value from response headers."""
	var prefix = header_name.to_lower() + ": "
	for header in headers:
		if header.to_lower().begins_with(prefix):
			return header.substr(prefix.length()).strip_edges()
	return ""

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

func make_request(endpoint: String, callback: Callable, authenticated: bool = true, use_cache: bool = false):
	var http = _create_http_request()
	_active_request_count += 1
	
	var url = _base_url.rstrip("/") + "/api" + endpoint
	
	var headers = []
	if authenticated:
		var auth_header = _get_auth_header()
		headers.append("Authorization: " + auth_header)
	
	# Get cached data for hash comparison
	var cached = _get_cached_response(endpoint) if use_cache else {}
	
	var error = http.request(url, headers, HTTPClient.METHOD_GET)
	
	if error != OK:
		callback.call({}, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if response_code == 401:
			authentication_failed.emit()
			callback.call({}, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call({}, "Request failed with result: " + str(result))
			return
		
		if response_code != 200:
			callback.call({}, "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		
		if parse_result != OK:
			callback.call({}, "Failed to parse JSON: " + json.get_error_message())
			return
		
		# Client-side hash-based caching: compute hash of sorted rom IDs
		var body_hash = _compute_content_hash(json.data)
		
		if use_cache and not cached.is_empty():
			var cached_hash = cached.get("hash", "")
			if body_hash == cached_hash:
				_cache_hits += 1
				# Count games in cached response
				var cached_data = cached.get("data", {})
				var game_count = _count_games_in_data(cached_data)
				_games_from_cache += game_count
				callback.call(cached_data, "")
				return
		
		if use_cache:
			_cache_misses += 1
			_store_cached_response(endpoint, body_hash, json.data)
		
		callback.call(json.data, "")
	)

func _compute_content_hash(data: Variant) -> String:
	"""Compute a stable hash of the response content (sorted rom IDs)."""
	var rom_ids: Array[int] = []
	
	if data is Dictionary and data.has("items") and data["items"] is Array:
		for item in data["items"]:
			if item is Dictionary and item.has("id"):
				rom_ids.append(int(item["id"]))
	elif data is Array:
		for item in data:
			if item is Dictionary and item.has("id"):
				rom_ids.append(int(item["id"]))
	
	rom_ids.sort()
	return str(rom_ids).md5_text()

func _count_games_in_data(data: Variant) -> int:
	"""Count the number of games in the response data."""
	if data is Dictionary and data.has("items") and data["items"] is Array:
		return data["items"].size()
	elif data is Array:
		return data.size()
	return 0

# ==================== ROMM API OPERATIONS ====================

func fetch_games(callback: Callable, platform_slug: String = "", offset: int = 0, limit: int = 250, use_cache: bool = true, updated_after: String = ""):
	if not _is_online:
		callback.call({}, "Not connected")
		return
	
	var endpoint = "/roms?offset=%d&limit=%d" % [offset, limit]
	if platform_slug != "":
		endpoint += "&platform_ids=" + platform_slug
	if updated_after != "":
		endpoint += "&updated_after=" + updated_after.uri_encode()
	
	make_request(endpoint, func(data, error):
		var success = error == ""
		api_request_completed.emit("games", success, data if success else error)
		callback.call(data, error)
	, true, use_cache)  # authenticated=true, use_cache=parameter

func fetch_platforms(callback: Callable):
	if not _is_configured:
		callback.call({}, "Not configured")
		return
	
	make_request("/platforms", func(data, error):
		var success = error == ""
		api_request_completed.emit("platforms", success, data if success else error)
		callback.call(data, error)
	, true, true)  # authenticated=true, use_cache=true

func get_and_reset_cache_stats() -> Dictionary:
	"""Get cache statistics and reset counters."""
	var stats = {
		"hits": _cache_hits,
		"misses": _cache_misses,
		"games_from_cache": _games_from_cache
	}
	_cache_hits = 0
	_cache_misses = 0
	_games_from_cache = 0
	return stats

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
	var http = _create_http_request()
	_active_request_count += 1
	
	var error = http.request(url, headers)
	
	if error != OK:
		if callback.is_valid():
			callback.call(false, PackedByteArray(), 0, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return null
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
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
	
	# Verify directory exists before starting download
	var dest_dir = normalized_path.get_base_dir()
	if not FileSystemManager.dir_exists(dest_dir):
		if not FileSystemManager.make_dir_recursive(dest_dir):
			if callback.is_valid():
				callback.call(false, 0, "Failed to create destination directory")
			http.queue_free()
			return {}
	
	# Configure HTTPRequest for large file downloads
	http.download_file = normalized_path
	http.timeout = 0.0  # Never timeout - let DownloadManager handle this
	# NOTE: Threading disabled on desktop to reduce CPU usage
	# Only enable threading on Android where it helps prevent UI blocking
	http.use_threads = PlatformManager.is_android()
	http.accept_gzip = false  # Disable compression to get accurate file sizes
	http.body_size_limit = -1  # No limit
	
	# Dynamic chunk size based on expected file size and platform
	# Note: download_file is only used for large files (games), images use http_get
	# Desktop uses larger buffers for better throughput on fast connections
	if PlatformManager.is_android():
		# Android: Smaller buffers to conserve memory
		if expected_size > 1024 * 1024 * 1024:  # > 1GB
			http.download_chunk_size = 8 * 1024 * 1024  # 8MB chunks
		elif expected_size > 100 * 1024 * 1024:  # > 100MB
			http.download_chunk_size = 4 * 1024 * 1024  # 4MB chunks
		elif expected_size > 10 * 1024 * 1024:  # > 10MB
			http.download_chunk_size = 1024 * 1024  # 1MB chunks
		else:
			http.download_chunk_size = 256 * 1024  # 256KB chunks
	else:
		# Desktop: Larger buffers for better performance (8MB for faster downloads)
		if expected_size > 1024 * 1024 * 1024:  # > 1GB
			http.download_chunk_size = 8 * 1024 * 1024  # 8MB chunks
		elif expected_size > 100 * 1024 * 1024:  # > 100MB
			http.download_chunk_size = 8 * 1024 * 1024  # 8MB chunks
		elif expected_size > 10 * 1024 * 1024:  # > 10MB
			http.download_chunk_size = 4 * 1024 * 1024  # 4MB chunks
		else:
			http.download_chunk_size = 1 * 1024 * 1024  # 1MB chunks
	
	var error = http.request(url, headers)
	
	if error != OK:
		if callback.is_valid():
			callback.call(false, 0, "Failed to start download: " + str(error))
		http.queue_free()
		return {}
	
	# Store callback for later use (DownloadManager will poll for completion)
	var result = {
		"http": http,
		"callback": callback,
		"path": normalized_path,
		"completed": false
	}
	
	http.request_completed.connect(func(request_result, response_code, response_headers, body):
		# Check callback validity first
		if not callback.is_valid():
			http.queue_free()
			return
		
		if request_result != HTTPRequest.RESULT_SUCCESS:
			result["error"] = "Download failed: " + str(request_result)
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		if response_code >= 400:
			if response_code == 401:
				authentication_failed.emit()
			result["error"] = "HTTP error: " + str(response_code)
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		if not FileSystemManager.file_exists(normalized_path):
			result["error"] = "Download file not created"
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		var file_size = FileSystemManager.get_file_size(normalized_path)
		print("[NetworkManager] Download complete: " + normalized_path + " (response=" + str(response_code) + ", size=" + str(file_size) + " bytes)")
		
		# Only mark as completed on success
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

# ==================== CHUNKED DOWNLOAD SUPPORT ====================

## Checks if the server supports HTTP Range requests
## callback(supports_range: bool, error_message: String)
func check_range_support(url: String, headers: Array = [], callback: Callable = Callable()) -> void:
	var http = _create_http_request()
	_active_request_count += 1
	
	# Add HEAD method to check capabilities without downloading
	var error = http.request(url, headers, HTTPClient.METHOD_HEAD)
	
	if error != OK:
		if callback.is_valid():
			callback.call(false, "Failed to start HEAD request: " + str(error), 0)
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		_active_request_count -= 1
		
		if result != HTTPRequest.RESULT_SUCCESS:
			if callback.is_valid():
				callback.call(false, "HEAD request failed: " + str(result), 0)
			_cleanup_http_request(http)
			return
		
		# Check for Accept-Ranges header
		var supports_range = false
		var content_length = 0
		for header in response_headers:
			var lower_header = header.to_lower()
			if lower_header.begins_with("accept-ranges:"):
				var value = header.split(":", false, 1)[1].strip_edges().to_lower()
				if value == "bytes":
					supports_range = true
			elif lower_header.begins_with("content-length:"):
				var length_str = header.split(":", false, 1)[1].strip_edges()
				content_length = int(length_str)
		
		if callback.is_valid():
			callback.call(supports_range, "", content_length)
		
		_cleanup_http_request(http)
	)

## Downloads a specific byte range (chunk) of a file
## Used for parallel chunked downloads
## This method is thread-safe and can be called from background threads
## callback(success: bool, status_code: int, error_message: String)
func http_download_chunk(url: String, destination_path: String, start_byte: int, end_byte: int, headers: Array = [], callback: Callable = Callable()) -> void:
	# Normalize path separators for the platform
	var normalized_path = destination_path.replace("\\", "/")
	
	# Verify directory exists before starting download
	var dest_dir = normalized_path.get_base_dir()
	if not FileSystemManager.dir_exists(dest_dir):
		if not FileSystemManager.make_dir_recursive(dest_dir):
			if callback.is_valid():
				callback.call(false, 0, "Failed to create destination directory")
			return
	
	# Add Range header
	var range_header = "Range: bytes=%d-%d" % [start_byte, end_byte]
	headers.append(range_header)
	
	# Add User-Agent if not present
	var has_user_agent = false
	for header in headers:
		if header.begins_with("User-Agent:"):
			has_user_agent = true
			break
	if not has_user_agent:
		headers.append("User-Agent: Kyodai-Launcher/1.0")
	
	# Queue the download to be started on the main thread
	# This is necessary because HTTPRequest nodes can only be added to the SceneTree from the main thread
	call_deferred("_start_chunk_download_on_main_thread", url, normalized_path, start_byte, end_byte, headers, callback)

## Internal method to start chunk download on main thread
## Called via call_deferred from http_download_chunk
func _start_chunk_download_on_main_thread(url: String, normalized_path: String, start_byte: int, end_byte: int, headers: Array, callback: Callable):
	var http = HTTPRequest.new()
	add_child(http)
	
	# Configure HTTPRequest for chunk download
	http.download_file = normalized_path
	http.timeout = 0.0  # Never timeout - let caller handle this
	# NOTE: Threading disabled on desktop to reduce CPU usage
	http.use_threads = PlatformManager.is_android()
	http.accept_gzip = false  # Disable compression to get accurate file sizes
	http.body_size_limit = -1  # No limit
	# Platform-specific buffer size for chunked downloads
	if PlatformManager.is_android():
		http.download_chunk_size = 4 * 1024 * 1024  # 4MB chunks for Android (memory optimized)
	else:
		http.download_chunk_size = 8 * 1024 * 1024  # 8MB chunks for desktop (performance)
	
	var error = http.request(url, headers)
	
	if error != OK:
		if callback.is_valid():
			callback.call(false, 0, "Failed to start chunk download: " + str(error))
		http.queue_free()
		return
	
	http.request_completed.connect(func(request_result, response_code, response_headers, body):
		# Check callback validity first
		if not callback.is_valid():
			http.queue_free()
			return
		
		if request_result != HTTPRequest.RESULT_SUCCESS:
			callback.call(false, response_code, "Chunk download failed: " + str(request_result))
			http.queue_free()
			return
		
		if response_code >= 400:
			if response_code == 401:
				authentication_failed.emit()
			callback.call(false, response_code, "HTTP error: " + str(response_code))
			http.queue_free()
			return
		
		if not FileSystemManager.file_exists(normalized_path):
			callback.call(false, response_code, "Chunk file not created")
			http.queue_free()
			return
		
		# Success
		callback.call(true, response_code, "")
		http.queue_free()
	)

# ==================== UTILITY ====================

func test_connection(callback: Callable = Callable()):
	_check_connection()
	
	var timer = Timer.new()
	timer.wait_time = 1.0
	timer.one_shot = true
	timer.timeout.connect(func():
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

## Fetches the latest release from a GitHub-compatible repository API
## Supports GitHub, Gitea, Forgejo, and other platforms with GitHub-compatible API
## @param repo: Repository path (e.g., "owner/repo")
## @param asset_pattern: Regex pattern to match the desired asset filename
## @param callback: Called with (download_url: String, error: String)
## @param release_tag: Specific tag to fetch (empty or "latest" for latest release)
## @param api_base_url: API base URL (default: "https://api.github.com", e.g., "https://git.example.com/api/v1")
func fetch_repo_release(repo: String, asset_pattern: String, callback: Callable, release_tag: String = "", api_base_url: String = ""):
	# Use GitHub as default if no api_base_url provided
	var base_url = api_base_url if api_base_url != "" else "https://api.github.com"
	
	var url = ""
	if release_tag != "" and release_tag != "latest":
		url = base_url + "/repos/" + repo + "/releases/tags/" + release_tag
	else:
		url = base_url + "/repos/" + repo + "/releases/latest"
	var headers = ["Accept: application/vnd.github.v3+json", "User-Agent: Kyodai-Launcher"]
	
	var http = _create_http_request()
	_active_request_count += 1
	
	var error = http.request(url, headers)
	
	if error != OK:
		callback.call("", "", "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call("", "", "Request failed: " + str(result))
			return
		
		if response_code != 200:
			callback.call("", "", "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		
		if parse_result != OK:
			callback.call("", "", "Failed to parse JSON: " + json.get_error_message())
			return
		
		var data = json.data
		if not data.has("assets"):
			callback.call("", "", "No assets in release")
			return
		
		var regex = RegEx.new()
		regex.compile(asset_pattern)
		
		var tag_name = data.get("tag_name", "")
		
		for asset in data.assets:
			var name = asset.get("name", "")
			if regex.search(name) != null:
				var download_url = asset.get("browser_download_url", "")
				callback.call(download_url, tag_name, "")
				return
		
		callback.call("", "", "No asset matched pattern: " + asset_pattern)
	)

func fetch_scraped_release(scrape_url: String, version_pattern: String, url_template: String, callback: Callable, match_strategy: String = "first"):
	var http = _create_http_request()
	_active_request_count += 1
	
	var error = http.request(scrape_url, ["User-Agent: Kyodai-Launcher"])
	
	if error != OK:
		callback.call("", "", "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call("", "", "Request failed: " + str(result))
			return
		
		if response_code != 200:
			callback.call("", "", "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		
		var regex = RegEx.new()
		regex.compile(version_pattern)
		
		var version: String = ""
		
		if match_strategy == "latest_semver":
			var all_matches = regex.search_all(body_text)
			if all_matches.is_empty():
				callback.call("", "", "Could not find version pattern in page")
				return
			
			var versions: Array[String] = []
			for m in all_matches:
				var v = m.get_string(1)
				if v not in versions:
					versions.append(v)
			
			if versions.is_empty():
				callback.call("", "", "Could not find version pattern in page")
				return
			
			# Parse and sort by semver (descending)
			versions.sort_custom(func(a: String, b: String) -> int:
				var a_parts = a.split(".")
				var b_parts = b.split(".")
				var max_len = max(a_parts.size(), b_parts.size())
				for i in range(max_len):
					var av = int(a_parts[i]) if i < a_parts.size() else 0
					var bv = int(b_parts[i]) if i < b_parts.size() else 0
					if av > bv:
						return true
					elif av < bv:
						return false
				return false
			)
			version = versions[0]
		else:
			# Default: first match
			var match_result = regex.search(body_text)
			if match_result == null:
				callback.call("", "", "Could not find version pattern in page")
				return
			version = match_result.get_string(1)
		
		var download_url = url_template.replace("{version}", version)
		
		callback.call(download_url, version, "")
	)

# ==================== ROMM SAVE API OPERATIONS ====================

## Upload a save file to RomM via multipart/form-data
## callback(data: Dictionary, error: String)
func upload_save(rom_id: int, file_path: String, emulator: String = "", slot: String = "", device_id: String = "", overwrite: bool = true, callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call({}, "Not connected")
		return
	
	if not FileSystemManager.file_exists(file_path):
		if callback.is_valid():
			callback.call({}, "File not found: " + file_path)
		return
	
	var file = FileSystemManager.open_file_read(file_path)
	if not file:
		if callback.is_valid():
			callback.call({}, "Cannot open file: " + file_path)
		return
	var file_data = file.get_buffer(file.get_length())
	file.close()
	
	var boundary = "----KyodaiBoundary" + str(Time.get_ticks_msec())
	var file_name = file_path.get_file()
	
	var body = PackedByteArray()
	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array(("Content-Disposition: form-data; name=\"saveFile\"; filename=\"" + file_name + "\"\r\n").to_utf8_buffer())
	body.append_array("Content-Type: application/octet-stream\r\n\r\n".to_utf8_buffer())
	body.append_array(file_data)
	body.append_array(("\r\n--" + boundary + "--\r\n").to_utf8_buffer())
	
	var url = _base_url.rstrip("/") + "/api/saves?rom_id=" + str(rom_id) + "&overwrite=" + str(overwrite).to_lower()
	if emulator != "":
		url += "&emulator=" + emulator.uri_encode()
	if slot != "":
		url += "&slot=" + slot.uri_encode()
	if device_id != "":
		url += "&device_id=" + device_id.uri_encode()
	
	var headers = [
		"Content-Type: multipart/form-data; boundary=" + boundary,
		"Authorization: " + _get_auth_header()
	]
	
	var http = _create_http_request()
	_active_request_count += 1
	
	print("[NetworkManager] upload_save URL: " + url)
	var error = http.request_raw(url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		if callback.is_valid():
			callback.call({}, "Failed to start upload: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, response_body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if response_code == 401:
			authentication_failed.emit()
			if callback.is_valid():
				callback.call({}, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			if callback.is_valid():
				callback.call({}, "Upload failed: " + str(result))
			return
		
		var body_text = response_body.get_string_from_utf8()
		
		if response_code < 200 or response_code >= 300:
			var error_msg = "HTTP error: " + str(response_code)
			if response_code == 404:
				error_msg = "RomM server does not support save syncing (404). Please update RomM to a version that includes the saves API."
			print("[NetworkManager] upload_save failed: " + error_msg + " | body: " + body_text)
			if callback.is_valid():
				callback.call({}, error_msg)
			return
		
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		if parse_result != OK:
			print("[NetworkManager] upload_save parse error: " + json.get_error_message() + " | body: " + body_text)
			if callback.is_valid():
				callback.call({}, "Failed to parse response: " + json.get_error_message())
			return
		
		print("[NetworkManager] upload_save success: " + str(json.data))
		if callback.is_valid():
			callback.call(json.data, "")
	)

## Fetch remote saves for a ROM
## callback(saves: Array, error: String)
func fetch_saves(rom_id: int, device_id: String = "", callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call([], "Not connected")
		return
	
	var endpoint = "/saves?rom_id=" + str(rom_id)
	if device_id != "":
		endpoint += "&device_id=" + device_id.uri_encode()
	
	print("[NetworkManager] fetch_saves URL: " + (_base_url.rstrip("/") + "/api" + endpoint))
	
	make_request(endpoint, func(data, error):
		if error != "":
			print("[NetworkManager] fetch_saves error: " + error)
		else:
			print("[NetworkManager] fetch_saves response: " + str(data))
		if callback.is_valid():
			if error == "":
				if data is Array:
					callback.call(data, "")
				else:
					callback.call([], "Invalid response format")
			else:
				if error == "HTTP error: 404":
					error = "RomM server does not support save syncing (404). Please update RomM to a version that includes the saves API."
				callback.call([], error)
	)

## Download a save file from RomM
## Returns download info dictionary (same as http_download_file)
func download_save(save_id: int, device_id: String, destination_path: String, callback: Callable = Callable()) -> Dictionary:
	var url = _base_url.rstrip("/") + "/api/saves/" + str(save_id) + "/content"
	if device_id != "":
		url += "?device_id=" + device_id.uri_encode()
	
	var headers = ["Authorization: " + _get_auth_header()]
	return http_download_file(url, destination_path, headers, callback)

## Register a device with RomM for save syncing
## callback(data: Dictionary, error: String)
func register_device(name: String, platform: String, client: String, client_version: String, callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call({}, "Not connected")
		return
	
	var url = _base_url.rstrip("/") + "/api/devices"
	var body = JSON.stringify({
		"name": name,
		"platform": platform,
		"client": client,
		"client_version": client_version,
		"allow_existing": true,
		"allow_duplicate": false
	})
	var headers = [
		"Content-Type: application/json",
		"Authorization: " + _get_auth_header()
	]
	
	var http = _create_http_request()
	_active_request_count += 1
	var error = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		if callback.is_valid():
			callback.call({}, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, response_body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if response_code == 401:
			authentication_failed.emit()
			if callback.is_valid():
				callback.call({}, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			if callback.is_valid():
				callback.call({}, "Request failed: " + str(result))
			return
		
		if response_code < 200 or response_code >= 300:
			if callback.is_valid():
				callback.call({}, "HTTP error: " + str(response_code))
			return
		
		var body_text = response_body.get_string_from_utf8()
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		if parse_result != OK:
			if callback.is_valid():
				callback.call({}, "Failed to parse response")
			return
		
		if callback.is_valid():
			callback.call(json.data, "")
	)

# ==================== FIRMWARE DOWNLOAD ====================
## Fetches firmware information for a platform from RomM
## callback(data: Dictionary, error: String)
## Returns platform data including firmware list
func fetch_platform_firmware(platform_slug: String, callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call({}, "Not connected")
		return
	
	var url = _base_url.rstrip("/") + "/api/platforms"
	var headers = [
		"Authorization: " + _get_auth_header()
	]
	
	var http = _create_http_request()
	_active_request_count += 1
	var error = http.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		if callback.is_valid():
			callback.call({}, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, response_body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if response_code == 401:
			authentication_failed.emit()
			if callback.is_valid():
				callback.call({}, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			if callback.is_valid():
				callback.call({}, "Request failed: " + str(result))
			return
		
		if response_code < 200 or response_code >= 300:
			if callback.is_valid():
				callback.call({}, "HTTP error: " + str(response_code))
			return
		
		var body_text = response_body.get_string_from_utf8()
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		if parse_result != OK:
			if callback.is_valid():
				callback.call({}, "Failed to parse response")
			return
		
		# Find the platform in the list
		var platforms = json.data
		var platform_data = {}
		if platforms is Array:
			for platform in platforms:
				if platform.get("slug", "") == platform_slug:
					platform_data = platform
					break
		
		if callback.is_valid():
			callback.call(platform_data, "")
	)

## Downloads a firmware zip file from RomM
## callback(success: bool, error: String)
func download_firmware_zip(firmware_id: int, file_name: String, destination_path: String, callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call(false, "Not connected")
		return
	
	var url = _base_url.rstrip("/") + "/api/firmware/" + str(firmware_id) + "/content/" + file_name
	var headers = [
		"Authorization: " + _get_auth_header()
	]
	
	# Ensure destination directory exists
	var dest_dir = destination_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dest_dir):
		DirAccess.make_dir_recursive_absolute(dest_dir)
	
	var http = _create_http_request()
	_active_request_count += 1
	
	# Set up file download
	http.download_file = destination_path
	
	var error = http.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		if callback.is_valid():
			callback.call(false, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, response_body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if response_code == 401:
			authentication_failed.emit()
			if callback.is_valid():
				callback.call(false, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			if callback.is_valid():
				callback.call(false, "Download failed: " + str(result))
			return
		
		if response_code < 200 or response_code >= 300:
			if callback.is_valid():
				callback.call(false, "HTTP error: " + str(response_code))
			return
		
		print("[NetworkManager] Firmware downloaded: " + destination_path)
		if callback.is_valid():
			callback.call(true, "")
	)

## Confirm a save was downloaded successfully
## callback(data: Dictionary, error: String)
func confirm_save_downloaded(save_id: int, device_id: String, callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call({}, "Not connected")
		return
	
	var url = _base_url.rstrip("/") + "/api/saves/" + str(save_id) + "/downloaded"
	var body = JSON.stringify({"device_id": device_id})
	var headers = [
		"Content-Type: application/json",
		"Authorization: " + _get_auth_header()
	]
	
	var http = _create_http_request()
	_active_request_count += 1
	var error = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		if callback.is_valid():
			callback.call({}, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, response_headers, response_body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if response_code == 401:
			authentication_failed.emit()
			if callback.is_valid():
				callback.call({}, "Authentication failed")
			return
		
		if result != HTTPRequest.RESULT_SUCCESS:
			if callback.is_valid():
				callback.call({}, "Request failed: " + str(result))
			return
		
		if response_code < 200 or response_code >= 300:
			var error_msg = "HTTP error: " + str(response_code)
			if response_code == 404:
				error_msg = "RomM server does not support save syncing (404). Please update RomM to a version that includes the saves API."
			if callback.is_valid():
				callback.call({}, error_msg)
			return
		
		var body_text = response_body.get_string_from_utf8()
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		if parse_result != OK:
			if callback.is_valid():
				callback.call({}, "Failed to parse response")
			return
		
		if callback.is_valid():
			callback.call(json.data, "")
	)
