## Config-first resolver for the xenia family's config TOML (xenia-edge,
## xenia-canary / XenDroid). Reads the [Storage] section:
##
##   [Storage]
##   content_root = ""   - guest content root (saves). Empty/absent means the
##                         default <storage root>/content applies, reported
##                         with the emulator-default caveat. The storage root
##                         is the config file's own dir in every in-scope
##                         layout (portable desktop, XenDroid's compose/).
##
## The active save profile is NOT resolved here: [Profiles]
## logged_profile_slot_0_xuid is consumed downstream in
## GameSaveSubManager._xenia_active_profile (slot 0 only; multi-slot is
## user-resolution-layer work).
##
## Pass 1 scope: save kind only; firmware resolves key-absent.
class_name XeniaTomlResolver

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

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.TOML)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	var anchor := config_path.get_base_dir()
	var value := str(parsed.sections.get("Storage", {}).get("content_root", "")).strip_edges()

	result.config_file = config_path
	result.key = "Storage.content_root"

	if value != "":
		var dir := value.replace("\\", "/").rstrip("/")
		if not dir.is_absolute_path():
			dir = anchor + "/" + dir
		result.path = dir.simplify_path().rstrip("/") + "/"
		result.source = "config"
		return result

	result.caveat = "emulator-default"
	result.path = anchor + "/content/"
	return result
