extends Manager

## Manages save file discovery and syncing with RomM server

signal save_sync_completed(game: GameResource, success: bool, message: String)

const SLOT_DEFAULT := ""
const MAX_FILE_SIZE := 100 * 1024 * 1024

func _ready() -> void:
	# Clean up orphaned temp directories on startup
	_cleanup_all_temp_dirs()

## Cleans up all temp directories under user://temp_saves/
func _cleanup_all_temp_dirs() -> void:
	var temp_base = "user://temp_saves"
	if not FileSystemManager.dir_exists(temp_base):
		return
	var items = FileSystemManager.list_dir(temp_base + "/")
	for item in items:
		if item == "." or item == "..":
			continue
		var full_path = temp_base + "/" + item
		if FileSystemManager.dir_exists(full_path):
			print("[SaveManager] Cleaning up temp directory: " + full_path)
			FileSystemManager.delete_dir_recursive(full_path)

## Cleans up empty parent directories after removing a temp file
func _cleanup_temp_dir(file_path: String) -> void:
	var parent = file_path.get_base_dir()
	while parent != "" and parent != "user://" and parent != "res://":
		if FileSystemManager.dir_exists(parent):
			var items = FileSystemManager.list_dir(parent + "/")
			var has_files = false
			for item in items:
				if item != "." and item != "..":
					has_files = true
					break
			if not has_files:
				print("[SaveManager] Removing empty temp directory: " + parent)
				DirAccess.remove_absolute(parent)
				parent = parent.get_base_dir()
			else:
				break
		else:
			break

## Returns the configured global save folder override, or empty string if not set
func _get_global_save_override() -> String:
	var setting = SettingsManager.get_setting("global_save_folder_override")
	if setting and setting.value is String and setting.value != "":
		return setting.value.rstrip("/")
	return ""

## Resolves the save directory for an emulator
## Priority: 1. Global override, 2. Registry per-platform directory
func resolve_save_directory(emulator_id: String) -> String:
	var override = _get_global_save_override()
	if override != "":
		return override + "/"
	
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return ""
	
	var save_config = emulator.get("save_config", {})
	var directories = save_config.get("directories", {})
	var platform_name = PlatformManager.get_platform_name().to_lower()
	
	var dir = directories.get(platform_name, "")
	if dir == "":
		dir = directories.get("all", "")
	
	if dir == "":
		return ""
	
	if dir.begins_with("{emulator_dir}"):
		var emulator_dir = LaunchManager._get_emulator_directory(emulator_id).rstrip("/")
		dir = dir.replace("{emulator_dir}", emulator_dir)
	
	if dir.begins_with("{games_dir}"):
		var games_folder_setting = SettingsManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value.rstrip("/") if games_folder_setting else "user://roms"
		dir = dir.replace("{games_dir}", games_dir)
	
	return dir.rstrip("/") + "/"

## Gets the save file extensions for an emulator
func get_save_extensions(emulator_id: String) -> Array[String]:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return []
	
	var save_config = emulator.get("save_config", {})
	var extensions = save_config.get("extensions", [])
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
	
	if not FileSystemManager.dir_exists(directory):
		return results
	
	_search_directory_for_saves(directory, rom_name_no_ext, extensions, results)
	return results

func _search_directory_for_saves(dir_path: String, rom_name_no_ext: String, extensions: Array[String], results: Array[Dictionary]) -> void:
	var items = FileSystemManager.list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var full_path = dir_path + item
		if FileSystemManager.dir_exists(full_path):
			_search_directory_for_saves(full_path + "/", rom_name_no_ext, extensions, results)
		elif FileSystemManager.file_exists(full_path):
			var item_no_ext = item.get_basename()
			var item_ext = item.get_extension()
			if item_no_ext == rom_name_no_ext:
				var dot_ext = "." + item_ext
				if dot_ext in extensions:
					var modified_time = 0
					if not FileSystemManager.is_saf_path(full_path):
						modified_time = FileAccess.get_modified_time(full_path)
					results.append({
						"file_name": item,
						"file_path": full_path,
						"modified_time": modified_time,
						"extension": dot_ext
					})

func uses_folder_saves(emulator_id: String) -> bool:
	var emulator = LaunchManager.get_emulator(emulator_id)
	if emulator.is_empty():
		return false
	var save_config = emulator.get("save_config", {})
	return save_config.get("uses_folder_saves", false)

func discover_local_folder_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		return results
	
	if not FileSystemManager.dir_exists(directory):
		return results
	
	var category = title_id.substr(0, 8)
	var short_title_id = title_id.substr(8, 8)
	
	var id0_dirs = FileSystemManager.list_dir(directory)
	for id0 in id0_dirs:
		if id0 == "." or id0 == ".." or not FileSystemManager.dir_exists(directory + id0):
			continue
		var id1_dirs = FileSystemManager.list_dir(directory + id0 + "/")
		for id1 in id1_dirs:
			if id1 == "." or id1 == ".." or not FileSystemManager.dir_exists(directory + id0 + "/" + id1):
				continue
			var title_path = directory + id0 + "/" + id1 + "/title/" + category + "/" + short_title_id
			if FileSystemManager.dir_exists(title_path):
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
	
	if not FileSystemManager.dir_exists(directory):
		return results
	
	var short_title_id = title_id.substr(8, 8)
	var prefixes: Array[String] = ["00050000", "00050010", "0005000e", "0005000c"]
	
	for prefix in prefixes:
		var save_path = directory + prefix + "/" + short_title_id
		if FileSystemManager.dir_exists(save_path):
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
	
	if not FileSystemManager.dir_exists(directory):
		return results
	
	var regions: Array[String] = ["USA", "EUR", "JAP", "KOR"]
	
	for region in regions:
		var card_dirs: Array[String] = ["Card A", "Card B"]
		for card in card_dirs:
			var card_path = directory + "GC/" + region + "/" + card + "/"
			if not FileSystemManager.dir_exists(card_path):
				continue
			
			var items = FileSystemManager.list_dir(card_path)
			for item in items:
				if item == "." or item == "..":
					continue
				if item.to_lower().ends_with(".gci") and game_id.to_lower() in item.to_lower():
					var mtime = _get_folder_mtime(card_path)
					results.append({
						"file_name": game_id + ".zip",
						"file_path": card_path,
						"modified_time": mtime,
						"extension": ".zip"
					})
					return results
	
	return results

func _game_id_to_hex(game_id: String) -> String:
	var hex = ""
	for c in game_id:
		hex += "%02x" % c.unicode_at(0)
	return hex

func discover_local_dolphin_wii_save(directory: String, game_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or game_id == "":
		return results
	
	var title_path = directory + "Wii/title/"
	if not FileSystemManager.dir_exists(title_path):
		return results
	
	var hex_id = _game_id_to_hex(game_id)
	
	var prefix_dirs = FileSystemManager.list_dir(title_path)
	for prefix in prefix_dirs:
		if prefix == "." or prefix == "..":
			continue
		var prefix_path = title_path + prefix + "/"
		if not FileSystemManager.dir_exists(prefix_path):
			continue
		
		var game_path = prefix_path + hex_id
		if FileSystemManager.dir_exists(game_path):
			var mtime = _get_folder_mtime(game_path)
			results.append({
				"file_name": hex_id + ".zip",
				"file_path": game_path,
				"modified_time": mtime,
				"extension": ".zip"
			})
			return results
	
	return results

func discover_local_eden_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "" or title_id.length() != 16:
		print("[SaveManager] discover_local_eden_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var dir_exists = FileSystemManager.dir_exists(directory)
	print("[SaveManager] discover_local_eden_save: dir_exists(" + directory + ") = " + str(dir_exists))
	if not dir_exists:
		return results
	
	var best_path = ""
	var best_mtime = 0
	
	var profile_dirs = FileSystemManager.list_dir(directory)
	print("[SaveManager] discover_local_eden_save: profile_dirs = " + str(profile_dirs))
	for profile in profile_dirs:
		if profile == "." or profile == "..":
			continue
		var profile_path = directory + profile + "/"
		if not FileSystemManager.dir_exists(profile_path):
			continue
		
		var save_path = profile_path + title_id
		var save_exists = FileSystemManager.dir_exists(save_path)
		print("[SaveManager] discover_local_eden_save: checking " + save_path + " -> " + str(save_exists))
		if save_exists:
			var mtime = _get_folder_mtime(save_path)
			print("[SaveManager] discover_local_eden_save: found save with mtime=" + str(mtime))
			if mtime > best_mtime:
				best_mtime = mtime
				best_path = save_path
	
	if best_path != "":
		results.append({
			"file_name": title_id + ".zip",
			"file_path": best_path,
			"modified_time": best_mtime,
			"extension": ".zip"
		})
	
	print("[SaveManager] discover_local_eden_save: results = " + str(results))
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
		if not FileSystemManager.dir_exists(current):
			continue
		
		var items = FileSystemManager.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			
			var full_path = current.rstrip("/") + "/" + item
			
			if FileSystemManager.dir_exists(full_path):
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
		print("[SaveManager] discover_local_pcsx2_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	print("[SaveManager] discover_local_pcsx2_save: searching for serial " + title_id + " in " + directory)
	var results = discover_local_fuzzy_folder_save(directory, title_id, true, false)
	
	if results.is_empty():
		print("[SaveManager] discover_local_pcsx2_save: no saves found for serial " + title_id)
	else:
		print("[SaveManager] discover_local_pcsx2_save: returning save at " + results[0].file_path)
	
	return results

## Discovers local PPSSPP saves for a PSP game
## Returns an array of save dictionaries, one per matching folder
## PSP games can have multiple save folders (e.g., ULUS10509DAT, ULUS10509DLC)
func discover_local_psp_save(directory: String, title_id: String) -> Array[Dictionary]:
	if directory == "" or title_id == "":
		print("[SaveManager] discover_local_psp_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return []
	
	# PPSSPP save_config already includes SAVEDATA in the path
	# e.g., {emulator_dir}/memstick/PSP/SAVEDATA
	var savedata_dir = directory.rstrip("/") + "/"
	print("[SaveManager] discover_local_psp_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FileSystemManager.dir_exists(savedata_dir):
		print("[SaveManager] discover_local_psp_save: SAVEDATA dir doesn't exist yet")
		return []
	
	var results = discover_local_fuzzy_folder_save(savedata_dir, title_id, false, true)
	print("[SaveManager] discover_local_psp_save: found " + str(results.size()) + " matching save folders")
	
	return results

## Discovers local Vita3K saves for a PSVita game
## Vita3K saves are folders directly in savedata/ named by TitleID (e.g., PCSA00152)
func discover_local_vita3k_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		print("[SaveManager] discover_local_vita3k_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var savedata_dir = directory.rstrip("/") + "/"
	print("[SaveManager] discover_local_vita3k_save: searching in " + savedata_dir + " for title_id " + title_id)
	
	if not FileSystemManager.dir_exists(savedata_dir):
		print("[SaveManager] discover_local_vita3k_save: savedata dir doesn't exist yet")
		return results
	
	# Look for exact match folder
	var save_path = savedata_dir + title_id
	if FileSystemManager.dir_exists(save_path):
		var mtime = _get_folder_mtime(save_path)
		results.append({
			"file_name": title_id + ".zip",
			"file_path": save_path,
			"modified_time": mtime,
			"extension": ".zip"
		})
		print("[SaveManager] discover_local_vita3k_save: found save at " + save_path)
	else:
		print("[SaveManager] discover_local_vita3k_save: no save found for " + title_id)
	
	return results

## Discovers local Xenia saves for an Xbox 360 game
## Xenia saves are in content/PROFILE_ID/TITLE_ID/ (PROFILE_ID varies per user)
## We search recursively from the content directory for matching TITLE_ID folders
func discover_local_xenia_save(directory: String, title_id: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if directory == "" or title_id == "":
		print("[SaveManager] discover_local_xenia_save: invalid args (dir=" + directory + ", tid=" + title_id + ")")
		return results
	
	var content_dir = directory.rstrip("/") + "/"
	print("[SaveManager] discover_local_xenia_save: searching in " + content_dir + " for title_id " + title_id)
	
	if not FileSystemManager.dir_exists(content_dir):
		print("[SaveManager] discover_local_xenia_save: content dir doesn't exist yet")
		return results
	
	# Search recursively through all profile subdirectories
	var dirs_to_check: Array[String] = [content_dir]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		var items = FileSystemManager.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			
			var full_path = current.rstrip("/") + "/" + item
			if FileSystemManager.dir_exists(full_path):
				# Check if this directory matches our Title ID
				if item.to_upper() == title_id.to_upper():
					var mtime = _get_folder_mtime(full_path)
					results.append({
						"file_name": title_id.to_upper() + ".zip",
						"file_path": full_path,
						"modified_time": mtime,
						"extension": ".zip"
					})
					print("[SaveManager] discover_local_xenia_save: found save at " + full_path)
					return results
				else:
					# Continue searching deeper (profile subdirectories)
					dirs_to_check.append(full_path)
	
	print("[SaveManager] discover_local_xenia_save: no save found for " + title_id)
	return results

func _get_folder_mtime(dir_path: String) -> int:
	var latest = 0
	var dirs_to_check: Array[String] = [dir_path]
	while not dirs_to_check.is_empty():
		var current = dirs_to_check.pop_back()
		var items = FileSystemManager.list_dir(current)
		for item in items:
			if item == "." or item == "..":
				continue
			var full = current.rstrip("/") + "/" + item
			if FileSystemManager.dir_exists(full):
				dirs_to_check.append(full)
			elif FileSystemManager.file_exists(full) and not FileSystemManager.is_saf_path(full):
				var mtime = FileAccess.get_modified_time(full)
				if mtime > latest:
					latest = mtime
	return latest

## Validates that a game's title ID is valid for the given emulator
## Returns empty string on success, error message on failure
func _validate_emulator_title_id(emulator_id: String, title_id: String) -> String:
	match emulator_id:
		"cemu", "eden":
			if title_id.length() != 16:
				return "Invalid Title ID for %s game." % emulator_id.capitalize()
		"pcsx2":
			if title_id == "":
				return "No serial available for this PS2 game. Launch it once to extract the serial."
		"ppsspp":
			if title_id == "":
				return "No game ID available for this PSP game. Launch it once to extract the ID."
		"vita3k":
			if title_id == "":
				return "No Title ID available for this Vita game. Launch it once to extract the Title ID."
		"xenia":
			if title_id == "":
				return "No Title ID available for this Xbox 360 game. Launch it once to extract the Title ID."
			if title_id.length() != 8:
				return "Invalid Title ID for Xbox 360 game."
		_:
			if title_id.length() != 16:
				return "Invalid Title ID for this game."
	return ""

## Discovers local saves for a specific emulator and game
## Returns an array of save dictionaries
func _discover_emulator_saves(emulator_id: String, save_dir: String, game: GameResource) -> Array[Dictionary]:
	var title_id = game.get_active_title_id()
	match emulator_id:
		"cemu":
			return discover_local_cemu_save(save_dir, title_id)
		"dolphin":
			if game.platform_slug == "wii":
				return discover_local_dolphin_wii_save(save_dir, title_id)
			return discover_local_dolphin_gc_save(save_dir, title_id)
		"eden":
			return discover_local_eden_save(save_dir, title_id)
		"pcsx2":
			return discover_local_pcsx2_save(save_dir, title_id)
		"ppsspp":
			return discover_local_psp_save(save_dir, title_id)
		"vita3k":
			return discover_local_vita3k_save(save_dir, title_id)
		"xenia":
			return discover_local_xenia_save(save_dir, title_id)
		_:
			return discover_local_folder_save(save_dir, title_id)

## Resolves the save path for the default emulator folder structure
## Returns a dictionary with "path" and "error" keys
func _resolve_default_save_path(save_dir: String, title_id: String) -> Dictionary:
	var short_title_id = title_id.substr(8, 8)
	var id0 = _find_first_subdir(save_dir)
	if id0 == "":
		return {"path": "", "error": "no_id0"}
	var id1 = _find_first_subdir(save_dir + id0 + "/")
	if id1 == "":
		return {"path": "", "error": "no_id1"}
	var category = title_id.substr(0, 8)
	return {
		"path": save_dir + id0 + "/" + id1 + "/title/" + category + "/" + short_title_id,
		"error": ""
	}

## Resolves the save path for a specific emulator and game
## Returns the resolved path string (empty string on failure)
func _resolve_emulator_save_path(emulator_id: String, save_dir: String, game: GameResource) -> String:
	var title_id = game.get_active_title_id()
	match emulator_id:
		"cemu":
			return save_dir + "00050000/" + title_id.substr(8, 8)
		"dolphin":
			if game.platform_slug == "wii":
				return save_dir + "Wii/title/00010000/" + _game_id_to_hex(title_id)
			return save_dir + "GC/USA/Card A"
		"eden":
			var profile = _find_first_subdir(save_dir)
			if profile == "":
				profile = "0000000000000000"
			return save_dir + profile + "/" + title_id
		"pcsx2":
			return save_dir + "main.ps2/"
		"ppsspp":
			return save_dir + title_id + "/"
		"vita3k":
			return save_dir + title_id + "/"
		"xenia":
			# Xenia saves are in content/PROFILE_ID/TITLE_ID/
			# We need to find the profile directory first
			var profile = _find_first_subdir(save_dir)
			if profile == "":
				profile = "0000000000000000"
			return save_dir + profile + "/" + title_id + "/"
		_:
			var result = _resolve_default_save_path(save_dir, title_id)
			return result.path

## Determines the extraction destination for downloaded saves based on emulator
## Returns the destination directory path
func _get_extract_dest(emulator_id: String, save_dir: String, record_path: String, game: GameResource) -> String:
	match emulator_id:
		"cemu":
			# Cemu saves are in save_dir/{prefix}/{short_id}/
			# The zip root is {short_id}/, so extract to the prefix directory
			return record_path.get_base_dir()
		"dolphin":
			if game.platform_slug == "wii":
				return save_dir
			return record_path
		"pcsx2":
			return save_dir + "main.ps2/"
		"ppsspp":
			return save_dir
		"vita3k":
			return save_dir
		"xenia":
			return save_dir
		_:
			return record_path.get_base_dir()

## Determines the save name for upload based on emulator and game
## Returns the save name string
func _get_save_name_for_upload(emulator_id: String, game: GameResource, local_file_path: String = "") -> String:
	var title_id = game.get_active_title_id()
	match emulator_id:
		"dolphin":
			if game.platform_slug == "wii":
				return _game_id_to_hex(title_id)
			return title_id
		"pcsx2":
			# Use actual folder name for PCSX2 saves
			return local_file_path.get_file() if local_file_path != "" else title_id
		"ppsspp":
			# For PSP, always use the specific folder name as the save name
			# This allows multiple saves (e.g., NPJH50333DAT, NPJH50333USER00) to be uploaded separately
			if local_file_path != "":
				return local_file_path.get_file()
			return title_id
		"vita3k":
			# For Vita3K, use the TitleID as the save name
			return title_id
		"xenia":
			# For Xenia, use the TitleID as the save name
			return title_id
		_:
			return title_id.substr(8, 8)

## Creates a ZIP archive for a specific emulator's save
## Returns true on success
func _zip_emulator_save(emulator_id: String, source_path: String, zip_path: String, game: GameResource) -> bool:
	match emulator_id:
		"cemu":
			var save_name = game.get_active_title_id().substr(8, 8)
			return FileSystemManager.zip_directory_with_root(source_path, save_name, zip_path)
		"dolphin":
			if game.platform_slug == "wii":
				return _zip_dolphin_wii_save(source_path, zip_path)
			return _zip_dolphin_gc_saves(source_path, game.get_active_title_id(), zip_path)
		"pcsx2":
			return FileSystemManager.zip_directory(source_path, zip_path)
		"ppsspp":
			# For individual uploads, zip the specific folder with its name as root
			# This ensures extraction creates the correct subfolder (e.g., NPJH50333DAT/)
			# Skip files over 100MB (DLC/install data) to avoid Cloudflare 413 errors
			var folder_name = source_path.get_file()
			return FileSystemManager.zip_directory_with_root(source_path, folder_name, zip_path, MAX_FILE_SIZE)
		"vita3k":
			# For Vita3K, zip the save folder with TitleID as root
			var vita_folder_name = source_path.get_file()
			return FileSystemManager.zip_directory_with_root(source_path, vita_folder_name, zip_path)
		"xenia":
			# For Xenia, zip the save folder with TitleID as root
			var xenia_folder_name = source_path.get_file()
			return FileSystemManager.zip_directory_with_root(source_path, xenia_folder_name, zip_path)
		_:
			return FileSystemManager.zip_directory(source_path, zip_path)

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
	
	print("[SaveManager] _zip_psp_save: normalized_path=" + normalized_path + ", folder_name=" + folder_name + ", savedata_dir=" + savedata_dir)
	
	var saves = discover_local_psp_save(savedata_dir, title_id)
	
	if saves.is_empty():
		print("[SaveManager] _zip_psp_save: no saves found in " + savedata_dir)
		return false
	
	print("[SaveManager] _zip_psp_save: found " + str(saves.size()) + " save(s) to zip")
	
	# Copy all matching save folders to staging directory
	for save in saves:
		var save_folder_name = save.file_path.get_file()
		var dest = stage_dir + save_folder_name
		print("[SaveManager] _zip_psp_save: copying " + save.file_path + " to " + dest)
		var success = FileSystemManager.copy_dir(save.file_path, dest)
		if not success:
			push_error("[SaveManager] _zip_psp_save: failed to copy " + save.file_path)
			FileSystemManager.delete_dir_recursive(stage_dir)
			return false
	
	# Zip the staging directory
	print("[SaveManager] _zip_psp_save: creating zip at " + zip_path)
	var zip_success = FileSystemManager.zip_directory(stage_dir, zip_path, max_file_size)
	if not zip_success:
		push_error("[SaveManager] _zip_psp_save: failed to create zip " + zip_path)
	
	FileSystemManager.delete_dir_recursive(stage_dir)
	return zip_success

func _zip_dolphin_gc_saves(card_dir: String, game_id: String, dest_zip: String) -> bool:
	var stage_dir = "user://temp_saves/stage_" + str(Time.get_ticks_msec()) + "/"
	var copy_success = false
	
	var items = FileSystemManager.list_dir(card_dir)
	for item in items:
		if item == "." or item == "..":
			continue
		if item.to_lower().ends_with(".gci") and game_id.to_lower() in item.to_lower():
			var src = card_dir + item
			var dst = stage_dir + item
			var parent = dst.get_base_dir()
			DirAccess.make_dir_recursive_absolute(parent)
			var file = FileAccess.open(src, FileAccess.READ)
			if file:
				var data = file.get_buffer(file.get_length())
				file.close()
				var out = FileAccess.open(dst, FileAccess.WRITE)
				if out:
					out.store_buffer(data)
					out.close()
					copy_success = true
	
	if not copy_success:
		FileSystemManager.delete_dir_recursive(stage_dir)
		return false
	
	var zip_success = FileSystemManager.zip_directory(stage_dir, dest_zip)
	FileSystemManager.delete_dir_recursive(stage_dir)
	return zip_success

func _zip_dolphin_wii_save(source_dir: String, dest_zip: String) -> bool:
	var parts = source_dir.rstrip("/").split("/")
	if parts.size() < 2:
		return false
	var hex_id = parts[-1]
	var prefix = parts[-2]
	var stage_dir = "user://temp_saves/stage_" + str(Time.get_ticks_msec()) + "/"
	var stage_root = stage_dir + "Wii/title/" + prefix + "/" + hex_id
	DirAccess.make_dir_recursive_absolute(stage_root)
	var copy_success = FileSystemManager.copy_dir(source_dir, stage_root)
	if not copy_success:
		FileSystemManager.delete_dir_recursive(stage_dir)
		return false
	var zip_success = FileSystemManager.zip_directory(stage_dir, dest_zip)
	FileSystemManager.delete_dir_recursive(stage_dir)
	return zip_success

func _sanitize_filename(name: String) -> String:
	return name.replace("/", "_").replace("\\", "_").replace(":", "_").replace("*", "_").replace("?", "_").replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")

func _find_first_subdir(dir_path: String) -> String:
	var items = FileSystemManager.list_dir(dir_path)
	for item in items:
		if item != "." and item != ".." and FileSystemManager.dir_exists(dir_path + item):
			return item
	return ""

func _ensure_device_registered(callback: Callable) -> void:
	var device_id = DataManager.get_romm_device_id()
	if device_id != "":
		callback.call(true, "")
		return
	
	var platform_name = OS.get_name().to_lower()
	var device_name = "Kyodai (" + platform_name.capitalize() + ")"
	NetworkManager.register_device(device_name, platform_name, "kyodai", "1.0", func(data: Dictionary, error: String):
		if error != "":
			callback.call(false, "Device registration failed: " + error)
			return
		
		var new_device_id = data.get("device_id", "")
		if new_device_id == "":
			callback.call(false, "Device registration returned empty device_id")
			return
		
		DataManager.set_romm_device_id(new_device_id)
		print("[SaveManager] Registered device with RomM: " + new_device_id)
		callback.call(true, "")
	)

## Main sync entry point for manual and auto sync
func sync_saves_for_game(game: GameResource, emulator_id: String, callback: Callable = Callable()) -> void:
	if not _is_sync_enabled():
		if callback.is_valid():
			callback.call(false, "Save sync is disabled")
		return
	
	if not NetworkManager.is_romm_connected():
		if callback.is_valid():
			callback.call(false, "Not connected to RomM")
		return
	
	var save_dir = resolve_save_directory(emulator_id)
	var extensions = get_save_extensions(emulator_id)
	
	if save_dir == "" or extensions.is_empty():
		if callback.is_valid():
			callback.call(false, "No save configuration for emulator: " + emulator_id)
		return
	
	var local_saves: Array[Dictionary]
	if uses_folder_saves(emulator_id):
		if game.get_active_title_id() == "":
			if callback.is_valid():
				callback.call(false, "No Title ID available for this game. Launch it once to extract the Title ID.")
			return
		var validation_error = _validate_emulator_title_id(emulator_id, game.get_active_title_id())
		if validation_error != "":
			if callback.is_valid():
				callback.call(false, validation_error)
			return
		local_saves = _discover_emulator_saves(emulator_id, save_dir, game)
	else:
		var rom_name_no_ext = game.get_active_file_name().get_basename()
		local_saves = discover_local_saves(save_dir, rom_name_no_ext, extensions)
	
	_ensure_device_registered(func(success: bool, error: String):
		if not success:
			if callback.is_valid():
				callback.call(false, error)
			return
		
		var device_id = DataManager.get_romm_device_id()
		NetworkManager.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, error: String):
			if error != "":
				if callback.is_valid():
					callback.call(false, "Failed to fetch remote saves: " + error)
				return
			
			_run_sync(game, emulator_id, local_saves, remote_saves, device_id, callback)
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
	
	for local in local_saves:
		var file_name = local.file_name
		var remote = remote_by_name.get(file_name)
		var db_rec = db_by_name.get(file_name)
		var last_synced_unix = 0
		var local_mtime = local.modified_time
		if db_rec:
			last_synced_unix = _parse_iso_to_unix(db_rec.last_synced_at)
		
		if remote:
			var remote_updated_unix = _parse_iso_to_unix(remote.get("updated_at", ""))
			
			if local_mtime > last_synced_unix and remote_updated_unix > last_synced_unix:
				pending_uploads.append({"local": local, "remote": remote})
			elif local_mtime > last_synced_unix:
				pending_uploads.append({"local": local, "remote": remote})
			elif remote_updated_unix > last_synced_unix:
				pending_downloads.append({"local": local, "remote": remote})
		else:
			if local_mtime > last_synced_unix or last_synced_unix == 0:
				pending_uploads.append({"local": local, "remote": null})
	
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
	
	var is_folder_save = uses_folder_saves(emulator_id)
	
	for upload in pending_uploads:
		var upload_file_name = upload.local.file_name
		var original_path = upload.local.file_path
		
		if is_folder_save:
			var save_name = _get_save_name_for_upload(emulator_id, game, original_path)
			var zip_path = "user://temp_saves/" + str(game.romm_id) + "/" + save_name + ".zip"
			print("[SaveManager] Preparing folder save upload for " + save_name + " from base: " + original_path)
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
			var zip_success = _zip_emulator_save(emulator_id, original_path, zip_path, game)
			if not zip_success:
				state.failed += 1
				push_error("[SaveManager] Failed to zip folder for upload: " + original_path)
				check_complete.call()
				continue
			
			NetworkManager.upload_save(
				game.romm_id,
				zip_path,
				emulator_id,
				SLOT_DEFAULT,
				device_id,
				true,
				func(data: Dictionary, error: String):
					if FileAccess.file_exists(zip_path):
						DirAccess.remove_absolute(zip_path)
					# Clean up empty parent directories
					_cleanup_temp_dir(zip_path)
					if error != "":
						state.failed += 1
						push_error("[SaveManager] Upload failed for " + original_path + ": " + error)
					else:
						var remote_id = data.get("id", 0)
						DataManager.update_save_sync_record(game.romm_id, emulator_id, upload_file_name, original_path, current_timestamp, remote_id, SLOT_DEFAULT)
					check_complete.call()
			)
		else:
			NetworkManager.upload_save(
				game.romm_id,
				original_path,
				emulator_id,
				SLOT_DEFAULT,
				device_id,
				true,
				func(data: Dictionary, error: String):
					if error != "":
						state.failed += 1
						push_error("[SaveManager] Upload failed for " + original_path + ": " + error)
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
			record_path = resolve_save_directory(emulator_id) + file_name
		
		if is_folder_save:
			zip_path = "user://temp_saves/download_" + str(Time.get_ticks_msec()) + ".zip"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
			local_path = zip_path
			var save_dir = resolve_save_directory(emulator_id)
			
			if not download.local:
				record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
				if record_path == "":
					var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
					if result.error != "":
						state.failed += 1
						push_error("[SaveManager] Cannot download folder save: no " + result.error + " folder found")
						check_complete.call()
						continue
					record_path = result.path
		else:
			local_path = record_path
		
		NetworkManager.download_save(save_id, device_id, local_path, func(_success: bool, status_code: int, error_msg: String):
			if not _success:
				state.failed += 1
				push_error("[SaveManager] Download failed for save " + str(save_id) + ": " + error_msg)
				check_complete.call()
				return
			
			NetworkManager.confirm_save_downloaded(save_id, device_id, func(_data, confirm_error):
				if confirm_error != "":
					push_warning("[SaveManager] Failed to confirm download: " + confirm_error)
				
				if is_folder_save:
					var extract_dest = _get_extract_dest(emulator_id, resolve_save_directory(emulator_id), record_path, game)
					# Don't use subfolder - the zip already contains the correct folder structure
					var extract_success = FileSystemManager.extract_zip_to_dir(zip_path, extract_dest, "")
					if not extract_success:
						state.failed += 1
						push_error("[SaveManager] Failed to extract downloaded zip: " + zip_path)
					if FileAccess.file_exists(zip_path):
						DirAccess.remove_absolute(zip_path)
					# Clean up empty parent directories
					_cleanup_temp_dir(zip_path)
					
						# Ensure PCSX2 superblock is valid after extracting saves
				if emulator_id == "pcsx2":
					print("[SaveManager] Ensuring PCSX2 superblock is valid after save sync...")
					var memcard_path = resolve_save_directory(emulator_id) + "main.ps2/"
					ensure_pcsx2_superblock(memcard_path)
				
				DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT)
				check_complete.call()
			)
		)

func _parse_iso_to_unix(iso_string: String) -> int:
	if iso_string == "":
		return 0
	var cleaned = iso_string.replace("Z", "+00:00")
	var dict = Time.get_datetime_dict_from_datetime_string(cleaned, false)
	if dict.is_empty():
		return 0
	return int(Time.get_unix_time_from_datetime_dict(dict))

## Auto-upload saves after playing (post-exit hook)
func auto_upload_saves_for_game(game: GameResource, emulator_id: String) -> void:
	print("[SaveManager] auto_upload_saves_for_game called for " + game.get_display_name() + " (" + emulator_id + ")")
	if not _is_sync_enabled():
		print("[SaveManager] Auto-upload aborted: sync not enabled")
		return
	if not SettingsManager.get_setting("save_sync_auto").value:
		print("[SaveManager] Auto-upload aborted: save_sync_auto is off")
		return
	if not NetworkManager.is_romm_connected():
		print("[SaveManager] Auto-upload aborted: not connected to RomM")
		return
	
	var save_dir = resolve_save_directory(emulator_id)
	var extensions = get_save_extensions(emulator_id)
	if save_dir == "" or extensions.is_empty():
		print("[SaveManager] Auto-upload aborted: no save dir or extensions (dir=" + save_dir + ", ext count=" + str(extensions.size()) + ")")
		return
	
	var is_folder_save = uses_folder_saves(emulator_id)
	var local_saves: Array[Dictionary]
	if is_folder_save:
		if game.get_active_title_id() == "":
			return
		local_saves = _discover_emulator_saves(emulator_id, save_dir, game)
	else:
		var rom_name_no_ext = game.get_active_file_name().get_basename()
		local_saves = discover_local_saves(save_dir, rom_name_no_ext, extensions)
	
	if local_saves.is_empty():
		print("[SaveManager] No local saves found for auto-upload (emulator: " + emulator_id + ", title_id: " + game.get_active_title_id() + ", dir: " + save_dir + "), skipping.")
		return
	
	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[SaveManager] Auto-upload aborted: " + error)
			return
		
		var device_id = DataManager.get_romm_device_id()
		var current_timestamp = Time.get_datetime_string_from_system(true, true)
		
		# Standard per-save upload for all emulators
		var state = {"pending": local_saves.size(), "failed": 0}
		
		for local in local_saves:
			var local_file_name = local.file_name
			var local_file_path = local.file_path
			
			if is_folder_save:
				var save_name = _get_save_name_for_upload(emulator_id, game, local_file_path)
				var zip_path = "user://temp_saves/" + str(game.romm_id) + "/" + save_name + ".zip"
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
				var zip_success = _zip_emulator_save(emulator_id, local_file_path, zip_path, game)
				if not zip_success:
					state.failed += 1
					push_error("[SaveManager] Failed to zip folder for auto-upload: " + local_file_path)
					state.pending -= 1
					if state.pending <= 0:
						if state.failed > 0:
							NotificationManager.show_notification("Save sync failed for some files", Notification.Type.ERROR)
						else:
							NotificationManager.show_notification("Saves synced to RomM", Notification.Type.INFO)
					continue
				
				NetworkManager.upload_save(
					game.romm_id,
					zip_path,
					emulator_id,
					SLOT_DEFAULT,
					device_id,
					true,
					func(data: Dictionary, error: String):
						if FileAccess.file_exists(zip_path):
							DirAccess.remove_absolute(zip_path)
						# Clean up empty parent directories
						_cleanup_temp_dir(zip_path)
						if error != "":
							state.failed += 1
							push_error("[SaveManager] Auto-upload failed: " + error)
						else:
							var remote_id = data.get("id", 0)
							print("[SaveManager] Auto-upload success for " + local_file_name + " -> remote save id: " + str(remote_id))
							DataManager.update_save_sync_record(game.romm_id, emulator_id, local_file_name, local_file_path, current_timestamp, remote_id, SLOT_DEFAULT)
						state.pending -= 1
						if state.pending <= 0:
							if state.failed > 0:
								NotificationManager.show_notification("Save sync failed for some files", Notification.Type.ERROR)
							else:
								NotificationManager.show_notification("Saves synced to RomM", Notification.Type.INFO)
				)
			else:
				NetworkManager.upload_save(
					game.romm_id,
					local_file_path,
					emulator_id,
					SLOT_DEFAULT,
					device_id,
					true,
					func(data: Dictionary, error: String):
						if error != "":
							state.failed += 1
							push_error("[SaveManager] Auto-upload failed: " + error)
						else:
							var remote_id = data.get("id", 0)
							print("[SaveManager] Auto-upload success for " + local_file_name + " -> remote save id: " + str(remote_id))
							DataManager.update_save_sync_record(game.romm_id, emulator_id, local_file_name, local_file_path, current_timestamp, remote_id, SLOT_DEFAULT)
						state.pending -= 1
						if state.pending <= 0:
							if state.failed > 0:
								NotificationManager.show_notification("Save sync failed for some files", Notification.Type.ERROR)
							else:
								NotificationManager.show_notification("Saves synced to RomM", Notification.Type.INFO)
				)
	)

## Auto-download saves before launch (pre-launch hook)
## If on_complete callback is provided, it will be called when sync finishes
func auto_download_saves_for_game(game: GameResource, emulator_id: String, on_complete: Callable = Callable()) -> void:
	if not _is_sync_enabled():
		if on_complete.is_valid():
			on_complete.call()
		return
	if not SettingsManager.get_setting("save_sync_auto").value:
		if on_complete.is_valid():
			on_complete.call()
		return
	if not NetworkManager.is_romm_connected():
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var save_dir = resolve_save_directory(emulator_id)
	var extensions = get_save_extensions(emulator_id)
	if save_dir == "" or extensions.is_empty():
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var is_folder_save = uses_folder_saves(emulator_id)
	
	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[SaveManager] Auto-download aborted: " + error)
			if on_complete.is_valid():
				on_complete.call()
			return
		
		var device_id = DataManager.get_romm_device_id()
		
		NetworkManager.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, error: String):
			if error != "":
				push_warning("[SaveManager] Pre-launch fetch failed: " + error)
				if on_complete.is_valid():
					on_complete.call()
				return
			
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
				local_saves = _discover_emulator_saves(emulator_id, save_dir, game)
			else:
				var rom_name_no_ext = game.get_active_file_name().get_basename()
				local_saves = discover_local_saves(save_dir, rom_name_no_ext, extensions)
			
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
				var remote_updated_unix = _parse_iso_to_unix(remote.get("updated_at", ""))
				
				var local = local_by_name.get(file_name)
				var db_rec = db_by_name.get(file_name)
				var last_synced_unix = 0
				if db_rec:
					last_synced_unix = _parse_iso_to_unix(db_rec.last_synced_at)
				
				var should_download = false
				if not local:
					should_download = true
				elif remote_updated_unix > last_synced_unix and remote_updated_unix > local.modified_time:
					should_download = true
				
				if should_download:
					state.pending += 1
					var _local = local_by_name.get(file_name)
					var record_path = ""
					var local_path = ""
					var zip_path = ""
					
					if _local:
						record_path = _local.file_path
					else:
						record_path = save_dir + file_name
					
					if is_folder_save:
						zip_path = "user://temp_saves/download_" + str(Time.get_ticks_msec()) + ".zip"
						DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
						local_path = zip_path
						
						if not _local:
							record_path = _resolve_emulator_save_path(emulator_id, save_dir, game)
							if record_path == "":
								var result = _resolve_default_save_path(save_dir, game.get_active_title_id())
								if result.error != "":
									state.failed += 1
									push_error("[SaveManager] Cannot auto-download folder save: no " + result.error + " folder found")
									state.pending -= 1
									check_complete.call()
									continue
								record_path = result.path
					else:
						local_path = record_path
					
					NetworkManager.download_save(save_id, device_id, local_path, func(success: bool, status_code: int, error_msg: String):
						if not success:
							state.failed += 1
							push_error("[SaveManager] Pre-launch download failed: " + error_msg)
							state.pending -= 1
							check_complete.call()
							return
						
						NetworkManager.confirm_save_downloaded(save_id, device_id, func(_data, confirm_error):
							if confirm_error != "":
								push_warning("[SaveManager] Failed to confirm download: " + confirm_error)
							
							if is_folder_save:
								var extract_dest = _get_extract_dest(emulator_id, save_dir, record_path, game)
								# Don't use subfolder - the zip already contains the correct folder structure
								var extract_success = FileSystemManager.extract_zip_to_dir(zip_path, extract_dest, "")
								if not extract_success:
									state.failed += 1
									push_error("[SaveManager] Failed to extract downloaded zip: " + zip_path)
								if FileAccess.file_exists(zip_path):
									DirAccess.remove_absolute(zip_path)
								# Clean up empty parent directories
								_cleanup_temp_dir(zip_path)
							
				# Ensure PCSX2 superblock is valid after extracting saves
							if emulator_id == "pcsx2":
								print("[SaveManager] Ensuring PCSX2 superblock is valid after save sync...")
								var memcard_path = save_dir + "main.ps2/"
								ensure_pcsx2_superblock(memcard_path)
							# Small delay to let filesystem settle before emulator launch
							OS.delay_msec(100)
							DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT)
							state.pending -= 1
							if state.pending <= 0 and state.failed == 0:
								NotificationManager.show_notification("Saves downloaded from RomM", Notification.Type.INFO)
							check_complete.call()
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
	if not FileAccess.file_exists(superblock_path):
		return false
	var existing = FileAccess.open(superblock_path, FileAccess.READ)
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
	print("[SaveManager] Creating PCSX2 superblock at: " + superblock_path)
	
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
	
	var file = FileAccess.open(superblock_path, FileAccess.WRITE)
	if not file:
		push_error("[SaveManager] Failed to write PCSX2 superblock: " + superblock_path)
		return false
	
	file.store_buffer(sb)
	file.close()
	print("[SaveManager] PCSX2 superblock created successfully")
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
	
	var unix = _parse_iso_to_unix(latest)
	if unix > 0:
		var now = Time.get_unix_time_from_system()
		var diff = int(now - unix)
		if diff < 60:
			return "Synced just now"
		elif diff < 3600:
			return "Synced %d min ago" % (diff / 60)
		elif diff < 86400:
			return "Synced %d hours ago" % (diff / 3600)
		else:
			return "Synced %d days ago" % (diff / 86400)
	
	return "Synced"

func _is_sync_enabled() -> bool:
	var setting = SettingsManager.get_setting("save_sync_enabled")
	return setting and setting.value
