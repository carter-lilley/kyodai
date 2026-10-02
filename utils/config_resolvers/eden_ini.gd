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
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

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

	var anchor := _compute_anchor(config_path)
	var storage := _scan_storage_section(text)
	var nand := _unescape(str(storage.get("nand_directory", ""))).strip_edges()

	var custom: bool = str(storage.get("use_custom_nand", "")) == "true"
	if not custom:
		custom = str(storage.get("nand_directory\\default", "")) == "false"

	if custom and nand != "":
		nand = nand.replace("\\", "/").rstrip("/")
		if not nand.is_absolute_path():
			nand = anchor + "/" + nand
		var resolved := nand.simplify_path().rstrip("/")
		if _is_stale_home_path(resolved):
			result.caveat = "stale-home-path"
			result.source = "default"
		else:
			result.path = resolved + SAVE_SUFFIX
		return result

	result.caveat = "emulator-default"
	result.path = anchor + "/nand" + SAVE_SUFFIX
	return result

## Computes the data-root anchor from the config file location.
## Portable layout:  <user dir>/config/qt-config.ini  -> anchor = <user dir>
## Non-portable layout: ~/.config/eden/qt-config.ini  -> anchor = ~/.config/eden
static func _compute_anchor(config_path: String) -> String:
	var config_parent := config_path.get_base_dir()
	var anchor := config_parent.get_base_dir()
	# Portable yuzu-family layout is <root>/user/config/qt-config.ini.
	# If we see .../user/config/<file>, the data root is the user/ directory.
	if config_parent.get_file().to_lower() == "config" and anchor.get_file().to_lower() == "user":
		return anchor
	return config_parent

## Returns true when a path appears to contain a stale home-directory prefix
## from a different machine/account (e.g. /home/user/... on /home/carter).
static func _is_stale_home_path(path: String) -> bool:
	if path.is_empty():
		return false
	var current_home := OS.get_environment("HOME")
	if current_home == "":
		return false
	current_home = current_home.rstrip("/")
	if not path.begins_with(current_home + "/") and path != current_home:
		# Path is outside current home; if it looks like a /home/... or
		if path.begins_with("/home/"):
			return true
	return false

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

## Enforces Kyodai-managed data paths by writing them directly into Eden's
## Qt INI config. Creates the config file and parent directories when missing.
## Backs up an existing config once to <path>.kyodai-backup before editing.
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[EdenIniResolver] enforce_paths called without config_path")
		return false

	var text := ""
	if FSM.file_exists(config_path):
		text = FSM.read_file(config_path)
		var backup_path := config_path + ".kyodai-backup"
		if not FSM.file_exists(backup_path):
			FSM.write_file(backup_path, text)

	for section_name in sections:
		var section_data: Dictionary = sections[section_name]
		var qt_section := _encode_section_name(section_name)
		text = _ensure_section(text, qt_section)
		for key in section_data:
			var value: String = str(section_data[key]).replace("\\", "/")
			text = _set_qt_key(text, qt_section, key, value)

	var parent_dir := config_path.get_base_dir()
	if parent_dir != "" and not FSM.dir_exists(parent_dir):
		FSM.make_dir_recursive(parent_dir)

	if not FSM.write_file(config_path, text):
		push_error("[EdenIniResolver] Failed to write enforced config: " + config_path)
		return false
	print("[EdenIniResolver] Enforced paths in " + config_path)
	return true

static func _encode_section_name(section: String) -> String:
	return "[" + section.replace(" ", "%20") + "]"

static func _ensure_section(text: String, section: String) -> String:
	if text.contains(section):
		return text
	if not text.is_empty() and not text.ends_with("\n"):
		text += "\n"
	return text + section + "\n"

static func _set_qt_key(text: String, section: String, key: String, value: String) -> String:
	var lines := text.split("\n")
	var section_idx := -1
	var key_idx := -1
	var companion_idx := -1
	var companion_key := key + "\\default"

	for i in range(lines.size()):
		var stripped := lines[i].strip_edges()
		if stripped == section:
			section_idx = i
			continue
		if section_idx < 0:
			continue
		# Stop at next section
		if stripped.begins_with("[") and stripped.ends_with("]"):
			break
		if key_idx < 0 and (stripped.begins_with(key + "=") or stripped.begins_with(key + " =")):
			key_idx = i
		elif companion_idx < 0 and (stripped.begins_with(companion_key + "=") or stripped.begins_with(companion_key + " =")):
			companion_idx = i

	var new_key_line := "%s=%s" % [key, value]
	var new_companion_line := "%s=false" % companion_key

	if key_idx >= 0:
		lines[key_idx] = new_key_line
	else:
		var insert_at := section_idx + 1 if section_idx >= 0 else lines.size()
		lines.insert(insert_at, new_key_line)
		if companion_idx >= 0 and companion_idx >= insert_at:
			companion_idx += 1

	if companion_idx >= 0:
		lines[companion_idx] = new_companion_line
	else:
		var insert_at := (key_idx + 1 if key_idx >= 0 else (section_idx + 1 if section_idx >= 0 else lines.size()))
		lines.insert(insert_at, new_companion_line)

	return "\n".join(lines)
