extends Manager

## Manages emulator registry, launch intents, and game execution

const REGISTRY_PATH := "res://data/emulator_registry.json"
const EMULATORS_DIR := "user://emulators/"

# Installation states
enum InstallState {
	NOT_INSTALLED,
	DOWNLOADING,
	EXTRACTING,
	NEEDS_POST_INSTALL,
	ENACTING_POST_INSTALL,
	INSTALLED
}

# Registry data
var _emulator_registry: Dictionary = {}
var _platform_defaults: Dictionary = {}

# Track installation states
var _emulator_install_states: Dictionary = {}  # emulator_id -> InstallState
var _emulator_install_progress: Dictionary = {}  # emulator_id -> progress text for UI

# Track ongoing extractions


# Track pending launches waiting for emulator installation
# emulator_id -> {game: GameResource, callback: Callable}
var _pending_launches: Dictionary = {}

# Signals
signal emulator_registry_loaded(success: bool)
signal launch_completed(success: bool, message: String)
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_progress(emulator_id: String, progress: float)
signal emulator_extraction_completed(emulator_id: String, success: bool)
signal emulator_installations_scanned()  # Emitted after disk scan completes

func _ready():
	_load_registry()
	_ensure_emulators_directory()
	
	# Connect to DownloadManager signals
	DownloadManager.extraction_started.connect(_on_download_manager_extraction_started)
	DownloadManager.extraction_completed.connect(_on_download_manager_extraction_completed)
	
	# Scan existing installations to detect partial installs
	# Wait a frame to ensure everything is initialized
	await get_tree().process_frame
	scan_emulator_installations()

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
	
	print("[LaunchManager] Loaded " + str(_emulator_registry.size()) + " emulators from registry")
	emulator_registry_loaded.emit(true)

func _build_platform_defaults():
	# Build a map of platform -> default emulator
	_platform_defaults.clear()
	
	for emulator_id in _emulator_registry.keys():
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

## Gets the current installation state of an emulator
func get_emulator_install_state(emulator_id: String) -> InstallState:
	return _emulator_install_states.get(emulator_id, InstallState.NOT_INSTALLED)

## Checks if emulator is fully installed (including post-install steps)
func is_emulator_fully_installed(emulator_id: String) -> bool:
	return get_emulator_install_state(emulator_id) == InstallState.INSTALLED

## Gets the current installation progress text for UI display
func get_emulator_install_progress(emulator_id: String) -> String:
	return _emulator_install_progress.get(emulator_id, "")

## Validates that emulator is properly installed by checking file existence
## This is the source of truth - state enums are for tracking operations
func validate_emulator_installation(emulator_id: String) -> bool:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return false
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var executable_name = emulator.get("executable_names", {}).get(platform_name, "")
	
	if executable_name == "":
		return false
	
	# Check if main executable exists
	var install_path = get_emulator_install_path(emulator_id)
	if install_path == "" or not FileAccess.file_exists(install_path):
		return false
	
	# Check post-install validation if configured
	var post_install = emulator.get("post_install", {})
	if not post_install.is_empty():
		var validation = post_install.get("validation", {})
		if not validation.is_empty():
			if not _validate_post_install(emulator_id, validation):
				return false
	
	return true

## Validates only that the main executable exists (no post-install check)
func validate_emulator_executable(emulator_id: String) -> bool:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return false
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var executable_name = emulator.get("executable_names", {}).get(platform_name, "")
	
	if executable_name == "":
		return false
	
	# Check if main executable exists
	var install_path = get_emulator_install_path(emulator_id)
	if install_path == "" or not FileAccess.file_exists(install_path):
		return false
	
	return true

## Validates post-install requirements (e.g., cores directory)
func _validate_post_install(emulator_id: String, validation: Dictionary) -> bool:
	var validation_type = validation.get("type", "")
	
	match validation_type:
		"cores_directory":
			var relative_path = validation.get("path", "")
			var file_pattern = validation.get("file_pattern", "*")
			
			if relative_path == "":
				return true
			
			var full_path = EMULATORS_DIR + emulator_id + "/" + relative_path
			
			# Check if directory exists
			var dir = DirAccess.open(full_path)
			if not dir:
				print("[LaunchManager] Post-install validation failed: directory not found - " + full_path)
				return false
			
			# Count files matching pattern
			var file_count = 0
			dir.list_dir_begin()
			var file_name = dir.get_next()
			
			while file_name != "":
				if file_name != "." and file_name != ".." and not dir.current_is_dir():
					if file_pattern == "*" or file_name.match(file_pattern):
						file_count += 1
				file_name = dir.get_next()
			
			dir.list_dir_end()
			
			if file_count == 0:
				print("[LaunchManager] Post-install validation failed: no files matching " + file_pattern + " in " + full_path)
				return false
			
			print("[LaunchManager] Post-install validation passed: found " + str(file_count) + " files in " + full_path)
			return true
		
		_:
			# Unknown validation type, assume valid
			return true

## Legacy function - checks if main executable exists (deprecated, use validate_emulator_installation)
func is_emulator_installed(emulator_id: String) -> bool:
	return validate_emulator_installation(emulator_id)

## Scans existing emulator installations and sets correct states
## Call this on startup to detect partial installations
func scan_emulator_installations():
	print("[LaunchManager] Scanning existing emulator installations...")
	
	var dir = DirAccess.open(EMULATORS_DIR)
	if not dir:
		print("[LaunchManager] No emulators directory found")
		return
	
	dir.list_dir_begin()
	var folder_name = dir.get_next()
	
	while folder_name != "":
		if folder_name == "." or folder_name == "..":
			folder_name = dir.get_next()
			continue
		
		# Check if this is an emulator directory (has emulator.json or matches registry)
		if _emulator_registry.has(folder_name):
			_check_emulator_disk_state(folder_name)
		
		folder_name = dir.get_next()
	
	dir.list_dir_end()
	print("[LaunchManager] Scan complete")
	emulator_installations_scanned.emit()

## Checks the actual disk state for a specific emulator and updates state accordingly
## Public wrapper for individual emulator checks
func check_emulator_disk_state(emulator_id: String):
	_check_emulator_disk_state(emulator_id)

## Internal implementation - checks disk state and updates _emulator_install_states
func _check_emulator_disk_state(emulator_id: String):
	_check_emulator_disk_state_internal(emulator_id, true)

## Internal disk check with option to skip active operations
func _check_emulator_disk_state_internal(emulator_id: String, skip_if_active: bool = true):
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return
	
	# Skip if currently in active download/install process (unless explicitly checking after completion)
	if skip_if_active:
		var current_state = get_emulator_install_state(emulator_id)
		if current_state in [InstallState.DOWNLOADING, InstallState.EXTRACTING, 
							InstallState.ENACTING_POST_INSTALL]:
			print("[LaunchManager] Skipping disk check for " + emulator_id + " - active operation in progress")
			return
	
	# Check if main executable exists
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var executable_name = emulator.get("executable_names", {}).get(platform_name, "")
	var install_path = get_emulator_install_path(emulator_id)
	
	if install_path == "" or not FileAccess.file_exists(install_path):
		# No executable found - truly not installed
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		_emulator_install_progress[emulator_id] = ""
		print("[LaunchManager] Disk check: " + emulator_id + " - executable not found, marking as NOT_INSTALLED")
		return
	
	# Executable exists - check if post-install is needed
	var post_install = emulator.get("post_install", {})
	if not post_install.is_empty():
		var validation = post_install.get("validation", {})
		if not validation.is_empty():
			if not _validate_post_install(emulator_id, validation):
				# Executable exists but post-install validation failed
				_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
				_emulator_install_progress[emulator_id] = "Post-install required"
				print("[LaunchManager] Disk check: " + emulator_id + " - executable found but post-install needed")
				return
	
	# All validation passed - fully installed
	_emulator_install_states[emulator_id] = InstallState.INSTALLED
	_emulator_install_progress[emulator_id] = ""
	print("[LaunchManager] Disk check: " + emulator_id + " - fully installed")

## Checks if emulator archive has been downloaded
func is_emulator_downloaded(emulator_id: String) -> bool:
	var archive_path = get_archive_path(emulator_id)
	if archive_path == "":
		return false
	return FileAccess.file_exists(archive_path)

## Gets the path to the downloaded archive
func get_archive_path(emulator_id: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var download_urls = emulator.get("download_urls", {})
	var download_url = download_urls.get(platform_name, "")
	
	if download_url == "":
		return ""
	
	var filename = download_url.get_file()
	return EMULATORS_DIR + emulator_id + "/" + filename

## Checks if emulator is currently being extracted
func is_emulator_extracting(emulator_id: String) -> bool:
	# Check DownloadManager for any active extraction for this emulator
	for item in DownloadManager.get_active():
		if item.name == emulator_id and item.status == "extracting":
			return true
	return false

func extract_emulator(emulator_id: String) -> bool:
	if is_emulator_installed(emulator_id):
		print("[LaunchManager] Emulator already installed: " + emulator_id)
		return true
	
	if not is_emulator_downloaded(emulator_id):
		push_error("[LaunchManager] Cannot extract - archive not downloaded: " + emulator_id)
		return false
	
	var archive_path = get_archive_path(emulator_id)
	var extract_dir = EMULATORS_DIR + emulator_id + "/"
	
	print("[LaunchManager] Queueing extraction: " + emulator_id)
	
	# Set state to extracting
	_emulator_install_states[emulator_id] = InstallState.EXTRACTING
	
	# Queue extraction via DownloadManager
	var item_id = DownloadManager.queue_extraction(archive_path, extract_dir, "emulator", emulator_id)
	if item_id == "":
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		return false
	
	return true

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

## Called when DownloadManager starts an extraction
## Updates emulator state to track extraction progress
func _on_download_manager_extraction_started(item_id: String):
	# Find which emulator this extraction belongs to
	var item = DownloadManager.get_item(item_id)
	if item == null:
		return
	
	# Check if this is a cores extraction
	if item.type == "cores":
		# Find the emulator this cores download belongs to
		for emulator_id in _emulator_install_states.keys():
			if item.destination_path.begins_with(EMULATORS_DIR + emulator_id):
				var current_state = get_emulator_install_state(emulator_id)
				if current_state == InstallState.NEEDS_POST_INSTALL:
					_emulator_install_states[emulator_id] = InstallState.ENACTING_POST_INSTALL
					print("[LaunchManager] Cores extraction started for: " + emulator_id)
				return
	else:
		# Check if this is an emulator extraction
		for emulator_id in _emulator_install_states.keys():
			if item.destination_path.begins_with(EMULATORS_DIR + emulator_id):
				var current_state = get_emulator_install_state(emulator_id)
				if current_state == InstallState.DOWNLOADING:
					_emulator_install_states[emulator_id] = InstallState.EXTRACTING
					print("[LaunchManager] Emulator extraction started for: " + emulator_id)
				return

## Called when DownloadManager completes an extraction
## Updates emulator state based on extraction result
func _on_download_manager_extraction_completed(item_id: String, success: bool, extract_dir: String):
	# Find which emulator this extraction belongs to
	for emulator_id in _emulator_install_states.keys():
		if extract_dir.begins_with(EMULATORS_DIR + emulator_id):
			if success:
				print("[LaunchManager] Extraction completed for: " + emulator_id)
				
				# Get current state before making changes
				var current_state = get_emulator_install_state(emulator_id)
				var emulator = get_emulator(emulator_id)
				
				if current_state == InstallState.ENACTING_POST_INSTALL:
					# Cores extraction just completed - check validation
					# Wait for filesystem to settle
					await get_tree().create_timer(0.5).timeout
					if validate_emulator_installation(emulator_id):
						_emulator_install_states[emulator_id] = InstallState.INSTALLED
						_emulator_install_progress[emulator_id] = ""
						print("[LaunchManager] Post-install complete, emulator fully installed: " + emulator_id)
						emulator_extraction_completed.emit(emulator_id, true)
					else:
						_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
						_emulator_install_progress[emulator_id] = "Post-install validation failed"
						emulator_extraction_completed.emit(emulator_id, false)
				elif current_state == InstallState.EXTRACTING:
					# Main emulator extraction just completed
					# Wait for filesystem to settle
					await get_tree().create_timer(0.5).timeout
					
					# Check if executable exists (no post-install check here)
					if not validate_emulator_executable(emulator_id):
						push_error("[LaunchManager] Validation failed - executable not found after extraction: " + emulator_id)
						_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
						_emulator_install_progress[emulator_id] = "Validation failed - executable missing"
						emulator_extraction_completed.emit(emulator_id, false)
						return
					
					print("[LaunchManager] Validation passed - executable found for: " + emulator_id)
					
					# Check for post-install
					if emulator.has("post_install"):
						# Validate post-install requirements
						var post_install = emulator.get("post_install", {})
						var validation = post_install.get("validation", {})
						
						if not validation.is_empty():
							if _validate_post_install(emulator_id, validation):
								# Post-install already complete
								_emulator_install_states[emulator_id] = InstallState.INSTALLED
								_emulator_install_progress[emulator_id] = ""
								print("[LaunchManager] Installation complete (post-install already done): " + emulator_id)
								emulator_extraction_completed.emit(emulator_id, true)
							else:
								# Need to do post-install - set state and trigger it
								_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
								_emulator_install_progress[emulator_id] = "Post-install required"
								print("[LaunchManager] Main extraction complete, post-install needed: " + emulator_id)
								emulator_extraction_completed.emit(emulator_id, true)
								# Auto-trigger post-install
								_start_post_install(emulator_id, emulator)
						else:
							# No validation configured, mark as installed
							_emulator_install_states[emulator_id] = InstallState.INSTALLED
							_emulator_install_progress[emulator_id] = ""
							print("[LaunchManager] Installation complete: " + emulator_id)
							emulator_extraction_completed.emit(emulator_id, true)
					else:
						# No post-install needed
						_emulator_install_states[emulator_id] = InstallState.INSTALLED
						_emulator_install_progress[emulator_id] = ""
						print("[LaunchManager] Installation complete: " + emulator_id)
						emulator_extraction_completed.emit(emulator_id, true)
				else:
					# Unexpected state
					print("[LaunchManager] Warning: Extraction completed in unexpected state: " + str(current_state))
					_emulator_install_states[emulator_id] = InstallState.INSTALLED
					_emulator_install_progress[emulator_id] = ""
					emulator_extraction_completed.emit(emulator_id, true)
				return
			else:
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				_emulator_install_progress[emulator_id] = "Extraction failed"
				emulator_extraction_completed.emit(emulator_id, false)
			return

## Starts the post-install process for an emulator
func _start_post_install(emulator_id: String, emulator: Dictionary):
	var post_install = emulator.get("post_install", {})
	var install_type = post_install.get("type", "")
	
	match install_type:
		"cores":
			_start_cores_post_install(emulator_id, emulator, post_install)
		_:
			# Unknown post-install type - validate and mark as installed if valid
			print("[LaunchManager] Unknown post-install type '" + install_type + "', validating: " + emulator_id)
			if validate_emulator_installation(emulator_id):
				_emulator_install_states[emulator_id] = InstallState.INSTALLED
				_emulator_install_progress[emulator_id] = ""
				print("[LaunchManager] Validation passed, marking as installed: " + emulator_id)
				emulator_extraction_completed.emit(emulator_id, true)
			else:
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				_emulator_install_progress[emulator_id] = "Validation failed"
				push_error("[LaunchManager] Validation failed after extraction: " + emulator_id)
				emulator_extraction_completed.emit(emulator_id, false)

## Handles cores-type post-install (download and extract cores)
func _start_cores_post_install(emulator_id: String, emulator: Dictionary, post_install: Dictionary):
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var cores_url = post_install.get("cores_url", {}).get(platform_name, "")
	var cores_filename = post_install.get("cores_filename", {}).get(platform_name, "")
	
	if cores_url == "":
		push_error("[LaunchManager] No cores URL for platform: " + platform_name)
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		_emulator_install_progress[emulator_id] = "Post-install configuration error"
		emulator_extraction_completed.emit(emulator_id, false)
		return
	
	var emulator_name = emulator.get("name", emulator_id)
	
	# Use provided filename or extract from URL
	if cores_filename == "":
		cores_filename = cores_url.get_file()
	
	var destination_path = EMULATORS_DIR + emulator_id + "/" + cores_filename
	
	print("[LaunchManager] Starting cores post-install for: " + emulator_id)
	print("[LaunchManager] Cores URL: " + cores_url)
	
	# Set state to enacting post-install
	_emulator_install_states[emulator_id] = InstallState.ENACTING_POST_INSTALL
	_emulator_install_progress[emulator_id] = "Downloading " + emulator_name + " cores..."
	
	# Queue cores download via DownloadManager (with auto-extract)
	var item_id = DownloadManager.queue_download(
		cores_url,
		destination_path,
		"cores",
		emulator_name + " cores",
		true,  # auto_extract
		EMULATORS_DIR + emulator_id + "/"
	)
	
	if item_id == "":
		push_error("[LaunchManager] Failed to queue cores download: " + emulator_id)
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		_emulator_install_progress[emulator_id] = "Failed to queue cores download"
		emulator_extraction_completed.emit(emulator_id, false)
## Gets the install path for an emulator (searches recursively)
func get_emulator_install_path(emulator_id: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var executable_name = emulator.get("executable_names", {}).get(platform_name, "")
	
	if executable_name == "":
		return ""
	
	# First check direct path
	var direct_path = EMULATORS_DIR + emulator_id + "/" + executable_name
	if FileAccess.file_exists(direct_path):
		return direct_path
	
	# Search recursively up to 3 levels deep
	var search_dir = EMULATORS_DIR + emulator_id + "/"
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
## Priority: 1. Game override, 2. Platform default, 3. First available
func resolve_emulator_for_game(game: GameResource) -> String:
	# 1. Check game override
	if game.preferred_emulator_id != "":
		return game.preferred_emulator_id
	
	# 2. Check platform settings
	var enabled_platforms = _get_enabled_platforms()
	var platform_config = enabled_platforms.get(game.platform_slug, {})
	var platform_emulator = platform_config.get("emulator_id", "")
	
	if platform_emulator != "":
		return platform_emulator
	
	# 3. Use registry default
	return get_default_emulator_for_platform(game.platform_slug)

## Creates a launch intent for a game
func create_launch_intent(game: GameResource) -> LaunchIntent:
	if not game.has_local_copy or game.file_path == "":
		push_error("[LaunchManager] Cannot launch game without local copy: " + game.get_display_name())
		return null
	
	var intent = LaunchIntent.new()
	intent.game = game
	intent.rom_path = game.file_path
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
	
	return intent

func _build_launch_args(intent: LaunchIntent, emulator: Dictionary):
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var templates = emulator.get("launch_templates", {})
	
	if PlatformManager.is_android():
		# Android uses intent-based launching
		var android_template = templates.get("android", {})
		intent.android_action = android_template.get("action", "")
		intent.android_package = android_template.get("package", "")
		intent.android_class = android_template.get("class", "")
		intent.android_extras = android_template.get("extras", {})
	else:
		# Desktop uses command-line arguments
		var template = templates.get(platform_name, [])
		var install_path = get_emulator_install_path(intent.emulator_id)
		
		# Convert paths to absolute system paths for OS.execute
		var global_install_path = ProjectSettings.globalize_path(install_path)
		var global_rom_path = ProjectSettings.globalize_path(intent.rom_path)
		
		# Normalize paths to remove double slashes
		global_install_path = global_install_path.replace("//", "/")
		global_rom_path = global_rom_path.replace("//", "/")
		
		# Build absolute core path
		var install_dir = global_install_path.get_base_dir()
		install_dir = install_dir.replace("//", "/")
		var core_extension = "_libretro.dll" if PlatformManager.is_windows() else "_libretro.so"
		var global_core_path = install_dir + "/cores/" + intent.core_name + core_extension
		global_core_path = global_core_path.replace("//", "/")
		
		for arg in template:
			var formatted_arg = arg.replace("{exe}", global_install_path)
			formatted_arg = formatted_arg.replace("{rom}", global_rom_path)
			formatted_arg = formatted_arg.replace("{core}", global_core_path)
			intent.launch_args.append(formatted_arg)

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	if not intent or not intent.is_valid():
		push_error("[LaunchManager] Invalid launch intent")
		return false
	
	# Check if emulator is fully installed (including post-install steps)
	if get_emulator_install_state(intent.emulator_id) != InstallState.INSTALLED:
		push_error("[LaunchManager] Emulator not fully installed: " + intent.emulator_id)
		NotificationManager.show_notification("Emulator not ready: " + intent.emulator_name, Notification.Type.ERROR)
		return false
	
	print("[LaunchManager] Launching: " + intent.to_string())
	
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
	
	# Debug: Print the full command
	var full_command = exe_path + " " + " ".join(arguments)
	print("[LaunchManager] Full launch command: " + full_command)
	
	# Use OS.create_process for non-blocking launch
	var pid = OS.create_process(exe_path, arguments, false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to launch process: " + exe_path)
		launch_completed.emit(false, "Failed to start emulator")
		return false
	
	print("[LaunchManager] Launched process with PID: " + str(pid))
	launch_completed.emit(true, "Game launched successfully")
	return true

## Main entry point for launching a game
func launch_game(game: GameResource) -> void:
	if not game.has_local_copy or game.file_path == "":
		NotificationManager.show_notification("Game file not downloaded", Notification.Type.ERROR)
		return
	
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
	
	# Check if emulator is fully installed (including post-install steps)
	if get_emulator_install_state(emulator_id) != InstallState.INSTALLED:
		print("[LaunchManager] Emulator not fully installed, auto-downloading: " + emulator_id)
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
	
	# Check if emulator is actually fully installed (post-install might still be in progress)
	if get_emulator_install_state(emulator_id) != InstallState.INSTALLED:
		# Post-install is still running, wait for it to complete
		print("[LaunchManager] Emulator " + emulator_id + " main extraction complete, waiting for post-install...")
		return
	
	# Check if we have a pending launch for this emulator
	if _pending_launches.has(emulator_id):
		var game: GameResource = _pending_launches[emulator_id]
		_pending_launches.erase(emulator_id)
		
		print("[LaunchManager] Emulator " + emulator_id + " fully installed, auto-launching: " + game.get_display_name())
		NotificationManager.show_notification("Launching " + game.get_display_name() + "...", Notification.Type.INFO)
		
		# Give a small delay for file system to settle
		await get_tree().create_timer(0.5).timeout
		
		# Retry the launch
		_launch_game_internal(game, emulator_id)

## Internal function to actually launch the game (emulator must be installed)
func _launch_game_internal(game: GameResource, emulator_id: String) -> void:
	var intent = create_launch_intent(game)
	
	if not intent:
		NotificationManager.show_notification("Failed to create launch intent", Notification.Type.ERROR)
		return
	
	var success = execute_launch(intent)
	
	if not success:
		NotificationManager.show_notification("Failed to launch " + game.get_display_name(), Notification.Type.ERROR)

func _execute_android(intent: LaunchIntent) -> bool:
	# TODO: Implement Android intent launching
	# This requires JNI calls or OS.shell_open with specific URI formats
	push_error("[LaunchManager] Android launching not yet implemented")
	return false

## Helper: Get enabled platforms from settings
func _get_enabled_platforms() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

# ==================== EMULATOR DOWNLOAD ====================

func download_emulator(emulator_id: String) -> bool:
	"""Queue an emulator for download. Returns true if queued, false if already downloaded/queued."""
	
	var current_state = get_emulator_install_state(emulator_id)
	
	# Check if already installed or in progress
	if current_state == InstallState.INSTALLED:
		print("[LaunchManager] Emulator already installed: " + emulator_id)
		return false
	
	# Check if already downloading (any state that indicates active download)
	if current_state in [InstallState.DOWNLOADING, InstallState.EXTRACTING, 
						InstallState.ENACTING_POST_INSTALL]:
		print("[LaunchManager] Emulator already downloading/installing: " + emulator_id)
		return false
	
	# Get emulator info
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[LaunchManager] Unknown emulator: " + emulator_id)
		return false
	
	var emulator_name = emulator.get("name", emulator_id)
	
	# Get download URL for current platform
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var download_urls = emulator.get("download_urls", {})
	var download_url = download_urls.get(platform_name, "")
	
	if download_url == "":
		push_error("[LaunchManager] No download URL for platform: " + platform_name)
		return false
	
	# Build destination path
	var filename = download_url.get_file()
	var destination_path = EMULATORS_DIR + emulator_id + "/" + filename
	
	# Set state to DOWNLOADING
	_emulator_install_states[emulator_id] = InstallState.DOWNLOADING
	_emulator_install_progress[emulator_id] = "Downloading " + emulator_name + "..."
	
	print("[LaunchManager] Queueing emulator download: " + emulator_id + " from " + download_url)
	
	# Queue the download via DownloadManager (with auto-extract)
	var item_id = DownloadManager.queue_download(
		download_url,
		destination_path,
		"emulator",
		emulator_name,
		true,  # auto_extract
		EMULATORS_DIR + emulator_id + "/"
	)
	
	if item_id == "":
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		return false
	
	return true

## Completes post-install for an emulator that's in NEEDS_POST_INSTALL state
## Call this when user clicks "Complete Install" on a partially installed emulator
func complete_post_install(emulator_id: String) -> bool:
	var current_state = get_emulator_install_state(emulator_id)
	
	if current_state != InstallState.NEEDS_POST_INSTALL:
		print("[LaunchManager] Cannot complete post-install - emulator not in NEEDS_POST_INSTALL state: " + emulator_id)
		return false
	
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[LaunchManager] Unknown emulator: " + emulator_id)
		return false
	
	if not emulator.has("post_install"):
		print("[LaunchManager] No post-install configured for: " + emulator_id)
		return false
	
	print("[LaunchManager] Completing post-install for: " + emulator_id)
	_start_post_install(emulator_id, emulator)
	return true

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
