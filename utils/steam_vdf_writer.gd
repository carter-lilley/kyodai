## Steam VDF Binary Format Writer/Reader
## Handles Steam's shortcuts.vdf file format for adding non-Steam games

class_name SteamVDFWriter

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

# VDF Type markers
const TYPE_NONE := 0x00
const TYPE_STRING := 0x01
const TYPE_INT32 := 0x02
const TYPE_UINT64 := 0x07
const TYPE_ENDOFOBJECT := 0x08
const TYPE_ENDOFOBJECT_ALT := 0x0B

## Reads a VDF file and returns the parsed data
static func read_vdf(path: String) -> Dictionary:
	var result := {}
	var data := FSM.read_file_bytes(path)
	if data.is_empty():
		return result
	
	# Use a mutable position wrapper so recursive calls can advance the index.
	var pos_ref := {"pos": 0}
	result = _parse_object(data, pos_ref)
	return result

## Parses a VDF object starting at the current position in pos_ref.
## pos_ref is a Dictionary {"pos": int} so nested objects advance the same index.
static func _parse_object(data: PackedByteArray, pos_ref: Dictionary) -> Dictionary:
	var obj := {}
	
	while pos_ref.pos < data.size():
		var type_byte := data[pos_ref.pos]
		pos_ref.pos += 1
		
		# End of object markers
		if type_byte == TYPE_ENDOFOBJECT or type_byte == TYPE_ENDOFOBJECT_ALT:
			break
		
		# Read key name (null-terminated UTF-8 string)
		var key_bytes := PackedByteArray()
		while pos_ref.pos < data.size() and data[pos_ref.pos] != 0:
			key_bytes.append(data[pos_ref.pos])
			pos_ref.pos += 1
		pos_ref.pos += 1  # Skip null terminator
		var key := key_bytes.get_string_from_utf8()

		match type_byte:
			TYPE_STRING:
				# Read string value (null-terminated UTF-8)
				var value_bytes := PackedByteArray()
				while pos_ref.pos < data.size() and data[pos_ref.pos] != 0:
					value_bytes.append(data[pos_ref.pos])
					pos_ref.pos += 1
				pos_ref.pos += 1  # Skip null terminator
				obj[key] = value_bytes.get_string_from_utf8()
			
			TYPE_INT32:
				# Read 4-byte little-endian integer
				if pos_ref.pos + 4 <= data.size():
					var value := data.decode_s32(pos_ref.pos)
					pos_ref.pos += 4
					obj[key] = value
			
			TYPE_UINT64:
				# Read 8-byte little-endian unsigned integer
				if pos_ref.pos + 8 <= data.size():
					var value := data.decode_u64(pos_ref.pos)
					pos_ref.pos += 8
					obj[key] = value
			
			_:
				# TYPE_NONE and any unknown type mark the start of a nested object
				obj[key] = _parse_object(data, pos_ref)
	
	return obj

## Writes a VDF object to a file.
## Backs up any existing file first, then writes via a temp file + move so a
## crash mid-write can never leave shortcuts.vdf truncated.
static func write_vdf(path: String, data: Dictionary) -> bool:
	var buffer := PackedByteArray()
	_write_object(buffer, data)
	# Add final terminator byte
	buffer.append(TYPE_ENDOFOBJECT)

	# Ensure directory exists
	var dir_path := path.get_base_dir()
	if not FSM.dir_exists(dir_path):
		if not FSM.make_dir_recursive(dir_path):
			push_error("[SteamVDF] Failed to create directory: " + dir_path)
			return false

	# Back up the existing file so a bad write never means lost shortcuts
	if FSM.file_exists(path):
		if not FSM.copy_file(path, path + ".kyodai-bak"):
			push_error("[SteamVDF] Failed to back up " + path + "; aborting write")
			return false

	var tmp_path := path + ".kyodai-tmp"
	if not FSM.write_file_bytes(tmp_path, buffer):
		push_error("[SteamVDF] Failed to write temp file: " + tmp_path)
		return false

	# rename_absolute can't overwrite on Windows, and the backup above covers
	# the brief window where the target doesn't exist
	if FSM.file_exists(path) and not FSM.delete_file(path):
		push_error("[SteamVDF] Failed to replace file: " + path)
		FSM.delete_file(tmp_path)
		return false
	if not FSM.move(tmp_path, path):
		push_error("[SteamVDF] Failed to move temp file into place: " + path)
		FSM.delete_file(tmp_path)
		return false

	return true

## Writes an object to the buffer
static func _write_object(buffer: PackedByteArray, obj: Dictionary) -> void:
	for key in obj.keys():
		var value = obj[key]
		
		if value is Dictionary:
			# Nested object - Steam uses TYPE_NONE (0x00) for object start
			buffer.append(TYPE_NONE)
			_append_string(buffer, key)
			_write_object(buffer, value)
			buffer.append(TYPE_ENDOFOBJECT)
		
		elif value is String:
			buffer.append(TYPE_STRING)
			_append_string(buffer, key)
			_append_string(buffer, value)
		
		elif value is int:
			# INT32 covers both freshly generated unsigned appids (up to
			# 4294967295) and parsed-back appids, which decode as negative
			# because the high bit is always set. Parsed values must keep
			# Steam's native 0x02 type on the round trip.
			if value >= -2147483648 and value <= 4294967295:
				buffer.append(TYPE_INT32)
				_append_string(buffer, key)
				var int_bytes := PackedByteArray()
				int_bytes.resize(4)
				int_bytes.encode_s32(0, value)
				buffer.append_array(int_bytes)
			else:
				# 64-bit unsigned int
				buffer.append(TYPE_UINT64)
				_append_string(buffer, key)
				var int_bytes := PackedByteArray()
				int_bytes.resize(8)
				int_bytes.encode_u64(0, value)
				buffer.append_array(int_bytes)

## Appends a null-terminated UTF-8 string to buffer
static func _append_string(buffer: PackedByteArray, s: String) -> void:
	buffer.append_array(s.to_utf8_buffer())
	buffer.append(0)

## Adds a game to the shortcuts dictionary
## Returns a Dictionary with "shortcuts" (the updated shortcuts dict) and "app_id" (the generated app ID)
static func add_shortcut(shortcuts: Dictionary, game_data: Dictionary) -> Dictionary:
	var new_shortcuts := shortcuts.duplicate(true)
	
	if not new_shortcuts.has("shortcuts"):
		new_shortcuts["shortcuts"] = {}
	
	var shortcuts_list = new_shortcuts["shortcuts"]
	
	# Append after the highest existing index so deletions never cause
	# gap-filling that reorders the user's shortcuts
	var next_index := 0
	for key in shortcuts_list.keys():
		next_index = maxi(next_index, int(key) + 1)

	# Generate AppID from the exe path (without quotes) + app name
	# Formula: crc32("exe" + app_name) | 0x80000000
	var exe_path := _extract_exe_path(game_data.get("exe", ""))
	var app_name: String = game_data.get("name", "Unknown")
	
	var result := generate_app_id(exe_path, app_name)
	var _app_id_64: int = result.app_id_64  # 64-bit for shortcuts.vdf
	var app_id_32: int = result.app_id_32  # 32-bit for grid files
	
	# Create shortcut entry with 32-bit appid (Steam expects INT32, not UINT64)
	var entry := {
		"appid": app_id_32,  # Use 32-bit here, Steam stores it as INT32
		"AppName": game_data.get("name", "Unknown"),
		"Exe": game_data.get("exe", ""),
		"StartDir": game_data.get("start_dir", ""),
		"icon": game_data.get("icon", ""),
		"ShortcutPath": "",
		"LaunchOptions": game_data.get("launch_options", ""),
		"IsHidden": 0,
		"AllowDesktopConfig": 1,
		"AllowOverlay": 1,
		"OpenVR": 0,
		"Devkit": 0,
		"DevkitGameID": "",
		"DevkitOverrideAppID": 0,
		"LastPlayTime": game_data.get("last_play_time", 0),
		"FlatpakAppID": "",
		"tags": {}
	}
	
	shortcuts_list[str(next_index)] = entry
	
	return {
		"shortcuts": new_shortcuts,
		"app_id": app_id_32  # Return 32-bit for grid artwork
	}

## Extracts just the exe path from a full command line (first quoted string,
## without quotes). Launch arguments are stored in the Exe field but must not
## feed the appid CRC.
static func _extract_exe_path(full_command: String) -> String:
	if full_command.begins_with("\""):
		var second_quote := full_command.find("\"", 1)
		if second_quote > 0:
			return full_command.substr(1, second_quote - 1)
	return full_command

## Generates unique AppIDs for a non-Steam game
## Returns both 64-bit (for shortcuts.vdf) and 32-bit (for grid files)
## Formula: 
##   32-bit: crc32(exe + name) | 0x80000000
##   64-bit: (32-bit << 32) | 0x02000000
static func generate_app_id(exe_path: String, app_name: String) -> Dictionary:
	# Steam wraps exe path in quotes for the CRC calculation
	var key := '"' + exe_path + '"' + app_name
	
	var crc := _crc32(key)
	# Mask to ensure unsigned 32-bit
	var app_id_32: int = ((crc & 0xFFFFFFFF) | 0x80000000) & 0xFFFFFFFF
	
	# Construct 64-bit appid using PackedByteArray to avoid signed overflow
	# Steam stores: Low 32 bits = app_id_32, High 32 bits = 0x02000000
	# This means: app_id_64 = (0x02000000 << 32) | app_id_32
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_u32(0, app_id_32)  # Low 32 bits at offset 0
	bytes.encode_u32(4, 0x02000000)  # High 32 bits at offset 4
	
	# Decode as unsigned 64-bit int (little endian)
	var app_id_64: int = bytes.decode_u64(0)
	
	return {
		"app_id_32": app_id_32,
		"app_id_64": app_id_64
	}

## Debug function to calculate AppID
static func debug_calculate_app_ids(full_command: String, app_name: String) -> void:
	# Extract exe path from full command (first quoted string, without quotes)
	var exe_path := _extract_exe_path(full_command)
	
	# Calculate AppIDs
	var _result := generate_app_id(exe_path, app_name)

## CRC32 implementation using reversed polynomial (standard CRC32)
## Standard CRC32: crc = (CRC32(exe + name) \u0026 0xFFFFFFFF) | 0x80000000
static func _crc32(s: String) -> int:
	var table: Array[int] = []
	var polynomial: int = 0xEDB88320  # Standard reversed CRC32 polynomial
	
	# Build CRC table
	for i in range(256):
		var crc_value: int = i
		for _j in range(8):
			if crc_value & 1:
				crc_value = ((crc_value >> 1) ^ polynomial) & 0xFFFFFFFF
			else:
				crc_value = (crc_value >> 1) & 0xFFFFFFFF
		table.append(crc_value)
	
	# Calculate CRC32 on UTF-8 bytes
	var crc: int = 0xFFFFFFFF
	var bytes := s.to_utf8_buffer()
	for byte in bytes:
		crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	
	return crc ^ 0xFFFFFFFF

## Lists Steam account IDs (userdata subfolders), excluding the shared
## "0" and "ac" folders. Order matches the previous first-found behavior.
static func _get_steam_user_ids(steam_path: String) -> Array[String]:
	var ids: Array[String] = []
	var userdata_path := steam_path.path_join("userdata")
	if FSM.dir_exists(userdata_path):
		for folder in FSM.list_dir(userdata_path):
			if FSM.is_dir(userdata_path.path_join(folder)) and folder != "0" and folder != "ac":
				ids.append(folder)
	return ids

## Gets the path to shortcuts.vdf for a given Steam installation
static func get_shortcuts_vdf_path(steam_path: String, user_id: String = "") -> String:
	if user_id.is_empty():
		var ids := _get_steam_user_ids(steam_path)
		if not ids.is_empty():
			user_id = ids[0]

	if not user_id.is_empty():
		return steam_path.path_join("userdata").path_join(user_id).path_join("config").path_join("shortcuts.vdf")

	return ""

## Validates that a path points to a valid Steam installation
static func is_valid_steam_path(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Check for steam.exe on Windows
	if FSM.file_exists(path.path_join("steam.exe")):
		return true
	
	# Check for steam executable on Linux
	if FSM.file_exists(path.path_join("steam")):
		return true
	
	# Check for userdata folder (exists on both platforms)
	if FSM.dir_exists(path.path_join("userdata")):
		return true
	
	return false

## Gets the path to Steam's grid folder for artwork
static func get_steam_grid_path(steam_path: String, user_id: String = "") -> String:
	if user_id.is_empty():
		var ids := _get_steam_user_ids(steam_path)
		if not ids.is_empty():
			user_id = ids[0]

	if not user_id.is_empty():
		return steam_path.path_join("userdata").path_join(user_id).path_join("config").path_join("grid")

	return ""

## Checks whether the Steam client is currently running (its in-memory
## shortcuts.vdf copy will clobber ours on exit, so we warn about it)
static func _is_steam_running() -> bool:
	var output: Array = []
	if OS.get_name() == "Windows":
		OS.execute("tasklist", ["/FI", "IMAGENAME eq steam.exe", "/NH"], output, true)
		return output.size() > 0 and String(output[0]).to_lower().contains("steam.exe")
	else:
		return OS.execute("pgrep", ["-x", "steam"], output, true) == 0

## Copies cover art to Steam's grid folder
static func copy_artwork_to_steam(steam_path: String, app_id: int, cover_path: String, user_id: String = "") -> bool:
	# Strip any URL query parameters
	var query_index := cover_path.find("?")
	if query_index != -1:
		cover_path = cover_path.substr(0, query_index)

	if cover_path.is_empty() or not FSM.file_exists(cover_path):
		push_warning("[SteamVDF] Cover path not found: " + cover_path)
		return false

	var grid_path := get_steam_grid_path(steam_path, user_id)
	if grid_path.is_empty():
		push_warning("[SteamVDF] Could not find Steam grid folder")
		return false
	
	# Ensure grid directory exists
	if not FSM.dir_exists(grid_path):
		if not FSM.make_dir_recursive(grid_path):
			push_error("[SteamVDF] Failed to create grid directory: " + grid_path)
			return false
	
	var app_id_str := str(app_id)
	
	# Read file bytes and detect format
	var bytes := FSM.read_file_bytes(cover_path)
	if bytes.is_empty():
		push_warning("[SteamVDF] Failed to read file: " + cover_path)
		return false
	
	# Load image from buffer
	var image := Image.new()
	var error: int = ERR_INVALID_DATA
	
	# Try to detect format from magic bytes and load accordingly
	if bytes.size() >= 8:
		var magic := bytes.slice(0, 8)
		# PNG magic: 89 50 4E 47 0D 0A 1A 0A
		if magic[0] == 0x89 and magic[1] == 0x50 and magic[2] == 0x4E and magic[3] == 0x47:
			error = image.load_png_from_buffer(bytes)
		# JPEG magic: FF D8 FF
		elif magic[0] == 0xFF and magic[1] == 0xD8 and magic[2] == 0xFF:
			error = image.load_jpg_from_buffer(bytes)
		# WebP magic: 52 49 46 46 ?? ?? ?? ?? 57 45 42 50
		elif magic[0] == 0x52 and magic[1] == 0x49 and magic[2] == 0x46 and magic[3] == 0x46:
			error = image.load_webp_from_buffer(bytes)
		else:
			# Try generic load
			error = image.load(cover_path)
	
	if error != OK:
		push_warning("[SteamVDF] Failed to load image from buffer: " + cover_path + " (error: " + str(error) + ")")
		return false
	
	# Resize to Steam's expected grid dimensions (600x900)
	var grid_image := image.duplicate()
	grid_image.resize(600, 900, Image.INTERPOLATE_LANCZOS)
	
	# Save as grid cover - Steam expects {appid}p.png (p = portrait/grid)
	var grid_cover_path := grid_path.path_join(app_id_str + "p.png")
	error = grid_image.save_png(grid_cover_path)
	if error != OK:
		push_warning("[SteamVDF] Failed to save grid cover: " + grid_cover_path)
		return false
	
	# Save horizontal library banner using the same source image.
	# Steam expects {appid}.png at 460x215. Center-crop to avoid stretching.
	var banner_image := image.duplicate()
	var banner_size := Vector2i(460, 215)
	var target_aspect := float(banner_size.x) / float(banner_size.y)
	var src_aspect := float(banner_image.get_width()) / float(banner_image.get_height())

	var crop_width: int
	var crop_height: int
	if src_aspect > target_aspect:
		# Source is wider than target; crop left/right to match target aspect
		crop_height = banner_image.get_height()
		crop_width = int(round(float(crop_height) * target_aspect))
	else:
		# Source is taller than target; crop top/bottom to match target aspect
		crop_width = banner_image.get_width()
		crop_height = int(round(float(crop_width) / target_aspect))

	var crop_x: int = (banner_image.get_width() - crop_width) / 2
	var crop_y: int = (banner_image.get_height() - crop_height) / 2

	# Center-crop by blitting the region to a new image (Image.crop only crops from top-left).
	var cropped := Image.create(crop_width, crop_height, false, banner_image.get_format())
	var src_rect := Rect2i(Vector2i(crop_x, crop_y), Vector2i(crop_width, crop_height))
	cropped.blit_rect(banner_image, src_rect, Vector2i.ZERO)

	cropped.resize(banner_size.x, banner_size.y, Image.INTERPOLATE_LANCZOS)
	var banner_path := grid_path.path_join(app_id_str + ".png")
	error = cropped.save_png(banner_path)
	if error != OK:
		push_warning("[SteamVDF] Failed to save banner: " + banner_path)
		return false
	
	return true

## Shared helper: add a downloaded game to Steam as a non-Steam game.
## This method is used by HomeView and LibraryView so the logic lives in one place.
static func add_game(game: GameResource) -> void:
	var steam_folder_setting = DataManager.get_setting("steam_folder")
	if not steam_folder_setting or steam_folder_setting.value.is_empty():
		SystemManager.notifications.show_notification("Steam folder not configured", SystemManager.notifications.Type.WARNING)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
		return
	
	var steam_path = steam_folder_setting.value
	if not is_valid_steam_path(steam_path):
		SystemManager.notifications.show_notification("Invalid Steam installation folder", SystemManager.notifications.Type.WARNING)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
		return
	
	SystemManager.notifications.show_notification("Adding " + game.title + " to Steam...", SystemManager.notifications.Type.INFO)
	
	var launch_intent = LaunchManager.create_launch_intent(game)
	if not launch_intent:
		SystemManager.notifications.show_notification("Failed to create launch intent for " + game.title, SystemManager.notifications.Type.ERROR)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
		return
	
	var exe_path = LaunchManager.get_emulator_install_path(launch_intent.emulator_id)
	if exe_path.is_empty():
		SystemManager.notifications.show_notification("Could not find emulator executable for " + game.title, SystemManager.notifications.Type.ERROR)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
		return
	
	exe_path = SystemManager.filesystem.resolve_native_path(exe_path)
	var rom_path: String = SystemManager.filesystem.resolve_native_path(launch_intent.rom_path)
	
	var full_command: String = "\"" + exe_path + "\""
	
	if not launch_intent.launch_args.is_empty():
		for i in range(launch_intent.launch_args.size()):
			var arg: String = launch_intent.launch_args[i]
			if i == 0 and (arg == exe_path or arg.ends_with(exe_path.get_file())):
				continue
			if arg == rom_path or arg.replace("/", "\\") == rom_path:
				arg = "\"" + arg + "\""
			full_command += " " + arg
	
	var working_dir: String = launch_intent.working_directory
	if working_dir.is_empty():
		working_dir = exe_path.get_base_dir()
	working_dir = SystemManager.filesystem.resolve_native_path(working_dir)
	
	var game_data := {
		"name": game.title,
		"exe": full_command,
		"start_dir": working_dir,
		"icon": "",
		"launch_options": "",
		"last_play_time": 0,
		"cover_path": ""
	}

	# Resolve cover art BEFORE touching shortcuts.vdf. The cache filename comes
	# from the cover URL's real extension (not always .jpg), and if the LRU
	# cache evicted the file we force a re-pull so artwork always lands.
	if not game.cover_url.is_empty() and game.cover_url.begins_with("http"):
		var cache_path: String = DataManager.get_cached_image_path(game.cover_url)
		if FSM.file_exists(cache_path):
			game_data.cover_path = FSM.resolve_path(cache_path, {"format": FSM.PathFormat.ABSOLUTE})
			_write_game_to_steam(game, steam_path, game_data)
		else:
			var download_notification: int = SystemManager.notifications.show_notification(
				"Downloading cover for " + game.title + "...",
				SystemManager.notifications.Type.INFO,
				null, 0.0, Callable(), Callable(), true, true)
			DataManager.cover.download_cover(game.cover_url, func(ok: bool):
				SystemManager.notifications.dismiss_notification(download_notification)
				if ok and FSM.file_exists(cache_path):
					game_data.cover_path = FSM.resolve_path(cache_path, {"format": FSM.PathFormat.ABSOLUTE})
				else:
					push_warning("[SteamVDF] Cover download failed for " + game.title + "; adding shortcut without artwork")
				_write_game_to_steam(game, steam_path, game_data)
			, true)
	elif not game.cover_path.is_empty():
		var cover_path: String = game.cover_path
		var query_index := cover_path.find("?")
		if query_index != -1:
			cover_path = cover_path.substr(0, query_index)
		if FSM.file_exists(cover_path):
			game_data.cover_path = FSM.resolve_path(cover_path, {"format": FSM.PathFormat.ABSOLUTE})
		_write_game_to_steam(game, steam_path, game_data)
	else:
		_write_game_to_steam(game, steam_path, game_data)

## Writes the shortcut entry and artwork after cover resolution. Runs on the
## main thread (directly, or from the cover download callback).
static func _write_game_to_steam(game: GameResource, steam_path: String, game_data: Dictionary) -> void:
	var user_ids := _get_steam_user_ids(steam_path)
	if user_ids.is_empty():
		SystemManager.notifications.show_notification("Could not find a Steam user folder", SystemManager.notifications.Type.ERROR)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
		return
	var user_id := user_ids[0]
	var shortcuts_path := get_shortcuts_vdf_path(steam_path, user_id)

	var shortcuts := {}
	var existing_count := 0
	if FSM.file_exists(shortcuts_path) and FSM.get_file_size(shortcuts_path) > 0:
		shortcuts = read_vdf(shortcuts_path)
		# A file we could not parse must never be rewritten as empty - that
		# is how existing shortcuts get wiped
		if not shortcuts.has("shortcuts"):
			push_error("[SteamVDF] Parse produced no shortcuts key for: " + shortcuts_path)
			SystemManager.notifications.show_notification("Could not read Steam shortcuts file - aborted to avoid wiping it", SystemManager.notifications.Type.ERROR)
			if SystemManager.audio:
				SystemManager.audio.play_sfx("error")
			return
		existing_count = shortcuts["shortcuts"].size()
	print("[SteamVDF] Existing shortcuts found: ", existing_count)

	if not shortcuts.has("shortcuts"):
		shortcuts["shortcuts"] = {}

	var cover_path: String = game_data.get("cover_path", "")

	var shortcuts_list = shortcuts["shortcuts"]
	for key in shortcuts_list.keys():
		var entry = shortcuts_list[key]
		if entry is Dictionary and entry.get("AppName", "") == game.title:
			# Already present - but the shortcut existing says nothing about
			# the artwork, so refresh it if we have a cover
			var art_note := ""
			if not cover_path.is_empty():
				var existing_app_id: int = generate_app_id(_extract_exe_path(game_data.exe), game.title).app_id_32
				if copy_artwork_to_steam(steam_path, existing_app_id, cover_path, user_id):
					art_note = " (artwork refreshed)"
				else:
					art_note = " (artwork failed)"
			SystemManager.notifications.show_notification(game.title + " is already in Steam" + art_note, SystemManager.notifications.Type.WARNING)
			if SystemManager.audio:
				SystemManager.audio.play_sfx("error")
			return

	var result = add_shortcut(shortcuts, game_data)
	shortcuts = result.shortcuts
	var app_id = result.app_id

	if not write_vdf(shortcuts_path, shortcuts):
		SystemManager.notifications.show_notification("Failed to add " + game.title + " to Steam", SystemManager.notifications.Type.ERROR)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
		return

	var artwork_ok := true
	if not cover_path.is_empty():
		artwork_ok = copy_artwork_to_steam(steam_path, app_id, cover_path, user_id)

	var notes: Array[String] = []
	if user_ids.size() > 1:
		notes.append("used Steam account " + user_id + " (multiple accounts found)")
	if _is_steam_running():
		notes.append("Steam is running - restart it for changes to appear")
	else:
		notes.append("restart Steam to see it")

	if artwork_ok:
		SystemManager.notifications.show_notification(game.title + " added to Steam! (" + "; ".join(notes) + ")", SystemManager.notifications.Type.SUCCESS)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("success")
	else:
		SystemManager.notifications.show_notification(game.title + " added to Steam, but artwork failed - re-run Add to Steam once the cover is available", SystemManager.notifications.Type.ERROR)
		if SystemManager.audio:
			SystemManager.audio.play_sfx("error")
