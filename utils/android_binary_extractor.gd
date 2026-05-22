## Android Native Binary Extractor
## Extracts native binaries from res:// to user://bin/ and makes them executable
## Required because Android cannot execute binaries directly from APK assets

class_name AndroidBinaryExtractor
extends RefCounted

const BIN_DIR := "user://bin/"

## Extracts a binary from res:// to user://bin/ if needed
## Returns the absolute path to the usable binary, or empty string on failure
static func extract_binary(res_path: String, binary_name: String) -> String:
	if not PlatformManager.is_android():
		# On non-Android, return the res:// path directly (OS.execute can use it)
		return ProjectSettings.globalize_path(res_path)
	
	var dest_dir = BIN_DIR
	var dest_path = dest_dir + binary_name
	var abs_dest = ProjectSettings.globalize_path(dest_path)
	
	# Check if already extracted and valid
	if FileAccess.file_exists(dest_path):
		# Verify it has executable permissions by trying to run it with --version
		var output = []
		var exit_code = OS.execute(abs_dest, ["--version"], output, true)
		if exit_code == 0:
			print("[AndroidBinaryExtractor] Using cached binary: " + dest_path)
			return abs_dest
		else:
			print("[AndroidBinaryExtractor] Cached binary invalid, re-extracting: " + dest_path)
	
	# Ensure bin directory exists
	var dir = DirAccess.open("user://")
	if dir == null:
		push_error("[AndroidBinaryExtractor] Failed to open user:// directory")
		return ""
	
	if not dir.dir_exists("bin"):
		var err = dir.make_dir("bin")
		if err != OK:
			push_error("[AndroidBinaryExtractor] Failed to create bin directory: " + str(err))
			return ""
	
	# Copy binary from res:// to user://bin/
	var source_file = FileAccess.open(res_path, FileAccess.READ)
	if not source_file:
		push_error("[AndroidBinaryExtractor] Failed to open source binary: " + res_path)
		return ""
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest_file:
		push_error("[AndroidBinaryExtractor] Failed to create destination file: " + dest_path)
		source_file.close()
		return ""
	
	var buffer_size = 65536  # 64KB chunks
	while not source_file.eof_reached():
		var chunk = source_file.get_buffer(buffer_size)
		dest_file.store_buffer(chunk)
	
	source_file.close()
	dest_file.close()
	
	print("[AndroidBinaryExtractor] Extracted binary: " + res_path + " -> " + dest_path)
	
	# Make executable via plugin
	var plugin = _get_plugin()
	if plugin == null:
		push_error("[AndroidBinaryExtractor] Plugin not available to chmod binary")
		return ""
	
	var chmod_success = plugin.call("chmodExecutable", abs_dest)
	if not chmod_success:
		push_error("[AndroidBinaryExtractor] Failed to chmod binary: " + abs_dest)
		return ""
	
	print("[AndroidBinaryExtractor] Binary ready: " + abs_dest)
	return abs_dest

## Extracts all utility binaries for Android
## Call this during app startup/OOBE
static func extract_all_binaries() -> void:
	if not PlatformManager.is_android():
		return
	
	print("[AndroidBinaryExtractor] Extracting all utility binaries...")
	
	# CHD reader
	var chd_path = extract_binary("res://bin/libchdr/android/chd_reader-arm64", "chd_reader")
	if chd_path == "":
		push_warning("[AndroidBinaryExtractor] Failed to extract chd_reader")
	
	# CSO reader  
	var cso_path = extract_binary("res://bin/cso_reader/android/cso_reader-arm64", "cso_reader")
	if cso_path == "":
		push_warning("[AndroidBinaryExtractor] Failed to extract cso_reader")
	
	print("[AndroidBinaryExtractor] Binary extraction complete")

## Gets the PackageChecker plugin singleton
static func _get_plugin():
	if Engine.has_singleton("PackageChecker"):
		return Engine.get_singleton("PackageChecker")
	return null