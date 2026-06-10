## Steam VDF Binary Format Writer/Reader
## Handles Steam's shortcuts.vdf file format for adding non-Steam games

class_name SteamVDFWriter

# VDF Type markers
const TYPE_NONE := 0x00
const TYPE_STRING := 0x01
const TYPE_INT32 := 0x02
const TYPE_FLOAT32 := 0x03
const TYPE_POINTER := 0x04
const TYPE_WIDESTRING := 0x05
const TYPE_COLOR := 0x06
const TYPE_UINT64 := 0x07
const TYPE_ENDOFOBJECT := 0x08
const TYPE_INT64 := 0x0A
const TYPE_ENDOFOBJECT_ALT := 0x0B

## Reads a VDF file and returns the parsed data
static func read_vdf(path: String) -> Dictionary:
	var result := {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return result
	
	var data := file.get_buffer(file.get_length())
	file.close()
	
	var pos := 0
	result = _parse_object(data, pos)
	return result

## Parses a VDF object starting at position
static func _parse_object(data: PackedByteArray, pos: int) -> Dictionary:
	var obj := {}
	
	while pos < data.size():
		if pos >= data.size():
			break
			
		var type_byte := data[pos]
		pos += 1
		
		# End of object markers
		if type_byte == TYPE_ENDOFOBJECT or type_byte == TYPE_ENDOFOBJECT_ALT:
			break
		
		# Read key name (null-terminated string)
		var key := ""
		while pos < data.size() and data[pos] != 0:
			key += char(data[pos])
			pos += 1
		pos += 1  # Skip null terminator
		
		match type_byte:
			TYPE_STRING:
				# Read string value (null-terminated)
				var value := ""
				while pos < data.size() and data[pos] != 0:
					value += char(data[pos])
					pos += 1
				pos += 1  # Skip null terminator
				obj[key] = value
			
			TYPE_INT32:
				# Read 4-byte little-endian integer
				if pos + 4 <= data.size():
					var value := data.decode_s32(pos)
					pos += 4
					obj[key] = value
			
			TYPE_UINT64:
				# Read 8-byte little-endian unsigned integer
				if pos + 8 <= data.size():
					var value := data.decode_u64(pos)
					pos += 8
					obj[key] = value
			
			TYPE_NONE:
				# This is actually the start of a nested object in shortcuts.vdf
				# The key has already been read, now parse the nested object
				obj[key] = _parse_object(data, pos)
			
			_:
				# For any other type (including TYPE_ENDOFOBJECT), treat as nested object
				# This handles the Steam shortcuts.vdf format
				obj[key] = _parse_object(data, pos)
	
	return obj

## Writes a VDF object to a file
static func write_vdf(path: String, data: Dictionary) -> bool:
	var buffer := PackedByteArray()
	_write_object(buffer, data)
	# Add final terminator byte
	buffer.append(TYPE_ENDOFOBJECT)
	
	# Ensure directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err = DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			push_error("[SteamVDF] Failed to create directory: " + dir_path)
			return false
	

	
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("[SteamVDF] Failed to open file for writing: " + path)
		return false
	
	file.store_buffer(buffer)
	var error = file.get_error()
	file.close()
	
	if error != OK:
		push_error("[SteamVDF] Failed to write file: " + str(error))
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
			if value >= 0 and value <= 4294967295:
				# 32-bit signed int
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

## Appends a null-terminated string to buffer
static func _append_string(buffer: PackedByteArray, s: String) -> void:
	for i in range(s.length()):
		buffer.append(s.unicode_at(i))
	buffer.append(0)

## Adds a game to the shortcuts dictionary
## Returns a Dictionary with "shortcuts" (the updated shortcuts dict) and "app_id" (the generated app ID)
static func add_shortcut(shortcuts: Dictionary, game_data: Dictionary) -> Dictionary:
	var new_shortcuts := shortcuts.duplicate(true)
	
	if not new_shortcuts.has("shortcuts"):
		new_shortcuts["shortcuts"] = {}
	
	var shortcuts_list = new_shortcuts["shortcuts"]
	
	# Find next available index
	var next_index := 0
	while shortcuts_list.has(str(next_index)):
		next_index += 1
	
	# Generate AppID from the exe path (without quotes) + app name
	# Formula: crc32("exe" + app_name) | 0x80000000
	# Extract just the exe path from the full command (first quoted string, without quotes)
	var full_exe: String = game_data.get("exe", "")
	var exe_path: String = ""
	if full_exe.begins_with("\""):
		var second_quote := full_exe.find("\"", 1)
		if second_quote > 0:
			exe_path = full_exe.substr(1, second_quote - 1)  # Extract without quotes
	else:
		exe_path = full_exe
	
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
	var exe_path: String = ""
	if full_command.begins_with("\""):
		var second_quote := full_command.find("\"", 1)
		if second_quote > 0:
			exe_path = full_command.substr(1, second_quote - 1)  # Without quotes
	else:
		exe_path = full_command
	
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

## Gets the path to shortcuts.vdf for a given Steam installation
static func get_shortcuts_vdf_path(steam_path: String, user_id: String = "") -> String:
	if user_id.is_empty():
		# Try to find the first user ID
		var userdata_path := steam_path.path_join("userdata")
		if DirAccess.dir_exists_absolute(userdata_path):
			var dir := DirAccess.open(userdata_path)
			if dir:
				dir.list_dir_begin()
				var folder := dir.get_next()
				while folder != "":
					if dir.current_is_dir() and folder != "0" and folder != "ac":
						user_id = folder
						break
					folder = dir.get_next()
					dir.list_dir_end()
	
	if not user_id.is_empty():
		return steam_path.path_join("userdata").path_join(user_id).path_join("config").path_join("shortcuts.vdf")
	
	return ""

## Validates that a path points to a valid Steam installation
static func is_valid_steam_path(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Check for steam.exe on Windows
	if FileAccess.file_exists(path.path_join("steam.exe")):
		return true
	
	# Check for steam executable on Linux
	if FileAccess.file_exists(path.path_join("steam")):
		return true
	
	# Check for userdata folder (exists on both platforms)
	if DirAccess.dir_exists_absolute(path.path_join("userdata")):
		return true
	
	return false

## Gets the path to Steam's grid folder for artwork
static func get_steam_grid_path(steam_path: String, user_id: String = "") -> String:
	if user_id.is_empty():
		var userdata_path := steam_path.path_join("userdata")
		if DirAccess.dir_exists_absolute(userdata_path):
			var dir := DirAccess.open(userdata_path)
			if dir:
				dir.list_dir_begin()
				var folder := dir.get_next()
				while folder != "":
					if dir.current_is_dir() and folder != "0" and folder != "ac":
						user_id = folder
						break
					folder = dir.get_next()
					dir.list_dir_end()
	
	if not user_id.is_empty():
		return steam_path.path_join("userdata").path_join(user_id).path_join("config").path_join("grid")
	
	return ""

## Copies cover art to Steam's grid folder
static func copy_artwork_to_steam(steam_path: String, app_id: int, cover_path: String) -> bool:
	# Strip any URL query parameters
	var query_index := cover_path.find("?")
	if query_index != -1:
		cover_path = cover_path.substr(0, query_index)
	
	if cover_path.is_empty() or not FileAccess.file_exists(cover_path):
		push_warning("[SteamVDF] Cover path not found: " + cover_path)
		return false
	
	var grid_path := get_steam_grid_path(steam_path)
	if grid_path.is_empty():
		push_warning("[SteamVDF] Could not find Steam grid folder")
		return false
	
	# Ensure grid directory exists
	if not DirAccess.dir_exists_absolute(grid_path):
		var err := DirAccess.make_dir_recursive_absolute(grid_path)
		if err != OK:
			push_error("[SteamVDF] Failed to create grid directory: " + grid_path)
			return false
	
	var app_id_str := str(app_id)
	
	# Read file bytes and detect format
	var file := FileAccess.open(cover_path, FileAccess.READ)
	if not file:
		push_warning("[SteamVDF] Failed to open file: " + cover_path)
		return false
	
	var bytes := file.get_buffer(file.get_length())
	file.close()
	
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
	
	return true

## Shared helper: add a downloaded game to Steam as a non-Steam game.
## This method is used by HomeView and LibraryView so the logic lives in one place.
static func add_game(game: GameResource) -> void:
	var steam_folder_setting = SettingsManager.get_setting("steam_folder")
	if not steam_folder_setting or steam_folder_setting.value.is_empty():
		NotificationManager.show_notification("Steam folder not configured", NotificationManager.Type.WARNING)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	var steam_path = steam_folder_setting.value
	if not is_valid_steam_path(steam_path):
		NotificationManager.show_notification("Invalid Steam installation folder", NotificationManager.Type.WARNING)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	NotificationManager.show_notification("Adding " + game.title + " to Steam...", NotificationManager.Type.INFO)
	
	var launch_intent = LaunchManager.create_launch_intent(game)
	if not launch_intent:
		NotificationManager.show_notification("Failed to create launch intent for " + game.title, NotificationManager.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	var exe_path = LaunchManager.get_emulator_install_path(launch_intent.emulator_id)
	if exe_path.is_empty():
		NotificationManager.show_notification("Could not find emulator executable for " + game.title, NotificationManager.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	exe_path = FileSystemManager.resolve_native_path(exe_path)
	var rom_path: String = FileSystemManager.resolve_native_path(launch_intent.rom_path)
	
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
	working_dir = FileSystemManager.resolve_native_path(working_dir)
	
	var cover_art_path: String = ""
	const CACHE_FOLDER = "user://cache/covers/"
	
	if not game.cover_url.is_empty() and game.cover_url.begins_with("http"):
		cover_art_path = FileSystemManager.join_paths(CACHE_FOLDER, game.cover_url.md5_text() + ".jpg")
		cover_art_path = FileSystemManager.resolve_path(cover_art_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	elif not game.cover_path.is_empty():
		cover_art_path = game.cover_path
		if cover_art_path.find("?") != -1:
			cover_art_path = cover_art_path.substr(0, cover_art_path.find("?"))
		if FileAccess.file_exists(cover_art_path):
			cover_art_path = FileSystemManager.resolve_path(cover_art_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	
	var game_data := {
		"name": game.title,
		"exe": full_command,
		"start_dir": working_dir,
		"icon": "",
		"launch_options": "",
		"last_play_time": 0,
		"cover_path": cover_art_path
	}
	
	var shortcuts_path = get_shortcuts_vdf_path(steam_path)
	if shortcuts_path.is_empty():
		NotificationManager.show_notification("Could not find Steam shortcuts file", NotificationManager.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	var shortcuts := {}
	if FileAccess.file_exists(shortcuts_path):
		shortcuts = read_vdf(shortcuts_path)
	
	if not shortcuts.has("shortcuts"):
		shortcuts["shortcuts"] = {}
	
	var shortcuts_list = shortcuts["shortcuts"]
	for key in shortcuts_list.keys():
		var entry = shortcuts_list[key]
		if entry is Dictionary and entry.get("AppName", "") == game.title:
			NotificationManager.show_notification(game.title + " is already in Steam", NotificationManager.Type.WARNING)
			if AudioManager:
				AudioManager.play_sfx("error")
			return
	
	debug_calculate_app_ids(game_data.exe, game.title)
	
	var result = add_shortcut(shortcuts, game_data)
	shortcuts = result.shortcuts
	var app_id = result.app_id
	
	if write_vdf(shortcuts_path, shortcuts):
		var cover_path = game_data.get("cover_path", "")
		if not cover_path.is_empty():
			copy_artwork_to_steam(steam_path, app_id, cover_path)
		
		NotificationManager.show_notification(game.title + " added to Steam! Restart Steam to see it.", NotificationManager.Type.SUCCESS)
		if AudioManager:
			AudioManager.play_sfx("success")
	else:
		NotificationManager.show_notification("Failed to add " + game.title + " to Steam", NotificationManager.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
