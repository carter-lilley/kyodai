## Config-first resolver for the Eden (yuzu-family) NAND save location.
## Reads the [Data%20Storage] section of qt-config.ini (desktop) /
## config.ini (android) by line scan - Qt percent-encodes the section name,
## writes a "<key>\default=" companion per key, and doubles backslashes,
## none of which a generic INI parser understands.
##
## Custom-NAND detection differs per build:
##   desktop (yuzu-style): use_custom_nand=true makes nand_directory
##     authoritative
##   android (device-verified): no toggle key; the companion line
##     "nand_directory\default=false" marks the written value as custom
## Either signal plus a non-empty nand_directory resolves custom.
##
## The default anchor is the config's grandparent dir: portable desktop keeps
## config at <user dir>/config/qt-config.ini and android at
## <app data>/config/config.ini, so grandparent + /nand/user/save reproduces
## the registry default on both. Non-portable desktop installs
## (%APPDATA%/eden) are out of scope (azahar precedent).
##
## Pass 1 scope: save kind only; firmware resolves key-absent.
class_name EdenIniResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")

const SAVE_SUFFIX := "/user/save/"

## Resolves one placement from the context RSM built.
## context: {config_path, config_status} ("anchor" is intentionally unused;
## the default anchor is the matched config's grandparent dir)
static func resolve(kind: String, context: Dictionary) -> Dictionary:
	var result := {
		"path": "",
		"source": "default",
		"config_file": "",
		"key": "",
		"caveat": "",
	}

	if kind != "save":
		result.caveat = "key-absent"
		return result

	var config_path: String = context.get("config_path", "")
	if config_path == "" or context.get("config_status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-missing"
		return result

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.RAW)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	return _resolve_from_text(str(parsed.get("text", "")), config_path)

## Core logic on raw config text, split from resolve() so it stays testable
## without the CSM/FSM autoload chain.
static func _resolve_from_text(text: String, config_path: String) -> Dictionary:
	var result := {
		"path": "",
		"source": "config",
		"config_file": config_path,
		"key": "nand_directory",
		"caveat": "",
	}

	var anchor := config_path.get_base_dir().get_base_dir()
	var storage := _scan_storage_section(text)
	var nand := _unescape(str(storage.get("nand_directory", ""))).strip_edges()

	var custom: bool = str(storage.get("use_custom_nand", "")) == "true"
	if not custom:
		custom = str(storage.get("nand_directory\\default", "")) == "false"

	if custom and nand != "":
		nand = nand.replace("\\", "/").rstrip("/")
		if not nand.is_absolute_path():
			nand = anchor + "/" + nand
		result.path = nand.simplify_path().rstrip("/") + SAVE_SUFFIX
		return result

	result.caveat = "emulator-default"
	result.path = anchor + "/nand" + SAVE_SUFFIX
	return result

## Collects the keys of the [Data Storage] section (Qt writes it percent-
## encoded as [Data%20Storage]). "<key>\default=" companions are kept so the
## android custom-marker is visible; readers must ask for keys explicitly.
static func _scan_storage_section(text: String) -> Dictionary:
	var entries := {}
	var in_section := false
	for raw_line in text.split("\n"):
		var line := raw_line.rstrip("\r").strip_edges()
		if line == "":
			continue
		if line.begins_with("["):
			in_section = line.trim_prefix("[").trim_suffix("]").replace("%20", " ") == "Data Storage"
			continue
		if not in_section:
			continue
		var sep := line.find("=")
		if sep < 0:
			continue
		var key := line.substr(0, sep).strip_edges()
		entries[key] = line.substr(sep + 1).strip_edges()
	return entries

## Reverses Qt's INI escaping (backslash is doubled; paths may mix the
## escaped form with plain forward slashes).
static func _unescape(value: String) -> String:
	return value.replace("\\\\", "\\")
