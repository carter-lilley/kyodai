## Headless conformance runner for the gavel GDScript port.
## Executes every JSON vector under bin/src/romm-gavel/vectors/ against
## utils/gavel.gd and diffs against each vector's expected value.
## Usage: godot --headless --path . -s tools/run_gavel_vectors.gd
## Exit code 0 = all vectors pass, 1 = any failure.
extends SceneTree

const Gavel = preload("res://utils/gavel.gd")

const VECTOR_FILES := [
	"res://bin/src/romm-gavel/vectors/ladder/named-cases.json",
	"res://bin/src/romm-gavel/vectors/ladder/equivalence-classes.json",
	"res://bin/src/romm-gavel/vectors/decision-table/named-cases.json",
]

var _failures := 0
var _total := 0

func _init() -> void:
	for path in VECTOR_FILES:
		_run_file(path)
	print("[gavel-vectors] %d/%d vectors passed, %d failed" % [_total - _failures, _total, _failures])
	quit(1 if _failures > 0 else 0)

func _run_file(path: String) -> void:
	var text = FileAccess.get_file_as_string(path)
	if text == "":
		_fail(path, "file missing or empty")
		return
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		_fail(path, "invalid JSON")
		return
	var family: String = data.get("family", "")
	for vector in data.get("vectors", []):
		_total += 1
		var name: String = vector.get("name", "?")
		var input: Dictionary = vector.get("input", {})
		var expected = vector.get("expected")
		var got
		match family:
			"upload-409-ladder":
				got = Gavel.resolve_upload_conflict(
					input.get("local_hash"),
					input.get("last_sync_hash"),
					input.get("server_content_hash"),
					input.get("last_sync_server_hash"))
			"decision-table":
				got = Gavel.compute_sync_action(
					input.get("local_file"),
					input.get("server_saves_in_slot", []),
					input.get("files_state", {}),
					input.get("device_id", ""),
					input.get("local_hash"))
			_:
				_fail(name, "unknown family: " + family)
				continue
		if not _matches(expected, got):
			_fail(name, "expected %s, got %s" % [str(expected), str(got)])

func _matches(expected, got) -> bool:
	if expected is String or expected == null:
		return expected == got
	if expected is Dictionary and got is Dictionary:
		if expected.size() != got.size():
			return false
		for key in expected:
			if not got.has(key) or got[key] != expected[key]:
				return false
		return true
	return false

func _fail(name: String, message: String) -> void:
	_failures += 1
	printerr("[gavel-vectors] FAIL %s: %s" % [name, message])
