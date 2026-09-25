extends SceneTree

func _read_proc_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = []
	while not f.eof_reached():
		var chunk = f.get_buffer(1024)
		if chunk.size() == 0:
			break
		bytes.append_array(chunk)
	f.close()
	return bytes.get_string_from_utf8()

func _get_process_cmdline(pid: int) -> String:
	if pid <= 0:
		return ""
	var path = "/proc/" + str(pid) + "/cmdline"
	var content = _read_proc_file(path)
	var bytes = content.to_utf8_buffer()
	for i in range(bytes.size()):
		if bytes[i] == 0:
			bytes[i] = 32
	return bytes.get_string_from_utf8().strip_edges()

func _initialize():
	print("Scanning for full path signature...")
	var proc_dir := DirAccess.open("/proc")
	proc_dir.list_dir_begin()
	var entry := proc_dir.get_next()
	while entry != "":
		if entry.is_valid_int():
			var scan_pid := entry.to_int()
			var cmdline := _get_process_cmdline(scan_pid)
			if cmdline.find("/tmp/kyodai_test_roms/test_rom.cci") != -1:
				print("Found PID ", scan_pid, ": ", cmdline)
				break
		entry = proc_dir.get_next()
	proc_dir.list_dir_end()
	quit()
