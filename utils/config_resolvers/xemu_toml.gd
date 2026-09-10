## Config-first resolver for the xemu family's config TOML (xemu desktop,
## x1box on Android). Reads the [sys.files] section:
##
##   [sys.files]
##   hdd_path = '...'       - HDD image (saves live inside its FATX; this
##                            resolver reports the image's parent dir).
##   flashrom_path = '...'  - BIOS (Complex_4627.bin / flash.bin). Firmware
##                            kind reports its parent dir.
##   bootrom_path = '...'   - MCPX boot ROM (mcpx_1.0.bin / mcpx.bin);
##                            firmware fallback when flashrom_path is absent.
##
## Both stock layouts are handled by CSM's TOML reader: desktop xemu writes
## flush-left sections, x1box writes indented sections, and both use
## single-quoted values.
##
## Scope: save + firmware kinds. eeprom_path is per-machine state, not
## firmware; it belongs to the future FATX/state workstream.
class_name XemuTomlResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")

## Resolves one placement from the context RSM built.
## context: {config_path, config_status, anchor}
static func resolve(kind: String, context: Dictionary) -> Dictionary:
	var result := {
		"path": "",
		"source": "default",
		"config_file": "",
		"key": "",
		"caveat": "",
	}

	if kind != "save" and kind != "firmware":
		result.caveat = "key-absent"
		return result

	var config_path: String = context.get("config_path", "")
	if config_path == "" or context.get("config_status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-missing"
		return result

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.TOML)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	var anchor := config_path.get_base_dir()
	var files_section: Dictionary = parsed.sections.get("sys.files", {})

	var keys: Array = []
	match kind:
		"save":
			keys = ["hdd_path"]
		"firmware":
			keys = ["flashrom_path", "bootrom_path"]

	for key in keys:
		var value := str(files_section.get(key, "")).strip_edges()
		if value == "":
			continue
		var file_path := value.replace("\\", "/")
		if not file_path.is_absolute_path():
			file_path = anchor + "/" + file_path
		result.path = file_path.simplify_path().get_base_dir().rstrip("/") + "/"
		result.source = "config"
		result.config_file = config_path
		result.key = "sys.files." + key
		return result

	result.caveat = "emulator-default"
	return result
