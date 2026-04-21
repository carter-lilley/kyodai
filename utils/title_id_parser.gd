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
	
	# Check if file exists (handles both regular paths and Godot virtual paths)
	if not FileAccess.file_exists(zip_path):
		# Try resolving to global path if it's a Godot virtual path
		var global_path = ProjectSettings.globalize_path(zip_path)
		if global_path != zip_path and FileAccess.file_exists(global_path):
			zip_path = global_path
		else:
			push_error("[TitleIDParser] Cannot extract TitleID - file not found: " + zip_path)
			return ""
	
	var reader = ZIPReader.new()
	# Try the path as-is first (ZIPReader on Windows often prefers forward slashes)
	var err = reader.open(zip_path)
	if err != OK:
		# Try with globalized path as fallback
		var global_path = ProjectSettings.globalize_path(zip_path)
		if global_path != zip_path:
			err = reader.open(global_path)
		if err != OK:
			# Last resort: try with backslashes on Windows
			if OS.get_name() == "Windows":
				var backslash_path = zip_path.replace("/", "\\")
				err = reader.open(backslash_path)
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
	
	var abs_reader = ProjectSettings.globalize_path(reader_path)
	var abs_chd = ProjectSettings.globalize_path(chd_path)
	
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
	var file = FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		push_error("[TitleIDParser] Failed to open PSP ISO: " + rom_path)
		return ""
	
	var pvd = _iso_read_pvd(file)
	if not pvd.valid:
		file.close()
		return ""
	
	# Find PSP_GAME directory in root
	var psp_game = _iso_find_file(file, pvd.root_lba, pvd.root_length, "PSP_GAME")
	if not psp_game.found:
		push_error("[TitleIDParser] PSP_GAME directory not found")
		file.close()
		return ""
	
	# Find PARAM.SFO inside PSP_GAME
	var paramsfo = _iso_find_file(file, psp_game.lba, psp_game.length, "PARAM.SFO")
	if not paramsfo.found:
		push_error("[TitleIDParser] PARAM.SFO not found in PSP_GAME")
		file.close()
		return ""
	
	file.seek(paramsfo.lba * _ISO_SECTOR_SIZE)
	var sfo_data = file.get_buffer(paramsfo.length)
	file.close()
	
	var disc_id = _parse_paramsfo_disc_id(sfo_data)
	
	# Normalize: remove hyphen if present, return 9-char format
	if disc_id.length() == 10 and disc_id[4] == "-":
		disc_id = disc_id.replace("-", "")
	
	if disc_id.length() == 9:
		return disc_id
	
	push_error("[TitleIDParser] Failed to extract valid PSP game ID from PARAM.SFO")
	return ""

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
	
	var abs_reader = ProjectSettings.globalize_path(reader_path)
	var abs_cso = ProjectSettings.globalize_path(rom_path)
	
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

static func mini(a: int, b: int) -> int:
	return a if a < b else b
