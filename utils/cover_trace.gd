extends RefCounted
## Opt-in diagnostics for the cover download, disk-cache, and decode pipeline.
##
## Enable with KYODAI_COVER_TRACE=1 before launch. Callers use stable URL/path
## hashes instead of logging credentials or full cover URLs. All helpers are
## cheap no-ops while tracing is disabled.

static var enabled: bool = OS.get_environment("KYODAI_COVER_TRACE") == "1"

static func event(layer: String, action: String, fields: Dictionary = {}) -> void:
	if not enabled:
		return
	_write("CoverTrace", layer, action, fields)

static func state(fields: Dictionary) -> void:
	if not enabled:
		return
	_write("CoverState", "pipeline", "snapshot", fields)

static func id_for(value: String) -> String:
	## A short correlation ID that does not expose URL query credentials or
	## user-specific cache paths. The full MD5 remains available in the cache
	## filename when a failing cover needs to be inspected on disk.
	if value.is_empty():
		return "none"
	return value.md5_text().substr(0, 12)

static func trace_id(value: String) -> String:
	## Event arguments are evaluated before event() can check `enabled`, so
	## production call sites use this guard to avoid hashing URLs on normal runs.
	return id_for(value) if enabled else ""

static func _write(prefix: String, layer: String, action: String, fields: Dictionary) -> void:
	var line := "[%s] t=%d layer=%s event=%s" % [prefix, Time.get_ticks_msec(), layer, action]
	for key in fields:
		var value = fields[key]
		if value is float:
			value = "%.2f" % value
		var text := str(value).replace("\n", "\\n").replace("\r", "\\r")
		line += " %s=%s" % [key, text]
	print(line)
