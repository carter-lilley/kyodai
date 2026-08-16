## RomM-parity content hashing for save sync (gavel/negotiate support).
## Mirrors RomM's compute_content_hash: plain files hash as raw MD5;
## zip files hash as MD5 over the sorted "entry:md5(entry)" lines.
class_name ContentHash

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

static func _md5_bytes(data: PackedByteArray) -> String:
	var ctx = HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		return ""
	if ctx.update(data) != OK:
		return ""
	return ctx.finish().hex_encode()

## MD5 of raw file bytes, streamed.
static func compute_file_hash(path: String) -> String:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx = HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		f.close()
		return ""
	while f.get_position() < f.get_length():
		var chunk = f.get_buffer(mini(1048576, f.get_length() - f.get_position()))
		if ctx.update(chunk) != OK:
			f.close()
			return ""
	f.close()
	return ctx.finish().hex_encode()

static func _is_zip_file(path: String) -> bool:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic = f.get_buffer(4)
	f.close()
	if magic.size() < 4:
		return false
	return magic[0] == 0x50 and magic[1] == 0x4B and (magic[2] == 0x03 or magic[2] == 0x05 or magic[2] == 0x07)

## RomM's zip hash: MD5 of the sorted "name:md5(content)" lines of all
## non-directory entries.
static func compute_zip_hash(zip_path: String) -> String:
	var zr = ZIPReader.new()
	if zr.open(zip_path) != OK:
		return ""
	var lines: Array[String] = []
	for entry_name in zr.get_files():
		if entry_name.ends_with("/"):
			continue
		lines.append(entry_name + ":" + _md5_bytes(zr.read_file(entry_name)))
	zr.close()
	lines.sort()
	return _md5_bytes("\n".join(lines).to_utf8_buffer())

## RomM-parity hash for any file: zip-aware.
static func compute_content_hash(path: String) -> String:
	if _is_zip_file(path):
		return compute_zip_hash(path)
	return compute_file_hash(path)

## Simulates the zip hash of a folder as FSM.zip_directory() would pack it
## (relative entry names, optional root_name wrapper) without writing a zip.
## Used to hash local folder saves before negotiate decides anything.
static func compute_folder_zip_hash(dir_path: String, root_name: String = "") -> String:
	if not FSM.dir_exists(dir_path):
		return ""
	var prefix = (root_name + "/") if root_name != "" else ""
	var lines: Array[String] = []
	_collect_folder_hash_lines(dir_path, prefix, lines)
	lines.sort()
	return _md5_bytes("\n".join(lines).to_utf8_buffer())

static func _collect_folder_hash_lines(dir_path: String, zip_prefix: String, lines: Array[String]) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var filename = dir.get_next()
	while filename != "":
		if filename != "." and filename != "..":
			var full_path = dir_path + "/" + filename
			var zip_path = zip_prefix + filename
			if dir.current_is_dir():
				_collect_folder_hash_lines(full_path, zip_path + "/", lines)
			else:
				var f = FileAccess.open(full_path, FileAccess.READ)
				if f != null:
					var data = f.get_buffer(f.get_length())
					f.close()
					lines.append(zip_path + ":" + _md5_bytes(data))
		filename = dir.get_next()
	dir.list_dir_end()
