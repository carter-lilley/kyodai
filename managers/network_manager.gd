extends Manager

# NetworkManager - Basic HTTP operations only
# Handles all HTTP requests: RomM API calls, returns raw responses
# All download logic moved to DownloadManager

const FSM = preload("res://managers/filesystem_manager.gd")

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
const MAX_RESPONSE_CACHE_SIZE: int = 200
var _response_cache_order: Array[String] = []

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
	var http: HTTPRequest
	if _use_pooling() and _request_pool.size() > 0:
		http = _request_pool.pop_back()
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
	
	http = HTTPRequest.new()
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
		# Refresh LRU order on access
		var idx = _response_cache_order.find(key)
		if idx != -1:
			_response_cache_order.remove_at(idx)
			_response_cache_order.append(key)
		return _response_cache[key]
	return {}

func _store_cached_response(endpoint: String, response_hash: String, data: Variant):
	"""Store response data in cache with its hash."""
	var key = _get_cache_key(endpoint)
	
	# If key already exists, just update and refresh LRU order
	if _response_cache.has(key):
		_response_cache[key] = {"hash": response_hash, "data": data}
		var idx = _response_cache_order.find(key)
		if idx != -1:
			_response_cache_order.remove_at(idx)
			_response_cache_order.append(key)
		return
	
	# Evict oldest entries if at capacity
	if _response_cache.size() >= MAX_RESPONSE_CACHE_SIZE:
		var to_evict = _response_cache.size() - MAX_RESPONSE_CACHE_SIZE + 1
		for i in range(to_evict):
			if _response_cache_order.size() > 0:
				var oldest_key = _response_cache_order.pop_front()
				_response_cache.erase(oldest_key)
	
	_response_cache[key] = {
		"hash": response_hash,
		"data": data
	}
	_response_cache_order.append(key)

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
	fetch_platforms(func(_data, error):
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
	
	http.request_completed.connect(func(result, response_code, _response_headers, body):
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

## Synchronous fetch for sync thread - uses HTTPClient directly
## Returns: {"success": bool, "data": Dictionary, "error": String}
## This is thread-safe and does not depend on the scene tree
func fetch_games_sync(platform_slug: String = "", offset: int = 0, limit: int = 250, updated_after: String = "") -> Dictionary:
	if not _is_configured:
		return {"success": false, "data": {}, "error": "Not configured"}
	
	var endpoint = "/roms?offset=%d&limit=%d" % [offset, limit]
	if platform_slug != "":
		endpoint += "&platform_ids=" + platform_slug
	if updated_after != "":
		endpoint += "&updated_after=" + updated_after.uri_encode()
	
	var url = _base_url.rstrip("/") + "/api" + endpoint
	var headers = ["Authorization: " + _get_auth_header()]
	
	return _http_get_sync(url, headers)

## Synchronous HTTP GET using HTTPClient - thread-safe, no scene tree dependency
func _http_get_sync(url: String, headers: Array = []) -> Dictionary:
	var result = _http_request_sync(url, headers)
	if not result.success:
		return result
	
	# Parse JSON from bytes
	var body_text = result.body.get_string_from_utf8()
	var json = JSON.new()
	var parse_result = json.parse(body_text)
	
	if parse_result != OK:
		return {"success": false, "data": {}, "error": "Failed to parse JSON: " + json.get_error_message()}
	
	return {"success": true, "data": json.data, "error": ""}

## Downloads raw bytes from URL using HTTPClient - thread-safe, no scene tree dependency
## Returns: {"success": bool, "body": PackedByteArray, "error": String}
func _http_get_bytes_sync(url: String, headers: Array = []) -> Dictionary:
	var result = _http_request_sync(url, headers)
	if not result.success:
		return {"success": false, "body": PackedByteArray(), "error": result.error}
	return {"success": true, "body": result.body, "error": ""}

## Shared HTTP request implementation - returns raw bytes
func _http_request_sync(url: String, headers: Array = []) -> Dictionary:
	var http = HTTPClient.new()
	
	# Parse URL
	var protocol = "http"
	var host = ""
	var port = 80
	var path = "/"
	var query = ""
	
	var protocol_end = url.find("://")
	if protocol_end != -1:
		protocol = url.substr(0, protocol_end)
		url = url.substr(protocol_end + 3)
	
	if protocol == "https":
		port = 443
	
	var path_start = url.find("/")
	if path_start == -1:
		host = url
	else:
		host = url.substr(0, path_start)
		var remainder = url.substr(path_start)
		var query_start = remainder.find("?")
		if query_start == -1:
			path = remainder
		else:
			path = remainder.substr(0, query_start)
			query = remainder.substr(query_start)
	
	var port_start = host.find(":")
	if port_start != -1:
		port = host.substr(port_start + 1).to_int()
		host = host.substr(0, port_start)
	
	# Connect
	var err: int
	if protocol == "https":
		var tls = TLSOptions.client()
		err = http.connect_to_host(host, port, tls)
	else:
		err = http.connect_to_host(host, port)
	
	if err != OK:
		return {"success": false, "body": PackedByteArray(), "error": "Failed to connect: " + str(err)}
	
	# Wait for connection
	var timeout = 0
	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		OS.delay_usec(1000)
		timeout += 1
		if timeout > 10000:  # 10 seconds
			return {"success": false, "body": PackedByteArray(), "error": "Connection timeout"}
	
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"success": false, "body": PackedByteArray(), "error": "Not connected, status: " + str(http.get_status())}
	
	# Make request
	var request_headers = headers.duplicate()
	var has_host = false
	for header in request_headers:
		if header.to_lower().begins_with("host:"):
			has_host = true
			break
	if not has_host:
		request_headers.append("Host: " + host)
	
	var has_user_agent = false
	for header in request_headers:
		if header.begins_with("User-Agent:"):
			has_user_agent = true
			break
	if not has_user_agent:
		request_headers.append("User-Agent: Kyodai-Launcher/1.0")
	
	err = http.request(HTTPClient.METHOD_GET, path + query, request_headers)
	if err != OK:
		return {"success": false, "body": PackedByteArray(), "error": "Failed to make request: " + str(err)}
	
	# Wait for response headers
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_usec(1000)
	
	var response_code = http.get_response_code()
	
	if response_code == 401:
		return {"success": false, "body": PackedByteArray(), "error": "Authentication failed"}
	
	if response_code != 200:
		return {"success": false, "body": PackedByteArray(), "error": "HTTP error: " + str(response_code)}
	
	# Read body
	var body = PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk = http.read_response_body_chunk()
		if chunk.size() > 0:
			body.append_array(chunk)
		else:
			OS.delay_usec(1000)
	
	return {"success": true, "body": body, "error": ""}

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
	
	http.request_completed.connect(func(result, response_code, _response_headers, body):
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
	if not FSM.dir_exists(dest_dir):
		if not FSM.make_dir_recursive(dest_dir):
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
	
	http.request_completed.connect(func(request_result, response_code, _response_headers, _body):
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
		
		if not FSM.file_exists(normalized_path):
			result["error"] = "Download file not created"
			callback.call(false, response_code, result.error)
			http.queue_free()
			return
		
		var file_size = FSM.get_file_size(normalized_path)
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
	
	http.request_completed.connect(func(result, _response_code, response_headers, _body):
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
	if not FSM.dir_exists(dest_dir):
		if not FSM.make_dir_recursive(dest_dir):
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
func _start_chunk_download_on_main_thread(url: String, normalized_path: String, _start_byte: int, _end_byte: int, headers: Array, callback: Callable):
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
	
	http.request_completed.connect(func(request_result, response_code, _response_headers, _body):
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
		
		if not FSM.file_exists(normalized_path):
			callback.call(false, response_code, "Chunk file not created")
			http.queue_free()
			return
		
		# Success
		callback.call(true, response_code, "")
		http.queue_free()
	)

# ==================== UTILITY ====================

func test_connection(callback: Callable = Callable()):
	if not _is_configured:
		_is_online = false
		if callback.is_valid():
			callback.call(false)
		return
	
	# Perform a direct request instead of relying on the cached _is_online state.
	# _check_connection() is asynchronous; a fixed timer races the HTTP round-trip.
	make_request("/platforms", func(_data, error):
		var success = error == ""
		var was_online = _is_online
		_is_online = success
		if was_online != _is_online:
			network_status_changed.emit(_is_online)
		if callback.is_valid():
			callback.call(success)
	, true, false)  # authenticated=true, use_cache=false

func format_bytes(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	elif bytes < 1024 * 1024:
		return str(bytes / 1024.0) + " KB"
	elif bytes < 1024 * 1024 * 1024:
		return str(bytes / (1024.0 * 1024.0)) + " MB"
	else:
		return str(bytes / (1024.0 * 1024.0 * 1024.0)) + " GB"

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
		callback.call("", "", "Failed to start request: " + str(error), 0, "")
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, _response_headers, body):
			_active_request_count -= 1
			_cleanup_http_request(http)
			
			if result != HTTPRequest.RESULT_SUCCESS:
				callback.call("", "", "Request failed: " + str(result), 0, "")
				return
			
			if response_code != 200:
				callback.call("", "", "HTTP error: " + str(response_code), 0, "")
				return
			
			var body_text = body.get_string_from_utf8()
			var json = JSON.new()
			var parse_result = json.parse(body_text)
			
			if parse_result != OK:
				callback.call("", "", "Failed to parse JSON: " + json.get_error_message(), 0, "")
				return
			
			var data = json.data
			if not data.has("assets"):
				callback.call("", "", "No assets in release", 0, "")
				return
			
			var regex = RegEx.new()
			regex.compile(asset_pattern)
			
			var tag_name = data.get("tag_name", "")
			var published_at = data.get("published_at", "")
			
			for asset in data.assets:
				var asset_name = asset.get("name", "")
				if regex.search(asset_name) != null:
					var download_url = asset.get("browser_download_url", "")
					var asset_size = asset.get("size", 0)
					callback.call(download_url, tag_name, "", asset_size, published_at)
					return
			callback.call("", "", "No asset matched pattern: " + asset_pattern, 0, "")
			)

func fetch_scraped_release(scrape_url: String, version_pattern: String, url_template: String, callback: Callable, match_strategy: String = "first", json_path: String = ""):
	var http = _create_http_request()
	_active_request_count += 1
	
	var error = http.request(scrape_url, ["User-Agent: Kyodai-Launcher"])
	
	if error != OK:
		callback.call("", "", "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, _response_headers, body):
		_active_request_count -= 1
		_cleanup_http_request(http)
		
		if result != HTTPRequest.RESULT_SUCCESS:
			callback.call("", "", "Request failed: " + str(result))
			return
		
		if response_code != 200:
			callback.call("", "", "HTTP error: " + str(response_code))
			return
		
		var body_text = body.get_string_from_utf8()
		var version: String = ""
		
		if json_path != "":
			# JSON API mode: parse JSON and extract version via path
			var json = JSON.new()
			var parse_result = json.parse(body_text)
			if parse_result != OK:
				callback.call("", "", "Failed to parse JSON: " + json.get_error_message())
				return
			
			# Check if path contains a wildcard array iterator [*]
			var wildcard_idx = json_path.find("[*]")
			if wildcard_idx != -1:
				# Array iteration mode: prefix[*].suffix
				var prefix_path = json_path.substr(0, wildcard_idx)
				var suffix_path = json_path.substr(wildcard_idx + 3)  # skip "[*]"
				if suffix_path.begins_with("."):
					suffix_path = suffix_path.substr(1)
				
				var array_data = _extract_json_value(json.data, prefix_path)
				if array_data == null or not (array_data is Array):
					callback.call("", "", "JSON path did not resolve to an array: " + prefix_path)
					return
				
				print("[NetworkManager] Fetched " + str(array_data.size()) + " tags from GitHub API")
				
				var regex = RegEx.new()
				if version_pattern != "":
					regex.compile(version_pattern)
				
				for item in array_data:
					var item_value = item
					if suffix_path != "":
						item_value = _extract_json_value(item, suffix_path)
					
					if item_value == null:
						continue
					
					var item_str = str(item_value)
					print("[NetworkManager] Checking tag: " + item_str)
					
					if version_pattern != "":
						var match_result = regex.search(item_str)
						if match_result != null:
							version = match_result.get_string(1) if match_result.get_group_count() >= 1 else item_str
							print("[NetworkManager] Matched tag: " + item_str + " -> version=" + version)
							break
					else:
						version = item_str
						break
				
				if version == "":
					callback.call("", "", "No array item matched version pattern: " + version_pattern)
					return
			else:
				# Single value extraction mode
				var extracted = _extract_json_value(json.data, json_path)
				if extracted == null or extracted == "":
					callback.call("", "", "Could not extract version from JSON path: " + json_path)
					return
				version = str(extracted)
		else:
			# HTML scraping mode: use regex on response body
			var regex = RegEx.new()
			regex.compile(version_pattern)
			
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

## Extracts a value from parsed JSON data using a dot-and-bracket path.
## Examples: "[0].name", "data.version", "items[2].url"
func _extract_json_value(data, path: String):
	var current = data
	var i = 0
	while i < path.length():
		if path[i] == "[":
			# Array index: find closing bracket
			var close_idx = path.find("]", i)
			if close_idx == -1:
				return null
			var index = int(path.substr(i + 1, close_idx - i - 1))
			if current is Array and index >= 0 and index < current.size():
				current = current[index]
			else:
				return null
			i = close_idx + 1
			# Skip dot after bracket if present
			if i < path.length() and path[i] == ".":
				i += 1
		else:
			# Object key: find next dot or bracket
			var next_dot = path.find(".", i)
			var next_bracket = path.find("[", i)
			var end_idx = path.length()
			if next_dot != -1 and (next_bracket == -1 or next_dot < next_bracket):
				end_idx = next_dot
			elif next_bracket != -1 and (next_dot == -1 or next_bracket < next_dot):
				end_idx = next_bracket
			var key = path.substr(i, end_idx - i)
			if current is Dictionary and current.has(key):
				current = current[key]
			else:
				return null
			i = end_idx
			if i < path.length() and path[i] == ".":
				i += 1
	return current

# ==================== ROMM SAVE API OPERATIONS ====================

## Upload a save file to RomM via multipart/form-data
## callback(data: Dictionary, error: String)
func upload_save(rom_id: int, file_path: String, emulator: String = "", slot: String = "", device_id: String = "", overwrite: bool = true, callback: Callable = Callable()) -> void:
	if not _is_online:
		if callback.is_valid():
			callback.call({}, "Not connected")
		return
	
	if not FSM.file_exists(file_path):
		if callback.is_valid():
			callback.call({}, "File not found: " + file_path)
		return
	
	var file = FSM.open_file_read(file_path)
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
	
	http.request_completed.connect(func(result, response_code, _response_headers, response_body):
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
func register_device(_device_name: String, platform: String, client: String, client_version: String, callback: Callable = Callable()) -> void:
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
	
	http.request_completed.connect(func(result, response_code, _response_headers, _response_body):
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
		
		# Success - parse response body for device data
		var body_text = _response_body.get_string_from_utf8()
		var json = JSON.new()
		var parse_result = json.parse(body_text)
		var response_data = {}
		if parse_result == OK:
			response_data = json.data
		
		if callback.is_valid():
			callback.call(response_data, "")
		http.queue_free()
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
	
	http.request_completed.connect(func(result, response_code, _response_headers, response_body):
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
func download_firmware_zip(firmware_id: int, file_name: String, destination_path: String, callback: Callable = Callable(), progress_callback: Callable = Callable()) -> void:
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
	
	# Track download progress with a timer
	var progress_timer: Timer = null
	var last_reported_mb = [-1]
	
	if progress_callback.is_valid():
		progress_timer = Timer.new()
		progress_timer.wait_time = 0.5
		progress_timer.one_shot = false
		add_child(progress_timer)
		
		progress_timer.timeout.connect(func():
			if FSM.file_exists(destination_path):
				var file_size = FSM.get_file_size(destination_path)
				var size_mb = int(file_size / (1024.0 * 1024.0))
				if size_mb != last_reported_mb[0]:
					last_reported_mb[0] = size_mb
					progress_callback.call(size_mb)
		)
		progress_timer.start()
	
	var error = http.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		if progress_timer:
			progress_timer.stop()
			progress_timer.queue_free()
		if callback.is_valid():
			callback.call(false, "Failed to start request: " + str(error))
		_active_request_count -= 1
		_cleanup_http_request(http)
		return
	
	http.request_completed.connect(func(result, response_code, _response_headers, _response_body):
		if progress_timer:
			progress_timer.stop()
			progress_timer.queue_free()
		
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
	
	http.request_completed.connect(func(result, response_code, _response_headers, response_body):
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
