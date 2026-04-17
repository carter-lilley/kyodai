## Unified title ID / serial parser for all platforms
## Extracts game identifiers from ROM files for save sync purposes
class_name TitleIDParser

# ==================== 3DS (Azahar) ====================

static func extract_3ds_title_id(rom_path: String) -> String:
	if not FileAccess.file_exists(rom_path):
		push_error("[TitleIDParser] Cannot extract TitleID - file not found: " + rom_path)
		return ""
	
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		push_error("[TitleIDParser] Failed to open 3DS ROM: " + rom_path)
		return ""
	
	var header = file.get_buffer(0x200)
	if header.size() < 0x200:
		file.close()
		push_error("[TitleIDParser] 3DS ROM too small: " + rom_path)
		return ""
	
	var title_id_val = 0
	var magic = header.slice(0x100, 0x104).get_string_from_ascii()
	
	if magic == "NCCH":
		title_id_val = header.decode_u64(0x118)
	elif magic == "NCSD":
		title_id_val = header.decode_u64(0x108)
	else:
		var ncsd_magic = header.slice(0x0, 0x4).get_string_from_ascii()
		if ncsd_magic == "NCSD":
			title_id_val = header.decode_u64(0x008)
		else:
			file.close()
			push_error("[TitleIDParser] Unknown 3DS ROM format: " + rom_path)
			return ""
	
	file.close()
	return "%016x" % title_id_val

# ==================== Wii U (Cemu) ====================

static func extract_wiiu_title_id(rom_path: String) -> String:
	if not FileAccess.file_exists(rom_path):
		return ""
	
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		return ""
	
	var file_size = file.get_length()
	var tail_size = mini(file_size, 262144)
	file.seek(file_size - tail_size)
	var tail = file.get_buffer(tail_size)
	file.close()
	
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
	var keys_path = emulator_dir.rstrip("/") + "/user/keys/prod.keys"
	if not FileAccess.file_exists(keys_path):
		return ""
	
	var file = FileAccess.open(keys_path, FileAccess.READ)
	if not file:
		return ""
	
	var content = file.get_as_text()
	file.close()
	
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
	if not FileAccess.file_exists(rom_path):
		return ""
	
	var header_key_hex = _read_prod_keys_header_key(emulator_dir)
	if header_key_hex == "":
		return ""
	
	var header_key = PackedByteArray()
	for i in range(0, header_key_hex.length(), 2):
		header_key.append(header_key_hex.substr(i, 2).hex_to_int())
	if header_key.size() != 32:
		return ""
	
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		return ""
	
	file.seek(0x130)
	var hfs0_offset = file.get_64()
	var hfs0_size = file.get_64()
	
	var root = _parse_hfs0(file, hfs0_offset)
	if not root.valid:
		file.close()
		return ""
	
	var secure_offset = -1
	for entry in root.entries:
		if entry.name == "secure":
			secure_offset = entry.offset
			break
	
	if secure_offset < 0:
		file.close()
		return ""
	
	var secure = _parse_hfs0(file, secure_offset)
	if not secure.valid or secure.entries.is_empty():
		file.close()
		return ""
	
	var largest_idx = -1
	var largest_size = 0
	for i in range(secure.entries.size()):
		if secure.entries[i].size > largest_size:
			largest_size = secure.entries[i].size
			largest_idx = i
	
	if largest_idx < 0:
		file.close()
		return ""
	
	var nca_offset = secure.entries[largest_idx].offset
	file.seek(nca_offset)
	var nca_header = file.get_buffer(0x400)
	file.close()
	
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

static func extract_switch_title_id(rom_path: String, emulator_dir: String) -> String:
	if not FileAccess.file_exists(rom_path):
		return ""
	
	var ext = rom_path.get_extension().to_lower()
	
	if ext == "xci":
		return extract_xci_title_id(rom_path, emulator_dir)
	
	if ext in ["nsp", "nsz"]:
		var file = FileAccess.open(rom_path, FileAccess.READ)
		if not file:
			return ""
		
		var header = file.get_buffer(0x2000)
		file.close()
		
		if header.size() < 0x10:
			return ""
		
		var magic = header.slice(0, 4).get_string_from_ascii()
		if magic != "PFS0":
			return ""
		
		var file_count = header.decode_u32(0x04)
		var string_table_size = header.decode_u32(0x08)
		
		var entries_size = file_count * 0x18
		var total_header = 0x10 + entries_size + string_table_size
		
		if header.size() < total_header:
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
		
		for i in range(file_count):
			var filename = filenames[i]
			if filename.to_lower().ends_with(".tik"):
				var basename = filename.get_basename()
				if basename.length() == 16:
					var is_hex = true
					for c in basename:
						if not ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')):
							is_hex = false
							break
					if is_hex and basename.to_upper().begins_with("01"):
						return basename.to_upper()
		
		var header_key_hex = _read_prod_keys_header_key(emulator_dir)
		if header_key_hex != "":
			var header_key = PackedByteArray()
			for i in range(0, header_key_hex.length(), 2):
				header_key.append(header_key_hex.substr(i, 2).hex_to_int())
			
			if header_key.size() == 32:
				for i in range(file_count):
					var filename = filenames[i]
					if filename.to_lower().ends_with(".nca"):
						var nca_offset = header.decode_u64(0x10 + (i * 0x18))
						var nca_size = header.decode_u64(0x10 + (i * 0x18) + 0x08)
						
						var nca_file = FileAccess.open(rom_path, FileAccess.READ)
						if nca_file:
							nca_file.seek(nca_offset)
							var nca_header = nca_file.get_buffer(0x400)
							nca_file.close()
							
							if nca_header.size() >= 0x400:
								var decrypted = _aes_xts_decrypt(nca_header, header_key, 0x200, 0)
								var nca_magic = decrypted.slice(0x200, 0x204).get_string_from_ascii()
								if nca_magic == "NCA3" or nca_magic == "NCA2" or nca_magic == "NCA1" or nca_magic == "NCA0":
									var nca_title_id = ""
									for j in range(7, -1, -1):
										nca_title_id += "%02x" % decrypted[0x210 + j]
									nca_title_id = nca_title_id.to_upper()
									if nca_title_id.begins_with("01") and nca_title_id.length() == 16:
										return nca_title_id
	
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
	if not FileAccess.file_exists(rom_path):
		return ""
	
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		return ""
	
	var file_size = file.get_length()
	var scan_size = mini(file_size, 1048576)
	var data = file.get_buffer(scan_size)
	file.close()
	
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
					var file = FileAccess.open(gci_path, FileAccess.READ)
					if not file:
						continue
					var header = file.get_buffer(6)
					file.close()
					if header.size() < 6:
						continue
					var game_id = header.slice(0, 4).get_string_from_ascii()
					var maker = header.slice(4, 6).get_string_from_ascii()
					if _is_valid_gamecube_game_id(game_id) and _is_valid_maker_code(maker):
						return game_id
	return ""

# ==================== Vita (Vita3K) ====================

static func extract_vita_title_id(zip_path: String) -> String:
	if PlatformManager.is_android() and zip_path.begins_with("content://"):
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin == null:
			push_error("[TitleIDParser] PackageChecker plugin not available for SAF URI conversion")
			return ""
		
		var title_id = plugin.extractVitaTitleIdFromSafZip(zip_path)
		if title_id != "":
			return title_id
		else:
			push_error("[TitleIDParser] Plugin failed to extract TitleID from: " + zip_path)
			return ""
	
	if not FileAccess.file_exists(zip_path):
		push_error("[TitleIDParser] Cannot extract TitleID - file not found: " + zip_path)
		return ""
	
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK:
		push_error("[TitleIDParser] Failed to open ZIP for TitleID extraction: " + zip_path)
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
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		push_error("[TitleIDParser] Failed to open ISO: " + rom_path)
		return ""
	
	var pvd = _iso_read_pvd(file)
	if not pvd.valid:
		file.close()
		return ""
	
	var cnf = _iso_find_file(file, pvd.root_lba, pvd.root_length, "SYSTEM.CNF")
	if not cnf.found:
		push_error("[TitleIDParser] ISO SYSTEM.CNF not found")
		file.close()
		return ""
	
	file.seek(cnf.lba * _ISO_SECTOR_SIZE)
	var cnf_data = file.get_buffer(cnf.length)
	file.close()
	
	var cnf_content = cnf_data.get_string_from_utf8()
	var serial = _iso_extract_serial_from_cnf(cnf_content)
	
	if serial == "":
		push_error("[TitleIDParser] ISO failed to extract serial from SYSTEM.CNF")
	
	return serial

# CHD v5 parsing

const _CHD_SIGNATURE = "MComprHD"
const _CHD_V5_VERSION = 5

static func _be_u32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]

static func _be_u64(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 56) | (bytes[offset + 1] << 48) | (bytes[offset + 2] << 40) | (bytes[offset + 3] << 32) | (bytes[offset + 4] << 24) | (bytes[offset + 5] << 16) | (bytes[offset + 6] << 8) | bytes[offset + 7]

static func _chd_read_header(file: FileAccess) -> Dictionary:
	var result = {
		"valid": false,
		"version": 0,
		"hunk_size": 0,
		"total_hunks": 0,
		"map_offset": 0,
		"compressed": true
	}
	
	file.seek(0)
	var header = file.get_buffer(124)
	
	if header.size() < 124:
		push_error("[TitleIDParser] CHD file too small for header")
		return result
	
	var sig = header.slice(0, 8).get_string_from_ascii()
	if sig != _CHD_SIGNATURE:
		push_error("[TitleIDParser] CHD invalid signature: " + sig)
		return result
	
	# CHD uses big-endian (Motorola byte ordering)
	result.version = _be_u32(header, 12)
	if result.version != _CHD_V5_VERSION:
		push_error("[TitleIDParser] CHD unsupported version: " + str(result.version))
		return result
	
	# Check compressors - if first is 0, entire file is uncompressed
	var compressor0 = _be_u32(header, 16)
	if compressor0 == 0:
		result.compressed = false
	
	result.hunk_size = _be_u32(header, 56)
	var logicalbytes = _be_u64(header, 32)
	result.total_hunks = (logicalbytes + result.hunk_size - 1) / result.hunk_size
	result.map_offset = _be_u64(header, 40)
	result.valid = true
	
	return result

static func _chd_read_hunk_map(file: FileAccess, header: Dictionary) -> Array:
	var map_entries = []
	var map_offset = header.map_offset
	var total_hunks = header.total_hunks
	var hunk_size = header.hunk_size
	
	file.seek(map_offset)
	
	if not header.compressed:
		# Uncompressed map: each entry is just a uint32_t offset
		# Read all map entries directly
		for i in range(total_hunks):
			var entry_bytes = file.get_buffer(4)
			if entry_bytes.size() < 4:
				break
			var entry_offset = _be_u32(entry_bytes, 0)
			# For uncompressed, offset is in units of hunk_size
			var actual_offset = entry_offset * hunk_size
			
			map_entries.append({
				"offset": actual_offset,
				"length": hunk_size,
				"flags": 0  # 0 = uncompressed
			})
		
		return map_entries
	
	# Compressed map - try zlib decompression
	# V5 compressed map header (16 bytes, big-endian)
	var map_header = file.get_buffer(16)
	var map_length = _be_u32(map_header, 0)
	
	var compressed_map = file.get_buffer(map_length)
	
	# Try zlib decompression
	var decompressed = compressed_map.decompress(compressed_map.size() * 4, 1)
	
	if decompressed.is_empty():
		push_error("[TitleIDParser] CHD failed to decompress hunk map. Compressed CHD v5 maps use custom Huffman encoding not supported by standard zlib. Consider converting to ISO or using an uncompressed CHD.")
		return map_entries
	
	var offset = 0
	for i in range(total_hunks):
		# V5 compressed map entry: compression(8) + complength(24) + offset(48) + crc(16) = 12 bytes
		var compression = decompressed[offset]
		var complength = (decompressed[offset + 1] << 16) | (decompressed[offset + 2] << 8) | decompressed[offset + 3]
		var entry_offset = ((decompressed[offset + 4] << 40) | (decompressed[offset + 5] << 32) | (decompressed[offset + 6] << 24) | (decompressed[offset + 7] << 16) | (decompressed[offset + 8] << 8) | decompressed[offset + 9])
		var crc = (decompressed[offset + 10] << 8) | decompressed[offset + 11]
		
		map_entries.append({
			"offset": entry_offset,
			"length": complength,
			"flags": compression
		})
		offset += 12
	
	return map_entries

static func _chd_read_hunk(file: FileAccess, map_entry: Dictionary, hunk_size: int) -> PackedByteArray:
	var flags = map_entry.flags
	
	if flags == 0:
		# Uncompressed
		file.seek(map_entry.offset)
		return file.get_buffer(hunk_size)
	
	if flags == 1:
		# Compressed (zlib)
		file.seek(map_entry.offset)
		var compressed = file.get_buffer(map_entry.length)
		
		var decompressed = compressed.decompress(hunk_size, 1)
		
		if decompressed.is_empty() or decompressed.size() != hunk_size:
			push_error("[TitleIDParser] CHD failed to decompress hunk")
			return PackedByteArray()
		
		return decompressed
	
	if flags == 2:
		# Self-referencing (copy from another hunk)
		push_error("[TitleIDParser] CHD self-referencing hunk not supported")
		return PackedByteArray()
	
	if flags == 3:
		# Parent hunk (copy from parent CHD)
		push_error("[TitleIDParser] CHD parent hunk not supported")
		return PackedByteArray()
	
	push_error("[TitleIDParser] CHD unknown hunk type: " + str(flags))
	return PackedByteArray()

static func _chd_read_sectors(file: FileAccess, header: Dictionary, map_entries: Array, start_sector: int, count: int) -> PackedByteArray:
	var hunk_size = header.hunk_size
	var sectors_per_hunk = hunk_size / _ISO_SECTOR_SIZE
	
	var result = PackedByteArray()
	
	for i in range(count):
		var sector = start_sector + i
		var hunk_index = sector / sectors_per_hunk
		var sector_in_hunk = sector % sectors_per_hunk
		
		if hunk_index >= map_entries.size():
			push_error("[TitleIDParser] CHD hunk index out of bounds: " + str(hunk_index))
			return PackedByteArray()
		
		var hunk = _chd_read_hunk(file, map_entries[hunk_index], hunk_size)
		if hunk.is_empty():
			return PackedByteArray()
		
		var sector_offset = sector_in_hunk * _ISO_SECTOR_SIZE
		var sector_data = hunk.slice(sector_offset, sector_offset + _ISO_SECTOR_SIZE)
		result.append_array(sector_data)
	
	return result

static func _chd_extract_ps2_serial(rom_path: String) -> String:
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		push_error("[TitleIDParser] Failed to open CHD: " + rom_path)
		return ""
	
	var header = _chd_read_header(file)
	if not header.valid:
		file.close()
		return ""
	
	var map_entries = _chd_read_hunk_map(file, header.map_offset, header.total_hunks)
	if map_entries.is_empty():
		file.close()
		return ""
	
	var pvd_sector = _chd_read_sectors(file, header, map_entries, 16, 1)
	if pvd_sector.is_empty():
		file.close()
		return ""
	
	if pvd_sector[0] != 0x01:
		push_error("[TitleIDParser] CHD invalid PVD descriptor type")
		file.close()
		return ""
	
	var sig = pvd_sector.slice(1, 6).get_string_from_ascii()
	if sig != "CD001":
		push_error("[TitleIDParser] CHD invalid PVD signature: " + sig)
		file.close()
		return ""
	
	var root_lba = pvd_sector.decode_u32(156 + 2)
	var root_length = pvd_sector.decode_u32(156 + 10)
	
	var dir_sectors = (root_length + _ISO_SECTOR_SIZE - 1) / _ISO_SECTOR_SIZE
	var dir_data = _chd_read_sectors(file, header, map_entries, root_lba, dir_sectors)
	
	if dir_data.is_empty():
		file.close()
		return ""
	
	var cnf_lba = 0
	var cnf_length = 0
	var found = false
	var offset = 0
	
	while offset < root_length:
		var entry_length = dir_data[offset]
		if entry_length == 0:
			offset = (offset / _ISO_SECTOR_SIZE + 1) * _ISO_SECTOR_SIZE
			continue
		
		var name_length = dir_data[offset + 32]
		var name_bytes = dir_data.slice(offset + 33, offset + 33 + name_length)
		var name = name_bytes.get_string_from_ascii()
		
		var semicolon = name.find(";")
		if semicolon >= 0:
			name = name.substr(0, semicolon)
		
		if name.to_upper() == "SYSTEM.CNF":
			cnf_lba = dir_data.decode_u32(offset + 2)
			cnf_length = dir_data.decode_u32(offset + 10)
			found = true
			break
		
		offset += entry_length
	
	if not found:
		push_error("[TitleIDParser] CHD SYSTEM.CNF not found")
		file.close()
		return ""
	
	var cnf_data = _chd_read_sectors(file, header, map_entries, cnf_lba, 1)
	file.close()
	
	if cnf_data.is_empty():
		return ""
	
	var cnf_content = cnf_data.get_string_from_utf8()
	
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

static func mini(a: int, b: int) -> int:
	return a if a < b else b
