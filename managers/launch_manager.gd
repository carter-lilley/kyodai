extends Manager

## Manages emulator registry, launch intents, and game execution

const REGISTRY_PATH := "res://data/emulator_registry.json"

## Returns the configured emulators directory from settings, or default if not set
func get_emulators_directory() -> String:
	if SettingsManager:
		var setting = SettingsManager.get_setting("emulators_folder")
		if setting and setting.value != "":
			return setting.value
	return "user://emulators/"

## Returns the effective Vita3K data directory on Android.
## Uses user setting if set, otherwise falls back to Vita3K's default path.
func _get_vita3k_android_data_path() -> String:
	if PlatformManager.is_android():
		var setting = SettingsManager.get_setting("vita3k_data_folder_android")
		if setting and setting.value != "" and setting.value != "user://roms/":
			return setting.value.rstrip("/")
	return "/storage/emulated/0/Android/data/org.vita3k.emulator/files/vita"

## Converts a SAF content:// URI to a real filesystem path when possible.
## Falls back to the original path if conversion fails.
func _resolve_saf_to_real_path(path: String) -> String:
	if PlatformManager.is_android() and path.begins_with("content://"):
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin and plugin.has_method("getRealPathFromSafUri"):
			var real_path = plugin.getRealPathFromSafUri(path)
			if real_path != "":
				return real_path
	return path

## Gets the full path to an emulator's directory
## Handles path separators correctly for all platforms
func _get_emulator_directory(emulator_id: String) -> String:
	# Vita3K on Android uses its own external storage path, not the emulators folder
	if emulator_id.begins_with("vita3k") and PlatformManager.is_android():
		var vita_path = _get_vita3k_android_data_path()
		if vita_path != "":
			return vita_path + "/"
	
	var base_dir = get_emulators_directory()
	
	# Ensure proper path separator
	if base_dir.ends_with("/") or base_dir.ends_with("\\"):
		return base_dir + emulator_id + "/"
	else:
		return base_dir + "/" + emulator_id + "/"

## Resolves {emulator_dir} placeholders in paths
func _resolve_emulator_path(path: String, emulator_id: String) -> String:
	if path.begins_with("{emulator_dir}"):
		return path.replace("{emulator_dir}", _get_emulator_directory(emulator_id).rstrip("/"))
	return path

## Resolves validation paths (handles {emulator_dir} and absolute paths)
func _resolve_validation_path(emulator_id: String, path: String) -> String:
	if path.begins_with("{emulator_dir}"):
		return path.replace("{emulator_dir}", _get_emulator_directory(emulator_id).rstrip("/"))
	if path.begins_with("/") or path.begins_with("content://"):
		# Absolute path or SAF URI - use as-is
		return path
	else:
		# Relative path - prepend emulator directory
		return _get_emulator_directory(emulator_id) + path

## Extracts the base tree URI from a SAF path for permission checks
func _extract_saf_tree_uri(full_uri: String) -> String:
	var tree_pos = full_uri.find("/tree/")
	if tree_pos == -1:
		return ""
	
	var after_tree = tree_pos + 6
	
	# For SAF URIs with encoded paths, the tree URI includes everything up to the last component
	var last_sep = full_uri.rfind("%2F")
	if last_sep == -1:
		last_sep = full_uri.rfind("/")
	
	if last_sep > after_tree:
		return full_uri.substr(0, last_sep)
	
	return full_uri

## Gets the subdirectory portion from a SAF path
func _get_saf_subdirectory(full_uri: String) -> String:
	var tree_pos = full_uri.find("/tree/")
	if tree_pos == -1:
		return ""
	
	var last_sep = full_uri.rfind("%2F")
	if last_sep == -1:
		last_sep = full_uri.rfind("/")
	
	if last_sep > tree_pos + 6:
		return full_uri.substr(last_sep + 1)
	
	return ""

# Registry data
var _emulator_registry: Dictionary = {}
var _platform_defaults: Dictionary = {}

# Track installation progress for UI display only
var _emulator_install_progress: Dictionary = {}  # emulator_id -> progress text for UI

# Track ongoing extractions


# Track pending launches waiting for emulator installation
# emulator_id -> {game: GameResource, callback: Callable}
var _pending_launches: Dictionary = {}

# Track pending launches waiting for game download
# item_id -> GameResource
var _pending_game_downloads: Dictionary = {}

## Unified download tracking for emulator downloads
# item_id -> {emulator_id, context, extract_to, strip_top_directory, callback}
var _pending_emulator_downloads: Dictionary = {}

## Validation cache to avoid redundant file system operations
# emulator_id -> {result: Dictionary, timestamp: int, step_results: Dictionary}
var _validation_cache: Dictionary = {}
var _cache_ttl_ms: int = 5000  # 5 second cache TTL

# Signals
signal emulator_registry_loaded(success: bool)
signal launch_completed(success: bool, message: String)
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_completed(emulator_id: String, success: bool)
signal game_launched(game: GameResource)  # Emitted when a game is successfully launched
signal game_launch_initiated(game: GameResource, focus_index: int)  # Emitted when a game launch is initiated (includes focus index for restoration)
signal background_state_entered(pid: int, game: GameResource)  # Emitted when entering background state (desktop only)
signal background_state_exited(game: GameResource, exit_code: int)  # Emitted when exiting background state (desktop only)

# Background state tracking (desktop only)
var _background_active_pid: int = -1
var _background_active_game: GameResource = null
var _is_in_background_state: bool = false
var _background_poll_timer: Timer = null
const BACKGROUND_POLL_INTERVAL: float = 1.0

func _ready():
	_load_registry()
	_ensure_emulators_directory()
	
	# Connect to DownloadManager signals
	DownloadManager.extraction_completed.connect(_on_download_manager_extraction_completed)
	DownloadManager.download_completed.connect(_on_unified_download_completed)
	
	# Initialize background state polling (desktop only)
	if not PlatformManager.is_android():
		_background_poll_timer = Timer.new()
		_background_poll_timer.wait_time = BACKGROUND_POLL_INTERVAL
		_background_poll_timer.one_shot = false
		_background_poll_timer.timeout.connect(_on_background_poll_timeout)
		add_child(_background_poll_timer)
	
	# Scan existing installations to detect partial installs
	# Wait a frame to ensure everything is initialized
	await get_tree().process_frame

# ==================== BACKGROUND STATE (DESKTOP ONLY) ====================

## Returns true if currently in background state (emulator running)
func is_in_background_state() -> bool:
	return _is_in_background_state

## Returns the active process PID, or -1 if none
func get_background_pid() -> int:
	return _background_active_pid

## Returns the active game during background state, or null
func get_background_game() -> GameResource:
	return _background_active_game

## Enter background state with active PID
func _enter_background_state(pid: int, game: GameResource) -> void:
	if _is_in_background_state:
		print("[LaunchManager] Warning: Already in background state, ignoring new PID ", pid)
		return
	
	if pid <= 0:
		push_error("[LaunchManager] Invalid PID for background state: " + str(pid))
		return
	
	print("[LaunchManager] Entering background state with PID: ", pid)
	_background_active_pid = pid
	_background_active_game = game
	_is_in_background_state = true
	
	if _background_poll_timer:
		_background_poll_timer.start()
	
	background_state_entered.emit(pid, game)

## Exit background state
func _exit_background_state(exit_code: int = 0) -> void:
	if not _is_in_background_state:
		return
	
	print("[LaunchManager] Exiting background state. PID was: ", _background_active_pid)
	
	var game = _background_active_game
	
	if _background_poll_timer:
		_background_poll_timer.stop()
	
	_background_active_pid = -1
	_background_active_game = null
	_is_in_background_state = false
	
	background_state_exited.emit(game, exit_code)

## Poll callback - check if process is still running
func _on_background_poll_timeout() -> void:
	if not _is_in_background_state or _background_active_pid <= 0:
		return
	
	print("[LaunchManager] Polling PID ", _background_active_pid, "...")
	
	if not _is_process_running(_background_active_pid):
		print("[LaunchManager] Process ", _background_active_pid, " no longer running")
		_exit_background_state(0)
	else:
		print("[LaunchManager] Process ", _background_active_pid, " still running")

## Check if a process is running by PID (platform-specific)
func _is_process_running(pid: int) -> bool:
	if pid <= 0:
		return false
	
	if PlatformManager.is_windows():
		return _is_process_running_windows(pid)
	else:
		return _is_process_running_unix(pid)

## Windows: Check if process is running using tasklist
func _is_process_running_windows(pid: int) -> bool:
	var output = []
	var exit_code = OS.execute("tasklist", ["/FI", "PID eq " + str(pid), "/NH"], output, true)
	
	if exit_code != 0:
		return false
	
	if output.size() > 0:
		var result = output[0].strip_edges()
		return result != "" and not result.begins_with("INFO:")
	
	return false

## Unix (Linux/Mac): Check if process is running using /proc or ps
func _is_process_running_unix(pid: int) -> bool:
	if PlatformManager.is_linux():
		var dir = DirAccess.open("/proc/" + str(pid))
		if dir:
			return true
	
	var output = []
	var exit_code = OS.execute("ps", ["-p", str(pid)], output, true)
	return exit_code == 0

## Force exit background state (for crashes/emergencies)
func force_exit_background_state() -> void:
	print("[LaunchManager] Force exiting background state")
	_exit_background_state(-1)

## Kill the active process (emergency use only)
func kill_background_process() -> bool:
	if not _is_in_background_state or _background_active_pid <= 0:
		return false
	
	print("[LaunchManager] Killing background process: ", _background_active_pid)
	
	if PlatformManager.is_windows():
		OS.execute("taskkill", ["/F", "/PID", str(_background_active_pid)], [], true)
	else:
		OS.execute("kill", ["-9", str(_background_active_pid)], [], true)
	
	_exit_background_state(-1)
	return true

func _load_registry():
	if not FileAccess.file_exists(REGISTRY_PATH):
		push_error("[LaunchManager] Emulator registry not found at: " + REGISTRY_PATH)
		emulator_registry_loaded.emit(false)
		return
	
	var file = FileAccess.open(REGISTRY_PATH, FileAccess.READ)
	if not file:
		push_error("[LaunchManager] Failed to open registry file")
		emulator_registry_loaded.emit(false)
		return
	
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("[LaunchManager] Failed to parse registry JSON: " + json.get_error_message())
		emulator_registry_loaded.emit(false)
		return
	
	_emulator_registry = json.data
	_build_platform_defaults()
	
	emulator_registry_loaded.emit(true)

func _build_platform_defaults():
	_platform_defaults.clear()
	
	# First, check for explicit platform defaults in registry
	if _emulator_registry.has("_platform_defaults"):
		var explicit_defaults = _emulator_registry["_platform_defaults"]
		if explicit_defaults is Dictionary:
			for platform in explicit_defaults.keys():
				var emulator_id = explicit_defaults[platform]
				if _emulator_registry.has(emulator_id):
					_platform_defaults[platform] = emulator_id
					#print("[LaunchManager] Explicit default for %s: %s" % [platform, emulator_id])
	
	# Then, for any platforms not explicitly set, use first available emulator
	for emulator_id in _emulator_registry.keys():
		if emulator_id.begins_with("_"):
			continue
		var emulator = _emulator_registry[emulator_id]
		var platforms = emulator.get("platforms", [])
		
		for platform in platforms:
			if not _platform_defaults.has(platform):
				_platform_defaults[platform] = emulator_id

func _ensure_emulators_directory():
	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists("emulators"):
		dir.make_dir("emulators")

## Gets all available emulators from registry
func get_all_emulators() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	
	for emulator_id in _emulator_registry.keys():
		var emulator = _emulator_registry[emulator_id].duplicate()
		emulator["id"] = emulator_id
		result.append(emulator)
	
	return result

## Gets emulators that support a specific platform
func get_emulators_for_platform(platform_slug: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	
	for emulator_id in _emulator_registry.keys():
		var emulator = _emulator_registry[emulator_id]
		var platforms = emulator.get("platforms", [])
		
		if platform_slug in platforms:
			var emu_copy = emulator.duplicate()
			emu_copy["id"] = emulator_id
			result.append(emu_copy)
	
	return result

## Gets the default emulator for a platform
func get_default_emulator_for_platform(platform_slug: String) -> String:
	return _platform_defaults.get(platform_slug, "")

## Gets details for a specific emulator
func get_emulator(emulator_id: String) -> Dictionary:
	if not _emulator_registry.has(emulator_id):
		return {}
	
	var emulator = _emulator_registry[emulator_id].duplicate()
	emulator["id"] = emulator_id
	return emulator

## Gets the current installation progress text for UI display
func get_emulator_install_progress(emulator_id: String) -> String:
	return _emulator_install_progress.get(emulator_id, "")

## Gets platform-specific config from a step's platforms dictionary
## Checks "all" first (universal config), then falls back to current platform
## Returns empty dictionary if no config found for current platform
func _get_step_platform_config(step: Dictionary) -> Dictionary:
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var platforms = step.get("platforms", {})
	
	var platform_config = platforms.get("all", {})
	if platform_config.is_empty():
		platform_config = platforms.get(platform_name, {})
	
	return platform_config

## Checks if emulator is currently being extracted
func is_emulator_extracting(emulator_id: String) -> bool:
	# Check DownloadManager for any active extraction for this emulator
	for item in DownloadManager.get_active():
		if item.name == emulator_id and item.status == "extracting":
			return true
	return false

## Helper: Get the bundled 7z binary path
func _get_7z_binary_path() -> String:
	var platform_name = ""
	match PlatformManager.current_platform:
		PlatformManager.Platform.WINDOWS:
			platform_name = "windows"
		PlatformManager.Platform.LINUX:
			platform_name = "linux"
		_:
			return ""
	
	var binary_name = "7za.exe" if PlatformManager.is_windows() else "7z"
	return ProjectSettings.globalize_path("res://bin/7z/" + platform_name + "/" + binary_name)

## Recursively searches for executable file up to max_depth (3 levels)
func _find_executable_recursive(dir_path: String, executable_name: String, max_depth: int = 3, current_depth: int = 0) -> String:
	if current_depth >= max_depth:
		return ""
	
	var dir = DirAccess.open(dir_path)
	if not dir:
		return ""
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		
		var full_path = dir_path + "/" + file_name
		
		if dir.current_is_dir():
			var result = _find_executable_recursive(full_path, executable_name, max_depth, current_depth + 1)
			if result != "":
				dir.list_dir_end()
				return result
		else:
			# Check if this is the executable we're looking for
			if file_name.to_lower() == executable_name.to_lower():
				dir.list_dir_end()
				return full_path
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return ""

## Called when DownloadManager completes an extraction
## Called when DownloadManager completes an extraction
## Registry-based validation handles actual installation checking
func _on_download_manager_extraction_completed(item_id: String, success: bool, extract_dir: String):
	# Check if this extraction has a pending callback (registry step tracking)
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		_pending_emulator_downloads.erase(item_id)
		
		# Clear validation cache for this emulator
		if task_info.has("emulator_id"):
			_validation_cache.erase(task_info.emulator_id)
		
		if task_info.has("callback"):
			task_info.callback.call(success, "")
			return
	
	# Find which emulator this extraction belongs to (fallback for non-registry extractions)
	for emulator_id in _emulator_install_progress.keys():
		if extract_dir.begins_with(_get_emulator_directory(emulator_id).rstrip("/")):
			# Clear validation cache
			_validation_cache.erase(emulator_id)
			
			if success:
				_emulator_install_progress[emulator_id] = ""
				emulator_extraction_completed.emit(emulator_id, true)
			else:
				_emulator_install_progress[emulator_id] = "Extraction failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return

## Called when DownloadManager completes a download
## Cleans up pending game downloads tracking
func _on_download_manager_download_completed(item_id: String, success: bool, message: String):
	# Handle game downloads
	if _pending_game_downloads.has(item_id):
		_pending_game_downloads.erase(item_id)
		return
	
	# Post-install downloads are handled by unified system
	# Let _on_unified_download_completed handle it

## Flattens an extracted directory by moving contents of a single top-level subdirectory up one level
## This handles zips that extract to a nested directory like "Archive-1.0/file.txt" -> "file.txt"
func _flatten_extracted_directory(emulator_id: String, extract_to: String, target_folder: String = ""):
	print("[LaunchManager] _flatten_extracted_directory called with extract_to=" + extract_to + ", target_folder=" + target_folder)
	# Android uses absolute paths, Desktop uses relative paths
	var extract_path: String
	if PlatformManager.is_android():
		# Handle "." as current directory
		if extract_to == ".":
			extract_path = _get_emulator_directory(emulator_id).rstrip("/")
		else:
			extract_path = extract_to
	else:
		# Handle "." as current directory on desktop too
		if extract_to == ".":
			extract_path = _get_emulator_directory(emulator_id).rstrip("/")
		elif extract_to.begins_with("/") or extract_to.begins_with("content://") or extract_to.begins_with("user://") or extract_to.begins_with("res://") or (extract_to.length() > 1 and extract_to[1] == ":"):
			# extract_to is already an absolute path (Unix, Windows, SAF, or Godot virtual filesystem style)
			extract_path = extract_to
		else:
			extract_path = _get_emulator_directory(emulator_id).rstrip("/") + "/" + extract_to
	
	# Normalize the path to remove "." and ".." components
	extract_path = FileSystemManager.normalize_path(extract_path)
	print("[LaunchManager] Flattening: normalized extract_path=" + extract_path)
	
	# Use SAF-aware operations if this is a SAF path
	var is_saf = FileSystemManager.is_saf_path(extract_path)
	print("[LaunchManager] Flattening: is_saf=" + str(is_saf))
	
	# If a specific target folder is specified, flatten only that one
	if target_folder != "":
		var target_path = ""
		
		# First try exact match
		var exact_path = extract_path + "/" + target_folder
		if FileSystemManager.dir_exists(exact_path):
			target_path = exact_path
		else:
			# Try wildcard match against entries in extract_path
			var candidates = FileSystemManager.list_dir(extract_path)
			for entry in candidates:
				if entry != "." and entry != ".." and entry.match(target_folder):
					if FileSystemManager.dir_exists(extract_path + "/" + entry):
						target_path = extract_path + "/" + entry
						break
		
		if target_path == "":
			return
		
		# Get list of items in the target folder
		var items = FileSystemManager.list_dir(target_path)
		
		# Move all contents from the subdirectory to the parent
		for item_name in items:
			if item_name == "." or item_name == "..":
				continue
			
			var source_path = target_path + "/" + item_name
			var dest_path = extract_path + "/" + item_name
			
			# Check if destination already exists
			if FileSystemManager.file_exists(dest_path) or FileSystemManager.dir_exists(dest_path):
				continue
			
			# Use SAF-aware move (can move to different parent directory)
			if not FileSystemManager.move(source_path, dest_path):
				push_warning("[LaunchManager] Failed to flatten item: " + source_path + " -> " + dest_path)
		
		# Remove the now-empty subdirectory
		# For SAF paths, the directory should be empty after moving all contents
		# For regular paths, use DirAccess
		if is_saf:
			# SAF doesn't have a direct directory delete, but it will be cleaned up
			pass
		else:
			var dir = DirAccess.open(extract_path)
			if dir:
				dir.remove(target_path)
		return
	
	# No target folder specified, use original logic (single directory only)
	# List all entries in the extract directory using SAF-aware method
	var entries = FileSystemManager.list_dir(extract_path)
	print("[LaunchManager] Flattening: entries in extract_path=" + str(entries))
	
	# Filter out . and ..
	var filtered_entries = []
	for entry in entries:
		if entry != "." and entry != "..":
			filtered_entries.append(entry)
	
	print("[LaunchManager] Flattening: filtered_entries=" + str(filtered_entries) + ", size=" + str(filtered_entries.size()))
	
	# If there's exactly one entry and it's a directory, flatten it
	if filtered_entries.size() == 1:
		var single_entry = filtered_entries[0]
		var single_entry_path = extract_path + "/" + single_entry
		print("[LaunchManager] Flattening: single_entry=" + single_entry + ", path=" + single_entry_path)
		
		# Check if the single entry is a directory
		var is_dir = FileSystemManager.dir_exists(single_entry_path)
		print("[LaunchManager] Flattening: is_dir=" + str(is_dir))
		if is_dir:
			# Get all items in the subdirectory
			var sub_items = FileSystemManager.list_dir(single_entry_path)
			print("[LaunchManager] Flattening: sub_items=" + str(sub_items))
			
			# Move all contents from the subdirectory to the parent
			for item_name in sub_items:
				if item_name == "." or item_name == "..":
					continue
				
				var source_path = single_entry_path + "/" + item_name
				var dest_path = extract_path + "/" + item_name
				print("[LaunchManager] Flattening: moving " + source_path + " -> " + dest_path)
				
				# Check if destination already exists
				if FileSystemManager.file_exists(dest_path) or FileSystemManager.dir_exists(dest_path):
					print("[LaunchManager] Flattening: destination already exists, skipping")
					continue
				
				# Use SAF-aware move (can move to different parent directory)
				var move_success = FileSystemManager.move(source_path, dest_path)
				print("[LaunchManager] Flattening: move result=" + str(move_success))
				if not move_success:
					push_warning("[LaunchManager] Failed to flatten item: " + source_path + " -> " + dest_path)
			
			# Remove the now-empty subdirectory
			if is_saf:
				# Use SAF-aware directory deletion
				var delete_success = FileSystemManager.delete_dir(single_entry_path)
				print("[LaunchManager] Flattening: SAF directory delete result=" + str(delete_success))
			else:
				var dir = DirAccess.open(extract_path)
				if dir:
					dir.remove(single_entry_path)
	else:
		print("[LaunchManager] Flattening: filtered_entries.size() != 1, skipping flatten")

## Gets the install path for an emulator (searches recursively)
func get_emulator_install_path(emulator_id: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	
	# Get executable name from new launch.platforms format
	var executable_name = ""
	var launch_config = emulator.get("launch", {})
	var platforms = launch_config.get("platforms", {})
	var platform_config = platforms.get(platform_name, {})
	if platform_config.has("executable"):
		executable_name = platform_config.get("executable", "")
	
	if executable_name == "":
		return ""
	
	# First check direct path
	var direct_path = _get_emulator_directory(emulator_id).rstrip("/") + "/" + executable_name
	if FileAccess.file_exists(direct_path):
		return direct_path
	
	# Search recursively up to 3 levels deep
	var search_dir = _get_emulator_directory(emulator_id).rstrip("/") + "/"
	var found_path = _find_executable_recursive(search_dir, executable_name, 3)
	
	if found_path != "":
		return found_path
	
	# Also check system PATH (for Linux system installs)
	if PlatformManager.is_linux() or PlatformManager.is_windows():
		var output = []
		var exit_code = OS.execute("which" if PlatformManager.is_linux() else "where", [executable_name], output, true)
		if exit_code == 0 and output.size() > 0:
			return output[0].strip_edges()
	
	return ""

## Gets the core name for a platform (for RetroArch-style emulators)
func get_core_for_platform(emulator_id: String, platform_slug: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var core_mappings = emulator.get("core_mappings", {})
	return core_mappings.get(platform_slug, "")

## Resolves which emulator to use for a game
## Priority: 1. Game override, 2. User platform setting, 3. Registry default
func resolve_emulator_for_game(game: GameResource) -> String:
	# 1. Check game override
	if game.preferred_emulator_id != "":
		return game.preferred_emulator_id
	
	# 2. Check user platform settings (empty = use registry default)
	var enabled_platforms = _get_enabled_platforms()
	var platform_config = enabled_platforms.get(game.platform_slug, {})
	var platform_emulator = platform_config.get("emulator_id", "")
	
	if platform_emulator != "":
		return platform_emulator
	
	# 3. Use registry default (from _platform_defaults or first available)
	return get_default_emulator_for_platform(game.platform_slug)

## Creates a launch intent for a game
func create_launch_intent(game: GameResource) -> LaunchIntent:
	if not game.is_active_variant_downloaded():
		push_error("[LaunchManager] Cannot launch game without local copy: " + game.get_display_name())
		return null
	
	var intent = LaunchIntent.new()
	intent.game = game
	
	# Get the correct file path for the active variant
	var active_file_name = game.get_active_file_name()
	
	# Use the actual file_path from game resource (contains content:// URI for SAF on Android)
	# Only fall back to constructing path if file_path is empty
	if game.file_path != "":
		intent.rom_path = game.file_path
	else:
		# Fallback: construct path from components (for legacy or if file_path not set)
		var root_folder = SettingsManager.get_setting("games_root_folder")
		var root_path = root_folder.value if root_folder else "user://roms/"
		intent.rom_path = root_path + "/" + game.platform_slug + "/" + active_file_name
	
	intent.platform_slug = game.platform_slug
	
	# Resolve emulator
	intent.emulator_id = resolve_emulator_for_game(game)
	if intent.emulator_id == "":
		push_error("[LaunchManager] No emulator configured for platform: " + game.platform_slug)
		return null
	
	var emulator = get_emulator(intent.emulator_id)
	intent.emulator_name = emulator.get("name", intent.emulator_id)
	
	# Get core if needed (for RetroArch)
	intent.core_name = get_core_for_platform(intent.emulator_id, game.platform_slug)
	
	# Build launch arguments based on platform
	_build_launch_args(intent, emulator)
	
	# NOTE: Emulator-specific preparation (TitleID extraction, game file extraction, etc.)
	# is done upstream in launch_game(), _queue_game_download_then_launch(), or
	# _on_emulator_installed_for_launch() BEFORE save sync. create_launch_intent()
	# only builds the launch arguments and should not perform any file I/O.
	
	return intent

func _build_launch_args(intent: LaunchIntent, emulator: Dictionary):
	var platform_name = PlatformManager.get_platform_name().to_lower()
	
	# Get launch configuration from new registry format
	var launch_config = emulator.get("launch", {})
	var platforms = launch_config.get("platforms", {})
	
	if PlatformManager.is_android():
		# Android uses intent-based launching
		var android_template = platforms.get("android", {})
		
		intent.android_action = android_template.get("action", "")
		intent.android_package = android_template.get("package", "")
		intent.android_class = android_template.get("class", "")
		# Extras is always an array in the new unified format
		intent.android_extras = android_template.get("extras", [])
		intent.android_config = android_template
		
		# Vita3K special handling - pass TitleID as command-line args via AppStartParameters
		# Vita3K expects StringArray extra with key "AppStartParameters" containing ["-r", "TitleID"]
		if intent.emulator_id.begins_with("vita3k") and intent.game and intent.game.title_id != "":
			intent.android_extras.append({
				"key": "AppStartParameters",
				"value": JSON.stringify(["-r", intent.game.title_id]),
				"type": "string_array"
			})
		
		# RPCS3/RPCSX special handling - pass boot path to the game folder
		if intent.emulator_id.begins_with("rpcs3") and intent.game and intent.game.title_id != "":
			var boot_path := "/storage/emulated/0/Android/data/net.rpcsx.ui/files/games/" + intent.game.title_id
			intent.android_extras.append({
				"key": "bootPath",
				"value": boot_path,
				"type": "string"
			})
	else:
		# Desktop uses command-line arguments
		var platform_config = platforms.get(platform_name, {})
		var template = platform_config.get("template", [])
		
		var install_path = get_emulator_install_path(intent.emulator_id)
		
		# Convert paths to absolute system paths for OS.execute
		var global_install_path = ProjectSettings.globalize_path(install_path)
		var global_rom_path = ProjectSettings.globalize_path(intent.rom_path)
		
		# Normalize paths to remove double slashes
		global_install_path = global_install_path.replace("//", "/")
		global_rom_path = global_rom_path.replace("//", "/")
		
		# On Windows, some emulators require native backslash paths
		if PlatformManager.is_windows() and emulator.get("requires_native_paths", false):
			global_install_path = global_install_path.replace("/", "\\")
			global_rom_path = global_rom_path.replace("/", "\\")
		
		# Build absolute core path
		var install_dir = global_install_path.get_base_dir()
		install_dir = install_dir.replace("//", "/")
		var core_extension = "_libretro.dll" if PlatformManager.is_windows() else "_libretro.so"
		var core_separator = "\\" if PlatformManager.is_windows() else "/"
		var global_core_path = install_dir + core_separator + "cores" + core_separator + intent.core_name + core_extension
		global_core_path = global_core_path.replace("//", "/")
		
		# Set working directory only if emulator requires it (e.g., xemu) or for Vita3K
		if emulator.get("requires_working_dir", false) or intent.emulator_id.begins_with("vita3k"):
			intent.working_directory = install_dir
		
		for arg in template:
			var formatted_arg = arg.replace("{exe}", global_install_path)
			formatted_arg = formatted_arg.replace("{rom}", global_rom_path)
			formatted_arg = formatted_arg.replace("{core}", global_core_path)
			intent.launch_args.append(formatted_arg)
		
		# Vita3K special handling for desktop - replace ROM path with TitleID
		if intent.emulator_id.begins_with("vita3k") and intent.game and intent.game.title_id != "":
			# Replace the ROM path (ZIP) with the TitleID flag
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = "-r"
					intent.launch_args.insert(i + 1, intent.game.title_id)
					break
		
		# RPCS3 special handling for desktop - replace ROM path with game folder path
		if intent.emulator_id.begins_with("rpcs3") and intent.game and intent.game.title_id != "":
			# Check both disc and digital install locations
			var disc_path: String = install_dir + "/games/" + intent.game.title_id
			var digital_path: String = install_dir + "/dev_hdd0/game/" + intent.game.title_id
			
			var game_path: String
			if FileSystemManager.dir_exists(disc_path):
				game_path = disc_path
			elif FileSystemManager.dir_exists(digital_path):
				game_path = digital_path
			else:
				# Fallback to disc path if neither exists (will fail gracefully later)
				game_path = disc_path
			
			print("[LaunchManager] RPCS3: Using game path: " + game_path)
			
			# Replace the ROM path (ZIP) with the game folder path
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = game_path
					break
		
		# shadPS4 special handling for desktop - replace ROM path with extracted game folder
		if intent.emulator_id == "shadps4" and intent.game and intent.game.title_id != "":
			var game_path: String = intent.rom_path.get_base_dir() + "/" + intent.game.title_id
			
			print("[LaunchManager] shadPS4: Using game path: " + game_path)
			
			# Replace the ROM path (ZIP) with the extracted game folder path
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = game_path
					break

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	if not intent or not intent.is_valid():
		push_error("[LaunchManager] Invalid launch intent")
		return false
	
	# Check if emulator is fully installed using step validation (all emulators use registry steps)
	var emulator = get_emulator(intent.emulator_id)
	var is_actually_installed = false
	var install_steps = emulator.get("install", [])
	is_actually_installed = true
	for i in range(install_steps.size()):
		if not _validate_install_step(intent.emulator_id, i, install_steps):
			is_actually_installed = false
			break
	
	if not is_actually_installed:
		push_error("[LaunchManager] Emulator not fully installed: " + intent.emulator_id)
		NotificationManager.show_notification("Emulator not ready: " + intent.emulator_name, Notification.Type.ERROR)
		return false
	
	# Controller configuration temporarily disabled - need to solve SDL device index mapping
	# TODO: Re-enable when SDL device index detection is implemented
	# Configure controllers for this emulator before launching
	# var should_continue = await _configure_emulator_controllers(intent)
	# if not should_continue:
	# 	return false
	
	if PlatformManager.is_android():
		return _execute_android(intent)
	else:
		return _execute_desktop(intent)

func _execute_desktop(intent: LaunchIntent) -> bool:
	if intent.launch_args.is_empty():
		push_error("[LaunchManager] No launch arguments for desktop")
		return false
	
	var exe_path = intent.launch_args[0]
	var arguments = intent.launch_args.slice(1)
	
	var pid: int
	
	# If working directory is specified, use shell wrapper to change directory first
	if intent.working_directory != "":
		# Build the command with proper quoting for each argument
		# Wrap each argument in quotes and escape any existing quotes
		var quoted_args = []
		for arg in arguments:
			var escaped = arg.replace('"', '\\"')
			quoted_args.append('"' + escaped + '"')
		
		if PlatformManager.is_windows():
			# Windows: use cmd /c "cd /d WORKING_DIR && exe args"
			var inner_cmd = 'cd /d "%s" && "%s" %s' % [
				intent.working_directory,
				exe_path,
				" ".join(quoted_args)
			]
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
		else:
			# Linux/macOS: use sh -c "cd WORKING_DIR && exe args"
			var inner_cmd = 'cd "%s" && "%s" %s' % [
				intent.working_directory,
				exe_path,
				" ".join(quoted_args)
			]
			pid = OS.create_process("sh", ["-c", inner_cmd], false)
	else:
		# No working directory specified, but still need to quote arguments properly
		# Build the command with proper quoting for each argument
		var quoted_args = []
		for arg in arguments:
			var escaped = arg.replace('"', '\\"')
			quoted_args.append('"' + escaped + '"')
		
		if PlatformManager.is_windows():
			# Windows: use cmd /c "exe args"
			var inner_cmd = '"%s" %s' % [
				exe_path,
				" ".join(quoted_args)
			]
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
		else:
			# Linux/macOS: use sh -c "exe args"
			var inner_cmd = '"%s" %s' % [
				exe_path,
				" ".join(quoted_args)
			]
			pid = OS.create_process("sh", ["-c", inner_cmd], false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to launch process: " + exe_path)
		launch_completed.emit(false, "Failed to start emulator")
		return false
	
	# Store PID and enter background state for desktop
	_enter_background_state(pid, intent.game)
	
	launch_completed.emit(true, "Game launched successfully")
	return true

## Configures controller settings for specific emulators before launch
const CONTROLLER_REGISTRY_PATH := "res://data/controller_registry.json"

var _controller_registry: Dictionary = {}

func _get_controller_registry() -> Dictionary:
	if _controller_registry.is_empty():
		_load_controller_registry()
	return _controller_registry

func _load_controller_registry() -> void:
	if not FileAccess.file_exists(CONTROLLER_REGISTRY_PATH):
		return
	
	var file = FileAccess.open(CONTROLLER_REGISTRY_PATH, FileAccess.READ)
	if not file:
		push_error("[LaunchManager] Failed to open controller registry")
		return
	
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("[LaunchManager] Failed to parse controller registry: " + json.get_error_message())
		return
	
	_controller_registry = json.data

func _configure_emulator_controllers(intent: LaunchIntent) -> bool:
	var registry = _get_controller_registry()
	if registry.is_empty():
		return true
	
	var emulator_id = intent.emulator_id
	if not registry.has(emulator_id):
		return true
	
	var config = registry[emulator_id]
	var tasks = config.get("tasks", [])
	
	var emulator_path = get_emulator_install_path(emulator_id)
	if emulator_path == "":
		return true
	
	# Get the directory containing the emulator (not the executable itself)
	var install_path = emulator_path.get_base_dir()
	
	for task in tasks:
		var should_continue = await _execute_controller_task(task, install_path)
		if not should_continue:
			return false
	
	return true

func _execute_controller_task(task: Dictionary, install_path: String) -> bool:
	var task_type = task.get("type", "")
	
	match task_type:
		"create_folders":
			_execute_controller_create_folders(task, install_path)
			return true
		"edit_file":
			return await _execute_controller_edit_file(task, install_path)
		_:
			return true

func _execute_controller_create_folders(task: Dictionary, install_path: String) -> void:
	var folders = task.get("folders", [])
	for folder in folders:
		var path = install_path + "/" + folder
		var dir = DirAccess.open(install_path)
		if dir:
			dir.make_dir_recursive(folder)

func _execute_controller_edit_file(task: Dictionary, install_path: String) -> bool:
	var file_path = task.get("file", "")
	var full_path = install_path + "/" + file_path
	
	# Validate existing config
	var validate = task.get("validate", {})
	if not validate.is_empty():
		var is_valid = _validate_controller_config(full_path, validate)
		if is_valid:
			return true
	
	# Show user prompt
	var emulator_name = _get_emulator_name_from_path(install_path)
	
	# Create and show dialog
	var dialog = ConfirmationDialog.new()
	dialog.title = "Controller Configuration"
	dialog.dialog_text = "Controller configuration for " + emulator_name + " is missing or incorrect.\n\nUpdate it now?"
	dialog.ok_button_text = "Yes"
	dialog.cancel_button_text = "No"
	dialog.min_size = Vector2(400, 150)
	dialog.exclusive = true  # Block input to other windows
	dialog.unresizable = true
	
	# Add to scene tree
	get_tree().root.add_child(dialog)
	
	# Use dictionary for reference semantics (lambdas capture by value)
	var dialog_state = {"confirmed": false, "responded": false}
	
	var on_confirmed = func():
		dialog_state.confirmed = true
		dialog_state.responded = true
	
	var on_canceled = func():
		dialog_state.confirmed = false
		dialog_state.responded = true
	
	dialog.confirmed.connect(on_confirmed)
	dialog.canceled.connect(on_canceled)
	
	# Show dialog after signals are connected
	dialog.popup_centered()
	
	# Wait for response
	while not dialog_state.responded:
		await get_tree().process_frame
	
	var confirmed = dialog_state.confirmed
	
	# Clean up
	dialog.queue_free()
	
	if not confirmed:
		return true  # Continue with launch
	
	# Apply edits
	var edits = task.get("edits", [])
	for edit in edits:
		var content = edit.get("content", "")
		if content != "":
			_execute_controller_file_edit(full_path, content)
	
	return true

func _validate_controller_config(file_path: String, validate: Dictionary) -> bool:
	var validate_type = validate.get("type", "")
	
	match validate_type:
		"section_contains":
			return _validate_section_contains(file_path, validate)
		_:
			return false

func _validate_section_contains(file_path: String, validate: Dictionary) -> bool:
	if not FileSystemManager.file_exists(file_path):
		return false
	
	var content = FileSystemManager.read_file(file_path)
	if content == "":
		return false
	
	var section = validate.get("section", "")
	var pattern = validate.get("pattern", "")
	
	# Find the section
	var section_start = content.find("[" + section + "]")
	if section_start == -1:
		return false
	
	# Find the next section or end of file
	var next_section = content.find("[", section_start + 1)
	var section_content = ""
	if next_section == -1:
		section_content = content.substr(section_start)
	else:
		section_content = content.substr(section_start, next_section - section_start)
	
	# Check if pattern exists in section
	return section_content.find(pattern) != -1

func _execute_controller_file_edit(file_path: String, content: String) -> void:
	var existing_content = ""
	
	if FileSystemManager.file_exists(file_path):
		existing_content = FileSystemManager.read_file(file_path)
	
	# Parse the new content to find sections we need to replace
	var new_sections = _parse_ini_sections(content)
	
	# Replace or append sections in existing content
	var final_content = existing_content
	for section_name in new_sections.keys():
		var section_content = new_sections[section_name]
		final_content = _replace_or_append_section(final_content, section_name, section_content)
	
	if not FileSystemManager.write_file(file_path, final_content):
		push_error("[LaunchManager] Failed to write: " + file_path)
		return

## Parse INI content into sections dictionary
func _parse_ini_sections(content: String) -> Dictionary:
	var sections = {}
	var current_section = ""
	var current_content = ""
	
	for line in content.split("\n"):
		var trimmed = line.strip_edges()
		if trimmed.begins_with("[") and trimmed.ends_with("]"):
			# Save previous section
			if current_section != "":
				sections[current_section] = current_content.strip_edges()
			# Start new section
			current_section = trimmed.substr(1, trimmed.length() - 2)
			current_content = line + "\n"
		elif current_section != "":
			current_content += line + "\n"
	
	# Save last section
	if current_section != "":
		sections[current_section] = current_content.strip_edges()
	
	return sections

## Replace a section in INI content or append if not exists
func _replace_or_append_section(content: String, section_name: String, section_content: String) -> String:
	var section_header = "[" + section_name + "]"
	var section_start = content.find(section_header)
	
	if section_start == -1:
		# Section doesn't exist, append it
		return content + "\n\n" + section_content
	
	# Find the end of this section (start of next section or end of file)
	var next_section = content.find("[", section_start + section_header.length())
	
	var before_section = content.substr(0, section_start)
	var after_section = ""
	if next_section != -1:
		after_section = content.substr(next_section)
	
	# Combine: before + new section + after
	return before_section + section_content + "\n\n" + after_section

func _get_emulator_name_from_path(install_path: String) -> String:
	# Extract emulator ID from path
	var parts = install_path.split("/")
	if parts.size() > 0:
		return parts[-1]
	return "emulator"

## Main entry point for launching a game
func launch_game(game: GameResource, focus_index: int = -1) -> void:
	print("[LaunchManager] launch_game() called for: ", game.get_display_name() if game else "null", " with focus_index: ", focus_index)
	
	# Emit signal immediately so focus can be saved before any suspension happens
	print("[LaunchManager] Emitting game_launch_initiated signal")
	game_launch_initiated.emit(game, focus_index)
	
	# DEBUG: Uncomment the next line to disable actual game launching
	# return
	
	# Play launch sound
	if AudioManager:
		AudioManager.play_sfx("affirm_00")
	
	# Check if this is a GameNative game
	if game.source == "gamenative":
		_launch_gamenative_game(game)
		return
	
	# If game is not downloaded, queue the download first then proceed
	if not game.is_active_variant_downloaded():
		_queue_game_download_then_launch(game)
		return
	
	# Game is downloaded, prepare emulator-specific data first
	var emulator_id = resolve_emulator_for_game(game)
	print("[LaunchManager] Resolved emulator for game: '" + emulator_id + "'")
	
	# Prepare emulator-specific data (extract TitleIDs, game files, etc.)
	# This must happen before save sync so the title_id is available
	print("[LaunchManager] launch_game: Preparing game for emulator: " + emulator_id)
	var prep_success = await _prepare_game_for_launch(game, emulator_id)
	if not prep_success:
		push_error("[LaunchManager] Failed to prepare game for launch: " + game.get_display_name())
		NotificationManager.show_notification("Failed to prepare game for launch", Notification.Type.ERROR)
		return
	print("[LaunchManager] launch_game: Game preparation complete")
	
	# Sync saves first then proceed with launch
	if emulator_id != "":
		print("[LaunchManager] Starting pre-launch save sync...")
		SaveManager.auto_download_saves_for_game(game, emulator_id, func():
			print("[LaunchManager] Pre-launch save sync complete, proceeding with launch")
			_launch_with_emulator_check(game)
		)
	else:
		_launch_with_emulator_check(game)

## Launch a GameNative game via intent
func _launch_gamenative_game(game: GameResource) -> void:
	if not PlatformManager.is_android():
		push_error("[LaunchManager] Cannot launch GameNative game on non-Android platform")
		NotificationManager.show_notification("GameNative games only available on Android", Notification.Type.ERROR)
		return
	
	var success = GameNativeManager.launch_game(game.steam_app_id)
	if success:
		_update_last_played(game)
		game_launched.emit(game)
	else:
		push_error("[LaunchManager] Failed to launch GameNative game")
		NotificationManager.show_notification("Failed to launch GameNative. Is the app installed?", Notification.Type.ERROR)
	
## If game is not downloaded, queue the download first then proceed
func _queue_game_download_then_launch(game: GameResource) -> void:
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		NotificationManager.show_notification("Error: Games folder not set", Notification.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	
	NotificationManager.show_notification("Downloading " + game.get_display_name() + "...", Notification.Type.INFO)
	
	# Define callback for when download completes
	var on_download_complete = func(success: bool, _path: String):
		if success:
			var updated_game = DataManager.get_game_by_id(game.romm_id)
			var game_to_launch = updated_game if updated_game else game
			var emulator_id = resolve_emulator_for_game(game_to_launch)
			
			# Prepare emulator-specific data after download (extract TitleIDs, game files, etc.)
			print("[LaunchManager] _queue_game_download_then_launch: Preparing game for emulator: " + emulator_id)
			var prep_success = await _prepare_game_for_launch(game_to_launch, emulator_id)
			if not prep_success:
				push_error("[LaunchManager] Failed to prepare game after download: " + game_to_launch.get_display_name())
				NotificationManager.show_notification("Failed to prepare game for launch", Notification.Type.ERROR)
				return
			print("[LaunchManager] _queue_game_download_then_launch: Game preparation complete")
			
			if emulator_id != "":
				print("[LaunchManager] Starting pre-launch save sync after game download...")
				SaveManager.auto_download_saves_for_game(game_to_launch, emulator_id, func():
					print("[LaunchManager] Pre-launch save sync complete, proceeding with launch")
					_launch_with_emulator_check(game_to_launch)
				)
			else:
				_launch_with_emulator_check(game_to_launch)
		else:
			NotificationManager.show_notification("Download failed for " + game.get_display_name(), Notification.Type.ERROR)
	
	# Queue download with callback to continue launch flow
	var item_id = DownloadManager.queue_download(
		download_url,
		destination_path,
		"game",
		game.get_display_name(),
		false,
		"",
		game,
		{"on_complete": on_download_complete},
		active_game_id
	)
	
	if item_id == "":
		NotificationManager.show_notification("Failed to queue download", Notification.Type.ERROR)

## Check emulator status and launch game (game must be downloaded)
func _launch_with_emulator_check(game: GameResource) -> void:
	print("[LaunchManager] _launch_with_emulator_check: ENTER for " + game.get_display_name())
	
	# Determine which emulator to use
	var emulator_id = resolve_emulator_for_game(game)
	
	# Check if this game is already pending launch (waiting for emulator install)
	if _pending_launches.has(emulator_id):
		var pending_game: GameResource = _pending_launches[emulator_id]
		if pending_game.romm_id == game.romm_id:
			NotificationManager.show_notification("Game already pending launch! Waiting for emulator installation...", Notification.Type.WARNING)
			return
	
	if emulator_id == "":
		NotificationManager.show_notification("No emulator configured for platform: " + game.platform_slug, Notification.Type.ERROR)
		return
	
	var emulator = get_emulator(emulator_id)
	var emulator_name = emulator.get("name", emulator_id)
	
	# Check if emulator is fully installed using step validation
	# All emulators use registry-based install steps
	var is_actually_installed = false
	var install_steps = emulator.get("install", [])
	is_actually_installed = true
	for i in range(install_steps.size()):
		if not _validate_install_step(emulator_id, i, install_steps):
			is_actually_installed = false
			break
	
	if not is_actually_installed:
		NotificationManager.show_notification("Setting up " + emulator_name + "...", Notification.Type.INFO)
		
		# Queue download/install - this will handle extraction and post-install
		var download_success = download_emulator(emulator_id)
		
		if download_success:
			NotificationManager.show_notification(emulator_name + " downloading... Will auto-launch when ready.", Notification.Type.INFO)
			
			# Store this launch as pending - it will be retried when installation completes
			_pending_launches[emulator_id] = game
			
			# Connect to extraction completion signal if not already connected
			if not emulator_extraction_completed.is_connected(_on_emulator_installed_for_launch):
				emulator_extraction_completed.connect(_on_emulator_installed_for_launch)
		else:
			NotificationManager.show_notification("Failed to queue " + emulator_name + " download", Notification.Type.ERROR)
		return
	
	# Emulator is already installed, launch immediately
	print("[LaunchManager] _launch_with_emulator_check: Emulator installed, launching game")
	_launch_game_internal(game, emulator_id)
	print("[LaunchManager] _launch_with_emulator_check: EXIT")

## Handler for when emulator extraction completes - retries pending launches
func _on_emulator_installed_for_launch(emulator_id: String, success: bool):
	if not success:
		return
	
	# Check if emulator is actually fully installed by validating all registry steps
	var emulator = get_emulator(emulator_id)
	if not emulator.is_empty() and emulator.has("install"):
		var install_steps = emulator.get("install", [])
		var all_valid = true
		for i in range(install_steps.size()):
			if not _validate_install_step(emulator_id, i, install_steps):
				all_valid = false
				break
		if not all_valid:
			# Post-install is still running, wait for it to complete
			return
	
	# Check if we have a pending launch for this emulator
	if _pending_launches.has(emulator_id):
		var game: GameResource = _pending_launches[emulator_id]
		_pending_launches.erase(emulator_id)
		NotificationManager.show_notification("Launching " + game.get_display_name() + "...", Notification.Type.INFO)
		
		# Give a small delay for file system to settle
		await get_tree().create_timer(0.5).timeout
		
		# Prepare game data before launching (extract TitleIDs, etc.)
		print("[LaunchManager] _on_emulator_installed_for_launch: Preparing game for emulator: " + emulator_id)
		var prep_success = await _prepare_game_for_launch(game, emulator_id)
		if not prep_success:
			push_error("[LaunchManager] Failed to prepare game after emulator install: " + game.get_display_name())
			NotificationManager.show_notification("Failed to prepare game for launch", Notification.Type.ERROR)
			return
		print("[LaunchManager] _on_emulator_installed_for_launch: Game preparation complete")
		
		# Retry the launch
		await _launch_game_internal(game, emulator_id)

## Internal function to actually launch the game (emulator must be installed)
func _launch_game_internal(game: GameResource, emulator_id: String) -> void:
	print("[LaunchManager] _launch_game_internal: ENTER for " + game.get_display_name() + " (emulator: " + emulator_id + ")")
	
	var intent = await create_launch_intent(game)
	
	if not intent:
		push_error("[LaunchManager] _launch_game_internal: create_launch_intent returned null")
		NotificationManager.show_notification("Failed to create launch intent", Notification.Type.ERROR)
		print("[LaunchManager] _launch_game_internal: EXIT (null intent)")
		return
	
	print("[LaunchManager] _launch_game_internal: Launch intent created, executing launch...")
	var success = await execute_launch(intent)
	
	if not success:
		push_error("[LaunchManager] _launch_game_internal: execute_launch returned false")
		NotificationManager.show_notification("Failed to launch " + game.get_display_name(), Notification.Type.ERROR)
		print("[LaunchManager] _launch_game_internal: EXIT (launch failed)")
		return
	
	print("[LaunchManager] _launch_game_internal: Launch successful")
	
	# Update last_played timestamp on successful launch
	_update_last_played(game)
	print("[LaunchManager] _launch_game_internal: EXIT (success)")

## Update the last_played timestamp for a game
func _update_last_played(game: GameResource) -> void:
	var timestamp = Time.get_datetime_string_from_system(false, true)  # UTC format
	game.last_played = timestamp
	
	# Update in database
	DataManager.update_game_last_played(game.romm_id, timestamp)
	
	# Notify views that game was launched (so they can re-sort)
	game_launched.emit(game)

func _execute_android(intent: LaunchIntent) -> bool:
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_error("[LaunchManager] PackageChecker plugin not available for Android launch")
		return false
	
	# Check if we need MANAGE_EXTERNAL_STORAGE permission for FileProvider to work with SD cards
	if plugin.has_method("hasManageExternalStoragePermission"):
		if not plugin.hasManageExternalStoragePermission():
			push_warning("[LaunchManager] MANAGE_EXTERNAL_STORAGE permission not granted - FileProvider may fail for SD card files")
			# Show dialog to user explaining they need to grant the permission manually
			if UIManager:
				var dialog = ConfirmationDialog.new()
				dialog.title = "Permission Required"
				dialog.dialog_text = "To launch games from SD card storage, Kyodai needs 'All Files Access' permission.\n\nPlease grant this permission in Settings → Apps → Kyodai → Permissions → Files"
				dialog.ok_button_text = "Open Settings"
				dialog.cancel_button_text = "Cancel"
				
				var on_confirmed = func():
					if plugin.has_method("requestManageExternalStoragePermission"):
						plugin.requestManageExternalStoragePermission()
				
				dialog.confirmed.connect(on_confirmed)
				UIManager.add_child(dialog)
				dialog.popup_centered()
			return false
	
	# Format the core path for RetroArch
	var core_path = ""
	
	# Check if using CoreSideloadActivity (for testing sideloaded cores)
	if intent.android_class == "com.retroarch.browser.debug.CoreSideloadActivity":
		# Use downloaded core from shared storage
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Cores are downloaded to shared RetroArch directory
			core_path = "/storage/emulated/0/RetroArch/cores/" + core_filename
	else:
		# Regular RetroArch launch - use internal core path
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Build core path using the actual package name from intent
			var retroarch_package = intent.android_package
			if retroarch_package != "":
				core_path = "/data/data/" + retroarch_package + "/cores/" + core_filename
			else:
				# Fallback if package name is somehow empty
				core_path = "/data/data/com.retroarch/cores/" + core_filename
	
	# Get configuration from android_config
	var rom_delivery = intent.android_config.get("rom_delivery", "intent_data")
	var mime_type = intent.android_config.get("mime_type", "application/octet-stream")
	var clear_task = intent.android_config.get("clear_task", true)
	var grant_uri_permission = intent.android_config.get("grant_uri_permission", true)
	var use_document_uri = intent.android_config.get("use_document_uri", false)
	var use_file_uri = intent.android_config.get("use_file_uri", false)
	
	# Convert extras array to JSON string
	var extras_array = intent.android_extras
	if extras_array.is_empty() and intent.android_config.has("extras"):
		extras_array = intent.android_config.get("extras", [])
	
	# Convert extras to JSON using proper JSON.stringify to handle escaping correctly
	var extras_json = "[]"
	if extras_array.size() > 0:
		var extras_to_serialize = []
		for extra in extras_array:
			extras_to_serialize.append({
				"key": extra.get("key", ""),
				"value": extra.get("value", ""),
				"type": extra.get("type", "string")
			})
		var json_result = JSON.stringify(extras_to_serialize)
		if json_result == "":
			push_error("[LaunchManager] Failed to serialize extras to JSON")
		else:
			extras_json = json_result
	
	# Launch using unified method
	var success = plugin.call("launchAndroidIntent",
		intent.android_action,
		intent.android_package,
		intent.android_class,
		intent.rom_path,
		core_path,
		rom_delivery,
		extras_json,
		mime_type,
		clear_task,
		grant_uri_permission,
		use_document_uri,
		use_file_uri
	)
	
	if not success:
		push_error("[LaunchManager] Failed to launch Android intent")
	
	return success

## Helper: Get enabled platforms from settings
func _get_enabled_platforms() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

# ==================== EMULATOR DOWNLOAD ====================

func download_emulator(emulator_id: String) -> bool:
	# Check if already downloading/extracting
	for item_id in _pending_emulator_downloads:
		if _pending_emulator_downloads[item_id].emulator_id == emulator_id:
			return false
	
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[LaunchManager] Unknown emulator: " + emulator_id)
		return false
	
	# Get install steps from new step-based format
	var install_steps = emulator.get("install", [])
	if install_steps.is_empty():
		push_error("[LaunchManager] No install steps defined for: " + emulator_id)
		return false
	
	# Ensure emulator directory exists before starting install (creates on desktop and SAF)
	var emulator_dir = _get_emulator_directory(emulator_id)
	if not FileSystemManager.dir_exists(emulator_dir):
		print("[LaunchManager] Creating emulator directory: " + emulator_dir)
		if not FileSystemManager.make_dir_recursive(emulator_dir):
			push_error("[LaunchManager] Failed to create emulator directory: " + emulator_dir)
			return false
		print("[LaunchManager] Successfully created emulator directory")
	
	return _execute_install_steps(emulator_id, emulator, install_steps)

## Executes a single install step by index
func _execute_install_step(emulator_id: String, step_index: int) -> bool:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[LaunchManager] Unknown emulator: " + emulator_id)
		return false
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var emulator_name = emulator.get("name", emulator_id)
	var install_steps = emulator.get("install", [])
	
	if step_index >= install_steps.size():
		# All steps completed successfully
		_emulator_install_progress[emulator_id] = ""
		emulator_extraction_completed.emit(emulator_id, true)
		return true
	
	var step = install_steps[step_index]
	var step_name = step.get("step", "")
	var platform_config = _get_step_platform_config(step)
	
	if platform_config.is_empty():
		push_error("[LaunchManager] No platform config for step '" + step_name + "' on platform: " + platform_name)
		return false
	
	var action_type = platform_config.get("action_type", "")
	
	# Route to appropriate handler based on action type
	match action_type:
		"download_url":
			return _handle_download_url_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"download_repo":
			return _handle_download_repo_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"download_scrape":
			return _handle_download_scrape_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"extract":
			return _execute_extract_step(emulator_id, step_index, platform_config)
		"apk_install":
			return _execute_apk_install_step(emulator_id, step_index, platform_config)
		"batch_url_download":
			return _execute_batch_url_download_step(emulator_id, step_index, platform_config)
		"create_folders":
			return _handle_create_folders_step(emulator_id, step_name, step_index, platform_config)
		"create_files":
			return _handle_create_files_step(emulator_id, step_name, step_index, platform_config)
		"create_pcsx2_superblock":
			return _handle_create_pcsx2_superblock_step(emulator_id, step_name, step_index, platform_config)
		"edit_file":
			return _handle_edit_file_step(emulator_id, step_name, step_index, platform_config)
		"none":
			return _handle_none_step(emulator_id, step_name, step_index)
		_:
			push_error("[LaunchManager] Unknown action_type '" + action_type + "' for step: " + step_name)
			return false

## Re-runs a previous install step when current step needs it
## Use this when a step's input (downloaded file, etc.) is missing
func _retry_previous_step(emulator_id: String, current_step_index: int) -> bool:
	var target_step = current_step_index - 1
	if target_step < 0:
		push_error("[LaunchManager] Cannot retry - would go before first step")
		return false
	
	return _execute_install_step(emulator_id, target_step)

## Executes APK install action for a step (Android only)
## Uses simple file:// URI approach with OS.shell_open()
## APKs are downloaded to user://temp_apk/ to avoid SAF complications
func _execute_apk_install_step(emulator_id: String, step_index: int, apk_config: Dictionary) -> bool:
	var package_name = apk_config.get("package_name", "")
	
	if package_name == "":
		push_error("[LaunchManager] No package_name specified for apk_install")
		return false
	
	# Check if this is the first step (can't go back)
	if step_index == 0:
		push_error("[LaunchManager] Cannot install APK - no previous download step")
		return false
	
	# Get expected filename pattern from config
	var expected_file = apk_config.get("expected_file", "")
	if expected_file == "":
		push_error("[LaunchManager] No expected_file specified for apk_install - cannot find APK to install")
		return false
	
	print("[LaunchManager] Executing APK install step...")
	print("[LaunchManager]   - package_name: '" + package_name + "'")
	print("[LaunchManager]   - expected_file: '" + expected_file + "'")
	
	# APKs are always downloaded to user://temp_apk/ (not SAF)
	var temp_apk_dir = "user://temp_apk/"
	var apk_path = ""
	
	# Find the APK file in temp directory
	var dir = DirAccess.open(temp_apk_dir)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.match(expected_file):
				apk_path = temp_apk_dir + file_name
				print("[LaunchManager] Found APK: " + apk_path)
				break
			file_name = dir.get_next()
		dir.list_dir_end()
	
	# If no APK found, retry download
	if apk_path == "":
		print("[LaunchManager] No APK found in temp directory, retrying download")
		return _retry_previous_step(emulator_id, step_index)
	
	# Convert to absolute path for Android
	var absolute_apk_path = ProjectSettings.globalize_path(apk_path)
	
	# Validate APK file exists and has content
	var file = FileAccess.open(apk_path, FileAccess.READ)
	if file:
		var file_size = file.get_length()
		file.close()
		print("[LaunchManager] APK file size: " + str(file_size) + " bytes")
		if file_size < 1000:
			print("[LaunchManager] ERROR: APK file is too small or empty!")
			NotificationManager.show_notification(
				"APK download incomplete!\nFile size: " + str(file_size) + " bytes",
				Notification.Type.ERROR,
				null,
				10.0
			)
			_emulator_install_progress[emulator_id] = "APK download incomplete"
			return false
	else:
		print("[LaunchManager] ERROR: Cannot open APK file!")
		return _retry_previous_step(emulator_id, step_index)
	
	var uri = "file://" + absolute_apk_path
	
	print("[LaunchManager] Installing APK: " + apk_path)
	print("[LaunchManager] Absolute path: " + absolute_apk_path)
	print("[LaunchManager] Opening APK with URI: " + uri)
	
	# Open APK for installation using OS.shell_open
	# Note: Requires "Install unknown apps" permission in Android Settings
	var result = OS.shell_open(uri)
	
	if result != Error.OK:
		print("[LaunchManager] APK install failed with error: " + str(result))
		NotificationManager.show_notification(
			"APK install failed!\nPlease install manually from:\n" + absolute_apk_path,
			Notification.Type.ERROR,
			null,
			10.0
		)
		
		# Try to open the folder
		var folder_result = OS.shell_open(ProjectSettings.globalize_path(temp_apk_dir))
		if folder_result == Error.OK:
			print("[LaunchManager] Opened folder containing APK")
		
		_emulator_install_progress[emulator_id] = "APK install failed"
		return false
	
	print("[LaunchManager] APK installer opened successfully")
	print("[LaunchManager] User must complete installation in Android UI")
	
	# DEBUG: Don't delete APK so we can check it
	print("[LaunchManager] DEBUG: Keeping APK for inspection: " + apk_path)
	# TODO: Re-enable deletion after debugging
	# var delete_result = DirAccess.remove_absolute(apk_path)
	# if delete_result == OK:
	# 	print("[LaunchManager] Deleted APK after install attempt")
	# else:
	# 	print("[LaunchManager] Could not delete APK: " + str(delete_result))
	
	# Validate installation
	var validate_config = apk_config.get("validate", {})
	if not _validate_step(emulator_id, validate_config):
		# Don't fail here - user might still be installing
		pass
	
	# Progress to next step
	_execute_install_step(emulator_id, step_index + 1)
	return true

## Executes batch URL download action for downloading multiple files
## Downloads all items in parallel and extracts them automatically
func _execute_batch_url_download_step(emulator_id: String, step_index: int, batch_config: Dictionary) -> bool:
	# Get configuration
	var base_url = batch_config.get("base_url", "")
	var url_pattern = batch_config.get("url_pattern", "{name}")
	var cores = batch_config.get("cores", [])
	var extract_to = batch_config.get("extract_to", ".")
	
	# Resolve {emulator_dir} templates
	extract_to = _resolve_emulator_path(extract_to, emulator_id)
	
	if base_url == "":
		push_error("[LaunchManager] No base_url specified for batch_url_download")
		return false
	
	if cores.is_empty():
		push_error("[LaunchManager] No cores specified for batch_url_download")
		return false
	
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Get step name for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var step_display_name = _get_step_display_name(step_name)
	
	# Track batch progress using Dictionary for proper reference semantics in closures
	var total_cores = cores.size()
	var progress = {"completed": 0, "failed": 0}
	var download_ids = []
	
	# Set progress text
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(total_cores) + ")"
	
	# Queue all downloads
	for core_name in cores:
		# Construct URL from pattern
		var filename = url_pattern.replace("{name}", core_name)
		var full_url = base_url + filename
		
		# Determine extract directory
		var extract_dir: String
		if extract_to.begins_with("/") or extract_to.begins_with("content://"):
			# Absolute path or SAF URI
			extract_dir = extract_to
		elif extract_to == ".":
			# Current directory - use emulator directory directly (don't append ".")
			extract_dir = _get_emulator_directory(emulator_id).rstrip("/")
		else:
			extract_dir = _get_emulator_directory(emulator_id) + extract_to
		
		# Normalize the path to remove "." and ".." components
		extract_dir = FileSystemManager.normalize_path(extract_dir)
		
		# Download to emulator directory (for extraction, then delete)
		var destination_path = _get_emulator_directory(emulator_id) + filename
		
		# Queue download without auto-extract (extraction happens in separate step)
		var item_id = DownloadManager.queue_download(
			full_url,
			destination_path,
			"emulator_core",
			core_name,
			false,  # auto_extract - extraction handled by install_cores step
			"",     # extract_dir - not used here
			null,   # game
			{},     # callbacks
			0,      # romm_id
			false   # delete_after_extract - keep zips for extraction step
		)
		
		if item_id == "":
			progress.failed += 1
		else:
			download_ids.append(item_id)
			
			# Create a callback that captures by reference (Dictionary is a reference type)
			var callback = func(success: bool, message: String):
				progress.completed += 1
				if not success:
					progress.failed += 1
				# Update progress
				_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")"
				# Check if all downloads are complete
				if progress.completed >= total_cores:
					if progress.failed > 0:
						push_error("[LaunchManager] Batch download failed: " + str(progress.failed) + "/" + str(total_cores) + " cores failed")
						_emulator_install_progress[emulator_id] = "Batch download failed"
					else:
						_execute_install_step(emulator_id, step_index + 1)
			
			# Track completion
			_pending_emulator_downloads[item_id] = {
				"emulator_id": emulator_id,
				"context": "batch_download",
				"step_index": step_index,
				"core_name": core_name,
				"callback": callback
			}
	
	if download_ids.is_empty():
		push_error("[LaunchManager] No downloads could be queued for batch_url_download")
		return false
	
	return true

## Executes extract action for a step
func _execute_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary) -> bool:
	var extract_to = extract_config.get("extract_to", ".")
	var strip_top = extract_config.get("strip_top_directory", false)
	var flatten_target = extract_config.get("flatten_target", "")
	
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Resolve {emulator_dir} templates
	extract_to = _resolve_emulator_path(extract_to, emulator_id)
	
	# Handle extract_to: absolute paths are used directly, relative paths are relative to emulator dir
	var extract_dir: String
	if extract_to.begins_with("/") or extract_to.begins_with("content://"):
		# Absolute path (e.g., Android /storage/emulated/0/... or SAF URI)
		extract_dir = extract_to
	elif extract_to == ".":
		# Current directory - use emulator directory directly (don't append ".")
		extract_dir = _get_emulator_directory(emulator_id).rstrip("/")
	else:
		# Relative path (default behavior for desktop)
		extract_dir = _get_emulator_directory(emulator_id) + extract_to
	
	# Normalize the path to remove "." and ".." components
	extract_dir = FileSystemManager.normalize_path(extract_dir)
	
	# NEW LOGIC: Check validation first (output files exist?)
	if _validate_install_step(emulator_id, step_index, install_steps):
		_execute_install_step(emulator_id, step_index + 1)
		return true
	
	# Look for the archive file to extract
	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var archive_path = ""
	var is_batch_mode = extract_config.get("batch", false)
	
	if is_batch_mode:
		# Batch mode: extract all matching archives
		return _execute_batch_extract_step(emulator_id, step_index, extract_config, extract_dir, strip_top, flatten_target)
	
	# Single archive mode (default behavior)
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	print("[LaunchManager] _execute_extract_step: expected_file pattern='" + expected_file + "'")
	if expected_file != "":
		var files = FileSystemManager.list_dir(emulator_dir)
		print("[LaunchManager] _execute_extract_step: files in emulator_dir=" + str(files))
		for file_name in files:
			print("[LaunchManager] _execute_extract_step: checking if '" + file_name + "' matches pattern '" + expected_file + "'")
			if file_name.match(expected_file):
				var full_path = emulator_dir + "/" + file_name
				print("[LaunchManager] _execute_extract_step: MATCH! full_path=" + full_path)
				if FileSystemManager.file_exists(full_path):
					archive_path = full_path
					print("[LaunchManager] _execute_extract_step: archive_path set to " + archive_path)
					break
				else:
					print("[LaunchManager] _execute_extract_step: file exists check failed for " + full_path)
		print("[LaunchManager] _execute_extract_step: after expected_file loop, archive_path=" + archive_path)
	
	# If no expected_file match, scan for common archive extensions (first match only)
	if archive_path == "":
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var files = FileSystemManager.list_dir(emulator_dir)
		for file_name in files:
			var lower_name = file_name.to_lower()
			for ext in archive_extensions:
				if lower_name.ends_with(ext):
					var full_path = emulator_dir + "/" + file_name
					if FileSystemManager.file_exists(full_path):
						archive_path = full_path
						break
			if archive_path != "":
				break
	
	# Check if archive was found
	if archive_path == "" or not FileSystemManager.file_exists(archive_path):
		# Go back to download step to re-download
		return _retry_previous_step(emulator_id, step_index)
	
	# Get step name from install_steps for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var step_display_name = _get_step_display_name(step_name)
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Queue extraction via DownloadManager
	var item_id = DownloadManager.queue_extraction(archive_path, extract_dir, "emulator", step_display_name)
	if item_id == "":
		push_error("[LaunchManager] Failed to queue extraction for: " + emulator_id)
		return false
	
	# Create callback for single archive extraction
	var extraction_callback = func(success: bool, message: String):
		if not success:
			_emulator_install_progress[emulator_id] = "Extraction failed"
			emulator_extraction_completed.emit(emulator_id, false)
			return
		
		# Handle post-extraction flattening
		print("[LaunchManager] Extraction callback called, strip_top=" + str(strip_top) + ", flatten_target=" + flatten_target)
		if strip_top:
			print("[LaunchManager] Calling _flatten_extracted_directory with extract_dir=" + extract_dir)
			_flatten_extracted_directory(emulator_id, extract_dir, flatten_target)
		else:
			print("[LaunchManager] Skipping flattening, strip_top is false")
		
		# Validate extraction
		var validate_config = extract_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[LaunchManager] Validation failed after extraction: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Validation failed"
			emulator_extraction_completed.emit(emulator_id, false)
			return
		
		# Progress to next step
		_execute_install_step(emulator_id, step_index + 1)
	
	# Track extraction completion
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "extraction",
		"step_index": step_index,
		"step_config": extract_config,
		"callback": extraction_callback
	}
	
	return true

## Executes batch extraction for multiple archives
func _execute_batch_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary, extract_dir: String, strip_top: bool, flatten_target: String) -> bool:
	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var archive_paths = []
	
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	if expected_file != "":
		var files = FileSystemManager.list_dir(emulator_dir)
		for file_name in files:
			if file_name.match(expected_file):
				var full_path = emulator_dir + "/" + file_name
				if FileSystemManager.file_exists(full_path):
					archive_paths.append(full_path)
	
	# If no expected_file match, scan for common archive extensions
	if archive_paths.is_empty():
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var files = FileSystemManager.list_dir(emulator_dir)
		for file_name in files:
			var lower_name = file_name.to_lower()
			for ext in archive_extensions:
				if lower_name.ends_with(ext):
					var full_path = emulator_dir + "/" + file_name
					if FileSystemManager.file_exists(full_path):
						archive_paths.append(full_path)
						break
	
	# Check if any archives were found
	if archive_paths.is_empty():
		# Go back to download step to re-download
		return _retry_previous_step(emulator_id, step_index)
	
	# Get step name from install_steps for display
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var step_display_name = _get_step_display_name(step_name)
	
	# Show batch progress
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(archive_paths.size()) + ")"
	
	# Track progress for multiple extractions using Dictionary (reference type for closures)
	var total_archives = archive_paths.size()
	var progress = {"completed": 0, "failed": 0}
	var extraction_ids = []
	
	# Queue extraction for all archives
	for archive_path in archive_paths:
		var item_id = DownloadManager.queue_extraction(archive_path, extract_dir, "emulator", step_display_name)
		if item_id == "":
			push_error("[LaunchManager] Failed to queue extraction for: " + archive_path)
			progress.failed += 1
		else:
			extraction_ids.append(item_id)
	
	if extraction_ids.is_empty():
		push_error("[LaunchManager] No extractions could be queued for batch: " + emulator_id)
		return false
	
	# Create callback for batch extraction (shared by all archives)
	var batch_callback = func(success: bool, message: String):
		progress.completed += 1
		
		if not success:
			progress.failed += 1
		
		# Update progress
		_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_archives) + ")"
		
		# Check if all extractions are complete
		if progress.completed >= total_archives:
			if progress.failed > 0:
				_emulator_install_progress[emulator_id] = "Extraction failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Handle post-extraction flattening
			if strip_top:
				_flatten_extracted_directory(emulator_id, extract_dir, flatten_target)
			
			# Validate extraction
			var validate_config = extract_config.get("validate", {})
			if not _validate_step(emulator_id, validate_config):
				push_error("[LaunchManager] Validation failed after batch extraction: " + emulator_id)
				_emulator_install_progress[emulator_id] = "Validation failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Progress to next step
			_execute_install_step(emulator_id, step_index + 1)
	
	# Track extraction completion for each archive
	for item_id in extraction_ids:
		_pending_emulator_downloads[item_id] = {
			"emulator_id": emulator_id,
			"context": "extraction",
			"step_index": step_index,
			"step_config": extract_config,
			"callback": batch_callback
		}
	
	return true

func _validate_step(emulator_id: String, validate_config: Dictionary) -> bool:
	if validate_config.is_empty():
		return true
	
	var action_type = validate_config.get("action_type", "")
	
	match action_type:
		"file_exists":
			var file_path = validate_config.get("file", "")
			if file_path == "":
				return true
			var full_path = _resolve_validation_path(emulator_id, file_path)
			return FileSystemManager.file_exists(full_path)
		
		"folder_exists":
			var folder_path = validate_config.get("path", "")
			if folder_path == "":
				return true
			var full_path = _resolve_validation_path(emulator_id, folder_path)
			return FileSystemManager.dir_exists(full_path)
		
		"files_exist":
			var folder_path = validate_config.get("path", "")
			var pattern = validate_config.get("pattern", "")
			var files_array = validate_config.get("files", [])
			
			# Support both "files" array format and "path" + "pattern" format
			if files_array.size() > 0:
				# Check if all files in the array exist
				for file_name in files_array:
					var full_file_path = _resolve_validation_path(emulator_id, file_name)
					if not FileSystemManager.file_exists(full_file_path):
						return false
				return true
			
			if folder_path == "":
				return true
			
			var full_path = _resolve_validation_path(emulator_id, folder_path)
			
			# For SAF paths, we can't easily list files with patterns
			# So we just check if the directory exists
			if full_path.begins_with("content://"):
				return FileSystemManager.dir_exists(full_path)
			
			# For regular paths, use DirAccess to list and match files
			var dir = DirAccess.open(full_path)
			
			if not dir:
				return false
			
			dir.list_dir_begin()
			var file_name = dir.get_next()
			
			while file_name != "":
				if file_name != "." and file_name != "..":
					if pattern == "" or file_name.match(pattern):
						dir.list_dir_end()
						return true
				file_name = dir.get_next()
			
			dir.list_dir_end()
			return false
		
		"package_installed":
			# Check if an Android package is installed using PackageManager
			var package = validate_config.get("package", "")
			if package == "":
				return true
			
			if PlatformManager.is_android():
				return _is_android_package_installed(package)
			else:
				# On desktop, always return true (package concept doesn't apply)
				return true
		
		"always_pass":
			return true
		
		_:
			return false

## Helper function for download_url action
func _handle_download_url_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var url = platform_config.get("url", "")
	if url == "":
		push_error("[LaunchManager] No download URL for step '" + step_name + "'")
		return false
	
	var step_display_name = _get_step_display_name(step_name)
	_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config)
	return true

## Helper function for download_repo action
## Supports GitHub, Gitea, Forgejo, and other GitHub-compatible APIs via api_base_url
func _handle_download_repo_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var github_repo = platform_config.get("github_repo", "")
	var asset_pattern = platform_config.get("asset_pattern", "")
	var release_tag = platform_config.get("release_tag", "")
	var api_base_url = platform_config.get("api_base_url", "")  # For non-GitHub hosts (e.g., Gitea/Forgejo)
	
	if github_repo == "" or asset_pattern == "":
		push_error("[LaunchManager] Invalid download_repo config for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = "Fetching release info..."
	
	var step_display_name = _get_step_display_name(step_name)
	
	NetworkManager.fetch_repo_release(
		github_repo,
		asset_pattern,
		func(url: String, error: String):
			if error != "":
				push_error("[LaunchManager] Failed to fetch release: " + error)
				_emulator_install_progress[emulator_id] = "Failed to fetch release"
				return
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config),
		release_tag,
		api_base_url
	)
	return true

## Helper function for download_scrape action
func _handle_download_scrape_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var scrape_url = platform_config.get("scrape_url", "")
	var version_pattern = platform_config.get("version_pattern", "")
	var url_template = platform_config.get("url_template", "")
	
	if scrape_url == "" or version_pattern == "" or url_template == "":
		push_error("[LaunchManager] Invalid download_scrape config for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = "Scraping for latest version..."
	
	var step_display_name = _get_step_display_name(step_name)
	
	NetworkManager.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(url: String, error: String):
			if error != "":
				push_error("[LaunchManager] Failed to scrape release: " + error)
				_emulator_install_progress[emulator_id] = "Failed to scrape release"
				return
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config)
	)
	return true

## Helper function for create_folders action
func _handle_create_folders_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var folders = platform_config.get("folders", [])
	if folders.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	for folder_path in folders:
		# Resolve {emulator_dir} templates
		folder_path = _resolve_emulator_path(folder_path, emulator_id)
		
		var full_path: String
		if folder_path.begins_with("/") or folder_path.begins_with("content://"):
			# Absolute path or SAF URI - use as-is
			full_path = folder_path
		else:
			full_path = _get_emulator_directory(emulator_id) + folder_path
		
		# Use FileSystemManager for all directory creation (handles SAF on Android)
		if not FileSystemManager.make_dir_recursive(full_path):
			push_error("[LaunchManager] Failed to create folder: " + full_path)
			return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for create_files action
func _handle_create_files_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var files = platform_config.get("files", [])
	if files.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	# Get the emulator directory path for placeholder resolution
	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var global_emulator_dir = ProjectSettings.globalize_path(emulator_dir)
	
	for file_entry in files:
		var file_name = ""
		var file_content = ""
		
		if typeof(file_entry) == TYPE_STRING:
			file_name = file_entry
		elif typeof(file_entry) == TYPE_DICTIONARY:
			file_name = file_entry.get("name", "")
			file_content = file_entry.get("content", "")
		
		if file_name == "":
			continue
		
		var full_path: String
		if file_name.begins_with("/"):
			full_path = file_name
		else:
			full_path = emulator_dir + "/" + file_name
		
		# Resolve placeholders in content
		file_content = file_content.replace("{emulator_dir}", global_emulator_dir)
		
		# Resolve {games_dir} placeholder
		var games_folder_setting = SettingsManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value.rstrip("/") if games_folder_setting else "user://roms"
		file_content = file_content.replace("{games_dir}", games_dir)
		
		if not FileSystemManager.file_exists(full_path):
			if not FileSystemManager.write_file(full_path, file_content):
				push_error("[LaunchManager] Failed to create file: " + full_path)
				return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for creating PCSX2 folder memory card superblock
func _handle_create_pcsx2_superblock_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var path = platform_config.get("path", "")
	if path == "":
		push_error("[LaunchManager] No path specified for create_pcsx2_superblock step: " + step_name)
		return false

	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var memcard_path = emulator_dir + "/" + path
	
	var success = SaveManager.create_pcsx2_superblock(memcard_path)
	if not success:
		push_error("[LaunchManager] Failed to create PCSX2 superblock at: " + memcard_path)
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for edit_file action
func _handle_edit_file_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var file_path = platform_config.get("file", "")
	var edits = platform_config.get("edits", [])
	
	if file_path == "" or edits.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	var full_path: String
	if file_path.begins_with("/"):
		full_path = file_path
	else:
		full_path = _get_emulator_directory(emulator_id).rstrip("/") + "/" + file_path
	
	if not FileSystemManager.file_exists(full_path):
		push_error("[LaunchManager] File not found for editing: " + full_path)
		return false
	
	var content = FileSystemManager.read_file(full_path)
	if content == "":
		push_error("[LaunchManager] Failed to read file for editing: " + full_path)
		return false
	
	for edit in edits:
		var old_text = edit.get("old", "")
		var new_text = edit.get("new", "")
		
		if old_text == "":
			continue
		
		content = content.replace(old_text, new_text)
	
	if not FileSystemManager.write_file(full_path, content):
		push_error("[LaunchManager] Failed to write edited file: " + full_path)
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for none action (skip)
func _handle_none_step(emulator_id: String, step_name: String, step_index: int) -> bool:
	return _execute_install_step(emulator_id, step_index + 1)

## Executes install steps from new step-based format (entry point)
func _execute_install_steps(emulator_id: String, emulator: Dictionary, install_steps: Array) -> bool:
	# Find the first incomplete step to start from
	var progress = get_install_progress(emulator_id)
	var start_step = 0
	
	if progress["status"] == "partial" and progress["next_step_index"] >= 0:
		start_step = progress["next_step_index"]
	
	return _execute_install_step(emulator_id, start_step)

## Gets display name for a step based on step_name
func _get_step_display_name(step_name: String) -> String:
	# Map step names to user-friendly display names
	match step_name:
		"download_emulator":
			return "Downloading Emulator"
		"install_emulator":
			return "Installing Emulator"
		"download_cores":
			return "Downloading Cores"
		"install_cores":
			return "Installing Cores"
		"download_system_files":
			return "Downloading System Files"
		"install_system_files":
			return "Installing System Files"
		_:
			# Convert snake_case to Title Case with spaces
			var words = step_name.split("_")
			var result = ""
			for word in words:
				if result != "":
					result += " "
				result += word.capitalize()
			return result

## Checks if an Android package is installed using the PackageChecker plugin
func _is_android_package_installed(package_name: String) -> bool:
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		return false
	
	# Check the main package name first
	var result = plugin.isPackageInstalled(package_name)
	
	if result:
		return true
	
	# For RetroArch, check common variants
	if package_name == "com.retroarch":
		var variants = ["com.retroarch.aarch64", "com.retroarch.ra32"]
		
		for i in range(variants.size()):
			var variant = variants[i]
			result = plugin.isPackageInstalled(variant)
			
			if result:
				return true
	
	return false

## Validates a specific install step to check if it's complete
## Returns true if the step validation passes (step is complete)
func _validate_install_step(emulator_id: String, step_index: int, install_steps: Array) -> bool:
	if step_index >= install_steps.size():
		return true
	
	var step = install_steps[step_index]
	var platform_config = _get_step_platform_config(step)
	
	if platform_config.is_empty():
		return false
	
	var action_type = platform_config.get("action_type", "")
	var validate_config = platform_config.get("validate", {})
	
	# If no validation config, consider step complete (just move on)
	# This handles download steps where the file gets deleted after extraction
	if validate_config.is_empty():
		return true
	
	# Run validation
	return _validate_step(emulator_id, validate_config)

## Scans install steps and finds the first incomplete step
## Returns a dictionary with progress info
## Uses caching to avoid redundant file system operations
func get_install_progress(emulator_id: String) -> Dictionary:
	# Check cache first
	if _validation_cache.has(emulator_id):
		var cached = _validation_cache[emulator_id]
		var elapsed = Time.get_ticks_msec() - cached.timestamp
		if elapsed < _cache_ttl_ms:
			return cached.result
	
	# Perform validation
	var result = _compute_install_progress(emulator_id)
	
	# Cache the result
	_validation_cache[emulator_id] = {
		"result": result,
		"timestamp": Time.get_ticks_msec()
	}
	
	return result

## Internal function to compute install progress without caching
func _compute_install_progress(emulator_id: String) -> Dictionary:
	var result = {
		"total_steps": 0,
		"completed_steps": 0,
		"next_step_index": -1,
		"next_step_name": "",
		"next_step_display": "",
		"status": "not_started",  # "not_started", "partial", "complete"
		"is_installed": false
	}
	
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return result
	
	var install_steps = emulator.get("install", [])
	result["total_steps"] = install_steps.size()
	
	# Scan each step
	for i in range(install_steps.size()):
		var step = install_steps[i]
		var step_name = step.get("step", "")
		
		if _validate_install_step(emulator_id, i, install_steps):
			result["completed_steps"] += 1
		else:
			# First incomplete step found
			if result["next_step_index"] == -1:
				result["next_step_index"] = i
				result["next_step_name"] = step_name
				result["next_step_display"] = _get_step_display_name(step_name)
	
	# Determine status
	if result["completed_steps"] == 0:
		result["status"] = "not_started"
	elif result["completed_steps"] == result["total_steps"]:
		result["status"] = "complete"
		result["is_installed"] = true
	else:
		result["status"] = "partial"
	
	return result

## Scans emulator installation and updates state based on step completion
## Call this when opening platform page to refresh state
func scan_emulator_install_state(emulator_id: String):
	var progress = get_install_progress(emulator_id)
	
	if progress["status"] == "complete":
		_emulator_install_progress[emulator_id] = ""
	elif progress["status"] == "partial":
		# Mark as partial - UI will show "Resume: [Step Name]"
		_emulator_install_progress[emulator_id] = "Resume: " + progress["next_step_display"]
	else:
		_emulator_install_progress[emulator_id] = ""

## Legacy unified download - kept for reference but not used
func _queue_emulator_download(emulator_id: String, emulator_name: String, step_display_name: String, download_url: String, step_index: int, step_config: Dictionary = {}):
	# Use explicit filename from config if provided, otherwise extract from URL
	var filename = step_config.get("filename", "")
	if filename == "":
		filename = download_url.get_file()
	
	# Check for custom destination path (for firmware/shared files)
	var custom_destination = step_config.get("destination", "")
	var destination_path: String
	if custom_destination != "":
		# Ensure the custom destination directory exists
		var base_dir = custom_destination.get_base_dir()
		var dir_name = custom_destination.get_file()
		var dir = DirAccess.open(base_dir)
		if dir and not dir.dir_exists(dir_name):
			dir.make_dir_recursive(dir_name)
		destination_path = custom_destination + "/" + filename
	else:
		destination_path = _get_emulator_directory(emulator_id).rstrip("/") + "/" + filename
	
	# Check if this is an APK download
	var is_apk = filename.to_lower().ends_with(".apk")
	
	# For APKs, always use local storage even if SAF is configured
	# This allows simple OS.shell_open() with file:// URI for installation
	if is_apk and destination_path.begins_with("content://"):
		print("[LaunchManager] APK detected - using local storage instead of SAF")
		destination_path = "user://temp_apk/" + filename
		# Ensure directory exists
		DirAccess.make_dir_recursive_absolute("user://temp_apk")
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Queue download WITHOUT auto-extract (extract is now a separate step)
	var item_id = DownloadManager.queue_download(
		download_url,
		destination_path,
		"emulator",
		step_display_name,  # Use step-specific display name for notifications
		false,  # auto_extract = false
		""  # extract_to = empty, we'll handle extraction separately
	)
	
	if item_id == "":
		return
	
	# Track download with step info for sequential execution
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "emulator",
		"step_index": step_index,
		"step_config": step_config,
		"filename": filename,
		"is_apk": is_apk,
		"use_saf": destination_path.begins_with("content://"),
		"callback": func(success: bool, message: String):
			if not success:
				_emulator_install_progress[emulator_id] = message if message != "" else "Download failed"
				emulator_extraction_completed.emit(emulator_id, false)
	}

## Checks if an emulator is currently downloading or extracting
## Uses DownloadManager to check active downloads for this emulator
func is_emulator_downloading(emulator_id: String) -> bool:
	# Check if any active item in DownloadManager is for this emulator
	for item in DownloadManager.get_active():
		if item.name == emulator_id or item.name.begins_with(emulator_id):
			return item.status == "downloading" or item.status == "extracting"
	return false

## Checks if an emulator is queued for download
func is_emulator_queued(emulator_id: String) -> bool:
	# Check if any queued item in DownloadManager is for this emulator
	for item in DownloadManager.get_queued():
		if item.name == emulator_id or item.name.begins_with(emulator_id):
			return true
	return false

## Handles download completion
func _on_unified_download_completed(item_id: String, success: bool, message: String):
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		var emulator_id = task_info.emulator_id
		var step_index = task_info.get("step_index", 0)
		var step_config = task_info.get("step_config", {})
		_pending_emulator_downloads.erase(item_id)
		
		if not success:
			_emulator_install_progress[emulator_id] = "Download failed: " + message
			emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, message)
			return
		
		# Validate download if validation config exists
		var validate_config = step_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[LaunchManager] Download validation failed for: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Download validation failed"
			emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Validation failed")
			return
		
		# Progress to next step
		var step_success = _execute_install_step(emulator_id, step_index + 1)
		if not step_success:
			push_error("[LaunchManager] Install step " + str(step_index + 1) + " failed for: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Install step failed"
			emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Install step failed")
		return

## Handles extraction completion
# ==================== VITA3K HELPERS ====================

## Extracts TitleID from Vita game ZIP by reading root folder name

## Helper to store title_id for the active game or sibling
func _store_title_id(game: GameResource, title_id: String) -> void:
	var active_id = game.get_active_game_id()
	if active_id == game.romm_id:
		# Main game
		if game.title_id != title_id:
			game.title_id = title_id
			DataManager.update_game_title_id(game.romm_id, title_id)
	else:
		# Sibling - update in the siblings array
		var current_title_id = game.get_active_title_id()
		if current_title_id != title_id:
			game.set_sibling_title_id(active_id, title_id)
			# Persist the updated siblings array to DB
			DataManager.update_game_siblings(game.romm_id, game.siblings)

## Prepares a game for launch by extracting title IDs and game files
## This must be called BEFORE save sync so that the title_id is available
## Returns true if preparation succeeded (or no prep needed), false on error
func _prepare_game_for_launch(game: GameResource, emulator_id: String) -> bool:
	print("[LaunchManager] _prepare_game_for_launch: START for " + game.get_display_name() + " (emulator: " + emulator_id + ")")
	
	# Build a temporary intent for ROM path
	var temp_intent = LaunchIntent.new()
	if game.file_path != "":
		temp_intent.rom_path = game.file_path
		print("[LaunchManager] _prepare_game_for_launch: Using game.file_path = " + game.file_path)
	else:
		var root_folder = SettingsManager.get_setting("games_root_folder")
		var root_path = root_folder.value if root_folder else "user://roms/"
		temp_intent.rom_path = root_path + "/" + game.platform_slug + "/" + game.get_active_file_name()
		print("[LaunchManager] _prepare_game_for_launch: Constructed path = " + temp_intent.rom_path)
	
	temp_intent.emulator_id = emulator_id
	
	var result = true
	
	match emulator_id:
		"azahar":
			print("[LaunchManager] _prepare_game_for_launch: Preparing Azahar game...")
			result = _prepare_azahar_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: Azahar prep result = " + str(result))
		"cemu":
			print("[LaunchManager] _prepare_game_for_launch: Preparing Cemu game...")
			result = _prepare_cemu_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: Cemu prep result = " + str(result))
		"eden":
			print("[LaunchManager] _prepare_game_for_launch: Preparing Eden game...")
			result = _prepare_eden_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: Eden prep result = " + str(result))
		"dolphin":
			print("[LaunchManager] _prepare_game_for_launch: Preparing Dolphin game...")
			result = _prepare_dolphin_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: Dolphin prep result = " + str(result))
		"pcsx2":
			print("[LaunchManager] _prepare_game_for_launch: Preparing PCSX2 game...")
			result = _prepare_pcsx2_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: PCSX2 prep result = " + str(result))
		"ppsspp":
			print("[LaunchManager] _prepare_game_for_launch: Preparing PPSSPP game...")
			result = _prepare_ppsspp_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: PPSSPP prep result = " + str(result))
		"vita3k", "vita3k-canary":
			print("[LaunchManager] _prepare_game_for_launch: Preparing Vita3K game...")
			result = await _prepare_vita3k_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: Vita3K prep result = " + str(result))
		"rpcs3", "rpcsx":
			print("[LaunchManager] _prepare_game_for_launch: Preparing RPCS3 game...")
			result = await _prepare_rpcs3_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: RPCS3 prep result = " + str(result))
		"shadps4":
			print("[LaunchManager] _prepare_game_for_launch: Preparing shadPS4 game...")
			result = await _prepare_shadps4_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: shadPS4 prep result = " + str(result))
		"xenia":
			print("[LaunchManager] _prepare_game_for_launch: Preparing Xenia game...")
			result = _prepare_xenia_game(game, temp_intent)
			print("[LaunchManager] _prepare_game_for_launch: Xenia prep result = " + str(result))
		_:
			print("[LaunchManager] _prepare_game_for_launch: No prep needed for emulator: " + emulator_id)
	
	print("[LaunchManager] _prepare_game_for_launch: END result = " + str(result))
	return result

func _prepare_azahar_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] Azahar: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = TitleIDParser.extract_3ds_title_id(rom_path)
	if title_id == "":
		push_error("[LaunchManager] Azahar: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract 3DS game TitleID", Notification.Type.ERROR)
		return false
	
	print("[LaunchManager] Azahar: TitleID from ROM: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[LaunchManager] Azahar: WARNING - Stored TitleID " + active_title_id + " doesn't match ROM TitleID " + title_id)
		print("[LaunchManager] Azahar: Updating to correct TitleID from ROM")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id)
		print("[LaunchManager] Azahar: Updated database with TitleID: " + title_id)
	
	return true

func _prepare_cemu_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] Cemu: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = TitleIDParser.extract_wiiu_title_id(rom_path)
	if title_id == "":
		push_error("[LaunchManager] Cemu: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract Wii U game TitleID", Notification.Type.ERROR)
		return false
	
	print("[LaunchManager] Cemu: TitleID from WUA: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[LaunchManager] Cemu: WARNING - Stored TitleID " + active_title_id + " doesn't match WUA TitleID " + title_id)
		print("[LaunchManager] Cemu: Updating to correct TitleID from WUA")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id)
		print("[LaunchManager] Cemu: Updated database with TitleID: " + title_id)
	
	return true

func _resolve_eden_title_id_from_db(game_name: String, emulator_id: String) -> String:
	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var search_roots: Array[String] = [emulator_dir + "/user"]
	if PlatformManager.is_windows():
		var appdata = OS.get_environment("APPDATA")
		if appdata != "":
			search_roots.append(appdata + "/eden")
			search_roots.append(appdata + "/yuzu")
	elif PlatformManager.is_linux():
		var home = OS.get_environment("HOME")
		if home != "":
			search_roots.append(home + "/.local/share/eden")
			search_roots.append(home + "/.local/share/yuzu")
	
	for root in search_roots:
		var db_path = root + "/cache/game_list/game_list.db"
		print("[LaunchManager] Eden DB lookup: checking " + db_path)
		if not FileAccess.file_exists(db_path):
			print("[LaunchManager] Eden DB lookup: file does not exist")
			continue
		print("[LaunchManager] Eden DB lookup: file exists, opening...")
		var db = SQLite.new()
		db.path = db_path
		db.verbosity_level = SQLite.VERBOSE
		if not db.open_db():
			print("[LaunchManager] Eden DB lookup: failed to open DB")
			continue
		print("[LaunchManager] Eden DB lookup: DB opened")
		
		var tables = db.query("SELECT name FROM sqlite_master WHERE type='table';")
		if tables == null or not tables is Array:
			print("[LaunchManager] Eden DB lookup: no tables found")
			db.close_db()
			continue
		print("[LaunchManager] Eden DB lookup: tables count = " + str(tables.size()))
		
		for table_dict in tables:
			var table_name = table_dict.get("name", "")
			if table_name == "" or table_name.begins_with("sqlite_"):
				continue
			
			var cols_result = db.query("PRAGMA table_info(" + table_name + ");")
			if cols_result == null or not cols_result is Array:
				continue
			
			var id_col = ""
			var name_col = ""
			for col in cols_result:
				var col_name = str(col.get("name", "")).to_lower()
				if id_col == "" and col_name in ["title_id", "program_id", "id"]:
					id_col = str(col.get("name", ""))
				if name_col == "" and ("name" in col_name or "title" in col_name):
					name_col = str(col.get("name", ""))
			
			if id_col == "" or name_col == "":
				continue
			
			print("[LaunchManager] Eden DB lookup: scanning table '" + table_name + "' (id_col=" + id_col + ", name_col=" + name_col + ")")
			var query = "SELECT " + id_col + " FROM " + table_name + " WHERE " + name_col + " LIKE ? LIMIT 1;"
			var rows = db.query_with_bindings(query, ["%" + game_name + "%"])
			if rows != null and rows is Array and rows.size() > 0:
				var raw = rows[0].get(id_col, "")
				var tid = ""
				if raw is int:
					tid = "%016x" % raw
				elif raw is String:
					tid = raw.to_upper().replace("0X", "")
				print("[LaunchManager] Eden DB lookup: raw result = " + str(raw) + ", parsed tid = " + tid)
				if tid.length() == 16:
					var valid = true
					for c in tid:
						if not ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F')):
							valid = false
							break
					if valid and tid.begins_with("01"):
						db.close_db()
						print("[LaunchManager] Eden: TitleID from DB (" + root + "): " + tid)
						return tid
					else:
						print("[LaunchManager] Eden DB lookup: parsed tid invalid or doesn't start with 01")
			else:
				print("[LaunchManager] Eden DB lookup: no match in table '" + table_name + "' for '" + game_name + "'")
		
		db.close_db()
	
	print("[LaunchManager] Eden DB lookup: exhausted all roots, no title id found")
	return ""

func _prepare_eden_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] Eden: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = ""
	
	# Use existing title_id from database/RomM if it's already valid
	if game.title_id.length() == 16:
		var valid = true
		for c in game.title_id:
			if not ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f')):
				valid = false
				break
		if valid and game.title_id.to_upper().begins_with("01"):
			title_id = game.title_id.to_upper()
			print("[LaunchManager] Eden: Using stored TitleID from database: " + title_id)
	
	if title_id == "":
		title_id = TitleIDParser.extract_switch_title_id(rom_path, _get_emulator_directory("eden"))
	if title_id == "":
		print("[LaunchManager] Eden: ROM extraction failed, trying game_list.db lookup...")
		title_id = _resolve_eden_title_id_from_db(game.get_display_name(), intent.emulator_id)
	
	if title_id == "":
		push_error("[LaunchManager] Eden: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract Switch game TitleID", Notification.Type.ERROR)
		return false
	
	print("[LaunchManager] Eden: TitleID resolved: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[LaunchManager] Eden: WARNING - Stored TitleID " + active_title_id + " doesn't match resolved TitleID " + title_id)
		print("[LaunchManager] Eden: Updating to correct TitleID")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id)
		print("[LaunchManager] Eden: Updated database with TitleID: " + title_id)
	
	return true

func _prepare_dolphin_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] Dolphin: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var game_id = TitleIDParser.extract_gamecube_game_id(rom_path)
	
	if game_id == "":
		print("[LaunchManager] Dolphin: Could not extract Game ID from ROM, trying existing saves...")
		var emulator_dir = LaunchManager._get_emulator_directory("dolphin")
		game_id = TitleIDParser.extract_gamecube_game_id_from_existing_saves(emulator_dir)
	
	if game_id == "":
		push_error("[LaunchManager] Dolphin: Failed to extract Game ID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract GameCube/Wii game ID", Notification.Type.ERROR)
		return false
	
	print("[LaunchManager] Dolphin: Game ID: " + game_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != game_id:
		print("[LaunchManager] Dolphin: WARNING - Stored Game ID " + active_title_id + " doesn't match detected Game ID " + game_id)
		print("[LaunchManager] Dolphin: Updating to correct Game ID")
	
	if active_title_id != game_id:
		_store_title_id(game, game_id)
		print("[LaunchManager] Dolphin: Updated database with Game ID: " + game_id)
	
	return true

func _prepare_xenia_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] Xenia: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = TitleIDParser.extract_xbox360_title_id(rom_path)
	if title_id == "":
		push_error("[LaunchManager] Xenia: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract Xbox 360 game TitleID", Notification.Type.ERROR)
		return false
	
	print("[LaunchManager] Xenia: TitleID from ISO: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[LaunchManager] Xenia: WARNING - Stored TitleID " + active_title_id + " doesn't match ISO TitleID " + title_id)
		print("[LaunchManager] Xenia: Updating to correct TitleID from ISO")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id)
		print("[LaunchManager] Xenia: Updated database with TitleID: " + title_id)
	
	return true

func _prepare_pcsx2_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] PCSX2: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var serial = ""
	
	# Try extracting serial from ROM
	if FileAccess.file_exists(rom_path):
		serial = TitleIDParser.extract_ps2_serial(rom_path)
		if serial != "":
			print("[LaunchManager] PCSX2: Serial from ROM: " + serial)
	
	if serial == "":
		push_error("[LaunchManager] PCSX2: Failed to extract serial from: " + rom_path)
		NotificationManager.show_notification("Failed to extract PS2 game serial", Notification.Type.ERROR)
		return false
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != serial:
		print("[LaunchManager] PCSX2: WARNING - Stored serial " + active_title_id + " doesn't match detected serial " + serial)
		print("[LaunchManager] PCSX2: Updating to correct serial")
	
	if active_title_id != serial:
		_store_title_id(game, serial)
		print("[LaunchManager] PCSX2: Updated database with serial: " + serial)
	
	return true

## Handles PPSSPP game extraction and launch preparation
## Returns true if ready to launch, false if error
func _prepare_ppsspp_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] PPSSPP: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var game_id = ""
	
	# Try extracting game ID from ROM
	if FileAccess.file_exists(rom_path):
		game_id = TitleIDParser.extract_psp_game_id(rom_path)
		if game_id != "":
			print("[LaunchManager] PPSSPP: Game ID from ROM: " + game_id)
	
	if game_id == "":
		push_error("[LaunchManager] PPSSPP: Failed to extract game ID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract PSP game ID", Notification.Type.ERROR)
		return false
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != game_id:
		print("[LaunchManager] PPSSPP: WARNING - Stored ID " + active_title_id + " doesn't match detected ID " + game_id)
		print("[LaunchManager] PPSSPP: Updating to correct ID")
	
	if active_title_id != game_id:
		_store_title_id(game, game_id)
		print("[LaunchManager] PPSSPP: Updated database with game ID: " + game_id)
	
	return true

## Handles Vita3K game extraction and launch preparation
## Returns true if ready to launch, false if error
func _prepare_vita3k_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] _prepare_vita3k_game: ENTER for " + game.get_display_name())
	
	var rom_path = intent.rom_path
	print("[LaunchManager] Vita3K: Preparing game from ROM path: " + rom_path)
	
	# Get emulator directory for checking existing games
	# Platform-specific: Android uses fixed external storage path, desktop uses install path
	var emulator_dir: String
	var ux0_app_path: String
	
	if PlatformManager.is_android():
		# Android: Vita3K stores games in its external storage path (configurable in settings)
		# Path may be SAF URI (content://) or real path - FileSystemManager handles both
		emulator_dir = _get_vita3k_android_data_path()
		ux0_app_path = emulator_dir + "/ux0/app"
	else:
		# Desktop: Get path from emulator installation
		var emulator_path = ""
		if intent.emulator_id != "":
			emulator_path = get_emulator_install_path(intent.emulator_id)
		else:
			# Fallback: try to find any vita3k emulator
			emulator_path = get_emulator_install_path("vita3k")
		
		if emulator_path != "":
			emulator_dir = emulator_path.get_base_dir()
		else:
			# Emulator not installed yet, use the default emulator directory
			# We can still extract the TitleID and prepare the game files
			emulator_dir = _get_emulator_directory("vita3k").rstrip("/")
			print("[LaunchManager] Vita3K: Emulator not installed yet, using default directory: " + emulator_dir)
		
		ux0_app_path = emulator_dir + "/ux0/app"
	
	print("[LaunchManager] Vita3K: ux0_app_path = " + ux0_app_path)
	
	# Always extract TitleID from ZIP to ensure we have the correct one for this ROM
	print("[LaunchManager] Vita3K: Extracting TitleID from ZIP...")
	var zip_title_id = TitleIDParser.extract_vita_title_id(rom_path)
	if zip_title_id == "":
		push_error("[LaunchManager] Vita3K: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract Vita game TitleID", Notification.Type.ERROR)
		return false
	print("[LaunchManager] Vita3K: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[LaunchManager] Vita3K: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[LaunchManager] Vita3K: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[LaunchManager] Vita3K: Updated database with TitleID: " + zip_title_id)
	
	var title_id = game.get_active_title_id()
	print("[LaunchManager] Vita3K: Using TitleID: " + title_id)
	
	# Platform-specific Vita3K app path
	var vita_app_path: String
	if PlatformManager.is_android():
		# Path may be SAF URI or real path - FileSystemManager handles both
		vita_app_path = _get_vita3k_android_data_path() + "/ux0/app/" + title_id
	else:
		# Desktop - use emulator directory (already obtained above)
		vita_app_path = emulator_dir + "/ux0/app/" + title_id
	
	print("[LaunchManager] Vita3K: Checking extracted files at: " + vita_app_path)
	
	# Check if already extracted by looking for actual game files, not just directory existence
	var is_extracted = _vita_app_has_game_files(vita_app_path)
	print("[LaunchManager] Vita3K: has_game_files = " + str(is_extracted))
	if is_extracted:
		return true
	
	# Extract ZIP to Vita3K ux0/app directory (ZIP contains the TitleID folder)
	# We extract to the parent directory (ux0/app) so the ZIP's root folder lands correctly
	var extract_parent = vita_app_path.get_base_dir()
	
	# Show persistent pulsing notification during extraction
	var notify_id = NotificationManager.show_notification(
		"Extracting " + game.get_display_name() + "...",
		Notification.Type.INFO,
		null,
		0.0,  # Never auto-dismiss
		Callable(),
		Callable(),
		true  # Pulsing
	)
	print("[LaunchManager] Vita3K: Extracting ZIP to: " + extract_parent)
	
	var extract_success = await _extract_vita_zip(rom_path, extract_parent, title_id)
	
	# Dismiss the extraction notification
	NotificationManager.dismiss_notification(notify_id)
	
	if not extract_success:
		push_error("[LaunchManager] Vita3K: Failed to extract game to " + vita_app_path)
		return false
	
	print("[LaunchManager] Vita3K: Extraction successful")
	print("[LaunchManager] _prepare_vita3k_game: EXIT with true")
	return true

## Checks whether the given Vita3K app path contains actual game files
func _vita_app_has_game_files(vita_app_path: String) -> bool:
	# Use FileSystemManager which handles both regular paths and SAF URIs
	var files = FileSystemManager.list_dir(vita_app_path)
	# Filter out . and .. entries - they don't count as game files
	var actual_files = 0
	for f in files:
		if f != "." and f != "..":
			actual_files += 1
	print("[LaunchManager] Vita3K: _vita_app_has_game_files: found " + str(actual_files) + " actual files in " + vita_app_path)
	return actual_files > 0

## Extracts Vita game ZIP with progress tracking
func _extract_vita_zip(zip_path: String, extract_to: String, title_id: String) -> bool:
	print("[LaunchManager] _extract_vita_zip: ENTER zip_path=" + zip_path + ", extract_to=" + extract_to)
	
	# Create parent directories if needed using FileSystemManager (handles both regular paths and SAF URIs)
	var parent_dir = extract_to.get_base_dir()
	print("[LaunchManager] Vita3K: Creating parent directory: " + parent_dir)
	if not FileSystemManager.make_dir_recursive(parent_dir):
		push_error("[LaunchManager] Failed to create Vita3K app directory: " + parent_dir)
		print("[LaunchManager] _extract_vita_zip: EXIT false (mkdir failed)")
		return false
	
	# Use DownloadManager's extraction for progress tracking.
	# DownloadManager handles both regular paths and SAF URIs on a background thread.
	print("[LaunchManager] Vita3K: Queueing extraction via DownloadManager")
	var item_id = DownloadManager.queue_extraction(zip_path, extract_to, "vita_game", title_id, false)
	if item_id == "":
		push_error("[LaunchManager] Failed to queue Vita game extraction")
		print("[LaunchManager] _extract_vita_zip: EXIT false (queue failed)")
		return false
	print("[LaunchManager] Vita3K: Extraction queued with item_id=" + item_id)
	
	# Use Dictionary for thread-safe state tracking (reference type)
	var future = {"complete": false, "success": false, "message": ""}
	
	var on_complete = func(completed_item_id: String, success: bool, message: String):
		if completed_item_id == item_id:
			future.complete = true
			future.success = success
			future.message = message
			print("[LaunchManager] Vita3K: Extraction callback received - success=" + str(success) + ", message=" + message)
	
	DownloadManager.extraction_completed.connect(on_complete)
	
	# Wait for completion (with timeout)
	var timeout = 300.0  # 5 minutes timeout
	var elapsed = 0.0
	print("[LaunchManager] _extract_vita_zip: Starting poll loop")
	while not future.complete and elapsed < timeout:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	
	DownloadManager.extraction_completed.disconnect(on_complete)
	
	if not future.complete:
		push_error("[LaunchManager] Vita game extraction timed out")
		print("[LaunchManager] _extract_vita_zip: EXIT false (timeout)")
		return false
	
	print("[LaunchManager] _extract_vita_zip: EXIT " + str(future.success))
	return future.success


## Recursively searches for PARAM.SFO file in a directory
## Returns the full path to PARAM.SFO if found, empty string otherwise
func _find_param_sfo_recursive(search_dir: String) -> String:
	var dir := DirAccess.open(search_dir)
	if not dir:
		return ""
	
	dir.list_dir_begin()
	var file_name := dir.get_next()
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path := search_dir + "/" + file_name
			
			# Check if this is the PARAM.SFO file we're looking for
			if file_name == "PARAM.SFO" and FileSystemManager.file_exists(full_path):
				dir.list_dir_end()
				return full_path
			
			# If it's a directory, search recursively
			if FileSystemManager.dir_exists(full_path):
				var result := _find_param_sfo_recursive(full_path)
				if result != "":
					dir.list_dir_end()
					return result
					
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return ""


## Recursively copies a directory and all its contents
## Returns true on success, false on failure
func _copy_dir_recursive(source_dir: String, dest_dir: String) -> bool:
	print("[LaunchManager] RPCS3: Copying directory recursively from " + source_dir + " to " + dest_dir)
	
	# Create destination directory
	if not FileSystemManager.make_dir_recursive(dest_dir):
		push_error("[LaunchManager] RPCS3: Failed to create destination directory: " + dest_dir)
		return false
	
	var dir := DirAccess.open(source_dir)
	if not dir:
		push_error("[LaunchManager] RPCS3: Cannot open source directory: " + source_dir)
		return false
	
	dir.list_dir_begin()
	var file_name := dir.get_next()
	var success := true
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			var source_path := source_dir + "/" + file_name
			var dest_path := dest_dir + "/" + file_name
			
			if FileSystemManager.dir_exists(source_path):
				# Recursively copy subdirectory
				if not _copy_dir_recursive(source_path, dest_path):
					success = false
					break
			else:
				# Copy file
				if not FileSystemManager.copy_file(source_path, dest_path):
					push_error("[LaunchManager] RPCS3: Failed to copy file: " + source_path + " to " + dest_path)
					success = false
					break
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return success


## Checks whether the given RPCS3 game path contains actual game files
func _rpcs3_game_has_files(game_path: String) -> bool:
	if not FileSystemManager.dir_exists(game_path):
		return false
	var files = FileSystemManager.list_dir(game_path)
	var actual_files = 0
	for f in files:
		if f != "." and f != "..":
			actual_files += 1
	print("[LaunchManager] RPCS3: _rpcs3_game_has_files: found " + str(actual_files) + " actual files in " + game_path)
	return actual_files > 0


## Recursively flattens wrapper folders in a PS3 game installation
## Handles multiple nesting levels (e.g., "Game Name/TitleID/..." -> "TitleID/...")
## Stops when it finds a game indicator (PARAM.SFO, PS3_DISC.SFB, or PS3_GAME/ folder)
func _flatten_rpcs3_wrappers(install_path: String) -> void:
	var max_iterations = 5  # Safety limit to prevent infinite loops
	
	for i in range(max_iterations):
		var dir := DirAccess.open(install_path)
		if not dir:
			break
		
		dir.list_dir_begin()
		var entries := []
		var file_name := dir.get_next()
		while file_name != "":
			if file_name != "." and file_name != "..":
				entries.append(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
		
		print("[LaunchManager] RPCS3: Flatten iteration " + str(i + 1) + " - found " + str(entries.size()) + " entries")
		
		# Stop if there are multiple entries or no entries
		if entries.size() != 1:
			print("[LaunchManager] RPCS3: Stopping flatten - not a single wrapper (" + str(entries.size()) + " entries)")
			break
		
		var potential_wrapper: String = install_path + "/" + entries[0]
		
		# Only flatten if it's a directory
		if not FileSystemManager.dir_exists(potential_wrapper):
			print("[LaunchManager] RPCS3: Stopping flatten - single entry is not a directory")
			break
		
		# Check if this directory contains game indicators
		var has_param_sfo = FileSystemManager.file_exists(potential_wrapper + "/PARAM.SFO")
		var has_disc_sfb = FileSystemManager.file_exists(potential_wrapper + "/PS3_DISC.SFB")
		var has_ps3_game = FileSystemManager.dir_exists(potential_wrapper + "/PS3_GAME")
		
		if has_param_sfo or has_disc_sfb or has_ps3_game:
			print("[LaunchManager] RPCS3: Found game indicators in: " + entries[0])
			
			# Flatten this level (move game folder contents up)
			print("[LaunchManager] RPCS3: Flattening game folder: " + entries[0])
			var wrapper_dir := DirAccess.open(potential_wrapper)
			if wrapper_dir:
				wrapper_dir.list_dir_begin()
				var wrapper_file := wrapper_dir.get_next()
				while wrapper_file != "":
					if wrapper_file != "." and wrapper_file != "..":
						var source := potential_wrapper + "/" + wrapper_file
						var dest := install_path + "/" + wrapper_file
						print("[LaunchManager] RPCS3: Moving " + wrapper_file + " up from game folder")
						FileSystemManager.move(source, dest)
					wrapper_file = wrapper_dir.get_next()
				wrapper_dir.list_dir_end()
				FileSystemManager.delete_dir_recursive(potential_wrapper)
				print("[LaunchManager] RPCS3: Flattened game folder")
			
			# Stop after flattening the game folder
			break
		else:
			# This is just a wrapper, flatten it
			print("[LaunchManager] RPCS3: Found wrapper folder: " + entries[0])
			var wrapper_dir := DirAccess.open(potential_wrapper)
			if wrapper_dir:
				wrapper_dir.list_dir_begin()
				var wrapper_file := wrapper_dir.get_next()
				while wrapper_file != "":
					if wrapper_file != "." and wrapper_file != "..":
						var source := potential_wrapper + "/" + wrapper_file
						var dest := install_path + "/" + wrapper_file
						print("[LaunchManager] RPCS3: Moving " + wrapper_file + " up from wrapper")
						FileSystemManager.move(source, dest)
					wrapper_file = wrapper_dir.get_next()
				wrapper_dir.list_dir_end()
				FileSystemManager.delete_dir_recursive(potential_wrapper)
				print("[LaunchManager] RPCS3: Flattened wrapper folder")


## Determines if a PS3 game ZIP is disc or digital format by checking file paths
## Returns "disc" if ZIP contains PS3_GAME/ folder, "digital" otherwise
func _determine_ps3_game_format(zip_path: String) -> String:
	if not FileSystemManager.file_exists(zip_path):
		push_error("[LaunchManager] RPCS3: Cannot determine format - file not found: " + zip_path)
		return "digital"  # Default to digital on error
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	
	if err != OK:
		# ZIPReader failed (likely ZIP64/large file), try 7-Zip fallback
		print("[LaunchManager] RPCS3: ZIPReader failed for format detection, trying 7-Zip fallback")
		return _determine_ps3_game_format_with_7z(zip_path)
	
	var files = reader.get_files()
	reader.close()
	
	if files.is_empty():
		return "digital"
	
	# Check if any file path contains PS3_GAME/
	for file_path in files:
		if file_path.find("PS3_GAME/") != -1:
			print("[LaunchManager] RPCS3: Detected disc format (found PS3_GAME/ in ZIP)")
			return "disc"
	
	print("[LaunchManager] RPCS3: Detected digital format (no PS3_GAME/ in ZIP)")
	return "digital"


## 7-Zip fallback for format detection on large/ZIP64 archives
func _determine_ps3_game_format_with_7z(zip_path: String) -> String:
	var binary_path = _get_7z_binary_path()
	if binary_path == "":
		print("[LaunchManager] RPCS3: 7-Zip binary not available for format detection")
		return "digital"
	
	var list_args = ["l", zip_path]
	var output = []
	var exit_code = OS.execute(binary_path, list_args, output, true)
	
	if exit_code != 0:
		push_error("[LaunchManager] RPCS3: 7-Zip list failed for format detection")
		return "digital"
	
	var output_str = output[0] if output.size() > 0 else ""
	
	# Check if any line contains PS3_GAME/
	if output_str.find("PS3_GAME/") != -1 or output_str.find("PS3_GAME\\") != -1:
		print("[LaunchManager] RPCS3: Detected disc format via 7-Zip (found PS3_GAME/)")
		return "disc"
	
	print("[LaunchManager] RPCS3: Detected digital format via 7-Zip (no PS3_GAME/)")
	return "digital"


## Prepares a PS3 game for RPCS3 by extracting ZIP directly to final location
## Follows the Vita3K pattern: extract TitleID first, check if installed, skip if present
## Extracts directly to games/ or dev_hdd0/game/ based on format detection - no temp directory
func _prepare_rpcs3_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] RPCS3: _prepare_rpcs3_game called for: " + game.get_display_name())
	
	if not game or not intent:
		print("[LaunchManager] RPCS3: ERROR - game or intent is null")
		return false
	
	var rom_path := game.file_path
	print("[LaunchManager] RPCS3: ROM path: " + rom_path)
	
	if rom_path == "":
		push_error("[LaunchManager] RPCS3: No ROM path for game: " + game.get_display_name())
		return false
	
	# Step 1: Extract TitleID from ZIP upfront (like Vita3K)
	print("[LaunchManager] RPCS3: Extracting TitleID from ZIP...")
	var zip_title_id = TitleIDParser.extract_ps3_title_id(rom_path)
	if zip_title_id == "":
		push_error("[LaunchManager] RPCS3: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract PS3 game TitleID", Notification.Type.ERROR)
		return false
	print("[LaunchManager] RPCS3: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[LaunchManager] RPCS3: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[LaunchManager] RPCS3: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[LaunchManager] RPCS3: Updated database with TitleID: " + zip_title_id)
	
	var title_id = game.get_active_title_id()
	print("[LaunchManager] RPCS3: Using TitleID: " + title_id)
	
	# Step 2: Determine emulator directory
	var emulator_dir: String
	
	if PlatformManager.is_android():
		# Android: RPCSX uses app-private storage
		emulator_dir = "/storage/emulated/0/Android/data/net.rpcsx.ui/files"
		print("[LaunchManager] RPCS3: Android mode - emulator_dir: " + emulator_dir)
	else:
		# Desktop: Use emulator install directory
		var install_path = get_emulator_install_path(intent.emulator_id)
		print("[LaunchManager] RPCS3: Desktop mode - install_path: " + install_path)
		emulator_dir = install_path.get_base_dir()
		print("[LaunchManager] RPCS3: Desktop mode - emulator_dir: " + emulator_dir)
	
	# Step 3: Detect game format from ZIP before extraction
	var game_format = _determine_ps3_game_format(rom_path)
	print("[LaunchManager] RPCS3: Game format: " + game_format)
	
	# Step 4: Determine final install location based on format
	var install_path: String
	if game_format == "disc":
		install_path = emulator_dir + "/games/" + title_id
	else:
		install_path = emulator_dir + "/dev_hdd0/game/" + title_id
	
	print("[LaunchManager] RPCS3: Install path: " + install_path)
	
	# Step 5: Check if already installed
	if _rpcs3_game_has_files(install_path):
		print("[LaunchManager] RPCS3: Game already installed at: " + install_path)
		return true
	
	print("[LaunchManager] RPCS3: Game not installed, will extract to: " + install_path)
	
	# Step 6: Create install directory
	if not FileSystemManager.dir_exists(install_path):
		print("[LaunchManager] RPCS3: Creating install directory: " + install_path)
		if not FileSystemManager.make_dir_recursive(install_path):
			push_error("[LaunchManager] RPCS3: Failed to create install directory: " + install_path)
			return false
	
	# Step 7: Extract ZIP directly to install location (no temp directory!)
	# Show persistent pulsing notification during extraction
	var rpcs3_notify_id = NotificationManager.show_notification(
		"Extracting " + game.get_display_name() + "...",
		Notification.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true
	)
	print("[LaunchManager] RPCS3: Extracting directly to: " + install_path)
	
	var extract_success := await _extract_ps3_zip(rom_path, install_path)
	
	# Dismiss the extraction notification
	NotificationManager.dismiss_notification(rpcs3_notify_id)
	
	print("[LaunchManager] RPCS3: _extract_ps3_zip returned: " + str(extract_success))
	
	if not extract_success:
		push_error("[LaunchManager] RPCS3: Failed to extract PS3 game ZIP: " + rom_path)
		return false
	
	print("[LaunchManager] RPCS3: Extraction complete, flattening wrapper folders...")
	
	# Step 8: Recursively flatten wrapper folders until we find game files
	# Handles multiple nesting levels: "Tokyo Jungle/NPUA80523/..."
	_flatten_rpcs3_wrappers(install_path)
	
	print("[LaunchManager] RPCS3: Game installed successfully at: " + install_path)
	return true


## Extracts a PS3 game ZIP file to the specified directory (NO TIMEOUT)
func _extract_ps3_zip(zip_path: String, extract_to: String) -> bool:
	print("[LaunchManager] RPCS3: Extracting ZIP: " + zip_path + " to: " + extract_to)
	
	# Use DownloadManager's extraction functionality
	var item_id := DownloadManager.queue_extraction(zip_path, extract_to, "ps3_game", "Extracting PS3 Game", false)
	
	if item_id == "":
		push_error("[LaunchManager] RPCS3: Failed to queue extraction")
		return false
	
	print("[LaunchManager] RPCS3: Waiting for extraction to complete (no timeout)...")
	
	# Use a completion tracker object (works around GDScript closure limitations)
	var completion_tracker := {"complete": false, "success": false}
	
	var on_complete = func(completed_item_id: String, success: bool, message: String):
		if completed_item_id == item_id:
			completion_tracker.complete = true
			completion_tracker.success = success
			print("[LaunchManager] RPCS3: Extraction callback - success=" + str(success))
	
	DownloadManager.extraction_completed.connect(on_complete)
	
	# Wait for extraction to complete (NO TIMEOUT - PS3 games can be very large)
	print("[LaunchManager] RPCS3: Waiting for extraction (no timeout)...")
	while not completion_tracker.complete:
		await get_tree().process_frame
	
	DownloadManager.extraction_completed.disconnect(on_complete)
	
	print("[LaunchManager] RPCS3: Extraction wait loop ended")
	
	print("[LaunchManager] RPCS3: Extraction wait loop ended")
	print("[LaunchManager] RPCS3: completion_tracker.complete=" + str(completion_tracker.complete) + ", completion_tracker.success=" + str(completion_tracker.success))
	
	if not completion_tracker.complete:
		push_error("[LaunchManager] RPCS3: Extraction callback never fired")
		return false
	
	print("[LaunchManager] RPCS3: _extract_ps3_zip returning: " + str(completion_tracker.success))
	return completion_tracker.success


## Prepares a PS4 game for launch by extracting the TitleID and extracting game files
## PS4 games are ZIP files containing a CUSAxxxxx directory at the root
## Returns true if preparation succeeded, false on error
func _prepare_shadps4_game(game: GameResource, intent: LaunchIntent) -> bool:
	print("[LaunchManager] shadPS4: _prepare_shadps4_game called for: " + game.get_display_name())
	
	if not game or not intent:
		print("[LaunchManager] shadPS4: ERROR - game or intent is null")
		return false
	
	var rom_path := game.file_path
	print("[LaunchManager] shadPS4: ROM path: " + rom_path)
	
	if rom_path == "":
		push_error("[LaunchManager] shadPS4: No ROM path for game: " + game.get_display_name())
		return false
	
	# Step 1: Extract TitleID from ZIP
	print("[LaunchManager] shadPS4: Extracting TitleID from ZIP...")
	var zip_title_id = TitleIDParser.extract_ps4_title_id(rom_path)
	if zip_title_id == "":
		push_error("[LaunchManager] shadPS4: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract PS4 game TitleID", Notification.Type.ERROR)
		return false
	print("[LaunchManager] shadPS4: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[LaunchManager] shadPS4: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[LaunchManager] shadPS4: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[LaunchManager] shadPS4: Updated database with TitleID: " + zip_title_id)
	
	var title_id = game.get_active_title_id()
	print("[LaunchManager] shadPS4: Using TitleID: " + title_id)
	
	# Step 2: Determine extraction path (next to the ZIP in the ps4 roms folder)
	var rom_parent_dir = rom_path.get_base_dir()
	var extract_path = rom_parent_dir + "/" + title_id
	print("[LaunchManager] shadPS4: Extraction path: " + extract_path)
	
	# Step 3: Check if already extracted
	if _shadps4_game_has_files(extract_path):
		print("[LaunchManager] shadPS4: Game already extracted at: " + extract_path)
		return true
	
	print("[LaunchManager] shadPS4: Game not extracted, will extract to: " + extract_path)
	
	# Step 4: Create extraction directory
	if not FileSystemManager.dir_exists(extract_path):
		print("[LaunchManager] shadPS4: Creating extraction directory: " + extract_path)
		if not FileSystemManager.make_dir_recursive(extract_path):
			push_error("[LaunchManager] shadPS4: Failed to create extraction directory: " + extract_path)
			return false
	
	# Step 5: Extract ZIP to extraction path
	var shadps4_notify_id = NotificationManager.show_notification(
		"Extracting " + game.get_display_name() + "...",
		Notification.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true
	)
	print("[LaunchManager] shadPS4: Extracting ZIP to: " + extract_path)
	
	var extract_success := await _extract_shadps4_zip(rom_path, extract_path)
	
	# Dismiss the extraction notification
	NotificationManager.dismiss_notification(shadps4_notify_id)
	
	print("[LaunchManager] shadPS4: _extract_shadps4_zip returned: " + str(extract_success))
	
	if not extract_success:
		push_error("[LaunchManager] shadPS4: Failed to extract PS4 game ZIP: " + rom_path)
		return false
	
	print("[LaunchManager] shadPS4: Extraction complete")
	
	return true


## Checks if a shadPS4 game directory has actual game files
func _shadps4_game_has_files(game_path: String) -> bool:
	if not FileSystemManager.dir_exists(game_path):
		return false
	
	var entries = FileSystemManager.list_dir(game_path)
	var actual_files = 0
	for entry in entries:
		if entry == "." or entry == "..":
			continue
		actual_files += 1
	
	print("[LaunchManager] shadPS4: _shadps4_game_has_files: found " + str(actual_files) + " entries in " + game_path)
	return actual_files > 0


## Extracts a PS4 game ZIP file to the specified directory (NO TIMEOUT)
func _extract_shadps4_zip(zip_path: String, extract_to: String) -> bool:
	print("[LaunchManager] shadPS4: Extracting ZIP: " + zip_path + " to: " + extract_to)
	
	# Use DownloadManager's extraction functionality
	var item_id := DownloadManager.queue_extraction(zip_path, extract_to, "ps4_game", "Extracting PS4 Game", false)
	
	if item_id == "":
		push_error("[LaunchManager] shadPS4: Failed to queue extraction")
		return false
	
	print("[LaunchManager] shadPS4: Waiting for extraction to complete (no timeout)...")
	
	# Use a completion tracker object
	var completion_tracker := {"complete": false, "success": false}
	
	var on_complete = func(completed_item_id: String, success: bool, message: String):
		if completed_item_id == item_id:
			completion_tracker.complete = true
			completion_tracker.success = success
			print("[LaunchManager] shadPS4: Extraction callback - success=" + str(success))
	
	DownloadManager.extraction_completed.connect(on_complete)
	
	# Wait for extraction to complete (NO TIMEOUT - PS4 games can be very large)
	print("[LaunchManager] shadPS4: Waiting for extraction (no timeout)...")
	while not completion_tracker.complete:
		await get_tree().process_frame
	
	DownloadManager.extraction_completed.disconnect(on_complete)
	
	print("[LaunchManager] shadPS4: Extraction wait loop ended")
	print("[LaunchManager] shadPS4: completion_tracker.complete=" + str(completion_tracker.complete) + ", completion_tracker.success=" + str(completion_tracker.success))
	
	if not completion_tracker.complete:
		push_error("[LaunchManager] shadPS4: Extraction callback never fired")
		return false
	
	print("[LaunchManager] shadPS4: _extract_shadps4_zip returning: " + str(completion_tracker.success))
	return completion_tracker.success
