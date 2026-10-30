extends Node

## Characterization of shuffler retention policy without real emulator/window
## processes. OS-heavy hide/signal helpers are replaced at their existing seams.
var _failures := 0

class ShufflerDouble:
	extends ShufflerSubManager
	var stopped: Array = []
	var resumed: Array = []
	var launched: Array = []
	var timers: Array = []
	var killed: Array = []

	func _ready() -> void:
		pass

	func _stop_game(entry: Dictionary) -> void:
		stopped.append(entry)
		entry.active = false
		_retain_entry_session(entry)

	func _await_launch_settled(_entry: Dictionary) -> void:
		pass

	func _show_intro(_game: GameResource) -> void:
		pass

	func _resolve_entry_target(entry: Dictionary) -> Dictionary:
		return {"pid": _entry_pid(entry), "pgid": _entry_pgid(entry)}

	func _adopt_entry_target(entry: Dictionary, target: Dictionary, _context: String) -> bool:
		_set_entry_pid(entry, target.pid)
		_set_entry_pgid(entry, target.pgid)
		return true

	func _resume_game(entry: Dictionary) -> void:
		resumed.append(entry)
		entry.active = true
		_resume_entry_session(entry)

	func _launch_game(entry: Dictionary) -> void:
		launched.append(entry)
		entry.started = true
		entry.active = true
		_activate_entry_session(entry, 500 + launched.size(), 500 + launched.size())

	func _start_round_timer(duration: float) -> void:
		timers.append(duration)

	func _kill_entry_processes(entry: Dictionary) -> void:
		killed.append(entry)

class StopPolicyDouble:
	extends ShufflerSubManager
	var suspended: Array = []

	func _suspend_game(entry: Dictionary) -> void:
		suspended.append(entry)

func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK   ", message)
	else:
		_failures += 1
		print("FAIL ", message)

func _game(id: int) -> GameResource:
	var game := GameResource.new()
	game.id = "shuffle-%d" % id
	game.romm_id = id
	game.title = "Shuffle %d" % id
	game.platform_slug = "test"
	return game

func _entry(id: int, started: bool) -> Dictionary:
	return {
		"game": _game(id),
		"session": null,
		"started": started,
		"active": false,
		"emulator_id": "test_emulator",
		"suspend_method": "suspend",
		"status": ShufflerBag.EntryStatus.READY,
		"temp_path": "",
		"download_id": "",
		"retry_count": 0,
		"launch_pending": false,
	}

func _cleanup_entries(entries: Array) -> void:
	for entry in entries:
		var session: GameSession = entry.get("session", null)
		if session:
			session.state = GameSession.State.ENDED
			SessionSubManager._delete_pending_record(session.pending_path)

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	for i in 5:
		await get_tree().process_frame
	var shuffler := ShufflerDouble.new()
	add_child(shuffler)
	var first := _entry(201, true)
	var second := _entry(202, true)
	var third := _entry(203, false)
	first.active = true
	shuffler._bag.entries = [first, second, third]
	shuffler._seen_entries = [first, second, third]
	shuffler._current_game_index = 0
	shuffler._state = ShufflerSubManager.State.ACTIVE
	shuffler._activate_entry_session(first, 201, 201)
	shuffler._activate_entry_session(second, 202, 202)
	_check(shuffler._session_for_entry(first) != null and shuffler._session_for_entry(second) != null, "started bag entries use shared GameSession runtime")
	_check(shuffler._entry_pid(first) == 201 and shuffler._entry_pgid(first) == 201, "PID/PGID reads resolve through the shared session")
	_check(shuffler._session_for_entry(first).is_shuffler(), "shuffler origin is persisted in session policy")
	_check(not LaunchManager.sessions._should_credit_playtime(shuffler._session_for_entry(first)), "shuffler does not opt into ordinary playtime accounting")
	_check(not LaunchManager.sessions._should_upload_saves(shuffler._session_for_entry(first)), "shuffler does not opt into ordinary save sync")

	await shuffler._switch_to_game(1)
	_check(shuffler.stopped.size() == 1 and shuffler.stopped[0] == first, "switch suspends/stops the outgoing entry")
	_check(shuffler.resumed.size() == 1 and shuffler.resumed[0] == second, "existing suspended entry resumes instead of relaunching")
	_check(shuffler.launched.is_empty(), "resume path does not create a duplicate process")
	_check(shuffler._current_game_index == 1 and second.active, "resumed entry becomes current")
	_check(shuffler._session_for_entry(first).state == GameSession.State.RETAINED, "outgoing game becomes RETAINED in the registry")
	_check(shuffler._session_for_entry(second).state == GameSession.State.ACTIVE, "resumed game becomes ACTIVE in the registry")

	await shuffler._switch_to_game(2)
	_check(shuffler.stopped.size() == 2 and shuffler.stopped[1] == second, "second switch retains the previous entry")
	_check(shuffler.launched.size() == 1 and shuffler.launched[0] == third, "never-started entry launches fresh")
	_check(shuffler._current_game_index == 2, "fresh launch becomes current")
	_check(shuffler.timers.size() == 2, "each committed switch restarts the round timer")
	var launches_before_restart: int = shuffler.launched.size()
	await shuffler.restart_game()
	_check(shuffler.launched.size() == launches_before_restart + 1, "restart launches a fresh process after finalizing the old session")
	_check(shuffler._session_for_entry(third) != null and shuffler._entry_pid(third) > 0, "restart never treats the fresh PID as stale")

	var stop_policy := StopPolicyDouble.new()
	add_child(stop_policy)
	var stopping := _entry(204, true)
	stop_policy._activate_entry_session(stopping, 204, 204)
	await stop_policy._stop_game(stopping)
	_check(stop_policy.suspended.size() == 1 and stop_policy.suspended[0] == stopping, "stop policy uses freeze for suspend-method entries")
	_cleanup_entries([first, second, third, stopping])
	stop_policy._state = ShufflerSubManager.State.IDLE
	stop_policy._bag.entries.clear()
	shuffler._state = ShufflerSubManager.State.IDLE
	shuffler._bag.entries.clear()
	shuffler._current_game_index = -1
	stop_policy.queue_free()
	shuffler.queue_free()
	await get_tree().process_frame

	if _failures == 0:
		print("SHUFFLER LIFECYCLE TEST PASSED")
	else:
		print("SHUFFLER LIFECYCLE TEST FAILED: ", _failures)
	get_tree().quit(_failures)
