extends Manager
class_name FirmwareManager

## Firmware readiness and download management

const FSM = preload("res://managers/filesystem_manager.gd")

## Firmware readiness cache to avoid repeated recursive directory scans
# key: "platform_slug:emulator_id", value: bool
var _firmware_ready_cache: Dictionary = {}

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

## Clears the firmware readiness cache for a specific platform/emulator.
func clear_firmware_cache(platform_slug: String, emulator_id: String) -> void:
	_firmware_ready_cache.erase(platform_slug + ":" + emulator_id)

## Clears the entire firmware readiness cache.
func clear_all_firmware_cache() -> void:
	_firmware_ready_cache.clear()

## Clears all cached firmware readiness entries for a given platform.
func clear_firmware_cache_for_platform(platform_slug: String) -> void:
	var prefix = platform_slug + ":"
	for key in _firmware_ready_cache.keys():
		if key.begins_with(prefix):
			_firmware_ready_cache.erase(key)

## Gets the firmware directory for an emulator
## Resolves paths with wildcards ({emulator_dir}, {app_data}, etc.)
func get_firmware_directory(emulator_id: String) -> String:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
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
	var cache_key = platform_slug + ":" + emulator_id
	if _firmware_ready_cache.has(cache_key):
		return _firmware_ready_cache[cache_key]
	
	var firmware_dir = get_firmware_directory(emulator_id)
	if firmware_dir == "":
		# No firmware directory configured, assume not needed
		_firmware_ready_cache[cache_key] = true
		return true
	
	if not FSM.dir_exists(firmware_dir):
		_firmware_ready_cache[cache_key] = false
		return false
	
	# Get expected files from platform configuration
	var platform_config = launch_manager.registry._platforms_data.get(platform_slug, {})
	var firmware_config = platform_config.get("firmware", {})
	var expected_files = firmware_config.get("expected_files", [])
	
	# No expected files means no BIOS needed for this platform
	if expected_files.is_empty():
		_firmware_ready_cache[cache_key] = true
		return true
	
	# Check if any expected file exists (searching recursively)
	for expected_file in expected_files:
		if _find_file_recursive(firmware_dir, expected_file):
			_firmware_ready_cache[cache_key] = true
			return true
	
	_firmware_ready_cache[cache_key] = false
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

func _on_firmware_download_complete(success: bool, download_error: String, _notification_id: int, temp_path: String, firmware_dir: String, platform_slug: String, emulator_id: String, callback: Callable, _last_progress_mb: Array):
	NotificationManager.dismiss_notification(_notification_id)
	
	if not success:
		push_error("[FirmwareManager] Failed to download firmware: " + download_error)
		if callback.is_valid():
			callback.call(false, download_error)
		return
	
	print("[FirmwareManager] Firmware downloaded, extracting to: " + firmware_dir)
	
	# FSM handles its own extraction notification
	FSM.extract_archive_async(
		temp_path,
		firmware_dir,
		"Firmware for " + platform_slug,
		true,
		func(_e, _t): pass,
		func(extract_success: bool, error_msg: String):
			if not extract_success:
				push_error("[FirmwareManager] Failed to extract firmware to: " + firmware_dir + ": " + error_msg)
				launch_manager.firmware_download_completed.emit(platform_slug, false)
				if callback.is_valid():
					callback.call(false, error_msg)
				return
			
			print("[FirmwareManager] Firmware successfully installed for " + platform_slug)
			clear_firmware_cache(platform_slug, emulator_id)
			launch_manager.firmware_download_completed.emit(platform_slug, true)
			if callback.is_valid():
				callback.call(true, "Firmware installed")
	)

## Returns the list of expected firmware files for a platform (empty if none).
func get_platform_firmware_expected_files(platform_slug: String) -> Array:
	var platform_config = launch_manager.registry._platforms_data.get(platform_slug, {})
	var firmware_config = platform_config.get("firmware", {})
	return firmware_config.get("expected_files", [])

## Sets up firmware for a platform by downloading from RomM
## This should be called during platform sync
## callback(success: bool, message: String)
func setup_platform_firmware(platform_slug: String, emulator_id: String, callback: Callable = Callable()) -> void:
	print("[FirmwareManager] Checking firmware for " + platform_slug + " / " + emulator_id)
	
	# Check if firmware is already ready
	if is_platform_firmware_ready(platform_slug, emulator_id):
		print("[FirmwareManager] Firmware already ready for " + platform_slug)
		if callback.is_valid():
			callback.call(true, "Firmware already installed")
		return
	
	# Get firmware directory
	var firmware_dir = get_firmware_directory(emulator_id)
	if firmware_dir == "":
		print("[FirmwareManager] No firmware directory configured for " + emulator_id)
		if callback.is_valid():
			callback.call(true, "No firmware needed")
		return
	
	print("[FirmwareManager] Firmware needed for " + platform_slug + ", querying RomM...")
	
	# Query RomM for platform firmware
	NetworkManager.fetch_platform_firmware(platform_slug, func(platform_data: Dictionary, error: String):
		if error != "":
			push_error("[FirmwareManager] Failed to fetch firmware info: " + error)
			if callback.is_valid():
				callback.call(false, error)
			return
		
		var firmware_list = platform_data.get("firmware", [])
		if firmware_list.is_empty():
			print("[FirmwareManager] No firmware available for " + platform_slug + " on RomM")
			if callback.is_valid():
				callback.call(true, "No firmware on server")
			return
		
		print("[FirmwareManager] Found " + str(firmware_list.size()) + " firmware file(s) for " + platform_slug)
		
		# For now, download the first firmware file (should be the zip)
		var firmware = firmware_list[0]
		var firmware_id = firmware.get("id", 0)
		var file_name = firmware.get("file_name", "")
		
		if firmware_id == 0 or file_name == "":
			push_error("[FirmwareManager] Invalid firmware data for " + platform_slug)
			if callback.is_valid():
				callback.call(false, "Invalid firmware data")
			return
		
		# Download to temp location first
		var temp_path = "user://temp_firmware/" + file_name
		FSM.make_dir_recursive("user://temp_firmware")
		
		print("[FirmwareManager] Downloading firmware: " + file_name)
		
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
			_on_firmware_download_complete.bind(_firmware_notification_id, temp_path, firmware_dir, platform_slug, emulator_id, callback, _last_progress_mb),
			func(size_mb: int):
				if size_mb != _last_progress_mb[0]:
					_last_progress_mb[0] = size_mb
					NotificationManager.update_notification_text(
						_firmware_notification_id,
						"Downloading firmware for " + platform_slug + "... " + str(size_mb) + " MB"
					)
		)
	)
