class_name M3Debug
extends RefCounted

## Conditional geometry/layout logging, gated by the internal
## debug_geometry_logging setting (set via console or config).
## Debug builds log by default; the setting can additionally force logging
## on in release builds.
## Usage: M3Debug.geom("tag", "message %s" % value) — prints "[Geom] tag: message"
## only when the setting is enabled.

static func geom(tag: String, text: String) -> void:
	if not _is_enabled():
		return
	print("[Geom] %s: %s" % [tag, text])

static func _is_enabled() -> bool:
	# Debug builds log by default; this check is thread-safe, unlike the
	# scene-tree access below (geom can fire from DB worker threads).
	if OS.is_debug_build():
		return true
	if not Engine.get_main_loop() is SceneTree:
		return false
	var root: Window = Engine.get_main_loop().root
	if not root.is_accessible_from_caller_thread():
		return false
	var dm = root.get_node_or_null("/root/DataManager")
	if dm != null:
		var setting = dm.get_setting("debug_geometry_logging")
		if setting != null and setting.value is bool and setting.value:
			return true
	return false
