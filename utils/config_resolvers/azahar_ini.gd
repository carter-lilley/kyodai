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

	var anchor := config_path.get_base_dir().get_base_dir()
	var storage := _scan_storage_section(text)
	var custom: bool = str(storage.get("use_custom_storage", "")) == "true"
	var sdmc := _unescape(storage.get("sdmc_directory", ""))

	if custom and sdmc != "":
		sdmc = sdmc.replace("\\", "/").rstrip("/")
		if not sdmc.is_absolute_path():
			sdmc = anchor + "/" + sdmc
		result.path = sdmc.simplify_path().rstrip("/") + SAVE_SUFFIX
		return result

	result.caveat = "emulator-default"
	result.path = anchor + "/sdmc" + SAVE_SUFFIX
	return result

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
