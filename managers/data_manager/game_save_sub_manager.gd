extends Manager
class_name GameSaveSubManager

## Manages save file discovery and syncing with RomM server

signal save_sync_completed(game: GameResource, success: bool, message: String)

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const SLOT_DEFAULT := ""
const MAX_FILE_SIZE := 100 * 1024 * 1024

# In-memory cache for discovered emulator profiles
var _emulator_profile_cache: Dictionary = {}

# Strategy pattern lookup table for emulator-specific save operations
var _emulator_strategies: Dictionary = {}

# Re-entrancy guards: one save-sync flow per game+emulator, one conflict dialog at a time
var _save_sync_in_flight: Dictionary = {}  # "romm_id:emulator_id" -> true
var _conflict_dialog_open: bool = false
signal _conflict_dialog_closed

func _save_sync_key(game: GameResource, emulator_id: String) -> String:
	return str(game.romm_id) + ":" + emulator_id

func _begin_save_sync(key: String) -> void:
	_save_sync_in_flight[key] = true

func _end_save_sync(key: String) -> void:
	_save_sync_in_flight.erase(key)

## Runs save-discovery/zip work off the main thread when safe. Android restricted
## paths (/Android/data, /Android/obb) go through the PackageChecker plugin whose
## worker-thread behavior is unverified - a false empty scan could trigger a
## remote-over-local download, so those run inline on the calling thread.
func _should_thread_io(path: String) -> bool:
	if SystemManager.platform.is_android():
		var normalized = path.replace("\\", "/")
		if normalized.contains("/Android/data/") or normalized.contains("/Android/obb/"):
			return false
	return true

func _run_io_task(path: String, work: Callable, callback: Callable) -> void:
	if _should_thread_io(path):
		MemorySubManager.queue_extraction_task(work, callback)
	else:
		callback.call(work.call())

func _ready() -> void:
	_init_strategies()
	_cleanup_all_temp_dirs()

## Cleans up all temp directories under user://temp_saves/
func _cleanup_all_temp_dirs() -> void:
	var temp_base = "user://temp_saves"
	if not FSM.dir_exists(temp_base):
		return
	var items = FSM.list_dir(temp_base + "/")
	for item in items:
		if item == "." or item == "..":
			continue
		var full_path = temp_base + "/" + item
		if FSM.dir_exists(full_path):
			print("[GameSaveSubManager] Cleaning up temp directory: " + full_path)
			FSM.delete_dir_recursive(full_path)

## Initializes the emulator strategy lookup table
func _init_strategies() -> void:
	_emulator_strategies = {
		"cemu": {
			"validate": func(tid: String) -> String:
				return "" if tid.length() == 16 else "Invalid Title ID for Cemu game.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_cemu_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id().substr(8, 8)),
			"extract_dest": func(_save_dir: String, record_path: String, _game: GameResource, _zip: String) -> String:
				return record_path.get_base_dir(),
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id().substr(8, 8),
			"zip": func(src: String, dst: String, game: GameResource) -> bool:
				return FSM.zip_directory(src, dst, -1, game.get_active_title_id().substr(8, 8)),
		},
		"dolphin": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No game ID available for this Dolphin game.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				if game.platform_slug == "wii":
					return discover_local_dolphin_wii_save(dir, game.get_active_title_id())
				return discover_local_dolphin_gc_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				if game.platform_slug == "wii":
					return FSM.join_paths(dir, _game_id_to_hex(game.get_active_title_id()))
				return dir,
			"extract_dest": func(save_dir: String, _record_path: String, game: GameResource, _zip: String) -> String:
				if game.platform_slug == "wii":
					return FSM.join_paths(save_dir, _game_id_to_hex(game.get_active_title_id()))
				return save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				if game.platform_slug == "wii":
					return _game_id_to_hex(game.get_active_title_id())
				return game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				return FSM.zip_directory(src, dst),
		},
		"eden": {
			"validate": func(tid: String) -> String:
				return "" if tid.length() == 16 else "Invalid Title ID for Eden game.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				var emu_dir = LaunchManager._get_emulator_directory("eden")
				return discover_local_eden_save(dir, game.get_active_title_id(), emu_dir),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				var emu_dir = LaunchManager._get_emulator_directory("eden")
				var profile_result = _discover_eden_profile(emu_dir)
				return FSM.join_paths(dir, "0000000000000000", profile_result.profile_id, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, record_path: String, _game: GameResource, _zip: String) -> String:
				return record_path,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				return FSM.zip_directory(src, dst),
		},
		"pcsx2": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No serial available for this PS2 game. Launch it once to extract the serial.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_pcsx2_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, _game: GameResource) -> String:
				return dir,
			"extract_dest": func(save_dir: String, _record_path: String, game: GameResource, zip_file_name: String) -> String:
				var folder_name: String
				if zip_file_name != "":
					folder_name = zip_file_name.get_basename()
				else:
					folder_name = game.get_active_title_id()
				return FSM.join_paths(save_dir, folder_name),
			"save_name": func(game: GameResource, local_file_path: String) -> String:
				return local_file_path.get_file() if local_file_path != "" else game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				return FSM.zip_directory(src, dst),
		},
		"ppsspp": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No game ID available for this PSP game. Launch it once to extract the ID.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_psp_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, local_file_path: String) -> String:
				return local_file_path.get_file() if local_file_path != "" else game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				var folder_name = src.get_file()
				return FSM.zip_directory(src, dst, MAX_FILE_SIZE, folder_name),
		},
		"vita3k": {
			"validate": func(tid: String) -> String:
				return "" if tid != "" else "No Title ID available for this Vita game. Launch it once to extract the Title ID.",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_vita3k_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				var folder_name = src.get_file()
				return FSM.zip_directory(src, dst, -1, folder_name),
		},
		"rpcs3": {
			"validate": func(tid: String) -> String:
				if tid == "":
					return "No Title ID available for this PS3 game. Launch it once to extract the Title ID."
				if tid.length() != 9:
					return "Invalid Title ID for PS3 game."
				return "",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_rpcs3_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				var folder_name = src.get_file()
				return FSM.zip_directory(src, dst, -1, folder_name),
		},
		"shadps4": {
			"validate": func(tid: String) -> String:
				if tid == "":
					return "No Title ID available for this PS4 game. Launch it once to extract the Title ID."
				if tid.length() != 9:
					return "Invalid Title ID for PS4 game."
				return "",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_shadps4_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return FSM.join_paths(dir, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				var folder_name = src.get_file()
				return FSM.zip_directory(src, dst, -1, folder_name),
		},
		"xenia": {
			"validate": func(tid: String) -> String:
				if tid == "":
					return "No Title ID available for this Xbox 360 game. Launch it once to extract the Title ID."
				if tid.length() != 8:
					return "Invalid Title ID for Xbox 360 game."
				return "",
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return discover_local_xenia_save(dir, game.get_active_title_id()),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				var profile = _find_first_subdir(dir)
				if profile == "":
					profile = "0000000000000000"
				return FSM.join_paths(dir, profile, game.get_active_title_id()),
			"extract_dest": func(_save_dir: String, _record_path: String, _game: GameResource, _zip: String) -> String:
				return _save_dir,
			"save_name": func(game: GameResource, _path: String) -> String:
				return game.get_active_title_id(),
			"zip": func(src: String, dst: String, _game: GameResource) -> bool:
				var folder_name = src.get_file()
				return FSM.zip_directory(src, dst, -1, folder_name),
		},
		"azahar": {
			"resolve_path": func(dir: String, game: GameResource) -> String:
				var short_title_id = game.get_active_title_id().substr(8, 8)
				return FSM.join_paths(dir, short_title_id),
			"extract_dest": func(_save_dir: String, record_path: String, _game: GameResource, _zip: String) -> String:
				return record_path,
		},
		"retroarch": {
			"discover": func(dir: String, game: GameResource) -> Array[Dictionary]:
				return _discover_retroarch_save(dir, game),
			"resolve_path": func(dir: String, game: GameResource) -> String:
				return _resolve_retroarch_save_path(dir, game),
			"extract_dest": func(save_dir: String, record_path: String, game: GameResource, _zip: String) -> String:
				return _get_retroarch_extract_dest(save_dir, record_path, game),
			"save_name": func(game: GameResource, local_file_path: String) -> String:
				return _get_retroarch_save_name(game, local_file_path),
			"zip": func(src: String, dst: String, game: GameResource) -> bool:
				return _zip_retroarch_save(src, dst, game),
		},
	}

func _get_strategy(emulator_id: String, strategy_name: String) -> Callable:
	if not _emulator_strategies.has(emulator_id):
		return Callable()
	var strategies = _emulator_strategies[emulator_id] as Dictionary
	if not strategies.has(strategy_name):
		return Callable()
	return strategies[strategy_name] as Callable

## Cleans up empty parent directories after removing a temp file
func _cleanup_temp_dir(file_path: String) -> void:
	var parent = file_path.get_base_dir()
	while parent != "" and parent != "user://" and parent != "res://":
		if FSM.dir_exists(parent):
			var items = FSM.list_dir(parent + "/")
			var has_files = false
			for item in items:
				if item != "." and item != "..":
					has_files = true
					break
			if not has_files:
				print("[GameSaveSubManager] Removing empty temp directory: " + parent)
				FSM.delete_dir_recursive(parent)
				parent = parent.get_base_dir()
			else:
				break
		else:
			break

## Resolves the default save directory for an emulator from the registry config.
## This is the "fallback" path based purely on the emulator JSON configuration.
## Optional platform_slug for resolving platform-specific paths (e.g., RetroArch {core_name}, Dolphin ngc/wii)
func resolve_default_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var paths = emulator.get("paths", {})
	var _saves = paths.get("saves", {})
	
	# Check core-specific config first (for RetroArch multi-core saves)
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	
	var directories = config.get("directories", {})
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")
	
	if dir == "":
		return ""
	
	# Use the full emulator path resolver with all wildcards
	dir = FSM.resolve_emulator_path(dir, emulator_id, platform_slug)
	
	return dir.rstrip("/") + "/"

## Returns the saves config dict for an emulator/core/platform combination.
## Priority: core-specific > platform-specific > _default.
func _get_save_config(emulator_id: String, platform_slug: String, core_id: String) -> Dictionary:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return {}
	
	var paths = emulator.get("paths", {})
	var saves = paths.get("saves", {})
	
	# For RetroArch, check core-specific config first
	if emulator_id == "retroarch" and core_id != "":
		var core_config = LaunchManager.registry.get_core_config(emulator_id, platform_slug, core_id)
		var core_paths = core_config.get("paths", {})
		var core_saves = core_paths.get("saves", {})
		if not core_saves.is_empty():
			return core_saves
	
	if platform_slug != "" and saves.has(platform_slug):
		return saves[platform_slug]
	
	return saves.get("_default", {})

## Resolves all candidate save directories for an emulator.
## On desktop this returns a single path. On Android it returns both the
## {app_data} path and the {emulator_dir} path so we can check which one
## is actively being used.
func resolve_save_directories(emulator_id: String, platform_slug: String = "", core_id: String = "") -> Array[String]:
	var candidates: Array[String] = []
	
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return candidates
	
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	
	var directories = config.get("directories", {})
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")
	
	if dir == "":
		return candidates
	
	# Default candidate using the platform's normal resolver
	var default_path = FSM.resolve_emulator_path(dir, emulator_id, platform_slug)
	candidates.append(default_path.rstrip("/") + "/")
	
	# On Android, always generate both {app_data} and {emulator_dir} variants
	# so the active-directory picker can choose whichever one has saves.
	if SystemManager.platform.is_android():
		var app_data_variant = dir.replace("{emulator_dir}", "{app_data}")
		var emulator_dir_variant = dir.replace("{app_data}", "{emulator_dir}")
		
		if app_data_variant != dir:
			var app_data_path = FSM.resolve_emulator_path(app_data_variant, emulator_id, platform_slug).rstrip("/") + "/"
			if not app_data_path in candidates:
				candidates.append(app_data_path)
		
		if emulator_dir_variant != dir:
			var emulator_dir_path = FSM.resolve_emulator_path(emulator_dir_variant, emulator_id, platform_slug).rstrip("/") + "/"
			if not emulator_dir_path in candidates:
				candidates.append(emulator_dir_path)
	
	return candidates

## Resolves the actively-used save directory for an emulator.
## Checks all candidate directories and picks the one with the most recent
## modification time. Falls back to the default (app_data on Android) if
## none exist or have recent activity.
func resolve_active_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	var candidates = resolve_save_directories(emulator_id, platform_slug, core_id)
	if candidates.is_empty():
		return ""
	
	var best_dir = ""
	var best_mtime = 0
	
	for candidate in candidates:
		if FSM.dir_exists(candidate):
			var mtime = FSM.get_modified_time(candidate)
			if mtime > best_mtime:
				best_dir = candidate
				best_mtime = mtime
	
	# If no candidate exists yet, fall back to the default (first candidate)
	if best_dir == "":
		best_dir = candidates[0]
	
	return best_dir

## Backward-compatible alias that returns the default save directory.
## Install-time and directory-creation code should use this.
func resolve_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	return resolve_default_save_directory(emulator_id, platform_slug, core_id)

## Ensures the save directory for an emulator exists, creating it if necessary
## Returns true if directory exists or was created successfully
func _ensure_save_directory_exists(emulator_id: String, save_dir: String = "") -> bool:
	if save_dir == "":
		save_dir = resolve_active_save_directory(emulator_id)
	if save_dir == "":
		print("[GameSaveSubManager] No save directory configured for: " + emulator_id)
		return false
	
	if FSM.dir_exists(save_dir):
		return true
	
	print("[GameSaveSubManager] Creating save directory for " + emulator_id + ": " + save_dir)
	var success = FSM.make_dir_recursive(save_dir)
	if not success:
		push_error("[GameSaveSubManager] Failed to create save directory for " + emulator_id + ": " + save_dir)
		return false
	
	print("[GameSaveSubManager] Successfully created save directory for " + emulator_id)
	return true

## Gets the save file extensions for an emulator
func get_save_extensions(emulator_id: String, platform_slug: String = "", core_id: String = "") -> Array[String]:
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	var extensions = config.get("extensions", [])
	var result: Array[String] = []
	for ext in extensions:
		if ext is String:
			result.append(ext)
	return result

## Discovers local save files for a game in the given directory
## Searches recursively for files matching: {rom_name_no_ext}{extension}
## Returns array of dictionaries: [{file_name, file_path, modified_time, extension}, ...]
func discover_local_saves(directory: String, rom_name_no_ext: String, extensions: Array[String]) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or extensions.is_empty():
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	_search_directory_for_saves(directory, rom_name_no_ext, extensions, results)
	return results

func _search_directory_for_saves(dir_path: String, rom_name_no_ext: String, extensions: Array[String], results: Array[Dictionary]) -> void:
	var items = FSM.list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var full_path = dir_path + item
		if FSM.dir_exists(full_path):
			_search_directory_for_saves(full_path + "/", rom_name_no_ext, extensions, results)
		elif FSM.file_exists(full_path):
			var item_no_ext = item.get_basename()
			var item_ext = item.get_extension()
			if item_no_ext == rom_name_no_ext:
				var dot_ext = "." + item_ext
				if dot_ext in extensions:
					var modified_time = FSM.get_modified_time(full_path)
					results.append({
						"file_name": item,
						"file_path": full_path,
						"modified_time": modified_time,
						"extension": dot_ext
					})

func uses_folder_saves(emulator_id: String, platform_slug: String = "", core_id: String = "") -> bool:
	var config: Dictionary = _get_save_config(emulator_id, platform_slug, core_id)
	return config.get("uses_folder_saves", false)

func discover_local_folder_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	var category = title_id.substr(0, 8)
	var short_title_id = title_id.substr(8, 8)
	
	var id0_dirs = FSM.list_dir(directory)
	for id0 in id0_dirs:
		if id0 == "." or id0 == ".." or not FSM.dir_exists(FSM.join_paths(directory, id0)):
			continue
		var id0_path = FSM.join_paths(directory, id0)
		var id1_dirs = FSM.list_dir(id0_path)
		for id1 in id1_dirs:
			if id1 == "." or id1 == ".." or not FSM.dir_exists(FSM.join_paths(id0_path, id1)):
				continue
			var title_path = FSM.join_paths(id0_path, id1, "title", category, short_title_id)
			if FSM.dir_exists(title_path):
				var mtime = _get_folder_mtime(title_path)
				results.append({
					"file_name": short_title_id + ".zip",
					"file_path": title_path,
					"modified_time": mtime,
					"extension": ".zip"
				})
				return results
	
	return results

func discover_local_cemu_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	var short_title_id = title_id.substr(8, 8)
	var save_path = FSM.join_paths(directory, short_title_id)
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": short_title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		return results
	
	return results

func discover_local_dolphin_gc_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	# Find all matching GCI files
	var gci_files: Array[String] = []
	var items = FSM.list_dir(directory)
	for item in items:
		if item == "." or item == "..":
			continue
		if item.to_lower().ends_with(".gci") and game_id.to_lower() in item.to_lower():
			gci_files.append(FSM.join_paths(directory, item))
	
	if gci_files.is_empty():
		return results
	
	# Create a temp zip bundle with all matching GCI files
	var zip_path = "user://temp_saves/" + game_id + ".zip"
	FSM.make_dir_recursive(zip_path.get_base_dir())
	
	var zip_success = _zip_gci_files(gci_files, zip_path)
	if not zip_success:
		push_error("[GameSaveSubManager] Failed to create GCI bundle for " + game_id)
		return results
	
	var mtime = _get_folder_mtime(directory)
	results.append({
		"file_name": game_id + ".zip",
		"file_path": zip_path,
		"modified_time": mtime,
		"extension": ".zip"
	})
	
	return results

## Creates a zip archive containing specific GCI files
## Used for bundling multiple GameCube saves for the same game
func _zip_gci_files(gci_files: Array[String], zip_path: String) -> bool:
	var writer = ZIPPacker.new()
	var err = writer.open(zip_path, ZIPPacker.ZipAppend.APPEND_CREATE)
	if err != OK:
		push_error("[GameSaveSubManager] Failed to create GCI zip: " + zip_path)
		return false
	
	for gci_path in gci_files:
		var file_name = gci_path.get_file()
		var data = FSM.read_file_bytes(gci_path)
		if data.size() > 0:
			writer.start_file(file_name)
			writer.write_file(data)
			writer.close_file()
	
	writer.close()
	return true

func _game_id_to_hex(game_id: String) -> String:
	var hex = ""
	for c in game_id:
		hex += "%02x" % c.unicode_at(0)
	return hex

func discover_local_dolphin_wii_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	var hex_id = _game_id_to_hex(game_id)
	var game_path = FSM.join_paths(directory, hex_id)
	
	if FSM.dir_exists(game_path):
		var mtime = _get_folder_mtime(game_path)
		results.append({
			"file_name": hex_id + ".zip",
			"file_path": game_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		return results
	
	return results

## Discovers the Eden profile ID from profiles.dat
## Reads the UUID from offset 0x10, reverses byte order, returns hex string
## Returns Dictionary with "profile_id" (String) and "is_fallback" (bool)
## Caches result in memory for subsequent calls
func _discover_eden_profile(emulator_dir: String) -> Dictionary:
	var cache_key = "eden_" + emulator_dir
	if _emulator_profile_cache.has(cache_key):
		return _emulator_profile_cache[cache_key]
	
	# On Android, Eden's data is in the app directory, not the download directory
	var profiles_path = ""
	if SystemManager.platform.is_android():
		profiles_path = "/storage/emulated/0/Android/data/dev.eden.eden_emulator/files/nand/system/save/8000000000000010/su/avators/profiles.dat"
	else:
		profiles_path = emulator_dir.rstrip("/") + "/user/nand/system/save/8000000000000010/su/avators/profiles.dat"
	
	print("[GameSaveSubManager] _discover_eden_profile: reading " + profiles_path)
	
	var result = {"profile_id": "0000000000000000", "is_fallback": true}
	
	if not FSM.file_exists(profiles_path):
		print("[GameSaveSubManager] _discover_eden_profile: profiles.dat not found, using zero profile")
		_emulator_profile_cache[cache_key] = result
		return result
	
	var data = FSM.read_file_bytes(profiles_path)
	if data.size() < 0x20:
		print("[GameSaveSubManager] _discover_eden_profile: profiles.dat too small (" + str(data.size()) + " bytes)")
		_emulator_profile_cache[cache_key] = result
		return result
	
	# Extract 16 bytes from offset 0x10 and reverse byte order
	var uuid_bytes = data.slice(0x10, 0x20)
	var reversed = PackedByteArray()
	reversed.resize(16)
	for i in range(16):
		reversed[i] = uuid_bytes[15 - i]
	
	# Convert to hex string
	var profile_id = ""
	for b in reversed:
		profile_id += "%02x" % b
	profile_id = profile_id.to_upper()
	
	print("[GameSaveSubManager] _discover_eden_profile: discovered profile " + profile_id)
	result = {"profile_id": profile_id, "is_fallback": false}
	_emulator_profile_cache[cache_key] = result
	return result

func discover_local_eden_save(directory: String, title_id: String, emulator_dir: String = "") -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		print("[GameSaveSubManager] discover_local_eden_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var dir_exists = FSM.dir_exists(directory)
	print("[GameSaveSubManager] discover_local_eden_save: dir_exists(" + directory + ") = " + str(dir_exists))
	if not dir_exists:
		return results
	
	# Discover the active profile
	var profile_id = "0000000000000000"
	if emulator_dir != "":
		var profile_result = _discover_eden_profile(emulator_dir)
		profile_id = profile_result.profile_id
	
	# Eden save structure: {base}/{user}/{profile}/{title_id}/
	# Eden uses full TitleID (16 chars) for save folder names
	var save_path = FSM.join_paths(directory, "0000000000000000", profile_id, title_id)
	print("[GameSaveSubManager] discover_local_eden_save: checking " + save_path)
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		print("[GameSaveSubManager] discover_local_eden_save: found save with mtime=" + str(mtime))
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		return results
	
	# Fallback: check zero profile
	var zero_path = FSM.join_paths(directory, "0000000000000000", "0000000000000000", title_id)
	print("[GameSaveSubManager] discover_local_eden_save: checking fallback " + zero_path)
	if FSM.dir_exists(zero_path):
		var mtime = _get_folder_mtime(zero_path)
		print("[GameSaveSubManager] discover_local_eden_save: found save in zero profile with mtime=" + str(mtime))
		results.append({
			"file_name": title_id + ".zip",
			"file_path": zero_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		return results
	
	print("[GameSaveSubManager] discover_local_eden_save: no save found")
	return results

## Generalized fuzzy folder save discovery
## Searches for folders whose names contain the given search_id
## Options: recursive_search (bool), return_all_matches (bool)
## Returns array of save dictionaries
func discover_local_fuzzy_folder_save(directory: String, search_id: String, recursive_search: bool = false, return_all_matches: bool = true) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or search_id == "":
		return results
	
	# Handle both hyphenated and non-hyphenated versions
	var id_with_hyphen = search_id.to_upper()
	var id_no_hyphen = search_id.replace("-", "").to_upper()
	
	var best_path = ""
	var best_mtime = 0
	
	var dirs_to_check: Array[String] = [directory]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		if not FSM.dir_exists(current):
			continue
		
		var items = FSM.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			
			var full_path = FSM.join_paths(current, item)
			
			if FSM.dir_exists(full_path):
				var folder_name = item.to_upper()
				var folder_name_no_hyphen = folder_name.replace("-", "")
				
				# Match if folder contains the search_id anywhere in the name
				var is_match = folder_name.find(id_with_hyphen) != -1 or folder_name_no_hyphen.find(id_no_hyphen) != -1
				
				if is_match:
					var mtime = _get_folder_mtime(full_path)
					if return_all_matches:
						results.append({
							"file_name": item + ".zip",
							"file_path": full_path,
							"modified_time": mtime,
							"extension": ".zip"
						})
					else:
						# Only keep the most recent
						if mtime > best_mtime:
							best_mtime = mtime
							best_path = full_path
				elif recursive_search:
					# Continue searching deeper
					dirs_to_check.append(full_path)
	
	if not return_all_matches and best_path != "":
		var folder_name = best_path.get_file()
		results.append({
			"file_name": folder_name + ".zip",
			"file_path": best_path,
			"modified_time": best_mtime,
			"extension": ".zip"
		})
	
	return results

func discover_local_pcsx2_save(directory: String, title_id: String) -> Array[Dictionary]:
	if directory == "" or title_id == "":
		print("[GameSaveSubManager] discover_local_pcsx2_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	print("[GameSaveSubManager] discover_local_pcsx2_save: searching for serial " + title_id + " in " + directory)
	var results = discover_local_fuzzy_folder_save(directory, title_id, true, false)
	
	if results.is_empty():
		print("[GameSaveSubManager] discover_local_pcsx2_save: no saves found for serial " + title_id)
	else:
		print("[GameSaveSubManager] discover_local_pcsx2_save: returning save at " + results[0].file_path)
	
	return results

## Discovers local PPSSPP saves for a PSP game
## Returns an array of save dictionaries, one per matching folder
## PSP games can have multiple save folders (e.g., ULUS10509DAT, ULUS10509DLC)
func discover_local_psp_save(directory: String, title_id: String) -> Array[Dictionary]:
	if directory == "" or title_id == "":
		print("[GameSaveSubManager] discover_local_psp_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	# PPSSPP save path already includes SAVEDATA in the path
	# e.g., {emulator_dir}/memstick/PSP/SAVEDATA
	var savedata_dir = directory.rstrip("/") + "/"
	print("[GameSaveSubManager] discover_local_psp_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		print("[GameSaveSubManager] discover_local_psp_save: SAVEDATA dir doesn't exist yet")
		return []
	
	var results = discover_local_fuzzy_folder_save(savedata_dir, title_id, false, true)
	print("[GameSaveSubManager] discover_local_psp_save: found " + str(results.size()) + " matching save folders")
	
	return results

## Discovers local Vita3K saves for a PSVita game
## Vita3K saves are folders directly in savedata/ named by TitleID (e.g., PCSA00152)
func discover_local_vita3k_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		print("[GameSaveSubManager] discover_local_vita3k_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var savedata_dir = directory.rstrip("/") + "/"
	print("[GameSaveSubManager] discover_local_vita3k_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		print("[GameSaveSubManager] discover_local_vita3k_save: savedata dir doesn't exist yet")
		return results
	
	# Look for exact match folder
	var save_path = savedata_dir + title_id
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		print("[GameSaveSubManager] discover_local_vita3k_save: found save at " + save_path)
	else:
		print("[GameSaveSubManager] discover_local_vita3k_save: no save found for " + title_id)
	
	return results

## Discovers local RPCS3 saves for a PS3 game
## RPCS3 saves are folders in dev_hdd0/home/00000001/savedata/ named by TitleID (e.g., BLUS12345)
func discover_local_rpcs3_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		print("[GameSaveSubManager] discover_local_rpcs3_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var savedata_dir = directory.rstrip("/") + "/"
	print("[GameSaveSubManager] discover_local_rpcs3_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		print("[GameSaveSubManager] discover_local_rpcs3_save: savedata dir doesn't exist yet")
		return results
	
	# Look for exact match folder
	var save_path = savedata_dir + title_id
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		print("[GameSaveSubManager] discover_local_rpcs3_save: found save at " + save_path)
	else:
		print("[GameSaveSubManager] discover_local_rpcs3_save: no save found for " + title_id)
	
	return results

## Discovers local shadPS4 saves for a PS4 game
## shadPS4 saves are folders in user/savedata/ named by TitleID (e.g., CUSA01130)
func discover_local_shadps4_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		print("[GameSaveSubManager] discover_local_shadps4_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var savedata_dir = directory.rstrip("/") + "/"
	print("[GameSaveSubManager] discover_local_shadps4_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(savedata_dir):
		print("[GameSaveSubManager] discover_local_shadps4_save: savedata dir doesn't exist yet")
		return results
	
	# Look for exact match folder
	var save_path = savedata_dir + title_id
	if FSM.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		print("[GameSaveSubManager] discover_local_shadps4_save: found save at " + save_path)
	else:
		print("[GameSaveSubManager] discover_local_shadps4_save: no save found for " + title_id)
	
	return results

## Discovers local Xenia saves for an Xbox 360 game
## Xenia saves are in content/PROFILE_ID/TITLE_ID/ (PROFILE_ID varies per user)
## We search recursively from the content directory for matching TITLE_ID folders
func discover_local_xenia_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		print("[GameSaveSubManager] discover_local_xenia_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var content_dir = directory.rstrip("/") + "/"
	print("[GameSaveSubManager] discover_local_xenia_save: searching in " + content_dir + " for title_id " + title_id)
	
	if not FSM.dir_exists(content_dir):
		print("[GameSaveSubManager] discover_local_xenia_save: content dir doesn't exist yet")
		return results
	
	# Search recursively through all profile subdirectories
	var dirs_to_check: Array[String] = [content_dir]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		var items = FSM.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			
			var full_path = current.rstrip("/") + "/" + item
			if FSM.dir_exists(full_path):
				# Check if this directory matches our Title ID
				if item.to_upper() == title_id.to_upper():
					var mtime = _get_folder_mtime(full_path)
					results.append({
						"file_name": title_id.to_upper() + ".zip",
						"file_path": full_path,
						"modified_time": mtime,
						"extension": ".zip"
					})
					print("[GameSaveSubManager] discover_local_xenia_save: found save at " + full_path)
					return results
				else:
					# Continue searching deeper (profile subdirectories)
					dirs_to_check.append(full_path)
	
	print("[GameSaveSubManager] discover_local_xenia_save: no save found for " + title_id)
	return results

func _get_folder_mtime(dir_path: String) -> int:
	var latest = 0
	var dirs_to_check: Array[String] = [dir_path]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		var items = FSM.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			var full = FSM.join_paths(current, item)
			if FSM.dir_exists(full):
				dirs_to_check.append(full)
			elif FSM.file_exists(full):
				var mtime = FSM.get_modified_time(full)
				if mtime > latest:
					latest = mtime
	return latest

## Validates that a game's title ID is valid for the given emulator
## Returns empty string on success, error message on failure
func _validate_emulator_title_id(emulator_id: String, title_id: String) -> String:
	var strategy = _get_strategy(emulator_id, "validate")
	if strategy.is_valid():
		return strategy.call(title_id)
	# Default validation
	if title_id.length() != 16:
		return "Invalid Title ID for this game."
	return ""

## Discovers local saves for a specific emulator and game
## Returns an array of save dictionaries

## Helper to determine the relevant core_id when resolving save paths for a game.
func _get_core_id_for_save_resolution(emulator_id: String, game: GameResource) -> String:
	if emulator_id != "retroarch":
		return ""
	return LaunchManager.resolve_core_for_game(game)
func _discover_emulator_saves(emulator_id: String, save_dir: String, game: GameResource) -> Array[Dictionary]:
	var strategy = _get_strategy(emulator_id, "discover")
	if strategy.is_valid():
		return strategy.call(save_dir, game)
	# Default: folder saves
	return discover_local_folder_save(save_dir, game.get_active_title_id())

## Resolves the save path for the default emulator folder structure
## Returns a dictionary with "path" and "error" keys
func _resolve_default_save_path(save_dir: String, title_id: String) -> Dictionary:
	var short_title_id = title_id.substr(8, 8)
	var id0 = _find_first_subdir(save_dir)
	if id0 == "":
		return {"path": "", "error": "no_id0"}
	var id1 = _find_first_subdir(FSM.join_paths(save_dir, id0))
	if id1 == "":
		return {"path": "", "error": "no_id1"}
	var category = title_id.substr(0, 8)
	return {
		"path": FSM.join_paths(save_dir, id0, id1, "title", category, short_title_id),
		"error": ""
	}

## Resolves the save path for a specific emulator and game
## Returns the resolved path string (empty string on failure)
func _resolve_emulator_save_path(emulator_id: String, save_dir: String, game: GameResource) -> String:
	var strategy = _get_strategy(emulator_id, "resolve_path")
	if strategy.is_valid():
		return strategy.call(save_dir, game)
	# Default: use standard folder save path resolution
	var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
	return result.path

## Resolves the save path for RetroArch with core-specific subdirectories
## Returns the full file path (for .srm-style saves) or folder path (for folder saves)
func _resolve_retroarch_save_path(save_dir: String, game: GameResource) -> String:
	var platform_slug = game.platform_slug
	var title_id = game.get_active_title_id()
	
	match platform_slug:
		"psp":
			if title_id == "":
				return ""
			return FSM.join_paths(save_dir, title_id)
		"ps2":
			if FSM.file_exists(save_dir):
				return save_dir
			if title_id == "":
				return ""
			return FSM.join_paths(save_dir, title_id)
		"ngc":
			return save_dir
		"wii":
			if title_id == "":
				return ""
			return FSM.join_paths(save_dir, _game_id_to_hex(title_id))
		"3ds":
			if title_id == "":
				return ""
			var short_title_id = title_id.substr(8, 8) if title_id.length() == 16 else title_id
			return FSM.join_paths(save_dir, short_title_id)
		_:
			var core_id = LaunchManager.resolve_core_for_game(game)
			var core_config = LaunchManager.registry.get_core_config("retroarch", platform_slug, core_id)
			var core_save_name = core_config.get("save_name", "")
			if core_save_name == "":
				push_error("[GameSaveSubManager] No save_name for platform: " + platform_slug)
				return ""
			
			var rom_name_no_ext = game.get_active_file_name().get_basename()
			return FSM.join_paths(save_dir, core_save_name, rom_name_no_ext + ".srm")

## Discovers local saves for a RetroArch core, dispatching by platform.
func _discover_retroarch_save(dir: String, game: GameResource) -> Array[Dictionary]:
	var platform_slug = game.platform_slug
	var title_id = game.get_active_title_id()
	
	match platform_slug:
		"psp":
			return discover_local_psp_save(dir, title_id)
		"ps2":
			if FSM.file_exists(dir):
				return _discover_single_file_save(dir)
			return discover_local_pcsx2_save(dir, title_id)
		"ngc":
			return _discover_retroarch_ngc_save(dir, title_id)
		"wii":
			return _discover_retroarch_wii_save(dir, title_id)
		"3ds":
			if title_id.length() == 16:
				var short_title_id = title_id.substr(8, 8)
				return discover_local_fuzzy_folder_save(dir, short_title_id, true, false)
			return discover_local_fuzzy_folder_save(dir, title_id, true, false)
		_:
			var core_id = LaunchManager.resolve_core_for_game(game)
			var extensions = get_save_extensions("retroarch", platform_slug, core_id)
			var rom_name_no_ext = game.get_active_file_name().get_basename()
			return discover_local_saves(dir, rom_name_no_ext, extensions)

## Discovers GameCube saves for the RetroArch Dolphin core.
## Returns the Card A directory as a single folder save (GCI files are bundled on upload).
func _discover_retroarch_ngc_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	# Check for any matching GCI files
	var items = FSM.list_dir(directory)
	var has_gci = false
	for item in items:
		if item == "." or item == "..":
			continue
		if item.to_lower().ends_with(".gci") and game_id.to_lower() in item.to_lower():
			has_gci = true
			break
	
	if not has_gci:
		return results
	
	var mtime = _get_folder_mtime(directory)
	results.append({
		"file_name": game_id + ".zip",
		"file_path": directory,
		"modified_time": mtime,
		"extension": ".zip"
	})
	return results

## Discovers Wii saves for the RetroArch Dolphin core.
func _discover_retroarch_wii_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results
	
	if not FSM.dir_exists(directory):
		return results
	
	var hex_id = _game_id_to_hex(game_id)
	var game_path = FSM.join_paths(directory, hex_id)
	
	if FSM.dir_exists(game_path):
		var mtime = _get_folder_mtime(game_path)
		results.append({
			"file_name": hex_id + ".zip",
			"file_path": game_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		return results
	
	return results

## Helper for RetroArch PS2 when the configured save path is a single memcard file.
func _discover_single_file_save(file_path: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if not FSM.file_exists(file_path):
		return results
	var mtime = FSM.get_modified_time(file_path)
	results.append({
		"file_name": file_path.get_file(),
		"file_path": file_path,
		"modified_time": mtime,
		"extension": "." + file_path.get_extension()
	})
	return results

## Determines the extraction destination for downloaded RetroArch saves.
func _get_retroarch_extract_dest(save_dir: String, record_path: String, game: GameResource) -> String:
	match game.platform_slug:
		"psp":
			return save_dir
		"ps2":
			if FSM.file_exists(save_dir):
				return save_dir.get_base_dir()
			return save_dir
		"ngc", "wii", "3ds":
			return record_path.get_base_dir()
		_:
			return record_path.get_base_dir()

## Determines the save name for RetroArch upload based on the local file/folder.
func _get_retroarch_save_name(game: GameResource, local_file_path: String) -> String:
	if local_file_path != "":
		return local_file_path.get_file()
	return game.get_active_file_name().get_basename() + ".srm"

## Creates a ZIP archive for a RetroArch save, dispatching by platform.
func _zip_retroarch_save(src: String, dst: String, game: GameResource) -> bool:
	match game.platform_slug:
		"psp":
			return _zip_psp_save(src, game.get_active_title_id(), dst, MAX_FILE_SIZE)
		"ps2", "ngc", "wii", "3ds":
			return FSM.zip_directory(src, dst)
		_:
			var folder_name = src.get_file()
			return FSM.zip_directory(src, dst, -1, folder_name)

## Determines the extraction destination for downloaded saves based on emulator
## Returns the destination directory path
func _get_extract_dest(emulator_id: String, save_dir: String, record_path: String, game: GameResource, zip_file_name: String = "") -> String:
	var strategy = _get_strategy(emulator_id, "extract_dest")
	if strategy.is_valid():
		return strategy.call(save_dir, record_path, game, zip_file_name)
	# Default: extract to the parent directory of the record path
	return record_path.get_base_dir()

## Determines the save name for upload based on emulator and game
## Returns the save name string
func _get_save_name_for_upload(emulator_id: String, game: GameResource, local_file_path: String = "") -> String:
	var strategy = _get_strategy(emulator_id, "save_name")
	if strategy.is_valid():
		return strategy.call(game, local_file_path)
	# Default: use the short Title ID (last 8 characters of the 16-character Title ID)
	return game.get_active_title_id().substr(8, 8)

## Creates a ZIP archive for a specific emulator's save
## Returns true on success
func _zip_emulator_save(emulator_id: String, source_path: String, zip_path: String, game: GameResource) -> bool:
	var strategy = _get_strategy(emulator_id, "zip")
	if strategy.is_valid():
		return strategy.call(source_path, zip_path, game)
	# Default: zip the directory without a root folder
	return FSM.zip_directory(source_path, zip_path)

## Zips all PSP save folders matching the title_id into a single archive
## max_file_size: maximum file size in bytes to include (-1 for no limit)
## Returns true on success
func _zip_psp_save(source_path: String, title_id: String, zip_path: String, max_file_size: int = -1) -> bool:
	# Normalize source path - remove trailing slashes to ensure get_file() works correctly
	var normalized_path = source_path.rstrip("/").rstrip("\\")
	
	# Use timestamp + random to avoid stage dir collisions when called rapidly
	var stage_dir = "user://temp_saves/stage_" + str(Time.get_ticks_msec()) + "_" + str(randi()) + "/"
	
	# Determine if source_path is an individual save folder or the SAVEDATA directory
	# Individual save folders contain the title_id in their name (e.g., NPJH50333DAT)
	var folder_name = normalized_path.get_file().to_upper()
	var savedata_dir = normalized_path
	
	if folder_name != "" and folder_name.contains(title_id.to_upper()):
		# It's an individual save folder, use parent directory
		savedata_dir = normalized_path.get_base_dir()
	
	print("[GameSaveSubManager] _zip_psp_save: normalized_path=" + normalized_path + ", folder_name=" + folder_name + ", savedata_dir=" + savedata_dir)
	
	var saves = discover_local_psp_save(savedata_dir, title_id)
	
	if saves.is_empty():
		print("[GameSaveSubManager] _zip_psp_save: no saves found in " + savedata_dir)
		return false
	
	print("[GameSaveSubManager] _zip_psp_save: found " + str(saves.size()) + " save(s) to zip")
	
	# Copy all matching save folders to staging directory
	for save in saves:
		var save_folder_name = save.file_path.get_file()
		var dest = FSM.join_paths(stage_dir, save_folder_name)
		print("[GameSaveSubManager] _zip_psp_save: copying " + save.file_path + " to " + dest)
		var success = FSM.copy_dir(save.file_path, dest)
		if not success:
			push_error("[GameSaveSubManager] _zip_psp_save: failed to copy " + save.file_path)
			FSM.delete_dir_recursive(stage_dir)
			return false
	
	# Zip the staging directory
	print("[GameSaveSubManager] _zip_psp_save: creating zip at " + zip_path)
	var zip_success = FSM.zip_directory(stage_dir, zip_path, max_file_size)
	if not zip_success:
		push_error("[GameSaveSubManager] _zip_psp_save: failed to create zip " + zip_path)
	
	FSM.delete_dir_recursive(stage_dir)
	return zip_success

func _sanitize_filename(file_name: String) -> String:
	return file_name.replace("/", "_").replace("\\", "_").replace(":", "_").replace("*", "_").replace("?", "_").replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")

func _find_first_subdir(dir_path: String) -> String:
	var items = FSM.list_dir(dir_path)
	for item in items:
		if item != "." and item != ".." and FSM.dir_exists(FSM.join_paths(dir_path, item)):
			return item
	return ""

func _ensure_device_registered(callback: Callable) -> void:
	var device_id = DataManager.get_romm_device_id()
	if device_id != "":
		callback.call(true, "")
		return
	
	var platform_name = OS.get_name().to_lower()
	var device_name = "Kyodai (" + platform_name.capitalize() + ")"
	SystemManager.network.register_device(device_name, platform_name, "kyodai", "1.0", func(data: Dictionary, error: String):
		if error != "":
			callback.call(false, "Device registration failed: " + error)
			return
		
		var new_device_id = data.get("device_id", "")
		if new_device_id == "":
			callback.call(false, "Device registration returned empty device_id")
			return
		
		DataManager.set_romm_device_id(new_device_id)
		print("[GameSaveSubManager] Registered device with RomM: " + new_device_id)
		callback.call(true, "")
	)

## Shows the save conflict dialog and waits for user choice
## Returns: "local", "server", "cancel", or "" (on error)
func _show_conflict_dialog(game: GameResource, local_time: int, server_time: int) -> String:
	# Serialize conflict dialogs: a second flow waits for the first dialog to close
	while _conflict_dialog_open:
		await _conflict_dialog_closed
	_conflict_dialog_open = true

	var result := {
		"choice": "",
		"server_btn": null,
		"local_btn": null,
		"cancel_btn": null,
	}

	var on_server := func(): result["choice"] = "server"
	var on_local := func(): result["choice"] = "local"
	var on_cancel := func(): result["choice"] = "cancel"

	var dialog = UIManager.show_custom_dialog(func(conflict_dialog: M3Dialog):
		conflict_dialog.title_text = "Save Conflict"
		conflict_dialog.body_text = "Your local save data for %s conflicts with what is stored on the server.\n\nWhichever save data you choose to keep will be synced to this device and the cloud. The option you choose not to keep will be overwritten." % game.get_display_name()
		conflict_dialog.dismissible = false
		conflict_dialog.disable_default_action = true

		var content = VBoxContainer.new()
		content.alignment = BoxContainer.ALIGNMENT_BEGIN

		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(0, M3Units.dp(16))
		content.add_child(spacer)

		result["server_btn"] = M3Button.new()
		var dlg_server_btn: M3Button = result["server_btn"]
		dlg_server_btn.custom_minimum_size = Vector2(0, M3Units.dp(80))
		dlg_server_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		dlg_server_btn.button_size = M3Button.Size.LARGE
		dlg_server_btn.text = "Server Save\nModified: " + _format_conflict_timestamp(server_time)
		dlg_server_btn.pressed.connect(func():
			on_server.call()
			conflict_dialog.dismiss()
		)
		content.add_child(dlg_server_btn)

		result["local_btn"] = M3Button.new()
		var dlg_local_btn: M3Button = result["local_btn"]
		dlg_local_btn.custom_minimum_size = Vector2(0, M3Units.dp(80))
		dlg_local_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		dlg_local_btn.button_size = M3Button.Size.LARGE
		dlg_local_btn.text = "Local Save\nModified: " + _format_conflict_timestamp(local_time)
		dlg_local_btn.pressed.connect(func():
			on_local.call()
			conflict_dialog.dismiss()
		)
		content.add_child(dlg_local_btn)

		result["cancel_btn"] = M3Button.new()
		var dlg_cancel_btn: M3Button = result["cancel_btn"]
		dlg_cancel_btn.custom_minimum_size = Vector2(0, M3Units.dp(56))
		dlg_cancel_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		dlg_cancel_btn.button_size = M3Button.Size.MEDIUM
		dlg_cancel_btn.button_variant = M3Button.Variant.TEXT
		dlg_cancel_btn.text = "Cancel"
		dlg_cancel_btn.pressed.connect(func():
			on_cancel.call()
			conflict_dialog.dismiss()
		)
		content.add_child(dlg_cancel_btn)

		conflict_dialog.content_slot.add_child(content)
	)

	# Wait for the dialog to be laid out and then focus the first choice.
	await get_tree().process_frame
	var server_btn = result["server_btn"]
	var local_btn = result["local_btn"]
	var cancel_btn = result["cancel_btn"]
	if is_instance_valid(server_btn) and is_instance_valid(local_btn) and is_instance_valid(cancel_btn):
		server_btn.focus_neighbor_bottom = local_btn.get_path()
		local_btn.focus_neighbor_top = server_btn.get_path()
		local_btn.focus_neighbor_bottom = cancel_btn.get_path()
		cancel_btn.focus_neighbor_top = local_btn.get_path()
		server_btn.grab_focus()

	# Wait until the user picks one of the three choices.
	await dialog.dismissed

	_conflict_dialog_open = false
	_conflict_dialog_closed.emit()

	print("[GameSaveSubManager] Conflict dialog resolved with choice: " + result["choice"])
	return result["choice"]

func _format_conflict_timestamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "Unknown"

	var dict = Time.get_datetime_dict_from_unix_time(unix_time)

	var tz_info = Time.get_time_zone_from_system()
	var tz_offset_minutes = tz_info.get("bias", 0)
	var adjusted_unix = unix_time + (tz_offset_minutes * 60)
	dict = Time.get_datetime_dict_from_unix_time(adjusted_unix)
	var month_names = ["January", "February", "March", "April", "May", "June",
					"July", "August", "September", "October", "November", "December"]

	var month = month_names[dict.month - 1]
	var day = dict.day
	var year = dict.year
	var hour = dict.hour
	var minute = dict.minute
	var ampm = "AM" if hour < 12 else "PM"

	if hour > 12:
		hour -= 12
	elif hour == 0:
		hour = 12

	return "%s %d, %d at %d:%02d %s" % [month, day, year, hour, minute, ampm]


## Main sync entry point for manual and auto sync
func sync_saves_for_game(game: GameResource, emulator_id: String, callback: Callable = Callable()) -> void:
	var sync_key = _save_sync_key(game, emulator_id)
	if _save_sync_in_flight.has(sync_key):
		SystemManager.notifications.show_notification("Save sync already in progress for " + game.get_display_name(), SystemManager.notifications.Type.WARNING)
		if callback.is_valid():
			callback.call(false, "Save sync already in progress")
		return
	_begin_save_sync(sync_key)
	var user_callback = callback
	callback = func(success: bool, message: String):
		_end_save_sync(sync_key)
		if user_callback.is_valid():
			user_callback.call(success, message)

	if not SystemManager.network.is_romm_connected():
		if callback.is_valid():
			callback.call(false, "Not connected to RomM")
		return
	
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var extensions = get_save_extensions(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	
	if save_dir == "" or extensions.is_empty():
		if callback.is_valid():
			callback.call(false, "No save configuration for emulator: " + emulator_id)
		return
	
	var is_folder_save_flow = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game)) or (emulator_id == "dolphin" and game.platform_slug == "ngc")
	if is_folder_save_flow:
		if game.get_active_title_id() == "":
			if callback.is_valid():
				callback.call(false, "No Title ID available for this game. Launch it once to extract the Title ID.")
			return
		var validation_error = _validate_emulator_title_id(emulator_id, game.get_active_title_id())
		if validation_error != "":
			if callback.is_valid():
				callback.call(false, validation_error)
			return

	# Discovery walks the save directory tree; run it off the main thread when safe
	var scan_work := func() -> Array[Dictionary]:
		if is_folder_save_flow:
			return _discover_emulator_saves(emulator_id, save_dir, game)
		var rom_name_no_ext = game.get_active_file_name().get_basename()
		return discover_local_saves(save_dir, rom_name_no_ext, extensions)
	_run_io_task(save_dir, scan_work, func(local_saves: Array[Dictionary]):
		_ensure_device_registered(func(success: bool, error: String):
			if not success:
				if callback.is_valid():
					callback.call(false, error)
				return

			var device_id = DataManager.get_romm_device_id()
			SystemManager.network.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, fetch_error: String):
				if fetch_error != "":
					if callback.is_valid():
						callback.call(false, "Failed to fetch remote saves: " + fetch_error)
					return

				_run_sync(game, emulator_id, local_saves, remote_saves, device_id, callback)
			)
		)
	)

func _run_sync(game: GameResource, emulator_id: String, local_saves: Array, remote_saves: Array, device_id: String, callback: Callable) -> void:
	var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
	
	var local_by_name: Dictionary = {}
	for save in local_saves:
		local_by_name[save.file_name] = save
	
	var remote_by_name: Dictionary = {}
	for save in remote_saves:
		var slot = save.get("slot", "")
		if slot == null:
			slot = ""
		if slot == SLOT_DEFAULT:
			remote_by_name[save.file_name] = save
	
	var db_by_name: Dictionary = {}
	for rec in db_records:
		db_by_name[rec.file_name] = rec
	
	var pending_uploads: Array[Dictionary] = []
	var pending_downloads: Array[Dictionary] = []
	var sync_aborted = false
	
	for local in local_saves:
		var file_name = local.file_name
		var remote = remote_by_name.get(file_name)
		var db_rec = db_by_name.get(file_name)
		var last_synced_unix = 0
		var local_mtime = local.modified_time
		if db_rec:
			last_synced_unix = parse_iso_timestamp(db_rec.last_synced_at)
		
		if remote:
			var remote_updated_unix = parse_iso_timestamp(remote.get("updated_at", ""))
			
			if local_mtime > last_synced_unix and remote_updated_unix > last_synced_unix:
				# CONFLICT: Both changed since last sync - show dialog
				var choice = await _show_conflict_dialog(game, local_mtime, remote_updated_unix)
				match choice:
					"local":
						pending_uploads.append({"local": local, "remote": remote})
					"server":
						pending_downloads.append({"local": local, "remote": remote})
					"cancel", "":
						sync_aborted = true
						break
			elif local_mtime > last_synced_unix:
				pending_uploads.append({"local": local, "remote": remote})
			elif remote_updated_unix > last_synced_unix:
				pending_downloads.append({"local": local, "remote": remote})
		else:
			if local_mtime > last_synced_unix or last_synced_unix == 0:
				pending_uploads.append({"local": local, "remote": null})
	
	if sync_aborted:
		save_sync_completed.emit(game, false, "Save sync cancelled by user")
		if callback.is_valid():
			callback.call(false, "Save sync cancelled by user")
		return
	
	for remote in remote_by_name.values():
		var file_name = remote.file_name
		if not local_by_name.has(file_name):
			pending_downloads.append({"local": null, "remote": remote})
	
	var total_ops = pending_uploads.size() + pending_downloads.size()
	if total_ops == 0:
		if callback.is_valid():
			callback.call(true, "Saves are already in sync")
		return
	
	var state = {"completed": 0, "failed": 0}
	var current_timestamp = Time.get_datetime_string_from_system(true, true)
	
	var check_complete = func():
		state.completed += 1
		if state.completed >= total_ops:
			if state.failed > 0:
				save_sync_completed.emit(game, false, "%d/%d operations failed" % [state.failed, total_ops])
				if callback.is_valid():
					callback.call(false, "%d/%d operations failed" % [state.failed, total_ops])
			else:
				save_sync_completed.emit(game, true, "Save sync completed")
				if callback.is_valid():
					callback.call(true, "Save sync completed")
	
	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	
	for upload in pending_uploads:
		var upload_file_name = upload.local.file_name
		var original_path = upload.local.file_path
		
		if is_folder_save:
			var save_name = _get_save_name_for_upload(emulator_id, game, original_path)
			var zip_path = "user://temp_saves/" + str(game.romm_id) + "/" + save_name + ".zip"
			print("[GameSaveSubManager] Preparing folder save upload for " + save_name + " from base: " + original_path)
			FSM.make_dir_recursive(zip_path.get_base_dir())
			# Zip off the main thread when the source path allows it
			var zip_state := {"done": false, "success": false}
			_run_io_task(original_path,
				func():
					return _zip_emulator_save(emulator_id, original_path, zip_path, game),
				func(zip_success: bool):
					zip_state["success"] = zip_success
					zip_state["done"] = true
			)
			while not zip_state["done"]:
				await get_tree().process_frame
			if not zip_state["success"]:
				state.failed += 1
				push_error("[GameSaveSubManager] Failed to zip folder for upload: " + original_path)
				check_complete.call()
				continue

			SystemManager.network.upload_save(
				game.romm_id,
				zip_path,
				emulator_id,
				SLOT_DEFAULT,
				device_id,
				true,
				func(data: Dictionary, error: String):
					if FSM.file_exists(zip_path):
						FSM.delete_file(zip_path)
					# Clean up empty parent directories
					_cleanup_temp_dir(zip_path)
					if error != "":
						state.failed += 1
						push_error("[GameSaveSubManager] Upload failed for " + original_path + ": " + error)
					else:
						var remote_id = data.get("id", 0)
						DataManager.update_save_sync_record(game.romm_id, emulator_id, upload_file_name, original_path, current_timestamp, remote_id, SLOT_DEFAULT)
					check_complete.call()
			)
		else:
			SystemManager.network.upload_save(
				game.romm_id,
				original_path,
				emulator_id,
				SLOT_DEFAULT,
				device_id,
				true,
				func(data: Dictionary, error: String):
					# Clean up temp GCI zip files after upload
					if original_path.contains("user://temp_saves/") and FSM.file_exists(original_path):
						FSM.delete_file(original_path)
					if error != "":
						state.failed += 1
						push_error("[GameSaveSubManager] Upload failed for " + original_path + ": " + error)
					else:
						var remote_id = data.get("id", 0)
						DataManager.update_save_sync_record(game.romm_id, emulator_id, upload_file_name, original_path, current_timestamp, remote_id, SLOT_DEFAULT)
					check_complete.call()
			)
	
	for download in pending_downloads:
		var remote = download.remote
		var save_id = remote.get("id", 0)
		var file_name = remote.get("file_name", "save")
		var local_path = ""
		var record_path = ""
		var zip_path = ""
		
		if download.local:
			record_path = download.local.file_path
		else:
			if emulator_id == "retroarch":
				record_path = _resolve_emulator_save_path(emulator_id, resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game)), game)
			else:
				record_path = FSM.join_paths(resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game)), file_name)
		
		if is_folder_save:
			zip_path = "user://temp_saves/download_" + str(Time.get_ticks_msec()) + ".zip"
			FSM.make_dir_recursive(zip_path.get_base_dir())
			local_path = zip_path
			var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
			
			if not download.local:
				record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
				print("[GameSaveSubManager] Folder save record_path for " + emulator_id + ": " + record_path)
				if record_path == "":
					var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
					if result.error != "":
						state.failed += 1
						push_error("[GameSaveSubManager] Cannot download folder save: no " + result.error + " folder found")
						check_complete.call()
						continue
					record_path = result.path
		else:
			local_path = record_path
			# Ensure parent directory exists for RetroArch core-specific saves
			if emulator_id == "retroarch":
				var parent_dir = record_path.get_base_dir()
				FSM.make_dir_recursive(parent_dir)
		
		# Ensure save directory exists before downloading
		_ensure_save_directory_exists(emulator_id)
		
		SystemManager.network.download_save(save_id, device_id, local_path, func(_success: bool, _status_code: int, error_msg: String):
			if not _success:
				state.failed += 1
				push_error("[GameSaveSubManager] Download failed for save " + str(save_id) + ": " + error_msg)
				check_complete.call()
				return
			
			SystemManager.network.confirm_save_downloaded(save_id, device_id, func(_data, confirm_error):
				if confirm_error != "":
					push_warning("[GameSaveSubManager] Failed to confirm download: " + confirm_error)
				
				if is_folder_save:
					var extract_dest = _get_extract_dest(emulator_id, resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game)), record_path, game)
					print("[GameSaveSubManager] Extracting folder save for " + emulator_id + " to: " + extract_dest)
					print("[GameSaveSubManager] record_path was: " + record_path)
					
					# Async extraction with completion callback
					FSM.extract_archive_async(zip_path, extract_dest, "Save data", true,
						func(_info: Dictionary): pass,
						func(extract_success: bool, _error):
							if not extract_success:
								state.failed += 1
								push_error("[GameSaveSubManager] Failed to extract downloaded zip: " + zip_path)
							
							# Clean up empty parent directories
							_cleanup_temp_dir(zip_path)
							
							# Ensure PCSX2 superblock is valid after extracting saves
							if emulator_id == "pcsx2":
								print("[GameSaveSubManager] Ensuring PCSX2 superblock is valid after save sync...")
								var memcard_path = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
								ensure_pcsx2_superblock(memcard_path)
							
							DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT)
							check_complete.call()
					)
					return  # Exit callback, completion handled by async
				else:
					# Non-folder save, no extraction needed
					if emulator_id == "pcsx2":
						print("[GameSaveSubManager] Ensuring PCSX2 superblock is valid after save sync...")
						var memcard_path = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
						ensure_pcsx2_superblock(memcard_path)
					
					DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT)
					check_complete.call()
			)
		)

## Parses an ISO 8601 timestamp string to Unix seconds.
## Handles trailing timezone offsets (Z, +HH:MM, -HH:MM) and converts to UTC.
## Returns 0 if parsing fails or the input is empty.
func parse_iso_timestamp(iso_string: String) -> int:
	if iso_string == "":
		return 0
	
	# Validate format and capture optional timezone offset.
	# Matches: 2024-01-15T10:30:00Z, 2024-01-15T10:30:00+02:00, etc.
	var regex = RegEx.new()
	regex.compile("^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})?")
	var match_result = regex.search(iso_string)
	if not match_result:
		return 0
	
	var year = int(match_result.get_string(1))
	var month = int(match_result.get_string(2))
	var day = int(match_result.get_string(3))
	var hour = int(match_result.get_string(4))
	var minute = int(match_result.get_string(5))
	var second = int(match_result.get_string(6))
	var tz_str = match_result.get_string(7)
	
	var dict = {"year": year, "month": month, "day": day,
				"hour": hour, "minute": minute, "second": second}
	var unix = int(Time.get_unix_time_from_datetime_dict(dict))
	
	# Apply timezone offset to get true UTC timestamp.
	if tz_str != "" and tz_str != "Z":
		var tz_regex = RegEx.new()
		tz_regex.compile("([+-])(\\d{2}):?(\\d{2})")
		var tz_match = tz_regex.search(tz_str)
		if tz_match:
			var tz_sign = 1 if tz_match.get_string(1) == "+" else -1
			var tz_hours = int(tz_match.get_string(2))
			var tz_minutes = int(tz_match.get_string(3))
			var offset_seconds = tz_sign * (tz_hours * 3600 + tz_minutes * 60)
			unix -= offset_seconds
	
	return unix

## Auto-upload saves after playing (post-exit hook)
## Checks for conflicts and shows dialog if both local and server saves have changed
func auto_upload_saves_for_game(game: GameResource, emulator_id: String) -> void:
	print("[GameSaveSubManager] auto_upload_saves_for_game called for " + game.get_display_name() + " (" + emulator_id + ")")
	if not DataManager.get_setting("save_sync_auto").value:
		print("[GameSaveSubManager] Auto-upload aborted: save_sync_auto is off")
		return
	if not SystemManager.network.is_romm_connected():
		print("[GameSaveSubManager] Auto-upload aborted: not connected to RomM")
		return

	var sync_key = _save_sync_key(game, emulator_id)
	if _save_sync_in_flight.has(sync_key):
		print("[GameSaveSubManager] Auto-upload aborted: save sync already in progress for this game")
		return
	
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var extensions = get_save_extensions(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	if save_dir == "" or extensions.is_empty():
		print("[GameSaveSubManager] Auto-upload aborted: no save dir or extensions (dir=" + save_dir + ", ext count=" + str(extensions.size()) + ")")
		return
	
	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	if is_folder_save or (emulator_id == "dolphin" and game.platform_slug == "ngc"):
		if game.get_active_title_id() == "":
			return
		# Eden: abort sync if profile not resolved (first launch)
		if emulator_id == "eden":
			var emu_dir = LaunchManager._get_emulator_directory("eden")
			var profile_result = _discover_eden_profile(emu_dir)
			if profile_result.is_fallback:
				print("[GameSaveSubManager] Auto-upload aborted: Eden profile not resolved (first launch?)")
				SystemManager.notifications.show_notification("Save sync paused - Eden profile not found. Launch the game once to initialize your profile.", SystemManager.notifications.Type.WARNING)
				return

	# Discovery walks the save directory tree; run it off the main thread when safe
	var scan_work := func() -> Array[Dictionary]:
		if is_folder_save or (emulator_id == "dolphin" and game.platform_slug == "ngc"):
			return _discover_emulator_saves(emulator_id, save_dir, game)
		var rom_name_no_ext = game.get_active_file_name().get_basename()
		return discover_local_saves(save_dir, rom_name_no_ext, extensions)
	_run_io_task(save_dir, scan_work, func(local_saves: Array[Dictionary]):
		if local_saves.is_empty():
			print("[GameSaveSubManager] No local saves found for auto-upload (emulator: " + emulator_id + ", title_id: " + game.get_active_title_id() + ", dir: " + save_dir + "), skipping.")
			return

		_begin_save_sync(sync_key)
		_auto_upload_after_scan(game, emulator_id, local_saves, is_folder_save, sync_key)
	)

func _auto_upload_after_scan(game: GameResource, emulator_id: String, local_saves: Array[Dictionary], is_folder_save: bool, sync_key: String) -> void:
	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[GameSaveSubManager] Auto-upload aborted: " + error)
			_end_save_sync(sync_key)
			return

		var device_id = DataManager.get_romm_device_id()
		
		# Check for conflicts with remote saves before uploading
		SystemManager.network.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, fetch_error: String):
			if fetch_error != "":
				push_warning("[GameSaveSubManager] Auto-upload conflict check failed: " + fetch_error)
				# Continue with upload anyway if we can't check
				_perform_auto_upload(game, emulator_id, local_saves, device_id, is_folder_save)
				return
			
			# Check if any local save conflicts with remote
			var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
			var db_by_name: Dictionary = {}
			for rec in db_records:
				db_by_name[rec.file_name] = rec
			
			var has_conflict = false
			var conflict_local_time = 0
			var conflict_server_time = 0
			
			for local in local_saves:
				var file_name = local.file_name
				var db_rec = db_by_name.get(file_name)
				var last_synced_unix = 0
				if db_rec:
					last_synced_unix = parse_iso_timestamp(db_rec.last_synced_at)
				
				for remote in remote_saves:
					if remote.file_name == file_name:
						var remote_updated_unix = parse_iso_timestamp(remote.get("updated_at", ""))
						if local.modified_time > last_synced_unix and remote_updated_unix > last_synced_unix:
							has_conflict = true
							conflict_local_time = local.modified_time
							conflict_server_time = remote_updated_unix
							break
				
				if has_conflict:
					break
			
			if has_conflict:
				# Show conflict dialog
				print("[GameSaveSubManager] Auto-upload detected conflict, showing dialog")
				var choice = await _show_conflict_dialog(game, conflict_local_time, conflict_server_time)

				match choice:
					"local":
						# User chose to keep local, proceed with upload
						print("[GameSaveSubManager] User chose to keep local save, proceeding with upload")
						_perform_auto_upload(game, emulator_id, local_saves, device_id, is_folder_save)
					"server":
						# User chose to keep server, skip upload (will download on next launch)
						print("[GameSaveSubManager] User chose to keep server save, skipping upload")
						SystemManager.notifications.show_notification("Save sync: keeping server version", SystemManager.notifications.Type.INFO)
						_end_save_sync(sync_key)
					"cancel", "":
						# User cancelled
						print("[GameSaveSubManager] User cancelled auto-upload")
						SystemManager.notifications.show_notification("Save sync cancelled", SystemManager.notifications.Type.INFO)
						_end_save_sync(sync_key)
			else:
				# No conflict, proceed with upload
				_perform_auto_upload(game, emulator_id, local_saves, device_id, is_folder_save)
		)
	)


## Internal function to perform the actual auto-upload after conflict checks
func _perform_auto_upload(game: GameResource, emulator_id: String, local_saves: Array, device_id: String, is_folder_save: bool) -> void:
	var current_timestamp = Time.get_datetime_string_from_system(true, true)
	var state = {"pending": local_saves.size(), "failed": 0}
	
	for local in local_saves:
		var local_file_name = local.file_name
		var local_file_path = local.file_path
		
		if is_folder_save:
			var save_name = _get_save_name_for_upload(emulator_id, game, local_file_path)
			var zip_path = "user://temp_saves/" + str(game.romm_id) + "/" + save_name + ".zip"
			FSM.make_dir_recursive(zip_path.get_base_dir())
			# Zip off the main thread when the source path allows it
			var zip_state := {"done": false, "success": false}
			_run_io_task(local_file_path,
				func():
					return _zip_emulator_save(emulator_id, local_file_path, zip_path, game),
				func(zip_success: bool):
					zip_state["success"] = zip_success
					zip_state["done"] = true
			)
			while not zip_state["done"]:
				await get_tree().process_frame
			if not zip_state["success"]:
				state.failed += 1
				push_error("[GameSaveSubManager] Failed to zip folder for auto-upload: " + local_file_path)
				state.pending -= 1
				if state.pending <= 0:
					if state.failed > 0:
						SystemManager.notifications.show_notification("Save sync failed for some files", SystemManager.notifications.Type.ERROR)
					else:
						SystemManager.notifications.show_notification("Saves synced to RomM", SystemManager.notifications.Type.INFO)
					_end_save_sync(_save_sync_key(game, emulator_id))
				continue
			
			SystemManager.network.upload_save(
				game.romm_id,
				zip_path,
				emulator_id,
				SLOT_DEFAULT,
				device_id,
				true,
				func(data: Dictionary, error: String):
					if FSM.file_exists(zip_path):
						FSM.delete_file(zip_path)
					# Clean up empty parent directories
					_cleanup_temp_dir(zip_path)
					if error != "":
						state.failed += 1
						push_error("[GameSaveSubManager] Auto-upload failed: " + error)
					else:
						var remote_id = data.get("id", 0)
						print("[GameSaveSubManager] Auto-upload success for " + local_file_name + " -> remote save id: " + str(remote_id))
						DataManager.update_save_sync_record(game.romm_id, emulator_id, local_file_name, local_file_path, current_timestamp, remote_id, SLOT_DEFAULT)
					state.pending -= 1
					if state.pending <= 0:
						if state.failed > 0:
							SystemManager.notifications.show_notification("Save sync failed for some files", SystemManager.notifications.Type.ERROR)
						else:
							SystemManager.notifications.show_notification("Saves synced to RomM", SystemManager.notifications.Type.INFO)
						_end_save_sync(_save_sync_key(game, emulator_id))
			)
		else:
			SystemManager.network.upload_save(
				game.romm_id,
				local_file_path,
				emulator_id,
				SLOT_DEFAULT,
				device_id,
				true,
			func(data: Dictionary, error: String):
				if error != "":
					state.failed += 1
					push_error("[GameSaveSubManager] Auto-upload failed: " + error)
				else:
					var remote_id = data.get("id", 0)
					print("[GameSaveSubManager] Auto-upload success for " + local_file_name + " -> remote save id: " + str(remote_id))
					DataManager.update_save_sync_record(game.romm_id, emulator_id, local_file_name, local_file_path, current_timestamp, remote_id, SLOT_DEFAULT)
				state.pending -= 1
				if state.pending <= 0:
					if state.failed > 0:
						SystemManager.notifications.show_notification("Save sync failed for some files", SystemManager.notifications.Type.ERROR)
					else:
						SystemManager.notifications.show_notification("Saves synced to RomM", SystemManager.notifications.Type.INFO)
					_end_save_sync(_save_sync_key(game, emulator_id))
			)

## Auto-download saves before launch (pre-launch hook)
## If on_complete callback is provided, it will be called when sync finishes
func auto_download_saves_for_game(game: GameResource, emulator_id: String, on_complete: Callable = Callable()) -> void:
	print("[GameSaveSubManager] auto_download: START for game=" + game.get_display_name() + " emulator=" + emulator_id)
	
	if not DataManager.get_setting("save_sync_auto").value:
		print("[GameSaveSubManager] auto_download: ABORT - save_sync_auto is false")
		if on_complete.is_valid():
			on_complete.call()
		return
	if not SystemManager.network.is_romm_connected():
		print("[GameSaveSubManager] auto_download: ABORT - not connected to RomM")
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var save_dir = resolve_active_save_directory(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	var extensions = get_save_extensions(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))
	print("[GameSaveSubManager] auto_download: save_dir=" + save_dir + " extensions=" + str(extensions.size()))
	if save_dir == "" or extensions.is_empty():
		print("[GameSaveSubManager] auto_download: ABORT - no save_dir or extensions")
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var is_folder_save = uses_folder_saves(emulator_id, game.platform_slug, _get_core_id_for_save_resolution(emulator_id, game))

	var sync_key = _save_sync_key(game, emulator_id)
	if _save_sync_in_flight.has(sync_key):
		# Pre-launch must not skip a needed download: wait for the in-flight
		# sync (e.g. a manual sync started moments ago) to finish, bounded.
		print("[GameSaveSubManager] auto_download: save sync already in progress, waiting for it to finish")
		var wait_ms = 0
		while _save_sync_in_flight.has(sync_key) and wait_ms < 15000:
			await get_tree().create_timer(0.1).timeout
			wait_ms += 100
		if _save_sync_in_flight.has(sync_key):
			push_warning("[GameSaveSubManager] auto_download: timed out waiting for in-flight save sync")
		if on_complete.is_valid():
			on_complete.call()
		return
	_begin_save_sync(sync_key)
	var user_on_complete = on_complete
	on_complete = func():
		_end_save_sync(sync_key)
		if user_on_complete.is_valid():
			user_on_complete.call()

	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[GameSaveSubManager] Auto-download aborted: " + error)
			if on_complete.is_valid():
				on_complete.call()
			return
		
		var device_id = DataManager.get_romm_device_id()
		
		SystemManager.network.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, fetch_error: String):
			if fetch_error != "":
				push_warning("[GameSaveSubManager] Pre-launch fetch failed: " + fetch_error)
				if on_complete.is_valid():
					on_complete.call()
				return
			
			print("[GameSaveSubManager] auto_download: fetched " + str(remote_saves.size()) + " remote saves for romm_id=" + str(game.romm_id))
			
			var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
			var db_by_name: Dictionary = {}
			for rec in db_records:
				db_by_name[rec.file_name] = rec
			
			var local_saves: Array[Dictionary]
			if is_folder_save:
				if game.get_active_title_id() == "":
					if on_complete.is_valid():
						on_complete.call()
					return
				var validation_error = _validate_emulator_title_id(emulator_id, game.get_active_title_id())
				if validation_error != "":
					if on_complete.is_valid():
						on_complete.call()
					return
				# Eden: abort sync if profile not resolved (first launch)
				if emulator_id == "eden":
					var emu_dir = LaunchManager._get_emulator_directory("eden")
					var profile_result = _discover_eden_profile(emu_dir)
					if profile_result.is_fallback:
						print("[GameSaveSubManager] Auto-download aborted: Eden profile not resolved (first launch?)")
						SystemManager.notifications.show_notification("Save sync paused - Eden profile not found. Launch the game once to initialize your profile.", SystemManager.notifications.Type.WARNING)
						if on_complete.is_valid():
							on_complete.call()
						return

			# Discovery walks the save directory tree; run it off the main thread when safe
			var scan_work := func() -> Array[Dictionary]:
				if is_folder_save:
					return _discover_emulator_saves(emulator_id, save_dir, game)
				var rom_name_no_ext = game.get_active_file_name().get_basename()
				return discover_local_saves(save_dir, rom_name_no_ext, extensions)
			var scan_state := {"done": false, "result": []}
			_run_io_task(save_dir, scan_work, func(scan_result: Array[Dictionary]):
				scan_state["result"] = scan_result
				scan_state["done"] = true
			)
			while not scan_state["done"]:
				await get_tree().process_frame
			local_saves = scan_state["result"]
			
			print("[GameSaveSubManager] auto_download: found " + str(local_saves.size()) + " local saves in " + save_dir)
			
			var local_by_name: Dictionary = {}
			for save in local_saves:
				local_by_name[save.file_name] = save
			
			var current_timestamp = Time.get_datetime_string_from_system(true, true)
			var state = {"pending": 0, "failed": 0}
			
			var check_complete = func():
				if state.pending <= 0:
					if on_complete.is_valid():
						on_complete.call()
			
			for remote in remote_saves:
				var slot = remote.get("slot", "")
				if slot == null:
					slot = ""
				if slot != SLOT_DEFAULT:
					continue
				
				var file_name = remote.get("file_name", "save")
				var save_id = remote.get("id", 0)
				var remote_updated_unix = parse_iso_timestamp(remote.get("updated_at", ""))
				
				print("[GameSaveSubManager] auto_download: checking remote save id=" + str(save_id) + " file_name='" + file_name + "' updated=" + str(remote_updated_unix))
				
				var local = local_by_name.get(file_name)
				var db_rec = db_by_name.get(file_name)
				var last_synced_unix = 0
				if db_rec:
					last_synced_unix = parse_iso_timestamp(db_rec.last_synced_at)
				
				var should_download = false
				if not local:
					should_download = true
					print("[GameSaveSubManager] auto_download: no local save for '" + file_name + "', will download")
				elif remote_updated_unix > last_synced_unix and remote_updated_unix > local.modified_time:
					should_download = true
					print("[GameSaveSubManager] auto_download: remote is newer for '" + file_name + "', will download")
				else:
					print("[GameSaveSubManager] auto_download: skipping '" + file_name + "' (local is up to date)")
				
				if should_download:
					state.pending += 1
					var _local = local_by_name.get(file_name)
					var record_path = ""
					var local_path = ""
					var zip_path = ""
					
					if _local:
						record_path = _local.file_path
					else:
						if emulator_id == "retroarch":
							record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
							print("[GameSaveSubManager] auto_download: resolved retroarch save path: " + record_path)
						else:
							record_path = save_dir + file_name
					
					if is_folder_save:
						zip_path = "user://temp_saves/download_" + str(Time.get_ticks_msec()) + ".zip"
						FSM.make_dir_recursive(zip_path.get_base_dir())
						local_path = zip_path
						
						if not _local:
							record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
							if record_path == "":
								var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
								if result.error != "":
									state.failed += 1
									push_error("[GameSaveSubManager] Cannot auto-download folder save: no " + result.error + " folder found")
									state.pending -= 1
									check_complete.call()
									continue
								record_path = result.path
					else:
						local_path = record_path
						# Ensure parent directory exists for RetroArch core-specific saves
						if emulator_id == "retroarch":
							var parent_dir = record_path.get_base_dir()
							FSM.make_dir_recursive(parent_dir)
					
					# Ensure save directory exists before downloading
					_ensure_save_directory_exists(emulator_id, save_dir)
					
					print("[GameSaveSubManager] auto_download: downloading save '" + file_name + "' to: " + local_path)
					
					SystemManager.network.download_save(save_id, device_id, local_path, func(success: bool, _status_code: int, error_msg: String):
						if not success:
							state.failed += 1
							push_error("[GameSaveSubManager] Pre-launch download failed: " + error_msg)
							state.pending -= 1
							check_complete.call()
							return
						
						SystemManager.network.confirm_save_downloaded(save_id, device_id, func(_data, confirm_error):
							if confirm_error != "":
								push_warning("[GameSaveSubManager] Failed to confirm download: " + confirm_error)
							
							var _post_extraction = func():
								# Ensure PCSX2 superblock is valid after extracting saves
								if emulator_id == "pcsx2":
									print("[GameSaveSubManager] Ensuring PCSX2 superblock is valid after save sync...")
									var memcard_path = save_dir
									ensure_pcsx2_superblock(memcard_path)
								# Small delay to let filesystem settle before emulator launch
								await get_tree().create_timer(0.1).timeout
								DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT)
								state.pending -= 1
								if state.pending <= 0 and state.failed == 0:
									SystemManager.notifications.show_notification("Saves downloaded from RomM", SystemManager.notifications.Type.INFO)
								check_complete.call()
							
							if is_folder_save:
								var extract_dest = _get_extract_dest(emulator_id, save_dir, record_path, game, file_name)
								FSM.extract_archive_async(zip_path, extract_dest, "Save data", true,
									func(_info: Dictionary): pass,
									func(extract_success: bool, _error):
										if not extract_success:
											state.failed += 1
											push_error("[GameSaveSubManager] Failed to extract downloaded zip: " + zip_path)
										_cleanup_temp_dir(zip_path)
										_post_extraction.call()
								)
							elif local_path.to_lower().ends_with(".zip"):
								# Non-folder save but downloaded as zip (e.g., GameCube .gci in zip)
								var extract_dest = _get_extract_dest(emulator_id, save_dir, record_path, game, file_name)
								print("[GameSaveSubManager] Extracting non-folder zip save for " + emulator_id + " to: " + extract_dest)
								FSM.extract_archive_async(local_path, extract_dest, "Save data", true,
									func(_info: Dictionary): pass,
									func(extract_success: bool, _error):
										if not extract_success:
											state.failed += 1
											push_error("[GameSaveSubManager] Failed to extract downloaded zip: " + local_path)
										_post_extraction.call()
								)
							else:
								# No extraction needed
								_post_extraction.call()
						)
					)
			# If no downloads were queued, call completion immediately
			if state.pending == 0:
				check_complete.call()
		)
	)

## Validates that a PCSX2 superblock exists and has a valid header.
## Returns true if valid, false if missing or invalid.
func validate_pcsx2_superblock(memcard_path: String) -> bool:
	var superblock_path = memcard_path.rstrip("/") + "/_pcsx2_superblock"
	if not FSM.file_exists(superblock_path):
		return false
	var existing = FSM.open_file_read(superblock_path)
	if not existing:
		return false
	var header = existing.get_buffer(28)
	existing.close()
	var magic = "Sony PS2 Memory Card Format "
	for i in range(min(header.size(), magic.length())):
		if header[i] != magic.unicode_at(i):
			return false
	return true

## Creates a valid PS2 memory card superblock header for PCSX2 folder memory cards.
## Always writes a fresh superblock regardless of existing state.
## PCSX2 handles directory scanning itself; we only need to provide the card metadata header.
func create_pcsx2_superblock(memcard_path: String) -> bool:
	var superblock_path = memcard_path.rstrip("/") + "/_pcsx2_superblock"
	print("[GameSaveSubManager] Creating PCSX2 superblock at: " + superblock_path)
	
	var sb = PackedByteArray()
	sb.resize(8192)
	sb.fill(0)
	
	# Magic string: "Sony PS2 Memory Card Format " (28 bytes)
	var magic = "Sony PS2 Memory Card Format "
	for i in range(magic.length()):
		sb[i] = magic.unicode_at(i)
	
	# Version: "1.2.0.0" (12 bytes)
	var version = "1.2.0.0"
	for i in range(version.length()):
		sb[0x1C + i] = version.unicode_at(i)
	
	# Page size: 512
	sb.encode_u16(0x28, 512)
	# Pages per cluster: 2
	sb.encode_u16(0x2A, 2)
	# Pages per erase block: 16
	sb.encode_u16(0x2C, 16)
	# Unused: 0xFF00
	sb.encode_u16(0x2E, 0xFF00)
	# Clusters per card: 8192 (8MB)
	sb.encode_u32(0x30, 8192)
	# Allocatable cluster offset: 41
	sb.encode_u32(0x34, 41)
	# Allocatable cluster end: 8135
	sb.encode_u32(0x38, 8135)
	# Rootdir cluster: 0
	sb.encode_u32(0x3C, 0)
	# Good block 1: 1023
	sb.encode_u32(0x40, 1023)
	# Good block 2: 1022
	sb.encode_u32(0x44, 1022)
	# Indirect FAT cluster list: cluster 8 at offset 0x50
	sb.encode_u32(0x50, 8)
	for i in range(1, 32):
		sb.encode_u32(0x50 + (i * 4), 0xFFFFFFFF)
	# Bad erase block list: all 0xFFFFFFFF
	for i in range(32):
		sb.encode_u32(0xD0 + (i * 4), 0xFFFFFFFF)
	# Card type: 2
	sb[0x150] = 2
	# Card flags: 0x2B
	sb[0x151] = 0x2B
	
	# Fill remaining bytes with 0xFF
	for i in range(512, 8192):
		sb[i] = 0xFF
	
	if not FSM.write_file_bytes(superblock_path, sb):
		push_error("[GameSaveSubManager] Failed to write PCSX2 superblock: " + superblock_path)
		return false
	
	print("[GameSaveSubManager] PCSX2 superblock created successfully")
	return true

## Validates the PCSX2 superblock and creates it only if invalid or missing.
## Returns true if valid (or successfully created), false on error.
func ensure_pcsx2_superblock(memcard_path: String) -> bool:
	if validate_pcsx2_superblock(memcard_path):
		return true
	return create_pcsx2_superblock(memcard_path)

## Returns a human-readable sync status for the UI
func get_save_sync_status_text(game: GameResource, emulator_id: String) -> String:
	var records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
	if records.is_empty():
		return "Not synced"
	
	var latest = ""
	for rec in records:
		if rec.last_synced_at > latest:
			latest = rec.last_synced_at
	
	if latest == "":
		return "Not synced"
	
	var unix = parse_iso_timestamp(latest)
	if unix > 0:
		var now = Time.get_unix_time_from_system()
		var diff = int(now - unix)
		if diff < 60:
			return "Synced just now"
		elif diff < 3600:
			return "Synced %d min ago" % (diff / 60.0)
		elif diff < 86400:
			return "Synced %d hours ago" % (diff / 3600.0)
		else:
			return "Synced %d days ago" % (diff / 86400.0)
	
	return "Synced"


