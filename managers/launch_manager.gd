extends Manager

## Manages emulator registry, launch intents, and game execution

const REGISTRY_PATH := "res://data/emulator_registry.json"
const EMULATORS_DIR := "user://emulators/"

# Registry data
var _emulator_registry: Dictionary = {}
var _platform_defaults: Dictionary = {}

# Track ongoing extractions
var _active_extractions: Array[String] = []

# Signals
signal emulator_registry_loaded(success: bool)
signal launch_completed(success: bool, message: String)
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_progress(emulator_id: String, progress: float)
signal emulator_extraction_completed(emulator_id: String, success: bool)

func _ready():
	_load_registry()
	_ensure_emulators_directory()

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

## Checks if an emulator is installed
func is_emulator_installed(emulator_id: String) -> bool:
	var install_path = get_emulator_install_path(emulator_id)
	return install_path != "" and FileAccess.file_exists(install_path)

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
	return emulator_id in _active_extractions

## Extracts the emulator archive
var _extraction_progress: Dictionary = {}  # emulator_id -> current_progress (0.0-1.0)

func extract_emulator(emulator_id: String) -> bool:
	if is_emulator_installed(emulator_id):
		print("[LaunchManager] Emulator already installed: " + emulator_id)
		return true
	
	if not is_emulator_downloaded(emulator_id):
		push_error("[LaunchManager] Cannot extract - archive not downloaded: " + emulator_id)
		return false
	
	if is_emulator_extracting(emulator_id):
		print("[LaunchManager] Extraction already in progress: " + emulator_id)
		return false
	
	var archive_path = get_archive_path(emulator_id)
	var extract_dir = EMULATORS_DIR + emulator_id + "/"
	
	print("[LaunchManager] Extracting emulator: " + emulator_id + " from " + archive_path)
	
	# Initialize progress
	_extraction_progress[emulator_id] = 0.0
	
	# Show extraction notification with progress callable
	var notification_id = NotificationManager.show_notification(
		"Installing " + emulator_id + "...",
		Notification.Type.INFO,
		null,
		0.0,
		func() -> float:
			# Return current progress (will be updated by extraction process)
			return _extraction_progress.get(emulator_id, 0.0),
		func(progress: float) -> String:
			return "Installing " + emulator_id + ": %d%%" % int(progress * 100)
	)
	
	# Track active extraction
	_active_extractions.append(emulator_id)
	
	# Extract based on archive type
	var success = false
	if archive_path.ends_with(".zip"):
		success = _extract_zip(archive_path, extract_dir, emulator_id, notification_id)
	elif archive_path.ends_with(".7z"):
		success = _extract_7z(archive_path, extract_dir, emulator_id, notification_id)
	else:
		push_error("[LaunchManager] Unknown archive format: " + archive_path)
		NotificationManager.update_notification_text(notification_id, "Unknown archive format")
		success = false
	
	return success

## Extracts a ZIP file with progress updates
func _extract_zip(archive_path: String, extract_dir: String, emulator_id: String, notification_id: int) -> bool:
	emulator_extraction_started.emit(emulator_id)
	
	var reader = ZIPReader.new()
	var err = reader.open(archive_path)
	
	if err != OK:
		push_error("[LaunchManager] Failed to open ZIP archive: " + str(err))
		NotificationManager.update_notification_text(notification_id, "Failed to open archive")
		emulator_extraction_completed.emit(emulator_id, false)
		return false
	
	var files = reader.get_files()
	var total_files = files.size()
	var extracted_count = 0
	
	for file in files:
		var dest_path = extract_dir + file
		
		# Create directory if needed
		if file.ends_with("/"):
			var dir = DirAccess.open("user://")
			if dir:
				dir.make_dir_recursive(dest_path.trim_prefix("user://"))
			continue
		
		# Extract file
		var buffer = reader.read_file(file)
		if buffer.size() > 0:
			var file_dir = dest_path.get_base_dir()
			var dir = DirAccess.open("user://")
			if dir:
				dir.make_dir_recursive(file_dir.trim_prefix("user://"))
			
			var f = FileAccess.open(dest_path, FileAccess.WRITE)
			if f:
				f.store_buffer(buffer)
				f.close()
				extracted_count += 1
		
		# Update progress
		var progress = float(extracted_count) / float(total_files)
		_extraction_progress[emulator_id] = progress
		emulator_extraction_progress.emit(emulator_id, progress)
	
	reader.close()
	
	# Delete archive after successful extraction
	var success = (extracted_count == total_files)
	if success:
		_extraction_progress[emulator_id] = 1.0
		var dir = DirAccess.open("user://")
		if dir:
			dir.remove(archive_path.trim_prefix("user://"))
		print("[LaunchManager] ZIP extraction successful")
	else:
		NotificationManager.update_notification_text(notification_id, "Installation incomplete")
		_extraction_progress.erase(emulator_id)
	
	_active_extractions.erase(emulator_id)
	emulator_extraction_completed.emit(emulator_id, success)
	return success

## Extracts a 7z archive using bundled 7za binary (non-blocking with progress)
var _extraction_processes: Dictionary = {}  # emulator_id -> {pid, timer, notification_id, total_files, extract_dir, archive_path}

func _extract_7z(archive_path: String, extract_dir: String, emulator_id: String, notification_id: int) -> bool:
	emulator_extraction_started.emit(emulator_id)
	
	# Get the bundled 7z binary path
	var binary_path = _get_7z_binary_path()
	
	if not FileAccess.file_exists(binary_path):
		push_error("[LaunchManager] 7z binary not found at: " + binary_path)
		NotificationManager.update_notification_text(notification_id, "7z extractor not found")
		emulator_extraction_completed.emit(emulator_id, false)
		return false
	
	print("[LaunchManager] Extracting 7z archive using: " + binary_path)
	
	# Convert paths to absolute system paths
	var abs_archive_path = ProjectSettings.globalize_path(archive_path)
	var abs_extract_dir = ProjectSettings.globalize_path(extract_dir)
	
	print("[LaunchManager] Archive: " + abs_archive_path)
	print("[LaunchManager] Extract to: " + abs_extract_dir)
	
	# Get total file count from archive first
	var total_files = _get_7z_file_count(binary_path, abs_archive_path)
	if total_files == 0:
		push_error("[LaunchManager] Could not determine file count in archive")
		NotificationManager.update_notification_text(notification_id, "Could not read archive")
		emulator_extraction_completed.emit(emulator_id, false)
		return false
	
	print("[LaunchManager] Total files to extract: " + str(total_files))
	
	# Track this extraction
	_active_extractions.append(emulator_id)
	
	# Build command: 7za x archive.7z -o"dest" -y
	var args = ["x", abs_archive_path, "-o" + abs_extract_dir, "-y"]
	
	# Start non-blocking extraction
	var output = []
	var pid = OS.execute(binary_path, args, output, false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to start 7z extraction process")
		NotificationManager.update_notification_text(notification_id, "Failed to start extraction")
		_active_extractions.erase(emulator_id)
		emulator_extraction_completed.emit(emulator_id, false)
		return false
	
	print("[LaunchManager] Extraction started with PID: " + str(pid))
	
	# Store process info
	_extraction_processes[emulator_id] = {
		"pid": pid,
		"notification_id": notification_id,
		"total_files": total_files,
		"extract_dir": extract_dir,
		"archive_path": archive_path,
		"output": output
	}
	
	# Create timer to poll progress
	var timer = Timer.new()
	timer.wait_time = 0.5
	timer.one_shot = false
	add_child(timer)
	timer.timeout.connect(_on_extraction_poll.bind(emulator_id, timer))
	timer.start()
	
	_extraction_processes[emulator_id]["timer"] = timer
	
	return true

## Gets file count from 7z archive
func _get_7z_file_count(binary_path: String, archive_path: String) -> int:
	var args = ["l", archive_path]
	var output = []
	var exit_code = OS.execute(binary_path, args, output, true)
	
	if exit_code != 0:
		print("[LaunchManager] 7za list command failed with exit code: " + str(exit_code))
		return 0
	
	if output.size() == 0:
		print("[LaunchManager] 7za list command returned no output")
		return 0
	
	var output_str = output[0]
	var lines = output_str.split("\n")
	
	# Search from the END of the output (summary is at the bottom)
	for i in range(lines.size() - 1, -1, -1):
		var line = lines[i].strip_edges()
		var lower_line = line.to_lower()
		
		# Look for "X files, Y folders" pattern (7za summary line)
		# Example: "2025-11-19 21:44:16          541900046    202356424  14808 files, 838 folders"
		if " files," in lower_line and " folders" in lower_line:
			# Extract the number before "files"
			var regex = RegEx.new()
			regex.compile("(\\d+)\\s+files,")
			var result = regex.search(lower_line)
			if result:
				var file_count = result.get_string(1).to_int()
				if file_count > 0:
					print("[LaunchManager] Found file count: " + str(file_count))
					return file_count
		
		# Fallback: Look for "X files" anywhere in the line
		if " files" in lower_line:
			var regex = RegEx.new()
			regex.compile("(\\d+)\\s+files")
			var result = regex.search(lower_line)
			if result:
				var file_count = result.get_string(1).to_int()
				if file_count > 0:
					print("[LaunchManager] Found file count (fallback): " + str(file_count))
					return file_count
	
	print("[LaunchManager] Could not parse file count from 7za output")
	return 0

## Polls extraction progress
func _on_extraction_poll(emulator_id: String, timer: Timer):
	if not _extraction_processes.has(emulator_id):
		timer.stop()
		timer.queue_free()
		return
	
	var process = _extraction_processes[emulator_id]
	var pid = process["pid"]
	var notification_id = process["notification_id"]
	var total_files = process["total_files"]
	var extract_dir = process["extract_dir"]
	var archive_path = process["archive_path"]
	
	# Check if process is still running
	# OS.execute doesn't give us an easy way to check process status in Godot 4.x
	# Instead, we'll count files and assume completion when file count stops changing or reaches total
	
	var current_files = _count_files_recursive(extract_dir)
	var progress = clamp(float(current_files) / float(total_files), 0.0, 1.0)
	
	# Update progress dictionary (notification will read this via progress callable)
	_extraction_progress[emulator_id] = progress
	
	# Emit progress signal
	emulator_extraction_progress.emit(emulator_id, progress)
	
	# Check if extraction is complete (all files extracted)
	if current_files >= total_files or progress >= 1.0:
		# Set to 100% for notification auto-dismiss
		_extraction_progress[emulator_id] = 1.0
		# Wait a bit then finalize
		timer.stop()
		timer.queue_free()
		_finalize_extraction(emulator_id, true)

## Counts all files recursively (no depth limit for accurate progress tracking)
func _count_files_recursive(dir_path: String) -> int:
	var count = 0
	var dir = DirAccess.open(dir_path)
	
	if not dir:
		return 0
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		
		var full_path = dir_path + "/" + file_name
		
		if dir.current_is_dir():
			count += _count_files_recursive(full_path)
		else:
			count += 1
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return count

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

## Finalizes extraction (cleanup and signals)
func _finalize_extraction(emulator_id: String, success: bool):
	if not _extraction_processes.has(emulator_id):
		return
	
	var process = _extraction_processes[emulator_id]
	var notification_id = process["notification_id"]
	var archive_path = process["archive_path"]
	
	_extraction_processes.erase(emulator_id)
	_active_extractions.erase(emulator_id)
	
	if success:
		# Set progress to 100% so notification auto-dismisses
		_extraction_progress[emulator_id] = 1.0
		
		# Delete archive
		var dir = DirAccess.open("user://")
		if dir:
			dir.remove(archive_path.trim_prefix("user://"))
		print("[LaunchManager] 7z extraction successful")
		# Notification will auto-dismiss at 100% due to progress callable
	else:
		NotificationManager.update_notification_text(notification_id, "Installation failed")
		_extraction_progress.erase(emulator_id)
	
	emulator_extraction_completed.emit(emulator_id, success)

## Gets the path to the bundled 7z binary
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
	var res_path = "res://bin/7z/" + platform_name + "/" + binary_name
	
	# Convert res:// path to absolute system path
	var global_path = ProjectSettings.globalize_path(res_path)
	print("[LaunchManager] 7z binary path: " + global_path)
	
	return global_path

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
		
		for arg in template:
			var formatted_arg = arg.replace("{exe}", install_path)
			formatted_arg = formatted_arg.replace("{rom}", intent.rom_path)
			formatted_arg = formatted_arg.replace("{core}", intent.core_name)
			intent.launch_args.append(formatted_arg)

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	if not intent or not intent.is_valid():
		push_error("[LaunchManager] Invalid launch intent")
		return false
	
	# Check if emulator is installed
	if not is_emulator_installed(intent.emulator_id):
		push_error("[LaunchManager] Emulator not installed: " + intent.emulator_id)
		NotificationManager.show_notification("Emulator not installed: " + intent.emulator_name, Notification.Type.ERROR)
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
	
	# Use OS.create_process for non-blocking launch
	var pid = OS.create_process(exe_path, arguments, false)
	
	if pid == -1:
		push_error("[LaunchManager] Failed to launch process: " + exe_path)
		launch_completed.emit(false, "Failed to start emulator")
		return false
	
	print("[LaunchManager] Launched process with PID: " + str(pid))
	launch_completed.emit(true, "Game launched successfully")
	return true

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
	
	# Check if already installed
	if is_emulator_installed(emulator_id):
		print("[LaunchManager] Emulator already installed: " + emulator_id)
		return false
	
	# Check if already downloaded in this session
	if DownloadManager.has_emulator_been_downloaded(emulator_id):
		print("[LaunchManager] Emulator already downloaded in this session: " + emulator_id)
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
	
	print("[LaunchManager] Queueing emulator download: " + emulator_id + " from " + download_url)
	
	# Queue the download
	return DownloadManager.queue_emulator_download(emulator_id, emulator_name, download_url, destination_path)

func is_emulator_downloading(emulator_id: String) -> bool:
	return DownloadManager.is_emulator_downloading(emulator_id)

func is_emulator_queued(emulator_id: String) -> bool:
	return DownloadManager.is_emulator_queued(emulator_id)
