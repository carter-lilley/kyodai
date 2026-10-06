## Bundled Tool Extractor
## Extracts native binaries and tool scripts from res:// to user://bin/.
## Required because packaged builds (PCK) cannot execute or stat files
## stored inside the pack; Android cannot execute binaries from APK assets.
## In the editor, res:// already points at real files and is returned as-is.

class_name AndroidBinaryExtractor
extends RefCounted

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

const BIN_DIR := "user://bin/"

## Returns the absolute native path to a usable copy of a bundled tool.
## Editor: globalized res:// path. Packaged: extracted copy under user://bin/.
## Returns empty string on failure.
static func extract_binary(res_path: String, binary_name: String) -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path(res_path)

	var dest_path = BIN_DIR + binary_name
	var abs_dest = ProjectSettings.globalize_path(dest_path)

	# A cached copy is valid when its size matches the packed source
	var source_size = FSM.get_file_size(res_path)
	if source_size <= 0:
		push_error("[AndroidBinaryExtractor] Source tool missing from pack: " + res_path)
		return ""
	if FSM.file_exists(dest_path) and FSM.get_file_size(dest_path) == source_size:
		return abs_dest

	if not FSM.copy_file(res_path, dest_path):
		push_error("[AndroidBinaryExtractor] Failed to copy binary: " + res_path + " -> " + dest_path)
		return ""

	print("[AndroidBinaryExtractor] Extracted binary: " + res_path + " -> " + dest_path)

	if not _make_executable(abs_dest):
		return ""

	return abs_dest

## Extracts all bundled tools for the current platform.
## Call once during app startup on packaged builds.
static func extract_all_binaries() -> void:
	if OS.has_feature("editor"):
		return

	print("[AndroidBinaryExtractor] Extracting bundled tools...")

	if SystemManager.platform.is_android():
		pass # sigil ships as jniLibs libsigil.so; see SigilRunner._get_sigil_path()
	elif SystemManager.platform.is_windows():
		_extract_tools({
			"res://bin/sigil/win/sigil.exe": "sigil.exe",
			"res://bin/7z/windows/7za.exe": "7za.exe",
			"res://bin/ahk/AutoHotkey64.exe": "AutoHotkey64.exe",
			"res://bin/shuffler_tools/pssuspend.exe": "pssuspend.exe",
			"res://bin/shuffler_tools/minimize_window.ahk": "minimize_window.ahk",
			"res://bin/shuffler_tools/maximize_process.ahk": "maximize_process.ahk",
		})
	elif SystemManager.platform.is_linux():
		_extract_tools({
			"res://bin/sigil/linux/sigil": "sigil",
			"res://bin/7z/linux/7z": "7z",
			"res://bin/linux/x11_windowctl": "x11_windowctl",
		})

	print("[AndroidBinaryExtractor] Tool extraction complete")

static func _extract_tools(tools: Dictionary) -> void:
	for res_path in tools:
		if extract_binary(res_path, tools[res_path]) == "":
			push_warning("[AndroidBinaryExtractor] Failed to extract: " + res_path)

static func _make_executable(abs_path: String) -> bool:
	if SystemManager.platform.is_windows():
		return true

	if SystemManager.platform.is_android():
		var plugin = _get_plugin()
		if plugin == null:
			push_error("[AndroidBinaryExtractor] Plugin not available to chmod binary")
			return false
		if not plugin.call("chmodExecutable", abs_path):
			push_error("[AndroidBinaryExtractor] Failed to chmod binary: " + abs_path)
			return false
		return true

	var output = []
	var exit_code = OS.execute("chmod", ["+x", abs_path], output, true)
	if exit_code != 0:
		push_error("[AndroidBinaryExtractor] Failed to chmod binary: " + abs_path)
		return false
	return true

## Gets the PackageChecker plugin singleton
static func _get_plugin():
	if Engine.has_singleton("PackageChecker"):
		return Engine.get_singleton("PackageChecker")
	return null
