class_name JsonKvResolver
extends RefCounted

## Resolver for flat or nested JSON key/value settings files.
## Used for Android emulators that expose writable JSON settings.

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")


static func resolve(_kind: String, _context: Dictionary) -> Dictionary:
	return {
		"status": CSM.Status.MISSING,
		"path": "",
		"source": "default",
		"caveat": "json_kv-resolver-not-implemented",
	}


static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[JsonKvResolver] enforce_paths called without config_path")
		return false

	var data: Dictionary = {}
	if FSM.file_exists(config_path):
		var existing_text: String = FSM.read_file(config_path)
		var parsed = JSON.parse_string(existing_text)
		if parsed is Dictionary:
			data = parsed.duplicate(true)
		else:
			push_error("[JsonKvResolver] Existing file is not a JSON object: " + config_path)
			return false
		var backup_path := config_path + ".kyodai-backup"
		if not FSM.file_exists(backup_path):
			FSM.write_file(backup_path, existing_text)

	for section_name in sections:
		var section_data: Dictionary = sections[section_name]
		var target: Dictionary = data
		if section_name != "":
			var parts: PackedStringArray = section_name.split("/", false)
			for part in parts:
				if not target.has(part) or not target[part] is Dictionary:
					target[part] = {}
				target = target[part]
		for key in section_data:
			target[key] = _coerce_value(section_data[key])

	var parent_dir := config_path.get_base_dir()
	if parent_dir != "" and not FSM.dir_exists(parent_dir):
		FSM.make_dir_recursive(parent_dir)

	if not FSM.write_file(config_path, JSON.stringify(data, "\t")):
		push_error("[JsonKvResolver] Failed to write enforced config: " + config_path)
		return false
	print("[JsonKvResolver] Enforced paths in " + config_path)
	return true


static func _coerce_value(value: String):
	if value == "true":
		return true
	if value == "false":
		return false
	return value
