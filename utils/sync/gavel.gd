## GDScript port of romm-gavel (SPEC.md + reference/), conforming to:
##   - vectors/ladder/ (normative 409 resolution ladder)
##   - vectors/decision-table/ (full sync decision model)
## Pure functions: hashes/state in, decision out. No I/O, no engine deps.
## null and "" both mean "unknown" and never prove anything.
## Conformance is verified by utils/sync/run_gavel_vectors.gd.
class_name Gavel

const SHRINK_RATIO := 0.5

static func _is_known(h) -> bool:
	return h != null and h is String and h != ""

## Identity check: is the local file byte-identical to that server save?
## Provenance (primary): local unchanged since baseline AND the baseline was
## synced against this exact server content. Parity (fallback): local hash
## equals the server content hash directly.
static func local_matches_server(local_hash, server_content_hash, last_sync_hash, last_sync_server_hash) -> bool:
	if (
		_is_known(local_hash)
		and local_hash == last_sync_hash
		and _is_known(last_sync_server_hash)
		and last_sync_server_hash == server_content_hash
	):
		return true
	return _is_known(local_hash) and local_hash == server_content_hash

## The 409 resolution ladder. The server's 409 on an overwrite=false POST
## proves the slot's head moved past what this device last synced.
## Returns "download" or "conflict".
static func resolve_upload_conflict(local_hash, last_sync_hash, server_content_hash = null, last_sync_server_hash = null) -> String:
	# L1 - unchanged since baseline: nothing of ours to protect
	if _is_known(local_hash) and _is_known(last_sync_hash) and local_hash == last_sync_hash:
		return "download"
	# L2 - byte-identical to the current head: adopting loses nothing
	if local_matches_server(local_hash, server_content_hash, last_sync_hash, last_sync_server_hash):
		return "download"
	# L3 - genuine two-sided divergence: the user decides
	return "conflict"

## ISO-8601 -> epoch seconds; null on any parse failure (unparseable loses).
static func _parse_iso_to_epoch(value):
	if value == null or not value is String or value == "":
		return null
	var regex = RegEx.new()
	regex.compile("^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})?")
	var m = regex.search(value)
	if not m:
		return null
	var epoch = Time.get_unix_time_from_datetime_dict({
		"year": int(m.get_string(1)),
		"month": int(m.get_string(2)),
		"day": int(m.get_string(3)),
		"hour": int(m.get_string(4)),
		"minute": int(m.get_string(5)),
		"second": int(m.get_string(6)),
	})
	var tz = m.get_string(7)
	if tz != "" and tz != "Z":
		var tz_sign = -1 if tz.begins_with("-") else 1
		var digits = tz.substr(1).replace(":", "")
		epoch -= tz_sign * (int(digits.substr(0, 2)) * 3600 + int(digits.substr(2, 2)) * 60)
	return epoch

## A 0-byte file is never a plausible edit; below half the recorded baseline
## size is a truncated write. Unknown sizes never fire the guard.
static func is_implausibly_shrunken(new_size, baseline_size) -> bool:
	if new_size == null:
		return false
	if new_size == 0:
		return true
	if baseline_size == null or baseline_size <= 0:
		return false
	return new_size < baseline_size * SHRINK_RATIO

static func _local_mtime_ge_head(local_file: Dictionary, head: Dictionary) -> bool:
	var local_mtime = local_file.get("mtime")
	if local_mtime == null or not (local_mtime is int or local_mtime is float):
		return false
	var head_epoch = _parse_iso_to_epoch(head.get("updated_at", ""))
	if head_epoch == null:
		return false
	return local_mtime >= head_epoch

static func _skip(reason: String, adopt_baseline: bool = false) -> Dictionary:
	return {"action": "skip", "reason": reason, "adopt_baseline": adopt_baseline}

static func _upload(target_save_id) -> Dictionary:
	return {"action": "upload", "target_save_id": target_save_id}

static func _download(head: Dictionary) -> Dictionary:
	return {"action": "download", "server_save_id": head["id"]}

static func _conflict(head: Dictionary) -> Dictionary:
	return {"action": "conflict", "server_save_id": head["id"]}

static func _decide_when_is_current(head: Dictionary, local_file, local_hash, last_sync_hash, last_sync_local_size) -> Dictionary:
	if local_file == null:
		return _download(head)
	if not _is_known(last_sync_hash):
		return _skip("synced", true)
	if _is_known(local_hash) and local_hash != last_sync_hash:
		if is_implausibly_shrunken(local_file.get("size"), last_sync_local_size):
			return _conflict(head)
		return _upload(head.get("id"))
	return _skip("synced")

static func _decide_when_not_current(head: Dictionary, local_file, local_hash, last_sync_hash, last_sync_server_hash) -> Dictionary:
	if local_file == null:
		return _download(head)
	if not _is_known(last_sync_hash):
		if local_matches_server(local_hash, head.get("content_hash"), last_sync_hash, last_sync_server_hash):
			return _download(head)
		return _conflict(head)
	if _is_known(local_hash) and local_hash != last_sync_hash:
		if local_matches_server(local_hash, head.get("content_hash"), last_sync_hash, last_sync_server_hash):
			return _download(head)
		return _conflict(head)
	return _download(head)

static func _decide_when_no_entry(head: Dictionary, local_file, local_hash, last_sync_hash, last_sync_server_hash) -> Dictionary:
	if local_file == null:
		return _download(head)
	if local_matches_server(local_hash, head.get("content_hash"), last_sync_hash, last_sync_server_hash):
		return _skip("synced", true)
	if _is_known(last_sync_hash) and _is_known(local_hash) and local_hash != last_sync_hash:
		return _conflict(head)
	if not _is_known(last_sync_hash) and _is_known(local_hash):
		return _conflict(head)
	if _local_mtime_ge_head(local_file, head):
		return _upload(null)
	return _download(head)

## The full per-(rom, filename, slot) decision.
## local_file: {filename, size, mtime} or null (null = no local file;
## a present-but-fieldless dictionary is still a present file).
## files_state: bookkeeping record {last_sync_hash, last_sync_server_hash,
## last_sync_local_size} — keys may be absent.
static func compute_sync_action(local_file, server_saves_in_slot: Array, files_state: Dictionary, device_id: String, local_hash) -> Dictionary:
	if server_saves_in_slot.is_empty():
		if local_file != null:
			return _upload(null)
		return _skip("nothing_to_sync")

	var head: Dictionary = server_saves_in_slot[0]
	var head_epoch = _parse_iso_to_epoch(head.get("updated_at"))
	var head_key := float(head_epoch) if head_epoch != null else 0.0
	for save in server_saves_in_slot:
		var epoch = _parse_iso_to_epoch(save.get("updated_at"))
		var key := float(epoch) if epoch != null else 0.0
		if key > head_key:
			head = save
			head_key = key

	var device_syncs = head.get("device_syncs")
	if device_syncs == null:
		device_syncs = []
	var our_entry = null
	for ds in device_syncs:
		if ds.get("device_id") == device_id:
			our_entry = ds
			break
	var last_sync_hash = files_state.get("last_sync_hash")
	var last_sync_server_hash = files_state.get("last_sync_server_hash")
	var last_sync_local_size = files_state.get("last_sync_local_size")

	if our_entry != null and our_entry.get("is_current"):
		return _decide_when_is_current(head, local_file, local_hash, last_sync_hash, last_sync_local_size)
	if our_entry != null:
		return _decide_when_not_current(head, local_file, local_hash, last_sync_hash, last_sync_server_hash)
	return _decide_when_no_entry(head, local_file, local_hash, last_sync_hash, last_sync_server_hash)
