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

## Gets the full path to an emulator's directory
## Handles path separators correctly for all platforms
func _get_emulator_directory(emulator_id: String) -> String:
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

# Signals
signal emulator_registry_loaded(success: bool)
signal launch_completed(success: bool, message: String)
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_completed(emulator_id: String, success: bool)
signal game_launched(game: GameResource)  # Emitted when a game is successfully launched

func _ready():
	_load_registry()
	_ensure_emulators_directory()
	
	# Connect to DownloadManager signals
	DownloadManager.extraction_completed.connect(_on_download_manager_extraction_completed)
	DownloadManager.download_completed.connect(_on_unified_download_completed)
	
	# Scan existing installations to detect partial installs
	# Wait a frame to ensure everything is initialized
	await get_tree().process_frame

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
## Registry-based validation handles actual installation checking
func _on_download_manager_extraction_completed(item_id: String, success: bool, extract_dir: String):
	# Check if this extraction has a pending callback (registry step tracking)
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		_pending_emulator_downloads.erase(item_id)
		
		if task_info.has("callback"):
			task_info.callback.call(success, "")
			return
	
	# Find which emulator this extraction belongs to (fallback for non-registry extractions)
	for emulator_id in _emulator_install_progress.keys():
		if extract_dir.begins_with(_get_emulator_directory(emulator_id).rstrip("/")):
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
	# Android uses absolute paths, Desktop uses relative paths
	var extract_path: String
	if PlatformManager.is_android():
		extract_path = extract_to
	else:
		extract_path = _get_emulator_directory(emulator_id).rstrip("/") + "/" + extract_to
	
	var dir = DirAccess.open(extract_path)
	if not dir:
		return
	

	
	# If a specific target folder is specified, flatten only that one
	if target_folder != "":
		var target_path = extract_path + "/" + target_folder
		
		if not dir.dir_exists(target_folder):
			return
		
		var subdir = DirAccess.open(target_path)
		if not subdir:
			return
		
		# Move all contents from the subdirectory to the parent
		subdir.list_dir_begin()
		var item_name = subdir.get_next()
		while item_name != "":
			if item_name != "." and item_name != "..":
				var source_path = target_path + "/" + item_name
				var dest_path = extract_path + "/" + item_name
				
				# Check if destination already exists
				if dir.file_exists(item_name) or dir.dir_exists(item_name):
					pass
				else:
					var error = dir.rename(source_path, dest_path)
					if error != OK:
						pass
			
			item_name = subdir.get_next()
		subdir.list_dir_end()
		
		# Remove the now-empty subdirectory
		var remove_error = subdir.remove(target_path)
		return
	
	# No target folder specified, use original logic (single directory only)
	# List all entries in the extract directory
	var entries = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			entries.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	# If there's exactly one entry and it's a directory, flatten it
	if entries.size() == 1:
		var single_entry = entries[0]
		var single_entry_path = extract_path + "/" + single_entry
		
		# Check if the single entry is a directory
		if dir.dir_exists(single_entry):
			
			var subdir = DirAccess.open(single_entry_path)
			if not subdir:
				return
			
			# Move all contents from the subdirectory to the parent
			subdir.list_dir_begin()
			var item_name = subdir.get_next()
			while item_name != "":
				if item_name != "." and item_name != "..":
					var source_path = single_entry_path + "/" + item_name
					var dest_path = extract_path + "/" + item_name
					
					# Check if destination already exists
					if dir.file_exists(item_name) or dir.dir_exists(item_name):
						pass
					else:
						var error = dir.rename(source_path, dest_path)
						if error != OK:
							pass
				
				item_name = subdir.get_next()
			subdir.list_dir_end()
			
			# Remove the now-empty subdirectory
			var remove_error = subdir.remove(single_entry_path)
			return

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
		var root_path = root_folder.value if root_folder else "user://games"
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
	
	# Vita3K special handling - extract game and prepare TitleID (all platforms)
	if intent.emulator_id.begins_with("vita3k"):
		var vita_ready = await _prepare_vita3k_game(game, intent)
		if not vita_ready:
			push_error("[LaunchManager] Failed to prepare Vita3K game: " + game.get_display_name())
			NotificationManager.show_notification("Failed to prepare Vita game", Notification.Type.ERROR)
			return null
	
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
	if not FileAccess.file_exists(file_path):
		return false
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false
	
	var section = validate.get("section", "")
	var pattern = validate.get("pattern", "")
	
	var content = file.get_as_text()
	file.close()
	
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
	
	if FileAccess.file_exists(file_path):
		var file = FileAccess.open(file_path, FileAccess.READ)
		if file:
			existing_content = file.get_as_text()
			file.close()
	
	# Parse the new content to find sections we need to replace
	var new_sections = _parse_ini_sections(content)
	
	# Replace or append sections in existing content
	var final_content = existing_content
	for section_name in new_sections.keys():
		var section_content = new_sections[section_name]
		final_content = _replace_or_append_section(final_content, section_name, section_content)
	
	var write_file = FileAccess.open(file_path, FileAccess.WRITE)
	if not write_file:
		push_error("[LaunchManager] Failed to write: " + file_path)
		return
	
	write_file.store_string(final_content)
	write_file.close()

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
func launch_game(game: GameResource) -> void:
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
	
	# Game is downloaded, proceed with launch
	_launch_with_emulator_check(game)

## Launch a GameNative game via intent
func _launch_gamenative_game(game: GameResource) -> void:
	if not PlatformManager.is_android():
		push_error("[LaunchManager] Cannot launch GameNative game on non-Android platform")
		NotificationManager.show_notification("GameNative games only available on Android", Notification.Type.ERROR)
		return
	
	var success = GameNativeManager.launch_game(game.steam_app_id)
	if success:
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
			if updated_game:
				_launch_with_emulator_check(updated_game)
			else:
				_launch_with_emulator_check(game)
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
	_launch_game_internal(game, emulator_id)

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
		
		# Retry the launch
		await _launch_game_internal(game, emulator_id)

## Internal function to actually launch the game (emulator must be installed)
func _launch_game_internal(game: GameResource, emulator_id: String) -> void:
	var intent = await create_launch_intent(game)
	
	if not intent:
		NotificationManager.show_notification("Failed to create launch intent", Notification.Type.ERROR)
		return
	
	var success = await execute_launch(intent)
	
	if not success:
		NotificationManager.show_notification("Failed to launch " + game.get_display_name(), Notification.Type.ERROR)
		return
	
	# Update last_played timestamp on successful launch
	_update_last_played(game)

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
	var use_document_uri = intent.android_config.get("use_document_uri", false)  # Opt-in for tree->document conversion (Eden only)
	
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
		use_document_uri
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
	
	# Track batch progress
	var total_cores = cores.size()
	var completed_cores = 0
	var failed_cores = 0
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
		else:
			extract_dir = _get_emulator_directory(emulator_id) + extract_to
		
		# Download to emulator directory (for extraction, then delete)
		var destination_path = _get_emulator_directory(emulator_id) + filename
		
		# Queue download with auto-extract
		var item_id = DownloadManager.queue_download(
			full_url,
			destination_path,
			"emulator_core",
			core_name,
			true,  # auto_extract
			extract_dir,
			null,  # game
			{},    # callbacks
			0,     # romm_id
			true   # delete_after_extract
		)
		
		if item_id == "":
			failed_cores += 1
		else:
			download_ids.append(item_id)
			
			# Create a callback that captures the current values
			var callback = func(success: bool, message: String):
				completed_cores += 1
				if not success:
					failed_cores += 1
				# Update progress
				_emulator_install_progress[emulator_id] = step_display_name + " (" + str(completed_cores) + "/" + str(total_cores) + ")"
				# Check if all downloads are complete
				if completed_cores >= total_cores:
					if failed_cores > 0:
						push_error("[LaunchManager] Batch download failed: " + str(failed_cores) + "/" + str(total_cores) + " cores failed")
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
	else:
		# Relative path (default behavior for desktop)
		extract_dir = _get_emulator_directory(emulator_id) + extract_to
	
	# NEW LOGIC: Check validation first (output files exist?)
	if _validate_install_step(emulator_id, step_index, install_steps):
		_execute_install_step(emulator_id, step_index + 1)
		return true
	
	# Look for the archive file to extract
	var emulator_dir = _get_emulator_directory(emulator_id).rstrip("/")
	var archive_path = ""
	
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	if expected_file != "":
		var dir = DirAccess.open(emulator_dir)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir():
					if file_name.match(expected_file):
						archive_path = emulator_dir + "/" + file_name
						break
				file_name = dir.get_next()
			dir.list_dir_end()
	
	# If no expected_file match, scan for common archive extensions
	if archive_path == "":
		var archive_extensions = [".zip", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".rar", ".tar"]
		var dir = DirAccess.open(emulator_dir)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir():
					var lower_name = file_name.to_lower()
					for ext in archive_extensions:
						if lower_name.ends_with(ext):
							archive_path = emulator_dir + "/" + file_name
							break
					if archive_path != "":
						break
				file_name = dir.get_next()
			dir.list_dir_end()
	
	# Check if archive was found
	if archive_path == "" or not FileAccess.file_exists(archive_path):
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
	
	# Track extraction completion
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "extraction",
		"step_index": step_index,
		"step_config": extract_config,
		"callback": func(success: bool, message: String):
			if not success:
				_emulator_install_progress[emulator_id] = "Extraction failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Handle post-extraction flattening
			if strip_top:
				_flatten_extracted_directory(emulator_id, extract_to, flatten_target)
			
			# Validate extraction
			var validate_config = extract_config.get("validate", {})
			if not _validate_step(emulator_id, validate_config):
				push_error("[LaunchManager] Validation failed after extraction: " + emulator_id)
				_emulator_install_progress[emulator_id] = "Validation failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Progress to next step
			_execute_install_step(emulator_id, step_index + 1)
	}
	
	return true

## Validates a step result based on validation config
## Resolves a path for validation - uses absolute paths directly, relative paths are relative to emulator dir
func _resolve_validation_path(emulator_id: String, path: String) -> String:
	# First resolve {emulator_dir} templates
	path = _resolve_emulator_path(path, emulator_id)
	
	if path.begins_with("/") or path.begins_with("content://"):
		# Absolute path or SAF URI - use as-is
		return path
	else:
		# Relative path - prepend emulator directory
		return _get_emulator_directory(emulator_id) + path

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
			return FileAccess.file_exists(full_path)
		
		"folder_exists":
			var folder_path = validate_config.get("path", "")
			if folder_path == "":
				return true
			var full_path = _resolve_validation_path(emulator_id, folder_path)
			var dir = DirAccess.open(full_path)
			return dir != null
		
		"files_exist":
			var folder_path = validate_config.get("path", "")
			var pattern = validate_config.get("pattern", "")
			var files_array = validate_config.get("files", [])
			
			# Support both "files" array format and "path" + "pattern" format
			if files_array.size() > 0:
				# Check if all files in the array exist
				for file_name in files_array:
					var full_file_path = _resolve_validation_path(emulator_id, file_name)
					if not FileAccess.file_exists(full_file_path):
						return false
				return true
			
			if folder_path == "":
				return true
			
			var full_path = _resolve_validation_path(emulator_id, folder_path)
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
		
		# On Android with SAF paths, use plugin to create directory
		if PlatformManager.is_android() and full_path.begins_with("content://"):
			var plugin = Engine.get_singleton("PackageChecker")
			if plugin and plugin.has_method("createSafDirectory"):
				var tree_uri = _extract_saf_tree_uri(full_path)
				var subdir = _get_saf_subdirectory(full_path)
				if subdir != "":
					plugin.call("createSafDirectory", tree_uri, subdir)
			continue
		
		# Create the full path recursively (handles nested folders like user/nand/system/Contents)
		var error = DirAccess.make_dir_recursive_absolute(full_path)
		if error != OK:
			push_error("[LaunchManager] Failed to create folder: " + full_path + " (error: " + str(error) + ")")
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
		
		if not FileAccess.file_exists(full_path):
			var file = FileAccess.open(full_path, FileAccess.WRITE)
			if file == null:
				push_error("[LaunchManager] Failed to create file: " + full_path)
				return false
			else:
				file.store_string(file_content)
				file.close()
		else:
			pass
	
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
	
	if not FileAccess.file_exists(full_path):
		push_error("[LaunchManager] File not found for editing: " + full_path)
		return false
	
	var file = FileAccess.open(full_path, FileAccess.READ)
	if file == null:
		push_error("[LaunchManager] Failed to open file for editing: " + full_path)
		return false
	
	var content = file.get_as_text()
	file.close()
	
	for edit in edits:
		var old_text = edit.get("old", "")
		var new_text = edit.get("new", "")
		
		if old_text == "":
			continue
		
		content = content.replace(old_text, new_text)
	
	file = FileAccess.open(full_path, FileAccess.WRITE)
	if file == null:
		push_error("[LaunchManager] Failed to write edited file: " + full_path)
		return false
	
	file.store_string(content)
	file.close()
	
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
func get_install_progress(emulator_id: String) -> Dictionary:
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
func _extract_vita_title_id(zip_path: String) -> String:
	var actual_zip_path = zip_path
	
	# On Android with SAF, content:// URIs can't be read directly by ZIPReader
	# Convert to real file path using the PackageChecker plugin
	if PlatformManager.is_android() and zip_path.begins_with("content://"):
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin == null:
			push_error("[LaunchManager] PackageChecker plugin not available for SAF URI conversion")
			return ""
		
		var real_path = plugin.getRealPathFromSafUri(zip_path)
		if real_path == "":
			push_error("[LaunchManager] Cannot convert SAF URI to real path: " + zip_path)
			return ""
		
		actual_zip_path = real_path
	
	if not FileAccess.file_exists(actual_zip_path):
		push_error("[LaunchManager] Cannot extract TitleID - file not found: " + actual_zip_path)
		return ""
	
	var reader = ZIPReader.new()
	var err = reader.open(actual_zip_path)
	if err != OK:
		push_error("[LaunchManager] Failed to open ZIP for TitleID extraction: " + actual_zip_path)
		return ""
	
	var files = reader.get_files()
	reader.close()
	
	if files.is_empty():
		push_error("[LaunchManager] ZIP is empty: " + actual_zip_path)
		return ""
	
	# Get root folder from first file path
	var first_file = files[0]
	var parts = first_file.split("/")
	if parts.is_empty():
		push_error("[LaunchManager] Invalid ZIP structure: " + actual_zip_path)
		return ""
	
	return parts[0]

## Handles Vita3K game extraction and launch preparation
## Returns true if ready to launch, false if error
func _prepare_vita3k_game(game: GameResource, intent: LaunchIntent) -> bool:
	var rom_path = intent.rom_path
	
	# Get emulator directory for checking existing games
	# Platform-specific: Android uses fixed external storage path, desktop uses install path
	var emulator_dir: String
	var ux0_app_path: String
	
	if PlatformManager.is_android():
		# Android: Vita3K stores games in external storage
		emulator_dir = "/storage/emulated/0/Vita3K"
		ux0_app_path = emulator_dir + "/ux0/app"
	else:
		# Desktop: Get path from emulator installation
		var emulator_path = get_emulator_install_path(intent.emulator_id)
		if emulator_path == "":
			push_error("[LaunchManager] Vita3K: Cannot find emulator install path")
			return false
		emulator_dir = emulator_path.get_base_dir()
		ux0_app_path = emulator_dir + "/ux0/app"
	
	# Extract TitleID from ZIP if not already stored
	if game.title_id == "":
		# by scanning the ux0/app directory for any TitleID folder
		var found_title_id = ""
		if DirAccess.dir_exists_absolute(ux0_app_path):
			var dir = DirAccess.open(ux0_app_path)
			if dir:
				dir.list_dir_begin()
				var folder_name = dir.get_next()
				while folder_name != "":
					if folder_name != "." and folder_name != ".." and dir.current_is_dir():
						# Found a TitleID folder - use it (Vita3K stores games by TitleID)
						found_title_id = folder_name
						break
					folder_name = dir.get_next()
				dir.list_dir_end()
		
		# If no existing game found, extract from ZIP
		if found_title_id == "":
			found_title_id = _extract_vita_title_id(rom_path)
			if found_title_id == "":
				push_error("[LaunchManager] Vita3K: Failed to extract TitleID from: " + rom_path)
				NotificationManager.show_notification("Failed to extract Vita game TitleID", Notification.Type.ERROR)
				return false
		
		game.title_id = found_title_id
		# Save only title_id to database (doesn't overwrite other fields)
		DataManager.update_game_title_id(game.romm_id, found_title_id)
	
	var title_id = game.title_id
	
	# Platform-specific Vita3K app path
	var vita_app_path: String
	if PlatformManager.is_android():
		vita_app_path = "/storage/emulated/0/Vita3K/ux0/app/" + title_id
	else:
		# Desktop - use emulator directory (already obtained above)
		vita_app_path = emulator_dir + "/ux0/app/" + title_id
	
	# Check if already extracted
	var dir = DirAccess.open(vita_app_path)
	if dir != null:
		return true
	
	# Extract ZIP to Vita3K ux0/app directory (ZIP contains the TitleID folder)
	# We extract to the parent directory (ux0/app) so the ZIP's root folder lands correctly
	var extract_parent = vita_app_path.get_base_dir()
	NotificationManager.show_notification("Extracting Vita game for first launch...", Notification.Type.INFO)
	
	var extract_success = await _extract_vita_zip(rom_path, extract_parent, title_id)
	if not extract_success:
		push_error("[LaunchManager] Vita3K: Failed to extract game to " + vita_app_path)
		return false
	
	return true

## Extracts Vita game ZIP with progress tracking
func _extract_vita_zip(zip_path: String, extract_to: String, title_id: String) -> bool:
	# Create parent directories if needed
	var parent_dir = extract_to.get_base_dir()
	var err = DirAccess.make_dir_recursive_absolute(parent_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("[LaunchManager] Failed to create Vita3K app directory: " + parent_dir)
		return false
	
	# Use DownloadManager's extraction for progress tracking
	# Pass false to preserve the ZIP file (don't delete after extraction)
	var item_id = DownloadManager.queue_extraction(zip_path, extract_to, "vita_game", title_id, false)
	if item_id == "":
		push_error("[LaunchManager] Failed to queue Vita game extraction")
		return false
	
	# Wait for extraction to complete
	var extraction_complete = false
	var extraction_success = false
	
	var on_complete = func(completed_item_id: String, success: bool, message: String):
		if completed_item_id == item_id:
			extraction_complete = true
			extraction_success = success
	
	DownloadManager.extraction_completed.connect(on_complete)
	
	# Wait for completion (with timeout)
	var timeout = 300.0  # 5 minutes timeout
	var elapsed = 0.0
	while not extraction_complete and elapsed < timeout:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	
	DownloadManager.extraction_completed.disconnect(on_complete)
	
	if not extraction_complete:
		push_error("[LaunchManager] Vita3K: Extraction timed out")
		return false
	
	return extraction_success
