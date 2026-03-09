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
	
	# DEBUG: Test PackageChecker plugin
	if OS.get_name() == "Android":
		print("[DEBUG] Godot version: ", Engine.get_version_info())
		print("[DEBUG] Checking PackageChecker plugin...")
		print("[DEBUG] All singletons: ", Engine.get_singleton_list())
		
		# Try different variations of the name
		var possible_names = ["PackageChecker", "packagechecker", "com.heckpoint.kyodai.PackageChecker"]
		var found = false
		for name in possible_names:
			if Engine.has_singleton(name):
				print("[DEBUG] Found plugin as: ", name)
				var plugin = Engine.get_singleton(name)
				print("[DEBUG] Plugin object: ", plugin)
				found = true
				break
		
		if not found:
			print("[DEBUG] PackageChecker plugin NOT found with any name variant")
			print("[DEBUG] Total singletons count: ", Engine.get_singleton_list().size())
	else:
		print("[DEBUG] Not on Android - plugin check skipped")

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
					
					# Mark as installed
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

## Flattens an extracted directory by moving contents of a single top-level subdirectory up one level
## This handles zips that extract to a nested directory like "Archive-1.0/file.txt" -> "file.txt"
func _flatten_extracted_directory(emulator_id: String, extract_to: String, target_folder: String = ""):
	# Android uses absolute paths, Desktop uses relative paths
	var extract_path: String
	if PlatformManager.is_android():
		extract_path = extract_to
	else:
		extract_path = EMULATORS_DIR + emulator_id + "/" + extract_to
	
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
	
	# Use the actual file_path from game resource (contains content:// URI for SAF on Android)
	# Only fall back to constructing path if file_path is empty
	if game.file_path != "":
		intent.rom_path = game.file_path
		print("[LaunchManager] Using stored file_path: " + intent.rom_path)
	else:
		# Fallback: construct path from components (for legacy or if file_path not set)
		var root_folder = SettingsManager.get_setting("games_root_folder")
		var root_path = root_folder.value if root_folder else "user://games"
		intent.rom_path = root_path + "/" + game.platform_slug + "/" + active_file_name
		print("[LaunchManager] Constructed fallback path: " + intent.rom_path)
	
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
		print("[LaunchManager] Vita3K detected - preparing game...")
		var vita_ready = await _prepare_vita3k_game(game, intent)
		if not vita_ready:
			push_error("[LaunchManager] Failed to prepare Vita3K game: " + game.get_display_name())
			NotificationManager.show_notification("Failed to prepare Vita game", Notification.Type.ERROR)
			return null
		print("[LaunchManager] Vita3K game ready")
	
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
			print("[LaunchManager] Vita3K: Added AppStartParameters for TitleID: " + intent.game.title_id)
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
			print("[LaunchManager] Set working directory: " + install_dir)
		
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
					print("[LaunchManager] Vita3K: Replaced ROM path with TitleID: " + intent.game.title_id)
					break

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	if not intent or not intent.is_valid():
		push_error("[LaunchManager] Invalid launch intent")
		return false
	
	# Check if emulator is fully installed using step validation (consistent across all platforms)
	var emulator = get_emulator(intent.emulator_id)
	var is_actually_installed = false
	if emulator.has("install"):
		var install_steps = emulator.get("install", [])
		is_actually_installed = true
		for i in range(install_steps.size()):
			if not _validate_install_step(intent.emulator_id, i, install_steps):
				is_actually_installed = false
				break
	else:
		# Fallback for legacy emulators
		is_actually_installed = get_emulator_install_state(intent.emulator_id) == InstallState.INSTALLED
	
	if not is_actually_installed:
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
			print("[LaunchManager] Shell command: cmd /c \"" + inner_cmd + "\"")
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
		else:
			# Linux/macOS: use sh -c "exe args"
			var inner_cmd = '"%s" %s' % [
				exe_path,
				" ".join(quoted_args)
			]
			print("[LaunchManager] Shell command: sh -c \"" + inner_cmd + "\"")
			pid = OS.create_process("sh", ["-c", inner_cmd], false)
	
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
	
	# Check if emulator is fully installed using step validation
	# This works consistently across all platforms (Android, Windows, Linux, Mac)
	var is_actually_installed = false
	if emulator.has("install"):
		# Use step validation for proper checking (package_installed, file_exists, etc.)
		var install_steps = emulator.get("install", [])
		is_actually_installed = true
		for i in range(install_steps.size()):
			if not _validate_install_step(emulator_id, i, install_steps):
				is_actually_installed = false
				break
	else:
		# Fallback to runtime state for legacy emulators without install steps
		is_actually_installed = get_emulator_install_state(emulator_id) == InstallState.INSTALLED
	
	if not is_actually_installed:
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
	
	print("[LaunchManager] Updated last_played for '%s' to %s" % [game.get_display_name(), timestamp])
	
	# Notify views that game was launched (so they can re-sort)
	game_launched.emit(game)

func _execute_android(intent: LaunchIntent) -> bool:
	print("[LaunchManager] Executing Android launch...")
	
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
			print("[LaunchManager] Using sideloaded core from: " + core_path)
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
	
	print("[LaunchManager] Launching Android intent:")
	print("  Action: " + intent.android_action)
	print("  Package: " + intent.android_package)
	print("  Class: " + intent.android_class)
	print("  ROM Path: " + intent.rom_path)
	print("  Core Path: " + core_path)
	print("  ROM Delivery: " + rom_delivery)
	print("  MIME Type: " + mime_type)
	print("  Clear Task: " + str(clear_task))
	print("  Grant URI Permission: " + str(grant_uri_permission))
	print("  Use Document URI: " + str(use_document_uri))
	print("  Extras JSON: " + extras_json)
	
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
	
	if success:
		print("[LaunchManager] Android intent launched successfully")
	else:
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
		emulator_extraction_completed.emit(emulator_id, true)
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
	
	print("[LaunchManager] Re-running step " + str(target_step) + " (needed by step " + str(current_step_index) + ")")
	return _execute_install_step(emulator_id, target_step)

## Executes APK install action for a step (Android only)
func _execute_apk_install_step(emulator_id: String, step_index: int, apk_config: Dictionary) -> bool:
	print("[LaunchManager] Executing APK install step...")
	
	var package_name = apk_config.get("package_name", "")
	
	if package_name == "":
		push_error("[LaunchManager] No package_name specified for apk_install")
		return false
	
	print("[LaunchManager] APK install config:")
	print("[LaunchManager]   - package_name: '" + package_name + "'")
	
	# Check if this is the first step (can't go back)
	if step_index == 0:
		push_error("[LaunchManager] Cannot install APK - no previous download step")
		return false
	
	# Get expected filename pattern from config
	var expected_file = apk_config.get("expected_file", "")
	if expected_file == "":
		push_error("[LaunchManager] No expected_file specified for apk_install - cannot find APK to install")
		return false
	
	var emulator_dir = EMULATORS_DIR + emulator_id
	var apk_path = ""
	
	# Find the APK file matching the expected pattern
	var dir = DirAccess.open(emulator_dir)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.match(expected_file):
				apk_path = emulator_dir + "/" + file_name
				break
			file_name = dir.get_next()
		dir.list_dir_end()
	
	# If no APK found matching the pattern, re-run the download step
	if apk_path == "":
		print("[LaunchManager] No APK file matching pattern '" + expected_file + "' found in: " + emulator_dir)
		print("[LaunchManager] Going back to download step")
		return _retry_previous_step(emulator_id, step_index)
	
	# Convert user:// path to absolute path for Android
	var absolute_apk_path = ProjectSettings.globalize_path(apk_path)
	
	print("[LaunchManager] Installing APK: " + apk_path)
	print("[LaunchManager] Absolute path: " + absolute_apk_path)
	
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

## Executes batch URL download action for downloading multiple files
## Downloads all items in parallel and extracts them automatically
func _execute_batch_url_download_step(emulator_id: String, step_index: int, batch_config: Dictionary) -> bool:
	print("[LaunchManager] Executing batch URL download step...")
	
	# Get configuration
	var base_url = batch_config.get("base_url", "")
	var url_pattern = batch_config.get("url_pattern", "{name}")
	var cores = batch_config.get("cores", [])
	var extract_to = batch_config.get("extract_to", ".")
	
	if base_url == "":
		push_error("[LaunchManager] No base_url specified for batch_url_download")
		return false
	
	if cores.is_empty():
		push_error("[LaunchManager] No cores specified for batch_url_download")
		return false
	
	print("[LaunchManager] Batch download config:")
	print("[LaunchManager]   - base_url: " + base_url)
	print("[LaunchManager]   - url_pattern: " + url_pattern)
	print("[LaunchManager]   - cores count: " + str(cores.size()))
	print("[LaunchManager]   - extract_to: " + extract_to)
	
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
	
	# Set state to downloading
	_emulator_install_states[emulator_id] = InstallState.DOWNLOADING
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(total_cores) + ")"
	
	print("[LaunchManager] Starting batch download of " + str(total_cores) + " cores...")
	
	# Queue all downloads
	for core_name in cores:
		# Construct URL from pattern
		var filename = url_pattern.replace("{name}", core_name)
		var full_url = base_url + filename
		
		# Determine extract directory
		var extract_dir: String
		if extract_to.begins_with("/"):
			extract_dir = extract_to
		else:
			extract_dir = EMULATORS_DIR + emulator_id + "/" + extract_to
		
		# Download to emulator directory (for extraction, then delete)
		var destination_path = EMULATORS_DIR + emulator_id + "/" + filename
		
		print("[LaunchManager] Queueing download: " + core_name + " -> " + full_url)
		
		# Queue download with auto-extract
		var item_id = DownloadManager.queue_download(
			full_url,
			destination_path,
			"emulator_core",
			core_name,
			true,  # auto_extract
			extract_dir
		)
		
		if item_id == "":
			print("[LaunchManager] WARNING: Failed to queue download for: " + core_name)
			failed_cores += 1
		else:
			download_ids.append(item_id)
			
			# Create a callback that captures the current values
			var callback = func(success: bool, message: String):
				completed_cores += 1
				if not success:
					failed_cores += 1
					print("[LaunchManager] FAILED: " + core_name + " - " + message)
				else:
					print("[LaunchManager] COMPLETED: " + core_name)
				# Update progress
				_emulator_install_progress[emulator_id] = step_display_name + " (" + str(completed_cores) + "/" + str(total_cores) + ")"
				# Check if all downloads are complete
				if completed_cores >= total_cores:
					if failed_cores > 0:
						push_error("[LaunchManager] Batch download failed: " + str(failed_cores) + "/" + str(total_cores) + " cores failed")
						_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
					else:
						print("[LaunchManager] All " + str(total_cores) + " cores downloaded successfully!")
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
	
	print("[LaunchManager] Queued " + str(download_ids.size()) + "/" + str(total_cores) + " downloads")
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
	
	var emulator = get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Handle extract_to: absolute paths are used directly, relative paths are relative to emulator dir
	var extract_dir: String
	if extract_to.begins_with("/"):
		# Absolute path (e.g., Android /storage/emulated/0/...)
		extract_dir = extract_to
	else:
		# Relative path (default behavior for desktop)
		extract_dir = EMULATORS_DIR + emulator_id + "/" + extract_to
	
	# NEW LOGIC: Check validation first (output files exist?)
	print("[LaunchManager] Checking if extraction output already exists...")
	if _validate_install_step(emulator_id, step_index, install_steps):
		print("[LaunchManager] Extraction output already exists, skipping extraction")
		_execute_install_step(emulator_id, step_index + 1)
		return true
	
	print("[LaunchManager] Extraction output not found, checking for input archive...")
	
	# Look for the archive file to extract
	var emulator_dir = EMULATORS_DIR + emulator_id
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
						print("[LaunchManager] Found archive matching expected_file pattern: " + file_name)
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
							print("[LaunchManager] Found archive file: " + file_name)
							break
					if archive_path != "":
						break
				file_name = dir.get_next()
			dir.list_dir_end()
	
	# Check if archive was found
	if archive_path == "" or not FileAccess.file_exists(archive_path):
		print("[LaunchManager] No archive file found in: " + emulator_dir)
		print("[LaunchManager] Going back to download step (index " + str(step_index - 1) + ")")
		# Go back to download step to re-download
		return _retry_previous_step(emulator_id, step_index)
	
	print("[LaunchManager] Archive found: " + archive_path)
	print("[LaunchManager] Extracting to: " + extract_dir)
	
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
			var files_array = validate_config.get("files", [])
			
			# Support both "files" array format and "path" + "pattern" format
			if files_array.size() > 0:
				# Check if all files in the array exist
				var all_exist = true
				for file_name in files_array:
					var full_file_path = _resolve_validation_path(emulator_id, file_name)
					var exists = FileAccess.file_exists(full_file_path)
					print("[LaunchManager] Validation: files_exist checking file '" + file_name + "' -> '" + full_file_path + "' = " + str(exists))
					if not exists:
						all_exist = false
						break
				return all_exist
			
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
			print("[LaunchManager] Unknown validation action_type: " + action_type)
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
func _handle_download_repo_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var github_repo = platform_config.get("github_repo", "")
	var asset_pattern = platform_config.get("asset_pattern", "")
	var release_tag = platform_config.get("release_tag", "")
	
	if github_repo == "" or asset_pattern == "":
		push_error("[LaunchManager] Invalid download_repo config for step: " + step_name)
		return false
	
	_emulator_install_states[emulator_id] = InstallState.DOWNLOADING
	_emulator_install_progress[emulator_id] = "Fetching release info..."
	
	var step_display_name = _get_step_display_name(step_name)
	
	NetworkManager.fetch_github_latest_release(
		github_repo,
		asset_pattern,
		func(url: String, error: String):
			if error != "":
				push_error("[LaunchManager] Failed to fetch GitHub release: " + error)
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				return
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config),
		release_tag
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
	
	_emulator_install_states[emulator_id] = InstallState.DOWNLOADING
	_emulator_install_progress[emulator_id] = "Scraping for latest version..."
	
	var step_display_name = _get_step_display_name(step_name)
	
	NetworkManager.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(url: String, error: String):
			if error != "":
				push_error("[LaunchManager] Failed to scrape release: " + error)
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
				return
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config)
	)
	return true

## Helper function for create_folders action
func _handle_create_folders_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var folders = platform_config.get("folders", [])
	if folders.is_empty():
		print("[LaunchManager] No folders to create for step: " + step_name)
		return _execute_install_step(emulator_id, step_index + 1)
	
	for folder_path in folders:
		var full_path: String
		if folder_path.begins_with("/"):
			full_path = folder_path
		else:
			full_path = EMULATORS_DIR + emulator_id + "/" + folder_path
		
		var base_dir = full_path.get_base_dir()
		var dir_name = full_path.get_file()
		
		var dir = DirAccess.open(base_dir)
		if dir and not dir.dir_exists(dir_name):
			var error = dir.make_dir_recursive(dir_name)
			if error != OK:
				push_error("[LaunchManager] Failed to create folder: " + full_path)
				return false
			else:
				print("[LaunchManager] Created folder: " + full_path)
		elif not dir:
			push_error("[LaunchManager] Cannot access base directory: " + base_dir)
			return false
		else:
			print("[LaunchManager] Folder already exists: " + full_path)
	
	print("[LaunchManager] Folder creation complete for step: " + step_name)
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for create_files action
func _handle_create_files_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var files = platform_config.get("files", [])
	if files.is_empty():
		print("[LaunchManager] No files to create for step: " + step_name)
		return _execute_install_step(emulator_id, step_index + 1)
	
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
			full_path = EMULATORS_DIR + emulator_id + "/" + file_name
		
		if not FileAccess.file_exists(full_path):
			var file = FileAccess.open(full_path, FileAccess.WRITE)
			if file == null:
				push_error("[LaunchManager] Failed to create file: " + full_path)
				return false
			else:
				file.store_string(file_content)
				file.close()
				print("[LaunchManager] Created file: " + full_path)
		else:
			print("[LaunchManager] File already exists: " + full_path)
	
	print("[LaunchManager] File creation complete for step: " + step_name)
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for edit_file action
func _handle_edit_file_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var file_path = platform_config.get("file", "")
	var edits = platform_config.get("edits", [])
	
	if file_path == "" or edits.is_empty():
		print("[LaunchManager] No file or edits for step: " + step_name)
		return _execute_install_step(emulator_id, step_index + 1)
	
	var full_path: String
	if file_path.begins_with("/"):
		full_path = file_path
	else:
		full_path = EMULATORS_DIR + emulator_id + "/" + file_path
	
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
		print("[LaunchManager] Edited file " + file_path + ": replaced '" + old_text + "' with '" + new_text + "'")
	
	file = FileAccess.open(full_path, FileAccess.WRITE)
	if file == null:
		push_error("[LaunchManager] Failed to write edited file: " + full_path)
		return false
	
	file.store_string(content)
	file.close()
	
	print("[LaunchManager] File editing complete for step: " + step_name)
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for none action (skip)
func _handle_none_step(emulator_id: String, step_name: String, step_index: int) -> bool:
	print("[LaunchManager] Skipping step '" + step_name + "' (action_type: none)")
	return _execute_install_step(emulator_id, step_index + 1)

## Executes install steps from new step-based format (entry point)
func _execute_install_steps(emulator_id: String, emulator: Dictionary, install_steps: Array) -> bool:
	print("[LaunchManager] Starting install flow for: " + emulator_id)
	print("[LaunchManager] Total steps: " + str(install_steps.size()))
	
	# Find the first incomplete step to start from
	var progress = get_install_progress(emulator_id)
	var start_step = 0
	
	if progress["status"] == "partial" and progress["next_step_index"] >= 0:
		start_step = progress["next_step_index"]
		print("[LaunchManager] Resuming from step " + str(start_step) + ": " + progress["next_step_display"])
	else:
		print("[LaunchManager] Starting from beginning (step 0)")
	
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
	print("[LaunchManager] ==========================================")
	print("[LaunchManager] _is_android_package_installed() called")
	print("[LaunchManager] Checking package: '" + package_name + "'")
	
	# Get the PackageChecker plugin singleton
	print("[LaunchManager] Attempting to get PackageChecker singleton...")
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		print("[LaunchManager] ERROR: PackageChecker plugin singleton is NULL")
		print("[LaunchManager] ==========================================")
		return false
	
	print("[LaunchManager] SUCCESS: PackageChecker plugin singleton obtained")
	print("[LaunchManager] Plugin object: " + str(plugin))
	
	# Check the main package name first
	print("[LaunchManager] Calling plugin.isPackageInstalled('" + package_name + "')...")
	var result = plugin.isPackageInstalled(package_name)
	print("[LaunchManager] Result for '" + package_name + "': " + str(result))
	
	if result:
		print("[LaunchManager] SUCCESS: Package '" + package_name + "' is INSTALLED")
		print("[LaunchManager] ==========================================")
		return true
	
	print("[LaunchManager] Package '" + package_name + "' not found, checking variants...")
	
	# For RetroArch, check common variants
	if package_name == "com.retroarch":
		var variants = ["com.retroarch.aarch64", "com.retroarch.ra32"]
		print("[LaunchManager] Checking " + str(variants.size()) + " RetroArch variants: " + str(variants))
		
		for i in range(variants.size()):
			var variant = variants[i]
			print("[LaunchManager] Variant " + str(i + 1) + "/" + str(variants.size()) + ": Checking '" + variant + "'...")
			result = plugin.isPackageInstalled(variant)
			print("[LaunchManager] Variant '" + variant + "' result: " + str(result))
			
			if result:
				print("[LaunchManager] SUCCESS: Variant '" + variant + "' is INSTALLED")
				print("[LaunchManager] ==========================================")
				return true
		
		print("[LaunchManager] No RetroArch variants found installed")
	
	print("[LaunchManager] FINAL: Package '" + package_name + "' is NOT installed")
	print("[LaunchManager] ==========================================")
	return false

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
	
	# If no validation config, consider step complete (just move on)
	# This handles download steps where the file gets deleted after extraction
	if validate_config.is_empty():
		print("[LaunchManager] Step '" + step_name + "' has no validation - skipping")
		return true
	
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
			print("[LaunchManager] Created custom destination directory: " + custom_destination)
		destination_path = custom_destination + "/" + filename
		print("[LaunchManager] Using custom destination: " + destination_path)
	else:
		destination_path = EMULATORS_DIR + emulator_id + "/" + filename
	
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
		"filename": filename,
		"callback": func(success: bool, message: String):
			if not success:
				_emulator_install_states[emulator_id] = InstallState.NOT_INSTALLED
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
	
	# Check for custom destination path (for firmware/shared files)
	var destination_path = download_config.get("destination", "")
	if destination_path == "":
		destination_path = EMULATORS_DIR + emulator_id + "/" + filename
	else:
		# destination is a folder path, append filename
		destination_path = destination_path + "/" + filename
	
	print("[LaunchManager] Download URL: " + download_url)
	print("[LaunchManager] Destination: " + destination_path)
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
		
		# Mark as installed
		_emulator_install_states[emulator_id] = InstallState.INSTALLED
		_emulator_install_progress[emulator_id] = ""
		print("[LaunchManager] Installation complete: " + emulator_id)
		emulator_extraction_completed.emit(emulator_id, true)
		task_info.callback.call(true, "")
		return

# ==================== VITA3K HELPERS ====================

## Extracts TitleID from Vita game ZIP by reading root folder name
func _extract_vita_title_id(zip_path: String) -> String:
	var actual_zip_path = zip_path
	
	# On Android with SAF, content:// URIs can't be read directly by ZIPReader
	# Convert to real file path using the PackageChecker plugin
	if PlatformManager.is_android() and zip_path.begins_with("content://"):
		print("[LaunchManager] Content URI detected, converting to real path...")
		
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin == null:
			push_error("[LaunchManager] PackageChecker plugin not available for SAF URI conversion")
			return ""
		
		var real_path = plugin.getRealPathFromSafUri(zip_path)
		if real_path == "":
			push_error("[LaunchManager] Cannot convert SAF URI to real path: " + zip_path)
			return ""
		
		actual_zip_path = real_path
		print("[LaunchManager] Converted SAF URI to path: " + actual_zip_path)
	
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
	
	var title_id = parts[0]
	print("[LaunchManager] Extracted Vita TitleID: " + title_id + " from " + zip_path)
	
	return title_id

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
		print("[LaunchManager] Vita3K: TitleID not stored, checking for existing extraction...")
		
		# First, check if the game was already extracted (from previous launch)
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
						print("[LaunchManager] Vita3K: Found existing TitleID folder: " + folder_name)
						break
					folder_name = dir.get_next()
				dir.list_dir_end()
		
		# If no existing game found, extract from ZIP
		if found_title_id == "":
			print("[LaunchManager] Vita3K: No existing game found, extracting TitleID from ZIP...")
			found_title_id = _extract_vita_title_id(rom_path)
			if found_title_id == "":
				push_error("[LaunchManager] Vita3K: Failed to extract TitleID from: " + rom_path)
				NotificationManager.show_notification("Failed to extract Vita game TitleID", Notification.Type.ERROR)
				return false
		
		game.title_id = found_title_id
		# Save only title_id to database (doesn't overwrite other fields)
		DataManager.update_game_title_id(game.romm_id, found_title_id)
		print("[LaunchManager] Vita3K: Stored TitleID " + found_title_id + " for game " + game.get_display_name())
	
	var title_id = game.title_id
	
	# Platform-specific Vita3K app path
	var vita_app_path: String
	if PlatformManager.is_android():
		vita_app_path = "/storage/emulated/0/Vita3K/ux0/app/" + title_id
	else:
		# Desktop - use emulator directory (already obtained above)
		vita_app_path = emulator_dir + "/ux0/app/" + title_id
	
	print("[LaunchManager] Vita3K: App path: " + vita_app_path)
	
	# Check if already extracted
	print("[LaunchManager] Vita3K: Checking if folder exists: " + vita_app_path)
	var dir = DirAccess.open(vita_app_path)
	print("[LaunchManager] Vita3K: DirAccess.open result: " + str(dir))
	if dir != null:
		print("[LaunchManager] Vita3K: Game already extracted to " + vita_app_path)
		return true
	print("[LaunchManager] Vita3K: Folder does not exist, need to extract")
	
	# Extract ZIP to Vita3K ux0/app directory (ZIP contains the TitleID folder)
	# We extract to the parent directory (ux0/app) so the ZIP's root folder lands correctly
	var extract_parent = vita_app_path.get_base_dir()
	print("[LaunchManager] Vita3K: First launch - extracting game to " + extract_parent)
	NotificationManager.show_notification("Extracting Vita game for first launch...", Notification.Type.INFO)
	
	var extract_success = await _extract_vita_zip(rom_path, extract_parent, title_id)
	if not extract_success:
		push_error("[LaunchManager] Vita3K: Failed to extract game to " + vita_app_path)
		return false
	
	print("[LaunchManager] Vita3K: Extraction complete for " + title_id)
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
	
	print("[LaunchManager] Vita3K: Queued extraction with ID: " + item_id)
	
	# Wait for extraction to complete
	var extraction_complete = false
	var extraction_success = false
	
	var on_complete = func(completed_item_id: String, success: bool, message: String):
		if completed_item_id == item_id:
			extraction_complete = true
			extraction_success = success
			print("[LaunchManager] Vita3K: Extraction " + ("succeeded" if success else "failed") + ": " + message)
	
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
