extends Manager
class_name SessionSubManager

## Owns live GameSession objects and the single terminal-finalization path.
## ProcessSubManager owns OS-specific launch/watch mechanics; these signals
## are the canonical lifecycle contract for UI and session consumers.
signal session_changed(session: GameSession)
signal session_activated(session: GameSession, legacy_pid: int)
signal session_retained(session: GameSession)
signal session_resumed(session: GameSession)
signal session_finalized(session: GameSession, exit_code: int)

const PENDING_SESSION_DIR := "user://pending_game_sessions"
const LEGACY_PENDING_SESSION_PATH := "user://pending_game_session.json"
const PLAY_SESSION_OUTBOX_DIR := "user://pending_play_sessions"

var _sessions: Dictionary = {}  # session_id -> GameSession
var _activity_session_id := ""
var _activity_romm_id := 0
var _play_session_inflight: Dictionary = {}
var _device_registration_inflight := false
var _device_waiters: Array[Callable] = []

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(PLAY_SESSION_OUTBOX_DIR)
	if SystemManager.network:
		SystemManager.network.network_status_changed.connect(_on_reporting_network_changed)
	call_deferred("_retry_play_session_outbox")

func begin_session(game: GameResource, backend: GameSession.Backend, metadata: Dictionary = {}) -> GameSession:
	var session := GameSession.new_session(game, backend, metadata)
	_sessions[session.session_id] = session
	_write_pending_record(session)
	session_changed.emit(session)
	return session

func activate_session(session: GameSession, legacy_pid: int) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.state = GameSession.State.ACTIVE
	session.resume_playtime()
	_write_pending_record(session)
	_start_native_watch(session)
	_start_activity_reporting(session)
	session_activated.emit(session, legacy_pid)
	session_changed.emit(session)

func retain_session(session: GameSession, emit_signal: bool = true) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.state = GameSession.State.RETAINED
	session.pause_playtime()
	_write_pending_record(session)
	_start_native_watch(session)
	_stop_activity_reporting(session)
	if emit_signal:
		session_retained.emit(session)
	session_changed.emit(session)

func resume_session(session: GameSession) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.state = GameSession.State.ACTIVE
	session.resume_playtime()
	_write_pending_record(session)
	_start_activity_reporting(session)
	session_resumed.emit(session)
	session_changed.emit(session)

## Reattaches a pending record after launcher process death. The original
## start_unix is retained and no new play session or save upload is started.
func reattach_session(record: Dictionary, game: GameResource, runtime: Dictionary) -> GameSession:
	var session := GameSession.from_pending(record, game)
	if session.session_id.is_empty():
		return null
	session.runtime = runtime.duplicate(true)
	# Recovery transfers ownership to this process before the record becomes
	# visible again, preventing a third launcher from adopting the same game.
	session.owner = GameSession.current_owner()
	_sessions[session.session_id] = session
	_write_pending_record(session)
	_start_native_watch(session)
	_start_activity_reporting(session)
	session_activated.emit(session, int(runtime.get("pid", -1)))
	session_changed.emit(session)
	return session

func abort_session(session: GameSession) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.state = GameSession.State.CLOSING
	_sessions.erase(session.session_id)
	_stop_native_watch(session)
	_stop_activity_reporting(session)
	_delete_pending_record(session.pending_path)
	session.state = GameSession.State.ENDED
	# A failed handoff restores UI but never credits playtime or uploads saves.
	session_finalized.emit(session, 0)
	session_changed.emit(session)

## Terminal finalization is idempotent: repeated lifecycle notifications cannot
## double-credit playtime, delete another session's record, or upload twice.
func finalize_once(session: GameSession, exit_code: int = 0, reason: String = "ended", recovered: bool = false) -> bool:
	if session == null or session.state == GameSession.State.ENDED:
		return false
	session.state = GameSession.State.CLOSING
	var record := _read_pending_record(session.pending_path)
	var end_unix := float(record.get("end_unix", 0.0))
	# Compute before pause clears last_resume_*: native end_unix must clamp the
	# currently running segment instead of crediting through launcher recovery.
	var elapsed := session.recovered_elapsed_seconds(end_unix) if recovered else session.elapsed_seconds(end_unix)
	session.pause_playtime()
	session.state = GameSession.State.ENDED
	_sessions.erase(session.session_id)
	_stop_native_watch(session)
	_stop_activity_reporting(session)
	if not _queue_play_session_ingest(session, end_unix, elapsed):
		# Keep the original recovery record if the durable outbox cannot be
		# written; a later recovery is preferable to silently losing playtime.
		push_warning("[SessionManager] Could not persist completed play-session outbox")
	else:
		_delete_pending_record(session.pending_path)
	_commit_play_seconds(session, elapsed)
	if session.game:
		DataManager.set_game_user_props(session.game, {"now_playing": false}, true, false)
	session_finalized.emit(session, exit_code)
	session_changed.emit(session)
	_queue_save_upload(session, reason)
	return true

func game_for_record(romm_id: int) -> GameResource:
	if romm_id > 0:
		return DataManager.get_game_by_id(romm_id)
	if romm_id < 0:
		for game in LaunchManager.steam_create_game_resources():
			if game.romm_id == romm_id:
				return game
	return null

func finalize_pending_record(record: Dictionary, reason: String = "recovered") -> bool:
	var romm_id := int(record.get("romm_id", 0))
	if float(record.get("start_unix", 0.0)) <= 0.0:
		_delete_pending_record(str(record.get("_pending_path", "")))
		return false
	var game := game_for_record(romm_id)
	var session := GameSession.from_pending(record, game)
	if session.session_id.is_empty():
		# Legacy records have no ID; give them a stable identity for this one
		# finalization without changing their original accounting fields.
		session.session_id = "legacy-%d" % int(session.start_unix * 1000.0)
	return finalize_once(session, 0, reason, true)

func update_runtime(session: GameSession, runtime: Dictionary) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.runtime.merge(runtime, true)
	_write_pending_record(session)
	session_changed.emit(session)

func get_session(session_id: String) -> GameSession:
	return _sessions.get(session_id, null)

func get_live_for_game(romm_id: int) -> GameSession:
	for session in _sessions.values():
		if session.romm_id == romm_id and session.state != GameSession.State.ENDED:
			return session
	return null

func get_live_for_package(package_name: String) -> Array[GameSession]:
	var result: Array[GameSession] = []
	for session in _sessions.values():
		if session.state != GameSession.State.ENDED and str(session.runtime.get("package", "")) == package_name:
			result.append(session)
	return result

func mark_lost(record: Dictionary, game: GameResource) -> GameSession:
	var session := GameSession.from_pending(record, game)
	if session.session_id.is_empty():
		return null
	var existing: GameSession = _sessions.get(session.session_id, null)
	if existing and existing.state != GameSession.State.ENDED:
		return existing
	session.owner = GameSession.current_owner()
	session.state = GameSession.State.LOST
	_stop_activity_reporting(session)
	session.pause_playtime()
	_write_pending_record(session)
	_sessions[session.session_id] = session
	session_changed.emit(session)
	return session

func pending_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for path in _pending_paths():
		var record := _read_pending_record(path)
		if record.is_empty():
			continue
		record["_pending_path"] = path
		records.append(record)
	return records

static func pending_path_for(session_id: String) -> String:
	return PENDING_SESSION_DIR.path_join(session_id + ".json")

func _pending_paths() -> Array[String]:
	var paths: Array[String] = []
	if FileAccess.file_exists(LEGACY_PENDING_SESSION_PATH):
		paths.append(LEGACY_PENDING_SESSION_PATH)
	var dir := DirAccess.open(PENDING_SESSION_DIR)
	if dir:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while not entry.is_empty():
			if not dir.current_is_dir() and entry.ends_with(".json"):
				paths.append(PENDING_SESSION_DIR.path_join(entry))
			entry = dir.get_next()
		dir.list_dir_end()
	return paths

func _write_pending_record(session: GameSession) -> void:
	if session.pending_path.is_empty():
		# An older Android AAR can only annotate the legacy single file. Keep
		# filename choice aligned with that native capability so end_unix is
		# never written beside the record the registry actually reads.
		if SystemManager.platform.is_android() and not SystemManager.platform.supports_per_session_pending_records():
			session.pending_path = LEGACY_PENDING_SESSION_PATH
		else:
			session.pending_path = pending_path_for(session.session_id)
	if session.end_unix <= 0.0:
		# Preserve a native completion annotation across GDScript runtime
		# updates instead of erasing it with a full-record rewrite.
		var existing := _read_pending_record(session.pending_path)
		session.end_unix = float(existing.get("end_unix", 0.0))
	var err := DirAccess.make_dir_recursive_absolute(PENDING_SESSION_DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("[SessionManager] Could not create pending-session directory: " + error_string(err))
		return
	var temp_path := session.pending_path + ".tmp"
	var f := FileAccess.open(temp_path, FileAccess.WRITE)
	if not f:
		push_warning("[SessionManager] Could not write pending session: " + error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(session.pending_record()))
	f.flush()
	f.close()
	if DirAccess.rename_absolute(temp_path, session.pending_path) != OK:
		push_warning("[SessionManager] Could not publish pending session atomically")
		DirAccess.remove_absolute(temp_path)

static func _read_pending_record(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}

static func _delete_pending_record(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _start_native_watch(session: GameSession) -> void:
	if not SystemManager.platform.is_android():
		return
	SystemManager.platform.start_game_session_foreground_service(
		session.title,
		int(session.start_unix) * 1000,
		str(session.runtime.get("package", "")),
		session.romm_id,
		session.session_id,
		session.state == GameSession.State.RETAINED
	)

func _stop_native_watch(_session: GameSession) -> void:
	if SystemManager.platform.is_android():
		SystemManager.platform.stop_game_session_foreground_service()

func _queue_play_session_ingest(session: GameSession, end_unix: float, elapsed_seconds: int) -> bool:
	if not _should_report_play_session(session) or elapsed_seconds <= 0 or session.start_unix <= 0.0:
		return true
	var duration_ms := maxi(0, elapsed_seconds * 1000)
	var confirmed_end := end_unix if end_unix > session.start_unix else Time.get_unix_time_from_system()
	confirmed_end = maxf(confirmed_end, session.start_unix + maxf(1.0, float(elapsed_seconds)))
	var entry := {
		"rom_id": session.romm_id,
		"start_time": Time.get_datetime_string_from_unix_time(int(session.start_unix)) + "Z",
		"end_time": Time.get_datetime_string_from_unix_time(int(confirmed_end)) + "Z",
		"duration_ms": duration_ms,
	}
	var record := {
		"session_id": session.session_id,
		"attempts": 0,
		"payload": {"device_id": "", "sessions": [entry]},
	}
	var path := PLAY_SESSION_OUTBOX_DIR.path_join(session.session_id + ".json")
	if not _write_play_session_record(path, record):
		return false
	call_deferred("_send_play_session_outbox", path)
	return true

func _write_play_session_record(path: String, record: Dictionary) -> bool:
	var directory_error := DirAccess.make_dir_recursive_absolute(PLAY_SESSION_OUTBOX_DIR)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return false
	var temp := path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if not file:
		return false
	file.store_string(JSON.stringify(record))
	file.flush()
	file.close()
	if DirAccess.rename_absolute(temp, path) != OK:
		DirAccess.remove_absolute(temp)
		return false
	return true

func _on_reporting_network_changed(online: bool) -> void:
	if not online:
		return
	if not _activity_session_id.is_empty():
		_with_reporting_device(func(device_id: String):
			if not device_id.is_empty() and not _activity_session_id.is_empty():
				SystemManager.network.start_activity_reporting(_activity_romm_id, device_id)
		)
	_retry_play_session_outbox()

func _retry_play_session_outbox() -> void:
	if not SystemManager.network or not SystemManager.network.is_online():
		return
	var directory := DirAccess.open(PLAY_SESSION_OUTBOX_DIR)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not directory.current_is_dir() and entry.ends_with(".json"):
			_send_play_session_outbox(PLAY_SESSION_OUTBOX_DIR.path_join(entry))
		entry = directory.get_next()
	directory.list_dir_end()

func _send_play_session_outbox(path: String) -> void:
	if _play_session_inflight.has(path) or not SystemManager.network or not SystemManager.network.is_online():
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var record = JSON.parse_string(file.get_as_text())
	file.close()
	if not (record is Dictionary) or not (record.get("payload", {}) is Dictionary):
		return
	_play_session_inflight[path] = true
	_with_reporting_device(func(device_id: String):
		if device_id.is_empty():
			_play_session_inflight.erase(path)
			return
		var payload: Dictionary = record.payload.duplicate(true)
		payload["device_id"] = device_id
		SystemManager.network.ingest_play_sessions(device_id, payload.get("sessions", []), func(data: Variant, error: String):
			_play_session_inflight.erase(path)
			if not error.is_empty():
				_record_play_session_error(path, error)
				return
			var accepted := false
			if data is Dictionary:
				var results: Array = data.get("results", [])
				accepted = not results.is_empty()
				for result in results:
					if not (result is Dictionary) or str(result.get("status", "")) not in ["created", "duplicate"]:
						accepted = false
						break
			if accepted:
				DirAccess.remove_absolute(path)
			else:
				_record_play_session_error(path, "RomM rejected completed play-session ingestion")
		)
	)

func _record_play_session_error(path: String, error: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var record = JSON.parse_string(file.get_as_text())
	file.close()
	if not (record is Dictionary):
		return
	record["attempts"] = int(record.get("attempts", 0)) + 1
	record["last_error"] = error
	_write_play_session_record(path, record)

func _should_report_play_session(session: GameSession) -> bool:
	if session == null or session.romm_id <= 0 or session.backend == GameSession.Backend.UNKNOWN:
		return false
	if session.is_shuffler():
		return false
	# Steam/GameNative/DroidDeck sessions are externally owned and do not map
	# cleanly to Kyodai's emulator session identity or RomM ROM IDs.
	if session.game and session.game.source == "steam":
		return false
	return true

func _start_activity_reporting(session: GameSession) -> void:
	if not _should_report_play_session(session) or not SystemManager.network:
		return
	if _activity_session_id == session.session_id:
		return
	if not _activity_session_id.is_empty():
		SystemManager.network.stop_activity_reporting()
	_activity_session_id = session.session_id
	_activity_romm_id = session.romm_id
	_with_reporting_device(func(device_id: String):
		if device_id.is_empty() or _activity_session_id != session.session_id or session.state != GameSession.State.ACTIVE:
			return
		SystemManager.network.start_activity_reporting(session.romm_id, device_id)
	)

func _stop_activity_reporting(session: GameSession) -> void:
	if session == null or _activity_session_id != session.session_id:
		return
	_activity_session_id = ""
	_activity_romm_id = 0
	if SystemManager.network:
		SystemManager.network.stop_activity_reporting()

func _with_reporting_device(callback: Callable) -> void:
	var device_id := DataManager.get_romm_device_id()
	if not device_id.is_empty():
		callback.call(device_id)
		return
	if not DataManager.game_save:
		callback.call("")
		return
	_device_waiters.append(callback)
	if _device_registration_inflight:
		return
	_device_registration_inflight = true
	DataManager.game_save._ensure_device_registered(func(success: bool, _error: String):
		var resolved := DataManager.get_romm_device_id() if success else ""
		var waiters := _device_waiters.duplicate()
		_device_waiters.clear()
		_device_registration_inflight = false
		for waiter in waiters:
			waiter.call(resolved)
	)

func _should_credit_playtime(session: GameSession) -> bool:
	# Shuffler has always bypassed ordinary play-session accounting.
	return not session.is_shuffler()

## Seams for isolated characterization tests and future non-DB session writers.
func _commit_play_seconds(session: GameSession, seconds: int) -> void:
	if seconds <= 0 or session.romm_id <= 0 or not _should_credit_playtime(session):
		return
	if session.game:
		session.game.play_seconds += seconds
	DataManager.add_game_play_seconds(session.romm_id, seconds)
	print("[SessionManager] Session playtime for ", session.title, ": ", seconds, "s")

func _should_upload_saves(session: GameSession) -> bool:
	# Standalone emulator sessions have no library save-sync identity. Steam's
	# negative IDs remain valid and continue through the normal game path.
	return not session.is_shuffler() and session.romm_id != 0

func _queue_save_upload(session: GameSession, _reason: String) -> void:
	if not _should_upload_saves(session):
		return
	var game := session.game
	if game == null and session.romm_id != 0:
		game = game_for_record(session.romm_id)
	if game == null:
		return
	var emulator_id := session.emulator_id
	if emulator_id.is_empty():
		emulator_id = LaunchManager.resolve_emulator_for_game(game)
	if emulator_id.is_empty():
		return
	DataManager.auto_upload_saves_for_game.call_deferred(game, emulator_id)
