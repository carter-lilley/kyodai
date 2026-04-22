# FileSystemManager - Unified file system operations that work on both desktop and Android SAF
# Provides SAF-aware abstractions for DirAccess and FileAccess operations

extends Manager

const SAF_PREFIX = "content://"

## Checks if a path is a SAF (Storage Access Framework) URI
static func is_saf_path(path: String) -> bool:
	return path.begins_with(SAF_PREFIX)

## Normalizes a path by removing redundant components like "." and ".."
## and ensuring consistent separators
static func normalize_path(path: String) -> String:
	if path.is_empty():
		return path
	
	# Handle SAF paths specially
	if is_saf_path(path):
		return _normalize_saf_path(path)
	
	# For regular paths, use simple normalization
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

## Normalizes a SAF path
static func _normalize_saf_path(path: String) -> String:
	# SAF paths have format: content://authority/tree/treeId/path/to/file
	# We need to preserve the tree URI portion and normalize the path portion
	
	var tree_pos = path.find("/tree/")
	if tree_pos == -1:
		return path
	
	var tree_uri_end = tree_pos + 6
	var next_slash = path.find("/", tree_uri_end)
	
	if next_slash == -1:
		# Just the tree root, no path to normalize
		return path
	
	var tree_uri = path.substr(0, next_slash)
	var subpath = path.substr(next_slash + 1)
	
	# Normalize the subpath by removing "." components
	var parts = subpath.split("/")
	var normalized_parts = []
	
	for part in parts:
		if part == "." or part.is_empty():
			continue
		normalized_parts.append(part)
	
	if normalized_parts.is_empty():
		return tree_uri
	
	return tree_uri + "/" + "/".join(normalized_parts)

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
	
	# Use the new method that properly handles nested directories
	return plugin.call("createSafDirectoryFromFullPath", full_path)

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

## Deletes a directory (works with both regular paths and SAF URIs)
## The directory must be empty
## Returns true on success, false on failure
static func delete_dir(path: String) -> bool:
	if path.is_empty():
		return false
	
	if is_saf_path(path) and is_android():
		var plugin = _get_plugin()
		if plugin:
			return plugin.call("deleteSafDirectory", path)
		return false
	
	var err = DirAccess.remove_absolute(path)
	return err == OK

## Recursively deletes a directory and all its contents
## Works with both regular paths and SAF URIs
## Returns true on success, false on failure
static func delete_dir_recursive(path: String) -> bool:
	if path.is_empty():
		return false
	
	if not dir_exists(path):
		return true  # Nothing to delete
	
	if is_saf_path(path) and is_android():
		return _saf_delete_dir_recursive(path)
	
	# For regular paths, manually recurse and delete
	var dir := DirAccess.open(path)
	if not dir:
		push_error("[FileSystemManager] Cannot open directory for deletion: " + path)
		return false
	
	dir.list_dir_begin()
	var file_name := dir.get_next()
	
	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		
		var full_path := path + "/" + file_name
		
		if dir.current_is_dir():
			# Recursively delete subdirectory
			if not delete_dir_recursive(full_path):
				dir.list_dir_end()
				return false
		else:
			# Delete file
			var err := DirAccess.remove_absolute(full_path)
			if err != OK:
				push_error("[FileSystemManager] Failed to delete file: " + full_path)
				dir.list_dir_end()
				return false
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	
	# Now delete the empty directory
	var err := DirAccess.remove_absolute(path)
	return err == OK

## Checks if a path is a directory (works with both regular paths and SAF URIs)
## Returns true if path exists and is a directory, false otherwise
static func is_dir(path: String) -> bool:
	if path.is_empty():
		return false
	
	if is_saf_path(path) and is_android():
		var plugin = _get_plugin()
		if plugin:
			return plugin.call("safDirExists", path)
		return false
	
	var dir = DirAccess.open(path)
	if dir:
		return true
	return false

## Moves/Renames a file or directory within the same parent directory (works with both regular paths and SAF URIs)
## source_path: Source path
## dest_name: New name (just the filename/directory name, not full path)
## Returns true on success, false on failure
static func rename(source_path: String, dest_name: String) -> bool:
	if source_path.is_empty() or dest_name.is_empty():
		return false
	
	if is_saf_path(source_path) and is_android():
		# For SAF paths, we need to use copy + delete since SAF doesn't have a direct rename
		return _saf_rename(source_path, dest_name)
	
	var parent_dir = source_path.get_base_dir()
	var dest_path = parent_dir + "/" + dest_name
	
	var err = DirAccess.rename_absolute(source_path, dest_path)
	return err == OK

## Moves a file or directory to a different location (works with both regular paths and SAF URIs)
## Unlike rename(), this can move across different parent directories
## source_path: Full source path
## dest_path: Full destination path
## Returns true on success, false on failure
static func move(source_path: String, dest_path: String) -> bool:
	if source_path.is_empty() or dest_path.is_empty():
		return false
	
	# Check if source exists
	if not file_exists(source_path) and not dir_exists(source_path):
		push_error("[FileSystemManager] Source does not exist: " + source_path)
		return false
	
	if is_saf_path(source_path) or is_saf_path(dest_path):
		# For SAF paths, we need to use copy + delete
		return _saf_move(source_path, dest_path)
	
	# For regular paths, use DirAccess
	var err = DirAccess.rename_absolute(source_path, dest_path)
	return err == OK

## Internal helper for SAF move (copy + delete) - handles full paths
static func _saf_move(source_path: String, dest_path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		push_error("[FileSystemManager] PackageChecker plugin not available for SAF move")
		return false
	
	# Determine if source is a file or directory
	var is_source_dir = dir_exists(source_path)
	
	if is_source_dir:
		# For directories: recursively copy then delete
		if not _saf_move_dir_recursive(source_path, dest_path):
			return false
		# Delete the source directory
		return _saf_delete_dir_recursive(source_path)
	else:
		# For files: copy to temp, then copy to destination SAF location, then delete original
		var temp_path = _saf_to_temp_path(source_path)
		var temp_dir = temp_path.get_base_dir()
		
		# Ensure temp directory exists
		if not DirAccess.dir_exists_absolute(temp_dir):
			DirAccess.make_dir_recursive_absolute(temp_dir)
		
		# Copy SAF file to temp
		if not plugin.call("copySafFileToLocal", source_path, temp_path):
			push_error("[FileSystemManager] Failed to copy SAF file to temp for move: " + source_path)
			return false
		
		# Ensure parent directory of destination exists
		var dest_parent = dest_path.get_base_dir()
		if not dir_exists(dest_parent):
			if not make_dir_recursive(dest_parent):
				push_error("[FileSystemManager] Failed to create destination parent directory: " + dest_parent)
				DirAccess.remove_absolute(temp_path)
				return false
		
		# Copy temp file to destination SAF location
		var tree_uri = _extract_saf_tree_uri(dest_path)
		var filename = _get_saf_filename(dest_path)
		
		if tree_uri.is_empty() or filename.is_empty():
			push_error("[FileSystemManager] Invalid destination SAF path: " + dest_path)
			DirAccess.remove_absolute(temp_path)
			return false
		
		# Convert temp_path to absolute for Java plugin
		var abs_temp_path = temp_path
		if temp_path.begins_with("user://"):
			abs_temp_path = ProjectSettings.globalize_path(temp_path)
		
		if not plugin.call("copyFileToSaf", abs_temp_path, tree_uri, filename):
			push_error("[FileSystemManager] Failed to copy temp file to SAF destination: " + dest_path)
			DirAccess.remove_absolute(temp_path)
			return false
		
		# Clean up temp file
		DirAccess.remove_absolute(temp_path)
		
		# Delete the original SAF file
		return plugin.call("deleteSafFile", source_path)

## Internal helper for SAF rename (copy + delete)
static func _saf_rename(source_path: String, dest_name: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		push_error("[FileSystemManager] PackageChecker plugin not available for SAF rename")
		return false
	
	# Build destination path
	var parent_path = source_path.get_base_dir()
	var dest_path = parent_path + "/" + dest_name
	
	# For directories, we need a different approach
	if is_dir(source_path):
		# SAF doesn't have a direct move for directories, so we copy recursively then delete
		if not _saf_move_dir_recursive(source_path, dest_path):
			return false
		# Delete the source directory
		return _saf_delete_dir_recursive(source_path)
	else:
		# For files: copy to temp, then copy to new SAF location, then delete original
		var temp_path = _saf_to_temp_path(source_path)
		var temp_dir = temp_path.get_base_dir()
		
		# Ensure temp directory exists
		if not DirAccess.dir_exists_absolute(temp_dir):
			DirAccess.make_dir_recursive_absolute(temp_dir)
		
		# Copy SAF file to temp
		if not plugin.call("copySafFileToLocal", source_path, temp_path):
			push_error("[FileSystemManager] Failed to copy SAF file to temp for rename: " + source_path)
			return false
		
		# Copy temp file to new SAF location
		var tree_uri = _extract_saf_tree_uri(dest_path)
		var filename = _get_saf_filename(dest_path)
		
		if tree_uri.is_empty() or filename.is_empty():
			push_error("[FileSystemManager] Invalid destination SAF path: " + dest_path)
			DirAccess.remove_absolute(temp_path)
			return false
		
		if not plugin.call("copyFileToSaf", temp_path, tree_uri, filename):
			push_error("[FileSystemManager] Failed to copy temp file to new SAF location: " + dest_path)
			DirAccess.remove_absolute(temp_path)
			return false
		
		# Clean up temp file
		DirAccess.remove_absolute(temp_path)
		
		# Delete the original SAF file
		return plugin.call("deleteSafFile", source_path)

## Internal helper to recursively move a SAF directory
static func _saf_move_dir_recursive(source_dir: String, dest_dir: String) -> bool:
	# First, create the destination directory
	if not make_dir_recursive(dest_dir):
		push_error("[FileSystemManager] Failed to create destination directory: " + dest_dir)
		return false
	
	# List and copy all items from source to destination
	var items = list_dir(source_dir)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var source_item = source_dir + "/" + item
		var dest_item = dest_dir + "/" + item
		
		if is_dir(source_item):
			# Recursively move subdirectory
			if not _saf_move_dir_recursive(source_item, dest_item):
				return false
		else:
			# Move file
			var temp_path = _saf_to_temp_path(source_item)
			var plugin = _get_plugin()
			
			if plugin == null:
				return false
			
			# Copy to temp
			if not plugin.call("copySafFileToLocal", source_item, temp_path):
				return false
			
			# Copy to destination
			var tree_uri = _extract_saf_tree_uri(dest_item)
			var filename = _get_saf_filename(dest_item)
			
			if not plugin.call("copyFileToSaf", temp_path, tree_uri, filename):
				DirAccess.remove_absolute(temp_path)
				return false
			
			DirAccess.remove_absolute(temp_path)
	
	return true

## Internal helper to recursively delete a SAF directory
static func _saf_delete_dir_recursive(dir_path: String) -> bool:
	var plugin = _get_plugin()
	if plugin == null:
		return false
	
	# List all items in the directory
	var items = list_dir(dir_path)
	for item in items:
		if item == "." or item == "..":
			continue
		
		var item_path = dir_path + "/" + item
		
		if is_dir(item_path):
			# Recursively delete subdirectory
			if not _saf_delete_dir_recursive(item_path):
				return false
		else:
			# Delete file
			if not plugin.call("deleteSafFile", item_path):
				return false
	
	# Note: SAF doesn't have a direct directory delete, we rely on the directory being empty
	# The directory will be cleaned up when empty or by the system
	return true

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

## Creates a ZIP archive from a directory
## source_dir: Directory to zip
## dest_zip: Destination ZIP file path
## Returns true on success
static func zip_directory(source_dir: String, dest_zip: String, max_file_size: int = -1) -> bool:
	if not dir_exists(source_dir):
		push_error("[FileSystemManager] Source directory does not exist: " + source_dir)
		return false
	
	var is_saf_dest = is_saf_path(dest_zip) and is_android()
	var actual_zip_path = dest_zip
	
	# For SAF destinations, write to temp first then copy
	if is_saf_dest:
		actual_zip_path = _saf_to_temp_path(dest_zip)
	
	# Ensure parent directory exists
	var parent_dir = actual_zip_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		var err = DirAccess.make_dir_recursive_absolute(parent_dir)
		if err != OK:
			push_error("[FileSystemManager] Failed to create ZIP parent directory: " + parent_dir)
			return false
	
	var packer = ZIPPacker.new()
	var err = packer.open(actual_zip_path)
	if err != OK:
		push_error("[FileSystemManager] Failed to open ZIPPacker for: " + actual_zip_path)
		return false
	
	var success = _zip_directory_recursive(packer, source_dir, "", max_file_size)
	packer.close()
	
	if not success:
		return false
	
	if is_saf_dest:
		if not copy_to_saf(actual_zip_path, dest_zip):
			return false
		# Clean up temp file
		if FileAccess.file_exists(actual_zip_path):
			DirAccess.remove_absolute(actual_zip_path)
	
	return true

## Extracts a ZIP archive to a directory
## Works with both regular paths and SAF URIs
## Returns true on success
static func extract_zip(zip_path: String, dest_dir: String) -> bool:
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK:
		push_error("[FileSystemManager] Failed to open ZIP for extraction: " + zip_path)
		return false
	
	var files = reader.get_files()
	var is_saf_dest = is_saf_path(dest_dir) and is_android()
	var actual_dest = dest_dir
	var temp_dest = ""
	
	if is_saf_dest:
		temp_dest = "user://extract_temp/fs_" + str(Time.get_ticks_msec()) + "/"
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
			push_error("[FileSystemManager] Failed to write extracted file: " + file_dest)
			reader.close()
			return false
	
	reader.close()
	
	if is_saf_dest:
		var success = copy_dir_to_saf(temp_dest, dest_dir)
		delete_dir_recursive(temp_dest)
		return success
	
	return true

## Gets the last modified time of a file (works with both regular paths and SAF URIs)
## Returns Unix timestamp (int), or 0 on failure
static func get_modified_time(path: String) -> int:
	if path.is_empty():
		return 0
	
	if is_saf_path(path) and is_android():
		var plugin = _get_plugin()
		if plugin:
			var result = plugin.call("safGetModifiedTime", path)
			if result is int:
				return result
			elif result is String and result.is_valid_int():
				return result.to_int()
		return 0
	
	return FileAccess.get_modified_time(path)

## Extracts a ZIP archive to a directory, optionally placing contents inside a named subfolder
## If subfolder_name is provided, creates dest_dir/subfolder_name/ and extracts there
## Otherwise extracts directly into dest_dir
## Works with both regular paths and SAF URIs
## Returns true on success
static func extract_zip_to_dir(zip_path: String, dest_dir: String, subfolder_name: String = "") -> bool:
	var actual_dest = dest_dir.rstrip("/") + "/"
	if subfolder_name != "":
		actual_dest += subfolder_name + "/"
	return extract_zip(zip_path, actual_dest)

## Recursively copies a local directory to another local directory
## Returns true on success
static func copy_dir(source: String, dest: String) -> bool:
	if not DirAccess.dir_exists_absolute(dest):
		DirAccess.make_dir_recursive_absolute(dest)
	
	var dir = DirAccess.open(source)
	if dir == null:
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
				var file = FileAccess.open(src_path, FileAccess.READ)
				if file:
					var data = file.get_buffer(file.get_length())
					file.close()
					var out = FileAccess.open(dst_path, FileAccess.WRITE)
					if out:
						out.store_buffer(data)
						out.close()
					else:
						success = false
				else:
					success = false
		item = dir.get_next()
	
	dir.list_dir_end()
	return success

## Creates a ZIP archive from a directory with a root folder inside
## e.g., zipping /path/to/data with root_name "save" creates save/... inside the zip
## max_file_size: maximum file size in bytes to include (-1 for no limit)
## Returns true on success
static func zip_directory_with_root(source_dir: String, root_name: String, dest_zip: String, max_file_size: int = -1) -> bool:
	var stage_dir = "user://temp_saves/stage_" + str(Time.get_ticks_msec()) + "/"
	var stage_root = stage_dir + root_name
	DirAccess.make_dir_recursive_absolute(stage_root)
	var copy_success = copy_dir(source_dir, stage_root)
	if not copy_success:
		delete_dir_recursive(stage_dir)
		return false
	var zip_success = zip_directory(stage_dir, dest_zip, max_file_size)
	delete_dir_recursive(stage_dir)
	return zip_success

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
