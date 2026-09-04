extends Manager
class_name EmulatorSubManager

## Emulator install/update/download management

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CSM = preload("res://managers/system_manager/config_sub_manager.gd")

# Track installation progress for UI display only
var _emulator_install_progress: Dictionary = {}  # emulator_id -> progress text for UI

## Unified download tracking for emulator downloads
# item_id -> {emulator_id, context, extract_to, strip_top_directory, callback}
var _pending_emulator_downloads: Dictionary = {}

## Pending emulator versions resolved during install but not yet persisted.
## Key: emulator_id, Value: version string. Saved only when install completes.
var _pending_emulator_version: Dictionary = {}

## When true, install-step handlers will execute even if their outputs already exist.
## Set for updates/reinstalls; cleared on completion or failure.
var _force_install_step: Dictionary = {}

## Validation cache to avoid redundant file system operations
# emulator_id -> {result: Dictionary, timestamp: int, step_results: Dictionary}
var _validation_cache: Dictionary = {}
var _cache_ttl_ms: int = 5000  # 5 second cache TTL

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

## Clears the validation cache. Call after external install state changes (e.g., APK install).
func clear_validation_cache() -> void:
	_validation_cache.clear()

## Clears pending launches whose emulators are now installed.
## Call on app resume after potential APK installations.
func clear_stale_pending_launches() -> void:
	var to_remove = []
	for emulator_id in launch_manager._pending_launches:
		var emulator = launch_manager.registry.get_emulator(emulator_id)
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
			print("[EmulatorManager] Clearing stale pending launch for emulator: " + emulator_id)
			to_remove.append(emulator_id)
	for emulator_id in to_remove:
		launch_manager._pending_launches.erase(emulator_id)

## Gets the current installation progress text for UI display
func get_emulator_install_progress(emulator_id: String) -> String:
	return _emulator_install_progress.get(emulator_id, "")

## Checks whether the stored progress text indicates an extraction is in progress.
func is_install_progress_extracting(emulator_id: String) -> bool:
	if _emulator_install_progress.has(emulator_id):
		var progress_str = _emulator_install_progress[emulator_id]
		return progress_str.find("Extracting") >= 0 or progress_str.find("extracting") >= 0
	return false

## Checks if emulator is currently being extracted
func is_emulator_extracting(emulator_id: String) -> bool:
	# Check SystemManager.download for any active extraction for this emulator
	for item in SystemManager.download.get_active():
		if item.name == emulator_id and item.status == "extracting":
			return true
	return false

## Called when SystemManager.download completes an extraction
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
		if extract_dir.begins_with(launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")):
			# Clear validation cache
			_validation_cache.erase(emulator_id)
			
			if success:
				_emulator_install_progress[emulator_id] = ""
				launch_manager.emulator_extraction_completed.emit(emulator_id, true)
			else:
				_emulator_install_progress[emulator_id] = "Extraction failed"
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			
			# Fallback: dismiss any lingering extraction notification for this emulator.
			# This handles cases where the notification dismissal failed while backgrounded.
			# Extraction notifications are progress snackbars whose text starts with
			# the emulator name (see _get_step_display_name); dismiss only that one.
			if SystemManager.notifications:
				var emulator_name: String = launch_manager.registry.get_emulator(emulator_id).get("name", emulator_id)
				SystemManager.notifications.dismiss_progress_notification_by_prefix(emulator_name + " - ")
			
			return

## Flattens an extracted directory by moving contents of a single top-level subdirectory up one level
## This handles zips that extract to a nested directory like "Archive-1.0/file.txt" -> "file.txt"
func _flatten_extracted_directory(emulator_id: String, extract_to: String, target_folder: String = ""):
	# Android uses absolute paths, Desktop uses relative paths
	var extract_path: String
	if SystemManager.platform.is_android():
		# Handle "." as current directory
		if extract_to == ".":
			extract_path = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
		else:
			extract_path = extract_to
	else:
		# Handle "." as current directory on desktop too
		if extract_to == ".":
			extract_path = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
		elif extract_to.begins_with("/") or extract_to.begins_with("content://") or extract_to.begins_with("user://") or extract_to.begins_with("res://") or (extract_to.length() > 1 and extract_to[1] == ":"):
			# extract_to is already an absolute path (Unix, Windows, or Godot virtual filesystem style)
			extract_path = extract_to
		else:
			extract_path = FSM.join_paths(launch_manager.registry._get_emulator_directory(emulator_id), extract_to)
	
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
				push_warning("[EmulatorManager] Failed to flatten item: " + source_path + " -> " + dest_path)
		
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
				print("[EmulatorManager] Flattening: move result=" + str(move_success))
				if not move_success:
					push_warning("[EmulatorManager] Failed to flatten item: " + source_path + " -> " + dest_path)
			
			# Remove the now-empty subdirectory
			DirAccess.remove_absolute(single_entry_path)

func download_emulator(emulator_id: String) -> bool:
	# Check if already downloading/extracting
	for item_id in _pending_emulator_downloads:
		if _pending_emulator_downloads[item_id].emulator_id == emulator_id:
			return false
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[EmulatorManager] Unknown emulator: " + emulator_id)
		return false
	
	# Get install steps from new step-based format
	var install_steps = emulator.get("install", [])
	if install_steps.is_empty():
		push_error("[EmulatorManager] No install steps defined for: " + emulator_id)
		return false
	
	# Ensure emulator directory exists before starting install
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id)
	if not FSM.dir_exists(emulator_dir):
		print("[EmulatorManager] Creating emulator directory: " + emulator_dir)
		if not FSM.make_dir_recursive(emulator_dir):
			push_error("[EmulatorManager] Failed to create emulator directory: " + emulator_dir)
			return false
		print("[EmulatorManager] Successfully created emulator directory")
	
	return _execute_install_steps(emulator_id, emulator, install_steps)

## Re-runs all non-download install steps to repair/refresh config files.
## Skips step 0 (download) since the emulator binary is already present.
## Forces re-creation of portable.txt, INIs, superblocks, etc.
func repair_emulator_config(emulator_id: String) -> bool:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[EmulatorManager] Unknown emulator: " + emulator_id)
		return false
	
	var install_steps = emulator.get("install", [])
	if install_steps.size() <= 1:
		push_error("[EmulatorManager] No config steps to repair for: " + emulator_id)
		return false
	
	# Force all steps to re-apply (overwrite existing config files)
	_force_install_step[emulator_id] = true
	
	# Start from step 1 (skip download)
	print("[EmulatorManager] Repairing config for " + emulator_id + " from step 1")
	return _execute_install_step(emulator_id, 1)

## Executes a single install step by index
func _execute_install_step(emulator_id: String, step_index: int) -> bool:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		push_error("[EmulatorManager] Unknown emulator: " + emulator_id)
		return false
	
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	var emulator_name = emulator.get("name", emulator_id)
	var install_steps = emulator.get("install", [])
	
	if step_index >= install_steps.size():
		# All steps completed successfully
		_create_emulator_save_directory(emulator_id)
		_emulator_install_progress[emulator_id] = ""
		# Persist the version resolved during the first download step now that the
		# install is fully complete. This avoids marking an emulator updated when a
		# download or extraction actually failed partway through.
		if _pending_emulator_version.has(emulator_id):
			_save_emulator_version(emulator_id, _pending_emulator_version[emulator_id])
			_pending_emulator_version.erase(emulator_id)
		_force_install_step.erase(emulator_id)
		launch_manager.emulator_extraction_completed.emit(emulator_id, true)
		return true
	
	var step = install_steps[step_index]
	var step_name = step.get("step", "")
	var platform_config = launch_manager.registry._get_step_platform_config(step)
	
	if platform_config.is_empty():
		push_error("[EmulatorManager] No platform config for step '" + step_name + "' on platform: " + platform_name)
		_force_install_step.erase(emulator_id)
		return false
	
	var action_type = platform_config.get("action_type", "")
	var step_success: bool = false
	
	# Route to appropriate handler based on action type
	match action_type:
		"download_url":
			step_success = _handle_download_url_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"download_repo":
			step_success = _handle_download_repo_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"download_scrape":
			step_success = _handle_download_scrape_step(emulator_id, emulator_name, step_name, step_index, platform_config)
		"extract":
			step_success = _execute_extract_step(emulator_id, step_index, platform_config)
		"apk_install":
			step_success = _execute_apk_install_step(emulator_id, step_index, platform_config)
		"batch_url_download":
			step_success = _execute_batch_url_download_step(emulator_id, step_index, platform_config)
		"create_folders":
			step_success = _handle_create_folders_step(emulator_id, step_name, step_index, platform_config)
		"create_files":
			step_success = _handle_create_files_step(emulator_id, step_name, step_index, platform_config)
		"create_pcsx2_superblock":
			step_success = _handle_create_pcsx2_superblock_step(emulator_id, step_name, step_index, platform_config)
		"edit_file":
			step_success = _handle_edit_file_step(emulator_id, step_name, step_index, platform_config)
		"none":
			step_success = _handle_none_step(emulator_id, step_name, step_index)
		_:
			push_error("[EmulatorManager] Unknown action_type '" + action_type + "' for step: " + step_name)
			step_success = false
	
	if not step_success:
		_force_install_step.erase(emulator_id)
	
	return step_success

## Re-runs a previous install step when current step needs it
## Use this when a step's input (downloaded file, etc.) is missing
func _retry_previous_step(emulator_id: String, current_step_index: int) -> bool:
	var target_step = current_step_index - 1
	if target_step < 0:
		push_error("[EmulatorManager] Cannot retry - would go before first step")
		return false
	
	return _execute_install_step(emulator_id, target_step)

## Executes APK install action for a step (Android only)
## Uses simple file:// URI approach with OS.shell_open()
## APKs are downloaded to the emulator directory for consistency
func _execute_apk_install_step(emulator_id: String, step_index: int, apk_config: Dictionary) -> bool:
	var package_name = apk_config.get("package_name", "")
	
	if package_name == "":
		push_error("[EmulatorManager] No package_name specified for apk_install")
		return false
	
	# Check if this is the first step (can't go back)
	if step_index == 0:
		push_error("[EmulatorManager] Cannot install APK - no previous download step")
		return false
	
	# Get expected filename pattern from config
	var expected_file = apk_config.get("expected_file", "")
	if expected_file == "":
		push_error("[EmulatorManager] No expected_file specified for apk_install - cannot find APK to install")
		return false
	
	print("[EmulatorManager] Executing APK install step...")
	print("[EmulatorManager]   - package_name: '" + package_name + "'")
	print("[EmulatorManager]   - expected_file: '" + expected_file + "'")
	
	# APKs are downloaded to the emulator directory (same as other platforms)
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id)
	var apk_path = ""
	
	# Find the APK file in emulator directory
	var entries = FSM.list_dir(emulator_dir)
	for file_name in entries:
		if file_name.match(expected_file):
			apk_path = FSM.join_paths(emulator_dir, file_name)
			print("[EmulatorManager] Found APK: " + apk_path)
			break
	
	# If no APK found, retry download
	if apk_path == "":
		print("[EmulatorManager] No APK found in emulator directory, retrying download")
		return _retry_previous_step(emulator_id, step_index)
	
	# Validate APK file exists and has content
	var file_size = FSM.get_file_size(apk_path)
	print("[EmulatorManager] APK file size: " + str(file_size) + " bytes")
	if file_size < 0:
		print("[EmulatorManager] ERROR: Cannot access APK file!")
		return _retry_previous_step(emulator_id, step_index)
	elif file_size < 1000:
		print("[EmulatorManager] ERROR: APK file is too small or empty!")
		SystemManager.notifications.show_notification(
			"APK download incomplete!\nFile size: " + str(file_size) + " bytes",
			SystemManager.notifications.Type.ERROR,
			null,
			10.0
		)
		_emulator_install_progress[emulator_id] = "APK download incomplete"
		return false
	
	print("[EmulatorManager] Installing APK: " + apk_path)
	
	# On Android, use plugin to install APK with content:// URI (required for Android N+)
	var plugin = null
	if Engine.has_singleton("PackageChecker"):
		plugin = Engine.get_singleton("PackageChecker")
	
	var result = Error.FAILED
	if plugin != null:
		# Convert Godot virtual path (user://) to an absolute filesystem path
		# so the Java plugin can create a File object from it.
		var absolute_apk_path = FSM.resolve_path(apk_path, {"format": FSM.PathFormat.ABSOLUTE})
		print("[EmulatorManager] Resolved APK path for plugin: " + absolute_apk_path)
		var success = plugin.call("installApk", absolute_apk_path)
		if success:
			result = Error.OK
	else:
		push_error("[EmulatorManager] PackageChecker plugin not available for APK install")
	
	if result != Error.OK:
		print("[EmulatorManager] APK install failed with error: " + str(result))
		SystemManager.notifications.show_notification(
			"APK install failed!\nPlease install manually from:\n" + apk_path,
			SystemManager.notifications.Type.ERROR,
			null,
			10.0
		)
		
		# Try to open the folder
		var folder_result = OS.shell_open(FSM.resolve_path(emulator_dir, {"format": FSM.PathFormat.ABSOLUTE}))
		if folder_result == Error.OK:
			print("[EmulatorManager] Opened folder containing APK")
		
		_emulator_install_progress[emulator_id] = "APK install failed"
		return false
	
	print("[EmulatorManager] APK installer opened successfully")
	print("[EmulatorManager] User must complete installation in Android UI")
	
	# Show reminder on Android to open the app and grant permissions
	launch_manager.process._show_android_permissions_reminder(emulator_id)
	
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
	var dynamic_cores = batch_config.get("dynamic_cores", false)
	
	# On Android RetroArch, generate the default-core list from the registry so it
	# stays in sync with the supported platform/core mappings.
	if dynamic_cores and emulator_id == "retroarch" and SystemManager.platform.is_android():
		cores = launch_manager.core.get_default_core_download_list(emulator_id) as Array
		if cores.is_empty():
			push_error("[EmulatorManager] No default cores found in registry for Android RetroArch")
			return false
	
	# Resolve {emulator_dir} templates
	extract_to = FSM.resolve_emulator_path(extract_to, emulator_id)
	
	if base_url == "":
		push_error("[EmulatorManager] No base_url specified for batch_url_download")
		return false
	
	if cores.is_empty():
		push_error("[EmulatorManager] No cores specified for batch_url_download")
		return false
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Get step name for display
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var emulator_name = emulator.get("name", emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	# Track batch progress using Dictionary for proper reference semantics in closures
	var total_cores = cores.size()
	var progress = {"completed": 0, "failed": 0}
	var failed_cores: Array[String] = []
	var download_ids = []
	
	# Set progress text
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(total_cores) + ")"
	
	# Create a single batch progress notification
	var batch_notification_id = SystemManager.notifications.show_notification(
		step_display_name + " (0/" + str(total_cores) + ")",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		func() -> float:
			return float(progress.completed) / float(total_cores),
		func(_p: float) -> String:
			return step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")",
		false,  # pulsing
		true  # pinned
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
		var destination_path = FSM.join_paths(launch_manager.registry._get_emulator_directory(emulator_id), filename)
		
		# Queue download without auto-extract (extraction happens in separate step)
		# suppress_notification=true to avoid dozens of individual notifications
		var item_id = SystemManager.download.queue_download(
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
				failed_cores.append(core_name)
				push_warning("[EmulatorManager] Core download failed: " + core_name)
			# Update progress
			_emulator_install_progress[emulator_id] = step_display_name + " (" + str(progress.completed) + "/" + str(total_cores) + ")"
			# Check if all downloads are complete
			if progress.completed >= total_cores:
				# Dismiss the batch notification
				SystemManager.notifications.dismiss_notification(batch_notification_id)
				if progress.failed > 0:
					push_error("[EmulatorManager] Batch download failed: " + str(progress.failed) + "/" + str(total_cores) + " cores failed: " + ", ".join(failed_cores))
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
		push_error("[EmulatorManager] No downloads could be queued for batch_url_download")
		SystemManager.notifications.dismiss_notification(batch_notification_id)
		return false
	
	return true

## Executes extract action for a step
func _execute_extract_step(emulator_id: String, step_index: int, extract_config: Dictionary) -> bool:
	var extract_to = extract_config.get("extract_to", ".")
	var strip_top = extract_config.get("strip_top_directory", false)
	var flatten_target = extract_config.get("flatten_target", "")
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	
	# Resolve path using universal resolver
	var extract_dir = FSM.resolve_emulator_path(extract_to, emulator_id)
	
	# Normalize the path to remove "." and ".." components
	extract_dir = FSM.normalize_path(extract_dir)
	
	# Skip extraction only when resuming a partial install. During an update or
	# reinstall the flag is set, so we re-extract the new archive over the old files.
	if not _force_install_step.get(emulator_id, false):
		if _validate_install_step(emulator_id, step_index, install_steps):
			_execute_install_step(emulator_id, step_index + 1)
			return true
	
	# Look for the archive file to extract
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var archive_path = ""
	var is_batch_mode = extract_config.get("batch", false)
	
	if is_batch_mode:
		# Batch mode: extract all matching archives
		return _execute_batch_extract_step(emulator_id, step_index, extract_config, extract_dir, strip_top, flatten_target)
	
	# Single archive mode (default behavior)
	# First, check for explicit expected_file pattern in extract_config
	var expected_file = extract_config.get("expected_file", "")
	print("[EmulatorManager] _execute_extract_step: expected_file pattern='" + expected_file + "'")
	if expected_file != "":
		var files = FSM.list_dir(emulator_dir)
		print("[EmulatorManager] _execute_extract_step: files in emulator_dir=" + str(files))
		for file_name in files:
			print("[EmulatorManager] _execute_extract_step: checking if '" + file_name + "' matches pattern '" + expected_file + "'")
			if file_name.match(expected_file):
				var full_path = FSM.join_paths(emulator_dir, file_name)
				print("[EmulatorManager] _execute_extract_step: MATCH! full_path=" + full_path)
				if FSM.file_exists(full_path):
					archive_path = full_path
					print("[EmulatorManager] _execute_extract_step: archive_path set to " + archive_path)
					break
				else:
					print("[EmulatorManager] _execute_extract_step: file exists check failed for " + full_path)
		print("[EmulatorManager] _execute_extract_step: after expected_file loop, archive_path=" + archive_path)
	
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
	
	var emulator_name = emulator.get("name", emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Notify UI that extraction has started
	launch_manager.emulator_extraction_started.emit(emulator_id)
	
	# Queue extraction via SystemManager.download
	var item_id = SystemManager.download.queue_extraction(archive_path, extract_dir, "emulator", step_display_name)
	if item_id == "":
		push_error("[EmulatorManager] Failed to queue extraction for: " + emulator_id)
		return false
	
	# Create callback for single archive extraction
	var extraction_callback = func(success: bool, _message: String):
		if not success:
			_emulator_install_progress[emulator_id] = "Extraction failed"
			_force_install_step.erase(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			return
		
		# Handle post-extraction flattening
		print("[EmulatorManager] Extraction callback called, strip_top=" + str(strip_top) + ", flatten_target=" + flatten_target)
		if strip_top:
			print("[EmulatorManager] Calling _flatten_extracted_directory with extract_dir=" + extract_dir)
			_flatten_extracted_directory(emulator_id, extract_dir, flatten_target)
		else:
			print("[EmulatorManager] Skipping flattening, strip_top is false")
		
		# Validate extraction
		var validate_config = extract_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[EmulatorManager] Validation failed after extraction: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Validation failed"
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			return
		
		# Notify UI that extraction completed successfully
		launch_manager.emulator_extraction_completed.emit(emulator_id, true)
		
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
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id)
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
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var install_steps = emulator.get("install", [])
	var step_name = ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	
	var emulator_name = emulator.get("name", emulator_id)
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	# Show batch progress
	_emulator_install_progress[emulator_id] = step_display_name + " (0/" + str(archive_paths.size()) + ")"
	
	# Notify UI that extraction has started
	launch_manager.emulator_extraction_started.emit(emulator_id)
	
	# Track progress for multiple extractions using Dictionary (reference type for closures)
	var total_archives = archive_paths.size()
	var progress = {"completed": 0, "failed": 0}
	var extraction_ids = []
	
	# Create a single batch progress notification
	var batch_notification_id = SystemManager.notifications.show_notification(
		step_display_name + " (0/" + str(total_archives) + ")",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		func() -> float:
			return float(progress.completed) / float(total_archives),
		func(_p: float) -> String:
			return step_display_name + " (" + str(progress.completed) + "/" + str(total_archives) + ")",
		false,  # pulsing
		true  # pinned
	)
	
	# Queue extraction for all archives
	for archive_path in archive_paths:
		var item_id = SystemManager.download.queue_extraction(archive_path, extract_dir, "emulator", step_display_name, true, true)
		if item_id == "":
			push_error("[EmulatorManager] Failed to queue extraction for: " + archive_path)
			progress.failed += 1
		else:
			extraction_ids.append(item_id)
	
	if extraction_ids.is_empty():
		push_error("[EmulatorManager] No extractions could be queued for batch: " + emulator_id)
		SystemManager.notifications.dismiss_notification(batch_notification_id)
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
			SystemManager.notifications.dismiss_notification(batch_notification_id)
			
			if progress.failed > 0:
				_emulator_install_progress[emulator_id] = "Extraction failed"
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Handle post-extraction flattening
			if strip_top:
				_flatten_extracted_directory(emulator_id, extract_dir, flatten_target)
			
			# For Android RetroArch, persist a manifest of expected default cores
			# so validation knows exactly which files should be present.
			if emulator_id == "retroarch" and SystemManager.platform.is_android():
				var manifest: Dictionary = launch_manager.core.build_default_core_manifest(emulator_id) as Dictionary
				launch_manager.core.write_manifest(emulator_id, manifest)
			
			# Validate extraction
			var validate_config = extract_config.get("validate", {})
			if not _validate_step(emulator_id, validate_config):
				push_error("[EmulatorManager] Validation failed after batch extraction: " + emulator_id)
				_emulator_install_progress[emulator_id] = "Validation failed"
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
				return
			
			# Notify UI that extraction completed successfully
			launch_manager.emulator_extraction_completed.emit(emulator_id, true)
			
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
			
			if SystemManager.platform.is_android():
				return _is_android_package_installed(package)
			else:
				# On desktop, always return true (package concept doesn't apply)
				return true
		
		"core_manifest":
			# Android RetroArch only: validate that the core manifest is present
			# and every expected default core file exists on disk.
			if not launch_manager or not launch_manager.core:
				return false
			return launch_manager.core.validate_core_manifest(emulator_id) as bool
		
		"always_pass":
			return true
		
		_:
			return false

## Helper function for download_url action
func _handle_download_url_step(emulator_id: String, emulator_name: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var url = platform_config.get("url", "")
	if url == "":
		push_error("[EmulatorManager] No download URL for step '" + step_name + "'")
		return false
	
	var step_display_name = _get_step_display_name(step_name, emulator_name)
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
		push_error("[EmulatorManager] Invalid download_repo config for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = emulator_name + " - Fetching release info..."
	
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	SystemManager.network.fetch_repo_release(
		github_repo,
		asset_pattern,
		func(url: String, tag: String, error: String, file_size: int, published_at: String, asset_updated_at: String):
			if error != "":
				push_error("[EmulatorManager] Failed to fetch release: " + error)
				_emulator_install_progress[emulator_id] = emulator_name + " - Failed to fetch release"
				return
			# Use the later of the release date and the matched asset's update date.
			# Asset updated_at is more reliable for rolling/pinned releases where the
			# release date stays fixed but CI re-uploads new builds.
			var version_to_save = launch_manager.registry._latest_iso_date(published_at, asset_updated_at)
			if version_to_save == "":
				version_to_save = tag
			if version_to_save != "":
				# Defer persistence until the entire install succeeds. Stashing it here
				# and saving it only after all steps complete prevents a failed download
				# or extraction from leaving a falsely "up to date" stored version.
				_pending_emulator_version[emulator_id] = version_to_save
				print("[EmulatorManager] Resolved emulator version for " + emulator_id + ": " + version_to_save)
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
		push_error("[EmulatorManager] Invalid download_scrape config for step: " + step_name)
		return false
	
	# version_pattern is required for HTML scraping, optional for JSON API mode
	if json_path == "" and version_pattern == "":
		push_error("[EmulatorManager] download_scrape requires either version_pattern or json_path for step: " + step_name)
		return false
	
	_emulator_install_progress[emulator_id] = emulator_name + " - Scraping for latest version..."
	
	var step_display_name = _get_step_display_name(step_name, emulator_name)
	
	SystemManager.network.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(url: String, version: String, error: String):
			if error != "":
				push_error("[EmulatorManager] Failed to scrape release: " + error)
				_emulator_install_progress[emulator_id] = emulator_name + " - Failed to scrape release"
				return
			if version != "":
				# Defer persistence until the entire install succeeds. Stashing it here
				# and saving it only after all steps complete prevents a failed download
				# or extraction from leaving a falsely "up to date" stored version.
				_pending_emulator_version[emulator_id] = version
				print("[EmulatorManager] Resolved emulator version for " + emulator_id + ": " + version)
			_queue_emulator_download(emulator_id, emulator_name, step_display_name, url, step_index, platform_config),
		match_strategy,
		json_path
	)
	return true

## Saves the installed emulator version to settings for update checking.
## Only stores the FIRST download step's version to prevent secondary assets
## (e.g. shadPS4 Qt launcher) from clobbering the core version.
## Pass force=true to overwrite an existing version when explicitly needed.
func _save_emulator_version(emulator_id: String, version: String, force: bool = false):
	if DataManager:
		var setting = DataManager.get_setting("installed_emulator_versions")
		if setting:
			var versions = setting.value as Dictionary
			if versions == null:
				versions = {}
			# Only save if not already present (first download step wins), unless force is true
			if not versions.has(emulator_id) or force:
				versions[emulator_id] = version
				DataManager.set_setting(versions, setting)
				DataManager.save_settings()
				print("[EmulatorManager] Saved version for " + emulator_id + ": " + version)
			else:
				print("[EmulatorManager] Skipped saving version for " + emulator_id + " (already exists: " + versions.get(emulator_id, "") + ")")

## Clears stored version so a fresh install/update can save a new version.
func _clear_emulator_version(emulator_id: String):
	if DataManager:
		var setting = DataManager.get_setting("installed_emulator_versions")
		if setting:
			var versions = setting.value as Dictionary
			if versions != null and versions.has(emulator_id):
				versions.erase(emulator_id)
				DataManager.set_setting(versions, setting)
				DataManager.save_settings()

## Helper function for create_folders action
func _handle_create_folders_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var folders = platform_config.get("folders", [])
	if folders.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	for folder_path in folders:
		# Resolve path using universal resolver
		var full_path = FSM.resolve_emulator_path(folder_path, emulator_id)
		
		if not FSM.make_dir_recursive(full_path):
			push_error("[EmulatorManager] Failed to create folder: " + full_path)
			return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for create_files action
func _handle_create_files_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var files = platform_config.get("files", [])
	if files.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	# Get the emulator directory path for placeholder resolution
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
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
		var games_folder_setting = DataManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value.rstrip("/") if games_folder_setting else "user://roms"
		file_content = file_content.replace("{games_dir}", games_dir)
		
		# During an update/reinstall we re-create config files so the new defaults
		# are applied. Otherwise we only create missing files to preserve user edits.
		var should_write = _force_install_step.get(emulator_id, false) or not FSM.file_exists(full_path)
		if should_write:
			if not CSM.write_config(full_path, file_content):
				push_error("[EmulatorManager] Failed to create file: " + full_path)
				return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for creating PCSX2 folder memory card superblock
func _handle_create_pcsx2_superblock_step(emulator_id: String, step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var path = platform_config.get("path", "")
	if path == "":
		push_error("[EmulatorManager] No path specified for create_pcsx2_superblock step: " + step_name)
		return false

	# Use the configured save directory as the base path, which properly resolves
	# to app_data on Android and emulator_dir on desktop
	var save_dir = DataManager.resolve_default_save_directory(emulator_id, "ps2")
	if save_dir == "":
		push_error("[EmulatorManager] No save directory configured for " + emulator_id)
		return false
	
	# The save directory already includes the memcards path from the emulator config,
	# so we use it directly without appending the step path again
	var memcard_path = save_dir.rstrip("/")
	
	var success = DataManager.create_pcsx2_superblock(memcard_path)
	if not success:
		push_error("[EmulatorManager] Failed to create PCSX2 superblock at: " + memcard_path)
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Apply a set of text replacements to an emulator-relative config file.
## Each edit is a Dictionary with "old" and "new". Set "regex": true to treat
## "old" as a RegEx pattern. If create_if_missing is true, the file is created
## when it doesn't exist.
## If append_if_missing is provided, any key not already present is appended under
## the named section (or at the end of the file if section_name is empty).
func edit_emulator_file(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	if emulator_id == "" or file_path == "" or (edits.is_empty() and append_if_missing.is_empty()):
		push_error("[EmulatorManager] Invalid arguments for edit_emulator_file")
		return false
	
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[EmulatorManager] Could not resolve emulator path: " + file_path)
		return false

	return CSM.edit_text(full_path, edits, create_if_missing, append_if_missing, section_name)


## Same as edit_emulator_file, but stores the original file content first so it can be restored later.
func edit_emulator_file_with_backup(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[EmulatorManager] Could not resolve emulator path for backup: " + file_path)
		return false

	CSM.begin_backup(full_path)

	return edit_emulator_file(emulator_id, file_path, edits, create_if_missing, append_if_missing, section_name)

## Restores a file to the content captured by edit_emulator_file_with_backup().
func restore_emulator_file(emulator_id: String, file_path: String) -> bool:
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		push_error("[EmulatorManager] Could not resolve emulator path for restore: " + file_path)
		return false

	return CSM.restore_backup(full_path)

## Returns true if a backup exists for the given emulator file.
func has_emulator_file_backup(emulator_id: String, file_path: String) -> bool:
	var full_path := FSM.resolve_emulator_path(file_path, emulator_id)
	if full_path == "":
		return false
	return CSM.has_backup(full_path)

## Helper function for edit_file action
func _handle_edit_file_step(emulator_id: String, _step_name: String, step_index: int, platform_config: Dictionary) -> bool:
	var file_path = platform_config.get("file", "")
	var edits = platform_config.get("edits", [])
	
	if file_path == "" or edits.is_empty():
		return _execute_install_step(emulator_id, step_index + 1)
	
	if not edit_emulator_file(emulator_id, file_path, edits, true):
		return false
	
	return _execute_install_step(emulator_id, step_index + 1)

## Helper function for none action (skip)
func _handle_none_step(emulator_id: String, _step_name: String, step_index: int) -> bool:
	return _execute_install_step(emulator_id, step_index + 1)

## Creates the save directory for an emulator if it doesn't exist
## Called automatically at the end of successful install flow
## For multi-platform emulators (e.g., RetroArch), creates directories for all supported platforms
func _create_emulator_save_directory(emulator_id: String) -> void:
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return
	
	var platforms = emulator.get("meta", {}).get("platforms", [])
	
	# For single-platform emulators, just create the base directory
	if platforms.size() == 1:
		var save_dir = DataManager.resolve_default_save_directory(emulator_id)
		if save_dir == "":
			print("[EmulatorManager] No save directory configured for: " + emulator_id)
			return
		
		if FSM.dir_exists(save_dir):
			print("[EmulatorManager] Save directory already exists for " + emulator_id + ": " + save_dir)
			return
		
		print("[EmulatorManager] Creating save directory for " + emulator_id + ": " + save_dir)
		var success = FSM.make_dir_recursive(save_dir)
		if not success:
			push_error("[EmulatorManager] Failed to create save directory for " + emulator_id + ": " + save_dir)
		else:
			print("[EmulatorManager] Successfully created save directory for " + emulator_id)
	else:
		# Multi-platform emulator: create save directories for each platform
		print("[EmulatorManager] Creating save directories for multi-platform emulator: " + emulator_id)
		for platform in platforms:
			var save_dir = DataManager.resolve_default_save_directory(emulator_id, platform)
			if save_dir == "":
				continue
			
			if FSM.dir_exists(save_dir):
				continue
			
			print("[EmulatorManager] Creating save directory for " + emulator_id + " / " + platform + ": " + save_dir)
			var success = FSM.make_dir_recursive(save_dir)
			if not success:
				push_error("[EmulatorManager] Failed to create save directory for " + emulator_id + " / " + platform + ": " + save_dir)
			else:
				print("[EmulatorManager] Successfully created save directory for " + emulator_id + " / " + platform)

## Executes install steps from new step-based format (entry point)
func _execute_install_steps(emulator_id: String, _emulator: Dictionary, _install_steps: Array) -> bool:
	# Find the first incomplete step to start from
	var progress = get_install_progress(emulator_id)
	var start_step = 0
	
	if progress["status"] == "partial" and progress["next_step_index"] >= 0:
		start_step = progress["next_step_index"]
	
	# Starting from step 0 means this is a fresh install or a reinstall.
	# Clear any persisted or pending version so the first download step can save
	# the new one and we don't leak a stale resolved version from a prior attempt.
	if start_step == 0:
		_clear_emulator_version(emulator_id)
		_pending_emulator_version.erase(emulator_id)
		# If the emulator was already fully installed, this is a reinstall/update:
		# force all steps to re-run instead of short-circuiting on existing files.
		if progress["status"] == "complete":
			_force_install_step[emulator_id] = true
		else:
			_force_install_step.erase(emulator_id)
	
	return _execute_install_step(emulator_id, start_step)

## Gets display name for a step based on step_name
## Optionally prepends the emulator name for context in notifications
func _get_step_display_name(step_name: String, emulator_name: String = "") -> String:
	# Map step names to user-friendly display names
	var step_label = ""
	match step_name:
		"download_emulator":
			step_label = "Downloading"
		"install_emulator":
			step_label = "Installing"
		"download_cores":
			step_label = "Downloading Cores"
		"install_cores":
			step_label = "Installing Cores"
		"download_system_files":
			step_label = "Downloading System Files"
		"install_system_files":
			step_label = "Installing System Files"
		_:
			# Convert snake_case to Title Case with spaces
			var words = step_name.split("_")
			for i in range(words.size()):
				if i > 0:
					step_label += " "
				step_label += words[i].capitalize()
	
	if emulator_name != "":
		return emulator_name + " - " + step_label
	return step_label

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
	var platform_config = launch_manager.registry._get_step_platform_config(step)
	
	if platform_config.is_empty():
		return false
	
	var _action_type = platform_config.get("action_type", "")
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
	
	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var emulator_name = emulator.get("name", emulator_id)

	if emulator.is_empty():
		return result
	
	var install_steps = emulator.get("install", [])
	result["total_steps"] = install_steps.size()
	
	# Scan each step
	for i in range(install_steps.size()):
		var step = install_steps[i]
		var step_name = step.get("step", "")
		var _step_display_name = _get_step_display_name(step_name, emulator_name)
		if _validate_install_step(emulator_id, i, install_steps):
			result["completed_steps"] += 1
		else:
			# First incomplete step found
			if result["next_step_index"] == -1:
				result["next_step_index"] = i
				result["next_step_name"] = step_name
				result["next_step_display"] = _get_step_display_name(step_name, emulator_name)
	
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
		destination_path = FSM.join_paths(launch_manager.registry._get_emulator_directory(emulator_id), filename)
	
	print("[EmulatorManager] Queueing download for " + emulator_id + ": " + filename + " -> " + destination_path)
	
	_emulator_install_progress[emulator_id] = step_display_name + "..."
	
	# Queue download WITHOUT auto-extract (extract is now a separate step)
	var item_id = SystemManager.download.queue_download(
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
				launch_manager.emulator_extraction_completed.emit(emulator_id, false)
	}

## Checks if an emulator is currently downloading or extracting
## Uses SystemManager.download to check active downloads for this emulator
func is_emulator_downloading(emulator_id: String) -> bool:
	# Check if any active item in SystemManager.download is for this emulator
	for item in SystemManager.download.get_active():
		if item.name == emulator_id or item.name.begins_with(emulator_id):
			return item.status == "downloading" or item.status == "extracting"
	return false

## Checks if an emulator is queued for download
func is_emulator_queued(emulator_id: String) -> bool:
	# Check if any queued item in SystemManager.download is for this emulator
	for item in SystemManager.download.get_queued():
		if item.name == emulator_id or item.name.begins_with(emulator_id):
			return true
	return false

## Gets the active download item for an emulator (if any)
## Returns the SystemManager.download.QueueItem or null
func get_emulator_active_download(emulator_id: String):
	for item_id in _pending_emulator_downloads:
		var task = _pending_emulator_downloads[item_id]
		if task.emulator_id == emulator_id:
			for item in SystemManager.download.get_active():
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
			_pending_emulator_version.erase(emulator_id)
			_force_install_step.erase(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, message)
			return
		
		# Validate download if validation config exists
		var validate_config = step_config.get("validate", {})
		if not _validate_step(emulator_id, validate_config):
			push_error("[EmulatorManager] Download validation failed for: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Download validation failed"
			_pending_emulator_version.erase(emulator_id)
			_force_install_step.erase(emulator_id)
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
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
			push_error("[EmulatorManager] Install step " + str(step_index + 1) + " failed for: " + emulator_id)
			_emulator_install_progress[emulator_id] = "Install step failed"
			launch_manager.emulator_extraction_completed.emit(emulator_id, false)
			task_info.callback.call(false, "Install step failed")
		return
