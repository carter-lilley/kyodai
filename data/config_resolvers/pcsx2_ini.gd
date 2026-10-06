## Config-first resolver for PCSX2's inis/PCSX2.ini (INI format, portable mode).
## Mirrors PCSX2's own path math:
##   [Folders] MemoryCards / BIOS   - custom roots, relative to the user dir
##                                    (the cfg's parent dir) or absolute
##   keys absent                    - PCSX2's built-in defaults apply
##                                    ("memcards"/"bios" under the user dir):
##                                    source stays "config" with the
##                                    emulator-default caveat
##   [MemoryCards] Slot1_Filename   - folder memory card name; absent falls to
##                                    kyodai's seeded convention "main.ps2",
##                                    never PCSX2's built-in "Mcd001.ps2"
## The folder card is the sync invariant: when the resolved card path exists
## as a FILE, the user converted it to file-type, which kyodai cannot sync;
## that state is flagged with the file-card caveat and a warning.
## Pass 1 scope: slot 1 only, no savestates, no per-game settings.
class_name Pcsx2IniResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

## kyodai's seeded folder-card name; PCSX2's own default (Mcd001.ps2) is a
## file-type card and is never used.
const CARD_NAME := "main.ps2"

## Resolves one placement ("save" or "firmware") from the context RSM built.
## Returns the standard result dict; path is "" with source "default" only
## when the config file itself is missing or unreadable.
static func resolve(kind: String, context: Dictionary) -> Dictionary:
	var result := {
		"path": "",
		"source": "default",
		"config_file": "",
		"key": "",
		"caveat": "",
	}

	var config_path: String = context.get("config_path", "")
	if config_path == "" or context.get("config_status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-missing"
		return result

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.INI)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	var sections: Dictionary = parsed.sections
	result.config_file = config_path

	# Portable mode: the user dir (anchor for relative [Folders] values and
	# for PCSX2's built-in default folders) is the parent of inis/.
	var user_dir := config_path.get_base_dir().get_base_dir()

	if kind == "save":
		var root := _folders_dir(sections, ["MemoryCards"], user_dir, "memcards")
		result.key = root.key
		if not root.stated:
			result.caveat = "emulator-default"

		var card := str(sections.get("MemoryCards", {}).get("Slot1_Filename", "")).strip_edges()
		if card == "":
			card = CARD_NAME
		var card_path: String = root.path.rstrip("/") + "/" + card

		if FSM.file_exists(card_path):
			result.caveat = "file-card"
			push_warning("[Pcsx2IniResolver] " + card_path + " is a file-type card; folder-card sync requires a folder card (main.ps2)")

		result.path = card_path + "/"
		result.source = "config"
		return result

	var firmware := _folders_dir(sections, ["BIOS", "Bios"], user_dir, "bios")
	result.key = firmware.key
	if not firmware.stated:
		result.caveat = "emulator-default"
	result.path = firmware.path
	result.source = "config"
	return result

## Reads the first present, non-empty key in [Folders] and resolves it against
## the user dir (relative values, including ".." chains) or verbatim (absolute
## values). Keys absent entirely yield PCSX2's built-in default folder under
## the user dir with stated=false.
static func _folders_dir(sections: Dictionary, key_names: Array, user_dir: String, builtin: String) -> Dictionary:
	var folders: Dictionary = sections.get("Folders", {})
	for key_name in key_names:
		var value: Variant = folders.get(key_name)
		if value == null:
			continue
		var dir := str(value).strip_edges().replace("\\", "/")
		if dir == "":
			continue
		if not dir.is_absolute_path():
			dir = user_dir + "/" + dir
		return {
			"path": dir.simplify_path().rstrip("/") + "/",
			"stated": true,
			"key": "Folders." + key_name,
		}
	return {
		"path": user_dir + "/" + builtin + "/",
		"stated": false,
		"key": "Folders." + str(key_names[0]),
	}

## Enforces PCSX2's INI config ([Folders] and [MemoryCards]).
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[Pcsx2IniResolver] enforce_paths called without config_path")
		return false

	for section_name in sections:
		var section_data: Dictionary = sections[section_name]
		for key in section_data:
			if not CSM.set_value(config_path, key, section_data[key], section_name, CSM.Format.INI, true):
				push_error("[Pcsx2IniResolver] Failed to enforce %s.%s" % [section_name, key])
				return false

	print("[Pcsx2IniResolver] Enforced paths in " + config_path)
	return true
