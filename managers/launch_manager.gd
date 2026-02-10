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
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return false
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var executable_name = emulator.get("executable_names", {}).get(platform_name, "")
	
	if executable_name == "":
		return false
	
	# Check in user://emulators/{emulator_id}/
	var install_path = EMULATORS_DIR + emulator_id + "/" + executable_name
	if FileAccess.file_exists(install_path):
		return true
	
	# Also check system PATH (for Linux system installs)
	if PlatformManager.is_linux() or PlatformManager.is_windows():
		var output = []
		var exit_code = OS.execute("which" if PlatformManager.is_linux() else "where", [executable_name], output, true)
		if exit_code == 0 and output.size() > 0:
			return true
	
	return false

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
	
	# Show extraction notification
	var notification_id = NotificationManager.show_notification(
		"Installing " + emulator_id + "...",
		Notification.Type.INFO,
		null,
		0.0,
		func() -> float:
			# Progress will be updated by extraction process
			return 0.0,
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
		# For 7z files, we'll need to use a different approach
		# For now, just report that extraction isn't supported
		NotificationManager.update_notification_text(notification_id, "7z extraction not yet supported")
		success = false
	else:
		push_error("[LaunchManager] Unknown archive format: " + archive_path)
		success = false
	
	# Remove from active extractions
	_active_extractions.erase(emulator_id)
	
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
		emulator_extraction_progress.emit(emulator_id, progress)
		NotificationManager.update_notification_text(notification_id, "Installing " + emulator_id + ": %d%%" % int(progress * 100))
	
	reader.close()
	
	# Delete archive after successful extraction
	var success = (extracted_count == total_files)
	if success:
		var dir = DirAccess.open("user://")
		if dir:
			dir.remove(archive_path.trim_prefix("user://"))
		NotificationManager.update_notification_text(notification_id, "Installation complete!")
	else:
		NotificationManager.update_notification_text(notification_id, "Installation incomplete")
	
	emulator_extraction_completed.emit(emulator_id, success)
	return success

## Gets the install path for an emulator
func get_emulator_install_path(emulator_id: String) -> String:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var platform_name = PlatformManager.get_platform_name().to_lower()
	var executable_name = emulator.get("executable_names", {}).get(platform_name, "")
	
	if executable_name == "":
		return ""
	
	return EMULATORS_DIR + emulator_id + "/" + executable_name

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
