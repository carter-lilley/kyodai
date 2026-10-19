## Config-first resolver for melonDS's portable melonDS.ini.
## melonDS uses a plain INI with sections like [Emu], [DS], and [DSi].
## Saves default to next-to-ROM (handled by kyodai's default_saves), so this
## resolver only enforces BIOS/firmware paths and boot settings.
class_name MelondsIniResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Resolves one placement from the context RSM built.
## melonDS saves are intentionally left as next-to-ROM defaults; this resolver
## does not override the save location via config.
static func resolve(_kind: String, _context: Dictionary) -> Dictionary:
	return {
		"path": "",
		"source": "default",
		"config_file": "",
		"key": "",
		"caveat": "key-absent",
	}

## Enforces melonDS's plain INI config.
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[MelondsIniResolver] enforce_paths called without config_path")
		return false

	var text := ""
	if FSM.file_exists(config_path):
		text = FSM.read_file(config_path)
		var backup_path := config_path + ".kyodai-backup"
		if not FSM.file_exists(backup_path):
			FSM.write_file(backup_path, text)

	for section_name in sections:
		var section_data: Dictionary = sections.get(section_name, {})
		text = _ensure_section(text, "[" + section_name + "]")
		for key in section_data:
			text = _set_plain_key(text, "[" + section_name + "]", key, str(section_data[key]))

	var parent_dir := config_path.get_base_dir()
	if parent_dir != "" and not FSM.dir_exists(parent_dir):
		FSM.make_dir_recursive(parent_dir)

	if not FSM.write_file(config_path, text):
		push_error("[MelondsIniResolver] Failed to write enforced config: " + config_path)
		return false
	print("[MelondsIniResolver] Enforced paths in " + config_path)
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
