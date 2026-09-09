## Config-first resolver for Vita3K's flat-YAML config.yml. Reads two
## top-level keys:
##
##   pref-path: <dir>   - guest filesystem root (ux0 tree lives under it).
##                        Empty/absent means the emulator default applies,
##                        reported with the emulator-default caveat so the
##                        caller's JSON default paths win. Relative values
##                        anchor at the config file's own dir (portable
##                        desktop installs ship "pref-path: ./").
##   user-id: <nn>      - active user profile; saves live under
##                        ux0/user/<user-id>/savedata. Absent/invalid
##                        falls back to "00".
##
## config.yml is flat (top-level keys only), so a line scan suffices; no
## YAML format is added to CSM. Multi-user selection beyond the config's
## user-id is user-resolution-layer work.
##
## Pass 1 scope: save kind only; firmware resolves key-absent.
class_name Vita3kYmlResolver

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

	if kind != "save":
		result.caveat = "key-absent"
		return result

	var config_path: String = context.get("config_path", "")
	if config_path == "" or context.get("config_status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-missing"
		return result

	if not FileAccess.file_exists(config_path):
		result.caveat = "config-missing"
		return result
	var text := FileAccess.get_file_as_string(config_path)
	if text == "":
		result.caveat = "config-unreadable"
		return result

	var pref_path := ""
	var user_id := ""
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.begins_with("pref-path:"):
			pref_path = _yaml_scalar(line.substr("pref-path:".length()))
		elif line.begins_with("user-id:"):
			user_id = _yaml_scalar(line.substr("user-id:".length()))

	if user_id.length() != 2 or not user_id.is_valid_int():
		user_id = "00"

	result.config_file = config_path
	result.key = "pref-path"

	if pref_path == "":
		result.caveat = "emulator-default"
		return result

	var anchor := config_path.get_base_dir()
	var dir := pref_path.replace("\\", "/").rstrip("/")
	if not dir.is_absolute_path():
		dir = anchor + "/" + dir
	result.path = dir.simplify_path().rstrip("/") + "/ux0/user/" + user_id + "/savedata/"
	result.source = "config"
	return result

## Reads a flat-YAML scalar: trims whitespace, cuts an unquoted inline
## comment, and strips one layer of surrounding single or double quotes.
static func _yaml_scalar(raw: String) -> String:
	raw = raw.strip_edges()
	if raw.length() >= 2 and ((raw.begins_with('"') and raw.ends_with('"')) or (raw.begins_with("'") and raw.ends_with("'"))):
		return raw.substr(1, raw.length() - 2)
	var hash_idx := raw.find(" #")
	if hash_idx >= 0:
		raw = raw.substr(0, hash_idx)
	return raw.strip_edges()
