## Config-first resolver for the RPCS3 family's VFS path config.
## Device path remaps live in vfs.yml (a flat key map sibling of config.yml);
## legacy installs may carry them in config.yml's VFS: section. This is
## deliberately NOT a YAML parser: it matches the exact device keys on any
## line, covering both shapes.
##
##   /dev_hdd0/: <path>     - save root; saves live at <path>/home/<user>/savedata
##   /dev_flash/: <path>    - flash dir; firmware zips (dev_flash{,2,3}) drop at
##                            its parent, so firmware resolution returns the
##                            parent of the remapped dir
##   $(EmulatorDir): <path> - optional override of the expansion base itself
##   key absent/empty       - the emulator's built-in default applies (RPCS3's
##                            own path.empty() -> default behavior), derived
##                            from the registry block's "anchor" fact and
##                            reported with the emulator-default caveat
## Values may embed $(EmulatorDir) (RPCS3 writes it explicitly for defaults),
## be absolute, or be relative to the anchor.
## Pass 1 scope: user id is fixed to 00000001 (RPCS3 multi-user unsupported).
class_name Rpcs3VfsResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

const USER_ID := "00000001"
const KEYS := ["/dev_hdd0/", "/dev_flash/", "$(EmulatorDir)"]

## Resolves one placement ("save" or "firmware") from the context RSM built.
## context: {config_path, config_status, anchor}
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

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.RAW)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	var anchor: String = str(context.get("anchor", "")).rstrip("/")
	if anchor == "":
		result.caveat = "key-absent"
		return result

	result.config_file = config_path
	var entries := _scan_vfs(str(parsed.get("text", "")))

	# The emulator_dir entry (serialized as a "$(EmulatorDir)" key) redefines
	# the expansion base when user-set; empty means auto.
	var override := str(entries.get("$(EmulatorDir)", ""))
	if override != "" and not override.contains("$("):
		anchor = _expand(override, anchor)

	if kind == "save":
		result.key = "/dev_hdd0/"
		var hdd0 := str(entries.get("/dev_hdd0/", ""))
		if hdd0 == "":
			result.caveat = "emulator-default"
			result.path = anchor + "/dev_hdd0/home/" + USER_ID + "/savedata/"
		else:
			result.path = _expand(hdd0, anchor) + "/home/" + USER_ID + "/savedata/"
		result.source = "config"
		return result

	result.key = "/dev_flash/"
	var flash := str(entries.get("/dev_flash/", ""))
	if flash == "":
		result.caveat = "emulator-default"
		result.path = anchor + "/"
	else:
		# Firmware payloads (dev_flash, dev_flash2, dev_flash3) drop at the
		# root, so resolve to the flash dir's parent.
		result.path = _expand(flash, anchor).get_base_dir() + "/"
	result.source = "config"
	return result

## Collects the exact device keys from any line (flat vfs.yml map or legacy
## config.yml VFS: section). Values are quote-stripped but left unexpanded;
## the caller resolves the anchor first (the $(EmulatorDir) key can override
## it) and expands via _expand().
static func _scan_vfs(text: String) -> Dictionary:
	var entries := {}
	for raw_line in text.split("\n"):
		var line := raw_line.rstrip("\r").strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var sep := line.find(":")
		if sep < 0:
			continue
		var key := line.substr(0, sep).strip_edges()
		key = key.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
		if not KEYS.has(key):
			continue
		var value := line.substr(sep + 1).strip_edges()
		value = value.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
		entries[key] = value
	return entries

static func _expand(value: String, anchor: String) -> String:
	var dir := value.replace("\\", "/")
	dir = dir.replace("$(EmulatorDir)", anchor + "/")
	if not dir.is_absolute_path():
		dir = anchor + "/" + dir
	return dir.simplify_path().rstrip("/")

## Enforces RPCS3's flat VFS key map in vfs.yml (or legacy config.yml).
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[Rpcs3VfsResolver] enforce_paths called without config_path")
		return false

	var text := ""
	if FSM.file_exists(config_path):
		text = FSM.read_file(config_path)
		var backup_path := config_path + ".kyodai-backup"
		if not FSM.file_exists(backup_path):
			FSM.write_file(backup_path, text)

	var flat: Dictionary = sections.get("", {})
	for key in flat:
		var value: String = str(flat[key])
		text = _set_vfs_entry(text, key, value)

	var parent_dir := config_path.get_base_dir()
	if parent_dir != "" and not FSM.dir_exists(parent_dir):
		FSM.make_dir_recursive(parent_dir)

	if not FSM.write_file(config_path, text):
		push_error("[Rpcs3VfsResolver] Failed to write enforced config: " + config_path)
		return false
	print("[Rpcs3VfsResolver] Enforced paths in " + config_path)
	return true

static func _set_vfs_entry(text: String, key: String, value: String) -> String:
	var lines := text.split("\n")
	var key_idx := -1
	for i in range(lines.size()):
		var stripped := lines[i].strip_edges()
		if stripped.begins_with(key):
			var sep := stripped.find(":")
			if sep >= 0 and stripped.substr(0, sep).strip_edges() == key:
				key_idx = i
				break
	var new_line := "%s: \"%s\"" % [key, value]
	if key_idx >= 0:
		lines[key_idx] = new_line
	else:
		lines.append(new_line)
	return "\n".join(lines)
