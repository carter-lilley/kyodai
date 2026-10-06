## Config-first resolver for PPSSPP's ppsspp.ini.
## The memstick root is the ini's great-grandparent:
## <memstick>/PSP/SYSTEM/ppsspp.ini.
##
##   [General]
##   MemStickDirectory =      - custom memstick root (rarely written; on
##                              Android the ini follows the memstick, so the
##                              key is usually absent and presence of the ini
##                              is itself the location signal)
##
## Semantics (PPSSPP PathUtil / GetSysDirectory(DIRECTORY_SAVEDATA)):
##   MemStickDirectory absent/empty - saves under <memstick>/PSP/SAVEDATA
##   set                            - treated as the memstick root (a trailing
##                                    /PSP is stripped defensively); relative
##                                    values resolve against the anchor
## Saves are one folder per game id: <memstick>/PSP/SAVEDATA/<GAMEID>/.
## Pass 1 scope: save kind only (psp); firmware resolves key-absent.
## Android memstick relocation without a readable pointer (SharedPreferences)
## is covered downstream by the {app_data}/{emulator_dir} variant picker in
## GameSaveSubManager, not here.
class_name PpssppIniResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Resolves one placement from the context RSM built.
## context: {config_path, config_status, platform_slug}
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

	var platform_slug: String = context.get("platform_slug", "")
	if platform_slug != "psp":
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

## Core logic on raw ppsspp.ini text, split from resolve() so it stays
## testable without the CSM/FSM autoload chain.
static func _resolve_from_text(text: String, config_path: String) -> Dictionary:
	var result := {
		"path": "",
		"source": "config",
		"config_file": config_path,
		"key": "MemStickDirectory",
		"caveat": "",
	}

	# The memstick root is the ini's great-grandparent:
	# <memstick>/PSP/SYSTEM/ppsspp.ini -> SYSTEM -> PSP -> memstick
	var anchor := config_path.get_base_dir().get_base_dir().get_base_dir()
	var sections := _scan_sections(text)

	var memstick := _normalize(str(sections.get("General", {}).get("MemStickDirectory", "")))
	if memstick == "":
		result.caveat = "emulator-default"
		result.path = anchor + "/PSP/SAVEDATA/"
		return result

	memstick = memstick.rstrip("/")
	# Defensive: accept both "parent of PSP" and "PSP dir itself" forms.
	if memstick.to_lower().ends_with("/psp"):
		memstick = memstick.substr(0, memstick.length() - 4)
	if not memstick.is_absolute_path():
		memstick = anchor + "/" + memstick
	result.path = memstick.simplify_path().rstrip("/") + "/PSP/SAVEDATA/"
	return result

## Collects sections as {section_name: {key: value}}. ppsspp.ini is plain:
## "key = value" lines, no escaping, no duplicate keys within a section.
static func _scan_sections(text: String) -> Dictionary:
	var sections := {}
	var current := ""
	for raw_line in text.split("\n"):
		var line := raw_line.rstrip("\r").strip_edges()
		if line == "":
			continue
		if line.begins_with("["):
			current = line.trim_prefix("[").trim_suffix("]").strip_edges()
			if not sections.has(current):
				sections[current] = {}
			continue
		if line.begins_with("#") or line.begins_with(";"):
			continue
		var sep := line.find("=")
		if sep < 0:
			continue
		sections[current][line.substr(0, sep).strip_edges()] = line.substr(sep + 1).strip_edges()
	return sections

static func _normalize(value: String) -> String:
	return value.replace("\\", "/").strip_edges()

## Enforces PPSSPP's plain INI config.
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[PpssppIniResolver] enforce_paths called without config_path")
		return false

	var text := ""
	if FSM.file_exists(config_path):
		text = FSM.read_file(config_path)
		var backup_path := config_path + ".kyodai-backup"
		if not FSM.file_exists(backup_path):
			FSM.write_file(backup_path, text)

	for section_name in sections:
		var section_data: Dictionary = sections[section_name]
		text = _ensure_section(text, "[" + section_name + "]")
		for key in section_data:
			text = _set_plain_key(text, "[" + section_name + "]", key, str(section_data[key]))

	var parent_dir := config_path.get_base_dir()
	if parent_dir != "" and not FSM.dir_exists(parent_dir):
		FSM.make_dir_recursive(parent_dir)

	if not FSM.write_file(config_path, text):
		push_error("[PpssppIniResolver] Failed to write enforced config: " + config_path)
		return false
	print("[PpssppIniResolver] Enforced paths in " + config_path)
	return true

static func _ensure_section(text: String, section: String) -> String:
	if text.contains(section):
		return text
	if not text.is_empty() and not text.ends_with("\n"):
		text += "\n"
	return text + section + "\n"

static func _set_plain_key(text: String, section: String, key: String, value: String) -> String:
	var lines := text.split("\n")
	var section_idx := -1
	var key_idx := -1
	for i in range(lines.size()):
		var stripped := lines[i].strip_edges()
		if stripped == section:
			section_idx = i
			continue
		if section_idx < 0:
			continue
		if stripped.begins_with("[") and stripped.ends_with("]"):
			break
		if key_idx < 0:
			var sep := stripped.find("=")
			if sep >= 0 and stripped.substr(0, sep).strip_edges() == key:
				key_idx = i

	var new_line := "%s = %s" % [key, value]
	if key_idx >= 0:
		lines[key_idx] = new_line
	else:
		var insert_at := section_idx + 1 if section_idx >= 0 else lines.size()
		lines.insert(insert_at, new_line)
	return "\n".join(lines)
