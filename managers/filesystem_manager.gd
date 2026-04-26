# FileSystemManager - Unified file system operations
# Now uses MANAGE_EXTERNAL_STORAGE on Android for direct filesystem access
# No more SAF (Storage Access Framework) handling

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
	
	# Remove "/./" patterns
	var result = path
	while result.find("/./") != -1:
		result = result.replace("/./", "/")
	
	# Remove trailing "/."
	if result.ends_with("/."):
		result = result.substr(0, result.length() - 2)
	
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
				if Engine.has_singleton("PlatformManager"):
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

## Convenience wrapper for emulator paths
## Automatically provides {emulator_dir} placeholder + base_dir
static func resolve_emulator_path(path: String, emulator_base_dir: String, format: PathFormat = PathFormat.DEFAULT) -> String:
	return resolve_path(path, {
		"base_dir": emulator_base_dir,
		"placeholders": {"{emulator_dir}": emulator_base_dir},
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
	return PlatformManager.is_android() if Engine.has_singleton("PlatformManager") else OS.get_name() == "Android"

## Checks if a file exists
static func file_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	# Convert content:// URIs to real paths
	path = resolve_content_uri(path)
	
	# Handle Godot virtual paths
	if path.begins_with("user://") or path.begins_with("res://"):
		return FileAccess.file_exists(path)
	
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

## Deletes a file
static func delete_file(path: String) -> bool:
	if path.is_empty():
		return false
	return DirAccess.remove_absolute(path) == OK

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
		push_error("[FileSystemManager] Failed to open ZIP: " + zip_path + " (error: " + str(err) + ")")
		return false
	
	var files = reader.get_files()
	for file_path in files:
		var dest_path = join_paths(extract_dir, file_path)
		var dest_dir = dest_path.get_base_dir()
		
		if not dir_exists(dest_dir):
			make_dir_recursive(dest_dir)
		
		var data = reader.read_file(file_path)
		write_file_bytes(dest_path, data)
	
	reader.close()
	return true

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
