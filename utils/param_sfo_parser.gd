## PARAM.SFO Parser for PS3 Games
## Parses PlayStation 3 PARAM.SFO files to extract game metadata
## Format: SCEI SFO format used by PS3, PSP, Vita

class_name ParamSFOParser

## Reads a PARAM.SFO file and returns a dictionary with all fields
## Returns empty dictionary if file cannot be parsed
static func read_sfo(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[ParamSFOParser] File not found: " + path)
		return {}
	
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("[ParamSFOParser] Failed to open file: " + path)
		return {}
	
	var data := file.get_buffer(file.get_length())
	file.close()
	
	# Check minimum file size (header is 20 bytes)
	if data.size() < 20:
		push_error("[ParamSFOParser] File too small: " + str(data.size()) + " bytes")
		return {}
	
	# Parse header
	var pos := 0
	var magic := data.decode_u32(pos)
	pos += 4
	
	# Magic should be "PSF\0" = 0x46535000 (little-endian)
	# Note: Some sources say 0x53434500 (SCE) but actual files use 0x46535000 (PSF)
	if magic != 0x46535000:
		push_error("[ParamSFOParser] Invalid magic: 0x" + String.num_uint64(magic, 16) + " (expected 0x46535000 for PSF)")
		return {}
	
	var version := data.decode_u32(pos)
	pos += 4
	
	var key_table_offset := data.decode_u32(pos)
	pos += 4
	
	var data_table_offset := data.decode_u32(pos)
	pos += 4
	
	var num_entries := data.decode_u32(pos)
	pos += 4
	
	print("[ParamSFOParser] Header: version=" + str(version) + ", entries=" + str(num_entries))
	print("[ParamSFOParser] Key table at offset " + str(key_table_offset) + ", data table at offset " + str(data_table_offset))
	
	# Read index table entries
	var entries := []
	for i in range(num_entries):
		if pos + 16 > data.size():
			push_error("[ParamSFOParser] Unexpected end of file reading entry " + str(i))
			break
		
		var entry := {}
		entry["key_offset"] = data.decode_u16(pos)
		pos += 2
		entry["data_fmt"] = data.decode_u16(pos)
		pos += 2
		entry["data_len"] = data.decode_u32(pos)
		pos += 4
		entry["data_max_len"] = data.decode_u32(pos)
		pos += 4
		entry["data_offset"] = data.decode_u32(pos)
		pos += 4
		
		entries.append(entry)
	
	# Read key table (null-terminated strings)
	var keys := {}
	var key_pos := key_table_offset
	var key_index := 0
	
	while key_pos < data_table_offset and key_index < entries.size():
		var key_name := ""
		while key_pos < data.size() and data[key_pos] != 0:
			key_name += char(data[key_pos])
			key_pos += 1
		key_pos += 1  # Skip null terminator
		
		if key_name != "":
			keys[key_index] = key_name
			key_index += 1
	
	# Read data table values
	var result: Dictionary = {}
	for i in range(entries.size()):
		if i >= keys.size():
			break
		
		var entry: Dictionary = entries[i]
		var key_name: String = keys.get(i, "unknown_" + str(i))
		var data_pos: int = data_table_offset + int(entry["data_offset"])
		
		# Read data as raw bytes regardless of format - this handles all PARAM.SFO formats
		var value: String = ""
		var max_read: int = mini(entry["data_len"], data.size() - data_pos)
		for j in range(max_read):
			var byte_val: int = data[data_pos + j]
			if byte_val == 0:
				break
			# Only include printable ASCII characters
			if byte_val >= 32 and byte_val < 127:
				value += char(byte_val)
			else:
				break
		
		result[key_name] = value
	
	return result


## Extracts the TitleID from a PARAM.SFO file
## Returns empty string if TitleID cannot be found
static func get_title_id(path: String) -> String:
	print("[ParamSFOParser] get_title_id called for: " + path)
	
	var sfo_data := read_sfo(path)
	if sfo_data.is_empty():
		print("[ParamSFOParser] read_sfo returned empty data")
		return ""
	
	print("[ParamSFOParser] SFO data keys: " + str(sfo_data.keys()))
	
	# TitleID is stored in the "TITLE_ID" field
	var title_id: String = sfo_data.get("TITLE_ID", "")
	print("[ParamSFOParser] TITLE_ID value: '" + title_id + "'")
	
	if title_id == "" or title_id == "<binary>":
		# Try alternative field names
		title_id = sfo_data.get("title_id", "")
		if title_id != "":
			print("[ParamSFOParser] Found title_id (lowercase): '" + title_id + "'")
	
	return title_id


## Extracts the game title from a PARAM.SFO file
## Returns empty string if title cannot be found  
static func get_title(path: String) -> String:
	var sfo_data := read_sfo(path)
	if sfo_data.is_empty():
		return ""
	
	# Title is stored in the "TITLE" field
	var title: String = sfo_data.get("TITLE", "")
	
	if title == "" or title == "<binary>":
		# Try shorter title field
		title = sfo_data.get("STITLE", "")
	
	return title
