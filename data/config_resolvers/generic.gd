class_name GenericResolver
extends RefCounted

## Generic READ-ONLY config resolver for user-provided ("custom") emulators.
## Covers the common case: the emulator's config is a standard flat key-value
## format and the save/firmware placement is stated directly as a path value.
##
## There is intentionally NO writer (enforce_paths). Format-preserving writes
## are where per-emulator quirks live (Qt escaping, TOML indentation styles,
## retroarch spacing), so enforcement stays bespoke; RSM's enforce dispatch
## treats a missing writer as a no-op.
##
## Configuration is data, declared in the emulator's resolution block:
##
##   "resolution": {
##     "strategy": "generic",
##     "format": "ini" | "cfg_kv" | "toml" | "json",
##     "config_candidates": { "linux": ["..."] , ... },
##     "save_keys":     ["section/key", ...],
##     "firmware_keys": ["section/key", ...],
##     "default_value_sentinels": ["<default>"],
##     "relative_anchor": "config_dir" | "none",
##     "relative_prefix": ":",
##     "path_transform": "parent_dir"
##   }
##
## Key paths: "section/key" — the section is everything before the LAST "/"
## (sections may contain dots, e.g. "sys.files/hdd_path"); no "/" means the
## root section ("" for INI/CFG_KV/TOML, the top-level object for JSON).
## For JSON, nested objects are flattened so "a/b/c" addresses data.a.b.c.
##
## Value handling:
##   - empty or listed sentinel values are skipped (next key wins)
##   - "relative_prefix": a value starting with it anchors at the config dir
##     (RetroArch's ":/saves" convention)
##   - relative values anchor at "relative_anchor" (default: config_dir);
##     an explicit block-level "anchor" overrides it (RSM resolves it first)
##   - "path_transform": "parent_dir" reports the value's parent directory
##     (for keys pointing at a file, e.g. an HDD image that holds the saves)

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")

## Resolves one placement ("save" or "firmware") from the context RSM built.
## The block's generic-resolver configuration arrives as context.block.
static func resolve(kind: String, context: Dictionary) -> Dictionary:
	var result := {
		"path": "",
		"source": "default",
		"config_file": "",
		"key": "",
		"caveat": "",
	}

	var block: Dictionary = context.get("block", {})
	var keys: Array = block.get(kind + "_keys", [])
	if keys.is_empty():
		result.caveat = "key-absent"
		return result

	var config_path: String = context.get("config_path", "")
	if config_path == "" or context.get("config_status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-missing"
		return result

	var values := _read_values(config_path, str(block.get("format", "ini")))
	if values.is_empty():
		result.caveat = "config-unreadable"
		return result

	var sentinels: Array = block.get("default_value_sentinels", ["<default>"])
	var anchor: String = context.get("anchor", "")
	if anchor == "" and str(block.get("relative_anchor", "config_dir")) == "config_dir":
		anchor = config_path.get_base_dir()
	var prefix := str(block.get("relative_prefix", ""))
	var transform := str(block.get("path_transform", ""))

	for key_path_variant in keys:
		var key_path := str(key_path_variant)
		var raw: Variant = _lookup(values, key_path)
		if raw == null:
			continue
		var value := str(raw).strip_edges()
		if value == "" or value in sentinels:
			continue

		value = value.replace("\\", "/")
		if prefix != "" and value.begins_with(prefix):
			value = value.trim_prefix(prefix).trim_prefix("/")
			if anchor != "":
				value = anchor + "/" + value
		elif not value.is_absolute_path() and anchor != "":
			value = anchor + "/" + value
		value = value.simplify_path().rstrip("/")
		if transform == "parent_dir":
			value = value.get_base_dir()
		if value == "" or value == "/":
			continue

		result.path = value.rstrip("/") + "/"
		result.source = "config"
		result.config_file = config_path
		result.key = key_path
		return result

	result.caveat = "key-absent"
	return result

## Reads the config into the shared sections shape ({section: {key: value}})
## regardless of format. JSON objects are flattened so nested paths become
## "a/b" sections. Returns {} when the file is missing/unparseable.
static func _read_values(config_path: String, format: String) -> Dictionary:
	match format:
		"ini":
			var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.INI)
			return parsed.get("sections", {}) if parsed.get("status") == CSM.Status.OK else {}
		"cfg_kv":
			var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.CFG_KV)
			return parsed.get("sections", {}) if parsed.get("status") == CSM.Status.OK else {}
		"toml":
			var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.TOML)
			return parsed.get("sections", {}) if parsed.get("status") == CSM.Status.OK else {}
		"json":
			if not FileAccess.file_exists(config_path):
				return {}
			var file := FileAccess.open(config_path, FileAccess.READ)
			if not file:
				return {}
			var text := file.get_as_text()
			file.close()
			var data = JSON.parse_string(text)
			if not data is Dictionary:
				return {}
			var out: Dictionary = {}
			_flatten_json(data, "", out)
			return out
	push_warning("[GenericResolver] Unknown format '%s' for %s" % [format, config_path])
	return {}

static func _flatten_json(data: Dictionary, prefix: String, out: Dictionary) -> void:
	for key in data:
		var value: Variant = data[key]
		if value is Dictionary:
			_flatten_json(value, prefix + str(key) + "/", out)
		else:
			var section := prefix.trim_suffix("/")
			if not out.has(section):
				out[section] = {}
			out[section][key] = value

## Looks up "section/key" in the sections shape; "key" alone reads the root
## section ("").
static func _lookup(values: Dictionary, key_path: String) -> Variant:
	var section := ""
	var key := key_path
	var idx := key_path.rfind("/")
	if idx >= 0:
		section = key_path.substr(0, idx)
		key = key_path.substr(idx + 1)
	return values.get(section, {}).get(key, null)
