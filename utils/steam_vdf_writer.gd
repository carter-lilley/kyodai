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
	
	print("[SteamVDF] Writing VDF file to: " + path)
	print("[SteamVDF] Buffer size: " + str(buffer.size()) + " bytes")
	
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
	
	print("[SteamVDF] Successfully wrote VDF file")
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
	
	# Generate AppID from exe path and name
	var exe_path = game_data.get("exe", "")
	var app_name = game_data.get("name", "Unknown")
	var app_id := generate_app_id(exe_path, app_name)
	
	# Create shortcut entry
	var entry := {
		"AppName": app_name,
		"Exe": exe_path,
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
		"app_id": app_id
	}

## Generates a unique AppID for a non-Steam game
## Steam uses CRC32 of "URL" + Exe path + game name (lowercase)
static func generate_app_id(exe_path: String, app_name: String) -> int:
	var input := "URL" + exe_path + app_name
	input = input.to_lower()
	
	var crc := _crc32(input)
	var app_id: int = (crc & 0xFFFFFFFF) | 0x10000000
	return app_id

## CRC32 implementation
static func _crc32(s: String) -> int:
	var table: Array[int] = []
	var polynomial: int = 0xEDB88320
	
	for i in range(256):
		var crc: int = i
		for _j in range(8):
			if crc & 1:
				crc = (crc >> 1) ^ polynomial
			else:
				crc = crc >> 1
		table.append(crc)
	
	var crc: int = 0xFFFFFFFF
	for i in range(s.length()):
		var byte: int = s.unicode_at(i) & 0xFF
		crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	
	return crc ^ 0xFFFFFFFF

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
	
	# Load and save the image
	var image := Image.new()
	var error := image.load(cover_path)
	if error != OK:
		push_warning("[SteamVDF] Failed to load image: " + cover_path)
		return false
	
	# Save as grid cover (600x900) - {appid}.jpg
	var grid_cover_path := grid_path.path_join(app_id_str + ".jpg")
	error = image.save_jpg(grid_cover_path, 0.9)
	if error == OK:
		print("[SteamVDF] Saved grid cover: " + grid_cover_path)
	else:
		push_warning("[SteamVDF] Failed to save grid cover: " + grid_cover_path)
		return false
	
	return true

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
