extends Manager

## Manages emulator registry, launch intents, and game execution

const REGISTRY_DIR := "res://data/emulators/"
const PLATFORMS_PATH := "res://data/platforms.json"
const FSM = preload("res://managers/filesystem_manager.gd")

## Returns the configured emulators directory from settings, or default if not set
func get_emulators_directory() -> String:
	if SettingsManager:
		var setting = SettingsManager.get_setting("emulators_folder")
		if setting and setting.value != "":
			return setting.value
	return "user://emulators/"

## Gets the full path to an emulator's directory
## Handles path separators correctly for all platforms
func _get_emulator_directory(emulator_id: String) -> String:
	var base_dir = get_emulators_directory()
	return FSM.join_paths(base_dir, emulator_id)

# Registry data
var _emulator_registry: Dictionary = {}
var _platform_defaults: Dictionary = {}
var _platforms_data: Dictionary = {}

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

## Track pending firmware downloads to avoid duplicates
# platform_slug -> bool
var _pending_firmware_downloads: Dictionary = {}

## Track pending launches waiting for firmware download
# platform_slug -> {game: GameResource, emulator_id: String, callback: Callable}
var _pending_firmware_launches: Dictionary = {}

## Validation cache to avoid redundant file system operations
# emulator_id -> {result: Dictionary, timestamp: int, step_results: Dictionary}
var _validation_cache: Dictionary = {}
var _cache_ttl_ms: int = 5000  # 5 second cache TTL

## Clears the validation cache. Call after external install state changes (e.g., APK install).
func clear_validation_cache() -> void:
	_validation_cache.clear()

# ============================================================================
# SHELL ESCAPING HELPERS (prevent command injection from user-controlled paths)
# ============================================================================

## Escapes a string for safe use inside Windows cmd.exe double quotes.
## Escapes cmd metacharacters: & | < > ^ % ( )"
func _escape_cmd_meta(s: String) -> String:
	# Escape caret first (it's the escape character)
	var result = s.replace("^", "^^")
	result = result.replace("\u0026", "^\u0026")
	result = result.replace("|", "^|")
	result = result.replace("<", "^<")
	result = result.replace(">", "^>")
	result = result.replace("(", "^(")
	result = result.replace(")", "^)")
	result = result.replace("%", "%%")
	# Double quotes are escaped by doubling them inside a quoted string
	result = result.replace('"', '""')
	return result

## Escapes a string for safe use inside Unix sh single quotes.
## Wraps in single quotes and handles embedded single quotes.
func _escape_sh_arg(s: String) -> String:
	# Single quotes prevent ALL interpretation in sh
	# To embed a single quote, close the quote, add an escaped quote, reopen
	return "'" + s.replace("'", "'\"'\"'") + "'"

## Escapes an array of arguments for the current platform's shell.
func _escape_args_for_shell(args: Array) -> Array:
	var result = []
	if PlatformManager.is_windows():
		for arg in args:
			result.append('"' + _escape_cmd_meta(arg) + '"')
	else:
		for arg in args:
			result.append(_escape_sh_arg(arg))
	return result

## Clears pending launches whose emulators are now installed.
## Call on app resume after potential APK installations.
func clear_stale_pending_launches() -> void:
	var to_remove = []
	for emulator_id in _pending_launches:
		var emulator = get_emulator(emulator_id)
		if emulator.is_empty():
			to_remove.append(emulator_id)
			continue
		var install_steps = emulator.get("install", [])
		var all_valid = true
		for i in range(install_steps.size()):
			if not _validate_install_step(emulator_id, i, install_steps):
				all_valid = false
				break
		if all_valid:
			print("[LaunchManager] Clearing stale pending launch for emulator: " + emulator_id)
			to_remove.append(emulator_id)
	for emulator_id in to_remove:
		_pending_launches.erase(emulator_id)

# Signals
signal emulator_registry_loaded(success: bool)
signal launch_completed(success: bool, message: String)
@warning_ignore("unused_signal")
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

## Enter background state for Android (no PID polling)
func _enter_background_state_android(game: GameResource) -> void:
	if _is_in_background_state:
		print("[LaunchManager] Warning: Already in background state, ignoring Android entry")
		return
	
	print("[LaunchManager] Entering background state for Android launch")
	_background_active_pid = -1  # No PID on Android
	_background_active_game = game
	_is_in_background_state = true
	
	# Don't start poll timer on Android - we rely on resume notification
	
	background_state_entered.emit(-1, game)

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
	# Load platforms.json
	if FileAccess.file_exists(PLATFORMS_PATH):
		var platforms_file = FileAccess.open(PLATFORMS_PATH, FileAccess.READ)
		if platforms_file:
			var platforms_json = JSON.new()
			var platforms_error = platforms_json.parse(platforms_file.get_as_text())
			platforms_file.close()
			if platforms_error == OK:
				_platforms_data = platforms_json.data
				for platform_id in _platforms_data.keys():
					if platform_id.begins_with("_"):
						continue
					var platform = _platforms_data[platform_id]
					var default_emulator = platform.get("default_emulator", "")
					if default_emulator != "":
						_platform_defaults[platform_id] = default_emulator
	
	# Load individual emulator files from emulators/ directory
	var dir = DirAccess.open(REGISTRY_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				var filepath = REGISTRY_DIR + file_name
				var file = FileAccess.open(filepath, FileAccess.READ)
				if file:
					var json = JSON.new()
					var error = json.parse(file.get_as_text())
					file.close()
					if error == OK:
						var emulator_data = json.data
						var emulator_id = emulator_data.get("meta", {}).get("id", "")
						if emulator_id != "":
							_emulator_registry[emulator_id] = emulator_data
							
							# For platforms without an explicit default, use first available emulator
							var platforms = emulator_data.get("meta", {}).get("platforms", [])
							for platform in platforms:
								if not _platform_defaults.has(platform):
									_platform_defaults[platform] = emulator_id
			file_name = dir.get_next()
		
		emulator_registry_loaded.emit(true)
	else:
		push_error("[LaunchManager] Failed to open emulators directory: " + REGISTRY_DIR)
		emulator_registry_loaded.emit(false)

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
## Recursively searches for executable file up to max_depth (3 levels)
func _find_executable_recursive(dir_path: String, executable_name: String, max_depth: int = 3, current_depth: int = 0) -> String:
	if current_depth >= max_depth:
		return ""
	
	var entries = FSM.list_dir(dir_path)
	if entries.is_empty() and not FSM.dir_exists(dir_path):
		return ""
	
	for file_name in entries:
		if file_name == "." or file_name == "..":
			continue
		
		var full_path = FSM.join_paths(dir_path, file_name)
		
		if FSM.is_dir(full_path):
			var result = _find_executable_recursive(full_path, executable_name, max_depth, current_depth + 1)
			if result != "":
				return result
		else:
			# Check if this is the executable we're looking for
			if file_name.to_lower() == executable_name.to_lower():
				return full_path
	
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
			
			# Fallback: dismiss any lingering extraction notifications for this emulator
			# This handles cases where the notification dismissal failed while backgrounded
			if NotificationManager:
				NotificationManager.dismiss_all_notifications()
			
			return

## Called when DownloadManager completes a download
## Cleans up pending game downloads tracking
func _on_download_manager_download_completed(item_id: String, _success: bool, _message: String):
	# Handle game downloads
	if _pending_game_downloads.has(item_id):
		_pending_game_downloads.erase(item_id)
		return
	
	# Post-install downloads are handled by unified system
	# Let _on_unified_download_completed handle it

## Flattens an extracted directory by moving contents of a single top-level subdirectory up one level
## This handles zips that extract to a nested directory like "Archive-1.0/file.txt" -> "file.txt"
func _flatten_extracted_directory(emulator_id: String, extract_to: String, target_folder: String = ""):
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
			# extract_to is already an absolute path (Unix, Windows, or Godot virtual filesystem style)
			extract_path = extract_to
		else:
			extract_path = FSM.join_paths(_get_emulator_directory(emulator_id), extract_to)
	
	# Normalize the path to remove "." and ".." components
	extract_path = FSM.normalize_path(extract_path)
	
	# If a specific target folder is specified, flatten only that one
	if target_folder != "":
		var target_path = ""
		
		# First try exact match
		var exact_path = FSM.join_paths(extract_path, target_folder)
		if FSM.dir_exists(exact_path):
			target_path = exact_path
		else:
			# Try wildcard match against entries in extract_path
			var candidates = FSM.list_dir(extract_path)
			for entry in candidates:
				if entry != "." and entry != ".." and entry.match(target_folder):
					var entry_path = FSM.join_paths(extract_path, entry)
					if FSM.dir_exists(entry_path):
						target_path = entry_path
						break
		
		if target_path == "":
			return
		
		# Get list of items in the target folder
		var items = FSM.list_dir(target_path)
		
		# Move all contents from the subdirectory to the parent
		for item_name in items:
			if item_name == "." or item_name == "..":
				continue
			
			var source_path = FSM.join_paths(target_path, item_name)
			var dest_path = FSM.join_paths(extract_path, item_name)
			
			# Check if destination already exists
			if FSM.file_exists(dest_path) or FSM.dir_exists(dest_path):
				continue
			
			# Move to parent directory
			if not FSM.move(source_path, dest_path):
				push_warning("[LaunchManager] Failed to flatten item: " + source_path + " -> " + dest_path)
		
		# Remove the now-empty subdirectory
		DirAccess.remove_absolute(target_path)
		return
	
	# No target folder specified, use original logic (single directory only)
	var entries = FSM.list_dir(extract_path)
	
	# Filter out . and ..
	var filtered_entries = []
	for entry in entries:
		if entry != "." and entry != "..":
			filtered_entries.append(entry)
	
	# If there's exactly one entry and it's a directory, flatten it
	if filtered_entries.size() == 1:
		var single_entry = filtered_entries[0]
		var single_entry_path = FSM.join_paths(extract_path, single_entry)
		
		# Check if the single entry is a directory
		var is_dir = FSM.dir_exists(single_entry_path)
		if is_dir:
			# Get all items in the subdirectory
			var sub_items = FSM.list_dir(single_entry_path)
			
			# Move all contents from the subdirectory to the parent
			for item_name in sub_items:
				if item_name == "." or item_name == "..":
					continue
				
				var source_path = FSM.join_paths(single_entry_path, item_name)
				var dest_path = FSM.join_paths(extract_path, item_name)
				
				# Check if destination already exists
				if FSM.file_exists(dest_path) or FSM.dir_exists(dest_path):
					continue
				
				# Move to parent directory
				var move_success = FSM.move(source_path, dest_path)
				print("[LaunchManager] Flattening: move result=" + str(move_success))
				if not move_success:
					push_warning("[LaunchManager] Failed to flatten item: " + source_path + " -> " + dest_path)
			
			# Remove the now-empty subdirectory
			DirAccess.remove_absolute(single_entry_path)

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
	var direct_path = FSM.join_paths(_get_emulator_directory(emulator_id), executable_name)
	if FSM.file_exists(direct_path):
		return direct_path
	
	# Search recursively up to 3 levels deep
	var search_dir = _get_emulator_directory(emulator_id)
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
	
	var cores = emulator.get("cores", {})
	var core = cores.get(platform_slug, {})
	return core.get("mapping", "")

## Gets the app data directory for an emulator on Android
## Resolves to /storage/emulated/0/Android/data/{package}/files/
func get_app_data_path(emulator_id: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var launch = emulator.get("launch", {})
	var platforms = launch.get("platforms", {})
	var android = platforms.get("android", {})
	var package = android.get("package", "")
	
	if package == "":
		return ""
	
	return "/storage/emulated/0/Android/data/" + package + "/files/"

## Gets the RetroArch core name for a platform from platforms.json
## This is the display name used for save directories (e.g., "SwanStation", "Snes9x")
func get_retroarch_core_name(platform_slug: String) -> String:
	var platform = _platforms_data.get(platform_slug, {})
	return platform.get("retroarch_core", "")

## Gets the firmware directory for an emulator
## Resolves paths with wildcards ({emulator_dir}, {app_data}, etc.)
func get_firmware_directory(emulator_id: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var paths = emulator.get("paths", {})
	var firmware = paths.get("firmware", {})
	var default_config = firmware.get("_default", {})
	var directories = default_config.get("directories", {})
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")
	
	if dir == "":
		return ""
	
	# Resolve wildcards
	dir = FSM.resolve_emulator_path(dir, emulator_id)
	return dir.rstrip("/") + "/"

## Checks if firmware is ready for a platform/emulator
## Returns true if firmware directory exists and has any of the expected files
## Searches recursively through subdirectories
func is_platform_firmware_ready(platform_slug: String, emulator_id: String) -> bool:
	var firmware_dir = get_firmware_directory(emulator_id)
	if firmware_dir == "":
		# No firmware directory configured, assume not needed
		return true
	
	if not FSM.dir_exists(firmware_dir):
		return false
	
	# Get expected files from platform configuration
	var platform_config = _platforms_data.get(platform_slug, {})
	var firmware_config = platform_config.get("firmware", {})
	var expected_files = firmware_config.get("expected_files", [])
	
	# No expected files means no BIOS needed for this platform
	if expected_files.is_empty():
		return true
	
	# Check if any expected file exists (searching recursively)
	for expected_file in expected_files:
		if _find_file_recursive(firmware_dir, expected_file):
			return true
	
	return false

## Recursively searches for a file in a directory and its subdirectories
## Returns true if the file is found
func _find_file_recursive(dir: String, filename: String) -> bool:
	if not FSM.dir_exists(dir):
		return false
	
	var entries = FSM.list_dir(dir)
	for entry in entries:
		if entry == "." or entry == "..":
			continue
		
		var full_path = FSM.join_paths(dir, entry)
		
		# Check if this entry matches the filename (handles subdirs like "dc/dc_boot.bin")
		if entry == filename or full_path.ends_with("/" + filename) or full_path.ends_with("\\" + filename):
			if FSM.file_exists(full_path):
				return true
		
		# Recurse into subdirectories
		if FSM.dir_exists(full_path):
			if _find_file_recursive(full_path, filename):
				return true
	
	return false

func _on_firmware_download_complete(success: bool, download_error: String, _notification_id: int, temp_path: String, firmware_dir: String, platform_slug: String, callback: Callable, _last_progress_mb: Array):
	NotificationManager.dismiss_notification(_notification_id)
	
	if not success:
		push_error("[LaunchManager] Failed to download firmware: " + download_error)
		if callback.is_valid():
			callback.call(false, download_error)
		return
	
	print("[LaunchManager] Firmware downloaded, extracting to: " + firmware_dir)
	
	# FSM handles its own extraction notification
	FSM.extract_archive_async(
		temp_path,
		firmware_dir,
		"Firmware for " + platform_slug,
		true,
		func(_e, _t): pass,
		func(extract_success: bool, error_msg: String):
			if not extract_success:
				push_error("[LaunchManager] Failed to extract firmware to: " + firmware_dir + ": " + error_msg)
				if callback.is_valid():
					callback.call(false, error_msg)
				return
			
			print("[LaunchManager] Firmware successfully installed for " + platform_slug)
			if callback.is_valid():
				callback.call(true, "Firmware installed")
	)

## Sets up firmware for a platform by downloading from RomM
## This should be called during platform sync
## callback(success: bool, message: String)
func setup_platform_firmware(platform_slug: String, emulator_id: String, callback: Callable = Callable()) -> void:
	print("[LaunchManager] Checking firmware for " + platform_slug + " / " + emulator_id)
	
	# Check if firmware is already ready
	if is_platform_firmware_ready(platform_slug, emulator_id):
		print("[LaunchManager] Firmware already ready for " + platform_slug)
		if callback.is_valid():
			callback.call(true, "Firmware already installed")
		return
	
	# Get firmware directory
	var firmware_dir = get_firmware_directory(emulator_id)
	if firmware_dir == "":
		print("[LaunchManager] No firmware directory configured for " + emulator_id)
		if callback.is_valid():
			callback.call(true, "No firmware needed")
		return
	
	print("[LaunchManager] Firmware needed for " + platform_slug + ", querying RomM...")
	
	# Query RomM for platform firmware
	NetworkManager.fetch_platform_firmware(platform_slug, func(platform_data: Dictionary, error: String):
		if error != "":
			push_error("[LaunchManager] Failed to fetch firmware info: " + error)
			if callback.is_valid():
				callback.call(false, error)
			return
		
		var firmware_list = platform_data.get("firmware", [])
		if firmware_list.is_empty():
			print("[LaunchManager] No firmware available for " + platform_slug + " on RomM")
			if callback.is_valid():
				callback.call(true, "No firmware on server")
			return
		
		print("[LaunchManager] Found " + str(firmware_list.size()) + " firmware file(s) for " + platform_slug)
		
		# For now, download the first firmware file (should be the zip)
		var firmware = firmware_list[0]
		var firmware_id = firmware.get("id", 0)
		var file_name = firmware.get("file_name", "")
		
		if firmware_id == 0 or file_name == "":
			push_error("[LaunchManager] Invalid firmware data for " + platform_slug)
			if callback.is_valid():
				callback.call(false, "Invalid firmware data")
			return
		
		# Download to temp location first
		var temp_path = "user://temp_firmware/" + file_name
		FSM.make_dir_recursive("user://temp_firmware")
		
		print("[LaunchManager] Downloading firmware: " + file_name)
		
		# Show progress notification
		var _firmware_notification_id = NotificationManager.show_notification(
			"Downloading firmware for " + platform_slug + "...",
			NotificationManager.Type.INFO,
			null,
			0.0,
			Callable(),
			Callable(),
			true  # pulsing
		)
		
		var _last_progress_mb = [-1]
		
		NetworkManager.download_firmware_zip(
			firmware_id,
			file_name,
			temp_path,
			_on_firmware_download_complete.bind(_firmware_notification_id, temp_path, firmware_dir, platform_slug, callback, _last_progress_mb),
			func(size_mb: int):
				if size_mb != _last_progress_mb[0]:
					_last_progress_mb[0] = size_mb
					NotificationManager.update_notification_text(
						_firmware_notification_id,
						"Downloading firmware for " + platform_slug + "... " + str(size_mb) + " MB"
					)
		)
	)

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
func create_launch_intent(game: GameResource, rom_path_override: String = "") -> LaunchIntent:
	if rom_path_override == "" and not game.is_active_variant_downloaded():
		push_error("[LaunchManager] Cannot launch game without local copy: " + game.get_display_name())
		return null
	
	var intent = LaunchIntent.new()
	intent.game = game
	
	if rom_path_override != "":
		intent.rom_path = rom_path_override
	else:
		# Get the correct file path for the active variant
		var active_file_name = game.get_active_file_name()
		
		# Use the actual file_path from game resource
		# Only fall back to constructing path if file_path is empty
		if game.file_path != "":
			intent.rom_path = game.file_path
		else:
			# Fallback: construct path from components (for legacy or if file_path not set)
			var root_folder = SettingsManager.get_setting("games_root_folder")
			var root_path = root_folder.value if root_folder else "user://roms/"
			intent.rom_path = FSM.join_paths(root_path, game.platform_slug, active_file_name)
	
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
		var vita_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id.begins_with("vita3k"):
			print("[LaunchManager] Vita3K launch: game.title_id='" + (intent.game.title_id if intent.game else "") + "', get_active_title_id='" + vita_title_id + "'")
			if vita_title_id != "":
				intent.android_extras.append({
					"key": "AppStartParameters",
					"value": JSON.stringify(["-r", vita_title_id]),
					"type": "string_array"
				})
				print("[LaunchManager] Vita3K launch: Added AppStartParameters extra with TitleID: " + vita_title_id)
			else:
				print("[LaunchManager] Vita3K launch: WARNING - No TitleID available for launch intent!")
		
		# No emulator-specific extra handling needed - all defined in JSON
		
	else:
		# Desktop uses command-line arguments
		var platform_config = platforms.get(platform_name, {})
		var template = platform_config.get("template", [])
		
		var install_path = get_emulator_install_path(intent.emulator_id)
		
		# Convert paths to absolute system paths for OS.execute
		# Use native path resolution for external tools (converts user:// and handles Windows backslashes)
		var global_install_path = FSM.resolve_native_path(install_path)
		var global_rom_path = FSM.resolve_native_path(intent.rom_path)
		
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
		var desktop_vita_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id.begins_with("vita3k") and desktop_vita_title_id != "":
			# Replace the ROM path (ZIP) with the TitleID flag
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = "-r"
					intent.launch_args.insert(i + 1, desktop_vita_title_id)
					break
		
		# RPCS3 special handling for desktop - replace ROM path with game folder path
		var desktop_rpcs3_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id.begins_with("rpcs3") and desktop_rpcs3_title_id != "":
			# Check both disc and digital install locations
			var disc_path: String = FSM.resolve_native_path(FSM.join_paths(install_dir, "games", desktop_rpcs3_title_id))
			var digital_path: String = FSM.resolve_native_path(FSM.join_paths(install_dir, "dev_hdd0", "game", desktop_rpcs3_title_id))
			
			var game_path: String
			if FSM.dir_exists(disc_path):
				game_path = disc_path
			elif FSM.dir_exists(digital_path):
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
		
		# shadPS4 special handling for desktop - replace ROM path with TitleID
		# shadPS4 searches configured installDirs for matching TitleID folder
		var shadps4_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id == "shadps4" and shadps4_title_id != "":
			print("[LaunchManager] shadPS4: Using TitleID: " + shadps4_title_id)
			
			# Replace the ROM path (ZIP) with just the TitleID
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = shadps4_title_id
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
		NotificationManager.show_notification("Emulator not ready: " + intent.emulator_name, NotificationManager.Type.ERROR)
		return false
	
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
		# Properly escape all arguments for shell safety
		var safe_args = _escape_args_for_shell(arguments)

		if PlatformManager.is_windows():
			# Windows: use cmd /c with properly escaped paths
			var safe_working_dir = _escape_cmd_meta(intent.working_directory)
			var safe_exe = _escape_cmd_meta(exe_path)
			var inner_cmd = 'cd /d "%s" && "%s" %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			print("[LaunchManager] Executing command: cmd /c ", inner_cmd)
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
		else:
			# Linux/macOS: use sh -c with single-quoted arguments
			var safe_working_dir = _escape_sh_arg(intent.working_directory)
			var safe_exe = _escape_sh_arg(exe_path)
			var inner_cmd = 'cd %s && %s %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			pid = OS.create_process("sh", ["-c", inner_cmd], false)
	else:
		# No working directory needed: call executable directly (no shell, no injection risk)
		pid = OS.create_process(exe_path, arguments, false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to launch process: " + exe_path)
		launch_completed.emit(false, "Failed to start emulator")
		return false
	
	# Store PID and enter background state for desktop
	_enter_background_state(pid, intent.game)
	
	launch_completed.emit(true, "Game launched successfully")
	return true

## Creates a process from a launch intent without entering background state.
## Returns the PID or -1 on failure.
func _create_process_from_intent(intent: LaunchIntent) -> int:
	if intent.launch_args.is_empty():
		push_error("[LaunchManager] No launch arguments for desktop")
		return -1
	
	var exe_path = intent.launch_args[0]
	var arguments = intent.launch_args.slice(1)
	var pid: int
	
	if intent.working_directory != "":
		var safe_args = _escape_args_for_shell(arguments)
		if PlatformManager.is_windows():
			var safe_working_dir = _escape_cmd_meta(intent.working_directory)
			var safe_exe = _escape_cmd_meta(exe_path)
			var inner_cmd = 'cd /d "%s" && "%s" %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
		else:
			var safe_working_dir = _escape_sh_arg(intent.working_directory)
			var safe_exe = _escape_sh_arg(exe_path)
			var inner_cmd = 'cd %s && %s %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			pid = OS.create_process("sh", ["-c", inner_cmd], false)
	else:
		pid = OS.create_process(exe_path, arguments, false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to launch process: " + exe_path)
		return -1
	
	return pid

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
		var path = FSM.join_paths(install_path, folder)
		FSM.make_dir_recursive(path)

func _execute_controller_edit_file(task: Dictionary, install_path: String) -> bool:
	var file_path = task.get("file", "")
	var full_path = FSM.join_paths(install_path, file_path)
	
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
	if not FSM.file_exists(file_path):
		return false
	
	var content = FSM.read_file(file_path)
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
	
	if FSM.file_exists(file_path):
		existing_content = FSM.read_file(file_path)
	
	# Parse the new content to find sections we need to replace
	var new_sections = _parse_ini_sections(content)
	
	# Replace or append sections in existing content
	var final_content = existing_content
	for section_name in new_sections.keys():
		var section_content = new_sections[section_name]
		final_content = _replace_or_append_section(final_content, section_name, section_content)
	
	if not FSM.write_file(file_path, final_content):
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

## Launch a game for the shuffler (no save sync, no background state).
## Calls on_pid_ready(pid) when the process is created. PID may be -1 on failure.
## If a download is pending, the function returns immediately and on_pid_ready will be called later.
func launch_shuffler_game(game: GameResource, rom_path_override: String, on_pid_ready: Callable = Callable()) -> void:
	print("[LaunchManager] launch_shuffler_game() called for: ", game.get_display_name())
	
	var emulator_id = resolve_emulator_for_game(game)
	if emulator_id == "":
		push_error("[LaunchManager] No emulator configured for platform: " + game.platform_slug)
		if on_pid_ready.is_valid():
			on_pid_ready.call(-1)
		return
	
	var on_ready = func():
		var intent = create_launch_intent(game, rom_path_override)
		if not intent:
			push_error("[LaunchManager] Failed to create launch intent")
			if on_pid_ready.is_valid():
				on_pid_ready.call(-1)
			return
		
		if PlatformManager.is_android():
			push_error("[LaunchManager] Shuffler not supported on Android")
			if on_pid_ready.is_valid():
				on_pid_ready.call(-1)
			return
		
		var pid = _create_process_from_intent(intent)
		if pid != -1:
			print("[LaunchManager] Shuffler launch successful, PID: ", pid)
		if on_pid_ready.is_valid():
			on_pid_ready.call(pid)
	
	var ready = await _ensure_prerequisites(game, emulator_id, on_ready, false)
	if not ready:
		return  # Download pending, callback will handle it
	# If ready, on_ready was already called

## Main entry point for launching a game
func launch_game(game: GameResource, focus_index: int = -1) -> void:
	print("[LaunchManager] launch_game() called for: ", game.get_display_name() if game else "null", " with focus_index: ", focus_index)
	
	# Emit signal immediately so focus can be saved before any suspension happens
	print("[LaunchManager] Emitting game_launch_initiated signal")
	game_launch_initiated.emit(game, focus_index)
	
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
	
	# Single ordered flow: emulator -> firmware -> prep -> saves -> launch
	_launch_with_emulator_check(game)

## Launch a GameNative game via intent
func _launch_gamenative_game(game: GameResource) -> void:
	if not PlatformManager.is_android():
		push_error("[LaunchManager] Cannot launch GameNative game on non-Android platform")
		NotificationManager.show_notification("GameNative games only available on Android", NotificationManager.Type.ERROR)
		return
	
	var success = GameNativeManager.launch_game(game.steam_app_id)
	if success:
		_update_last_played(game)
		game_launched.emit(game)
	else:
		push_error("[LaunchManager] Failed to launch GameNative game")
		NotificationManager.show_notification("Failed to launch GameNative. Is the app installed?", NotificationManager.Type.ERROR)
	
## If game is not downloaded, queue the download first then proceed
func _queue_game_download_then_launch(game: GameResource) -> void:
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		NotificationManager.show_notification("Error: Games folder not set", NotificationManager.Type.ERROR)
		return
	
	var destination_path = FSM.join_paths(root_folder.value, game.platform_slug, active_file_name)
	
	NotificationManager.show_notification("Downloading " + game.get_display_name() + "...", NotificationManager.Type.INFO)
	
	# Define callback for when download completes
	var on_download_complete = func(success: bool, _path: String):
		if success:
			var updated_game = DataManager.get_game_by_id(game.romm_id)
			var game_to_launch = updated_game if updated_game else game
			var emulator_id = resolve_emulator_for_game(game_to_launch)
			
			# Single ordered flow: emulator -> firmware -> prep -> saves -> launch
			_launch_with_emulator_check(game_to_launch)
		else:
			NotificationManager.show_notification("Download failed for " + game.get_display_name(), NotificationManager.Type.ERROR)
	
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
		NotificationManager.show_notification("Failed to queue download", NotificationManager.Type.ERROR)

## Ensures emulator is installed, firmware is ready, and game is prepared.
## Returns true if everything is ready and on_ready was called.
## Returns false if a download was started (caller should return and wait for callback).
func _ensure_prerequisites(game: GameResource, emulator_id: String, on_ready: Callable, prepare_game: bool = true) -> bool:
	var emulator = get_emulator(emulator_id)
	var emulator_name = emulator.get("name", emulator_id)
	
	# Check if emulator is fully installed
	var is_actually_installed = true
	var install_steps = emulator.get("install", [])
	for i in range(install_steps.size()):
		if not _validate_install_step(emulator_id, i, install_steps):
			is_actually_installed = false
			break
	
	# If emulator is now installed but there's a stale pending launch, clear it
	if is_actually_installed and _pending_launches.has(emulator_id):
		print("[LaunchManager] Emulator " + emulator_id + " is installed, clearing stale pending launch")
		_pending_launches.erase(emulator_id)
	
	# Check if this game is already pending launch
	if _pending_launches.has(emulator_id):
		var pending_data = _pending_launches[emulator_id]
		var pending_game: GameResource = pending_data.game
		if pending_game.romm_id == game.romm_id:
			NotificationManager.show_notification("Game already pending launch! Waiting for emulator installation...", NotificationManager.Type.WARNING)
			return false
	
	if not is_actually_installed:
		NotificationManager.show_notification("Setting up " + emulator_name + "...", NotificationManager.Type.INFO)
		
		if not emulator_extraction_completed.is_connected(_on_emulator_installed_for_launch):
			emulator_extraction_completed.connect(_on_emulator_installed_for_launch)
		
		_pending_launches[emulator_id] = {game = game, callback = on_ready}
		
		var download_success = download_emulator(emulator_id)
		
		if download_success:
			NotificationManager.show_notification(emulator_name + " downloading... Will auto-launch when ready.", NotificationManager.Type.INFO)
		else:
			NotificationManager.show_notification("Failed to queue " + emulator_name + " download", NotificationManager.Type.ERROR)
			_pending_launches.erase(emulator_id)
		return false
	
	# Emulator is installed - check firmware
	if not is_platform_firmware_ready(game.platform_slug, emulator_id):
		if _pending_firmware_downloads.has(game.platform_slug):
			print("[LaunchManager] Firmware download already in progress for " + game.platform_slug + ", will launch when ready")
			NotificationManager.show_notification("Firmware download in progress for " + game.platform_slug + "...", NotificationManager.Type.INFO)
			_pending_firmware_launches[game.platform_slug] = {game = game, emulator_id = emulator_id, callback = on_ready}
			return false
		
		print("[LaunchManager] Firmware not ready for " + game.platform_slug + ", downloading...")
		NotificationManager.show_notification("Downloading firmware for " + game.platform_slug + "...", NotificationManager.Type.INFO)
		
		_pending_firmware_downloads[game.platform_slug] = true
		_pending_firmware_launches[game.platform_slug] = {game = game, emulator_id = emulator_id, callback = on_ready}
		
		setup_platform_firmware(game.platform_slug, emulator_id, func(success: bool, message: String):
			_pending_firmware_downloads.erase(game.platform_slug)
			
			var pending = _pending_firmware_launches.get(game.platform_slug)
			if pending:
				_pending_firmware_launches.erase(game.platform_slug)
				var pending_callback = pending.callback
				
				if not success:
					push_error("[LaunchManager] Firmware download failed for " + game.platform_slug + ": " + message)
					NotificationManager.show_notification("Failed to download firmware for " + game.platform_slug, NotificationManager.Type.ERROR)
					return
				
				print("[LaunchManager] Firmware ready for " + game.platform_slug + ", continuing launch...")
				if pending_callback.is_valid():
					pending_callback.call()
		)
		
		return false
	
	if prepare_game:
		# Emulator and firmware are ready - prepare game
		print("[LaunchManager] _ensure_prerequisites: Preparing game for emulator: " + emulator_id)
		var prep_success = await _prepare_game_for_launch(game, emulator_id)
		if not prep_success:
			push_error("[LaunchManager] Failed to prepare game for launch: " + game.get_display_name())
			NotificationManager.show_notification("Failed to prepare game for launch", NotificationManager.Type.ERROR)
			return false
		print("[LaunchManager] _ensure_prerequisites: Game preparation complete")
	else:
		print("[LaunchManager] _ensure_prerequisites: Skipping game preparation (shuffler session)")
	
	on_ready.call()
	return true

## Check emulator status and launch game (game must be downloaded)
func _launch_with_emulator_check(game: GameResource) -> void:
	print("[LaunchManager] _launch_with_emulator_check: ENTER for " + game.get_display_name())
	
	var emulator_id = resolve_emulator_for_game(game)
	
	if emulator_id == "":
		NotificationManager.show_notification("No emulator configured for platform: " + game.platform_slug, NotificationManager.Type.ERROR)
		return
	
	var on_ready = func():
		# Sync saves then launch
		if emulator_id != "":
			print("[LaunchManager] Starting pre-launch save sync...")
			SaveManager.auto_download_saves_for_game(game, emulator_id, func():
				print("[LaunchManager] Pre-launch save sync complete, launching game...")
				_launch_game_internal(game, emulator_id)
			)
		else:
			_launch_game_internal(game, emulator_id)
		print("[LaunchManager] _launch_with_emulator_check: EXIT")
	
	var ready = await _ensure_prerequisites(game, emulator_id, on_ready)
	if not ready:
		return  # Download pending, callback will handle it
	# If ready, on_ready was already called

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
		var pending = _pending_launches[emulator_id]
		var game: GameResource = pending.game
		var callback: Callable = pending.callback
		_pending_launches.erase(emulator_id)
		NotificationManager.show_notification("Launching " + game.get_display_name() + "...", NotificationManager.Type.INFO)
		
		# Give a small delay for file system to settle
		await get_tree().create_timer(0.5).timeout
		
		print("[LaunchManager] _on_emulator_installed_for_launch: Calling ready callback for emulator: " + emulator_id)
		if callback.is_valid():
			callback.call()

## Internal function to actually launch the game (emulator must be installed)
func _launch_game_internal(game: GameResource, emulator_id: String) -> void:
	print("[LaunchManager] _launch_game_internal: ENTER for " + game.get_display_name() + " (emulator: " + emulator_id + ")")
	
	var intent = create_launch_intent(game)
	
	if not intent:
		push_error("[LaunchManager] _launch_game_internal: create_launch_intent returned null")
		NotificationManager.show_notification("Failed to create launch intent", NotificationManager.Type.ERROR)
		print("[LaunchManager] _launch_game_internal: EXIT (null intent)")
		return
	
	# Wait for launch transition overlay phase 1 to complete before opening game window
	# This ensures the user sees the card scale up before the game covers it
	if LaunchTransitionOverlay.is_transition_active:
		print("[LaunchManager] Waiting for launch transition overlay phase 1...")
		# Find the overlay instance to await its signal
		var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
		if overlay_nodes.size() > 0:
			var overlay = overlay_nodes[0] as LaunchTransitionOverlay
			if overlay:
				if overlay.is_phase1_complete():
					print("[LaunchManager] Overlay phase 1 already complete, proceeding")
				else:
					await overlay.phase1_completed
					print("[LaunchManager] Overlay phase 1 complete, proceeding with launch")
		else:
			# Fallback: wait for the expected duration
			await get_tree().create_timer(0.5).timeout
	
	print("[LaunchManager] _launch_game_internal: Launch intent created, executing launch...")
	var success = execute_launch(intent)
	
	if not success:
		push_error("[LaunchManager] _launch_game_internal: execute_launch returned false")
		NotificationManager.show_notification("Failed to launch " + game.get_display_name(), NotificationManager.Type.ERROR)
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
				plugin.requestManageExternalStoragePermission()
			
			dialog.confirmed.connect(on_confirmed)
			UIManager.add_child(dialog)
			dialog.popup_centered()
		return false
	
	# Format the core path for RetroArch
	var core_path = ""
	
	# Check if using CoreSideloadActivity (for testing sideloaded cores)
	if intent.android_class == "com.retroarch.browser.debug.CoreSideloadActivity":
		# Use downloaded core from emulator directory
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Cores are downloaded to {emulator_dir}/cores
			var _emulator_dir = _get_emulator_directory(intent.emulator_id)
			# Use real filesystem path - with MANAGE_EXTERNAL_STORAGE, RetroArch can read directly
			core_path = FSM.resolve_emulator_path("cores/" + core_filename, intent.emulator_id, "", FSM.PathFormat.ABSOLUTE)
			print("[LaunchManager] Core path for sideload: " + core_path)
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
	
	# Resolve ROM path to absolute filesystem path for the Java plugin.
	# The plugin creates File objects directly, so user:// virtual paths won't work.
	var absolute_rom_path = FSM.resolve_path(intent.rom_path, {"format": FSM.PathFormat.ABSOLUTE})
	print("[LaunchManager] Resolved ROM path for Android intent: " + absolute_rom_path)
	
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
	# Replace {core_path} placeholder with actual core path
	var extras_json = "[]"
	if extras_array.size() > 0:
		var extras_to_serialize = []
		for extra in extras_array:
			var value = extra.get("value", "")
			if value.contains("{core_path}"):
				value = value.replace("{core_path}", core_path)
				print("[LaunchManager] Replaced {core_path} with: " + core_path)
			
			extras_to_serialize.append({
				"key": extra.get("key", ""),
				"value": value,
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
		absolute_rom_path,
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
		return false
	
	# Enter background state for Android - we track the game and exit on resume
	_enter_background_state_android(intent.game)
	
	return true

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
	
	# Ensure emulator directory exists before starting install
	var emulator_dir = _get_emulator_directory(emulator_id)
	if not FSM.dir_exists(emulator_dir):
		print("[LaunchManager] Creating emulator directory: " + emulator_dir)
		if not FSM.make_dir_recursive(emulator_dir):
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
		_create_emulator_save_directory(emulator_id)
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
## APKs are downloaded to the emulator directory for consistency
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
	
	# APKs are downloaded to the emulator directory (same as other platforms)
	var emulator_dir = _get_emulator_directory(emulator_id)
	var apk_path = ""
	
	# Find the APK file in emulator directory
	var entries = FSM.list_dir(emulator_dir)
	for file_name in entries:
		if file_name.match(expected_file):
			apk_path = FSM.join_paths(emulator_dir, file_name)
			print("[LaunchManager] Found APK: " + apk_path)
			break
	
	# If no APK found, retry download
	if apk_path == "":
		print("[LaunchManager] No APK found in emulator directory, retrying download")
		return _retry_previous_step(emulator_id, step_index)
	
	# Validate APK file exists and has content
	var file_size = FSM.get_file_size(apk_path)
	print("[LaunchManager] APK file size: " + str(file_size) + " bytes")
	if file_size < 0:
		print("[LaunchManager] ERROR: Cannot access APK file!")
		return _retry_previous_step(emulator_id, step_index)
	elif file_size < 1000:
		print("[LaunchManager] ERROR: APK file is too small or empty!")
		NotificationManager.show_notification(
			"APK download incomplete!\nFile size: " + str(file_size) + " bytes",
			NotificationManager.Type.ERROR,
			null,
			10.0
		)
		_emulator_install_progress[emulator_id] = "APK download incomplete"
		return false
	
	print("[LaunchManager] Installing APK: " + apk_path)
	
	# On Android, use plugin to install APK with content:// URI (required for Android N+)
	var plugin = null
	if Engine.has_singleton("PackageChecker"):
		plugin = Engine.get_singleton("PackageChecker")
	
	var result = Error.FAILED
	if plugin != null:
		# Convert Godot virtual path (user://) to an absolute filesystem path
		# so the Java plugin can create a File object from it.
		var absolute_apk_path = FSM.resolve_path(apk_path, {"format": FSM.PathFormat.ABSOLUTE})
		print("[LaunchManager] Resolved APK path for plugin: " + absolute_apk_path)
		var success = plugin.call("installApk", absolute_apk_path)
		if success:
			result = Error.OK
	else:
		push_error("[LaunchManager] PackageChecker plugin not available for APK install")
	
	if result != Error.OK:
		print("[LaunchManager] APK install failed with error: " + str(result))
		NotificationManager.show_notification(
			"APK install failed!\nPlease install manually from:\n" + apk_path,
			NotificationManager.Type.ERROR,
			null,
			10.0
		)
		
		# Try to open the folder
		var folder_result = OS.shell_open(FSM.resolve_path(emulator_dir, {"format": FSM.PathFormat.ABSOLUTE}))
		if folder_result == Error.OK:
			print("[LaunchManager] Opened folder containing APK")
		
		_emulator_install_progress[emulator_id] = "APK install failed"
		return false
	
	print("[LaunchManager] APK installer opened successfully")
	print("[LaunchManager] User must complete installation in Android UI")
	
	# Show reminder on Android to open the app and grant permissions
	_show_android_permissions_reminder(emulator_id)
	
	# DEBUG: Don't delete APK so we can check it
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
	extract_to = FSM.resolve_emulator_path(extract_to, emulator_id)
	
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
	
	# Create a single batch progress notification
	var batch_notification_id = NotificationManager.show_notification(
		step_display_name + " (0/" + str(total_cores) + ")",
		NotificationManager.Type.INFO,
		null,
		0.0,
		func() -> float:
			return float(progress.completed) / float(total_cores),
		func(_p: float) -> String:
			return step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")"
	)
	
	# Queue all downloads
	for core_name in cores:
		# Construct URL from pattern
		var filename = url_pattern.replace("{name}", core_name)
		var full_url = base_url + filename
		
		# Resolve extract directory using universal path resolver
		var extract_dir = FSM.resolve_emulator_path(extract_to, emulator_id)
		
		# Normalize the path to remove "." and ".." components
		extract_dir = FSM.normalize_path(extract_dir)
		
		# Download to emulator directory (for extraction, then delete)
		var destination_path = FSM.join_paths(_get_emulator_directory(emulator_id), filename)
		
		# Queue download without auto-extract (extraction happens in separate step)
		# suppress_notification=true to avoid dozens of individual notifications
		var item_id = DownloadManager.queue_download(
			full_url,
			destination_path,
			"emulator_core",
			core_name,
			false,   # auto_extract - extraction handled by install_cores step
			"",      # extract_dir - not used here
			null,    # game
			{},      # callbacks
			0,       # romm_id
			false,   # delete_after_extract - keep zips for extraction step
			true     # suppress_notification - use batch notification instead
		)
		
		if item_id == "":
			progress.failed += 1
		else:
			download_ids.append(item_id)
			
			# Create a callback that captures by reference (Dictionary is a reference type)
			var callback = func(success: bool, _message: String):
				progress.completed += 1
				if not success:
					progress.failed += 1
				# Update progress
				_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")"
				# Check if all downloads are complete
				if progress.completed >= total_cores:
					# Dismiss the batch notification
					NotificationManager.dismiss_notification(batch_notification_id)
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
		NotificationManager.dismiss_notification(batch_notification_id)
		return false
	
	return true

## Executes extract action for a step
func _execute_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary) -> bool:
	var extract_to = extract_config.get("extract_to", ".")
	var strip_top = extract_config.get("strip_top_directory", false)
	var flatten_target = extract_config.get("flatten_target", "")
	
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Resolve path using universal resolver
	var extract_dir = FSM.resolve_emulator_path(extract_to, emulator_id)
	
	# Normalize the path to remove "." and ".." components
	extract_dir = FSM.normalize_path(extract_dir)
	
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
		var files = FSM.list_dir(emulator_dir)
		print("[LaunchManager] _execute_extract_step: files in emulator_dir=" + str(files))
		for file_name in files:
			print("[LaunchManager] _execute_extract_step: checking if '" + file_name + "' matches pattern '" + expected_file + "'")
			if file_name.match(expected_file):
				var full_path = FSM.join_paths(emulator_dir, file_name)
				print("[LaunchManager] _execute_extract_step: MATCH! full_path=" + full_path)
				if FSM.file_exists(full_path):
					archive_path = full_path
					print("[LaunchManager] _execute_extract_step: archive_path set to " + archive_path)
					break
				else:
					print("[LaunchManager] _execute_extract_step: file exists check failed for " + full_path)
		print("[LaunchManager] _execute_extract_step: after expected_file loop, archive_path=" + archive_path)
	
	# If no expected_file match, scan for common archive extensions (first match only)
	if archive_path == "":
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var files = FSM.list_dir(emulator_dir)
		for file_name in files:
			var lower_name = file_name.to_lower()
			for ext in archive_extensions:
				if lower_name.ends_with(ext):
					var full_path = FSM.join_paths(emulator_dir, file_name)
					if FSM.file_exists(full_path):
						archive_path = full_path
						break
			if archive_path != "":
				break
	
	# Check if archive was found
	if archive_path == "" or not FSM.file_exists(archive_path):
		# Go back to download step to re-download
		return _retry_previous_step(emulator_id, step_index)
	
	# Get step name from install_steps for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var step_display_name = _get_step_display_name(step_name)
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Notify UI that extraction has started
	emulator_extraction_started.emit(emulator_id)
	
	# Queue extraction via DownloadManager
	var item_id = DownloadManager.queue_extraction(archive_path, extract_dir, "emulator", step_display_name)
	if item_id == "":
		push_error("[LaunchManager] Failed to queue extraction for: " + emulator_id)
		return false
	
	# Create callback for single archive extraction
	var extraction_callback = func(success: bool, _message: String):
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
		
		# Notify UI that extraction completed successfully
		emulator_extraction_completed.emit(emulator_id, true)
		
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
	var emulator_dir = _get_emulator_directory(emulator_id)
	var archive_paths = []
	
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	if expected_file != "":
		var files = FSM.list_dir(emulator_dir)
		for file_name in files:
			if file_name.match(expected_file):
				var full_path = FSM.join_paths(emulator_dir, file_name)
				if FSM.file_exists(full_path):
					archive_paths.append(full_path)
	
	# If no expected_file match, scan for common archive extensions
	if archive_paths.is_empty():
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var files = FSM.list_dir(emulator_dir)
		for file_name in files:
			var lower_name = file_name.to_lower()
			for ext in archive_extensions:
				if lower_name.ends_with(ext):
					var full_path = FSM.join_paths(emulator_dir, file_name)
					if FSM.file_exists(full_path):
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
	
	# Notify UI that extraction has started
	emulator_extraction_started.emit(emulator_id)
	
	# Track progress for multiple extractions using Dictionary (reference type for closures)
	var total_archives = archive_paths.size()
	var progress = {"completed": 0, "failed": 0}
	var extraction_ids = []
	
	# Create a single batch progress notification
	var batch_notification_id = NotificationManager.show_notification(
		step_display_name + " (0/" + str(total_archives) + ")",
		NotificationManager.Type.INFO,
		null,
		0.0,
		func() -> float:
			return float(progress.completed) / float(total_archives),
		func(_p: float) -> String:
			return step_display_name + " (" + str(progress.completed) + "/" + str(total_archives) + ")"
	)
	
	# Queue extraction for all archives
	for archive_path in archive_paths:
		var item_id = DownloadManager.queue_extraction(archive_path, extract_dir, "emulator", step_display_name, true, true)
		if item_id == "":
			push_error("[LaunchManager] Failed to queue extraction for: " + archive_path)
			progress.failed += 1
		else:
			extraction_ids.append(item_id)
	
	if extraction_ids.is_empty():
		push_error("[LaunchManager] No extractions could be queued for batch: " + emulator_id)
		NotificationManager.dismiss_notification(batch_notification_id)
		return false
	
	# Create callback for batch extraction (shared by all archives)
	var batch_callback = func(success: bool, _message: String):
		progress.completed += 1
		
		if not success:
			progress.failed += 1
			
		# Update progress
		_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_archives) + ")"
		
		# Check if all extractions are complete
		if progress.completed >= total_archives:
			# Dismiss batch notification
			NotificationManager.dismiss_notification(batch_notification_id)
			
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
			
			# Notify UI that extraction completed successfully
			emulator_extraction_completed.emit(emulator_id, true)
			
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
			var full_path = FSM.resolve_emulator_path(file_path, emulator_id)
			return FSM.file_exists(full_path)
		
		"folder_exists":
			var folder_path = validate_config.get("path", "")
			if folder_path == "":
				return true
			var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
			return FSM.dir_exists(full_path)
		
		"files_exist":
			var folder_path = validate_config.get("path", "")
			var pattern = validate_config.get("pattern", "")
			var files_array = validate_config.get("files", [])
			
			# Support both "files" array format and "path" + "pattern" format
			if files_array.size() > 0:
				# Check if all files in the array exist
				for file_name in files_array:
					var full_file_path = FSM.resolve_emulator_path(file_name, emulator_id)
					if not FSM.file_exists(full_file_path):
						return false
				return true
			
			if folder_path == "":
				return true
			
			var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
			
			var entries = FSM.list_dir(full_path)
			for file_name in entries:
				if file_name != "." and file_name != "..":
					if pattern == "" or file_name.match(pattern):
						return true
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
		func(url: String, tag: String, error: String, file_size: int, published_at: String):
			if error != "":
				push_error("[LaunchManager] Failed to fetch release: " + error)
				_emulator_install_progress[emulator_id] = "Failed to fetch release"
				return
			# Use published_at date as version for date-based comparison
			# Fall back to tag name if no date available
			var version_to_save = published_at if published_at != "" else tag
			if version_to_save != "":
				# force=true to overwrite any existing version during install
				_save_emulator_version(emulator_id, version_to_save, true)
				print("[LaunchManager] Saved emulator version for " + emulator_id + ": " + version_to_save)
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config, file_size),
		release_tag,
		api_base_url
	)
	return true

## Helper function for download_scrape action
func _handle_download_scrape_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var scrape_url = platform_config.get("scrape_url", "")
	var version_pattern = platform_config.get("version_pattern", "")
	var url_template = platform_config.get("url_template", "")
	var match_strategy = platform_config.get("match_strategy", "first")
	var json_path = platform_config.get("json_path", "")
	
	if scrape_url == "" or url_template == "":
		push_error("[LaunchManager] Invalid download_scrape config for step: " + step_name)
		return false
	
	# version_pattern is required for HTML scraping, optional for JSON API mode
	if json_path == "" and version_pattern == "":
		push_error("[LaunchManager] download_scrape requires either version_pattern or json_path for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = "Scraping for latest version..."
	
	var step_display_name = _get_step_display_name(step_name)
	
	NetworkManager.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(url: String, version: String, error: String):
			if error != "":
				push_error("[LaunchManager] Failed to scrape release: " + error)
				_emulator_install_progress[emulator_id] = "Failed to scrape release"
				return
			if version != "":
				# force=true to overwrite any existing version during install
				_save_emulator_version(emulator_id, version, true)
				print("[LaunchManager] Saved emulator version for " + emulator_id + ": " + version)
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config),
		match_strategy,
		json_path
	)
	return true

## Saves the installed emulator version to settings for update checking.
## Only stores the FIRST download step's version to prevent secondary assets
## (e.g. shadPS4 Qt launcher) from clobbering the core version.
## Set force=true to overwrite an existing version (used by async version fetch).
func _save_emulator_version(emulator_id: String, version: String, force: bool = false):
	if SettingsManager:
		var setting = SettingsManager.get_setting("installed_emulator_versions")
		if setting:
			var versions = setting.value as Dictionary
			if versions == null:
				versions = {}
			# Only save if not already present (first download step wins), unless force is true
			if not versions.has(emulator_id) or force:
				versions[emulator_id] = version
				SettingsManager.set_setting(versions, setting)
				SettingsManager.save_settings()
				print("[LaunchManager] Saved version for " + emulator_id + ": " + version)
			else:
				print("[LaunchManager] Skipped saving version for " + emulator_id + " (already exists: " + versions.get(emulator_id, "") + ")")

## Clears stored version so a fresh install/update can save a new version.
func _clear_emulator_version(emulator_id: String):
	if SettingsManager:
		var setting = SettingsManager.get_setting("installed_emulator_versions")
		if setting:
			var versions = setting.value as Dictionary
			if versions != null and versions.has(emulator_id):
				versions.erase(emulator_id)
				SettingsManager.set_setting(versions, setting)
				SettingsManager.save_settings()

## Normalizes a version string for comparison/display
func _normalize_version(version: String) -> String:
	var regex = RegEx.new()
	regex.compile("^[vV]\\.?(.*)$")
	var match_result = regex.search(version)
	if match_result:
		return match_result.get_string(1).replace("_", ".")
	return version.replace("_", ".")

## Checks if a version string looks like semver
func _is_semver(version: String) -> bool:
	var normalized = _normalize_version(version)
	var regex = RegEx.new()
	regex.compile("^[0-9]+(\\.[0-9]+)*")
	return regex.search(normalized) != null

## Compares two version strings
## Returns: -1 (a < b), 0 (equal), 1 (a > b), 2 (incomparable)
func _compare_versions(a: String, b: String) -> int:
	var na = _normalize_version(a)
	var nb = _normalize_version(b)
	
	if na == nb:
		return 0
	
	var regex = RegEx.new()
	regex.compile("^([0-9]+(?:\\.[0-9]+)*)")
	var match_a = regex.search(na)
	var match_b = regex.search(nb)
	
	if match_a and match_b:
		# Both have numeric prefixes - compare semver-style
		var parts_a = match_a.get_string(1).split(".")
		var parts_b = match_b.get_string(1).split(".")
		var max_len = max(parts_a.size(), parts_b.size())
		for i in range(max_len):
			var va = int(parts_a[i]) if i < parts_a.size() else 0
			var vb = int(parts_b[i]) if i < parts_b.size() else 0
			if va < vb:
				return -1
			elif va > vb:
				return 1
		return 0
	
	# Opaque strings - incomparable
	return 2

## Parses an ISO 8601 date string to unix timestamp for comparison
## Returns -1 if parsing fails
func _parse_iso_date(date_str: String) -> int:
	if date_str == "" or not date_str.contains("-"):
		return -1
	
	# Use regex to validate format first (avoids Godot parser error spam)
	# Matches: 2024-01-15T10:30:00Z or 2024-01-15T10:30:00+00:00
	var regex = RegEx.new()
	regex.compile("^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})")
	var match_result = regex.search(date_str)
	if not match_result:
		return -1
	
	var year = int(match_result.get_string(1))
	var month = int(match_result.get_string(2))
	var day = int(match_result.get_string(3))
	var hour = int(match_result.get_string(4))
	var minute = int(match_result.get_string(5))
	var second = int(match_result.get_string(6))
	
	var dict = {"year": year, "month": month, "day": day,
				"hour": hour, "minute": minute, "second": second}
	return int(Time.get_unix_time_from_datetime_dict(dict))

## Checks for updates across all installed emulators
## callback(updated: Array, up_to_date: Array, failed: Array)
func check_for_updates(callback: Callable):
	if not SettingsManager:
		callback.call([], [], [])
		return
	
	var version_setting = SettingsManager.get_setting("installed_emulator_versions")
	var installed_versions = {}
	if version_setting:
		installed_versions = version_setting.value as Dictionary
		if installed_versions == null:
			installed_versions = {}
	
	var results = {
		"updated": [],
		"up_to_date": [],
		"failed": [],
		"pending": 0
	}
	
	var all_emulators = get_all_emulators()
	
	for emulator in all_emulators:
		var emulator_id = emulator.get("id", "")
		if emulator_id == "":
			continue
		
		var progress = get_install_progress(emulator_id)
		if progress["status"] != "complete":
			continue
		
		# Find the first download step to determine how to check
		var install_steps = emulator.get("install", [])
		var platform_config = null
		
		for step in install_steps:
			var config = _get_step_platform_config(step)
			if not config.is_empty():
				var action = config.get("action_type", "")
				if action == "download_scrape" or action == "download_repo" or action == "download_url":
					platform_config = config
					break
		
		if not platform_config:
			continue
		
		var action_type = platform_config.get("action_type", "")
		
		# If installed but no version stored, force reinstall to get the actual version
		if not installed_versions.has(emulator_id):
			print("[LaunchManager] Emulator %s installed but no version stored - triggering reinstall" % emulator_id)
			results.updated.append(emulator_id)
			_trigger_emulator_update(emulator_id, emulator.get("name", emulator_id), platform_config)
			continue
		
		var installed_version = installed_versions[emulator_id]
		
		match action_type:
			"download_scrape":
				results.pending += 1
				_check_scrape_update(emulator_id, emulator.get("name", emulator_id), installed_version, platform_config, results, callback)
			"download_repo":
				results.pending += 1
				_check_repo_update(emulator_id, emulator.get("name", emulator_id), installed_version, platform_config, results, callback)
			"download_url":
				# Hardcoded URL - can't check for updates automatically
				results.up_to_date.append(emulator_id)
	
	# If nothing was pending and nothing was auto-updated, call callback immediately
	if results.pending == 0 and results.updated.is_empty():
		callback.call(results.updated, results.up_to_date, results.failed)

## Internal helper to check if all pending checks are done
func _check_updates_complete(results: Dictionary, callback: Callable):
	results.pending -= 1
	if results.pending <= 0:
		callback.call(results.updated, results.up_to_date, results.failed)

## Checks for a scrape-based update
func _check_scrape_update(emulator_id: String, emulator_name: String, installed_version: String, platform_config: Dictionary, results: Dictionary, callback: Callable):
	var scrape_url = platform_config.get("scrape_url", "")
	var version_pattern = platform_config.get("version_pattern", "")
	var url_template = platform_config.get("url_template", "")
	var match_strategy = platform_config.get("match_strategy", "first")
	var json_path = platform_config.get("json_path", "")
	
	if scrape_url == "" or url_template == "":
		results.failed.append(emulator_id)
		_check_updates_complete(results, callback)
		return
	
	# version_pattern is required for HTML scraping, optional for JSON API mode
	if json_path == "" and version_pattern == "":
		results.failed.append(emulator_id)
		_check_updates_complete(results, callback)
		return
	
	NetworkManager.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(_url: String, version: String, error: String):
			if error != "" or version == "":
				results.failed.append(emulator_id)
				_check_updates_complete(results, callback)
				return
			
			var comparison = _compare_versions(installed_version, version)
			if comparison == -1 or comparison == 2:
				# Update available or incomparable (treat as update)
				results.updated.append(emulator_id)
				_trigger_emulator_update(emulator_id, emulator_name, platform_config)
			else:
				results.up_to_date.append(emulator_id)
			
			_check_updates_complete(results, callback),
		match_strategy,
		json_path
	)

## Checks for a repo-based update
func _check_repo_update(emulator_id: String, emulator_name: String, installed_version: String, platform_config: Dictionary, results: Dictionary, callback: Callable):
	var github_repo = platform_config.get("github_repo", "")
	var asset_pattern = platform_config.get("asset_pattern", "")
	var release_tag = platform_config.get("release_tag", "")
	var api_base_url = platform_config.get("api_base_url", "")
	
	if github_repo == "" or asset_pattern == "":
		results.failed.append(emulator_id)
		_check_updates_complete(results, callback)
		return
	
	NetworkManager.fetch_repo_release(
		github_repo,
		asset_pattern,
		func(_url: String, tag: String, error: String, _file_size: int, published_at: String):
			if error != "" or tag == "":
				results.failed.append(emulator_id)
				_check_updates_complete(results, callback)
				return
			
			var update_available = false
			
			# Primary: use published_at date if available (more reliable for repos)
			if published_at != "":
				var remote_date = _parse_iso_date(published_at)
				var installed_date = _parse_iso_date(installed_version)
				
				if remote_date > 0 and installed_date > 0:
					# Both are dates - compare directly
					if remote_date > installed_date:
						update_available = true
						print("[LaunchManager] Update available for " + emulator_id + ": " + published_at + " > " + installed_version)
					else:
						print("[LaunchManager] " + emulator_id + " is up to date: " + installed_version)
				else:
					# Installed version is not a date (legacy format), assume update needed
					print("[LaunchManager] " + emulator_id + " has legacy version format, triggering update")
					update_available = true
			else:
				# Fallback: version string comparison when no date available
				var comparison = _compare_versions(installed_version, tag)
				
				if comparison == -1:
					# Remote version is newer
					update_available = true
					print("[LaunchManager] Update available for " + emulator_id + ": " + tag + " > " + installed_version)
				elif comparison == 0 or comparison == 1:
					# Same version or installed is newer
					print("[LaunchManager] " + emulator_id + " is up to date: " + installed_version)
				elif comparison == 2:
					# Versions are incomparable - assume update needed to be safe
					print("[LaunchManager] " + emulator_id + " versions incomparable ('" + installed_version + "' vs '" + tag + "'), assuming update needed")
					update_available = true
			
			if update_available:
				results.updated.append(emulator_id)
				_trigger_emulator_update(emulator_id, emulator_name, platform_config)
			else:
				results.up_to_date.append(emulator_id)
			
			_check_updates_complete(results, callback),
		release_tag,
		api_base_url
	)

## Triggers re-installation of an emulator for update
func _trigger_emulator_update(emulator_id: String, _emulator_name: String, _platform_config: Dictionary):
	print("[LaunchManager] Triggering update for: " + emulator_id)
	
	# Clear install progress to force fresh install
	_emulator_install_progress.erase(emulator_id)
	
	# Clear stored version so the first download step can save the new version
	_clear_emulator_version(emulator_id)
	
	# Start installation from step 0
	_execute_install_step(emulator_id, 0)

## Helper function for create_folders action
func _handle_create_folders_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var folders = platform_config.get("folders", [])
	if folders.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	for folder_path in folders:
		# Resolve path using universal resolver
		var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
		
		if not FSM.make_dir_recursive(full_path):
			push_error("[LaunchManager] Failed to create folder: " + full_path)
			return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for create_files action
func _handle_create_files_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var files = platform_config.get("files", [])
	if files.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	# Get the emulator directory path for placeholder resolution
	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var global_emulator_dir = FSM.resolve_path(emulator_dir, {"format": FSM.PathFormat.ABSOLUTE})
	
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
		
		var full_path = FSM.resolve_emulator_path(file_name, emulator_id)
		
		# Resolve placeholders in content
		file_content = file_content.replace("{emulator_dir}", global_emulator_dir)
		
		# Resolve {games_dir} placeholder
		var games_folder_setting = SettingsManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value.rstrip("/") if games_folder_setting else "user://roms"
		file_content = file_content.replace("{games_dir}", games_dir)
		
		if not FSM.file_exists(full_path):
			if not FSM.write_file(full_path, file_content):
				push_error("[LaunchManager] Failed to create file: " + full_path)
				return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for creating PCSX2 folder memory card superblock
func _handle_create_pcsx2_superblock_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var path = platform_config.get("path", "")
	if path == "":
		push_error("[LaunchManager] No path specified for create_pcsx2_superblock step: " + step_name)
		return false

	# Use the configured save directory as the base path, which properly resolves
	# to app_data on Android and emulator_dir on desktop
	var save_dir = SaveManager.resolve_default_save_directory(emulator_id, "ps2")
	if save_dir == "":
		push_error("[LaunchManager] No save directory configured for " + emulator_id)
		return false
	
	# The save directory already includes the memcards path from the emulator config,
	# so we use it directly without appending the step path again
	var memcard_path = save_dir.rstrip("/")
	
	var success = SaveManager.create_pcsx2_superblock(memcard_path)
	if not success:
		push_error("[LaunchManager] Failed to create PCSX2 superblock at: " + memcard_path)
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Apply a set of text replacements to an emulator-relative config file.
## Each edit is a Dictionary with "old" and "new". Set "regex": true to treat
## "old" as a RegEx pattern. If create_if_missing is true, the file is created
## when it doesn't exist.
func edit_emulator_file(emulator_id: String, file_path: String, edits: Array, create_if_missing := false) -> bool:
	if emulator_id == "" or file_path == "" or edits.is_empty():
		push_error("[LaunchManager] Invalid arguments for edit_emulator_file")
		return false
	
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[LaunchManager] Could not resolve emulator path: " + file_path)
		return false
	
	if not FSM.file_exists(full_path):
		if create_if_missing:
			if not FSM.write_file(full_path, ""):
				push_error("[LaunchManager] Failed to create file: " + full_path)
				return false
		else:
			push_error("[LaunchManager] File not found for editing: " + full_path)
			return false
	
	var content := FSM.read_file(full_path)
	# Empty content is allowed so missing keys can be appended later.
	
	for edit in edits:
		var old_text: String = edit.get("old", "")
		var new_text: String = edit.get("new", "")
		
		if old_text == "":
			continue
		
		if edit.get("regex", false):
			var regex := RegEx.new()
			var err := regex.compile(old_text)
			if err != OK:
				push_error("[LaunchManager] Invalid regex in edit: " + old_text)
				continue
			content = regex.sub(content, new_text, true)
		else:
			content = content.replace(old_text, new_text)
	
	if not FSM.write_file(full_path, content):
		push_error("[LaunchManager] Failed to write edited file: " + full_path)
		return false
	
	return true


## Helper function for edit_file action
func _handle_edit_file_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var file_path = platform_config.get("file", "")
	var edits = platform_config.get("edits", [])
	
	if file_path == "" or edits.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	if not edit_emulator_file(emulator_id, file_path, edits, false):
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for none action (skip)
func _handle_none_step(emulator_id: String, _step_name: String, step_index: int) -> bool:
	return _execute_install_step(emulator_id, step_index + 1)

## Creates the save directory for an emulator if it doesn't exist
## Called automatically at the end of successful install flow
## For multi-platform emulators (e.g., RetroArch), creates directories for all supported platforms
func _create_emulator_save_directory(emulator_id: String) -> void:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return
	
	var platforms = emulator.get("meta", {}).get("platforms", [])
	
	# For single-platform emulators, just create the base directory
	if platforms.size() == 1:
		var save_dir = SaveManager.resolve_default_save_directory(emulator_id)
		if save_dir == "":
			print("[LaunchManager] No save directory configured for: " + emulator_id)
			return
		
		if FSM.dir_exists(save_dir):
			print("[LaunchManager] Save directory already exists for " + emulator_id + ": " + save_dir)
			return
		
		print("[LaunchManager] Creating save directory for " + emulator_id + ": " + save_dir)
		var success = FSM.make_dir_recursive(save_dir)
		if not success:
			push_error("[LaunchManager] Failed to create save directory for " + emulator_id + ": " + save_dir)
		else:
			print("[LaunchManager] Successfully created save directory for " + emulator_id)
	else:
		# Multi-platform emulator: create save directories for each platform
		print("[LaunchManager] Creating save directories for multi-platform emulator: " + emulator_id)
		for platform in platforms:
			var save_dir = SaveManager.resolve_default_save_directory(emulator_id, platform)
			if save_dir == "":
				continue
			
			if FSM.dir_exists(save_dir):
				continue
			
			print("[LaunchManager] Creating save directory for " + emulator_id + " / " + platform + ": " + save_dir)
			var success = FSM.make_dir_recursive(save_dir)
			if not success:
				push_error("[LaunchManager] Failed to create save directory for " + emulator_id + " / " + platform + ": " + save_dir)
			else:
				print("[LaunchManager] Successfully created save directory for " + emulator_id + " / " + platform)

## Executes install steps from new step-based format (entry point)
func _execute_install_steps(emulator_id: String, _emulator: Dictionary, _install_steps: Array) -> bool:
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
func _queue_emulator_download(emulator_id: String, _emulator_name: String, step_display_name: String, download_url: String, step_index: int, step_config: Dictionary = {}, file_size: int = 0):
	# Use explicit filename from config if provided, otherwise extract from URL
	var filename = step_config.get("filename", "")
	if filename == "":
		filename = download_url.get_file()
	
	# Check for custom destination path (for firmware/shared files)
	var custom_destination = step_config.get("destination", "")
	var destination_path: String
	if custom_destination != "":
		FSM.make_dir_recursive(custom_destination)
		destination_path = FSM.join_paths(custom_destination, filename)
	else:
		destination_path = FSM.join_paths(_get_emulator_directory(emulator_id), filename)
	
	print("[LaunchManager] Queueing download for " + emulator_id + ": " + filename + " -> " + destination_path)
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Queue download WITHOUT auto-extract (extract is now a separate step)
	var item_id = DownloadManager.queue_download(
		download_url,
		destination_path,
		"emulator",
		step_display_name,  # Use step-specific display name for notifications
		false,  # auto_extract = false
		"",  # extract_to = empty, we'll handle extraction separately
		null,  # game
		{},  # callbacks
		0,  # romm_id
		true,  # delete_after_extract
		false,  # suppress_notification
		file_size  # expected_file_size from GitHub API
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

## Gets the active download item for an emulator (if any)
## Returns the DownloadManager.QueueItem or null
func get_emulator_active_download(emulator_id: String):
	for item_id in _pending_emulator_downloads:
		var task = _pending_emulator_downloads[item_id]
		if task.emulator_id == emulator_id:
			for item in DownloadManager.get_active():
				if item.id == item_id:
					return item
	return null

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
		
		# For batch downloads, let the callback handle progress tracking and step advancement
		# The callback only advances when ALL items in the batch are complete
		if task_info.get("context", "") == "batch_download":
			task_info.callback.call(true, "")
			return
		
		# For non-batch downloads, proceed to next step
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
func _store_file_path(game: GameResource, file_path: String) -> void:
	print("[LaunchManager] _store_file_path: current=" + game.file_path + " new=" + file_path)
	if game.file_path != file_path:
		game.file_path = file_path
		DataManager.update_game(game)
		print("[LaunchManager] _store_file_path: UPDATED and persisted to DB")
	else:
		print("[LaunchManager] _store_file_path: path already correct, no update needed")

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
		temp_intent.rom_path = FSM.join_paths(root_path, game.platform_slug, game.get_active_file_name())
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
		"rpcs3":
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
	if game.get_active_title_id() != "":
		return true
	print("[LaunchManager] Azahar: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = TitleIDParser.extract_3ds_title_id(rom_path)
	if title_id == "":
		push_error("[LaunchManager] Azahar: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract 3DS game TitleID", NotificationManager.Type.ERROR)
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
	if game.get_active_title_id() != "":
		return true
	print("[LaunchManager] Cemu: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = TitleIDParser.extract_wiiu_title_id(rom_path)
	if title_id == "":
		push_error("[LaunchManager] Cemu: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract Wii U game TitleID", NotificationManager.Type.ERROR)
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
	if game.get_active_title_id() != "":
		return true
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
		NotificationManager.show_notification("Failed to extract Switch game TitleID", NotificationManager.Type.ERROR)
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
	if game.get_active_title_id() != "":
		return true
	print("[LaunchManager] Dolphin: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var game_id = TitleIDParser.extract_gamecube_game_id(rom_path)
	
	if game_id == "":
		print("[LaunchManager] Dolphin: Could not extract Game ID from ROM, trying existing saves...")
		var emulator_dir = LaunchManager._get_emulator_directory("dolphin")
		game_id = TitleIDParser.extract_gamecube_game_id_from_existing_saves(emulator_dir)
	
	if game_id == "":
		push_error("[LaunchManager] Dolphin: Failed to extract Game ID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract GameCube/Wii game ID", NotificationManager.Type.ERROR)
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
	if game.get_active_title_id() != "":
		return true
	print("[LaunchManager] Xenia: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = TitleIDParser.extract_xbox360_title_id(rom_path)
	if title_id == "":
		push_error("[LaunchManager] Xenia: Failed to extract TitleID from: " + rom_path)
		NotificationManager.show_notification("Failed to extract Xbox 360 game TitleID", NotificationManager.Type.ERROR)
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
	if game.get_active_title_id() != "":
		return true
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
		NotificationManager.show_notification("Failed to extract PS2 game serial", NotificationManager.Type.ERROR)
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
	if game.get_active_title_id() != "":
		return true
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
		NotificationManager.show_notification("Failed to extract PSP game ID", NotificationManager.Type.ERROR)
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
		# Path is a real filesystem path
		emulator_dir = get_app_data_path("vita3k") + "/vita"
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
		NotificationManager.show_notification("Failed to extract Vita game TitleID", NotificationManager.Type.ERROR)
		return false
	print("[LaunchManager] Vita3K: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	print("[LaunchManager] Vita3K: active_title_id from DB = '" + active_title_id + "', zip_title_id = '" + zip_title_id + "'")
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[LaunchManager] Vita3K: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[LaunchManager] Vita3K: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[LaunchManager] Vita3K: Updated database with TitleID: " + zip_title_id)
	else:
		print("[LaunchManager] Vita3K: TitleID already matches, skipping DB update")
	
	var title_id = game.get_active_title_id()
	print("[LaunchManager] Vita3K: Using TitleID: " + title_id)
	
	# Platform-specific Vita3K app path
	var vita_app_path: String
	if PlatformManager.is_android():
		vita_app_path = get_app_data_path("vita3k") + "/vita/ux0/app/" + title_id
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
		NotificationManager.Type.INFO,
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
	# Use FileSystemManager to list files
	var files = FSM.list_dir(vita_app_path)
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
	
	var parent_dir = extract_to.get_base_dir()
	print("[LaunchManager] Vita3K: Creating parent directory: " + parent_dir)
	if not FSM.make_dir_recursive(parent_dir):
		push_error("[LaunchManager] Failed to create Vita3K app directory: " + parent_dir)
		print("[LaunchManager] _extract_vita_zip: EXIT false (mkdir failed)")
		return false
	
	# Use DownloadManager's extraction for progress tracking.
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
			var full_path := FSM.join_paths(search_dir, file_name)
			
			# Check if this is the PARAM.SFO file we're looking for
			if file_name == "PARAM.SFO" and FSM.file_exists(full_path):
				dir.list_dir_end()
				return full_path
			
			# If it's a directory, search recursively
			if FSM.dir_exists(full_path):
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
	if not FSM.make_dir_recursive(dest_dir):
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
			var source_path := FSM.join_paths(source_dir, file_name)
			var dest_path := FSM.join_paths(dest_dir, file_name)
			
			if FSM.dir_exists(source_path):
				# Recursively copy subdirectory
				if not _copy_dir_recursive(source_path, dest_path):
					success = false
					break
			else:
				# Copy file
				if not FSM.copy_file(source_path, dest_path):
					push_error("[LaunchManager] RPCS3: Failed to copy file: " + source_path + " to " + dest_path)
					success = false
					break
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return success


## Checks whether the given RPCS3 game path contains actual game files
func _rpcs3_game_has_files(game_path: String) -> bool:
	if not FSM.dir_exists(game_path):
		return false
	var files = FSM.list_dir(game_path)
	var actual_files = 0
	for f in files:
		if f != "." and f != "..":
			actual_files += 1
	print("[LaunchManager] RPCS3: _rpcs3_game_has_files: found " + str(actual_files) + " actual files in " + game_path)
	return actual_files > 0


## Prepares a PS3 game for launch by extracting ZIP to a folder next to the ZIP
## The extracted folder path is passed to aPS3e via the game_dir intent extra
## Works on both desktop and Android
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
	
	# Handle case where game.file_path points to previously-extracted folder
	# (from older versions or if user deleted files and we need to re-extract)
	var zip_path := rom_path
	
	if FSM.dir_exists(rom_path):
		# This might be an extracted folder. Check if it has actual game files.
		if _ps3_game_has_files(rom_path):
			print("[LaunchManager] RPCS3: ROM path is extracted folder with valid game files")
			
			# First, try to get TitleID from existing PARAM.SFO in the extracted folder
			# This is more reliable than searching for ZIPs when multiple games share a folder
			var sfo_path = _find_param_sfo_recursive(rom_path)
			if sfo_path != "":
				var sfo_bytes = FSM.read_file_bytes(sfo_path)
				if not sfo_bytes.is_empty():
					var title_id_from_sfo = TitleIDParser.get_title_id_from_sfo_bytes(sfo_bytes)
					if title_id_from_sfo != "":
						print("[LaunchManager] RPCS3: Got TitleID from PARAM.SFO: " + title_id_from_sfo)
						
						# Verify this matches the folder name or update if needed
						var folder_name = rom_path.get_file()
						if folder_name != title_id_from_sfo and folder_name.to_upper() == folder_name:
							# Folder is named after TitleID, all good
							pass
						
						# Update intent and game file_path
						intent.rom_path = rom_path
						_store_file_path(game, rom_path)
						
						# Also update title_id if it's different
						if game.get_active_title_id() != title_id_from_sfo:
							_store_title_id(game, title_id_from_sfo)
						
						return true
			
			# Fallback: find the original ZIP
			# This handles cases where we can't read PARAM.SFO
			print("[LaunchManager] RPCS3: Could not get TitleID from PARAM.SFO, searching for ZIP...")
			
			# On desktop, the extracted folder might be in the emulator directory
			# but the ZIP is in the games library. Check both.
			var search_dirs = [rom_path.get_base_dir()]
			if not PlatformManager.is_android():
				var root_folder = SettingsManager.get_setting("games_root_folder")
				var root_path = root_folder.value if root_folder else "user://roms/"
				var library_dir = FSM.join_paths(root_path, game.platform_slug)
				if library_dir != search_dirs[0]:
					search_dirs.append(library_dir)
			
			var all_zip_files: Array[String] = []
			for search_dir in search_dirs:
				var zip_files = _find_zip_files_in_dir(search_dir)
				for zf in zip_files:
					if not zf in all_zip_files:
						all_zip_files.append(zf)
			
			# Try to find the ZIP that matches this game by name
			var game_name = game.get_display_name().to_lower()
			var matching_zip = ""
			for zf in all_zip_files:
				if zf.to_lower().contains(game_name) or game_name.contains(zf.get_file().get_basename().to_lower()):
					matching_zip = zf
					break
			
			if matching_zip != "":
				zip_path = matching_zip
				print("[LaunchManager] RPCS3: Found matching ZIP by game name: " + zip_path)
			elif all_zip_files.size() > 0:
				# Fallback to first ZIP (old behavior, but warn about it)
				zip_path = all_zip_files[0]
				push_warning("[LaunchManager] RPCS3: Multiple ZIPs found, using first one: " + zip_path + " for game: " + game.get_display_name())
			else:
				push_error("[LaunchManager] RPCS3: No ZIP found to verify TitleID")
				NotificationManager.show_notification("Game files missing - please re-download", NotificationManager.Type.ERROR)
				return false
		else:
			# Directory exists but is empty - files were deleted. Look for ZIP.
			print("[LaunchManager] RPCS3: Extracted folder is empty, looking for original ZIP...")
			var parent_dir = rom_path.get_base_dir()
			var zip_files = _find_zip_files_in_dir(parent_dir)
			if zip_files.size() > 0:
				zip_path = zip_files[0]
				print("[LaunchManager] RPCS3: Found original ZIP in parent dir: " + zip_path)
			else:
				# On desktop, the extracted folder might be in the emulator directory
				# but the ZIP is in the games library. Check the library folder.
				if not PlatformManager.is_android():
					var root_folder = SettingsManager.get_setting("games_root_folder")
					var root_path = root_folder.value if root_folder else "user://roms/"
					var library_dir = FSM.join_paths(root_path, game.platform_slug)
					print("[LaunchManager] RPCS3: Checking games library: " + library_dir)
					zip_files = _find_zip_files_in_dir(library_dir)
					if zip_files.size() > 0:
						zip_path = zip_files[0]
						print("[LaunchManager] RPCS3: Found original ZIP in library: " + zip_path)
				
				if zip_path == "":
					push_error("[LaunchManager] RPCS3: No ZIP found to re-extract in: " + parent_dir)
					NotificationManager.show_notification("Game files missing - please re-download", NotificationManager.Type.ERROR)
					return false
	elif not FSM.file_exists(rom_path):
		# Path doesn't exist at all (deleted extracted folder). Look for ZIP in parent.
		print("[LaunchManager] RPCS3: ROM path does not exist, looking for original ZIP...")
		
		# First try the parent directory of the deleted folder
		var parent_dir = rom_path.get_base_dir()
		var zip_files = _find_zip_files_in_dir(parent_dir)
		if zip_files.size() > 0:
			zip_path = zip_files[0]
			print("[LaunchManager] RPCS3: Found original ZIP in parent dir: " + zip_path)
		else:
			# On desktop, the extracted folder might be in the emulator directory
			# but the ZIP is in the games library. Check the library folder.
			if not PlatformManager.is_android():
				var root_folder = SettingsManager.get_setting("games_root_folder")
				var root_path = root_folder.value if root_folder else "user://roms/"
				var library_dir = FSM.join_paths(root_path, game.platform_slug)
				print("[LaunchManager] RPCS3: Checking games library: " + library_dir)
				zip_files = _find_zip_files_in_dir(library_dir)
				if zip_files.size() > 0:
					zip_path = zip_files[0]
					print("[LaunchManager] RPCS3: Found original ZIP in library: " + zip_path)
			
			if zip_path == "":
				push_error("[LaunchManager] RPCS3: No ZIP found to re-extract in: " + parent_dir)
				NotificationManager.show_notification("Game files missing - please re-download", NotificationManager.Type.ERROR)
				return false
	
	# Step 1: Extract TitleID from ZIP
	print("[LaunchManager] RPCS3: Extracting TitleID from ZIP: " + zip_path)
	var zip_title_id = TitleIDParser.extract_ps3_title_id(zip_path)
	if zip_title_id == "":
		push_error("[LaunchManager] RPCS3: Failed to extract TitleID from: " + zip_path)
		NotificationManager.show_notification("Failed to extract PS3 game TitleID", NotificationManager.Type.ERROR)
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
	
	# On desktop, determine the correct RPCS3 directory
	var rpcs3_install_dir := ""
	var desktop_disc_path := ""
	var desktop_digital_path := ""
	if not PlatformManager.is_android():
		var emulator_install_path = get_emulator_install_path(intent.emulator_id)
		if emulator_install_path != "":
			rpcs3_install_dir = emulator_install_path.get_base_dir()
			desktop_disc_path = FSM.join_paths(rpcs3_install_dir, "games", title_id)
			desktop_digital_path = FSM.join_paths(rpcs3_install_dir, "dev_hdd0", "game", title_id)
			print("[LaunchManager] RPCS3: Desktop disc path: " + desktop_disc_path)
			print("[LaunchManager] RPCS3: Desktop digital path: " + desktop_digital_path)
	
	# Step 2: Determine final extraction path (next to the ZIP)
	var rom_parent_dir = zip_path.get_base_dir()
	var extract_path = FSM.join_paths(rom_parent_dir, title_id)
	print("[LaunchManager] RPCS3: Extraction path: " + extract_path)
	
	# Step 3: Check if already extracted
	# On desktop, check RPCS3 directories first
	if not PlatformManager.is_android():
		if _ps3_game_has_files(desktop_disc_path):
			print("[LaunchManager] RPCS3: Game already extracted at disc path: " + desktop_disc_path)
			intent.rom_path = desktop_disc_path
			_store_file_path(game, desktop_disc_path)
			return true
		elif _ps3_game_has_files(desktop_digital_path):
			print("[LaunchManager] RPCS3: Game already extracted at digital path: " + desktop_digital_path)
			intent.rom_path = desktop_digital_path
			_store_file_path(game, desktop_digital_path)
			return true
	
	if _ps3_game_has_files(extract_path):
		print("[LaunchManager] RPCS3: Game already extracted at: " + extract_path)
		# Update intent and game to point to extracted folder
		intent.rom_path = extract_path
		print("[LaunchManager] RPCS3: Calling _store_file_path with extract_path=" + extract_path)
		_store_file_path(game, extract_path)
		print("[LaunchManager] RPCS3: After _store_file_path, game.file_path=" + game.file_path)
		return true
	
	print("[LaunchManager] RPCS3: Game not extracted, will extract to: " + extract_path)
	
	# Step 4: Extract ZIP
	var rpcs3_notify_id = NotificationManager.show_notification(
		"Extracting " + game.get_display_name() + "...",
		NotificationManager.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true
	)
	
	# Determine extraction target
	var extract_target: String
	var is_desktop = not PlatformManager.is_android() and rpcs3_install_dir != ""
	if is_desktop:
		# On desktop, extract directly to RPCS3 directory.
		# We default to disc path; if the game is digital format we'll handle it after extraction.
		extract_target = desktop_disc_path
		print("[LaunchManager] RPCS3: Desktop - extracting directly to: " + extract_target)
	else:
		# On Android, extract to temp first (same drive, no permission issues)
		extract_target = extract_path + "_tmp"
		print("[LaunchManager] RPCS3: Android - extracting to temp: " + extract_target)
	
	var extract_success := await _extract_ps3_zip(zip_path, extract_target)
	
	# Dismiss the extraction notification
	NotificationManager.dismiss_notification(rpcs3_notify_id)
	
	print("[LaunchManager] RPCS3: Extraction returned: " + str(extract_success))
	
	if not extract_success:
		push_error("[LaunchManager] RPCS3: Failed to extract PS3 game ZIP: " + zip_path)
		return false
	
	# Step 5: Find PARAM.SFO and determine format
	var sfo_path = FSM.find_file_recursive(extract_target, "PARAM.SFO")
	if sfo_path == "":
		sfo_path = FSM.find_file_recursive(extract_target, "PARAM.sfo")
	
	if sfo_path == "":
		push_error("[LaunchManager] RPCS3: PARAM.SFO not found after extraction at: " + extract_target)
		FSM.delete_dir_recursive(extract_target)
		return false
	
	print("[LaunchManager] RPCS3: Found PARAM.SFO at: " + sfo_path)
	var sfo_dir = sfo_path.get_base_dir()
	
	# Determine if disc or digital format
	var is_disc_format = sfo_dir.get_file().to_upper() == "PS3_GAME"
	print("[LaunchManager] RPCS3: Format detected: " + ("disc" if is_disc_format else "digital"))
	
	# Determine final path
	var final_extract_path = extract_path
	if is_desktop:
		final_extract_path = desktop_disc_path if is_disc_format else desktop_digital_path
		print("[LaunchManager] RPCS3: Desktop final path: " + final_extract_path)
	
	# Step 6: Handle wrapper folder (e.g., "Soulcalibur IV/PS3_GAME/" -> "PS3_GAME/")
	var game_root = sfo_dir.get_base_dir() if is_disc_format else sfo_dir
	if is_desktop and game_root != final_extract_path:
		print("[LaunchManager] RPCS3: Wrapper folder detected: " + game_root.get_file())
		print("[LaunchManager] RPCS3: Unwrapping to: " + final_extract_path)
		
		# Move contents of wrapper folder up to final_extract_path
		var items = FSM.list_dir(game_root)
		for item in items:
			if item == "." or item == "..":
				continue
			var source = FSM.join_paths(game_root, item)
			var dest = FSM.join_paths(final_extract_path, item)
			if not FSM.move(source, dest):
				push_error("[LaunchManager] RPCS3: Failed to unwrap: " + source + " -> " + dest)
				return false
		
		# Try to delete empty wrapper folder (may fail on Windows due to permissions, that's OK)
		FSM.delete_dir_recursive(game_root)
		print("[LaunchManager] RPCS3: Unwrapped successfully")
	elif not is_desktop:
		# Android: move from temp to final
		print("[LaunchManager] RPCS3: Moving game files from " + game_root + " to " + final_extract_path)
		if not FSM.move_dir_contents(game_root, final_extract_path):
			push_error("[LaunchManager] RPCS3: Failed to move game files to " + final_extract_path)
			FSM.delete_dir_recursive(extract_target)
			return false
		FSM.delete_dir_recursive(extract_target)
	
	# Step 7: Verify extracted files
	if not _ps3_game_has_files(final_extract_path):
		push_error("[LaunchManager] RPCS3: Game files missing after extraction at: " + final_extract_path)
		NotificationManager.show_notification("Failed to install PS3 game - files missing", NotificationManager.Type.ERROR)
		return false
	
	# Step 8: Update intent to point to extracted folder
	intent.rom_path = final_extract_path
	
	# Also update game.file_path so create_launch_intent() picks up the extracted folder
	_store_file_path(game, final_extract_path)
	print("[LaunchManager] RPCS3: Updated game.file_path to: " + final_extract_path)
	
	print("[LaunchManager] RPCS3: Game extracted successfully at: " + final_extract_path)
	return true


## Checks if a PS3 game directory has a valid game structure
## Validates by looking for PARAM.SFO, which is required for both disc and HDD formats
func _ps3_game_has_files(game_path: String) -> bool:
	if not FSM.dir_exists(game_path):
		return false
	
	# Look for PARAM.SFO - the definitive marker of a valid PS3 game
	var sfo_path = FSM.find_file_recursive(game_path, "PARAM.SFO")
	if sfo_path == "":
		# Try lowercase fallback
		sfo_path = FSM.find_file_recursive(game_path, "PARAM.sfo")
	
	var has_sfo = sfo_path != ""
	print("[LaunchManager] RPCS3: _ps3_game_has_files: PARAM.SFO found=" + str(has_sfo) + " in " + game_path)
	return has_sfo


## Finds ZIP files in a directory (for re-extraction when extracted files are deleted)
func _find_zip_files_in_dir(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	if not FSM.dir_exists(dir_path):
		return result
	
	var dir = DirAccess.open(dir_path)
	if not dir:
		return result
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = FSM.join_paths(dir_path, file_name)
			if not FSM.is_dir(full_path) and file_name.to_lower().ends_with(".zip"):
				result.append(full_path)
		file_name = dir.get_next()
	
	print("[LaunchManager] RPCS3: _find_zip_files_in_dir: found " + str(result.size()) + " ZIP files in " + dir_path)
	return result


## Extracts a PS3 game ZIP file to the specified directory
func _extract_ps3_zip(zip_path: String, extract_to: String) -> bool:
	print("[LaunchManager] RPCS3: Extracting ZIP: " + zip_path + " to: " + extract_to)
	
	# Create extraction directory
	if not FSM.dir_exists(extract_to):
		FSM.make_dir_recursive(extract_to)
	
	# Use DownloadManager's extraction functionality
	var item_id: String = DownloadManager.queue_extraction(zip_path, extract_to, "ps3_game", "Extracting PS3 Game", false)
	
	if item_id == "":
		push_error("[LaunchManager] RPCS3: Failed to queue extraction")
		return false
	
	print("[LaunchManager] RPCS3: Waiting for extraction to complete...")
	
	# Use a completion tracker object
	var completion_tracker := {"complete": false, "success": false}
	
	var on_complete = func(completed_item_id: String, success: bool, _message: String):
		if completed_item_id == item_id:
			completion_tracker.complete = true
			completion_tracker.success = success
			print("[LaunchManager] RPCS3: Extraction callback - success=" + str(success))
	
	DownloadManager.extraction_completed.connect(on_complete)
	
	# Wait for extraction to complete (30 min timeout for large games)
	var timeout_frames = 0
	var max_timeout_frames = 30 * 60 * 60  # 30 minutes at 60fps
	while not completion_tracker.complete:
		await get_tree().process_frame
		timeout_frames += 1
		if timeout_frames > max_timeout_frames:
			push_error("[LaunchManager] RPCS3: Extraction timed out after 30 minutes")
			DownloadManager.extraction_completed.disconnect(on_complete)
			return false

	DownloadManager.extraction_completed.disconnect(on_complete)

	print("[LaunchManager] RPCS3: Extraction complete, success=" + str(completion_tracker.success))
	return completion_tracker.success


## Prepares a PS4 game for launch by extracting the TitleID and extracting game files
## PS4 games are ZIP files containing a CUSAxxxxx directory at the root
## Returns true if preparation succeeded, false on error
func _prepare_shadps4_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
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
		NotificationManager.show_notification("Failed to extract PS4 game TitleID", NotificationManager.Type.ERROR)
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
	var extract_path = FSM.join_paths(rom_parent_dir, title_id)
	print("[LaunchManager] shadPS4: Extraction path: " + extract_path)
	
	# Step 3: Check if already extracted
	if _shadps4_game_has_files(extract_path):
		print("[LaunchManager] shadPS4: Game already extracted at: " + extract_path)
		return true
	
	print("[LaunchManager] shadPS4: Game not extracted, will extract to: " + extract_path)
	
	# Step 4: Create extraction directory
	if not FSM.dir_exists(extract_path):
		print("[LaunchManager] shadPS4: Creating extraction directory: " + extract_path)
		if not FSM.make_dir_recursive(extract_path):
			push_error("[LaunchManager] shadPS4: Failed to create extraction directory: " + extract_path)
			return false
	
	# Step 5: Extract ZIP to extraction path
	var shadps4_notify_id = NotificationManager.show_notification(
		"Extracting " + game.get_display_name() + "...",
		NotificationManager.Type.INFO,
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
	if not FSM.dir_exists(game_path):
		return false
	
	var entries = FSM.list_dir(game_path)
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
	var item_id: String = DownloadManager.queue_extraction(zip_path, extract_to, "ps4_game", "Extracting PS4 Game", false)
	
	if item_id == "":
		push_error("[LaunchManager] shadPS4: Failed to queue extraction")
		return false
	
	print("[LaunchManager] shadPS4: Waiting for extraction to complete (no timeout)...")
	
	# Use a completion tracker object
	var completion_tracker := {"complete": false, "success": false}
	
	var on_complete = func(completed_item_id: String, success: bool, _message: String):
		if completed_item_id == item_id:
			completion_tracker.complete = true
			completion_tracker.success = success
			print("[LaunchManager] shadPS4: Extraction callback - success=" + str(success))
	
	DownloadManager.extraction_completed.connect(on_complete)
	
	# Wait for extraction to complete (30 min timeout for large games)
	var timeout_frames = 0
	var max_timeout_frames = 30 * 60 * 60  # 30 minutes at 60fps
	while not completion_tracker.complete:
		await get_tree().process_frame
		timeout_frames += 1
		if timeout_frames > max_timeout_frames:
			push_error("[LaunchManager] shadPS4: Extraction timed out after 30 minutes")
			DownloadManager.extraction_completed.disconnect(on_complete)
			return false

	DownloadManager.extraction_completed.disconnect(on_complete)

	print("[LaunchManager] shadPS4: Extraction wait loop ended")
	print("[LaunchManager] shadPS4: completion_tracker.complete=" + str(completion_tracker.complete) + ", completion_tracker.success=" + str(completion_tracker.success))

	if not completion_tracker.complete:
		push_error("[LaunchManager] shadPS4: Extraction callback never fired")
		return false
	
	print("[LaunchManager] shadPS4: _extract_shadps4_zip returning: " + str(completion_tracker.success))
	return completion_tracker.success

## Shows a reminder dialog on Android after APK installation
## Prompts the user to open the newly installed emulator and grant permissions
func _show_android_permissions_reminder(emulator_id: String) -> void:
	# Only show on Android
	if PlatformManager.get_platform_name().to_lower() != "android":
		return
	
	var emulator = get_emulator(emulator_id)
	var emulator_name = emulator.get("name", emulator_id)
	
	# Create M3Dialog reminder as a distinct overlay type so it stacks above the settings dialog
	var dialog = M3Dialog.new()
	dialog.overlay_type = "alert"
	dialog.overlay_layer = 95
	dialog.title_text = "Installation Reminder"
	dialog.body_text = "Please open " + emulator_name + " from your app drawer and grant any requested permissions (especially storage access) before launching games."
	dialog.dismissible = false
	dialog.add_action("Got it", func(): dialog.dismiss(), true)
	
	# Show directly (not via M3Dialog.show_dialog which would force overlay_type back to "dialog")
	var parent = M3Overlay.get_overlay_parent()
	if parent and dialog.get_parent() == null:
		parent.add_child(dialog)
	dialog.show_overlay()
	
	print("[LaunchManager] Shown Android permissions reminder for: " + emulator_name)
