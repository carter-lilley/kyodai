extends Node

func _ready():
	# Test if we can access the binary files
	var test_paths = [
		"res://bin/libchdr/win/chd_reader.exe",
		"res://bin/libchdr/android/chd_reader-arm64",
		"res://bin/cso_reader/android/cso_reader-arm64"
	]
	
	for path in test_paths:
		var exists = FileAccess.file_exists(path)
		print("File exists [" + str(exists) + "]: " + path)
		
		if exists:
			var file = FileAccess.open(path, FileAccess.READ)
			if file:
				var size = file.get_length()
				file.close()
				print("  Size: " + str(size) + " bytes")
			else:
				print("  ERROR: Cannot open file")
		else:
			print("  ERROR: File not found")