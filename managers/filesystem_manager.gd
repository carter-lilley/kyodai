# FileSystemManager - Unified file system operations that work on both desktop and Android SAF
# Provides SAF-aware abstractions for DirAccess and FileAccess operations

extends Manager

const SAF_PREFIX = "content://"

## Checks if a path is a SAF (Storage Access Framework) URI
static func is_saf_path(path: String) -> bool:
	return path.begins_with(SAF_PREFIX)

## Checks if running on Android platform
static func is_android() -> bool:
	return PlatformManager.is_android() if Engine.has_singleton("PlatformManager") else OS.get_name() == "Android"

## Gets the PackageChecker plugin singleton (cached reference for performance)
static var _plugin_cache = null
static var _plugin_debug_logged = false

static func _get_plugin():
	if _plugin_cache == null:
		_plugin_cache = Engine.get_singleton("PackageChecker")
		if not _plugin_debug_logged and is_android():
			_plugin_debug_logged = true
			if _plugin_cache != null:
				print("[FileSystemManager] PackageChecker plugin loaded successfully")
				_debug_log_available_methods()
			else:
				push_error("[FileSystemManager] PackageChecker plugin NOT available - SAF operations will fail!")
	return _plugin_cache

## Debug logging for available plugin methods
static func _debug_log_available_methods():
	if _plugin_cache == null:
		return
	
	print("[FileSystemManager] SAF plugin loaded (has_method() unreliable with JNI, methods will be called directly)")

## Checks if a file exists (works with both regular paths and SAF URIs)
static func file_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	if is_saf_path(path) and is_android():
		var plugin = _get_plugin()
		print("[FileSystemManager] Checking SAF file exists: " + path)
		print("[FileSystemManager] Plugin available: " + str(plugin != null))
		if plugin:
			var result = plugin.call("safFileExists", path)
			print("[FileSystemManager] safFileExists result: " + str(result))
			return result
		return false
	
	return FileAccess.file_exists(path)

## Checks if a directory exists (works with both regular paths and SAF URIs)
static func dir_exists(path: String) -> bool:
	if path.is_empty():
		return false
	
	if is_saf_path(path) and is_android():
		var plugin = _get_plugin()
		print("[FileSystemManager] Checking SAF dir exists: " + path)
		print("[FileSystemManager] Plugin available: " + str(plugin != null))
		if plugin:
			var result = plugin.call("safDirExists", path)
			print("[FileSystemManager] safDirExists result: " + str(result))
			return result
		return false
	
	var dir = DirAccess.open(path)
	return dir != null

## Creates a directory recursively (works with both regular paths and SAF URIs)
## Returns true on success, false on failure
static func make_dir_recursive(path: String) -> bool:
	if path.is_empty():
		return false
	
	if is_saf_path(path) and is_android():
		return _saf_make_dir_recursive(path)
	
	var result = DirAccess.make_dir_recursive_absolute(path)
	return result == OK

## Internal helper for SAF directory creation
static func _saf_make_dir_recursive(full_path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		push_error("[FileSystemManager] PackageChecker plugin not available for SAF directory creation")
		return false
	
	# Parse SAF path: content://authority/tree/treeId/subdir1/subdir2
	var tree_pos = full_path.find("/tree/")
	if tree_pos == -1:
		push_error("[FileSystemManager] Invalid SAF path format: " + full_path)
		return false
	
	var after_tree = tree_pos + 6
	var next_slash = full_path.find("/", after_tree)
	
	if next_slash == -1:
		# Just the tree root, no subdirectories to create
		return true
	
	var tree_uri = full_path.substr(0, next_slash)
	var subdirs = full_path.substr(next_slash + 1)
	
	# Split subdirectories and create them one by one
	var path_parts = subdirs.split("/")
	var current_path = ""
	
	for part in path_parts:
		if part.is_empty():
			continue
		
		if current_path.is_empty():
			current_path = part
		else:
			current_path += "/" + part
		
		var success = plugin.call("createSafDirectory", tree_uri, current_path)
		if not success:
			# Directory might already exist, continue
			pass
	
	return true

## Deletes a file (works with both regular paths and SAF URIs)
## Returns true on success, false on failure
static func delete_file(path: String) -> bool:
	if path.is_empty():
		return false
	
	if is_saf_path(path) and is_android():
		var plugin = _get_plugin()
		if plugin:
			return plugin.call("deleteSafFile", path)
		return false
	
	var err = DirAccess.remove_absolute(path)
	return err == OK

## Lists files in a directory (works with both regular paths and SAF URIs)
## Returns array of filenames
static func list_dir(path: String) -> Array:
	print("[FileSystemManager] list_dir called with: " + path)
	
	if path.is_empty():
		print("[FileSystemManager] Empty path, returning empty array")
		return []
	
	if is_saf_path(path) and is_android():
		print("[FileSystemManager] Using SAF path")
		var plugin = _get_plugin()
		if plugin:
			print("[FileSystemManager] Calling safListFiles...")
			var json_str = plugin.call("safListFiles", path)
			print("[FileSystemManager] safListFiles returned: " + str(json_str))
			# Parse the JSON array string returned by the plugin
			var json = JSON.new()
			var error = json.parse(json_str)
			if error == OK:
				print("[FileSystemManager] Parsed JSON data: " + str(json.data))
				return json.data
			else:
				print("[FileSystemManager] JSON parse error: " + str(error))
		else:
			print("[FileSystemManager] Plugin is null!")
		return []
	
	var result: Array = []
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if file != "." and file != "..":
				result.append(file)
			file = dir.get_next()
		dir.list_dir_end()
	return result

## Opens a file for reading (works with both regular paths and SAF URIs)
## For SAF paths on Android, copies to temp location first
## Returns FileAccess object or null on failure
static func open_file_read(path: String) -> FileAccess:
	if path.is_empty():
		return null
	
	if is_saf_path(path) and is_android():
		return _saf_open_file_read(path)
	
	return FileAccess.open(path, FileAccess.READ)

## Opens a file for writing (works with both regular paths and SAF URIs)
## For SAF paths on Android, writes to temp location first, then copies
## Returns FileAccess object or null on failure
static func open_file_write(path: String) -> FileAccess:
	if path.is_empty():
		return null
	
	if is_saf_path(path) and is_android():
		return _saf_open_file_write(path)
	
	return FileAccess.open(path, FileAccess.WRITE)

## Internal helper to read SAF file via temp copy
static func _saf_open_file_read(saf_path: String) -> FileAccess:
	var plugin = _get_plugin()
	if plugin == null:
		return null
	
	# Copy SAF file to temp location
	var temp_path = _saf_to_temp_path(saf_path)
	var temp_dir = temp_path.get_base_dir()
	
	# Ensure temp directory exists
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	# Copy via plugin
	var success = plugin.call("copySafFileToLocal", saf_path, temp_path)
	if not success:
		return null
	
	return FileAccess.open(temp_path, FileAccess.READ)

## Internal helper to write SAF file via temp location
static func _saf_open_file_write(saf_path: String) -> FileAccess:
	# Write to temp location first
	var temp_path = _saf_to_temp_path(saf_path)
	var temp_dir = temp_path.get_base_dir()
	
	# Ensure temp directory exists
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	# Create a wrapper that will copy to SAF on close
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return null
	
	# Store the SAF destination for later copy
	_saf_pending_writes[temp_path] = saf_path
	
	return file

## Dictionary to track pending SAF writes (temp_path -> saf_path)
static var _saf_pending_writes: Dictionary = {}

## Converts a SAF path to a temp path for local operations
static func _saf_to_temp_path(saf_path: String) -> String:
	# Create a safe filename from the SAF path
	var safe_name = saf_path.replace(":", "_").replace("/", "_")
	return "user://saf_temp/" + safe_name

## Commits a pending SAF write (copies temp file to SAF destination)
## Call this after writing to a file returned by open_file_write()
static func commit_saf_write(temp_path: String) -> bool:
	if not _saf_pending_writes.has(temp_path):
		return true  # Not a SAF write, nothing to do
	
	var saf_path = _saf_pending_writes[temp_path]
	var plugin = _get_plugin()
	
	if plugin == null:
		return false
	
	# Extract tree URI and filename from SAF path
	var tree_uri = _extract_saf_tree_uri(saf_path)
	var filename = _get_saf_filename(saf_path)
	
	if tree_uri.is_empty() or filename.is_empty():
		push_error("[FileSystemManager] Could not parse SAF path: " + saf_path)
		return false
	
	var success = plugin.call("copyFileToSaf", temp_path, tree_uri, filename)
	
	# Clean up temp file
	_saf_pending_writes.erase(temp_path)
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	
	return success

## Extracts the tree URI from a full SAF path
## Example: content://authority/tree/treeId/subdir/file -> content://authority/tree/treeId
static func _extract_saf_tree_uri(full_uri: String) -> String:
	var tree_pos = full_uri.find("/tree/")
	if tree_pos == -1:
		return ""
	
	var after_tree = tree_pos + 6
	var next_slash = full_uri.find("/", after_tree)
	
	if next_slash == -1:
		return full_uri
	
	return full_uri.substr(0, next_slash)

## Gets the filename portion from a SAF path
## Example: content://authority/tree/treeId/subdir/file -> subdir/file
static func _get_saf_filename(full_uri: String) -> String:
	var tree_pos = full_uri.find("/tree/")
	if tree_pos == -1:
		return ""
	
	var after_tree = tree_pos + 6
	var next_slash = full_uri.find("/", after_tree)
	
	if next_slash == -1:
		return ""  # Just tree root, no filename
	
	return full_uri.substr(next_slash + 1)

## Copies a file to SAF storage
## source_path: Local file path (absolute or user://)
## dest_saf_path: Full SAF destination path
## Returns true on success
static func copy_to_saf(source_path: String, dest_saf_path: String) -> bool:
	if not is_saf_path(dest_saf_path):
		push_error("[FileSystemManager] Destination is not a SAF path: " + dest_saf_path)
		return false
	
	var plugin = _get_plugin()
	if plugin == null:
		push_error("[FileSystemManager] PackageChecker plugin not available for SAF copy")
		return false
	
	# Convert source path to absolute if needed
	var abs_source = source_path
	if source_path.begins_with("user://"):
		abs_source = ProjectSettings.globalize_path(source_path)
	
	# Extract tree URI and filename
	var tree_uri = _extract_saf_tree_uri(dest_saf_path)
	var filename = _get_saf_filename(dest_saf_path)
	
	if tree_uri.is_empty() or filename.is_empty():
		push_error("[FileSystemManager] Invalid SAF path: " + dest_saf_path)
		return false
	
	return plugin.call("copyFileToSaf", abs_source, tree_uri, filename)

## Copies files recursively from local directory to SAF directory
## source_dir: Local source directory path
## dest_saf_dir: SAF destination directory path
## Returns true on success
static func copy_dir_to_saf(source_dir: String, dest_saf_dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(source_dir):
		push_error("[FileSystemManager] Source directory does not exist: " + source_dir)
		return false
	
	# Ensure destination directory exists
	if not dir_exists(dest_saf_dir):
		if not make_dir_recursive(dest_saf_dir):
			push_error("[FileSystemManager] Failed to create SAF directory: " + dest_saf_dir)
			return false
	
	var dir = DirAccess.open(source_dir)
	if dir == null:
		return false
	
	dir.list_dir_begin()
	var filename = dir.get_next()
	var success = true
	
	while filename != "":
		if filename != "." and filename != "..":
			var source_path = source_dir + "/" + filename
			var dest_path = dest_saf_dir + "/" + filename
			
			if dir.current_is_dir():
				# Recursively copy subdirectory
				if not copy_dir_to_saf(source_path, dest_path):
					success = false
			else:
				# Copy file
				if not copy_to_saf(source_path, dest_path):
					success = false
			
			if not success:
				break
		
		filename = dir.get_next()
	
	dir.list_dir_end()
	return success

## Reads a text file (works with both regular paths and SAF URIs)
## Returns file contents as String, or empty string on failure
static func read_file(path: String) -> String:
	var file = open_file_read(path)
	if file == null:
		return ""
	
	var content = file.get_as_text()
	file.close()
	return content

## Writes text to a file (works with both regular paths and SAF URIs)
## Returns true on success
static func write_file(path: String, content: String) -> bool:
	if is_saf_path(path) and is_android():
		return _saf_write_file(path, content)
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	
	file.store_string(content)
	file.close()
	return true

## Internal helper for SAF file writing
static func _saf_write_file(saf_path: String, content: String) -> bool:
	var plugin = _get_plugin()
	if plugin:
		return plugin.call("writeSafFile", saf_path, content)
	
	# Fallback: write to temp then copy
	var temp_path = _saf_to_temp_path(saf_path)
	var temp_dir = temp_path.get_base_dir()
	
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	
	file.store_string(content)
	file.close()
	
	var success = copy_to_saf(temp_path, saf_path)
	
	# Clean up temp file
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	
	return success
