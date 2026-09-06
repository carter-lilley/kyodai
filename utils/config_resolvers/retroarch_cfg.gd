## Config-first resolver for RetroArch's retroarch.cfg (CFG_KV format).
## Reads the keys RetroArch itself resolves and mirrors its path math:
##   savefile_directory / system_directory   - explicit roots
##   ":\name" prefix                         - relative to the cfg's directory
##   "<default>" / empty / absent            - no statement; caller falls back
##   sort_savefiles_enable + core save_name  - per-core sorted subdirectory
## Exactly one path is returned: the layout the config states. Flipping the
## sorting toggle moves where saves live; old-layout saves stay put until the
## user migrates them.
## Pass 1 scope: save dir, system dir, sorting flag. No override chain,
## no savestates, no *_in_content_dir tracking.
class_name RetroArchCfgResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")

## Resolves one placement ("save" or "firmware") from the context RSM built.
## context: {config_path, config_status, core_save_name}
## Returns the standard result dict; path is "" with source "default" whenever
## the config does not state the placement (the JSON default then applies).
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

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.CFG_KV)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	var keys: Dictionary = parsed.sections.get("", {})
	result.config_file = config_path

	var key := "savefile_directory" if kind == "save" else "system_directory"
	result.key = key

	var value: Variant = keys.get(key)
	if value == null:
		result.caveat = "key-absent"
		return result
	var dir := str(value).strip_edges()
	if dir == "" or dir == "<default>":
		result.caveat = "default-value"
		return result

	# RetroArch's ":" prefix anchors the path at the cfg's own directory.
	if dir.begins_with(":"):
		dir = config_path.get_base_dir() + "/" + dir.trim_prefix(":").trim_prefix("\\").trim_prefix("/")
	dir = dir.replace("\\", "/").rstrip("/") + "/"

	if kind == "save":
		var save_name: String = context.get("core_save_name", "")
		var sorted: bool = str(keys.get("sort_savefiles_enable", "false")) == "true"
		if sorted and save_name != "":
			dir += save_name + "/"

	result.path = dir
	result.source = "config"
	return result
