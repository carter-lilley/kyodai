extends Manager
class_name SessionSubManager

## Owns live GameSession objects and the single terminal-finalization path.
## ProcessSubManager owns OS-specific launch/watch mechanics; these signals
## are the canonical lifecycle contract for UI and session consumers.
signal session_changed(session: GameSession)
signal session_activated(session: GameSession, legacy_pid: int)
signal session_finalized(session: GameSession, exit_code: int)

const PENDING_SESSION_DIR := "user://pending_game_sessions"
const LEGACY_PENDING_SESSION_PATH := "user://pending_game_session.json"

var _sessions: Dictionary = {}  # session_id -> GameSession

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
	_write_pending_record(session)
	_start_native_watch(session)
	session_activated.emit(session, legacy_pid)
	session_changed.emit(session)

func retain_session(session: GameSession) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.state = GameSession.State.RETAINED
	session_changed.emit(session)

func resume_session(session: GameSession) -> void:
	if session == null or session.state == GameSession.State.ENDED:
		return
	session.state = GameSession.State.ACTIVE
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
	session_activated.emit(session, int(runtime.get("pid", -1)))
	session_changed.emit(session)
	return session

## Terminal finalization is idempotent: repeated lifecycle notifications cannot
## double-credit playtime, delete another session's record, or upload twice.
func finalize_once(session: GameSession, exit_code: int = 0, reason: String = "ended", recovered: bool = false) -> bool:
	if session == null or session.state == GameSession.State.ENDED:
		return false
	session.state = GameSession.State.CLOSING
	var record := _read_pending_record(session.pending_path)
	var end_unix := float(record.get("end_unix", 0.0))
	var elapsed := session.recovered_elapsed_seconds(end_unix) if recovered else session.elapsed_seconds(end_unix)
	session.state = GameSession.State.ENDED
	_sessions.erase(session.session_id)
	_stop_native_watch(session)
	_delete_pending_record(session.pending_path)
	_commit_play_seconds(session, elapsed)
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

func get_session(session_id: String) -> GameSession:
	return _sessions.get(session_id, null)

func get_live_for_game(romm_id: int) -> GameSession:
	for session in _sessions.values():
		if session.romm_id == romm_id and session.state != GameSession.State.ENDED:
			return session
	return null

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
	var err := DirAccess.make_dir_recursive_absolute(PENDING_SESSION_DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("[SessionManager] Could not create pending-session directory: " + error_string(err))
		return
	var f := FileAccess.open(session.pending_path, FileAccess.WRITE)
	if not f:
		push_warning("[SessionManager] Could not write pending session: " + error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(session.pending_record()))
	f.close()

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
		session.session_id
	)

func _stop_native_watch(_session: GameSession) -> void:
	if SystemManager.platform.is_android():
		SystemManager.platform.stop_game_session_foreground_service()

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
	return not session.is_shuffler() and session.romm_id != 0 and not LaunchManager.is_session_active()

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
