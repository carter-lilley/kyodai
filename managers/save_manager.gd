extends Manager

## Manages save file discovery and syncing with RomM server

signal save_sync_completed(game: GameResource, success: bool, message: String)

const SLOT_DEFAULT := ""

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

func _extract_zip_to_directory(zip_path: String, dest_dir: String) -> bool:
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK:
		push_error("[SaveManager] Failed to open ZIP for extraction: " + zip_path)
		return false
	
	var files = reader.get_files()
	var is_saf_dest = FileSystemManager.is_saf_path(dest_dir) and FileSystemManager.is_android()
	var actual_dest = dest_dir
	var temp_dest = ""
	
	if is_saf_dest:
		temp_dest = "user://extract_temp/save_sync_" + str(Time.get_ticks_msec()) + "/"
		actual_dest = ProjectSettings.globalize_path(temp_dest)
		if not DirAccess.dir_exists_absolute(actual_dest):
			DirAccess.make_dir_recursive_absolute(actual_dest)
	
	for file in files:
		var file_dest = actual_dest.rstrip("/") + "/" + file
		if file.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(file_dest)
			continue
		
		var parent = file_dest.get_base_dir()
		DirAccess.make_dir_recursive_absolute(parent)
		
		var data = reader.read_file(file)
		var file_obj = FileAccess.open(file_dest, FileAccess.WRITE)
		if file_obj:
			file_obj.store_buffer(data)
			file_obj.close()
		else:
			push_error("[SaveManager] Failed to write extracted file: " + file_dest)
			reader.close()
			return false
	
	reader.close()
	
	if is_saf_dest:
		var success = FileSystemManager.copy_dir_to_saf(temp_dest, dest_dir)
		_remove_dir_recursive(actual_dest)
		return success
	
	return true

func _remove_dir_recursive(dir_path: String) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var item = dir.get_next()
	while item != "":
		if item != "." and item != "..":
			var full = dir_path.rstrip("/") + "/" + item
			if dir.current_is_dir():
				_remove_dir_recursive(full)
			else:
				DirAccess.remove_absolute(full)
		item = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)

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
		if game.title_id == "" or game.title_id.length() != 16:
			if callback.is_valid():
				callback.call(false, "No Title ID available for this game. Launch it once to extract the Title ID.")
			return
		local_saves = discover_local_folder_save(save_dir, game.title_id)
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
			var short_title_id = game.title_id.substr(8, 8)
			var zip_path = "user://temp_saves/" + str(game.romm_id) + "/" + short_title_id + ".zip"
			print("[SaveManager] Preparing folder save upload for " + short_title_id + " from base: " + original_path)
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
			print("[SaveManager] Zipping console profile to: " + zip_path)
			if not FileSystemManager.zip_directory(original_path, zip_path):
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
			
			if not download.local:
				var save_dir = resolve_save_directory(emulator_id)
				var id0 = _find_first_subdir(save_dir)
				if id0 == "":
					state.failed += 1
					push_error("[SaveManager] Cannot download folder save: no id0 folder found in " + save_dir)
					check_complete.call()
					continue
				var id1 = _find_first_subdir(save_dir + id0 + "/")
				if id1 == "":
					state.failed += 1
					push_error("[SaveManager] Cannot download folder save: no id1 folder found in " + save_dir + id0 + "/")
					check_complete.call()
					continue
				var category = game.title_id.substr(0, 8)
				var short_title_id = game.title_id.substr(8, 8)
				record_path = save_dir + id0 + "/" + id1 + "/title/" + category + "/" + short_title_id
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
					var extract_success = _extract_zip_to_directory(zip_path, record_path.get_base_dir())
					if not extract_success:
						state.failed += 1
						push_error("[SaveManager] Failed to extract downloaded zip: " + zip_path)
					if FileAccess.file_exists(zip_path):
						DirAccess.remove_absolute(zip_path)
				
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
	if not _is_sync_enabled():
		return
	if not SettingsManager.get_setting("save_sync_auto").value:
		return
	if not NetworkManager.is_romm_connected():
		return
	
	var save_dir = resolve_save_directory(emulator_id)
	var extensions = get_save_extensions(emulator_id)
	if save_dir == "" or extensions.is_empty():
		return
	
	var is_folder_save = uses_folder_saves(emulator_id)
	var local_saves: Array[Dictionary]
	if is_folder_save:
		if game.title_id == "":
			return
		local_saves = discover_local_folder_save(save_dir, game.title_id)
	else:
		var rom_name_no_ext = game.get_active_file_name().get_basename()
		local_saves = discover_local_saves(save_dir, rom_name_no_ext, extensions)
	
	if local_saves.is_empty():
		return
	
	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[SaveManager] Auto-upload aborted: " + error)
			return
		
		var device_id = DataManager.get_romm_device_id()
		var current_timestamp = Time.get_datetime_string_from_system(true, true)
		var state = {"pending": local_saves.size(), "failed": 0}
		
		for local in local_saves:
			var local_file_name = local.file_name
			var local_file_path = local.file_path
			
			if is_folder_save:
				var short_title_id = game.title_id.substr(8, 8)
				var zip_path = "user://temp_saves/" + str(game.romm_id) + "/" + short_title_id + ".zip"
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
				if not FileSystemManager.zip_directory(local_file_path, zip_path):
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
func auto_download_saves_for_game(game: GameResource, emulator_id: String) -> void:
	if not _is_sync_enabled():
		return
	if not SettingsManager.get_setting("save_sync_auto").value:
		return
	if not NetworkManager.is_romm_connected():
		return
	
	var save_dir = resolve_save_directory(emulator_id)
	var extensions = get_save_extensions(emulator_id)
	if save_dir == "" or extensions.is_empty():
		return
	
	var is_folder_save = uses_folder_saves(emulator_id)
	
	_ensure_device_registered(func(_success: bool, error: String):
		if not _success:
			push_error("[SaveManager] Auto-download aborted: " + error)
			return
		
		var device_id = DataManager.get_romm_device_id()
		
		NetworkManager.fetch_saves(game.romm_id, device_id, func(remote_saves: Array, error: String):
			if error != "":
				push_warning("[SaveManager] Pre-launch fetch failed: " + error)
				return
			
			var db_records = DataManager.get_save_sync_records(game.romm_id, emulator_id)
			var db_by_name: Dictionary = {}
			for rec in db_records:
				db_by_name[rec.file_name] = rec
			
			var local_saves: Array[Dictionary]
			if is_folder_save:
				if game.title_id == "" or game.title_id.length() != 16:
					return
				local_saves = discover_local_folder_save(save_dir, game.title_id)
			else:
				var rom_name_no_ext = game.get_active_file_name().get_basename()
				local_saves = discover_local_saves(save_dir, rom_name_no_ext, extensions)
			
			var local_by_name: Dictionary = {}
			for save in local_saves:
				local_by_name[save.file_name] = save
			
			var current_timestamp = Time.get_datetime_string_from_system(true, true)
			var state = {"pending": 0, "failed": 0}
			
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
							var id0 = _find_first_subdir(save_dir)
							if id0 == "":
								state.failed += 1
								push_error("[SaveManager] Cannot auto-download folder save: no id0 folder found")
								state.pending -= 1
								continue
							var id1 = _find_first_subdir(save_dir + id0 + "/")
							if id1 == "":
								state.failed += 1
								push_error("[SaveManager] Cannot auto-download folder save: no id1 folder found")
								state.pending -= 1
								continue
							var category = game.title_id.substr(0, 8)
							var short_title_id = game.title_id.substr(8, 8)
							record_path = save_dir + id0 + "/" + id1 + "/title/" + category + "/" + short_title_id
					else:
						local_path = record_path
					
					NetworkManager.download_save(save_id, device_id, local_path, func(success: bool, status_code: int, error_msg: String):
						if not success:
							state.failed += 1
							push_error("[SaveManager] Pre-launch download failed: " + error_msg)
							state.pending -= 1
							return
						
						NetworkManager.confirm_save_downloaded(save_id, device_id, func(_data, confirm_error):
							if confirm_error != "":
								push_warning("[SaveManager] Failed to confirm download: " + confirm_error)
							
							if is_folder_save:
								var extract_success = _extract_zip_to_directory(zip_path, record_path.get_base_dir())
								if not extract_success:
									state.failed += 1
									push_error("[SaveManager] Failed to extract downloaded zip: " + zip_path)
								if FileAccess.file_exists(zip_path):
									DirAccess.remove_absolute(zip_path)
							
							DataManager.update_save_sync_record(game.romm_id, emulator_id, file_name, record_path, current_timestamp, save_id, SLOT_DEFAULT)
							state.pending -= 1
							if state.pending <= 0 and state.failed == 0:
								NotificationManager.show_notification("Saves downloaded from RomM", Notification.Type.INFO)
						)
					)
		)
	)

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
