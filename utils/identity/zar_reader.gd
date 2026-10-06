## Random-access reader for ZArchive (.zar) files
## ZArchive stores files as a directory tree over a single concatenated
## data stream, split into independent 64KiB zstd blocks. All multi-byte
## fields on disk are big-endian. Layout reference: Exzap/ZArchive.
## Used by TitleIDParser for Xbox 360 .zar ROMs (compressed ISO contents).
class_name ZarReader
extends RefCounted

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

const _BLOCK_SIZE = 64 * 1024
const _ENTRIES_PER_OFFSET_RECORD = 16
const _OFFSET_RECORD_SIZE = 40  # u64 baseOffset + 16 x u16 sizes
const _FILE_TREE_ENTRY_SIZE = 16
const _FOOTER_SIZE = 144
const _FOOTER_MAGIC = 0x169F52D6
const _FOOTER_VERSION = 0x61BF3A01
const _BLOCK_CACHE_LIMIT = 16  # 1 MiB of decompressed blocks

var _file: FileAccess
var _compressed_data_offset: int = 0
var _compressed_data_size: int = 0
var _offset_records := PackedByteArray()
var _name_table := PackedByteArray()
var _file_tree := PackedByteArray()
var _block_count: int = 0
var _block_cache := {}
var _block_cache_order: Array[int] = []

## FileAccess-like view over a single file node inside the archive.
## Offset zero maps to the node's start in the uncompressed stream.
class NodeIO:
	extends RefCounted

	var _reader  # ZarReader (untyped to avoid cyclic class reference)
	var _size: int = 0
	var _base: int = 0
	var _pos: int = 0

	func _init(reader, base_offset: int, size: int) -> void:
		_reader = reader
		_base = base_offset
		_size = size

	func seek(position: int) -> void:
		_pos = clampi(position, 0, _size)

	func get_position() -> int:
		return _pos

	func get_length() -> int:
		return _size

	func get_buffer(length: int) -> PackedByteArray:
		if length <= 0 or _pos >= _size:
			return PackedByteArray()
		var to_read = mini(length, _size - _pos)
		var data = _reader._read_at(_base + _pos, to_read)
		_pos += data.size()
		return data

## Opens a .zar file and parses its footer, offset records, name table and
## file tree. Returns null if the file is missing or not a valid archive.
static func open(path: String) -> ZarReader:
	if not FSM.file_exists(path):
		push_error("[ZarReader] File not found: " + path)
		return null

	var file = FSM.open_file_read(path)
	if not file:
		push_error("[ZarReader] Failed to open file: " + path)
		return null

	var file_size = file.get_length()
	if file_size <= _FOOTER_SIZE:
		push_error("[ZarReader] File too small to be a ZArchive: " + path)
		file.close()
		return null

	file.seek(file_size - _FOOTER_SIZE)
	var footer = file.get_buffer(_FOOTER_SIZE)
	if footer.size() < _FOOTER_SIZE:
		push_error("[ZarReader] Failed to read footer: " + path)
		file.close()
		return null

	var magic = _be_u32(footer, 140)
	var version = _be_u32(footer, 136)
	var total_size = _be_u64(footer, 128)
	if magic != _FOOTER_MAGIC or version != _FOOTER_VERSION:
		push_error("[ZarReader] Invalid ZArchive footer magic/version: " + path)
		file.close()
		return null
	if total_size != file_size:
		push_error("[ZarReader] ZArchive footer size mismatch: " + path)
		file.close()
		return null

	var reader = ZarReader.new()
	reader._file = file
	reader._compressed_data_offset = _be_u64(footer, 0)
	reader._compressed_data_size = _be_u64(footer, 8)
	var records_offset = _be_u64(footer, 16)
	var records_size = _be_u64(footer, 24)
	var names_offset = _be_u64(footer, 32)
	var names_size = _be_u64(footer, 40)
	var tree_offset = _be_u64(footer, 48)
	var tree_size = _be_u64(footer, 56)

	if records_size == 0 or records_size % _OFFSET_RECORD_SIZE != 0:
		push_error("[ZarReader] Invalid offset record section in: " + path)
		file.close()
		return null
	if tree_size == 0 or tree_size % _FILE_TREE_ENTRY_SIZE != 0:
		push_error("[ZarReader] Invalid file tree section in: " + path)
		file.close()
		return null

	reader._offset_records = reader._read_raw(records_offset, records_size)
	reader._name_table = reader._read_raw(names_offset, names_size)
	reader._file_tree = reader._read_raw(tree_offset, tree_size)
	if reader._offset_records.size() != records_size or reader._name_table.size() != names_size or reader._file_tree.size() != tree_size:
		push_error("[ZarReader] Failed to read ZArchive sections: " + path)
		file.close()
		return null

	reader._block_count = (records_size / _OFFSET_RECORD_SIZE) * _ENTRIES_PER_OFFSET_RECORD

	# First entry must be the unnamed root directory
	if reader._is_file_entry(0) or reader._get_name(reader._get_name_offset(0)) != "":
		push_error("[ZarReader] Invalid root node in: " + path)
		file.close()
		return null

	print("[ZarReader] Opened ZArchive: " + path + " (blocks=" + str(reader._block_count) + ", tree entries=" + str(tree_size / _FILE_TREE_ENTRY_SIZE) + ")")
	return reader

func close() -> void:
	if _file:
		_file.close()
		_file = null
	_block_cache.clear()
	_block_cache_order.clear()

## Recursively searches the archive file tree for a file by name
## (case-insensitive). Returns {offset, size} in the uncompressed stream,
## or an empty Dictionary if not found.
func find_file(filename: String) -> Dictionary:
	var target = filename.to_lower()
	var stack: Array[int] = [0]
	var guard = 0
	while not stack.is_empty() and guard < 1000000:
		guard += 1
		var index = stack.pop_back()
		if _is_file_entry(index):
			if _get_name(_get_name_offset(index)).to_lower() == target:
				return {
					"offset": _get_file_offset(index),
					"size": _get_file_size(index),
				}
		else:
			var start = _get_dir_start(index)
			var count = _get_dir_count(index)
			for i in range(start, start + count):
				stack.append(i)
	return {}

## Creates a FileAccess-like IO view over a node returned by find_file()
func create_node_io(node: Dictionary) -> NodeIO:
	return NodeIO.new(self, node.get("offset", 0), node.get("size", 0))

## Reads length bytes at a global uncompressed stream offset
func _read_at(global_offset: int, length: int) -> PackedByteArray:
	var result := PackedByteArray()
	var remaining = length
	var cursor = global_offset
	while remaining > 0:
		var block_index = cursor / _BLOCK_SIZE
		var block_offset = cursor % _BLOCK_SIZE
		var block = _get_block(block_index)
		if block.is_empty():
			break
		var step = mini(remaining, _BLOCK_SIZE - block_offset)
		result.append_array(block.slice(block_offset, block_offset + step))
		cursor += step
		remaining -= step
	return result

## Returns the decompressed 64KiB block for a block index, using the cache
func _get_block(block_index: int) -> PackedByteArray:
	if _block_cache.has(block_index):
		return _block_cache[block_index]

	var record_index = block_index / _ENTRIES_PER_OFFSET_RECORD
	var sub_index = block_index % _ENTRIES_PER_OFFSET_RECORD
	var record_base = record_index * _OFFSET_RECORD_SIZE
	if record_base + _OFFSET_RECORD_SIZE > _offset_records.size():
		return PackedByteArray()

	var offset = _be_u64(_offset_records, record_base)
	for i in range(sub_index):
		offset += _be_u16(_offset_records, record_base + 8 + i * 2) + 1
	var compressed_size = _be_u16(_offset_records, record_base + 8 + sub_index * 2) + 1

	if offset + compressed_size > _compressed_data_size:
		return PackedByteArray()

	var block := PackedByteArray()
	if compressed_size == _BLOCK_SIZE:
		# Stored uncompressed (compression was not beneficial)
		block = _read_raw(_compressed_data_offset + offset, compressed_size)
	else:
		var compressed = _read_raw(_compressed_data_offset + offset, compressed_size)
		if compressed.size() == compressed_size:
			block = compressed.decompress(_BLOCK_SIZE, FileAccess.COMPRESSION_ZSTD)
	if block.size() != _BLOCK_SIZE:
		push_warning("[ZarReader] Failed to load block " + str(block_index))
		return PackedByteArray()

	if _block_cache_order.size() >= _BLOCK_CACHE_LIMIT:
		var evict = _block_cache_order.pop_front()
		_block_cache.erase(evict)
	_block_cache[block_index] = block
	_block_cache_order.append(block_index)
	return block

## Reads raw bytes from the archive file itself
func _read_raw(offset: int, length: int) -> PackedByteArray:
	_file.seek(offset)
	return _file.get_buffer(length)

# ==================== File tree entry accessors ====================

func _is_file_entry(index: int) -> bool:
	return (_be_u32(_file_tree, index * _FILE_TREE_ENTRY_SIZE) & 0x80000000) != 0

func _get_name_offset(index: int) -> int:
	return _be_u32(_file_tree, index * _FILE_TREE_ENTRY_SIZE) & 0x7FFFFFFF

func _get_file_offset(index: int) -> int:
	var base = index * _FILE_TREE_ENTRY_SIZE
	var low = _be_u32(_file_tree, base + 4)
	var high = _be_u32(_file_tree, base + 12)
	return low | ((high & 0xFFFF) << 32)

func _get_file_size(index: int) -> int:
	var base = index * _FILE_TREE_ENTRY_SIZE
	var low = _be_u32(_file_tree, base + 8)
	var high = _be_u32(_file_tree, base + 12)
	return low | ((high & 0xFFFF0000) << 16)

func _get_dir_start(index: int) -> int:
	return _be_u32(_file_tree, index * _FILE_TREE_ENTRY_SIZE + 4)

func _get_dir_count(index: int) -> int:
	return _be_u32(_file_tree, index * _FILE_TREE_ENTRY_SIZE + 8)

## Resolves a name table offset to a string.
## Names have a 1-byte length prefix (2 bytes when the MSB is set, extending
## the length field to 15 bits) and Windows-1252 encoded characters.
func _get_name(name_offset: int) -> String:
	if name_offset == 0x7FFFFFFF or name_offset >= _name_table.size():
		return ""
	var first = _name_table[name_offset]
	var name_length: int
	var data_offset: int
	if (first & 0x80) != 0:
		if name_offset + 1 >= _name_table.size():
			return ""
		name_length = (first & 0x7F) | (_name_table[name_offset + 1] << 7)
		data_offset = name_offset + 2
	else:
		name_length = first & 0x7F
		data_offset = name_offset + 1
	if data_offset + name_length > _name_table.size():
		return ""
	return _name_table.slice(data_offset, data_offset + name_length).get_string_from_ascii()

# ==================== Big-endian decoding ====================

static func _be_u16(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 8) | bytes[offset + 1]

static func _be_u32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]

static func _be_u64(bytes: PackedByteArray, offset: int) -> int:
	var value = 0
	for i in range(8):
		value = (value << 8) | bytes[offset + i]
	return value
