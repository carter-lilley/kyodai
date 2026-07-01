extends Manager
class_name RegistryManager

## Read-only emulator registry lookup and update checking

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

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

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
		
		launch_manager.emulator_registry_loaded.emit(true)
	else:
		push_error("[RegistryManager] Failed to open emulators directory: " + REGISTRY_DIR)
		launch_manager.emulator_registry_loaded.emit(false)

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
		var platforms = emulator.get("meta", {}).get("platforms", [])
		
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

## Helper: Recursively searches for executable file up to max_depth (3 levels)
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

## Returns the raw core array for a platform from an emulator's registry data.
## Each entry is a Dictionary with id/name/mapping/save_name/default etc.
func get_cores_for_platform(emulator_id: String, platform_slug: String) -> Array[Dictionary]:
	var emulator = get_emulator(emulator_id)
	if emulator.is_empty():
		return []
	
	var cores = emulator.get("cores", {})
	var platform_cores = cores.get(platform_slug, [])
	
	# Backward compatibility: old single-core dicts become single-element arrays.
	if platform_cores is Dictionary:
		var migrated: Array[Dictionary] = []
		var copy = platform_cores.duplicate()
		if not copy.has("id"):
			copy["id"] = copy.get("mapping", platform_slug)
		if not copy.has("name"):
			copy["name"] = copy.get("save_name", copy["id"])
		migrated.append(copy)
		return migrated
	
	if platform_cores is Array:
		var result: Array[Dictionary] = []
		for core in platform_cores:
			if core is Dictionary:
				if core.get("desktop_only", false) and PlatformManager.is_android():
					continue
				if core.get("android_only", false) and not PlatformManager.is_android():
					continue
				result.append(core.duplicate())
		return result
	
	return []

## Gets the default core id for a platform, falling back to the first available core.
func get_default_core_id_for_platform(emulator_id: String, platform_slug: String) -> String:
	var cores = get_cores_for_platform(emulator_id, platform_slug)
	
	for core in cores:
		if core.get("default", false):
			return core.get("id", "")
	
	if cores.size() > 0:
		return cores[0].get("id", "")
	
	return ""

## Looks up a specific core config by id for a platform.
func get_core_config(emulator_id: String, platform_slug: String, core_id: String) -> Dictionary:
	if core_id == "":
		return {}
	
	var cores = get_cores_for_platform(emulator_id, platform_slug)
	for core in cores:
		if core.get("id", "") == core_id:
			return core
	return {}

## Gets the OS-specific libretro core base name for a platform/core (for RetroArch-style emulators).
## Returns the desktop "mapping" or Android "android_mapping" when available.
func get_core_for_platform(emulator_id: String, platform_slug: String, core_id: String = "") -> String:
	var core = get_core_config(emulator_id, platform_slug, core_id)
	if core.is_empty():
		core = get_core_config(emulator_id, platform_slug, get_default_core_id_for_platform(emulator_id, platform_slug))
	
	if core.is_empty():
		return ""
	
	if PlatformManager.is_android():
		var android_mapping = core.get("android_mapping", "")
		if android_mapping != "":
			return android_mapping
	
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

## Gets the RetroArch core id for a platform from platforms.json
## This is the default core id used when no user/game override exists.
func get_retroarch_core_name(platform_slug: String) -> String:
	var platform = _platforms_data.get(platform_slug, {})
	return platform.get("retroarch_core", "")

## Checks for updates across all installed emulators
## callback(updated: Array, up_to_date: Array, failed: Array, failed_details: Dictionary)
## progress_callback(completed: int, total: int) - fires per async check completion
func check_for_updates(callback: Callable, progress_callback: Callable = Callable()):
	if not SettingsManager:
		callback.call([], [], [], {})
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
		"failed_details": {},
		"pending": 0,
		"total": 0,
		"completed": 0
	}
	
	var all_emulators = get_all_emulators()
	
	for emulator in all_emulators:
		var emulator_id = emulator.get("id", "")
		if emulator_id == "":
			continue
		
		var progress = launch_manager.emulator.get_install_progress(emulator_id)
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
			print("[RegistryManager] Emulator %s installed but no version stored - triggering reinstall" % emulator_id)
			results.updated.append(emulator_id)
			_trigger_emulator_update(emulator_id, emulator.get("name", emulator_id), platform_config)
			continue
		
		var installed_version = installed_versions[emulator_id]
		
		match action_type:
			"download_scrape":
				results.pending += 1
				_check_scrape_update(emulator_id, emulator.get("name", emulator_id), installed_version, platform_config, results, callback, progress_callback)
			"download_repo":
				results.pending += 1
				_check_repo_update(emulator_id, emulator.get("name", emulator_id), installed_version, platform_config, results, callback, progress_callback)
			"download_url":
				# Hardcoded URL - can't check for updates automatically
				results.up_to_date.append(emulator_id)
	
	# If nothing was pending and nothing was auto-updated, call callback immediately
	if results.pending == 0 and results.updated.is_empty():
		callback.call(results.updated, results.up_to_date, results.failed, results.failed_details)
		return

	# Set total for progress tracking and fire initial progress
	results.total = results.pending
	if results.pending == 0:
		callback.call(results.updated, results.up_to_date, results.failed, results.failed_details)
		return
	if not progress_callback.is_null():
		progress_callback.call(0, results.total)

## Internal helper to check if all pending checks are done
func _check_updates_complete(results: Dictionary, callback: Callable, progress_callback: Callable = Callable()):
	results.pending -= 1
	results.completed += 1
	if not progress_callback.is_null():
		progress_callback.call(results.completed, results.total)
	if results.pending <= 0:
		callback.call(results.updated, results.up_to_date, results.failed, results.failed_details)

## Checks for a scrape-based update
func _check_scrape_update(emulator_id: String, emulator_name: String, installed_version: String, platform_config: Dictionary, results: Dictionary, callback: Callable, progress_callback: Callable = Callable()):
	var scrape_url = platform_config.get("scrape_url", "")
	var version_pattern = platform_config.get("version_pattern", "")
	var url_template = platform_config.get("url_template", "")
	var match_strategy = platform_config.get("match_strategy", "first")
	var json_path = platform_config.get("json_path", "")
	
	if scrape_url == "" or url_template == "":
		results.failed.append(emulator_id)
		results.failed_details[emulator_id] = "Invalid scrape configuration"
		_check_updates_complete(results, callback, progress_callback)
		return
	
	# version_pattern is required for HTML scraping, optional for JSON API mode
	if json_path == "" and version_pattern == "":
		results.failed.append(emulator_id)
		results.failed_details[emulator_id] = "Invalid scrape configuration"
		_check_updates_complete(results, callback, progress_callback)
		return
	
	NetworkManager.fetch_scraped_release(
		scrape_url,
		version_pattern,
		url_template,
		func(_url: String, version: String, error: String):
			if error != "" or version == "":
				results.failed.append(emulator_id)
				results.failed_details[emulator_id] = error if error != "" else "No version found"
				_check_updates_complete(results, callback, progress_callback)
				return
			
			# Check for format mismatch before comparing. If installed version
			# is a date but remote is a tag (or vice versa), we can't compare
			# reliably and should treat it as needing an update.
			var installed_is_date = _is_date_version(installed_version)
			var remote_is_date = _is_date_version(version)
			
			if installed_is_date != remote_is_date:
				# Mixed formats - can't compare, assume update needed
				results.updated.append(emulator_id)
				print("[RegistryManager] " + emulator_id + " version format mismatch ('" + installed_version + "' vs '" + version + "'), assuming update needed")
				_trigger_emulator_update(emulator_id, emulator_name, platform_config)
			else:
				var comparison = _compare_versions(installed_version, version)
				if comparison == -1 or comparison == 2:
					# Update available or incomparable (treat as update)
					results.updated.append(emulator_id)
					_trigger_emulator_update(emulator_id, emulator_name, platform_config)
				else:
					results.up_to_date.append(emulator_id)
			
			_check_updates_complete(results, callback, progress_callback),
		match_strategy,
		json_path
	)

## Checks for a repo-based update
func _check_repo_update(emulator_id: String, emulator_name: String, installed_version: String, platform_config: Dictionary, results: Dictionary, callback: Callable, progress_callback: Callable = Callable()):
	var github_repo = platform_config.get("github_repo", "")
	var asset_pattern = platform_config.get("asset_pattern", "")
	var release_tag = platform_config.get("release_tag", "")
	var api_base_url = platform_config.get("api_base_url", "")
	
	if github_repo == "" or asset_pattern == "":
		results.failed.append(emulator_id)
		results.failed_details[emulator_id] = "Invalid repo configuration"
		_check_updates_complete(results, callback, progress_callback)
		return
	
	NetworkManager.fetch_repo_release(
		github_repo,
		asset_pattern,
		func(_url: String, tag: String, error: String, _file_size: int, published_at: String, asset_updated_at: String):
			if error != "" or tag == "":
				results.failed.append(emulator_id)
				results.failed_details[emulator_id] = error if error != "" else "No matching release asset found"
				_check_updates_complete(results, callback, progress_callback)
				return
			
			var update_available = false
			
			# Primary: use the later of the release date and the matched asset's
			# update date. Asset updated_at catches rolling/pinned releases where
			# the release date stays fixed but CI uploads new builds.
			var remote_date_str = _latest_iso_date(published_at, asset_updated_at)
			if remote_date_str != "":
				var remote_date = _parse_iso_date(remote_date_str)
				var installed_date = _parse_iso_date(installed_version)
				
				if remote_date > 0 and installed_date > 0:
					# Both are dates - compare directly
					if remote_date > installed_date:
						update_available = true
						print("[RegistryManager] Update available for " + emulator_id + ": " + remote_date_str + " > " + installed_version)
					else:
						print("[RegistryManager] " + emulator_id + " is up to date: " + installed_version)
				else:
					# Installed version is not a date (legacy format), assume update needed
					print("[RegistryManager] " + emulator_id + " has legacy version format, triggering update")
					update_available = true
			else:
				# Fallback: no dates available from API. Determine what each
				# version represents and compare accordingly.
				var installed_is_date = _is_date_version(installed_version)
				var tag_is_date = _is_date_version(tag)
				
				if installed_is_date and tag_is_date:
					# Both are dates - compare timestamps
					var remote_date = _parse_iso_date(tag)
					var installed_date = _parse_iso_date(installed_version)
					if remote_date > installed_date:
						update_available = true
						print("[RegistryManager] Update available for " + emulator_id + ": " + tag + " > " + installed_version)
					else:
						print("[RegistryManager] " + emulator_id + " is up to date: " + installed_version)
				elif installed_is_date != tag_is_date:
					# Mixed formats (date vs tag) - can't compare, assume update needed
					update_available = true
					print("[RegistryManager] " + emulator_id + " version format mismatch ('" + installed_version + "' vs '" + tag + "'), assuming update needed")
				else:
					# Both are version tags - semver comparison
					var comparison = _compare_versions(installed_version, tag)
					if comparison == -1 or comparison == 2:
						update_available = true
						print("[RegistryManager] Update available for " + emulator_id + ": " + tag + " > " + installed_version)
					else:
						print("[RegistryManager] " + emulator_id + " is up to date: " + installed_version)
			
			if update_available:
				results.updated.append(emulator_id)
				_trigger_emulator_update(emulator_id, emulator_name, platform_config)
			else:
				results.up_to_date.append(emulator_id)
			
			_check_updates_complete(results, callback, progress_callback),
		release_tag,
		api_base_url
	)

## Triggers re-installation of an emulator for update
func _trigger_emulator_update(emulator_id: String, _emulator_name: String, _platform_config: Dictionary):
	print("[RegistryManager] Triggering update for: " + emulator_id)
	
	# Clear install progress to force fresh install
	launch_manager.emulator._emulator_install_progress.erase(emulator_id)
	
	# Clear stored version so the first download step can save the new version
	launch_manager.emulator._clear_emulator_version(emulator_id)
	launch_manager.emulator._pending_emulator_version.erase(emulator_id)
	launch_manager.emulator._force_install_step[emulator_id] = true
	
	# Start installation from step 0
	launch_manager.emulator._execute_install_step(emulator_id, 0)

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

## Returns true if a version string looks like an ISO 8601 date
func _is_date_version(version: String) -> bool:
	return _parse_iso_date(version) > 0

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

## Parses an ISO 8601 date string to unix timestamp for comparison.
## Delegates to SaveManager for a single, timezone-aware implementation.
func _parse_iso_date(date_str: String) -> int:
	return SaveManager.parse_iso_timestamp(date_str)

## Returns the later of two ISO 8601 date strings.
## If only one is valid, returns that one. If neither is valid, returns "".
func _latest_iso_date(a: String, b: String) -> String:
	var ta = _parse_iso_date(a)
	var tb = _parse_iso_date(b)
	if ta > 0 and tb > 0:
		return a if ta > tb else b
	if ta > 0:
		return a
	if tb > 0:
		return b
	return ""
