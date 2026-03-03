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


# Track post-install task sequences
var _emulator_post_install_task_index: Dictionary = {}  # emulator_id -> current task index

# Track pending launches waiting for emulator installation
# emulator_id -> {game: GameResource, callback: Callable}
var _pending_launches: Dictionary = {}

# Track pending launches waiting for game download
# item_id -> GameResource
var _pending_game_downloads: Dictionary = {}

## Unified download tracking for emulator downloads
# item_id -> {emulator_id, context, extract_to, strip_top_directory, callback}
var _pending_emulator_downloads: Dictionary = {}

## Unified download tracking for post-install downloads
# item_id -> {emulator_id, context, extract_to, strip_top_directory, callback, destination_path, task_index}
var _pending_post_install_downloads: Dictionary = {}

# Signals
signal emulator_registry_loaded(success: bool)
signal launch_completed(success: bool, message: String)
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_progress(emulator_id: String, progress: float)
signal emulator_extraction_completed(emulator_id: String, success: bool)
signal emulator_installations_scanned()  # Emitted after disk scan completes
signal game_launched(game: GameResource)  # Emitted when a game is successfully launched

func _ready():
	_load_registry()
	_ensure_emulators_directory()
	
	# Connect to DownloadManager signals (using unified handlers only)
	DownloadManager.extraction_started.connect(_on_download_manager_extraction_started)
	DownloadManager.extraction_completed.connect(_on_unified_extraction_completed)
	DownloadManager.download_completed.connect(_on_unified_download_completed)
	
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
	_platform_defaults.clear()
	
	# First, check for explicit platform defaults in registry
	if _emulator_registry.has("_platform_defaults"):
		var explicit_defaults = _emulator_registry["_platform_defaults"]
		if explicit_defaults is Dictionary:
			for platform in explicit_defaults.keys():
				var emulator_id = explicit_defaults[platform]
				if _emulator_registry.has(emulator_id):
					_platform_defaults[platform] = emulator_id
					print("[LaunchManager] Explicit default for %s: %s" % [platform, emulator_id])
	
	# Then, for any platforms not explicitly set, use first available emulator
	for emulator_id in _emulator_registry.keys():
		if emulator_id.begins_with("_"):
			continue
		var emulator = _emulator_registry[emulator_id]
		var platforms = emulator.get("platforms", [])
		
		for platform in platforms:
			if not _platform_defaults.has(platform):
				_platform_defaults[platform] = emulator_id
				print("[LaunchManager] Implicit default for %s: %s" % [platform, emulator_id])

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
	
	# Check post-install tasks validation if configured
	var post_install_tasks = emulator.get("post_install_tasks", [])
	if not post_install_tasks.is_empty():
		for task in post_install_tasks:
			var validation = task.get("validation", {})
			if not validation.is_empty():
				if not _validate_post_install(emulator_id, validation, false):
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
## @param quiet: If true, suppresses "passed" log messages (only logs failures)
func _validate_post_install(emulator_id: String, validation: Dictionary, quiet: bool = false) -> bool:
	var validation_type = validation.get("type", "")
	
	match validation_type:
		"folders":
			var folders = validation.get("folders", [])
			
			if folders.is_empty():
				return true
			
			var emulator_path = get_emulator_install_path(emulator_id)
			if emulator_path == "":
				print("[LaunchManager] Post-install validation failed: emulator not found - " + emulator_id)
				return false
			
			var base_dir = emulator_path.get_base_dir()
			var dir = DirAccess.open(base_dir)
			
			if not dir:
				print("[LaunchManager] Post-install validation failed: cannot access base dir - " + base_dir)
				return false
			
			for folder_path in folders:
				if not dir.dir_exists(folder_path):
					print("[LaunchManager] Post-install validation failed: folder not found - " + folder_path)
					return false
			
			if not quiet:
				print("[LaunchManager] Post-install validation passed: all folders exist for " + emulator_id)
			return true
		"files":
			var files_list = validation.get("files", [])
			var path = validation.get("path", "")
			var pattern = validation.get("pattern", "*")
			
			# Use emulator root directory (not executable directory)
			var base_dir = EMULATORS_DIR + emulator_id + "/"
			
			# Case 1: Specific files list
			if not files_list.is_empty():
				for file_entry in files_list:
					var file_name = ""
					if typeof(file_entry) == TYPE_STRING:
						file_name = file_entry
					elif typeof(file_entry) == TYPE_DICTIONARY:
						file_name = file_entry.get("name", "")
					
					if file_name == "":
						continue
					
					var full_path = base_dir + file_name
					if not FileAccess.file_exists(full_path):
						print("[LaunchManager] Post-install validation failed: required file not found - " + file_name)
						return false
				
				if not quiet:
					print("[LaunchManager] Post-install validation passed: all " + str(files_list.size()) + " required files exist")
				return true
			
			# Case 2 & 3: Pattern matching in directory (or any files if pattern is "*")
			elif path != "":
				var full_path = base_dir + path
				
				var dir = DirAccess.open(full_path)
				if not dir:
					if not quiet:
						print("[LaunchManager] Post-install validation failed: directory not found for file check - " + path)
					return false
				
				var file_count = 0
				dir.list_dir_begin()
				var file_name = dir.get_next()
				
				while file_name != "":
					if file_name != "." and file_name != ".." and not dir.current_is_dir():
						if pattern == "*" or file_name.match(pattern):
							file_count += 1
					file_name = dir.get_next()
				
				dir.list_dir_end()
				
				if file_count == 0:
					if not quiet:
						if pattern == "*":
							print("[LaunchManager] Post-install validation failed: no files found in directory - " + path)
						else:
							print("[LaunchManager] Post-install validation failed: no files matching pattern '" + pattern + "' in directory - " + path)
					return false
				
				if not quiet:
					if pattern == "*":
						print("[LaunchManager] Post-install validation passed: found " + str(file_count) + " files in directory - " + path)
					else:
						print("[LaunchManager] Post-install validation passed: found " + str(file_count) + " files matching pattern '" + pattern + "' in directory - " + path)
				return true
			
			return true
		"edit_file":
			var config_file = validation.get("file", "")
			var edits = validation.get("edits", [])
			
			if config_file == "":
				return true
			
			var emulator_path = get_emulator_install_path(emulator_id)
			if emulator_path == "":
				print("[LaunchManager] Post-install validation failed: emulator not found - " + emulator_id)
				return false
			
			var base_dir = emulator_path.get_base_dir()
			var full_path = base_dir + "/" + config_file
			
			if not FileAccess.file_exists(full_path):
				print("[LaunchManager] Post-install validation failed: config file not found - " + config_file)
				return false
			
			if edits.is_empty():
				if not quiet:
					print("[LaunchManager] Post-install validation passed: config file exists for " + emulator_id)
				return true
			
			var file = FileAccess.open(full_path, FileAccess.READ)
			if file == null:
				print("[LaunchManager] Post-install validation failed: cannot read config file - " + config_file)
				return false
			
			var content = file.get_as_text()
			file.close()
			
			for edit in edits:
				var key = edit.get("key", "")
				var expected_value = edit.get("value", "").replace("{emulator_dir}", base_dir)
				
				if key == "":
					continue
				
				var patterns = [
					"(?m)^" + key.regex_escape() + "\\s*:\\s*(.+)$",
					"(?m)^" + key.regex_escape() + "\\s*=\\s*(.+)$"
				]
				
				var found = false
				for pattern in patterns:
					var regex = RegEx.new()
					regex.compile(pattern)
					var match_result = regex.search(content)
					if match_result:
						var actual_value = match_result.get_string(1).strip_edges()
						if actual_value == expected_value:
							found = true
							break
				
				if not found:
					print("[LaunchManager] Post-install validation failed: " + key + " not set correctly in " + config_file)
					return false
			
			if not quiet:
				print("[LaunchManager] Post-install validation passed: config edits verified for " + emulator_id)
			return true
		_:
			print("[LaunchManager] Unknown validation type: " + validation_type)
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
	var post_install_tasks = emulator.get("post_install_tasks", [])
	if not post_install_tasks.is_empty():
		for task in post_install_tasks:
			var validation = task.get("validation", {})
			if not validation.is_empty():
				if not _validate_post_install(emulator_id, validation, true):
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
	
	# Check if this is a cores or download_release extraction
	if item.type == "cores" or item.type == "download_release":
		# Find the emulator this download belongs to
		for emulator_id in _emulator_install_states.keys():
			if item.destination_path.begins_with(EMULATORS_DIR + emulator_id):
				var current_state = get_emulator_install_state(emulator_id)
				if current_state == InstallState.NEEDS_POST_INSTALL:
					_emulator_install_states[emulator_id] = InstallState.ENACTING_POST_INSTALL
					print("[LaunchManager] " + item.type + " extraction started for: " + emulator_id)
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
					# Post-install downloads are handled by unified system
					# Let _on_unified_extraction_completed handle it
					return
				
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
					
					# Check for post-install tasks
					var post_install_tasks = emulator.get("post_install_tasks", [])
					if not post_install_tasks.is_empty():
						# Validate all post-install tasks to see if any are needed
						var all_tasks_valid = true
						var first_invalid_task = -1
						
						for i in range(post_install_tasks.size()):
							var task = post_install_tasks[i]
							var validation = task.get("validation", {})
							
							if not validation.is_empty():
								if not _validate_post_install(emulator_id, validation, true):
									all_tasks_valid = false
									if first_invalid_task == -1:
										first_invalid_task = i
									break
						
						if all_tasks_valid:
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
							# Auto-trigger post-install starting from first invalid task
							_start_post_install(emulator_id, emulator, first_invalid_task)
						return
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

## Called when DownloadManager completes a download
## Cleans up pending game downloads tracking
func _on_download_manager_download_completed(item_id: String, success: bool, message: String):
	# Handle game downloads
	if _pending_game_downloads.has(item_id):
		_pending_game_downloads.erase(item_id)
		if not success:
			print("[LaunchManager] Pending game download failed: " + item_id + " - " + message)
		return
	
	# Post-install downloads are handled by unified system
	# Let _on_unified_download_completed handle it

## Starts the post-install process for an emulator
## @param start_task_index: Index of the first task to execute (default 0)
func _start_post_install(emulator_id: String, emulator: Dictionary, start_task_index: int = 0):
	var post_install_tasks = emulator.get("post_install_tasks", [])
	
	if post_install_tasks.is_empty():
		print("[LaunchManager] No post-install tasks for: " + emulator_id)
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		_emulator_install_progress[emulator_id] = ""
		emulator_extraction_completed.emit(emulator_id, true)
		return
	
	# Store the starting task index
	_emulator_post_install_task_index[emulator_id] = start_task_index
	
	# Start executing tasks from the specified index
	_execute_post_install_task(emulator_id, emulator, start_task_index)

## Executes a specific post-install task and handles the sequence
func _execute_post_install_task(emulator_id: String, emulator: Dictionary, task_index: int):
	var post_install_tasks = emulator.get("post_install_tasks", [])
	
	if task_index >= post_install_tasks.size():
		# All tasks completed successfully
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		_emulator_install_progress[emulator_id] = ""
		_emulator_post_install_task_index.erase(emulator_id)
		print("[LaunchManager] All post-install tasks complete for: " + emulator_id)
		emulator_extraction_completed.emit(emulator_id, true)
		return
	
	var task = post_install_tasks[task_index]
	var task_type = task.get("type", "")
	var total_tasks = post_install_tasks.size()
	
	# Update UI progress
	var task_description = _get_task_description(task_type)
	_emulator_install_progress[emulator_id] = "Post-install task %d of %d: %s" % [task_index + 1, total_tasks, task_description]
	print("[LaunchManager] Starting task %d of %d (%s) for: " % [task_index + 1, total_tasks, task_type] + emulator_id)
	
	# Execute the task based on type
	var task_success = false
	
	match task_type:
		"download_repo", "download_scrape", "download_url":
			# Unified download tasks
			_emulator_install_states[emulator_id] = InstallState.ENACTING_POST_INSTALL
			task_success = _execute_download_task(
				emulator_id,
				"post_install",
				emulator.get("name", emulator_id),
				task,
				func(success: bool, message: String):
					if not success:
						_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
						_emulator_install_progress[emulator_id] = "Task %d failed" % (task_index + 1)
						emulator_extraction_completed.emit(emulator_id, false),
				_pending_post_install_downloads
			)
			
			if task_success:
				# Find the item_id that was just added to track it
				for id in _pending_post_install_downloads.keys():
					if _pending_post_install_downloads[id].emulator_id == emulator_id:
						_pending_post_install_downloads[id].task_index = task_index
						break
			
			return
		"create_folders":
			task_success = _execute_create_folders_task(emulator_id, emulator, task)
		"create_files":
			task_success = _execute_create_files_task(emulator_id, emulator, task)
		"edit_file":
			task_success = _execute_edit_file_task(emulator_id, emulator, task)
		_:
			print("[LaunchManager] Unknown post-install task type '" + task_type + "' for: " + emulator_id)
			task_success = true  # Unknown types are treated as no-op
	
	# Handle task completion (for non-async tasks)
	if task_success:
		_continue_post_install_sequence(emulator_id, emulator)
	else:
		# Task failed - mark as needing post-install again
		_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
		_emulator_install_progress[emulator_id] = "Task %d failed" % (task_index + 1)
		print("[LaunchManager] Task %d failed for: " % (task_index + 1) + emulator_id)
		emulator_extraction_completed.emit(emulator_id, false)

## Continues the post-install sequence after a task completes
## NOTE: Caller should have already validated the completed task before calling this
func _continue_post_install_sequence(emulator_id: String, emulator: Dictionary):
	var current_index = _emulator_post_install_task_index.get(emulator_id, 0)
	var post_install_tasks = emulator.get("post_install_tasks", [])
	
	# Move to next task
	var next_index = current_index + 1
	_emulator_post_install_task_index[emulator_id] = next_index
	
	print("[LaunchManager] Moving from task %d to task %d for: " % [current_index + 1, next_index + 1] + emulator_id)
	
	_execute_post_install_task(emulator_id, emulator, next_index)

## Flattens an extracted directory by moving contents of a single top-level subdirectory up one level
## This handles zips that extract to a nested directory like "Archive-1.0/file.txt" -> "file.txt"
func _flatten_extracted_directory(emulator_id: String, extract_to: String, target_folder: String = ""):
	var extract_path = EMULATORS_DIR + emulator_id + "/" + extract_to
	
	print("[LaunchManager] Starting flatten for: " + emulator_id)
	print("[LaunchManager]   extract_to: '" + extract_to + "'")
	print("[LaunchManager]   extract_path: '" + extract_path + "'")
	print("[LaunchManager]   target_folder: '" + target_folder + "'")
	
	var dir = DirAccess.open(extract_path)
	if not dir:
		print("[LaunchManager] Cannot open extract path for flattening: " + extract_path)
		return
	
	# Debug: List what's in the directory
	print("[LaunchManager] Contents of extract path:")
	var debug_entries = []
	dir.list_dir_begin()
	var debug_file = dir.get_next()
	while debug_file != "":
		if debug_file != "." and debug_file != "..":
			debug_entries.append(debug_file)
			var is_dir = dir.dir_exists(debug_file)
			print("[LaunchManager]   - " + debug_file + (" [DIR]" if is_dir else " [FILE]"))
		debug_file = dir.get_next()
	dir.list_dir_end()
	print("[LaunchManager] Total entries: " + str(debug_entries.size()))
	
	# If a specific target folder is specified, flatten only that one
	if target_folder != "":
		var target_path = extract_path + "/" + target_folder
		
		if not dir.dir_exists(target_folder):
			print("[LaunchManager] Target folder not found for flattening: " + target_folder)
			return
		
		print("[LaunchManager] Flattening target directory: " + target_folder + " -> " + extract_to)
		
		var subdir = DirAccess.open(target_path)
		if not subdir:
			print("[LaunchManager] Warning: Cannot open subdirectory for flattening: " + target_path)
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
					print("[LaunchManager] Warning: Cannot flatten - destination exists: " + item_name)
				else:
					var error = dir.rename(source_path, dest_path)
					if error != OK:
						print("[LaunchManager] Warning: Failed to move " + item_name + " during flattening")
			
			item_name = subdir.get_next()
		subdir.list_dir_end()
		
		# Remove the now-empty subdirectory
		var remove_error = subdir.remove(target_path)
		if remove_error != OK:
			print("[LaunchManager] Warning: Failed to remove empty directory after flattening: " + target_path)
		else:
			print("[LaunchManager] Successfully flattened directory structure")
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
			print("[LaunchManager] Flattening directory: " + single_entry + " -> " + extract_to)
			
			var subdir = DirAccess.open(single_entry_path)
			if not subdir:
				print("[LaunchManager] Warning: Cannot open subdirectory for flattening: " + single_entry_path)
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
						print("[LaunchManager] Warning: Cannot flatten - destination exists: " + item_name)
					else:
						var error = dir.rename(source_path, dest_path)
						if error != OK:
							print("[LaunchManager] Warning: Failed to move " + item_name + " during flattening")
				
				item_name = subdir.get_next()
			subdir.list_dir_end()
			
			# Remove the now-empty subdirectory
			var remove_error = subdir.remove(single_entry_path)
			if remove_error != OK:
				print("[LaunchManager] Warning: Failed to remove empty directory after flattening: " + single_entry_path)
			else:
				print("[LaunchManager] Successfully flattened directory structure")

## Gets a human-readable description for a task type
func _get_task_description(task_type: String) -> String:
	match task_type:
		"cores":
			return "Downloading cores..."
		"download_release":
			return "Downloading firmware..."
		"download_scraped":
			return "Downloading keys..."
		"create_folders":
			return "Creating folders..."
		"create_files":
			return "Creating files..."
		"edit_file":
			return "Editing configuration..."
		_:
			return "Setting up..."

## Executes a create_folders task - returns true if successful
func _execute_create_folders_task(emulator_id: String, emulator: Dictionary, task: Dictionary) -> bool:
	var folders = task.get("folders", [])
	
	if folders.is_empty():
		print("[LaunchManager] No folders to create for: " + emulator_id)
		return true
	
	# Use emulator root directory (same as folders validation)
	var base_dir = EMULATORS_DIR + emulator_id + "/"
	
	for folder_path in folders:
		var full_path = base_dir + folder_path
		var dir = DirAccess.open(base_dir)
		
		if dir and not dir.dir_exists(folder_path):
			var error = dir.make_dir_recursive(folder_path)
			if error != OK:
				push_error("[LaunchManager] Failed to create folder: " + full_path + " (error: " + str(error) + ")")
				return false
			else:
				print("[LaunchManager] Created folder: " + full_path)
		elif not dir:
			push_error("[LaunchManager] Cannot access base directory: " + base_dir)
			return false
		else:
			print("[LaunchManager] Folder already exists: " + full_path)
	
	print("[LaunchManager] Folder creation complete for: " + emulator_id)
	return true

## Executes a create_files task - returns true if successful
func _execute_create_files_task(emulator_id: String, emulator: Dictionary, task: Dictionary) -> bool:
	var files = task.get("files", [])
	
	if files.is_empty():
		print("[LaunchManager] No files to create for: " + emulator_id)
		return true
	
	# Use emulator root directory (same as files validation)
	var base_dir = EMULATORS_DIR + emulator_id + "/"
	
	for file_entry in files:
		var file_name = ""
		var file_content = []
		
		if typeof(file_entry) == TYPE_STRING:
			file_name = file_entry
		elif typeof(file_entry) == TYPE_DICTIONARY:
			file_name = file_entry.get("name", "")
			file_content = file_entry.get("content", [])
		
		if file_name == "":
			continue
		
		var full_path = base_dir + file_name
		
		if not FileAccess.file_exists(full_path):
			var file = FileAccess.open(full_path, FileAccess.WRITE)
			if file == null:
				push_error("[LaunchManager] Failed to create file: " + full_path + " (error: " + str(FileAccess.get_open_error()) + ")")
				return false
			else:
				for line in file_content:
					file.store_line(line)
				file.close()
				print("[LaunchManager] Created file: " + full_path)
		else:
			print("[LaunchManager] File already exists: " + full_path)
	
	print("[LaunchManager] File creation complete for: " + emulator_id)
	return true

## Executes an edit_file task - returns true if successful
func _execute_edit_file_task(emulator_id: String, emulator: Dictionary, task: Dictionary) -> bool:
	var config_file = task.get("file", "")
	var edits = task.get("edits", [])
	
	if config_file == "" or edits.is_empty():
		print("[LaunchManager] No config file or edits specified for: " + emulator_id)
		return true
	
	var emulator_path = get_emulator_install_path(emulator_id)
	if emulator_path == "":
		push_error("[LaunchManager] Cannot find emulator path for file edit: " + emulator_id)
		return false
	
	var base_dir = emulator_path.get_base_dir()
	var full_path = base_dir + "/" + config_file
	
	if not FileAccess.file_exists(full_path):
		push_error("[LaunchManager] Config file not found: " + full_path)
		return false
	
	var file = FileAccess.open(full_path, FileAccess.READ)
	if file == null:
		push_error("[LaunchManager] Failed to open config file: " + full_path)
		return false
	
	var content = file.get_as_text()
	file.close()
	
	for edit in edits:
		# Check if this is a raw content edit (for TOML sections, etc.)
		var raw_content = edit.get("content", "")
		if raw_content != "":
			# Globalize the path for native compatibility
			var global_base_dir = ProjectSettings.globalize_path(base_dir)
			raw_content = raw_content.replace("{emulator_dir}", global_base_dir)
			# Check if this content already exists
			if not content.contains(raw_content.strip_edges()):
				content += "\n" + raw_content
				print("[LaunchManager] Added content section to " + config_file)
			continue
		
		# Otherwise, treat as key-value edit
		var key = edit.get("key", "")
		var value = edit.get("value", "")
		
		if key == "":
			continue
		
		# Globalize the path for native compatibility
		var global_base_dir = ProjectSettings.globalize_path(base_dir)
		value = value.replace("{emulator_dir}", global_base_dir)
		
		var patterns = [
			"(?m)^(" + key.regex_escape() + ")\\s*:\\s*.*$",
			"(?m)^(" + key.regex_escape() + ")\\s*=\\s*.*$"
		]
		
		var replaced = false
		for pattern in patterns:
			var regex = RegEx.new()
			regex.compile(pattern)
			var new_content = regex.sub(content, "$1: " + value, true)
			if new_content != content:
				content = new_content
				replaced = true
				print("[LaunchManager] Updated " + key + " in " + config_file)
				break
		
		if not replaced:
			content += "\n" + key + ": " + value
			print("[LaunchManager] Added " + key + " to " + config_file)
	
	file = FileAccess.open(full_path, FileAccess.WRITE)
	if file == null:
		push_error("[LaunchManager] Failed to write config file: " + full_path)
		return false
	
	file.store_string(content)
	file.close()
	
	print("[LaunchManager] Config edit complete for: " + emulator_id)
	return true

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
	var root_folder = SettingsManager.get_setting("games_root_folder")
	var root_path = root_folder.value if root_folder else "user://games"
	# Construct the full file path from known components (don't rely on file_path which may be relative)
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
		
		# Set working directory only if emulator requires it (e.g., xemu)
		if emulator.get("requires_working_dir", false):
			intent.working_directory = install_dir
		
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
	
	# Controller configuration temporarily disabled - need to solve SDL device index mapping
	# TODO: Re-enable when SDL device index detection is implemented
	# Configure controllers for this emulator before launching
	# var should_continue = await _configure_emulator_controllers(intent)
	# if not should_continue:
	# 	print("[LaunchManager] Controller configuration cancelled, aborting launch")
	# 	return false
	
	if PlatformManager.is_android():
		return _execute_android(intent)
	else:
		print("[LaunchManager] Calling _execute_desktop")
		return _execute_desktop(intent)

func _execute_desktop(intent: LaunchIntent) -> bool:
	print("[LaunchManager] _execute_desktop starting")
	
	if intent.launch_args.is_empty():
		push_error("[LaunchManager] No launch arguments for desktop")
		return false
	
	print("[LaunchManager] Got launch args: " + str(intent.launch_args.size()) + " arguments")
	
	var exe_path = intent.launch_args[0]
	var arguments = intent.launch_args.slice(1)
	
	# Debug: Print the full command
	var full_command = exe_path + " " + " ".join(arguments)
	print("[LaunchManager] Full launch command: " + full_command)
	print("[LaunchManager] Working directory: " + intent.working_directory)
	
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
			print("[LaunchManager] Shell command: cmd /c \"" + inner_cmd + "\"")
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
		else:
			# Linux/macOS: use sh -c "cd WORKING_DIR && exe args"
			var inner_cmd = 'cd "%s" && "%s" %s' % [
				intent.working_directory,
				exe_path,
				" ".join(quoted_args)
			]
			print("[LaunchManager] Shell command: sh -c \"" + inner_cmd + "\"")
			pid = OS.create_process("sh", ["-c", inner_cmd], false)
	else:
		# No working directory specified, launch directly
		pid = OS.create_process(exe_path, arguments, false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to launch process: " + exe_path)
		launch_completed.emit(false, "Failed to start emulator")
		return false
	
	print("[LaunchManager] Launched process with PID: " + str(pid))
	launch_completed.emit(true, "Game launched successfully")
	print("[LaunchManager] _execute_desktop returning true")
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
		print("[LaunchManager] Controller registry not found")
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
			print("[LaunchManager] Controller config valid: " + file_path)
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
	
	print("[LaunchManager] Controller config needs update: " + file_path)
	print("[LaunchManager] Showing dialog for: " + emulator_name)
	
	# Use dictionary for reference semantics (lambdas capture by value)
	var dialog_state = {"confirmed": false, "responded": false}
	
	var on_confirmed = func():
		print("[LaunchManager] Dialog: User confirmed")
		dialog_state.confirmed = true
		dialog_state.responded = true
	
	var on_canceled = func():
		print("[LaunchManager] Dialog: User canceled")
		dialog_state.confirmed = false
		dialog_state.responded = true
	
	dialog.confirmed.connect(on_confirmed)
	dialog.canceled.connect(on_canceled)
	
	# Show dialog after signals are connected
	dialog.popup_centered()
	
	print("[LaunchManager] Waiting for dialog response...")
	
	# Wait for response
	while not dialog_state.responded:
		await get_tree().process_frame
	
	print("[LaunchManager] Dialog closed, confirmed=" + str(dialog_state.confirmed))
	
	var confirmed = dialog_state.confirmed
	
	# Clean up
	dialog.queue_free()
	
	if not confirmed:
		print("[LaunchManager] User skipped controller update for: " + file_path)
		return true  # Continue with launch
	
	# Apply edits
	print("[LaunchManager] Applying controller config update for: " + file_path)
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
	
	print("[LaunchManager] Updated controller config: " + file_path)

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
	
	# If game is not downloaded, queue the download first then proceed
	if not game.is_active_variant_downloaded():
		_queue_game_download_then_launch(game)
		return
	
	# Game is downloaded, proceed with launch
	_launch_with_emulator_check(game)
	
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
	
	print("[LaunchManager] Updated last_played for '%s' to %s" % [game.get_display_name(), timestamp])
	
	# Notify views that game was launched (so they can re-sort)
	game_launched.emit(game)

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
	var current_state = get_emulator_install_state(emulator_id)
	
	if current_state == InstallState.INSTALLED:
		print("[LaunchManager] Emulator already installed: " + emulator_id)
		return false
	
	if current_state in [InstallState.DOWNLOADING, InstallState.EXTRACTING, 
						InstallState.ENACTING_POST_INSTALL]:
		print("[LaunchManager] Emulator already downloading/installing: " + emulator_id)
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
		print("[LaunchManager] All install steps complete for: " + emulator_id)
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		return true
	
	var step = install_steps[step_index]
	var step_name = step.get("step", "")
	var platforms = step.get("platforms", {})
	
	print("[LaunchManager] Executing step " + str(step_index) + ": " + step_name)
	
	# Get platform config
	var platform_config = platforms.get("all", {})
	if platform_config.is_empty():
		platform_config = platforms.get(platform_name, {})
	
	if platform_config.is_empty():
		push_error("[LaunchManager] No platform config for step '" + step_name + "' on platform: " + platform_name)
		return false
	
	var action_type = platform_config.get("action_type", "")
	
	# Handle download_url action
	if action_type == "download_url":
		var url = platform_config.get("url", "")
		if url == "":
			push_error("[LaunchManager] No download URL for step '" + step_name + "'")
			return false
		
		# Create step-specific display name for notifications
		var step_display_name = _get_step_display_name(step_name)
		_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config)
		return true
	
	# Handle download_repo action
	elif action_type == "download_repo":
		var github_repo = platform_config.get("github_repo", "")
		var asset_pattern = platform_config.get("asset_pattern", "")
		
		if github_repo == "" or asset_pattern == "":
			push_error("[LaunchManager] Invalid download_repo config for step: " + step_name)
			return false
		
		_emulator_install_states[emulator_id] = InstallState.DOWNLOADING
		_emulator_install_progress[emulator_id] = "Fetching release info..."
		
		# Create step-specific display name for notifications
		var step_display_name = _get_step_display_name(step_name)
		
		NetworkManager.fetch_github_latest_release(
			github_repo,
			asset_pattern,
			func(url: String, error: String):
				if error != "":
					push_error("[LaunchManager] Failed to fetch GitHub release: " + error)
					_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
					return
				_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config)
		)
		return true
	
	# Handle extract action
	elif action_type == "extract":
		return _execute_extract_step(emulator_id, step_index, platform_config)
	
	# Handle apk_install action (Android only)
	elif action_type == "apk_install":
		return _execute_apk_install_step(emulator_id, step_index, platform_config)
	
	# Handle none action (skip)
	elif action_type == "none":
		print("[LaunchManager] Skipping step '" + step_name + "' (action_type: none)")
		return _execute_install_step(emulator_id, step_index + 1)
	
	push_error("[LaunchManager] Unknown action_type '" + action_type + "' for step: " + step_name)
	return false

## Executes APK install action for a step (Android only)
func _execute_apk_install_step(emulator_id: String, step_index: int, apk_config: Dictionary) -> bool:
	print("[LaunchManager] Executing APK install step...")
	
	var package_name = apk_config.get("package_name", "")
	
	if package_name == "":
		push_error("[LaunchManager] No package_name specified for apk_install")
		return false
	
	print("[LaunchManager] APK install config:")
	print("[LaunchManager]   - package_name: '" + package_name + "'")
	
	# Find the downloaded APK from the previous download step
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Get previous step (should be download)
	if step_index == 0:
		push_error("[LaunchManager] Cannot install APK - no previous download step")
		return false
	
	var prev_step = install_steps[step_index - 1]
	var prev_platforms = prev_step.get("platforms", {})
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var prev_config = prev_platforms.get("all", {})
	if prev_config.is_empty():
		prev_config = prev_platforms.get(platform_name, {})
	
	var download_url = prev_config.get("url", "")
	if download_url == "":
		push_error("[LaunchManager] Cannot install APK - no download URL from previous step")
		return false
	
	var filename = download_url.get_file()
	var apk_path = EMULATORS_DIR + emulator_id + "/" + filename
	
	# Convert user:// path to absolute path for Android
	var absolute_apk_path = ProjectSettings.globalize_path(apk_path)
	
	print("[LaunchManager] Installing APK: " + apk_path)
	print("[LaunchManager] Absolute path: " + absolute_apk_path)
	
	# Check if file exists
	if not FileAccess.file_exists(apk_path):
		push_error("[LaunchManager] APK file not found: " + apk_path)
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		return false
	
	# Use OS.shell_open with proper Android intent format
	# Try different approaches for Android
	var uri = "file://" + absolute_apk_path
	print("[LaunchManager] Opening APK with URI: " + uri)
	
	# Try to open the APK for installation
	# Note: On Android, this requires:
	# 1. Kyodai to have "Install unknown apps" permission in Android Settings
	# 2. The install_packages permission in the manifest
	var result = OS.shell_open(uri)
	
	if result != Error.OK:
		print("[LaunchManager] Direct APK install failed with error: " + str(result))
		print("[LaunchManager] This usually means Kyodai doesn't have permission to install APKs")
		
		# Show user-friendly message about manual installation
		NotificationManager.show_notification(
			"RetroArch APK downloaded!\nPlease install it manually from:\n" + absolute_apk_path,
			Notification.Type.WARNING,
			null,  # icon
			10.0   # Show for 10 seconds
		)
		
		# Try to open the folder so user can find the APK
		var folder_path = ProjectSettings.globalize_path(EMULATORS_DIR + emulator_id)
		print("[LaunchManager] Attempting to open folder: " + folder_path)
		var folder_result = OS.shell_open(folder_path)
		
		if folder_result == Error.OK:
			print("[LaunchManager] Opened folder containing APK")
		else:
			print("[LaunchManager] Could not open folder either: " + str(folder_result))
		
		# Mark as installed anyway - user will install manually
		# Next time the app launches, validation will check if it's actually installed
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		print("[LaunchManager] Marked as installed - awaiting manual APK installation")
		
		# Progress to next step
		_execute_install_step(emulator_id, step_index + 1)
		return true
	else:
		print("[LaunchManager] APK installer opened successfully!")
		print("[LaunchManager] User should see Android install dialog")
	
	# Mark as installing - user needs to complete the install via Android UI
	_emulator_install_states[emulator_id] = InstallState.INSTALLED
	
	# Validate installation (check if package is installed)
	var validate_config = apk_config.get("validate", {})
	if not _validate_step(emulator_id, validate_config):
		print("[LaunchManager] Warning: APK validation failed - package may not be installed yet")
		# Don't fail here - user might still be installing
	
	# Progress to next step
	_execute_install_step(emulator_id, step_index + 1)
	return true

## Executes extract action for a step
func _execute_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary) -> bool:
	print("[LaunchManager] Executing extract step...")
	
	var extract_to = extract_config.get("extract_to", ".")
	var strip_top = extract_config.get("strip_top_directory", false)
	var flatten_target = extract_config.get("flatten_target", "")
	
	print("[LaunchManager] Extract config:")
	print("[LaunchManager]   - extract_to: '" + extract_to + "'")
	print("[LaunchManager]   - strip_top_directory: " + str(strip_top))
	print("[LaunchManager]   - flatten_target: '" + flatten_target + "'")
	
	# Find the downloaded file from the previous download step
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Get previous step (should be download)
	if step_index == 0:
		push_error("[LaunchManager] Cannot extract - no previous download step")
		return false
	
	var prev_step = install_steps[step_index - 1]
	var prev_platforms = prev_step.get("platforms", {})
	var prev_config = prev_platforms.get("all", {})
	if prev_config.is_empty():
		prev_config = prev_platforms.get(PlatformManager.get_platform_name().to_lower(), {})
	
	var download_url = prev_config.get("url", "")
	if download_url == "":
		push_error("[LaunchManager] Cannot extract - no download URL from previous step")
		return false
	
	var filename = download_url.get_file()
	var archive_path = EMULATORS_DIR + emulator_id + "/" + filename
	
	# Handle extract_to: absolute paths are used directly, relative paths are relative to emulator dir
	var extract_dir: String
	if extract_to.begins_with("/"):
		# Absolute path (e.g., Android /storage/emulated/0/...)
		extract_dir = extract_to
	else:
		# Relative path (default behavior for desktop)
		extract_dir = EMULATORS_DIR + emulator_id + "/" + extract_to
	
	print("[LaunchManager] Extracting archive: " + archive_path)
	print("[LaunchManager] Extract to: " + extract_dir)
	
	# Get step name from install_steps for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var step_display_name = _get_step_display_name(step_name)
	
	_emulator_install_states[emulator_id] = InstallState.EXTRACTING
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Queue extraction via DownloadManager
	var item_id = DownloadManager.queue_extraction(archive_path, extract_dir, "emulator", step_display_name)
	if item_id == "":
		push_error("[LaunchManager] Failed to queue extraction for: " + emulator_id)
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		return false
	
	# Track extraction completion
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "extraction",
		"step_index": step_index,
		"step_config": extract_config,
		"callback": func(success: bool, message: String):
			if not success:
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				_emulator_install_progress[emulator_id] = "Extraction failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Handle post-extraction flattening
			if strip_top:
				print("[LaunchManager] Flattening directory...")
				_flatten_extracted_directory(emulator_id, extract_to, flatten_target)
			
			# Validate extraction
			var validate_config = extract_config.get("validate", {})
			if not _validate_step(emulator_id, validate_config):
				push_error("[LaunchManager] Validation failed after extraction: " + emulator_id)
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				_emulator_install_progress[emulator_id] = "Validation failed"
				emulator_extraction_completed.emit(emulator_id, false)
				return
			
			print("[LaunchManager] Extraction complete and validated for: " + emulator_id)
			
			# Progress to next step
			_execute_install_step(emulator_id, step_index + 1)
	}
	
	return true

## Validates a step result based on validation config
## Resolves a path for validation - uses absolute paths directly, relative paths are relative to emulator dir
func _resolve_validation_path(emulator_id: String, path: String) -> String:
	if path.begins_with("/"):
		# Absolute path - use as-is
		return path
	else:
		# Relative path - prepend emulator directory
		return EMULATORS_DIR + emulator_id + "/" + path

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
			var exists = FileAccess.file_exists(full_path)
			print("[LaunchManager] Validation: file_exists '" + file_path + "' -> '" + full_path + "' = " + str(exists))
			return exists
		
		"folder_exists":
			var folder_path = validate_config.get("path", "")
			if folder_path == "":
				return true
			var full_path = _resolve_validation_path(emulator_id, folder_path)
			var dir = DirAccess.open(full_path)
			var exists = dir != null
			print("[LaunchManager] Validation: folder_exists '" + folder_path + "' -> '" + full_path + "' = " + str(exists))
			return exists
		
		"files_exist":
			var folder_path = validate_config.get("path", "")
			var pattern = validate_config.get("pattern", "")
			
			if folder_path == "":
				return true
			
			var full_path = _resolve_validation_path(emulator_id, folder_path)
			var dir = DirAccess.open(full_path)
			
			if not dir:
				print("[LaunchManager] Validation: files_exist '" + folder_path + "' - directory not found")
				return false
			
			var found_files = false
			dir.list_dir_begin()
			var file_name = dir.get_next()
			
			while file_name != "":
				if file_name != "." and file_name != "..":
					if pattern == "" or file_name.match(pattern):
						found_files = true
						break
				file_name = dir.get_next()
			
			dir.list_dir_end()
			print("[LaunchManager] Validation: files_exist '" + folder_path + "' -> '" + full_path + "' pattern '" + pattern + "' = " + str(found_files))
			return found_files
		
		"package_installed":
			# Check if an Android package is installed
			var package = validate_config.get("package", "")
			if package == "":
				return true
			
			# On Android, we can check by attempting to query the package
			# Try to launch the app with a view intent - if it opens, it's installed
			if PlatformManager.is_android():
				# Create a simple intent to check if package exists
				var check_uri = "intent:#Intent;action=android.intent.action.MAIN;package=" + package + ";end"
				var result = OS.shell_open(check_uri)
				var is_installed = (result == Error.OK)
				print("[LaunchManager] Validation: package_installed '" + package + "' = " + str(is_installed))
				return is_installed
			else:
				# On desktop, always return true (package concept doesn't apply)
				return true
		
		"always_pass":
			return true
		
		_:
			print("[LaunchManager] Unknown validation action_type: " + action_type)
			return false

## Executes install steps from new step-based format (entry point)
func _execute_install_steps(emulator_id: String, emulator: Dictionary, install_steps: Array) -> bool:
	print("[LaunchManager] Starting install flow for: " + emulator_id)
	print("[LaunchManager] Total steps: " + str(install_steps.size()))
	return _execute_install_step(emulator_id, 0)

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

## Validates a specific install step to check if it's complete
## Returns true if the step validation passes (step is complete)
func _validate_install_step(emulator_id: String, step_index: int, install_steps: Array) -> bool:
	if step_index >= install_steps.size():
		return true
	
	var step = install_steps[step_index]
	var step_name = step.get("step", "")
	var platforms = step.get("platforms", {})
	
	# Get platform config
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var platform_config = platforms.get("all", {})
	if platform_config.is_empty():
		platform_config = platforms.get(platform_name, {})
	
	if platform_config.is_empty():
		return false
	
	var action_type = platform_config.get("action_type", "")
	var validate_config = platform_config.get("validate", {})
	
	# If no validation config, assume step needs to be run
	if validate_config.is_empty():
		return false
	
	# Run validation
	var is_valid = _validate_step(emulator_id, validate_config)
	print("[LaunchManager] Step validation '" + step_name + "' (index " + str(step_index) + "): " + str(is_valid))
	return is_valid

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
	
	if install_steps.is_empty():
		# Legacy format - check old validation
		result["is_installed"] = validate_emulator_installation(emulator_id)
		result["status"] = "complete" if result["is_installed"] else "not_started"
		return result
	
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
	
	print("[LaunchManager] Install progress for '" + emulator_id + "': " + 
		str(result["completed_steps"]) + "/" + str(result["total_steps"]) + 
		" steps, next: " + result["next_step_display"])
	
	return result

## Scans emulator installation and updates state based on step completion
## Call this when opening platform page to refresh state
func scan_emulator_install_state(emulator_id: String):
	var progress = get_install_progress(emulator_id)
	
	if progress["status"] == "complete":
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		_emulator_install_progress[emulator_id] = ""
	elif progress["status"] == "partial":
		# Mark as partial - UI will show "Resume: [Step Name]"
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		_emulator_install_progress[emulator_id] = "Resume: " + progress["next_step_display"]
	else:
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		_emulator_install_progress[emulator_id] = ""
	
	print("[LaunchManager] Scanned '" + emulator_id + "': state=" + 
		str(_emulator_install_states[emulator_id]) + 
		", progress=" + _emulator_install_progress[emulator_id])

## Legacy unified download - kept for reference but not used
func _queue_emulator_download(emulator_id: String, emulator_name: String, step_display_name: String, download_url: String, step_index: int, step_config: Dictionary = {}):
	var filename = download_url.get_file()
	var destination_path = EMULATORS_DIR + emulator_id + "/" + filename
	
	_emulator_install_states[emulator_id] = InstallState.DOWNLOADING
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	print("[LaunchManager] Queueing emulator download: " + emulator_id + " from " + download_url)
	print("[LaunchManager] Step index: " + str(step_index))
	print("[LaunchManager] Display name: " + step_display_name)
	
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
		_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
		return
	
	# Track download with step info for sequential execution
	_pending_emulator_downloads[item_id] = {
		"emulator_id": emulator_id,
		"context": "emulator",
		"step_index": step_index,
		"step_config": step_config,
		"callback": func(success: bool, message: String):
			if not success:
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				_emulator_install_progress[emulator_id] = message if message != "" else "Download failed"
				emulator_extraction_completed.emit(emulator_id, false)
	}

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
	
	var post_install_tasks = emulator.get("post_install_tasks", [])
	if post_install_tasks.is_empty():
		print("[LaunchManager] No post-install configured for: " + emulator_id)
		return false
	
	print("[LaunchManager] Completing post-install for: " + emulator_id)
	
	# Find the first task that needs to be run (validation fails)
	var first_invalid_task = 0
	for i in range(post_install_tasks.size()):
		var task = post_install_tasks[i]
		var validation = task.get("validation", {})
		
		if not validation.is_empty():
			if not _validate_post_install(emulator_id, validation, true):
				first_invalid_task = i
				break
			first_invalid_task = i + 1
	
	_start_post_install(emulator_id, emulator, first_invalid_task)
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


## Unified download task execution
## Handles download_repo, download_scrape, and download_url for both emulator and post-install
func _execute_download_task(emulator_id: String, context: String, item_name: String, download_config: Dictionary, callback: Callable, pending_tracker: Dictionary) -> bool:
	var download_type = download_config.get("type", "")
	
	match download_type:
		"download_repo":
			return _execute_download_repo(emulator_id, context, item_name, download_config, callback, pending_tracker)
		"download_scrape":
			return _execute_download_scrape(emulator_id, context, item_name, download_config, callback, pending_tracker)
		"download_url":
			return _execute_download_url(emulator_id, context, item_name, download_config, callback, pending_tracker)
		_:
			push_error("[LaunchManager] Unknown download type: " + download_type)
			return false

## Executes a download_repo task - fetches from GitHub releases
func _execute_download_repo(emulator_id: String, context: String, item_name: String, download_config: Dictionary, callback: Callable, pending_tracker: Dictionary) -> bool:
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var github_repo = download_config.get("github_repo", "")
	var asset_pattern = download_config.get("asset_pattern", "")
	
	if asset_pattern == "":
		var asset_patterns = download_config.get("asset_patterns", {})
		asset_pattern = asset_patterns.get(platform_name, "")
	
	if github_repo == "" or asset_pattern == "":
		push_error("[LaunchManager] No github_repo or asset_pattern specified for download_repo")
		return false
	
	var release_tag = download_config.get("release_tag", "")
	
	print("[LaunchManager] Starting download_repo for: " + emulator_id + " (" + context + ")")
	
	NetworkManager.fetch_github_latest_release(
		github_repo,
		asset_pattern,
		func(download_url: String, error: String):
			if error != "":
				callback.call(false, error)
				return
			_execute_download_from_url(emulator_id, context, item_name, download_config, download_url, callback, pending_tracker),
		release_tag
	)
	
	return true

## Executes a download_scrape task - scrapes webpage for version
func _execute_download_scrape(emulator_id: String, context: String, item_name: String, download_config: Dictionary, callback: Callable, pending_tracker: Dictionary) -> bool:
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var scrape_url = download_config.get("scrape_url", "")
	var version_pattern = download_config.get("version_pattern", "")
	var url_template = download_config.get("url_template", "")
	
	if url_template == "":
		var url_templates = download_config.get("url_templates", {})
		url_template = url_templates.get(platform_name, "")
	
	if scrape_url == "" or version_pattern == "" or url_template == "":
		push_error("[LaunchManager] Invalid scrape config for download_scrape")
		return false
	
	print("[LaunchManager] Starting download_scrape for: " + emulator_id)
	
	NetworkManager.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(download_url: String, error: String):
			if error != "":
				callback.call(false, error)
				return
			_execute_download_from_url(emulator_id, context, item_name, download_config, download_url, callback, pending_tracker)
	)
	
	return true

## Executes a download_url task - uses hardcoded URL
func _execute_download_url(emulator_id: String, context: String, item_name: String, download_config: Dictionary, callback: Callable, pending_tracker: Dictionary) -> bool:
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var url = download_config.get("url", "")
	
	if url == "":
		var urls = download_config.get("urls", {})
		url = urls.get(platform_name, "")
	
	if url == "":
		push_error("[LaunchManager] No URL specified for download_url")
		return false
	
	print("[LaunchManager] Starting download_url for: " + emulator_id)
	
	return _execute_download_from_url(emulator_id, context, item_name, download_config, url, callback, pending_tracker)

## Core download execution - queues download with DownloadManager
func _execute_download_from_url(emulator_id: String, context: String, item_name: String, download_config: Dictionary, download_url: String, callback: Callable, pending_tracker: Dictionary) -> bool:
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var should_extract = download_config.get("extract", true)
	var extract_to = download_config.get("extract_to", "")
	var strip_top = download_config.get("strip_top_directory", false)
	var filename = download_config.get("filename", "")
	
	if filename == "":
		var filenames = download_config.get("filenames", {})
		filename = filenames.get(platform_name, "")
	
	if filename == "":
		filename = download_url.get_file()
	
	var destination_path = EMULATORS_DIR + emulator_id + "/" + filename
	
	print("[LaunchManager] Download URL: " + download_url)
	print("[LaunchManager] Extract: " + str(should_extract))
	
	var dm_type = "emulator" if context == "emulator" else "download_" + download_config.get("type", "unknown")
	
	if should_extract:
		var extract_destination = EMULATORS_DIR + emulator_id + "/" + extract_to
		
		var item_id = DownloadManager.queue_download(
			download_url,
			destination_path,
			dm_type,
			item_name,
			true,
			extract_destination
		)
		
		if item_id == "":
			callback.call(false, "Failed to queue download")
			return false
		
		pending_tracker[item_id] = {
			"emulator_id": emulator_id,
			"context": context,
			"extract_to": extract_to,
			"strip_top_directory": strip_top,
			"flatten_target": download_config.get("flatten_target", ""),
			"callback": callback
		}
		
		return true
	else:
		var item_id = DownloadManager.queue_download(
			download_url,
			destination_path,
			dm_type,
			item_name,
			false
		)
		
		if item_id == "":
			callback.call(false, "Failed to queue download")
			return false
		
		pending_tracker[item_id] = {
			"emulator_id": emulator_id,
			"context": context,
			"destination_path": destination_path,
			"callback": callback
		}
		
		return true

## Handles download completion
func _on_unified_download_completed(item_id: String, success: bool, message: String):
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		var emulator_id = task_info.emulator_id
		var step_index = task_info.get("step_index", 0)
		var step_config = task_info.get("step_config", {})
		_pending_emulator_downloads.erase(item_id)
		
		if not success:
			print("[LaunchManager] Download failed for: " + emulator_id)
			_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
			_emulator_install_progress[emulator_id] = "Download failed: " + message
			emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, message)
			return
		
		print("[LaunchManager] Download completed for: " + emulator_id + " (step " + str(step_index) + ")")
		
		# Validate download if validation config exists
		var validate_config = step_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[LaunchManager] Download validation failed for: " + emulator_id)
			_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
			_emulator_install_progress[emulator_id] = "Download validation failed"
			emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Validation failed")
			return
		
		print("[LaunchManager] Download validated, progressing to next step...")
		
		# Progress to next step
		_execute_install_step(emulator_id, step_index + 1)
		return

## Handles extraction completion
func _on_unified_extraction_completed(item_id: String, success: bool, extract_dir: String):
	if _pending_emulator_downloads.has(item_id):
		var task_info = _pending_emulator_downloads[item_id]
		var emulator_id = task_info.emulator_id
		var context = task_info.get("context", "")
		
		if context == "extraction":
			# Handled in the callback within _execute_extract_step
			_pending_emulator_downloads.erase(item_id)
			task_info.callback.call(success, "Extraction " + ("complete" if success else "failed"))
			return
		
		_pending_emulator_downloads.erase(item_id)
		
		# Check if executable exists
		if not validate_emulator_executable(emulator_id):
			push_error("[LaunchManager] Validation failed - executable not found after extraction: " + emulator_id)
			_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
			_emulator_install_progress[emulator_id] = "Validation failed - executable missing"
			emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Executable not found")
			return
		
		print("[LaunchManager] Validation passed - executable found for: " + emulator_id)
		
		# Check for post-install tasks
		var emulator = get_emulator(emulator_id)
		if not emulator.is_empty():
			var post_install_tasks = emulator.get("post_install_tasks", [])
			if not post_install_tasks.is_empty():
				# Validate all post-install tasks to see if any are needed
				var all_tasks_valid = true
				var first_invalid_task = -1
				
				for i in range(post_install_tasks.size()):
					var task = post_install_tasks[i]
					var validation = task.get("validation", {})
					
					if not validation.is_empty():
						if not _validate_post_install(emulator_id, validation, true):
							all_tasks_valid = false
							if first_invalid_task == -1:
								first_invalid_task = i
							break
				
				if all_tasks_valid:
					# Post-install already complete
					_emulator_install_states[emulator_id] = InstallState.INSTALLED
					_emulator_install_progress[emulator_id] = ""
					print("[LaunchManager] Installation complete (post-install already done): " + emulator_id)
					emulator_extraction_completed.emit(emulator_id, true)
					task_info.callback.call(true, "")
				else:
					# Need to do post-install - set state and trigger it
					_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
					_emulator_install_progress[emulator_id] = "Post-install required"
					print("[LaunchManager] Main extraction complete, post-install needed: " + emulator_id)
					emulator_extraction_completed.emit(emulator_id, true)
					# Auto-trigger post-install starting from first invalid task
					_start_post_install(emulator_id, emulator, first_invalid_task)
					task_info.callback.call(true, "")
				return
		
		# No post-install needed
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		_emulator_install_progress[emulator_id] = ""
		print("[LaunchManager] Installation complete: " + emulator_id)
		emulator_extraction_completed.emit(emulator_id, true)
		task_info.callback.call(true, "")
		return
	
	if _pending_post_install_downloads.has(item_id):
		var task_info = _pending_post_install_downloads[item_id]
		_pending_post_install_downloads.erase(item_id)
		
		var emulator_id = task_info.emulator_id
		var task_index = task_info.get("task_index", -1)
		
		if not success:
			_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
			emulator_extraction_completed.emit(emulator_id, false)
			return
		
		# Flatten directory structure if needed
		if task_info.get("strip_top_directory", false):
			var flatten_target = task_info.get("flatten_target", "")
			var extract_to = task_info.get("extract_to", ".")
			_flatten_extracted_directory(emulator_id, extract_to, flatten_target)
		
		var emulator = get_emulator(emulator_id)
		if emulator.is_empty():
			_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
			emulator_extraction_completed.emit(emulator_id, false)
			return
		
		# Get the task that was completed and validate it
		var post_install_tasks = emulator.get("post_install_tasks", [])
		if task_index >= 0 and task_index < post_install_tasks.size():
			var task = post_install_tasks[task_index]
			var validation = task.get("validation", {})
			
			if not validation.is_empty():
				if not _validate_post_install(emulator_id, validation):
					_emulator_install_states[emulator_id] = InstallState.NEEDS_POST_INSTALL
					_emulator_install_progress[emulator_id] = "Task %d validation failed" % (task_index + 1)
					print("[LaunchManager] Task %d validation failed for: " % (task_index + 1) + emulator_id)
					emulator_extraction_completed.emit(emulator_id, false)
					return
			
			print("[LaunchManager] Task %d validated successfully for: " % (task_index + 1) + emulator_id)
		
		# Task completed and validated - continue to next task
		_continue_post_install_sequence(emulator_id, emulator)
