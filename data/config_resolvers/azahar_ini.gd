## Config-first resolver for the Azahar family's qt-config.ini.
## The SDMC (save) location lives in the [Data Storage] section:
##
##   [Data%20Storage]
##   use_custom_storage\default=true
##   use_custom_storage=false
##   sdmc_directory\default=false
##   sdmc_directory=C:\\Users\\...\\azahar/user/sdmc/
##
## This is deliberately NOT an INI parser: Qt's INI flavor percent-encodes
## the section name ([Data%20Storage]), writes a "<key>\default=" companion
## for every real key, and escapes backslashes as \\ - none of which a
## generic parser understands, so the keys are matched by line scan.
##
## Semantics (citra_qt QtConfig::ReadDataStorageValues):
##   use_custom_storage=true + sdmc_directory set - the custom SDMC root
##   anything else                              - the built-in default applies:
##                                                <user dir>/sdmc, reported
##                                                with the emulator-default
##                                                caveat. (The directory keys
##                                                are ALWAYS written, defaults
##                                                included; only the toggle
##                                                makes them authoritative.)
## The default anchor is the config's grandparent dir: config lives at
## <user dir>/config/qt-config.ini, and user data path = config parent in
## every in-scope layout (portable <exe>/user/, the only mode kyodai
## manages). Non-portable installs (%APPDATA%/Azahar) are out of scope.
##
## Pass 1 scope: save kind only (3ds declares no firmware contract);
## firmware resolves key-absent. The result anchors at the console-identity
## root (<sdmc>/Nintendo 3DS/<id0>/<id1>/) with all-zeros placeholders; the
## real identity dirs are substituted downstream in
## GameSaveSubManager.resolve_save_directories, and the save unit's
## title/extdata trees derive from this root.
class_name AzaharIniResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

const SAVE_SUFFIX := "/Nintendo 3DS/00000000000000000000000000000000/00000000000000000000000000000000/"

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

## Core logic on raw qt-config.ini text, split from resolve() so it stays
## testable without the CSM/FSM autoload chain.
static func _resolve_from_text(text: String, config_path: String) -> Dictionary:
	var result := {
		"path": "",
		"source": "config",
		"config_file": config_path,
		"key": "sdmc_directory",
		"caveat": "",
	}

	var anchor := _compute_anchor(config_path)
	var storage := _scan_storage_section(text)
	var custom: bool = str(storage.get("use_custom_storage", "")) == "true"
	var sdmc := _unescape(storage.get("sdmc_directory", ""))

	if custom and sdmc != "":
		sdmc = sdmc.replace("\\", "/").rstrip("/")
		if not sdmc.is_absolute_path():
			sdmc = anchor + "/" + sdmc
		var resolved := sdmc.simplify_path().rstrip("/")
		if _is_stale_home_path(resolved):
			result.caveat = "stale-home-path"
			result.source = "default"
		else:
			result.path = resolved + SAVE_SUFFIX
		return result

	result.caveat = "emulator-default"
	result.path = anchor + "/sdmc" + SAVE_SUFFIX
	return result

## Computes the data-root anchor from the config file location.
## Portable layout:  <user dir>/config/qt-config.ini  -> anchor = <user dir>
## Non-portable layout: ~/.config/azahar-emu/qt-config.ini -> anchor = ~/.config/azahar-emu
static func _compute_anchor(config_path: String) -> String:
	var config_parent := config_path.get_base_dir()
	var anchor := config_parent.get_base_dir()
	# Portable yuzu-family layout is <root>/user/config/qt-config.ini.
	if config_parent.get_file().to_lower() == "config" and anchor.get_file().to_lower() == "user":
		return anchor
	return config_parent

## Returns true when a path appears to contain a stale home-directory prefix.
static func _is_stale_home_path(path: String) -> bool:
	if path.is_empty():
		return false
	var current_home := OS.get_environment("HOME")
	if current_home == "":
		return false
	current_home = current_home.rstrip("/")
	if not path.begins_with(current_home + "/") and path != current_home:
		if path.begins_with("/home/"):
			return true
	return false

## Collects the real keys of the [Data Storage] section (Qt writes it
## percent-encoded as [Data%20Storage]). "<key>\default=" companion lines
## are QSettings bookkeeping and skipped.
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
		if key.ends_with("\\default"):
			continue
		entries[key] = line.substr(sep + 1).strip_edges()
	return entries

## Reverses Qt's INI escaping (backslash is doubled; paths may mix the
## escaped form with plain forward slashes, as Azahar writes them).
static func _unescape(value: String) -> String:
	return value.replace("\\\\", "\\")

## Enforces Kyodai-managed data paths in Azahar's Qt INI config.
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[AzaharIniResolver] enforce_paths called without config_path")
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
		push_error("[AzaharIniResolver] Failed to write enforced config: " + config_path)
		return false
	print("[AzaharIniResolver] Enforced paths in " + config_path)
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
