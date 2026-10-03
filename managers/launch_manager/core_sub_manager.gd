extends Manager
class_name CoreSubManager

## Manager for RetroArch core tracking, validation, and on-demand downloads.
## Cores are downloaded individually from the libretro nightly buildbot on all
## platforms, batched during install via the dynamic default-core manifest.

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

const MANIFEST_FILE_NAME := ".kyodai_core_manifest.json"
const MANIFEST_VERSION := 1

## Parent LaunchManager node. Set in _ready() to avoid relying on the autoload name.
var launch_manager: Node

## Tracks on-demand core downloads that are in flight.
## key: item_id (String), value: {platform_slug, core_id, callback}
var _pending_core_downloads: Dictionary = {}

## Emitted when a single-core download finishes (used by Phase 2 on-demand UI).
signal core_download_completed(platform_slug: String, core_id: String, success: bool)

func _ready():
	launch_manager = get_parent()
	SystemManager.download.extraction_completed.connect(_on_core_extraction_completed)

## Returns the directory cores are extracted into for the given emulator.
func get_core_directory(emulator_id: String = "retroarch") -> String:
	return FSM.resolve_emulator_path("cores", emulator_id)

## Returns the full path to the core manifest file.
func get_manifest_path(emulator_id: String = "retroarch") -> String:
	return FSM.join_paths(get_core_directory(emulator_id), MANIFEST_FILE_NAME)

## Reads the persisted core manifest, returning an empty dictionary on failure.
func read_manifest(emulator_id: String = "retroarch") -> Dictionary:
	var manifest_path := get_manifest_path(emulator_id)
	if not FSM.file_exists(manifest_path):
		return {}
	
	var content := FSM.read_file(manifest_path)
	if content.is_empty():
		return {}
	
	var json := JSON.new()
	if json.parse(content) != OK:
		push_error("[CoreManager] Failed to parse core manifest at " + manifest_path)
		return {}
	
	var data = json.get_data()
	if data is Dictionary:
		return data
	return {}

## Writes the core manifest to disk. Returns true on success.
func write_manifest(emulator_id: String = "retroarch", manifest: Dictionary = {}) -> bool:
	var manifest_path := get_manifest_path(emulator_id)
	var payload := {
		"version": MANIFEST_VERSION,
		"cores": manifest
	}
	var content := JSON.stringify(payload, "\t")
	return FSM.write_file(manifest_path, content)

## Builds the expected manifest for all default cores across all platforms.
## Format: { "platform_slug": { "core_id": "android_mapping" } }
func build_default_core_manifest(emulator_id: String = "retroarch") -> Dictionary:
	var manifest := {}
	var platforms: Array = launch_manager.registry._platforms_data.keys() as Array
	
	for platform_slug in platforms:
		var core_id: String = launch_manager.registry.get_default_core_id_for_platform(emulator_id, platform_slug) as String
		if core_id.is_empty():
			continue
		
		var mapping: String = launch_manager.registry.get_core_for_platform(emulator_id, platform_slug, core_id) as String
		if mapping.is_empty():
			continue
		
		if not manifest.has(platform_slug):
			manifest[platform_slug] = {}
		manifest[platform_slug][core_id] = mapping
	
	return manifest

## Returns the list of core base names (mappings) that should be downloaded for
## the default-core set on Android. Duplicates are removed.
func get_default_core_download_list(emulator_id: String = "retroarch") -> Array[String]:
	var result: Array[String] = []
	var seen := {}
	var manifest := build_default_core_manifest(emulator_id)
	
	for platform_data in manifest.values():
		if platform_data is not Dictionary:
			continue
		for mapping in platform_data.values():
			if mapping is String and not mapping.is_empty() and not seen.has(mapping):
				seen[mapping] = true
				result.append(mapping)
	
	return result

## Returns the expected filesystem path for a specific core binary.
func get_core_expected_path(emulator_id: String, platform_slug: String, core_id: String) -> String:
	var mapping: String = launch_manager.registry.get_core_for_platform(emulator_id, platform_slug, core_id) as String
	if mapping.is_empty():
		return ""
	
	var suffix := _get_core_suffix()
	var core_dir := get_core_directory(emulator_id)
	return FSM.join_paths(core_dir, mapping + suffix)

## Returns the suffix for libretro core binaries on the current platform.
func _get_core_suffix() -> String:
	if SystemManager.platform.is_android():
		return "_libretro_android.so"
	elif SystemManager.platform.is_windows():
		return "_libretro.dll"
	else:
		return "_libretro.so"

## Checks whether a core is present according to the manifest and filesystem.
func is_core_ready(emulator_id: String, platform_slug: String, core_id: String) -> bool:
	if core_id.is_empty():
		return false
	
	var manifest: Dictionary = read_manifest(emulator_id)
	var cores: Dictionary = manifest.get("cores", {}) as Dictionary
	var platform_data: Dictionary = cores.get(platform_slug, {}) as Dictionary
	if not platform_data.has(core_id):
		return false
	
	var expected_path := get_core_expected_path(emulator_id, platform_slug, core_id)
	if expected_path.is_empty():
		return false
	
	return FSM.file_exists(expected_path)

## Validates that every default core listed in the manifest exists on disk.
## This is used as the install-step validation for Android RetroArch.
func validate_core_manifest(emulator_id: String = "retroarch") -> bool:
	var manifest: Dictionary = read_manifest(emulator_id)
	var cores: Dictionary = manifest.get("cores", {}) as Dictionary
	if cores.is_empty():
		push_error("[CoreManager] validate_core_manifest: no manifest found for " + emulator_id)
		return false
	
	for platform_slug in cores.keys():
		var platform_data: Dictionary = cores[platform_slug] as Dictionary
		if platform_data.is_empty():
			push_error("[CoreManager] validate_core_manifest: empty platform data for " + platform_slug)
			return false
		for core_id in platform_data.keys():
			if not is_core_ready(emulator_id, platform_slug, core_id):
				var expected_path := get_core_expected_path(emulator_id, platform_slug, core_id)
				push_error("[CoreManager] validate_core_manifest: missing core %s / %s (expected: %s)" % [platform_slug, core_id, expected_path])
				return false
	return true

## Downloads and extracts a single core for the given platform.
## The callback receives success: bool.
func setup_platform_core(emulator_id: String, platform_slug: String, core_id: String, callback: Callable) -> void:
	var mapping: String = launch_manager.registry.get_core_for_platform(emulator_id, platform_slug, core_id) as String
	if mapping.is_empty():
		push_error("[CoreManager] No core mapping found for %s / %s / %s" % [emulator_id, platform_slug, core_id])
		if callback.is_valid():
			callback.call(false)
		return
	
	var download_url := _get_core_download_url(emulator_id, mapping)
	if download_url.is_empty():
		push_error("[CoreManager] No download URL configured for core %s on %s" % [mapping, emulator_id])
		if callback.is_valid():
			callback.call(false)
		return
	
	var emulator_dir: String = launch_manager.registry._get_emulator_directory(emulator_id) as String
	var filename := mapping + _get_core_suffix() + ".zip"
	var destination_path := FSM.join_paths(emulator_dir, filename)
	var extract_dir := get_core_directory(emulator_id)
	
	# Check if a download for this URL is already in progress. If so, attach to it
	# rather than starting a duplicate.
	var existing_item_id := _find_existing_core_download(download_url)
	if existing_item_id != "":
		print("[CoreManager] Core download already in progress, attaching: " + download_url)
		_pending_core_downloads[existing_item_id] = {
			"platform_slug": platform_slug,
			"core_id": core_id,
			"callback": callback
		}
		return
	
	print("[CoreManager] Downloading core for %s: %s" % [platform_slug, download_url])
	var item_id := SystemManager.download.queue_download(
		download_url,
		destination_path,
		"emulator_core",
		mapping + " core",
		true,   # auto_extract
		extract_dir,
		null,   # game
		{},     # callbacks
		0,      # romm_id
		true,   # delete_after_extract
		false   # suppress_notification
	)
	
	if item_id == "":
		push_error("[CoreManager] Failed to queue core download: " + download_url)
		if callback.is_valid():
			callback.call(false)
		return
	
	_pending_core_downloads[item_id] = {
		"platform_slug": platform_slug,
		"core_id": core_id,
		"callback": callback
	}

## Resolves the buildbot download URL for a single core mapping from the emulator registry.
func _get_core_download_url(emulator_id: String, mapping: String) -> String:
	var emulator: Dictionary = launch_manager.registry.get_emulator(emulator_id) as Dictionary
	if emulator.is_empty():
		return ""
	
	var install_steps: Array = emulator.get("install", []) as Array
	for step in install_steps:
		if step is not Dictionary:
			continue
		var step_dict: Dictionary = step as Dictionary
		if step_dict.get("step", "") != "download_cores":
			continue
		var platform_config: Dictionary = launch_manager.registry._get_step_platform_config(step_dict) as Dictionary
		if platform_config.is_empty():
			continue
		var base_url: String = platform_config.get("base_url", "") as String
		var url_pattern: String = platform_config.get("url_pattern", "{name}") as String
		if base_url.is_empty():
			continue
		var filename := url_pattern.replace("{name}", mapping)
		return base_url + filename
	
	return ""

## Searches the SystemManager.download queue and active items for an in-progress core
## download matching the given URL. Returns the item_id or empty string.
func _find_existing_core_download(url: String) -> String:
	for item in SystemManager.download.get_active():
		if item.url == url and item.type == "emulator_core":
			return item.id
	for item in SystemManager.download.get_queued():
		if item.url == url and item.type == "emulator_core":
			return item.id
	return ""

## Handles completion of an auto-extracted core download.
func _on_core_extraction_completed(item_id: String, success: bool, message: String):
	if not _pending_core_downloads.has(item_id):
		return
	
	var info: Dictionary = _pending_core_downloads[item_id] as Dictionary
	_pending_core_downloads.erase(item_id)
	
	var platform_slug: String = info.get("platform_slug", "") as String
	var core_id: String = info.get("core_id", "") as String
	var callback: Callable = info.get("callback", Callable()) as Callable
	
	if not success:
		push_error("[CoreManager] Core extraction failed: " + message)
		if callback.is_valid():
			callback.call(false)
		core_download_completed.emit(platform_slug, core_id, false)
		return
	
	# Mark the core installed in the manifest.
	if not mark_core_installed("retroarch", platform_slug, core_id):
		push_error("[CoreManager] Failed to update core manifest for %s / %s" % [platform_slug, core_id])
		if callback.is_valid():
			callback.call(false)
		core_download_completed.emit(platform_slug, core_id, false)
		return
	
	if callback.is_valid():
		callback.call(true)
	core_download_completed.emit(platform_slug, core_id, true)

## Updates the manifest entry for a single core and persists it.
## Used after extraction and by on-demand downloads in Phase 2.
func mark_core_installed(emulator_id: String, platform_slug: String, core_id: String) -> bool:
	var installed: Dictionary = read_manifest(emulator_id).get("cores", {}) as Dictionary
	
	# Preserve existing entries and add/update the requested one.
	if installed.is_empty():
		installed = {}
	
	var mapping: String = launch_manager.registry.get_core_for_platform(emulator_id, platform_slug, core_id) as String
	if mapping.is_empty():
		return false
	
	if not installed.has(platform_slug):
		installed[platform_slug] = {}
	installed[platform_slug][core_id] = mapping
	
	return write_manifest(emulator_id, installed)
