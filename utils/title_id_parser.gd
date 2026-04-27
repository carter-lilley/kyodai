## Unified title ID / serial parser for all platforms
## Extracts game identifiers from ROM files for save sync purposes
class_name TitleIDParser

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

## Opens a file for reading and calls the callback. Handles error checking and cleanup.
## Returns the callback's result, or empty string on failure.
static func _with_open_file(path: String, callback: Callable) -> String:
	if not FileSystemManager.file_exists(path):
		push_error("[TitleIDParser] File not found: " + path)
		return ""
	
	var file = FileSystemManager.open_file_read(path)
	if not file:
		push_error("[TitleIDParser] Failed to open file: " + path)
		return ""
	
	var result = callback.call(file)
	file.close()
	return result

## Reads a specific byte range from a file.
## Opens the file, seeks to the offset, and reads the requested length.
## Returns the bytes read, or empty array on failure.
static func _read_file_range(path: String, offset: int, length: int) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		push_error("[TitleIDParser] File not found: " + path)
		return PackedByteArray()
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("[TitleIDParser] Failed to open file: " + path)
		return PackedByteArray()
	
	file.seek(offset)
	var bytes = file.get_buffer(length)
	file.close()
	return bytes

## Converts a PackedByteArray to a hex string
static func _bytes_to_hex(bytes: PackedByteArray) -> String:
	var hex = ""
	for b in bytes:
		hex += "%02x" % b
	return hex

## Verifies magic bytes at a specific offset in a buffer
static func _verify_magic(buffer: PackedByteArray, offset: int, expected: String) -> bool:
	if buffer.size() < offset + expected.length():
		return false
	return buffer.slice(offset, offset + expected.length()).get_string_from_ascii() == expected

## Reads little-endian uint16 from byte array
static func _read_le16(bytes: PackedByteArray, offset: int) -> int:
	return bytes.decode_u16(offset)

## Reads little-endian uint32 from byte array
static func _read_le32(bytes: PackedByteArray, offset: int) -> int:
	return bytes.decode_u32(offset)

## Reads little-endian uint64 from byte array
static func _read_le64(bytes: PackedByteArray, offset: int) -> int:
	return bytes.decode_u64(offset)

## Reads big-endian uint16 from byte array
static func _read_be16(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 8) | bytes[offset + 1]

## Reads big-endian uint32 from byte array
static func _read_be32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]

## Reads a null-terminated string from a byte array starting at offset
static func _read_cstring(bytes: PackedByteArray, offset: int) -> String:
	var end = offset
	while end < bytes.size() and bytes[end] != 0:
		end += 1
	if end > offset:
		return bytes.slice(offset, end).get_string_from_ascii()
	return ""

## Returns the minimum of two integers
static func mini(a: int, b: int) -> int:
	return a if a < b else b

## Resolves a ZIP file path for opening with ZIPReader
## Handles Godot virtual paths, globalizes them, and tries Windows backslashes
## Returns the resolved path or empty string if file cannot be found
static func _resolve_zip_path(zip_path: String) -> String:
	# On Windows, prefer backslash paths for ZIPReader compatibility
	if OS.get_name() == "Windows":
		var backslash_path = zip_path.replace("/", "\\")
		if FileSystemManager.file_exists(backslash_path):
			return backslash_path
	
	# Try original path
	if FileSystemManager.file_exists(zip_path):
		return zip_path
	
	# Try absolute path (resolves user://, res://, etc.)
	var abs_path = FileSystemManager.resolve_path(zip_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	if abs_path != zip_path and FileSystemManager.file_exists(abs_path):
		return abs_path
	
	return ""

# ============================================================================
# PLATFORM-SPECIFIC EXTRACTORS
# ============================================================================

# ==================== 3DS (Azahar) ====================

static func extract_3ds_title_id(rom_path: String) -> String:
	var header = _read_file_range(rom_path, 0, 0x200)
	if header.size() < 0x200:
		push_error("[TitleIDParser] 3DS ROM too small: " + rom_path)
		return ""
	
	var title_id_val = 0
	
	if _verify_magic(header, 0x100, "NCCH"):
		title_id_val = _read_le64(header, 0x118)
	elif _verify_magic(header, 0x100, "NCSD"):
		title_id_val = _read_le64(header, 0x108)
	elif _verify_magic(header, 0x0, "NCSD"):
		title_id_val = _read_le64(header, 0x008)
	else:
		push_error("[TitleIDParser] Unknown 3DS ROM format: " + rom_path)
		return ""
	
	return "%016x" % title_id_val

# ==================== Wii U (Cemu) ====================

static func extract_wiiu_title_id(rom_path: String) -> String:
	var file_size = FileSystemManager.get_file_size(rom_path)
	if file_size <= 0:
		return ""
	
	var tail_size = mini(file_size, 262144)
	var tail = _read_file_range(rom_path, file_size - tail_size, tail_size)
	if tail.is_empty():
		return ""
	
	for i in range(tail.size() - 20):
		if tail[i] == 95 and tail[i + 1] == 118:
			var j = i + 2
			while j < tail.size() and tail[j] >= 48 and tail[j] <= 57:
				j += 1
			
			if j > i + 2 and i >= 16:
				var is_hex = true
				var title_id = ""
				for k in range(i - 16, i):
					var c = tail[k]
					if (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70):
						title_id += char(c)
					else:
						is_hex = false
						break
				
				if is_hex and title_id.length() == 16:
					return title_id.to_lower()
	
	return ""

# ==================== Switch (Eden) ====================

static func _read_prod_keys_header_key(emulator_dir: String) -> String:
	var keys_path = ""
	
	if PlatformManager.is_android():
		keys_path = "/storage/emulated/0/Android/data/dev.eden.eden_emulator/files/keys/prod.keys"
	else:
		keys_path = emulator_dir.rstrip("/") + "/user/keys/prod.keys"
	
	if not FileSystemManager.file_exists(keys_path):
		return ""
	
	var content = FileSystemManager.read_file(keys_path)
	if content == "":
		return ""
	
	var lines = content.split("\n")
	for i in range(lines.size()):
		var line = lines[i].strip_edges()
		if line.begins_with("header_key ="):
			var parts = line.split("=", false, 1)
			if parts.size() == 2:
				var key = parts[1].strip_edges().replace(" ", "").replace("\t", "")
				if key == "" and i + 1 < lines.size():
					key = lines[i + 1].strip_edges().replace(" ", "").replace("\t", "")
				if key.length() == 64:
					return key
	return ""

static func _aes_xts_decrypt(data: PackedByteArray, key: PackedByteArray, sector_size: int, sector_start: int) -> PackedByteArray:
	var key1 = key.slice(0, 16)
	var key2 = key.slice(16, 32)
	
	var aes_tweak = AESContext.new()
	aes_tweak.start(AESContext.MODE_ECB_ENCRYPT, key2)
	
	var aes_data = AESContext.new()
	aes_data.start(AESContext.MODE_ECB_DECRYPT, key1)
	
	var result = PackedByteArray()
	result.resize(data.size())
	
	var sectors = data.size() / sector_size
	for sector in range(sectors):
		var sector_data = data.slice(sector * sector_size, (sector + 1) * sector_size)
		
		var tweak_block = PackedByteArray()
		tweak_block.resize(16)
		tweak_block[8] = (sector_start + sector) >> 56
		tweak_block[9] = ((sector_start + sector) >> 48) & 0xFF
		tweak_block[10] = ((sector_start + sector) >> 40) & 0xFF
		tweak_block[11] = ((sector_start + sector) >> 32) & 0xFF
		tweak_block[12] = ((sector_start + sector) >> 24) & 0xFF
		tweak_block[13] = ((sector_start + sector) >> 16) & 0xFF
		tweak_block[14] = ((sector_start + sector) >> 8) & 0xFF
		tweak_block[15] = (sector_start + sector) & 0xFF
		
		var t = aes_tweak.update(tweak_block)
		var blocks = sector_size / 16
		
		for block in range(blocks):
			var block_data = PackedByteArray()
			block_data.resize(16)
			for j in range(16):
				block_data[j] = sector_data[block * 16 + j] ^ t[j]
			
			var decrypted = aes_data.update(block_data)
			for j in range(16):
				result[sector * sector_size + block * 16 + j] = decrypted[j] ^ t[j]
			
			# Galois multiply tweak by x (shift left, conditional XOR)
			var carry = 0
			for j in range(16):
				var new_carry = t[j] >> 7
				t[j] = ((t[j] << 1) | carry) & 0xFF
				carry = new_carry
			if carry:
				t[0] ^= 0x87
	
	return result

static func _parse_hfs0(file: FileAccess, offset: int) -> Dictionary:
	var result = {"valid": false, "file_count": 0, "entries": []}
	
	file.seek(offset)
	var header = file.get_buffer(0x10)
	if header.size() < 0x10:
		return result
	
	var magic = header.slice(0, 4).get_string_from_ascii()
	if magic != "HFS0":
		return result
	
	var file_count = header.decode_u32(0x04)
	var string_table_size = header.decode_u32(0x08)
	
	if file_count == 0:
		result.valid = true
		return result
	
	var entries = []
	for i in range(file_count):
		var entry = file.get_buffer(0x40)
		if entry.size() < 0x40:
			return result
		
		var rel_off = entry.decode_u64(0x00)
		var size = entry.decode_u64(0x08)
		var str_off = entry.decode_u32(0x10)
		entries.append({
			"rel_offset": rel_off,
			"size": size,
			"string_offset": str_off
		})
	
	file.seek(offset + 0x10 + file_count * 0x40)
	var string_table = file.get_buffer(string_table_size)
	
	var data_start = offset + 0x10 + file_count * 0x40 + string_table_size
	
	for i in range(entries.size()):
		var str_off = entries[i].string_offset
		var name_end = str_off
		while name_end < string_table.size() and string_table[name_end] != 0:
			name_end += 1
		entries[i].name = string_table.slice(str_off, name_end).get_string_from_ascii()
		entries[i].offset = data_start + entries[i].rel_offset
	
	result.valid = true
	result.file_count = file_count
	result.entries = entries
	return result

static func extract_xci_title_id(rom_path: String, emulator_dir: String) -> String:
	if not FileSystemManager.file_exists(rom_path):
		return ""
	
	var header_key_hex = _read_prod_keys_header_key(emulator_dir)
	if header_key_hex == "":
		return ""
	
	var header_key = PackedByteArray()
	for i in range(0, header_key_hex.length(), 2):
		header_key.append(header_key_hex.substr(i, 2).hex_to_int())
	if header_key.size() != 32:
		return ""
	
	return _with_open_file(rom_path, func(file: FileAccess) -> String:
		file.seek(0x130)
		var hfs0_offset = file.get_64()
		var hfs0_size = file.get_64()
		
		var root = _parse_hfs0(file, hfs0_offset)
		if not root.valid:
			return ""
		
		var secure_offset = -1
		for entry in root.entries:
			if entry.name == "secure":
				secure_offset = entry.offset
				break
		
		if secure_offset < 0:
			return ""
		
		var secure = _parse_hfs0(file, secure_offset)
		if not secure.valid or secure.entries.is_empty():
			return ""
		
		var largest_idx = -1
		var largest_size = 0
		for i in range(secure.entries.size()):
			if secure.entries[i].size > largest_size:
				largest_size = secure.entries[i].size
				largest_idx = i
		
		if largest_idx < 0:
			return ""
		
		var nca_offset = secure.entries[largest_idx].offset
		file.seek(nca_offset)
		var nca_header = file.get_buffer(0x400)
		
		if nca_header.size() < 0x400:
			return ""
		
		var decrypted = _aes_xts_decrypt(nca_header, header_key, 0x200, 0)
		
		var magic = decrypted.slice(0x200, 0x204).get_string_from_ascii()
		if magic != "NCA3" and magic != "NCA2" and magic != "NCA1" and magic != "NCA0":
			return ""
		
		var title_id = ""
		for i in range(7, -1, -1):
			title_id += "%02x" % decrypted[0x210 + i]
		title_id = title_id.to_upper()
		
		if title_id.begins_with("01") and title_id.length() == 16:
			return title_id
		
		var rights_id_empty = true
		for b in range(16):
			if decrypted[0x230 + b] != 0:
				rights_id_empty = false
				break
		if not rights_id_empty:
			title_id = ""
			for i in range(7, -1, -1):
				title_id += "%02x" % decrypted[0x230 + i]
			title_id = title_id.to_upper()
			if title_id.begins_with("01") and title_id.length() == 16:
				return title_id
		
		return ""
	)

static func extract_switch_title_id(rom_path: String, emulator_dir: String) -> String:
	if not FileSystemManager.file_exists(rom_path):
		print("[TitleIDParser] extract_switch_title_id: file not found: " + rom_path)
		return ""
	
	var ext = rom_path.get_extension().to_lower()
	print("[TitleIDParser] extract_switch_title_id: ext=" + ext + ", rom=" + rom_path.get_file())
	
	if ext == "xci":
		return extract_xci_title_id(rom_path, emulator_dir)
	
	if ext in ["nsp", "nsz"]:
		return _with_open_file(rom_path, func(file: FileAccess) -> String:
			var header = file.get_buffer(0x2000)
			print("[TitleIDParser] NSP header size: " + str(header.size()))
			
			if header.size() < 0x10:
				print("[TitleIDParser] NSP header too small")
				return ""
			
			var magic = header.slice(0, 4).get_string_from_ascii()
			print("[TitleIDParser] NSP magic: " + magic)
			if magic != "PFS0":
				print("[TitleIDParser] NSP magic mismatch, expected PFS0")
				return ""
			
			var file_count = header.decode_u32(0x04)
			var string_table_size = header.decode_u32(0x08)
			print("[TitleIDParser] NSP file_count=" + str(file_count) + ", string_table_size=" + str(string_table_size))
			
			var entries_size = file_count * 0x18
			var total_header = 0x10 + entries_size + string_table_size
			
			if header.size() < total_header:
				print("[TitleIDParser] NSP header size " + str(header.size()) + " < total_header " + str(total_header))
				return ""
			
			var string_table_offset = 0x10 + entries_size
			var filenames: Array[String] = []
			
			for i in range(file_count):
				var entry_offset = 0x10 + (i * 0x18)
				var string_offset = header.decode_u32(entry_offset + 0x10)
				var name_start = string_table_offset + string_offset
				
				var name_end = name_start
				while name_end < total_header and header[name_end] != 0:
					name_end += 1
				
				var filename = header.slice(name_start, name_end).get_string_from_ascii()
				filenames.append(filename)
			
			print("[TitleIDParser] NSP filenames: " + str(filenames))
			
			for i in range(file_count):
				var filename = filenames[i]
				if filename.to_lower().ends_with(".tik"):
					var basename = filename.get_basename()
					print("[TitleIDParser] Found .tik: " + filename + ", basename=" + basename)
					
					# .tik files use rights_id (32 hex chars), TitleID is first 16 chars
					var possible_ids: Array[String] = []
					if basename.length() == 32:
						possible_ids.append(basename.substr(0, 16))
					elif basename.length() == 16:
						possible_ids.append(basename)
					
					for possible_id in possible_ids:
						var is_hex = true
						for c in possible_id:
							if not ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')):
								is_hex = false
								break
						if is_hex and possible_id.to_upper().begins_with("01"):
							print("[TitleIDParser] Returning TitleID from .tik: " + possible_id.to_upper())
							return possible_id.to_upper()
			
			var header_key_hex = _read_prod_keys_header_key(emulator_dir)
			print("[TitleIDParser] header_key_hex length: " + str(header_key_hex.length()))
			if header_key_hex != "":
				var header_key = PackedByteArray()
				for i in range(0, header_key_hex.length(), 2):
					header_key.append(header_key_hex.substr(i, 2).hex_to_int())
				
				print("[TitleIDParser] header_key size: " + str(header_key.size()))
				if header_key.size() == 32:
					for i in range(file_count):
						var filename = filenames[i]
						if filename.to_lower().ends_with(".nca"):
							var nca_offset = header.decode_u64(0x10 + (i * 0x18))
							var nca_size = header.decode_u64(0x10 + (i * 0x18) + 0x08)
							
							file.seek(nca_offset)
							var nca_header = file.get_buffer(0x400)
							
							print("[TitleIDParser] Trying NCA: " + filename + ", offset=" + str(nca_offset) + ", header_size=" + str(nca_header.size()))
							if nca_header.size() >= 0x400:
								var decrypted = _aes_xts_decrypt(nca_header, header_key, 0x200, 0)
								var nca_magic = decrypted.slice(0x200, 0x204).get_string_from_ascii()
								print("[TitleIDParser] NCA magic: " + nca_magic)
								if nca_magic == "NCA3" or nca_magic == "NCA2" or nca_magic == "NCA1" or nca_magic == "NCA0":
									var nca_title_id = ""
									for j in range(7, -1, -1):
										nca_title_id += "%02x" % decrypted[0x210 + j]
									nca_title_id = nca_title_id.to_upper()
									print("[TitleIDParser] Found TitleID in NCA: " + nca_title_id)
									if nca_title_id.begins_with("01") and nca_title_id.length() == 16:
										return nca_title_id
			else:
				print("[TitleIDParser] No header key found")
			
			return ""
		)
	
	return ""

# ==================== GameCube/Wii (Dolphin) ====================

static func _is_valid_gamecube_game_id(game_id: String) -> bool:
	if game_id.length() != 4:
		return false
	for c in game_id:
		if not ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')):
			return false
	return true

static func _is_valid_maker_code(maker: String) -> bool:
	if maker.length() != 2:
		return false
	for c in maker:
		if not ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')):
			return false
	return true

static func extract_gamecube_game_id(rom_path: String) -> String:
	var file_size = FileSystemManager.get_file_size(rom_path)
	if file_size <= 0:
		return ""
	
	var scan_size = mini(file_size, 1048576)
	var data = _read_file_range(rom_path, 0, scan_size)
	if data.is_empty():
		return ""
	
	for i in range(data.size() - 20):
		var game_id = data.slice(i, i + 4).get_string_from_ascii()
		var maker = data.slice(i + 4, i + 6).get_string_from_ascii()
		
		if not _is_valid_gamecube_game_id(game_id) or not _is_valid_maker_code(maker):
			continue
		
		var disc_number = data[i + 6]
		var version = data[i + 7]
		var audio_streaming = data[i + 8]
		var stream_buffer_size = data[i + 9]
		
		if disc_number <= 1 and version <= 2 and audio_streaming <= 1 and stream_buffer_size <= 0x40:
			return game_id
	
	return ""

static func extract_gamecube_game_id_from_existing_saves(emulator_dir: String) -> String:
	var regions: Array[String] = ["USA", "EUR", "JAP", "KOR"]
	for region in regions:
		var card_dirs: Array[String] = ["Card A", "Card B"]
		for card in card_dirs:
			var card_path = emulator_dir.rstrip("/") + "/User/GC/" + region + "/" + card + "/"
			if not FileSystemManager.dir_exists(card_path):
				continue
			var items = FileSystemManager.list_dir(card_path)
			for item in items:
				if item == "." or item == "..":
					continue
				if item.to_lower().ends_with(".gci"):
					var gci_path = card_path + item
					var result = _with_open_file(gci_path, func(file: FileAccess) -> String:
						var header = file.get_buffer(6)
						if header.size() < 6:
							return ""
						var game_id = header.slice(0, 4).get_string_from_ascii()
						var maker = header.slice(4, 6).get_string_from_ascii()
						if _is_valid_gamecube_game_id(game_id) and _is_valid_maker_code(maker):
							return game_id
						return ""
					)
					if result != "":
						return result
	return ""

# ==================== Vita (Vita3K) ====================

static func extract_vita_title_id(zip_path: String) -> String:
	# Resolve ZIP path with fallbacks for Godot virtual paths and Windows backslashes
	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		push_error("[TitleIDParser] Cannot extract TitleID - file not found: " + zip_path)
		return ""
	zip_path = resolved_path
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK:
		push_error("[TitleIDParser] Failed to open ZIP for TitleID extraction: " + zip_path + " (error: " + str(err) + ")")
		return ""
	
	var files = reader.get_files()
	reader.close()
	
	if files.is_empty():
		push_error("[TitleIDParser] ZIP is empty: " + zip_path)
		return ""
	
	var first_file = files[0]
	var parts = first_file.split("/")
	if parts.is_empty():
		push_error("[TitleIDParser] Invalid ZIP structure: " + zip_path)
		return ""
	
	return parts[0]

# ==================== Xbox 360 (Xenia) ====================

const _XEX_SECTOR_SIZE = 2048
const _GDFX_MAGIC = "MICROSOFT*XBOX*MEDIA"
const _XEX_HEADER_EXECUTION_INFO = 0x00040006

## Extracts Xbox 360 Title ID from an ISO file
## Parses the GDFX filesystem to find default.xex, then extracts Title ID from XEX header
## Returns 8-character hex string (e.g., "545407DF")
static func extract_xbox360_title_id(iso_path: String) -> String:
	return _with_open_file(iso_path, func(file: FileAccess) -> String:
		print("[TitleIDParser] Parsing Xbox 360 ISO: " + iso_path)
		
		# Step 1: Find GDFX partition
		var game_offset = _find_gdfx_partition(file)
		if game_offset < 0:
			push_error("[TitleIDParser] Failed to find GDFX partition in Xbox 360 ISO: " + iso_path)
			return ""
		
		print("[TitleIDParser] GDFX partition found at offset: 0x" + "%x" % game_offset)
		
		# Step 2: Read root directory info from sector 32
		file.seek(game_offset + (32 * _XEX_SECTOR_SIZE) + 20)
		var root_sector_bytes = file.get_buffer(4)
		var root_size_bytes = file.get_buffer(4)
		
		if root_sector_bytes.size() < 4 or root_size_bytes.size() < 4:
			push_error("[TitleIDParser] Failed to read GDFX root directory info")
			return ""
		
		var root_sector = _read_le32(root_sector_bytes, 0)
		var root_size = _read_le32(root_size_bytes, 0)
		var root_offset = game_offset + (root_sector * _XEX_SECTOR_SIZE)
		
		print("[TitleIDParser] GDFX root directory: sector=" + str(root_sector) + ", size=" + str(root_size) + ", offset=0x" + "%x" % root_offset)
		
		# Validate root directory is within file bounds
		if root_offset > file.get_length():
			push_error("[TitleIDParser] GDFX root directory offset exceeds file size")
			return ""
		
		# Step 3: Parse directory tree to find default.xex
		print("[TitleIDParser] Searching for default.xex in GDFX directory tree...")
		var xex_entry = _find_file_in_gdfx(file, game_offset, root_offset, "default.xex")
		
		# Step 4: If default.xex not found, try GameInfo.bin (XNA/Indie games)
		if xex_entry.is_empty():
			print("[TitleIDParser] default.xex not found, trying GameInfo.bin...")
			var gameinfo_entry = _find_file_in_gdfx(file, game_offset, root_offset, "GameInfo.bin")
			if not gameinfo_entry.is_empty():
				var title_id = _parse_gameinfo_title_id(file, gameinfo_entry)
				if title_id != "":
					print("[TitleIDParser] Xbox 360 Title ID found from GameInfo.bin: " + title_id.to_upper())
					return title_id.to_upper()
			
			push_error("[TitleIDParser] Failed to find default.xex or GameInfo.bin in Xbox 360 ISO")
			return ""
		
		print("[TitleIDParser] Found default.xex at offset 0x" + "%x" % xex_entry["offset"] + ", length=" + str(xex_entry["length"]))
		
		# Step 5: Read XEX header and extract Title ID
		var title_id = _read_xex_title_id(file, xex_entry["offset"], xex_entry["length"])
		
		if title_id != "":
			print("[TitleIDParser] Xbox 360 Title ID found: " + title_id.to_upper())
			return title_id.to_upper()
		
		push_error("[TitleIDParser] Failed to extract Title ID from XEX in Xbox 360 ISO")
		return ""
	)

## Searches for GDFX partition by looking for "MICROSOFT*XBOX*MEDIA" magic at known offsets
## Returns the game partition base offset, or -1 if not found
static func _find_gdfx_partition(file: FileAccess) -> int:
	var likely_offsets = [0x00000000, 0x0000FB20, 0x00020600, 0x02080000, 0x0FD90000]
	var file_size = file.get_length()
	
	for base_offset in likely_offsets:
		var magic_offset = base_offset + (32 * _XEX_SECTOR_SIZE)
		if magic_offset >= file_size:
			continue
		
		file.seek(magic_offset)
		var magic = file.get_buffer(20)
		if magic.size() < 20:
			continue
		
		var magic_str = magic.get_string_from_ascii()
		if magic_str == _GDFX_MAGIC:
			return base_offset
	
	return -1

## Recursively searches GDFX directory tree for a file by name
## Returns dictionary with "offset", "length", "attributes" or empty dictionary if not found
static func _find_file_in_gdfx(file: FileAccess, game_offset: int, dir_offset: int, filename: String) -> Dictionary:
	var result = {}
	var max_depth = 100  # Prevent infinite loops
	
	# Use a stack for iterative tree traversal
	# Each entry is [buffer_offset, parent_dir_offset]
	var stack = [[0, dir_offset]]
	var depth = 0
	
	while not stack.is_empty() and depth < max_depth:
		var current = stack.pop_back()
		var entry_ordinal = current[0]
		var buffer_offset = current[1]
		
		file.seek(buffer_offset + (entry_ordinal * 4))
		var entry_data = file.get_buffer(14)
		if entry_data.size() < 14:
			continue
		
		# GDFX directory entries are little-endian
		var node_l = entry_data.decode_u16(0)
		var node_r = entry_data.decode_u16(2)
		var sector = entry_data.decode_u32(4)
		var length = entry_data.decode_u32(8)
		var attributes = entry_data[12]
		var name_length = entry_data[13]
		
		# Read filename
		var name_bytes = file.get_buffer(name_length)
		if name_bytes.size() < name_length:
			continue
		var name = name_bytes.get_string_from_ascii()
		
		# Check if this is our target file
		if name.to_lower() == filename.to_lower():
			if not (attributes & 0x10):  # Not a directory
				result = {
					"offset": game_offset + (sector * _XEX_SECTOR_SIZE),
					"length": length,
					"attributes": attributes
				}
				return result
		
		# If directory and has children, add to stack
		if (attributes & 0x10) and length > 0 and name != "" and name != "." and name != "..":
			var child_offset = game_offset + (sector * _XEX_SECTOR_SIZE)
			stack.append([0, child_offset])
		
		# Add siblings to stack (right child)
		if node_r != 0:
			stack.append([node_r, buffer_offset])
		
		# Add left child to stack
		if node_l != 0:
			stack.append([node_l, buffer_offset])
		
		depth += 1
	
	return result

## Reads Title ID from XEX file
## XEX structure: magic "XEX2" at 0x0, header_count at 0x14, headers[] at 0x18
## Looks for XEX_HEADER_EXECUTION_INFO (0x00040006) and reads title_id at offset + 0x0C
static func _read_xex_title_id(file: FileAccess, xex_offset: int, xex_length: int) -> String:
	if xex_length < 0x20:
		push_error("[TitleIDParser] XEX file too small")
		return ""
	
	file.seek(xex_offset)
	var xex_header = file.get_buffer(0x18)
	if xex_header.size() < 0x18:
		push_error("[TitleIDParser] Failed to read XEX header")
		return ""
	
	var magic = xex_header.slice(0, 4).get_string_from_ascii()
	if magic != "XEX2" and magic != "XEX1":
		push_error("[TitleIDParser] Invalid XEX magic: " + magic)
		return ""
	
	var header_count = _read_be32(xex_header, 0x14)
	if header_count == 0 or header_count > 100:
		push_error("[TitleIDParser] Invalid XEX header count: " + str(header_count))
		return ""
	
	# Read optional headers
	file.seek(xex_offset + 0x18)
	for i in range(header_count):
		var opt_header = file.get_buffer(8)
		if opt_header.size() < 8:
			break
		
		var key = _read_be32(opt_header, 0)
		var value = _read_be32(opt_header, 4)
		
		# Check if this is XEX_HEADER_EXECUTION_INFO
		if key == _XEX_HEADER_EXECUTION_INFO:
			# For key 0x00040006, value is an offset from XEX header start
			var exec_info_offset = xex_offset + value
			file.seek(exec_info_offset + 0x0C)  # Title ID is at +0x0C in execution info
			var title_id_bytes = file.get_buffer(4)
			if title_id_bytes.size() < 4:
				return ""
			
			var title_id = ""
			for b in title_id_bytes:
				title_id += "%02x" % b
			
			if title_id.length() == 8:
				return title_id
	
	return ""

## Parses GameInfo.bin to extract Title ID (for XNA/Indie games)
## GameInfo.bin structure: Starts with "XGI1" magic, Title ID at offset 0x14
static func _parse_gameinfo_title_id(file: FileAccess, entry: Dictionary) -> String:
	if entry.is_empty() or entry["length"] < 0x18:
		return ""
	
	file.seek(entry["offset"])
	var header = file.get_buffer(4)
	if header.size() < 4:
		return ""
	
	var magic = header.get_string_from_ascii()
	if magic != "XGI1":
		return ""
	
	# Title ID is at offset 0x14 in GameInfo.bin
	file.seek(entry["offset"] + 0x14)
	var title_id_bytes = file.get_buffer(4)
	if title_id_bytes.size() < 4:
		return ""
	
	var title_id = ""
	for b in title_id_bytes:
		title_id += "%02x" % b
	
	if title_id.length() == 8:
		return title_id
	
	return ""

# ==================== PS2 (PCSX2) ====================
# ISO9660 and CHD parsing for PS2 disc images

const _ISO_SECTOR_SIZE = 2048
const _ISO_PVD_SECTOR = 16

static func _iso_read_pvd(file: FileAccess) -> Dictionary:
	var result = {
		"valid": false,
		"root_lba": 0,
		"root_length": 0
	}
	
	file.seek(_ISO_PVD_SECTOR * _ISO_SECTOR_SIZE)
	var pvd = file.get_buffer(_ISO_SECTOR_SIZE)
	
	if pvd.size() < _ISO_SECTOR_SIZE:
		push_error("[TitleIDParser] ISO PVD sector too small")
		return result
	
	if pvd[0] != 0x01:
		push_error("[TitleIDParser] ISO invalid descriptor type: " + str(pvd[0]))
		return result
	
	var sig = pvd.slice(1, 6).get_string_from_ascii()
	if sig != "CD001":
		push_error("[TitleIDParser] ISO invalid PVD signature: " + sig)
		return result
	
	result.root_lba = pvd.decode_u32(156 + 2)
	result.root_length = pvd.decode_u32(156 + 10)
	result.valid = true
	
	return result

static func _iso_find_file(file: FileAccess, dir_lba: int, dir_length: int, target_name: String) -> Dictionary:
	var result = {
		"found": false,
		"lba": 0,
		"length": 0
	}
	
	var bytes_read = 0
	var current_sector = dir_lba
	
	while bytes_read < dir_length:
		file.seek(current_sector * _ISO_SECTOR_SIZE)
		var sector = file.get_buffer(_ISO_SECTOR_SIZE)
		
		if sector.size() < _ISO_SECTOR_SIZE:
			break
		
		var offset = 0
		while offset < _ISO_SECTOR_SIZE:
			var entry_length = sector[offset]
			if entry_length == 0:
				break
			
			var name_length = sector[offset + 32]
			var name_bytes = sector.slice(offset + 33, offset + 33 + name_length)
			var name = name_bytes.get_string_from_ascii()
			
			var semicolon = name.find(";")
			if semicolon >= 0:
				name = name.substr(0, semicolon)
			
			if name.to_upper() == target_name.to_upper():
				result.found = true
				result.lba = sector.decode_u32(offset + 2)
				result.length = sector.decode_u32(offset + 10)
				return result
			
			offset += entry_length
		
		bytes_read += _ISO_SECTOR_SIZE
		current_sector += 1
	
	return result

static func _iso_extract_serial_from_cnf(cnf_content: String) -> String:
	var regex = RegEx.new()
	regex.compile(r"BOOT2\s*=\s*cdrom0:\\\\?([A-Z]{4})[_.](\d{3})\.(\d{2});")
	
	var match = regex.search(cnf_content)
	if match:
		return match.get_string(1) + "-" + match.get_string(2) + match.get_string(3)
	
	return ""

static func _iso_extract_ps2_serial(rom_path: String) -> String:
	return _with_open_file(rom_path, func(file: FileAccess) -> String:
		var pvd = _iso_read_pvd(file)
		if not pvd.valid:
			return ""
		
		var cnf = _iso_find_file(file, pvd.root_lba, pvd.root_length, "SYSTEM.CNF")
		if not cnf.found:
			push_error("[TitleIDParser] ISO SYSTEM.CNF not found")
			return ""
		
		file.seek(cnf.lba * _ISO_SECTOR_SIZE)
		var cnf_data = file.get_buffer(cnf.length)
		var cnf_content = cnf_data.get_string_from_utf8()
		var serial = _iso_extract_serial_from_cnf(cnf_content)
		
		if serial == "":
			push_error("[TitleIDParser] ISO failed to extract serial from SYSTEM.CNF")
		
		return serial
	)

# CHD v5 parsing

static func _get_chd_reader_path() -> String:
	var base_path = "res://bin/libchdr/"
	if PlatformManager.is_windows():
		return base_path + "win/chd_reader.exe"
	elif PlatformManager.is_linux():
		return base_path + "linux/chd_reader"
	elif PlatformManager.is_macos():
		return base_path + "macos/chd_reader"
	elif PlatformManager.is_android():
		return base_path + "android/chd_reader-arm64"
	else:
		push_error("[TitleIDParser] Unsupported platform for CHD reading")
		return ""

static func _chd_read_sector_binary(chd_path: String, lba: int) -> PackedByteArray:
	var reader_path = _get_chd_reader_path()
	if reader_path == "":
		return PackedByteArray()
	
	var abs_reader = FileSystemManager.resolve_path(reader_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	var abs_chd = FileSystemManager.resolve_path(chd_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	
	# Create temp file for sector output
	var temp_path = OS.get_user_data_dir() + "/chd_sector_" + str(lba) + ".tmp"
	
	var output = []
	var args = [abs_chd, str(lba), temp_path]
	var exit_code = OS.execute(abs_reader, args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] chd_reader failed with exit code: " + str(exit_code))
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)
		return PackedByteArray()
	
	if not FileAccess.file_exists(temp_path):
		push_error("[TitleIDParser] chd_reader did not create output file")
		return PackedByteArray()
	
	var file = FileAccess.open(temp_path, FileAccess.READ)
	if not file:
		push_error("[TitleIDParser] Failed to read temp sector file")
		DirAccess.remove_absolute(temp_path)
		return PackedByteArray()
	
	var data = file.get_buffer(file.get_length())
	file.close()
	DirAccess.remove_absolute(temp_path)
	
	return data

static func _chd_extract_ps2_serial(rom_path: String) -> String:
	# Read PVD from sector 16
	var pvd_sector = _chd_read_sector_binary(rom_path, 16)
	if pvd_sector.is_empty() or pvd_sector.size() < 2048:
		push_error("[TitleIDParser] Failed to read CHD PVD sector")
		return ""
	
	# Verify PVD
	if pvd_sector[0] != 0x01:
		push_error("[TitleIDParser] CHD invalid PVD descriptor type")
		return ""
	
	var sig = pvd_sector.slice(1, 6).get_string_from_ascii()
	if sig != "CD001":
		push_error("[TitleIDParser] CHD invalid PVD signature: " + sig)
		return ""
	
	# Get root directory info (little-endian in ISO)
	var root_lba = pvd_sector.decode_u32(158)
	var root_length = pvd_sector.decode_u32(166)
	
	# Read root directory sectors
	var dir_sectors = (root_length + 2047) / 2048
	var dir_data = PackedByteArray()
	
	for i in range(dir_sectors):
		var sector = _chd_read_sector_binary(rom_path, root_lba + i)
		if sector.is_empty():
			push_error("[TitleIDParser] Failed to read CHD root directory")
			return ""
		dir_data.append_array(sector)
	
	# Find SYSTEM.CNF in directory
	var offset = 0
	var cnf_lba = 0
	var found = false
	
	while offset < root_length:
		var entry_length = dir_data[offset]
		if entry_length == 0:
			offset = (offset / 2048 + 1) * 2048
			continue
		
		var name_length = dir_data[offset + 32]
		var name = dir_data.slice(offset + 33, offset + 33 + name_length).get_string_from_ascii()
		
		var semicolon = name.find(";")
		if semicolon >= 0:
			name = name.substr(0, semicolon)
		
		if name.to_upper() == "SYSTEM.CNF":
			cnf_lba = dir_data.decode_u32(offset + 2)
			found = true
			break
		
		offset += entry_length
	
	if not found:
		push_error("[TitleIDParser] CHD SYSTEM.CNF not found")
		return ""
	
	# Read SYSTEM.CNF
	var cnf_data = _chd_read_sector_binary(rom_path, cnf_lba)
	if cnf_data.is_empty():
		return ""
	
	var cnf_content = cnf_data.get_string_from_utf8()
	
	# Parse serial
	var regex = RegEx.new()
	regex.compile(r"BOOT2\s*=\s*cdrom0:\\\\?([A-Z]{4})[_.](\d{3})\.(\d{2});")
	
	var match = regex.search(cnf_content)
	if match:
		return match.get_string(1) + "-" + match.get_string(2) + match.get_string(3)
	
	push_error("[TitleIDParser] CHD failed to extract serial from SYSTEM.CNF")
	return ""

static func extract_ps2_serial(rom_path: String) -> String:
	var ext = rom_path.get_extension().to_lower()
	
	match ext:
		"iso":
			return _iso_extract_ps2_serial(rom_path)
		"chd":
			return _chd_extract_ps2_serial(rom_path)
		_:
			push_error("[TitleIDParser] Unsupported PS2 ROM format: " + ext)
			return ""

# ==================== PS4 (shadPS4) ====================

## Extracts PS4 Title ID from a ZIP file by reading the root directory names
## PS4 game ZIPs contain a CUSAxxxxx directory at the root level
## Returns Title ID string (e.g., "CUSA01130") or empty string on failure
static func extract_ps4_title_id(zip_path: String) -> String:
	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		push_error("[TitleIDParser] File not found: " + zip_path)
		return ""
	zip_path = resolved_path
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	
	# If ZIPReader fails (e.g., ZIP64 large files), try 7-Zip fallback
	if err != OK:
		print("[TitleIDParser] ZIPReader failed, attempting 7-Zip fallback for: " + zip_path)
		var title_id_from_7z = _extract_ps4_title_id_with_7z(zip_path)
		if title_id_from_7z != "":
			return title_id_from_7z
		push_error("[TitleIDParser] Failed to open ZIP for PS4 TitleID extraction: " + zip_path + " (error: " + str(err) + ")")
		return ""
	
	var files = reader.get_files()
	if files.is_empty():
		push_error("[TitleIDParser] ZIP is empty: " + zip_path)
		reader.close()
		return ""
	
	# Find the root-level CUSA directory
	var title_id := ""
	for file_path in files:
		# Look for paths like "CUSAxxxxx/..." at the root level
		var parts = file_path.split("/", false)
		if parts.size() > 0:
			var potential_id = parts[0]
			if potential_id.begins_with("CUSA") and potential_id.length() == 9:
				title_id = potential_id
				print("[TitleIDParser] Found PS4 TitleID in ZIP: " + title_id + " (from path: " + file_path + ")")
				break
	
	reader.close()
	
	if title_id == "":
		push_error("[TitleIDParser] No CUSA TitleID found in PS4 ZIP: " + zip_path)
		return ""
	
	print("[TitleIDParser] PS4 TitleID extracted from ZIP: " + title_id)
	return title_id


## 7-Zip fallback for extracting PS4 TitleID from large/ZIP64 archives
static func _extract_ps4_title_id_with_7z(zip_path: String) -> String:
	var binary_path = _get_7z_binary_path()
	if binary_path == "":
		print("[TitleIDParser] 7-Zip binary not available")
		return ""
	
	print("[TitleIDParser] Using 7-Zip fallback for PS4 TitleID: " + binary_path)
	
	# List archive contents
	var list_args = ["l", "-slt", zip_path]
	var output = []
	var exit_code = OS.execute(binary_path, list_args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] 7-Zip list failed with exit code: " + str(exit_code))
		return ""
	
	var output_str = ""
	if output.size() > 0:
		output_str = output[0]
	
	# Parse output to find root-level CUSA directory
	var title_id = ""
	var lines = output_str.split("\n")
	for line in lines:
		if line.begins_with("Path = "):
			var path = line.substr(7).strip_edges()
			# Normalize path separators (Windows uses backslashes)
			path = path.replace("\\", "/")
			# Check if this is a root-level CUSA directory
			var parts = path.split("/", false)
			if parts.size() > 0:
				var potential_id = parts[0]
				if potential_id.begins_with("CUSA") and potential_id.length() == 9:
					title_id = potential_id
					print("[TitleIDParser] Found PS4 TitleID in 7-Zip output: " + title_id + " (from path: " + path + ")")
					break
	
	if title_id == "":
		push_error("[TitleIDParser] No CUSA TitleID found via 7-Zip listing")
		return ""
	
	print("[TitleIDParser] PS4 TitleID extracted via 7-Zip fallback: " + title_id)
	return title_id


# ==================== PS3 (RPCS3) ====================

## Extracts PS3 Title ID from a ZIP file by reading PARAM.SFO directly from the archive
## Supports both disc format (PS3_GAME/PARAM.SFO) and digital format (TITLEID/PARAM.SFO)
## Returns Title ID string (e.g., "BLUS12345") or empty string on failure
static func extract_ps3_title_id(zip_path: String) -> String:
	# Resolve ZIP path with fallbacks for Godot virtual paths and Windows backslashes
	var resolved_path = _resolve_zip_path(zip_path)
	if resolved_path == "":
		push_error("[TitleIDParser] File not found: " + zip_path)
		return ""
	zip_path = resolved_path
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	
	# If ZIPReader fails (e.g., ZIP64 large files), try 7-Zip fallback
	if err != OK:
		print("[TitleIDParser] ZIPReader failed, attempting 7-Zip fallback for: " + zip_path)
		var title_id_from_7z = _extract_ps3_title_id_with_7z(zip_path)
		if title_id_from_7z != "":
			return title_id_from_7z
		push_error("[TitleIDParser] Failed to open ZIP for PS3 TitleID extraction: " + zip_path + " (error: " + str(err) + ")")
		return ""
	
	var files = reader.get_files()
	if files.is_empty():
		push_error("[TitleIDParser] ZIP is empty: " + zip_path)
		reader.close()
		return ""
	
	# Find PARAM.SFO in the ZIP (could be PS3_GAME/PARAM.SFO or TITLEID/PARAM.SFO)
	var sfo_path := ""
	for file_path in files:
		if file_path.ends_with("PARAM.SFO") or file_path.ends_with("PARAM.sfo"):
			sfo_path = file_path
			break
	
	if sfo_path == "":
		push_error("[TitleIDParser] PARAM.SFO not found in PS3 ZIP: " + zip_path)
		reader.close()
		return ""
	
	print("[TitleIDParser] Found PARAM.SFO in ZIP at: " + sfo_path)
	
	# Read PARAM.SFO bytes from ZIP
	var sfo_bytes = reader.read_file(sfo_path)
	reader.close()
	
	if sfo_bytes.is_empty():
		push_error("[TitleIDParser] Failed to read PARAM.SFO from ZIP: " + zip_path)
		return ""
	
	# Parse TitleID from SFO bytes
	var title_id = get_title_id_from_sfo_bytes(sfo_bytes)
	
	if title_id == "":
		push_error("[TitleIDParser] Failed to extract TitleID from PARAM.SFO in: " + zip_path)
		return ""
	
	print("[TitleIDParser] PS3 TitleID extracted from ZIP: " + title_id)
	return title_id


## 7-Zip fallback for extracting PS3 TitleID from large/ZIP64 archives
## Uses bundled 7z binary to extract PARAM.SFO, then parses it
static func _extract_ps3_title_id_with_7z(zip_path: String) -> String:
	var binary_path = _get_7z_binary_path()
	if binary_path == "":
		print("[TitleIDParser] 7-Zip binary not available")
		return ""
	
	print("[TitleIDParser] Using 7-Zip fallback: " + binary_path)
	
	# Step 1: List archive contents to find PARAM.SFO path
	var list_args = ["l", "-slt", zip_path]
	var output = []
	var exit_code = OS.execute(binary_path, list_args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] 7-Zip list failed with exit code: " + str(exit_code))
		return ""
	
	var output_str = ""
	if output.size() > 0:
		output_str = output[0]
	
	# Parse output to find PARAM.SFO path
	var sfo_path = ""
	var lines = output_str.split("\n")
	for line in lines:
		if line.find("PARAM.SFO") != -1 and not line.ends_with("/") and not line.ends_with("\\"):
			# Extract path from "Path = ..." line
			if line.begins_with("Path = "):
				sfo_path = line.substr(7).strip_edges()
				break
	
	if sfo_path == "":
		push_error("[TitleIDParser] PARAM.SFO not found via 7-Zip listing")
		return ""
	
	print("[TitleIDParser] Found PARAM.SFO via 7-Zip at: " + sfo_path)
	
	# Step 2: Extract PARAM.SFO to temp directory
	var temp_dir = "user://temp_ps3_sfo/"
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	var extract_args = ["e", zip_path, sfo_path, 		"-o" + FileSystemManager.resolve_path(temp_dir, {"format": FileSystemManager.PathFormat.ABSOLUTE}), "-y"]
	exit_code = OS.execute(binary_path, extract_args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] 7-Zip extract failed with exit code: " + str(exit_code))
		return ""
	
	# Step 3: Read extracted PARAM.SFO
	var extracted_sfo = temp_dir + "PARAM.SFO"
	if not FileAccess.file_exists(extracted_sfo):
		push_error("[TitleIDParser] Extracted PARAM.SFO not found at: " + extracted_sfo)
		return ""
	
	var sfo_file = FileAccess.open(extracted_sfo, FileAccess.READ)
	if not sfo_file:
		push_error("[TitleIDParser] Failed to open extracted PARAM.SFO")
		return ""
	
	var sfo_bytes = sfo_file.get_buffer(sfo_file.get_length())
	sfo_file.close()
	
	# Clean up temp file
	DirAccess.remove_absolute(extracted_sfo)
	
	if sfo_bytes.is_empty():
		push_error("[TitleIDParser] Failed to read extracted PARAM.SFO")
		return ""
	
	# Step 4: Parse TitleID
	var title_id = get_title_id_from_sfo_bytes(sfo_bytes)
	
	if title_id == "":
		push_error("[TitleIDParser] Failed to extract TitleID from 7-Zip extracted PARAM.SFO")
		return ""
	
	print("[TitleIDParser] PS3 TitleID extracted via 7-Zip fallback: " + title_id)
	return title_id


## Gets the bundled 7z binary path for the current platform
static func _get_7z_binary_path() -> String:
	var platform_name = ""
	match OS.get_name():
		"Windows":
			platform_name = "windows"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			platform_name = "linux"
		_:
			return ""
	
	var binary_name = "7za.exe" if OS.get_name() == "Windows" else "7z"
	return ProjectSettings.globalize_path("res://bin/7z/" + platform_name + "/" + binary_name)


# ============================================================================
# PARAM.SFO PARSER (merged from param_sfo_parser.gd)
# ============================================================================

## Reads a PARAM.SFO file from disk and returns a dictionary with all fields
## Returns empty dictionary if file cannot be parsed
static func read_sfo(path: String) -> Dictionary:
	if not FileSystemManager.file_exists(path):
		push_error("[TitleIDParser] SFO file not found: " + path)
		return {}
	
	var file := FileSystemManager.open_file_read(path)
	if not file:
		push_error("[TitleIDParser] Failed to open SFO file: " + path)
		return {}
	
	var data := file.get_buffer(file.get_length())
	file.close()
	
	return _read_sfo_from_bytes(data)


## Parses PARAM.SFO data from a byte array
## Returns empty dictionary if data cannot be parsed
static func _read_sfo_from_bytes(data: PackedByteArray) -> Dictionary:
	# Check minimum file size (header is 20 bytes)
	if data.size() < 20:
		push_error("[TitleIDParser] SFO data too small: " + str(data.size()) + " bytes")
		return {}
	
	# Parse header
	var pos := 0
	var magic := data.decode_u32(pos)
	pos += 4
	
	# Magic should be "PSF\0" = 0x46535000 (little-endian)
	if magic != 0x46535000:
		push_error("[TitleIDParser] Invalid SFO magic: 0x" + String.num_uint64(magic, 16) + " (expected 0x46535000 for PSF)")
		return {}
	
	var version := data.decode_u32(pos)
	pos += 4
	
	var key_table_offset := data.decode_u32(pos)
	pos += 4
	
	var data_table_offset := data.decode_u32(pos)
	pos += 4
	
	var num_entries := data.decode_u32(pos)
	pos += 4
	
	print("[TitleIDParser] SFO Header: version=" + str(version) + ", entries=" + str(num_entries))
	print("[TitleIDParser] SFO Key table at offset " + str(key_table_offset) + ", data table at offset " + str(data_table_offset))
	
	# Read index table entries
	var entries := []
	for i in range(num_entries):
		if pos + 16 > data.size():
			push_error("[TitleIDParser] Unexpected end of file reading SFO entry " + str(i))
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
static func get_sfo_title_id(path: String) -> String:
	print("[TitleIDParser] get_sfo_title_id called for: " + path)
	
	var sfo_data := read_sfo(path)
	return _extract_title_id_from_sfo_data(sfo_data)


## Extracts the TitleID from PARAM.SFO byte data
## Returns empty string if TitleID cannot be found
static func get_title_id_from_sfo_bytes(data: PackedByteArray) -> String:
	print("[TitleIDParser] get_title_id_from_sfo_bytes called")
	
	var sfo_data := _read_sfo_from_bytes(data)
	return _extract_title_id_from_sfo_data(sfo_data)


static func _extract_title_id_from_sfo_data(sfo_data: Dictionary) -> String:
	if sfo_data.is_empty():
		print("[TitleIDParser] SFO data is empty")
		return ""
	
	print("[TitleIDParser] SFO data keys: " + str(sfo_data.keys()))
	
	# TitleID is stored in the "TITLE_ID" field
	var title_id: String = sfo_data.get("TITLE_ID", "")
	print("[TitleIDParser] TITLE_ID value: '" + title_id + "'")
	
	if title_id == "" or title_id == "<binary>":
		# Try alternative field names
		title_id = sfo_data.get("title_id", "")
		if title_id != "":
			print("[TitleIDParser] Found title_id (lowercase): '" + title_id + "'")
	
	return title_id


## Extracts the game title from a PARAM.SFO file
## Returns empty string if title cannot be found  
static func get_sfo_title(path: String) -> String:
	var sfo_data := read_sfo(path)
	if sfo_data.is_empty():
		return ""
	
	# Title is stored in the "TITLE" field
	var title: String = sfo_data.get("TITLE", "")
	
	if title == "" or title == "<binary>":
		# Try shorter title field
		title = sfo_data.get("STITLE", "")
	
	return title

# ==================== PSP (PPSSPP) ====================
# ISO9660 + PARAM.SFO parsing for PSP game IDs

static func _parse_paramsfo_disc_id(sfo_data: PackedByteArray) -> String:
	if sfo_data.size() < 0x14:
		return ""
	
	var magic = sfo_data.decode_u32(0x00)
	if magic != 0x46535000:  # "PSF\0"
		return ""
	
	var key_table_start = sfo_data.decode_u32(0x08)
	var data_table_start = sfo_data.decode_u32(0x0C)
	var index_entries = sfo_data.decode_u32(0x10)
	
	var index_offset = 0x14
	for i in range(index_entries):
		if index_offset + 0x10 > sfo_data.size():
			break
		
		var key_offset = sfo_data.decode_u16(index_offset + 0x00)
		var data_fmt = sfo_data.decode_u16(index_offset + 0x02)
		var data_len = sfo_data.decode_u32(index_offset + 0x04)
		var data_max_len = sfo_data.decode_u32(index_offset + 0x08)
		var data_offset = sfo_data.decode_u32(index_offset + 0x0C)
		
		# Read key name (null-terminated)
		var key_name = ""
		var key_abs = key_table_start + key_offset
		while key_abs < sfo_data.size() and sfo_data[key_abs] != 0:
			key_name += char(sfo_data[key_abs])
			key_abs += 1
		
		if key_name == "DISC_ID" and data_fmt == 0x0204:
			var id_abs = data_table_start + data_offset
			var disc_id = ""
			for j in range(data_len):
				if id_abs + j >= sfo_data.size():
					break
				var c = sfo_data[id_abs + j]
				if c == 0:
					break
				disc_id += char(c)
			return disc_id.to_upper()
		
		index_offset += 0x10
	
	return ""

static func _iso_extract_psp_game_id(rom_path: String) -> String:
	return _with_open_file(rom_path, func(file: FileAccess) -> String:
		var pvd = _iso_read_pvd(file)
		if not pvd.valid:
			return ""
		
		# Find PSP_GAME directory in root
		var psp_game = _iso_find_file(file, pvd.root_lba, pvd.root_length, "PSP_GAME")
		if not psp_game.found:
			push_error("[TitleIDParser] PSP_GAME directory not found")
			return ""
		
		# Find PARAM.SFO inside PSP_GAME
		var paramsfo = _iso_find_file(file, psp_game.lba, psp_game.length, "PARAM.SFO")
		if not paramsfo.found:
			push_error("[TitleIDParser] PARAM.SFO not found in PSP_GAME")
			return ""
		
		file.seek(paramsfo.lba * _ISO_SECTOR_SIZE)
		var sfo_data = file.get_buffer(paramsfo.length)
		
		var disc_id = _parse_paramsfo_disc_id(sfo_data)
		
		# Normalize: remove hyphen if present, return 9-char format
		if disc_id.length() == 10 and disc_id[4] == "-":
			disc_id = disc_id.replace("-", "")
		
		if disc_id.length() == 9:
			return disc_id
		
		push_error("[TitleIDParser] Failed to extract valid PSP game ID from PARAM.SFO")
		return ""
	)

static func _get_cso_reader_path() -> String:
	var base_path = "res://bin/cso_reader/"
	if PlatformManager.is_windows():
		return base_path + "win/cso_reader.exe"
	elif PlatformManager.is_linux():
		return base_path + "linux/cso_reader"
	elif PlatformManager.is_macos():
		return base_path + "macos/cso_reader"
	elif PlatformManager.is_android():
		return base_path + "android/cso_reader-arm64"
	else:
		push_error("[TitleIDParser] Unsupported platform for CSO reading")
		return ""

static func _cso_extract_psp_game_id(rom_path: String) -> String:
	print("[TitleIDParser] Extracting PSP game ID from CSO: " + rom_path)
	
	var reader_path = _get_cso_reader_path()
	if reader_path == "":
		return ""
	
	var abs_reader = FileSystemManager.resolve_path(reader_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	var abs_cso = FileSystemManager.resolve_path(rom_path, {"format": FileSystemManager.PathFormat.ABSOLUTE})
	
	var output = []
	var args = [abs_cso]
	var exit_code = OS.execute(abs_reader, args, output, true)
	
	if exit_code != 0:
		push_error("[TitleIDParser] cso_reader failed with exit code: " + str(exit_code))
		return ""
	
	# Parse output
	var game_id = ""
	if output.size() > 0:
		game_id = output[0].strip_edges()
	
	if game_id.length() == 9:
		return game_id
	
	push_error("[TitleIDParser] Failed to extract valid PSP game ID from CSO")
	return ""

static func extract_psp_game_id(rom_path: String) -> String:
	var ext = rom_path.get_extension().to_lower()
	
	match ext:
		"iso":
			return _iso_extract_psp_game_id(rom_path)
		"cso":
			return _cso_extract_psp_game_id(rom_path)
		_:
			push_error("[TitleIDParser] Unsupported PSP ROM format: " + ext)
			return ""

## Extracts TitleID/serial for a game based on its platform
## Returns empty string if extraction fails or not needed
static func extract_for_game(game: GameResource) -> String:
	var rom_path = game.file_path
	if rom_path == "":
		return ""
	
	match game.platform_slug:
		"3ds":
			return extract_3ds_title_id(rom_path)
		"wiiu":
			return extract_wiiu_title_id(rom_path)
		"ngc", "wii":
			return extract_gamecube_game_id(rom_path)
		"ps2":
			return extract_ps2_serial(rom_path)
		"psp":
			return extract_psp_game_id(rom_path)
		"ps3":
			return extract_ps3_title_id(rom_path)
		"ps4":
			return extract_ps4_title_id(rom_path)
		"switch":
			# Switch needs emulator directory for prod.keys lookup
			var emulator_dir = LaunchManager._get_emulator_directory("eden")
			return extract_switch_title_id(rom_path, emulator_dir)
		"vita":
			return extract_vita_title_id(rom_path)
		"xbox360":
			return extract_xbox360_title_id(rom_path)
		_:
			return ""
