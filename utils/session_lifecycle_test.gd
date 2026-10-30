extends Node

## Headless characterization coverage for the shared session lifecycle.
## Run with isolated user storage, for example:
##   HOME=/tmp/kyodai-test-home godot --headless --path . res://utils/session_lifecycle_test.tscn

var _failures := 0
var _fixtures: Array[Node] = []

class SpySessions:
	extends SessionSubManager
	var commits: Array = []
	var uploads: Array = []
	var native_starts: Array = []
	var native_stops: Array = []

	func _ready() -> void:
		pass

	func _commit_play_seconds(session: GameSession, seconds: int) -> void:
		if not _should_credit_playtime(session):
			return
		commits.append([session.romm_id, seconds])

	func _queue_save_upload(session: GameSession, reason: String) -> void:
		if not _should_upload_saves(session):
			return
		uploads.append([session.romm_id, reason])

	func _start_native_watch(session: GameSession) -> void:
		native_starts.append(session.session_id)

	func _stop_native_watch(session: GameSession) -> void:
		native_stops.append(session.session_id)

class FakeFacade:
	extends Node
	var sessions: SpySessions
	var entered: Array = []
	var exited: Array = []

	func wire() -> void:
		sessions.session_activated.connect(func(session, legacy_pid):
			entered.append([legacy_pid, session.game])
		)
		sessions.session_finalized.connect(func(session, exit_code):
			exited.append([session.game, exit_code])
		)

	func resolve_emulator_for_game(_game: GameResource) -> String:
		return "test_emulator"

class ProcessDouble:
	extends ProcessSubManager
	var pending_game: GameResource = null
	var signature_match_pid: int = -1

	func _ready() -> void:
		launch_manager = get_parent()
		_background_poll_timer = Timer.new()
		add_child(_background_poll_timer)

	func _game_for_pending_session(_romm_id: int) -> GameResource:
		return pending_game

	func find_process_by_signature(_signature: String, _exe_signature: String = "") -> int:
		return signature_match_pid

class HeadlessDouble:
	extends HeadlessLaunchRunner
	var finalizations: Array = []
	var waits: Array = []

	func _finalize_session(session: GameSession) -> void:
		finalizations.append([session.romm_id, session.emulator_id])

	func _await_upload_completion(game: GameResource, emulator_id: String) -> void:
		waits.append([game.romm_id, emulator_id])

func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK   ", message)
	else:
		_failures += 1
		print("FAIL ", message)

func _game(id: int, title: String = "Test Game") -> GameResource:
	var game := GameResource.new()
	game.id = "session-test-%d" % id
	game.romm_id = id
	game.title = title
	game.platform_slug = "test"
	return game

func _fixture() -> Array:
	var facade := FakeFacade.new()
	var sessions := SpySessions.new()
	facade.sessions = sessions
	var process := ProcessDouble.new()
	add_child(facade)
	facade.add_child(sessions)
	facade.add_child(process)
	facade.wire()
	_fixtures.append(facade)
	return [facade, sessions, process]

func _delete_pending(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _write_record(path: String, record: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(record))
	f.close()

func _read_record(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	for i in 5:
		await get_tree().process_frame
	_check(not SessionFeatureFlags.enabled(SessionFeatureFlags.ANDROID_RETAINED_SESSIONS), "Android retained sessions remain opt-in")
	_check(not SessionFeatureFlags.enabled(SessionFeatureFlags.ANDROID_TASK_SNAPSHOTS), "Android snapshots remain opt-in")
	_check(not SessionFeatureFlags.enabled(SessionFeatureFlags.ANDROID_DISPLAY_TASK_MOVE), "Android display moves remain opt-in")

	await _test_desktop_launch_exit_and_duplicates()
	await _test_android_resume_is_terminal()
	await _test_playtime_annotation_and_recovery()
	await _test_steam_recovery()
	await _test_recovery_claim()
	await _test_desktop_reattach()
	await _test_leaderless_group_reattach()
	await _test_headless_post_launch_upload()

	for fixture in _fixtures:
		if is_instance_valid(fixture):
			fixture.queue_free()
	await get_tree().process_frame
	if _failures == 0:
		print("SESSION LIFECYCLE TEST PASSED")
	else:
		print("SESSION LIFECYCLE TEST FAILED: ", _failures)
	get_tree().quit(_failures)

func _test_desktop_launch_exit_and_duplicates() -> void:
	var fixture := _fixture()
	var facade: FakeFacade = fixture[0]
	var sessions: SpySessions = fixture[1]
	var process: ProcessDouble = fixture[2]
	var game := _game(101, "Desktop Game")
	process.enter_background_state(987654, game)
	var session: GameSession = process._active_session
	_check(session != null, "desktop launch creates a session")
	if session == null:
		return
	_check(session.backend == GameSession.Backend.DESKTOP_PROCESS, "desktop launch uses process backend")
	_check(session.state == GameSession.State.ACTIVE, "desktop launch becomes ACTIVE")
	_check(FileAccess.file_exists(session.pending_path), "desktop pending record exists before entry signal")
	_check(facade.entered.size() == 1 and facade.entered[0][0] == 987654, "legacy desktop entry signal preserved")

	process.enter_background_state(987653, game)
	_check(process._active_session == session, "duplicate active launch is ignored")
	_check(facade.entered.size() == 1, "duplicate active launch emits no second entry")

	session.session_start_ms -= 5000
	var pending := _read_record(session.pending_path)
	_check(int(pending.get("runtime", {}).get("pid", 0)) == 987654, "pending record stores desktop PID")
	process.exit_background_state(7)
	_check(sessions.commits.size() == 1, "desktop exit credits playtime once")
	if sessions.commits.size() == 1:
		var seconds: int = sessions.commits[0][1]
		_check(seconds >= 4 and seconds <= 6, "desktop playtime uses monotonic elapsed time")
	_check(sessions.uploads.size() == 1, "desktop exit queues save upload once")
	_check(facade.exited.size() == 1 and facade.exited[0][1] == 7, "legacy exit signal preserves exit code")
	_check(not FileAccess.file_exists(session.pending_path), "desktop finalization removes only its own pending record")
	_check(session.state == GameSession.State.ENDED, "desktop process exit becomes ENDED")
	process.exit_background_state(0)
	_check(sessions.commits.size() == 1 and sessions.uploads.size() == 1, "duplicate process-exit notification is idempotent")

func _test_android_resume_is_terminal() -> void:
	var fixture := _fixture()
	var sessions: SpySessions = fixture[1]
	var process: ProcessDouble = fixture[2]
	var game := _game(102, "Android Game")
	process.enter_background_state_android(game, "example.emulator")
	var session: GameSession = process._active_session
	_check(session != null and session.backend == GameSession.Backend.ANDROID_TASK, "Android launch uses Android task backend")
	_check(process.get_background_pid() == -1, "Android background PID remains -1")
	_check(session.runtime.get("package", "") == "example.emulator", "Android pending record stores emulator package")
	_check(sessions.native_starts.has(session.session_id), "Android native watch receives per-session identity")
	session.session_start_ms -= 3000
	# Kyodai resuming still terminates the legacy Android session in Phase 1.
	process.force_exit_background_state()
	_check(session.state == GameSession.State.ENDED, "legacy Android resume maps to ENDED")
	_check(sessions.commits.size() == 1 and sessions.uploads.size() == 1, "Android resume commits and uploads once")
	_check(sessions.native_stops.has(session.session_id), "Android resume stops native watch")

func _test_playtime_annotation_and_recovery() -> void:
	var fixture := _fixture()
	var sessions: SpySessions = fixture[1]
	var game := _game(103, "Recovered Game")
	var now: float = floor(Time.get_unix_time_from_system())
	var path := SessionSubManager.pending_path_for("session-recovery-test")
	var record := {
		"session_id": "session-recovery-test",
		"romm_id": 103,
		"title": game.title,
		"platform_slug": game.platform_slug,
		"emulator_id": "test_emulator",
		"backend": "desktop_process",
		"start_unix": now - 100.0,
		"end_unix": now - 40.0,
		"runtime": {"pid": 1234},
		"_pending_path": path,
	}
	_write_record(path, record)
	var session := GameSession.from_pending(record, game)
	_check(sessions.finalize_once(session, 0, "recovered", true), "pending recovery finalizes once")
	_check(sessions.commits.size() == 1 and sessions.commits[0][1] == 60, "recovery uses exact native end timestamp")
	_check(sessions.uploads.size() == 1, "recovery queues one save upload")
	_check(not sessions.finalize_once(session, 0, "duplicate", true), "duplicate recovery finalization is rejected")
	_check(sessions.commits.size() == 1 and sessions.uploads.size() == 1, "duplicate recovery cannot double-credit or double-upload")
	_check(not FileAccess.file_exists(path), "recovered pending record is removed")
	var invalid_path := SessionSubManager.pending_path_for("session-invalid-start")
	var invalid := record.duplicate(true)
	invalid["session_id"] = "session-invalid-start"
	invalid["start_unix"] = 0.0
	invalid["end_unix"] = 0.0
	invalid["_pending_path"] = invalid_path
	_write_record(invalid_path, invalid)
	_check(not sessions.finalize_pending_record(invalid, "invalid"), "zero start timestamp is rejected")
	_check(sessions.commits.size() == 1 and sessions.uploads.size() == 1, "invalid recovery cannot credit or upload")
	_check(not FileAccess.file_exists(invalid_path), "invalid pending record is cleaned up")

func _test_steam_recovery() -> void:
	var fixture := _fixture()
	var sessions: SpySessions = fixture[1]
	var now: float = floor(Time.get_unix_time_from_system())
	var path := SessionSubManager.pending_path_for("session-steam-recovery")
	var record := {
		"session_id": "session-steam-recovery",
		"romm_id": -55,
		"title": "Recovered Steam Game",
		"platform_slug": "steam",
		"emulator_id": "test_emulator",
		"backend": "android_task",
		"start_unix": now - 30.0,
		"end_unix": now - 10.0,
		"runtime": {},
		"_pending_path": path,
	}
	_write_record(path, record)
	_check(sessions.finalize_pending_record(record, "recovered"), "negative Steam IDs remain valid recovery records")
	_check(sessions.uploads.size() == 1, "Steam recovery reaches save policy once")
	_check(not FileAccess.file_exists(path), "Steam recovery record is finalized and removed")

func _test_recovery_claim() -> void:
	var fixture := _fixture()
	var process: ProcessDouble = fixture[2]
	var path := SessionSubManager.pending_path_for("session-claim-test")
	var record := {"_pending_path": path, "policy": {"origin": "ordinary"}}
	_check(await process._claim_pending_record(record), "first recovery claimant wins")
	_check(not await process._claim_pending_record(record), "live claimant blocks duplicate finalization")
	process._release_recovery_claim(record)
	_check(await process._claim_pending_record(record), "released claim can be reacquired")
	process._release_recovery_claim(record)
	_check(not process._recovery_role_allows({"policy": {"origin": "headless"}, "romm_id": 42}), "GUI recovery cannot adopt a headless session")
	process._initial_recovery_completed = false
	process.request_pending_recovery()
	await process.wait_for_initial_recovery()
	_check(process._initial_recovery_completed, "initial recovery publishes completion for headless runners")
	_delete_pending(path)

func _test_desktop_reattach() -> void:
	var fixture := _fixture()
	var sessions: SpySessions = fixture[1]
	var process: ProcessDouble = fixture[2]
	var game := _game(104, "Surviving Game")
	process.pending_game = game
	var pid := OS.get_process_id()
	var session := sessions.begin_session(game, GameSession.Backend.DESKTOP_PROCESS, {
		"emulator_id": "test_emulator",
		"runtime": {
			"pid": pid,
			"pgid": process.get_pgid(pid),
			"process_start_ticks": process._process_start_ticks(pid),
			"boot_id": process._current_boot_id(),
			"signature": "",
			"exe_signature": "",
		},
	})
	var record := session.pending_record()
	record["_pending_path"] = session.pending_path
	record["owner"] = {"pid": 1, "start_ticks": 1, "boot_id": process._current_boot_id()}
	var restored := await process._try_reattach_pending_session(record)
	_check(restored, "desktop recovery reattaches to a surviving process group")
	_check(process._active_session.owner.get("pid", -1) == OS.get_process_id(), "reattach transfers ownership to the recovering launcher")
	_check(process.is_in_background_state(), "reattached process restores background state")
	_check(process._active_session != null and process._active_session.session_id == session.session_id, "reattach preserves session identity")
	_check(sessions.commits.is_empty() and sessions.uploads.is_empty(), "surviving game is not finalized during launcher recovery")
	_check(FileAccess.file_exists(session.pending_path), "reattached session remains pending")
	if process._background_poll_timer:
		process._background_poll_timer.stop()

	var stale := sessions.begin_session(game, GameSession.Backend.DESKTOP_PROCESS, {
		"runtime": {
			"pid": pid,
			"pgid": process.get_pgid(pid),
			"process_start_ticks": process._process_start_ticks(pid) + 1,
			"boot_id": process._current_boot_id(),
		},
	})
	var stale_record := stale.pending_record()
	stale_record["_pending_path"] = stale.pending_path
	_check(not await process._try_reattach_pending_session(stale_record), "PID reuse/start-tick mismatch is never adopted")
	_delete_pending(stale.pending_path)

	var standalone := sessions.begin_session(null, GameSession.Backend.DESKTOP_PROCESS, {
		"title": "Standalone Emulator",
		"runtime": {
			"pid": pid,
			"pgid": process.get_pgid(pid),
			"process_start_ticks": process._process_start_ticks(pid),
			"boot_id": process._current_boot_id(),
		},
	})
	var standalone_record := standalone.pending_record()
	standalone_record["_pending_path"] = standalone.pending_path
	_check(await process._try_reattach_pending_session(standalone_record), "standalone null-game session can reattach with synthetic identity")
	sessions.finalize_once(process._active_session, 0, "test_cleanup")
	_check(sessions.uploads.is_empty(), "standalone sessions never invoke save sync")
	_delete_pending(standalone.pending_path)
	_delete_pending(session.pending_path)

func _test_leaderless_group_reattach() -> void:
	if not SystemManager.platform.is_linux():
		return
	var fixture := _fixture()
	var sessions: SpySessions = fixture[1]
	var process: ProcessDouble = fixture[2]
	var game := _game(106, "Leaderless Game")
	process.pending_game = game
	var payload_pid := OS.get_process_id()
	var pgid := process.get_pgid(payload_pid)
	# The recorded leader no longer exists. The signature lookup is stubbed to
	# return a real surviving payload in that same group, making this test
	# deterministic while exercising the actual adoption and liveness logic.
	process.signature_match_pid = payload_pid
	var missing_leader_pid := payload_pid + 1000000
	var session := sessions.begin_session(game, GameSession.Backend.DESKTOP_PROCESS, {
		"runtime": {
			"pid": missing_leader_pid,
			"pgid": pgid,
			"process_start_ticks": 1,
			"boot_id": process._current_boot_id(),
			"signature": "leaderless-payload",
		},
	})
	var record := session.pending_record()
	record["_pending_path"] = session.pending_path
	_check(await process._try_reattach_pending_session(record), "surviving payload can be adopted after its leader exits")
	_check(process._active_session.runtime.get("pid", -1) == payload_pid, "leader-less adoption persists the real payload identity")
	if process._background_poll_timer:
		process._background_poll_timer.stop()
	_delete_pending(session.pending_path)

func _test_headless_post_launch_upload() -> void:
	var runner := HeadlessDouble.new()
	add_child(runner)
	var game := _game(105, "Headless Steam Game")
	var session := GameSession.new_session(game, GameSession.Backend.DESKTOP_PROCESS, {"emulator_id": "test_emulator"})
	await runner._post_launch(session)
	_check(runner.finalizations.size() == 1, "headless Steam process exit uses shared finalization once")
	_check(runner.waits.size() == 1, "headless Steam launch waits for registry-driven upload once")
	runner.queue_free()
	await get_tree().process_frame
