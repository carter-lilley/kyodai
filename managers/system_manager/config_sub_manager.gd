# SystemManager.config - Unified emulator configuration file I/O
# Format-aware readers and surgical writers for the config formats kyodai's
# emulators use: RetroArch cfg (sectionless key = "value"), INI, and a TOML
# subset, plus a raw string/regex edit engine for everything else.
# Writers edit line-surgically rather than parse-reserialize so comments,
# ordering, and emulator-written formatting survive edits.

extends Manager
class_name ConfigSubManager

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Config file formats understood by this manager.
enum Format {
	RAW,    ## Unstructured text; only edit_text() applies
	CFG_KV, ## RetroArch-style sectionless key = "value" lines
	INI,    ## [section] + key = value
	TOML,   ## TOML subset: [section], string/bool/int/float/array values
}

## Read outcomes for read_config(). MISSING and UNREADABLE are distinct states;
## an empty existing file is OK with empty sections.
enum Status {
	OK,
	MISSING,
	UNREADABLE,
	INVALID,
}

## Original contents captured by begin_backup(), keyed by resolved absolute path.
static var _backups: Dictionary = {}

## Guesses the format of a config file from its extension.
static func detect_format(path: String) -> int:
	match path.get_extension().to_lower():
		"cfg":
			return Format.CFG_KV
		"ini":
			return Format.INI
		"toml":
			return Format.TOML
	return Format.RAW

## Reads and parses a config file.
## Returns {status, format, sections, text} where sections maps
## section name -> {key: value} ("" holds keys before any section; it is the
## only section for CFG_KV). text is the raw file content.
static func read_config(path: String, format := -1) -> Dictionary:
	var fmt := format if format >= 0 else detect_format(path)
	var result := {"status": Status.OK, "format": fmt, "sections": {}, "text": ""}
	if path.is_empty() or not FSM.file_exists(path):
		result.status = Status.MISSING
		return result

	var content := FSM.read_file(path)
	result.text = content
	match fmt:
		Format.CFG_KV:
			result.sections = _parse_kv_lines(content, false, false)
		Format.INI:
			result.sections = _parse_kv_lines(content, true, false)
		Format.TOML:
			result.sections = _parse_kv_lines(content, true, true)
	return result

## Returns the parsed value for key in section ("" for global), or null when the
## file or key is missing. Use read_config() when the distinction matters.
static func get_value(path: String, key: String, section := "", format := -1) -> Variant:
	var result := read_config(path, format)
	if result.status != Status.OK:
		return null
	var section_data: Dictionary = result.sections.get(section, {})
	return section_data.get(key)

## Returns true when key exists in section ("" for global).
static func has_key(path: String, key: String, section := "", format := -1) -> bool:
	var result := read_config(path, format)
	if result.status != Status.OK:
		return false
	var section_data: Dictionary = result.sections.get(section, {})
	return section_data.has(key)

## Sets key to value in section ("" for global), editing only the key's line.
## Appends the key (and section, for INI/TOML) when absent. Creates the file
## when missing and create_if_missing is true. RAW files reject key edits.
static func set_value(path: String, key: String, value: Variant, section := "", format := -1, create_if_missing := true) -> bool:
	if path.is_empty() or key.is_empty():
		push_error("[ConfigManager] Invalid arguments for set_value")
		return false

	var fmt := format if format >= 0 else detect_format(path)
	if fmt == Format.RAW:
		push_error("[ConfigManager] set_value does not apply to RAW format: " + path)
		return false

	if not FSM.file_exists(path):
		if not create_if_missing:
			push_error("[ConfigManager] File not found for set_value: " + path)
			return false
		if not FSM.write_file(path, ""):
			push_error("[ConfigManager] Failed to create file: " + path)
			return false

	var content := FSM.read_file(path)
	var new_line := _format_key_line(key, value, fmt)
	var updated := _set_key_sectioned(content, section, key, new_line)
	if not FSM.write_file(path, updated):
		push_error("[ConfigManager] Failed to write file: " + path)
		return false
	return true

## Writes content to path. When only_if_missing is true, an existing file is
## left untouched (user edits preserved) and the call reports success.
static func write_config(path: String, content: String, only_if_missing := false) -> bool:
	if path.is_empty():
		return false
	if only_if_missing and FSM.file_exists(path):
		return true
	if not FSM.write_file(path, content):
		push_error("[ConfigManager] Failed to write file: " + path)
		return false
	return true

## Applies a set of text replacements to a config file.
## Each edit is a Dictionary with "old" and "new". Set "regex": true to treat
## "old" as a RegEx pattern. If create_if_missing is true, the file is created
## when it doesn't exist.
## If append_if_missing is provided, any key not already present is appended
## under the named section (or at the end of the file if section_name is empty).
static func edit_text(path: String, edits: Array, create_if_missing := false, append_if_missing: Dictionary = {}, section_name := "") -> bool:
	if path == "" or (edits.is_empty() and append_if_missing.is_empty()):
		push_error("[ConfigManager] Invalid arguments for edit_text")
		return false

	if not FSM.file_exists(path):
		if create_if_missing:
			FSM.make_dir_recursive(path.get_base_dir())
			if not FSM.write_file(path, ""):
				push_error("[ConfigManager] Failed to create file: " + path)
				return false
		else:
			push_error("[ConfigManager] File not found for editing: " + path)
			return false

	var content := FSM.read_file(path)
	# Empty content is allowed so missing keys can be appended later.

	for edit in edits:
		var old_text: String = edit.get("old", "")
		var new_text: String = edit.get("new", "")

		if old_text == "":
			continue

		if edit.get("regex", false):
			var regex := RegEx.new()
			var err := regex.compile(old_text)
			if err != OK:
				push_error("[ConfigManager] Invalid regex in edit: " + old_text)
				continue
			content = regex.sub(content, new_text, true)
		else:
			content = content.replace(old_text, new_text)

	# Append any missing keys so the caller doesn't have to do it manually.
	if not append_if_missing.is_empty():
		var missing: Array[String] = []
		for key in append_if_missing:
			var key_regex := RegEx.new()
			key_regex.compile(r'(?m)^%s\s*=' % _regex_escape(key))
			if key_regex.search(content) == null:
				missing.append(key)

		if not missing.is_empty():
			var has_section := true
			if section_name != "":
				var section_regex := RegEx.new()
				section_regex.compile(r"(?m)^\[%s\]\s*$" % _regex_escape(section_name))
				has_section = section_regex.search(content) != null

			if has_section:
				var lines := content.split("\n")
				var insert_at := lines.size()
				if section_name != "":
					var in_section := false
					for i in lines.size():
						var stripped := lines[i].strip_edges()
						if stripped == "[%s]" % section_name:
							in_section = true
							insert_at = i + 1
						elif in_section and stripped.begins_with("[") and stripped.ends_with("]"):
							insert_at = i
							break
						elif in_section:
							insert_at = i + 1
				for key in missing:
					lines.insert(insert_at, "%s = %s" % [key, append_if_missing[key]])
					insert_at += 1
				content = "\n".join(lines)
			else:
				if not content.is_empty() and not content.ends_with("\n"):
					content += "\n"
				content += "[%s]\n" % section_name
				for key in missing:
					content += '%s = %s\n' % [key, append_if_missing[key]]

	if not FSM.write_file(path, content):
		push_error("[ConfigManager] Failed to write edited file: " + path)
		return false

	return true

## Captures the current content of path so restore_backup() can revert it.
## Only the first capture sticks until a restore; subsequent calls are no-ops.
static func begin_backup(path: String) -> void:
	if path.is_empty() or _backups.has(path):
		return
	var original := ""
	if FSM.file_exists(path):
		original = FSM.read_file(path)
	_backups[path] = original

## Writes the content captured by begin_backup() back to path and drops it.
static func restore_backup(path: String) -> bool:
	if not _backups.has(path):
		return false
	var success := FSM.write_file(path, _backups[path])
	if success:
		_backups.erase(path)
	else:
		push_error("[ConfigManager] Failed to restore config file: " + path)
	return success

## Returns true when a backup exists for path.
static func has_backup(path: String) -> bool:
	return _backups.has(path)

## Parses key = value lines into {section: {key: value}}. When use_sections is
## false every key lands in the global "" section (CFG_KV). When typed_values
## is true, values are parsed as TOML scalars/arrays; otherwise surrounding
## quotes are stripped and the value stays a string.
static func _parse_kv_lines(content: String, use_sections: bool, typed_values: bool) -> Dictionary:
	var sections := {"": {}}
	var current := ""
	var key_regex := RegEx.new()
	key_regex.compile("^\\s*([^=\\s\\[#][^=]*?)\\s*=\\s*(.*)$")

	for line in content.split("\n"):
		var stripped := line.strip_edges()
		if stripped == "" or stripped.begins_with("#") or stripped.begins_with(";"):
			continue
		if use_sections and stripped.begins_with("[") and stripped.ends_with("]"):
			current = stripped.substr(1, stripped.length() - 2).strip_edges()
			if not sections.has(current):
				sections[current] = {}
			continue
		var m := key_regex.search(line)
		if m == null:
			continue
		var key := m.get_string(1).strip_edges()
		var raw := m.get_string(2).strip_edges()
		sections[current][key] = _parse_toml_value(_strip_toml_comment(raw)) if typed_values else _unquote(raw)

	return sections

## Cuts a TOML value at the first '#' outside a quoted string; per the
## TOML spec a comment runs to end of line. Double-quoted strings honor
## backslash escapes; single-quoted literal strings do not. Configs like
## xenia's annotate every line with a trailing comment; without this the
## comment text poisons the parsed value.
static func _strip_toml_comment(raw: String) -> String:
	var quote := ""
	var i := 0
	while i < raw.length():
		var c := raw[i]
		if quote == '"':
			if c == "\\":
				i += 2
				continue
			if c == '"':
				quote = ""
		elif quote == "'":
			if c == "'":
				quote = ""
		else:
			if c == '"' or c == "'":
				quote = c
			elif c == "#":
				return raw.substr(0, i).strip_edges()
		i += 1
	return raw.strip_edges()

## Strips one layer of surrounding double quotes from a value.
static func _unquote(value: String) -> String:
	value = value.strip_edges()
	if value.length() >= 2 and value.begins_with('"') and value.ends_with('"'):
		return value.substr(1, value.length() - 2)
	return value

## Parses a TOML subset value: quoted string (double-quoted basic or
## single-quoted literal), bool, int, float, or array.
static func _parse_toml_value(raw: String) -> Variant:
	raw = raw.strip_edges()
	if raw.length() >= 2 and raw.begins_with('"') and raw.ends_with('"'):
		return raw.substr(1, raw.length() - 2)
	if raw.length() >= 2 and raw.begins_with("'") and raw.ends_with("'"):
		return raw.substr(1, raw.length() - 2)
	if raw == "true":
		return true
	if raw == "false":
		return false
	if raw.is_valid_int():
		return raw.to_int()
	if raw.is_valid_float():
		return raw.to_float()
	if raw.begins_with("[") and raw.ends_with("]"):
		var items: Array = []
		var inner := raw.substr(1, raw.length() - 2).strip_edges()
		if inner != "":
			for part in inner.split(","):
				items.append(_parse_toml_value(part))
		return items
	return raw

## Formats one key line for the given format. CFG_KV quotes every value the way
## RetroArch writes them; INI writes raw; TOML writes typed values.
static func _format_key_line(key: String, value: Variant, format: int) -> String:
	match format:
		Format.CFG_KV:
			return '%s = "%s"' % [key, str(value)]
		Format.TOML:
			return '%s = %s' % [key, _format_toml_value(value)]
	return '%s = %s' % [key, str(value)]

## Formats a value for a TOML key line.
static func _format_toml_value(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT, TYPE_FLOAT:
			return str(value)
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY:
			var parts: Array = []
			for item in value:
				parts.append(_format_toml_value(item))
			return "[" + ", ".join(parts) + "]"
	return '"%s"' % str(value)

## Replaces the line assigning key inside the given section, or inserts it when
## absent. Section "" is the region before the first [header]; for files with
## no sections at all (CFG_KV) it is the whole file. Missing sections are
## appended. Everything outside the key's own line is preserved byte-for-byte,
## including the file's line-ending style.
static func _set_key_sectioned(text: String, section: String, key: String, new_line: String) -> String:
	var eol := "\r\n" if text.contains("\r\n") else "\n"
	var lines := text.split(eol)
	var key_regex := RegEx.new()
	key_regex.compile("^[ \\t]*" + _regex_escape(key) + "[ \\t]*=")
	var header_regex := RegEx.new()
	header_regex.compile("^[ \\t]*\\[")

	var region_start := 0
	var region_end := lines.size()
	var first_header := -1

	if section == "":
		for i in lines.size():
			if header_regex.search(lines[i]):
				first_header = i
				break
		if first_header >= 0:
			region_end = first_header
	else:
		var target_header := "[" + section + "]"
		var found := false
		for i in lines.size():
			if lines[i].strip_edges() == target_header:
				region_start = i + 1
				found = true
				for j in range(i + 1, lines.size()):
					if header_regex.search(lines[j]):
						region_end = j
						break
				break
		if not found:
			var out := text
			if not out.is_empty() and not out.ends_with(eol):
				out += eol
			out += target_header + eol + new_line + eol
			return out

	for i in range(region_start, region_end):
		if key_regex.search(lines[i]):
			lines[i] = new_line
			return eol.join(lines)

	# Key absent: insert at the end of the region. For a global region bounded
	# by a section header, insert just before it so the key stays global.
	var insert_at := region_end
	if section == "" and first_header >= 0:
		insert_at = first_header
	lines.insert(insert_at, new_line)
	return eol.join(lines)

## Escapes RegEx metacharacters so a literal key can be used in a pattern.
static func _regex_escape(text: String) -> String:
	var out := ""
	for i in text.length():
		var c := text.substr(i, 1)
		if c in "\\.+*?[](){}^$|":
			out += "\\"
		out += c
	return out
