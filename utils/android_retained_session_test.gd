extends Node

var _failures := 0

class SpySessions:
	extends SessionSubManager
	var commits: Array = []
	var uploads: Array = []
	func _ready() -> void: pass
	func _commit_play_seconds(session: GameSession, seconds: int) -> void:
		if not _should_credit_playtime(session): return
		commits.append([session.romm_id, seconds])
	func _queue_save_upload(session: GameSession, reason: String) -> void:
		if not _should_upload_saves(session): return
		uploads.append([session.romm_id, reason])
	func _start_native_watch(_session: GameSession) -> void: pass
	func _stop_native_watch(_session: GameSession) -> void: pass

class FakeAndroidTasks:
	extends AndroidTaskSubManager
	var tasks: Array = []
	var snapshot_count := 0
	func _ready() -> void: pass
	func retention_available() -> bool: return true
	func snapshots_available() -> bool: return true
	func list_tasks() -> Dictionary:
		return {"ok": true, "tasks": tasks.duplicate(true)}
	func capture_snapshot(_task: Dictionary) -> Dictionary:
		snapshot_count += 1
		DirAccess.make_dir_recursive_absolute("user://android-task-test")
		var path := "user://android-task-test/frame-%d.jpg" % snapshot_count
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		img.save_jpg(path, 1.0)
		return {"ok": true, "snapshot": {"path": path, "width": 4, "height": 4, "real": true}}
	func focus(_task: Dictionary) -> Dictionary:
		return {"ok": false, "code": "stale_task"} if tasks.is_empty() else {"ok": true}
	func force_stop(_task: Dictionary) -> Dictionary:
		tasks.clear()
		return {"ok": true}
	func remove_task(_task: Dictionary) -> Dictionary:
		return {"ok": true}

class CapabilityProbeDouble:
	extends AndroidTaskSubManager
	func _ready() -> void: pass
	func _call(_method: String, _args: Array = []) -> Dictionary:
		return {"ok": true, "privileged": true, "listTasks": true, "focus": true, "forceStop": true, "removeTask": true, "retainedSessions": true}

class FakeFacade:
	extends Node
	var sessions: SpySessions
	var android_tasks: FakeAndroidTasks
	func resolve_emulator_for_game(_game: GameResource) -> String:
		return "test_emulator"

class ProcessDouble:
	extends ProcessSubManager
	func _ready() -> void:
		launch_manager = get_parent()
		_background_poll_timer = Timer.new()
		add_child(_background_poll_timer)

func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK   ", message)
	else:
		_failures += 1
		print("FAIL ", message)

func _game() -> GameResource:
	var game := GameResource.new()
	game.id = "android-retained-test"
	game.romm_id = 501
	game.title = "Retained Test"
	game.platform_slug = "test"
	return game

func _fixture() -> Array:
	var facade := FakeFacade.new()
	facade.sessions = SpySessions.new()
	facade.android_tasks = FakeAndroidTasks.new()
	var process := ProcessDouble.new()
	add_child(facade)
	facade.add_child(facade.sessions)
	facade.add_child(facade.android_tasks)
	facade.add_child(process)
	return [facade, process]

func _task() -> Dictionary:
	return {
		"taskId": 41,
		"packageName": "example.emulator",
		"topActivity": "example.emulator.MainActivity",
		"baseActivity": "example.emulator/.MainActivity",
		"displayId": 0,
		"userId": 0,
		"visible": false,
	}

func _wait_for_registration(process: ProcessDouble) -> void:
	for i in 20:
		var session := process.get_active_android_session()
		if session and bool(session.policy.get("retain", false)):
			return
		await get_tree().process_frame
	_check(false, "retained task registers after cold launch")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	for i in 5:
		await get_tree().process_frame
	var probe := CapabilityProbeDouble.new()
	add_child(probe)
	await probe.probe_capabilities()
	_check(bool(probe._capabilities.get("retainedSessions", false)), "native top-level capabilities enable retention")
	probe.queue_free()
	await _test_transition_modes()
	await _test_card_snapshot_publication()
	await _test_retain_resume_close()
	await _test_lost_task()
	if _failures == 0:
		print("ANDROID RETAINED SESSION TEST PASSED")
	else:
		print("ANDROID RETAINED SESSION TEST FAILED: ", _failures)
	get_tree().quit(_failures)

func _test_transition_modes() -> void:
	var overlay := LaunchTransitionOverlay.new()
	var margin := MarginContainer.new()
	margin.name = "MarginContainer"
	var title := Label.new()
	title.name = "GameTitleLabel"
	margin.add_child(title)
	overlay.add_child(margin)
	add_child(overlay)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(img)
	var game := _game()

	LaunchTransitionOverlay.set_source(texture, Rect2(0, 0, 16, 16))
	overlay.play_resume(game)
	await overlay.resume_ready
	_check(overlay._effect_stack.get_effect("hsl") == null, "resume has no desaturation or dimming effect")
	_check(overlay._effect_stack.get_effect("gradient_overlay") == null, "resume has no gradient overlay effect")
	_check(not title.visible, "resume never shows the cold-launch title")
	_check(not overlay._black_curtain.visible, "resume never fades to black")

	LaunchTransitionOverlay.set_source(texture, Rect2(0, 0, 16, 16))
	overlay.restart(game)
	await overlay.phase1_completed
	await overlay.finish_cold_launch()
	_check(overlay._black_curtain.visible, "cold launch enables its black curtain")
	_check(overlay._black_curtain.modulate.a > 0.99, "cold launch fades the black curtain fully opaque")
	_check(not title.visible, "cold black curtain hides the landing title")
	var hsl := overlay._effect_stack.get_effect("hsl") as HSLEffect
	_check(hsl._settings.get("saturation_scale", 1.0) == 0.0, "cold landing retains its desaturation step")
	LaunchTransitionOverlay.set_source(texture, Rect2(0, 0, 16, 16))
	overlay.play_resume(game)
	await overlay.resume_ready
	_check(overlay._effect_stack.get_effect("hsl") == null, "cold-to-resume removes stale HSL state")
	_check(overlay._effect_stack.get_effect("gradient_overlay") == null, "cold-to-resume removes stale gradient state")
	overlay.abort()
	overlay.queue_free()
	await get_tree().process_frame

func _test_card_snapshot_publication() -> void:
	var game := _game()
	game.romm_id = 999
	var session := LaunchManager.sessions.begin_session(game, GameSession.Backend.ANDROID_TASK, {})
	LaunchManager.sessions.activate_session(session, -1)
	var card := GameCard.new()
	add_child(card)
	card.game = game
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute("user://android-task-test")
	var path := "user://android-task-test/card-frame.jpg"
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLUE)
	img.save_jpg(path, 1.0)
	LaunchManager.sessions.retain_session(session, false)
	session.runtime["snapshotPath"] = path
	LaunchManager.sessions.update_runtime(session, session.runtime)
	await get_tree().process_frame
	_check(card._session_snapshot_texture() != null, "card loads the published retained snapshot")
	_check(card._current_texture == card._session_snapshot_texture(), "card current texture is the retained snapshot")
	card.queue_free()
	LaunchManager.sessions._sessions.erase(session.session_id)
	SessionSubManager._delete_pending_record(session.pending_path)
	session.state = GameSession.State.ENDED
	await get_tree().process_frame

func _test_retain_resume_close() -> void:
	var fixture := _fixture()
	var facade: FakeFacade = fixture[0]
	var process: ProcessDouble = fixture[1]
	var game := _game()
	facade.android_tasks.tasks = [_task()]
	process.enter_background_state_android(game, "example.emulator")
	await _wait_for_registration(process)
	var session := process.get_active_android_session()
	_check(session.runtime.get("taskId", -1) == 41, "cold launch records real task identity")
	_check(session.state == GameSession.State.ACTIVE, "cold launch is ACTIVE")

	await get_tree().create_timer(0.05).timeout
	_check(await process.retain_active_android_session(), "Home retains the Android session")
	_check(session.state == GameSession.State.RETAINED, "Home changes ACTIVE to RETAINED")
	_check(not process.is_in_background_state(), "retained session leaves launcher interactive")
	_check(session.runtime.get("snapshotPath", "") != "", "retained session stores snapshot path")
	_check(facade.sessions.commits.is_empty() and facade.sessions.uploads.is_empty(), "Home does not finalize or upload")
	var paused_ms := session.active_elapsed_ms
	await get_tree().create_timer(0.06).timeout
	_check(session.active_elapsed_ms == paused_ms, "retained state pauses active-time accounting")

	var resumed := await process.resume_retained_game(game.romm_id)
	_check(resumed.get("ok", false), "resume focuses existing task")
	_check(session.state == GameSession.State.ACTIVE, "resume changes RETAINED to ACTIVE")
	_check(process.is_in_background_state(), "resumed game owns background state")

	var snapshot_path := str(session.runtime.get("snapshotPath", ""))
	var closed := await process.close_retained_game(game.romm_id)
	_check(closed.get("ok", false), "close confirms task death")
	_check(session.state == GameSession.State.ENDED, "confirmed close becomes ENDED")
	_check(facade.sessions.commits.size() == 1, "close credits playtime once")
	_check(facade.sessions.uploads.size() == 1, "close uploads saves once")
	_check(not FileAccess.file_exists(snapshot_path), "close removes snapshot state")
	process.queue_free()
	await get_tree().process_frame

func _test_lost_task() -> void:
	var fixture := _fixture()
	var facade: FakeFacade = fixture[0]
	var process: ProcessDouble = fixture[1]
	var game := _game()
	facade.android_tasks.tasks = [_task()]
	process.enter_background_state_android(game, "example.emulator")
	await _wait_for_registration(process)
	var session := process.get_active_android_session()
	await process.retain_active_android_session()
	# Simulate the OS reclaiming the task while it is retained.
	facade.android_tasks.tasks.clear()
	var resumed := await process.resume_retained_game(game.romm_id)
	_check(not resumed.get("ok", false), "missing task cannot resume")
	_check(session.state == GameSession.State.LOST, "missing task becomes LOST")
	_check(facade.sessions.uploads.is_empty(), "lost task is not silently finalized")
	await process.discard_lost_android_session()
	_check(session.state == GameSession.State.ENDED, "discard explicitly finalizes lost session")
	_check(facade.sessions.uploads.size() == 1, "discard uploads once")
	process.queue_free()
	await get_tree().process_frame
