# FileSystemManager - Unified file system operations
# Uses MANAGE_EXTERNAL_STORAGE on Android for direct filesystem access
# DocumentsContract used for /Android/data/ and /Android/obb/ paths

extends Manager

## Path format options for resolve_path()
enum PathFormat {
	DEFAULT,      ## Resolve placeholders, normalize slashes
	ABSOLUTE,     ## Full absolute path (globalize user://)
	NORMALIZED,   ## Just clean slashes and ./ ../
	PLATFORM      ## Platform-appropriate separators (\ on Windows, / elsewhere)
}

## Normalizes a path by removing redundant components like "." and ".."
## and ensuring consistent separators.
## Also converts content:// URIs to real paths.
static func normalize_path(path: String) -> String:
	if path.is_empty():
		return path
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Preserve Godot virtual paths - don't normalize slashes in user:// or res://
	if path.begins_with("user://") or path.begins_with("res://"):
		# Only resolve . and .. after the protocol prefix
		var prefix = ""
		var rest = path
		if path.begins_with("user://"):
			prefix = "user://"
			rest = path.substr(7)
		elif path.begins_with("res://"):
			prefix = "res://"
			rest = path.substr(6)
		
		# Normalize the rest of the path
		var has_leading_slash = rest.begins_with("/")
		var segments = rest.split("/", false)
		var resolved: Array[String] = []
		for segment in segments:
			if segment == ".":
				continue
			elif segment == "..":
				if resolved.size() > 0:
					resolved.pop_back()
			else:
				resolved.append(segment)
		
		var result = "/".join(resolved)
		if has_leading_slash:
			result = "/" + result
		if result.length() > 1 and result.ends_with("/"):
			result = result.substr(0, result.length() - 1)
		
		return prefix + result
	
	# Detect leading slash (absolute path)
	var has_leading_slash = path.begins_with("/")
	
	# Split into segments and resolve . and ..
	var segments = path.split("/", false)
	var resolved: Array[String] = []
	for segment in segments:
		if segment == ".":
			continue
		elif segment == "..":
			if resolved.size() > 0:
				resolved.pop_back()
		else:
			resolved.append(segment)
	
	# Rejoin segments
	var result = "/".join(resolved)
	
	# Restore leading slash for absolute paths
	if has_leading_slash:
		result = "/" + result
	
	# Remove trailing "/" (except for root "/")
	if result.length() > 1 and result.ends_with("/"):
		result = result.substr(0, result.length() - 1)
	
	return result

## Joins path components safely, handling trailing/leading slashes
## Supports up to 6 path segments. For more, chain calls.
static func join_paths(path1: String, path2: String, path3: String = "", path4: String = "", path5: String = "", path6: String = "") -> String:
	var result = _join_paths_2(path1, path2)
	if path3 != "":
		result = _join_paths_2(result, path3)
	if path4 != "":
		result = _join_paths_2(result, path4)
	if path5 != "":
		result = _join_paths_2(result, path5)
	if path6 != "":
		result = _join_paths_2(result, path6)
	return result

## Internal: Joins two path components
static func _join_paths_2(a: String, b: String) -> String:
	if a.is_empty():
		return b
	if b.is_empty():
		return a
	
	var result = a
	if not result.ends_with("/") and not result.ends_with("\\"):
		result += "/"
	if b.begins_with("/") or b.begins_with("\\"):
		b = b.substr(1)
	
	return result + b

## Universal path resolver - handles all path formats and transformations
##
## Options:
##   "base_dir": String        - REQUIRED for relative paths (errors if missing)
##   "placeholders": Dictionary - {"{key}": "value", ...} for custom placeholders
##   "format": PathFormat      - Output format (default: DEFAULT)
##   "platform": String        - Override platform for PLATFORM format
##
## Returns empty string on error (with push_error)
static func resolve_path(path: String, options: Dictionary = {}) -> String:
	if path.is_empty():
		return ""
	
	# Convert content:// URIs to real paths first
	var result = resolve_content_uri(path)
	var format = options.get("format", PathFormat.DEFAULT)
	
	# Step 1: Resolve placeholders
	var placeholders = options.get("placeholders", {})
	for key in placeholders:
		result = result.replace(key, str(placeholders[key]))
	
	# Step 2: Handle relative paths
	if not _is_absolute_path(result):
		var base_dir = options.get("base_dir", "")
		if base_dir.is_empty():
			push_error("[FileSystemManager] Relative path requires base_dir: " + path)
			return ""
		result = join_paths(base_dir, result)
	
	# Step 3: Apply format
	match format:
		PathFormat.DEFAULT:
			result = normalize_path(result)
		PathFormat.NORMALIZED:
			result = normalize_path(result)
		PathFormat.ABSOLUTE:
			result = ProjectSettings.globalize_path(normalize_path(result))
		PathFormat.PLATFORM:
			result = normalize_path(result)
			var platform = options.get("platform", "")
			if platform == "":
				if is_instance_valid(PlatformManager):
					platform = PlatformManager.get_platform_name()
				else:
					platform = OS.get_name().to_lower()
			if platform == "windows":
				result = result.replace("/", "\\")
			else:
				result = result.replace("\\", "/")
		_:
			result = normalize_path(result)
	
	return result

## Resolves a path to an absolute native path for external tools/processes
## Combines ABSOLUTE resolution with platform-specific slash conversion
## Windows: backslashes, Others: forward slashes
static func resolve_native_path(path: String) -> String:
	var resolved = resolve_path(path, {"format": PathFormat.ABSOLUTE})
	if is_instance_valid(PlatformManager):
		if PlatformManager.is_windows():
			resolved = resolved.replace("/", "\\")
	elif OS.get_name() == "Windows":
		resolved = resolved.replace("/", "\\")
	return resolved

## Resolves emulator paths with full wildcard support
## Handles {emulator_dir}, {app_data}, {games_dir}, and {core_name}
## This is the preferred method for resolving emulator-related paths
func resolve_emulator_path(path: String, emulator_id: String, platform_slug: String = "", format: PathFormat = PathFormat.DEFAULT) -> String:
	if path.is_empty():
		return ""
	
	var placeholders = {}
	
	# Resolve {emulator_dir}
	if is_instance_valid(LaunchManager):
		var emulator_dir = LaunchManager._get_emulator_directory(emulator_id)
		placeholders["{emulator_dir}"] = emulator_dir.rstrip("/")
		
		# Resolve {app_data}
		var app_data = LaunchManager.get_app_data_path(emulator_id)
		if app_data != "":
			placeholders["{app_data}"] = app_data.rstrip("/")
		
		# Resolve {core_name}
		if platform_slug != "":
			var core_name = LaunchManager.get_retroarch_core_name(platform_slug)
			if core_name != "":
				placeholders["{core_name}"] = core_name
	
	# Resolve {games_dir}
	if is_instance_valid(SettingsManager):
		var games_folder_setting = SettingsManager.get_setting("games_root_folder")
		var games_dir = games_folder_setting.value if games_folder_setting else "user://roms"
		placeholders["{games_dir}"] = games_dir.rstrip("/")
	
	return resolve_path(path, {
		"base_dir": placeholders.get("{emulator_dir}", ""),
		"placeholders": placeholders,
		"format": format
	})

## Checks if a path is absolute (not relative)
static func _is_absolute_path(path: String) -> bool:
	if path.is_empty():
		return false
	return path.begins_with("/") \
		or path.begins_with("user://") \
		or path.begins_with("res://") \
		or (path.length() > 1 and path[1] == ":")

## Gets the size of a file in bytes
## Returns -1 if file doesn't exist or size cannot be determined
static func get_file_size(path: String) -> int:
	if path.is_empty():
		return -1
	
	if not file_exists(path):
		return -1
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var size = file.get_length()
		file.close()
		return size
	
	return -1

## Converts a content:// URI (from Android file picker) to a real filesystem path.
## Uses the plugin to resolve the URI. Returns the original path if not a content URI.
static func resolve_content_uri(path: String) -> String:
	if not path.begins_with("content://"):
		return path
	
	if not is_android():
		return path
	
	var plugin = _get_plugin()
	if plugin == null:
		push_warning("[FileSystemManager] Plugin not available to resolve content URI: " + path)
		return path
	
	var real_path = plugin.call("resolveContentUriToRealPath", path)
	if real_path != "" and real_path != path:
		return real_path
	
	return path

## Gets the PackageChecker plugin singleton
static func _get_plugin():
	if Engine.has_singleton("PackageChecker"):
		return Engine.get_singleton("PackageChecker")
	return null

## Checks if running on Android platform
static func is_android() -> bool:
	return PlatformManager.is_android() if is_instance_valid(PlatformManager) else OS.get_name() == "Android"

## Checks if a path requires DocumentsContract on Android 11+
static func _is_restricted_android_path(path: String) -> bool:
	if not is_android():
		return false
	if path.is_empty():
		return false
	# Normalize to resolve any ".." segments before checking
	var normalized = normalize_path(path)
	return normalized.contains("/Android/data/") or normalized.contains("/Android/obb/")

## Delegates file_exists to plugin for restricted paths
static func _plugin_file_exists(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidFileExists", path)

## Delegates dir_exists to plugin for restricted paths (verifies it's actually a directory)
static func _plugin_dir_exists(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidDirExists", path)

## Delegates dir listing to plugin for restricted paths
static func _plugin_list_dir(path: String) -> Array[String]:
	var result: Array[String] = []
	var plugin = _get_plugin()
	if plugin == null:
		return result
	
	var json_str = plugin.call("androidListDir", path)
	if json_str.is_empty() or json_str == "[]":
		return result
	
	var json = JSON.new()
	var error = json.parse(json_str)
	if error == OK and json.data is Array:
		for item in json.data:
			result.append(str(item))
	
	return result

## Delegates file read to plugin for restricted paths
static func _plugin_read_file(path: String) -> PackedByteArray:
	var plugin = _get_plugin()
	if plugin == null:
		return PackedByteArray()
	
	var base64_data = plugin.call("androidReadFile", path)
	if base64_data.is_empty():
		return PackedByteArray()
	
	return Marshalls.base64_to_raw(base64_data)

## Delegates file write to plugin for restricted paths
static func _plugin_write_file(path: String, data: PackedByteArray) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	
	var base64_data = Marshalls.raw_to_base64(data)
	return plugin.call("androidWriteFile", path, base64_data)

## Delegates file delete to plugin for restricted paths
static func _plugin_delete_file(path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	return plugin.call("androidDeleteFile", path)

## Delegates get modified time to plugin for restricted paths
## Note: Android plugin returns milliseconds, Godot expects seconds
static func _plugin_get_modified_time(path: String) -> int:
	var plugin = _get_plugin()
	if plugin == null:
		return 0
	var ms = plugin.call("androidGetModifiedTime", path)
	return int(ms / 1000)

## Checks if a file exists
static func file_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return FileAccess.file_exists(path)
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_file_exists(path)
	
	# For real paths
	return FileAccess.file_exists(path)

## Checks if a directory exists
static func dir_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return DirAccess.dir_exists_absolute(path)
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_dir_exists(path)
	
	# For real paths
	return DirAccess.dir_exists_absolute(path)

## Creates a directory and all parent directories if they don't exist
static func make_dir_recursive(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		if DirAccess.dir_exists_absolute(path):
			return true
		return DirAccess.make_dir_recursive_absolute(path) == OK
	
	# For real paths
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK

## Deletes a directory and all its contents recursively
static func delete_dir_recursive(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return _delete_dir_recursive_internal(path)
	
	# For real paths
	return _delete_dir_recursive_internal(path)

static func _delete_dir_recursive_internal(path: String) -> bool:
	var dir = DirAccess.open(path)
	if dir == null:
		return false
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var item_path = join_paths(path, file_name)
			if dir.current_is_dir():
				_delete_dir_recursive_internal(item_path)
			else:
				DirAccess.remove_absolute(item_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	return DirAccess.remove_absolute(path) == OK

## Lists files in a directory
static func list_dir(path: String) -> Array[String]:
	var result: Array[String] = []
	
	if path.is_empty():
		return result
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_list_dir(path)
	
	var dir = DirAccess.open(path)
	if dir == null:
		return result
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			result.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	return result

## Renames a file or directory
static func rename(source_path: String, dest_name: String) -> bool:
	if source_path.is_empty() or dest_name.is_empty():
		return false
	
	var dest_path = join_paths(source_path.get_base_dir(), dest_name)
	return DirAccess.rename_absolute(source_path, dest_path) == OK

## Moves a file or directory to a new location
static func move(source_path: String, dest_path: String) -> bool:
	if source_path.is_empty() or dest_path.is_empty():
		return false
	
	# Ensure destination directory exists
	var dest_dir = dest_path.get_base_dir()
	if not dest_dir.is_empty() and not dir_exists(dest_dir):
		if not make_dir_recursive(dest_dir):
			return false
	
	return DirAccess.rename_absolute(source_path, dest_path) == OK

## Copies a file from source to destination
static func copy_file(source_path: String, dest_path: String) -> bool:
	if source_path.is_empty() or dest_path.is_empty():
		return false
	
	# Ensure destination directory exists
	var dest_dir = dest_path.get_base_dir()
	if not dest_dir.is_empty() and not dir_exists(dest_dir):
		if not make_dir_recursive(dest_dir):
			return false
	
	var source_file = FileAccess.open(source_path, FileAccess.READ)
	if not source_file:
		return false
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest_file:
		source_file.close()
		return false
	
	var buffer_size = 65536  # 64KB chunks
	while not source_file.eof_reached():
		var chunk = source_file.get_buffer(buffer_size)
		dest_file.store_buffer(chunk)
	
	source_file.close()
	dest_file.close()
	
	return true

## Recursively copies a directory to another location
## Returns true on success
static func copy_dir(source: String, dest: String) -> bool:
	if not DirAccess.dir_exists_absolute(dest):
		DirAccess.make_dir_recursive_absolute(dest)
	
	var dir = DirAccess.open(source)
	if dir == null:
		push_error("[FileSystemManager] Failed to open source directory: " + source)
		return false
	
	dir.list_dir_begin()
	var item = dir.get_next()
	var success = true
	
	while item != "":
		if item != "." and item != "..":
			var src_path = source.rstrip("/") + "/" + item
			var dst_path = dest.rstrip("/") + "/" + item
			if dir.current_is_dir():
				if not copy_dir(src_path, dst_path):
					success = false
			else:
				if not copy_file(src_path, dst_path):
					success = false
		item = dir.get_next()
	
	dir.list_dir_end()
	return success

## Creates a ZIP archive from a directory
## When root_name is provided, creates a root folder inside the zip with that name
## max_file_size: maximum file size in bytes to include (-1 for no limit)
## Returns true on success
static func zip_directory(source_dir: String, dest_zip: String, max_file_size: int = -1, root_name: String = "") -> bool:
	if not dir_exists(source_dir):
		push_error("[FileSystemManager] Source directory does not exist: " + source_dir)
		return false
	
	# If root_name is provided, stage to temp directory first
	var actual_source = source_dir
	var stage_dir = ""
	
	if not root_name.is_empty():
		stage_dir = "user://temp_saves/stage_" + str(Time.get_ticks_msec()) + "/"
		var stage_root = stage_dir + root_name
		DirAccess.make_dir_recursive_absolute(stage_root)
		var copy_success = copy_dir(source_dir, stage_root)
		if not copy_success:
			delete_dir_recursive(stage_dir)
			return false
		actual_source = stage_dir
	
	# Ensure parent directory exists
	var parent_dir = dest_zip.get_base_dir()
	if not parent_dir.is_empty() and not dir_exists(parent_dir):
		if not make_dir_recursive(parent_dir):
			if not stage_dir.is_empty():
				delete_dir_recursive(stage_dir)
			return false
	
	var packer = ZIPPacker.new()
	var err = packer.open(dest_zip)
	if err != OK:
		push_error("[FileSystemManager] Failed to open ZIPPacker for: " + dest_zip)
		if not stage_dir.is_empty():
			delete_dir_recursive(stage_dir)
		return false
	
	var success = _zip_directory_recursive(packer, actual_source, "", max_file_size)
	packer.close()
	
	# Clean up staging directory if used
	if not stage_dir.is_empty():
		delete_dir_recursive(stage_dir)
	
	return success

## Internal: Recursively adds directory contents to a ZIPPacker
static func _zip_directory_recursive(packer: ZIPPacker, dir_path: String, zip_prefix: String, max_file_size: int = -1) -> bool:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		push_error("[FileSystemManager] Failed to open directory for zipping: " + dir_path)
		return false
	
	dir.list_dir_begin()
	var filename = dir.get_next()
	var success = true
	
	while filename != "":
		if filename != "." and filename != "..":
			var full_path = dir_path + "/" + filename
			var zip_path = zip_prefix + filename
			
			if dir.current_is_dir():
				packer.start_file(zip_path + "/")
				packer.close_file()
				if not _zip_directory_recursive(packer, full_path, zip_path + "/", max_file_size):
					success = false
			else:
				# Check file size if max_file_size is set
				var file = FileAccess.open(full_path, FileAccess.READ)
				if file == null:
					push_error("[FileSystemManager] Failed to read file for zipping: " + full_path)
					success = false
				else:
					var file_size = file.get_length()
					if max_file_size > 0 and file_size > max_file_size:
						print("[FileSystemManager] Skipping oversized file (" + str(file_size) + " bytes): " + full_path)
						file.close()
					else:
						var data = file.get_buffer(file_size)
						file.close()
						packer.start_file(zip_path)
						packer.write_file(data)
						packer.close_file()
			
			if not success:
				break
		
		filename = dir.get_next()
	
	dir.list_dir_end()
	return success

## Deletes a file
static func delete_file(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_delete_file(path)
	
	return DirAccess.remove_absolute(path) == OK

## Gets file modification time
static func get_modified_time(path: String) -> int:
	if path.is_empty():
		return 0
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_get_modified_time(path)
	
	if not FileAccess.file_exists(path):
		return 0
	
	return FileAccess.get_modified_time(path)

## Opens a file for reading
## Returns FileAccess object or null on failure
static func open_file_read(path: String) -> FileAccess:
	if path.is_empty():
		return null
	
	path = resolve_content_uri(path)
	return FileAccess.open(path, FileAccess.READ)

## Opens a file for writing
## Returns FileAccess object or null on failure
static func open_file_write(path: String) -> FileAccess:
	if path.is_empty():
		return null
	
	path = resolve_content_uri(path)
	return FileAccess.open(path, FileAccess.WRITE)

## Writes string content to a file
static func write_file(path: String, content: String) -> bool:
	if path.is_empty():
		return false
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_write_file(path, content.to_utf8_buffer())
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	
	file.store_string(content)
	file.close()
	return true

## Writes binary data to a file
static func write_file_bytes(path: String, data: PackedByteArray) -> bool:
	if path.is_empty():
		return false
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_write_file(path, data)
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	
	file.store_buffer(data)
	file.close()
	return true

## Reads the entire content of a file as a string
static func read_file(path: String) -> String:
	if path.is_empty() or not file_exists(path):
		return ""
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		var bytes = _plugin_read_file(path)
		return bytes.get_string_from_utf8()
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	
	var content = file.get_as_text()
	file.close()
	return content

## Reads the entire content of a file as bytes
static func read_file_bytes(path: String) -> PackedByteArray:
	if path.is_empty() or not file_exists(path):
		return PackedByteArray()
	
	# Check if restricted Android path
	if _is_restricted_android_path(path):
		return _plugin_read_file(path)
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return PackedByteArray()
	
	var data = file.get_buffer(file.get_length())
	file.close()
	return data

## Extracts a ZIP archive to a destination directory
static func extract_zip(zip_path: String, extract_dir: String) -> bool:
	if not file_exists(zip_path):
		push_error("[FileSystemManager] ZIP file not found: " + zip_path)
		return false
	
	if not dir_exists(extract_dir):
		if not make_dir_recursive(extract_dir):
			push_error("[FileSystemManager] Failed to create extraction directory: " + extract_dir)
			return false
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK:
		print("[FileSystemManager] ZIPReader failed to open ZIP, attempting 7-Zip fallback...")
		return _extract_zip_with_7z(zip_path, extract_dir)
	
	var files = reader.get_files()
	var success = true
	for file_path in files:
		# Skip directory entries (paths ending with /)
		if file_path.ends_with("/"):
			continue
		
		var dest_path = join_paths(extract_dir, file_path)
		var dest_dir = dest_path.get_base_dir()
		
		if not dir_exists(dest_dir):
			make_dir_recursive(dest_dir)
		
		var data = reader.read_file(file_path)
		if data.is_empty():
			push_warning("[FileSystemManager] Empty file in ZIP: " + file_path)
			continue
		
		if not write_file_bytes(dest_path, data):
			push_error("[FileSystemManager] Failed to write extracted file: " + dest_path)
			success = false
	
	reader.close()
	return success

## Extracts a ZIP archive using 7-Zip binary (fallback for ZIP64/large files)
## Returns true on success
static func _extract_zip_with_7z(zip_path: String, extract_dir: String) -> bool:
	var binary_path = _get_7z_binary_path()
	if binary_path == "":
		push_error("[FileSystemManager] 7-Zip binary not available for fallback extraction")
		return false
	
	print("[FileSystemManager] Using 7-Zip fallback for ZIP extraction: " + binary_path)
	
	var abs_zip = resolve_native_path(zip_path)
	var abs_extract_dir = resolve_native_path(extract_dir)
	
	print("[FileSystemManager] 7-Zip extracting: " + abs_zip + " -> " + abs_extract_dir)
	
	# Use 7z x to extract with full paths
	var output = []
	var args = ["x", abs_zip, "-o" + abs_extract_dir, "-y"]
	var exit_code = OS.execute(binary_path, args, output, true)
	
	if exit_code != 0:
		push_error("[FileSystemManager] 7-Zip extraction failed with exit code: " + str(exit_code))
		return false
	
	print("[FileSystemManager] 7-Zip extraction completed successfully")
	return true

## Gets the bundled 7z binary path for the current platform
static func _get_7z_binary_path() -> String:
	var platform_name = ""
	match OS.get_name():
		"Windows":
			platform_name = "windows"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			platform_name = "linux"
		_:
			return ""
	
	var binary_name = "7za.exe" if OS.get_name() == "Windows" else "7z"
	return ProjectSettings.globalize_path("res://bin/7z/" + platform_name + "/" + binary_name)

## Gets available storage space in bytes for a given path
static func get_available_space(path: String) -> int:
	# Use OS.get_user_data_dir() as a proxy for available space
	# This is platform-dependent and may not be accurate for all paths
	var dir = DirAccess.open(path.get_base_dir())
	if dir:
		return dir.get_space_left()
	return -1

## Gets the directory portion of a path
static func get_dir(path: String) -> String:
	return path.get_base_dir()

## Gets the filename portion of a path
static func get_filename(path: String) -> String:
	return path.get_file()

## Gets the file extension
static func get_extension(path: String) -> String:
	return path.get_extension()

## Checks if a path is a directory
static func is_dir(path: String) -> bool:
	return dir_exists(path)

## Gets a list of all files (not directories) in a directory
static func get_files(path: String) -> Array[String]:
	var result: Array[String] = []
	var items = list_dir(path)
	
	for item in items:
		var item_path = join_paths(path, item)
		if not is_dir(item_path):
			result.append(item)
	
	return result

## Gets a list of all subdirectories in a directory
static func get_dirs(path: String) -> Array[String]:
	var result: Array[String] = []
	var items = list_dir(path)
	
	for item in items:
		var item_path = join_paths(path, item)
		if is_dir(item_path):
			result.append(item)
	
	return result
