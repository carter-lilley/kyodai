## PS2 Memory Card Superblock Rebuilder for PCSX2 Folder Saves
## Rebuilds _pcsx2_superblock to include directory entries for save folders
class_name PS2MCRebuilder

const SUPERBLOCK_SIZE = 8192
const PAGE_SIZE = 512
const CLUSTER_SIZE = 1024
const DIRENT_SIZE = 512
const DIRENT_OFFSET_NAME = 0x40

# Directory entry mode flags
const DF_READ = 0x0001
const DF_WRITE = 0x0002
const DF_EXECUTE = 0x0004
const DF_RWX = 0x0007
const DF_DIR = 0x0020
const DF_0400 = 0x0400
const DF_EXISTS = 0x8000

# FAT constants
const FAT_ALLOCATED_BIT = 0x80000000
const FAT_CHAIN_END = 0xFFFFFFFF
const FAT_CLUSTER_MASK = 0x7FFFFFFF

# Standard 8MB card geometry
const CLUSTERS_PER_CARD = 8192
const ALLOC_OFFSET = 41
const ALLOC_END = 8135
const GOOD_BLOCK1 = 1023
const GOOD_BLOCK2 = 1022

static func rebuild_superblock(memcard_path: String) -> bool:
	var superblock_path = memcard_path + "/_pcsx2_superblock"
	
	# Create fresh superblock
	var superblock = _create_fresh_superblock()
	
	# Get existing save folders
	var folders = _scan_save_folders(memcard_path)
	if folders.is_empty():
		print("[PS2MCRebuilder] No save folders found in: " + memcard_path)
		return false
	
	# Build directory entries
	var entries = _build_directory_entries(folders)
	
	# Inject entries into superblock
	_inject_entries(superblock, entries)
	
	# Save superblock
	var file = FileAccess.open(superblock_path, FileAccess.WRITE)
	if not file:
		push_error("[PS2MCRebuilder] Failed to write superblock: " + superblock_path)
		return false
	
	file.store_buffer(superblock)
	file.close()
	
	print("[PS2MCRebuilder] Rebuilt superblock with " + str(entries.size() - 2) + " save entries")
	return true

static func _create_fresh_superblock() -> PackedByteArray:
	var sb = PackedByteArray()
	sb.resize(SUPERBLOCK_SIZE)
	sb.fill(0)
	
	# Magic string (28 bytes)
	var magic = "Sony PS2 Memory Card Format "
	for i in range(magic.length()):
		sb[i] = magic.unicode_at(i)
	
	# Version (12 bytes): "1.2.0.0\0\0\0\0\0"
	var version = "1.2.0.0"
	for i in range(version.length()):
		sb[0x1C + i] = version.unicode_at(i)
	
	# Page size (2 bytes, little-endian): 512
	sb.encode_u16(0x28, 512)
	
	# Pages per cluster (2 bytes): 2
	sb.encode_u16(0x2A, 2)
	
	# Pages per erase block (2 bytes): 16
	sb.encode_u16(0x2C, 16)
	
	# Unused (2 bytes): 0xFF00
	sb.encode_u16(0x2E, 0xFF00)
	
	# Clusters per card (4 bytes): 8192
	sb.encode_u32(0x30, CLUSTERS_PER_CARD)
	
	# Allocatable cluster offset (4 bytes): 41
	sb.encode_u32(0x34, ALLOC_OFFSET)
	
	# Allocatable cluster end (4 bytes): 8135
	sb.encode_u32(0x38, ALLOC_END)
	
	# Rootdir cluster (4 bytes): 0
	sb.encode_u32(0x3C, 0)
	
	# Good block 1 (4 bytes): 1023
	sb.encode_u32(0x40, GOOD_BLOCK1)
	
	# Good block 2 (4 bytes): 1022
	sb.encode_u32(0x44, GOOD_BLOCK2)
	
	# Indirect FAT cluster list (128 bytes = 32 x uint32)
	# For standard card: indirect FAT is at cluster 8
	for i in range(32):
		var offset = 0x50 + (i * 4)
		if i == 0:
			sb.encode_u32(offset, 8)  # First indirect FAT cluster
		else:
			sb.encode_u32(offset, 0xFFFFFFFF)
	
	# Bad erase block list (128 bytes = 32 x uint32)
	# All 0xFFFFFFFF = no bad blocks
	for i in range(32):
		sb.encode_u32(0xD0 + (i * 4), 0xFFFFFFFF)
	
	# Card type (1 byte): 2
	sb[0x150] = 2
	
	# Card flags (1 byte): 0x2B
	sb[0x151] = 0x2B
	
	# Fill rest of first page with zeros (already done by fill(0))
	
	# Fill remaining pages with 0xFF (unallocated)
	for i in range(PAGE_SIZE, SUPERBLOCK_SIZE):
		sb[i] = 0xFF
	
	return sb

static func _scan_save_folders(memcard_path: String) -> Array[String]:
	var folders: Array[String] = []
	
	if not FileSystemManager.dir_exists(memcard_path):
		return folders
	
	var items = FileSystemManager.list_dir(memcard_path)
	for item in items:
		if item == "." or item == ".." or item == "_pcsx2_superblock":
			continue
		
		var full_path = memcard_path.rstrip("/") + "/" + item
		if FileSystemManager.dir_exists(full_path):
			# Validate name length (max 32 bytes for PS2)
			if item.length() > 32:
				push_warning("[PS2MCRebuilder] Save folder name too long (max 32 chars), skipping: " + item)
				continue
			
			folders.append(item)
	
	return folders

static func _build_directory_entries(folder_names: Array[String]) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var now = _get_jst_timestamp()
	
	# Entry 0: Root directory self-reference (".")
	entries.append({
		"mode": DF_RWX | DF_DIR | DF_0400 | DF_EXISTS,
		"length": folder_names.size() + 2,  # +2 for . and ..
		"created": now,
		"cluster": 0,
		"parent_entry": 0,
		"modified": now,
		"attr": 0,
		"name": "."
	})
	
	# Entry 1: Parent directory reference ("..")
	entries.append({
		"mode": DF_WRITE | DF_EXECUTE | DF_DIR | DF_0400 | DF_HIDDEN | DF_EXISTS,
		"length": 0,
		"created": now,
		"cluster": 0,
		"parent_entry": 0,
		"modified": now,
		"attr": 0,
		"name": ".."
	})
	
	# Entries 2+: Save folders
	for folder_name in folder_names:
		entries.append({
			"mode": DF_RWX | DF_DIR | DF_0400 | DF_EXISTS,
			"length": 2,  # . and .. entries inside
			"created": now,
			"cluster": 0xFFFFFFFF,  # No actual cluster for folder card
			"parent_entry": 0,
			"modified": now,
			"attr": 0,
			"name": folder_name
		})
	
	return entries

static func _get_jst_timestamp() -> Array[int]:
	# Get current UTC time and add 9 hours for JST
	var unix_time = Time.get_unix_time_from_system()
	unix_time += 9 * 3600  # JST = UTC+9
	
	# Convert to datetime
	var dict = Time.get_datetime_dict_from_unix_time(unix_time)
	
	# PS2 Time of Day format: [sec, min, hour, day, month, year]
	return [
		dict.second,
		dict.minute,
		dict.hour,
		dict.day,
		dict.month,
		dict.year
	]

static func _inject_entries(superblock: PackedByteArray, entries: Array[Dictionary]):
	# Directory entries start at offset 0 (right after header)
	# Each entry is 512 bytes
	# For PCSX2 folder cards, entries are packed sequentially
	
	for i in range(entries.size()):
		var entry = entries[i]
		var offset = i * DIRENT_SIZE
		
		# Mode (2 bytes, little-endian)
		superblock.encode_u16(offset, entry.mode)
		
		# Unknown/padding (2 bytes) - already zero
		
		# Length (4 bytes, little-endian)
		superblock.encode_u32(offset + 0x04, entry.length)
		
		# Created timestamp (8 bytes)
		_pack_timestamp(superblock, offset + 0x08, entry.created)
		
		# Cluster (4 bytes, little-endian)
		superblock.encode_u32(offset + 0x10, entry.cluster)
		
		# Parent entry (4 bytes, little-endian)
		superblock.encode_u32(offset + 0x14, entry.parent_entry)
		
		# Modified timestamp (8 bytes)
		_pack_timestamp(superblock, offset + 0x18, entry.modified)
		
		# Attr (4 bytes, little-endian)
		superblock.encode_u32(offset + 0x20, entry.attr)
		
		# Name (32 bytes, zero-terminated)
		var name = entry.name
		for j in range(min(name.length(), 32)):
			superblock[offset + DIRENT_OFFSET_NAME + j] = name.unicode_at(j)
		# Rest is already zero from fill(0)
	
	# Fill remaining directory space with 0xFF (unallocated entries)
	for i in range(entries.size() * DIRENT_SIZE, SUPERBLOCK_SIZE):
		superblock[i] = 0xFF

static func _pack_timestamp(data: PackedByteArray, offset: int, timestamp: Array[int]):
	# PS2 Time of Day format (8 bytes):
	# [unused, sec, min, hour, day, month, year(2 bytes)]
	data[offset + 0] = 0  # Unused
	data[offset + 1] = timestamp[0]  # sec
	data[offset + 2] = timestamp[1]  # min
	data[offset + 3] = timestamp[2]  # hour
	data[offset + 4] = timestamp[3]  # day
	data[offset + 5] = timestamp[4]  # month
	data.encode_u16(offset + 6, timestamp[5])  # year
