## Config-first resolver for melonDS's melonDS.toml (TOML subset).
## Mirrors melonDS's own path math (EmuInstance.cpp / Config.cpp):
##   [Instance0] SaveFilePath   - .sav root; absent/empty means melonDS writes
##                                the .sav next to the ROM (emulator-default
##                                caveat, registry default {games_dir}/nds
##                                applies)
##   [DS] FirmwarePath          - DS firmware image; its parent is the firmware
##                                dir kyodai syncs (bios7/bios9/firmware.bin).
##                                BIOS7Path/BIOS9Path are fallbacks
##   keys absent                - registry default {emulator_dir} applies
##                                (key-absent caveat)
## Values may be absolute or relative to the config file's dir (= the portable
## emulator dir). DSi paths and savestates/cheats are out of scope.
## Pass 1 scope: instance 0 only, DS (not DSi) firmware.
class_name MelondsTomlResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Resolves one placement ("save" or "firmware") from the context RSM built.
## Returns the standard result dict; path is "" with source "default" whenever
## the config cannot produce a value (missing, unreadable, or key absent).
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

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.TOML)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	var sections: Dictionary = parsed.sections
	result.config_file = config_path
	var anchor: String = str(context.get("anchor", ""))
	if anchor == "":
		anchor = config_path.get_base_dir()

	if kind == "save":
		# Per-instance path override; instance 0 is what the Paths settings page
		# writes. A root-level entry only exists if hand-written (legacy ini
		# migration maps SaveFilePath into the instance tables).
		for section_name in ["Instance0", ""]:
			var value := str(sections.get(section_name, {}).get("SaveFilePath", "")).strip_edges()
			if value == "":
				continue
			result.key = ("Instance0." if section_name != "" else "") + "SaveFilePath"
			result.path = _expand(value, anchor) + "/"
			result.source = "config"
			return result
		# melonDS writes the .sav next to the ROM; the registry default
		# ({games_dir}/nds) approximates that layout.
		result.key = "Instance0.SaveFilePath"
		result.caveat = "emulator-default"
		return result

	# firmware: the DS firmware image's parent dir holds bios7/bios9/firmware.bin
	for key_name in ["FirmwarePath", "BIOS9Path", "BIOS7Path"]:
		var value := str(sections.get("DS", {}).get(key_name, "")).strip_edges()
		if value == "":
			continue
		result.key = "DS." + key_name
		result.path = _expand(value, anchor).get_base_dir() + "/"
		result.source = "config"
		return result
	result.key = "DS.FirmwarePath"
	result.caveat = "key-absent"
	return result

## Expands a TOML path value: absolute values pass through, relative values
## resolve against the anchor (the portable emulator dir).
static func _expand(value: String, anchor: String) -> String:
	var dir := value.replace("\\", "/")
	if not dir.is_absolute_path():
		dir = anchor.rstrip("/") + "/" + dir
	return dir.simplify_path().rstrip("/")
