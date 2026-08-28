extends Manager
class_name ShufflerSubManager

## Manages shuffler sessions: bag building, game switching, process control.

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

enum State { IDLE, DOWNLOADING, ACTIVE, PAUSED, STOPPING }

signal session_started()
signal session_stopped()
signal game_switched(game_title: String, platform_name: String)
signal timer_updated(time_left: float)
signal download_progress(current: int, total: int)
signal game_ready(index: int)

var _state: State = State.IDLE
var _switch_in_progress: bool = false
var _pending_switch_index: int = -1  # latest requested target while a switch is in flight
var _bag: ShufflerBag = ShufflerBag.new()
var _current_game_index: int = -1
var _round_timer: Timer = null
var _countdown_timer: Timer = null
var _config: Dictionary = {}
var _controls_window: Node = null
var _controls_topmost_timer: Timer = null
var _main_window: Window = null
var _total_downloads: int = 0
var _pending_downloads: int = 0
var _pending_preparations: int = 0
var _tools_dir: String = ""
var _ahk_path: String = ""
var _pssuspend_path: String = ""
var _reroll_in_progress: bool = false
var _reroll_download_id: String = ""
var _shuffle_overrides: Dictionary = {}  # platform_slug -> {"emulator_id": String, "core_id": String}
var _shuffle_session_active: bool = false

# "Preparing Shuffle" progress notification: tracks only the FIRST queued
# download so the user can tell the session is about to start. Dismissed when
# the first game is ready (_enter_shuffler_mode) or the session aborts.
var _prep_notification_id: int = 0
var _prep_first_item_id: String = ""
var _prep_first_title: String = ""
var _session_log_path: String = "user://logs/session.log"
var _session_log_start_offset: int = -1
var _download_item_ids: Array[String] = []
var _download_progresses: Dictionary = {}  # item_id -> float
var _download_sizes: Dictionary = {}       # item_id -> int (bytes)
var _total_download_bytes: int = 0
var _active_download_item_id: String = ""
var _shuffler_vita_apps: Array[Dictionary] = []
var _maximize_token: int = 0  # incremented whenever the foreground game changes; in-flight maximize coroutines check it and bail

const TEMP_DIR := "user://shuffler_temp/"

const RETROARCH_SHUFFLER_CFG := {
	"network_cmd_enable": "true",
	"savestate_auto_load": "true",
	"savestate_auto_save": "true",
	"pause_nonactive": "false",
	"menu_enable_widgets": "false",
	"input_auto_game_focus": "1",
	"video_font_enable": "false",
}

const PCSX2_SHUFFLER_INI_PATH := "{emulator_dir}/inis/PCSX2.ini"
const PCSX2_MEMORY_CARD_KEYS := ["Slot1_Enable", "Slot2_Enable", "Slot1_Filename", "Slot2_Filename"]
const PCSX2_MEMORY_CARD_VALUES := {
	"Slot1_Enable": "false",
	"Slot2_Enable": "false",
	"Slot1_Filename": '""',
	"Slot2_Filename": '""',
}

func _ready():
	_main_window = get_tree().root
	# Shuffler is Windows-only; skip tool extraction on other platforms
	if not SystemManager.platform.is_windows():
		return
	if SystemManager.platform.is_packaged():
		# Packaged builds cannot execute tools from inside the PCK; use extracted copies
		_tools_dir = ProjectSettings.globalize_path(AndroidBinaryExtractor.BIN_DIR)
		_ahk_path = AndroidBinaryExtractor.extract_binary("res://bin/ahk/AutoHotkey64.exe", "AutoHotkey64.exe")
		AndroidBinaryExtractor.extract_binary("res://bin/shuffler_tools/pssuspend.exe", "pssuspend.exe")
		AndroidBinaryExtractor.extract_binary("res://bin/shuffler_tools/minimize_window.ahk", "minimize_window.ahk")
		AndroidBinaryExtractor.extract_binary("res://bin/shuffler_tools/maximize_process.ahk", "maximize_process.ahk")
	else:
		_tools_dir = ProjectSettings.globalize_path("res://bin/shuffler_tools/")
		_ahk_path = ProjectSettings.globalize_path("res://bin/ahk/AutoHotkey64.exe")
	_pssuspend_path = _tools_dir + "pssuspend.exe"

func _exit_tree():
	if is_session_active():
		stop_session()

# ============================================================================
# SESSION LOGGING
# ============================================================================

func _start_session_log_capture() -> void:
	var logs_dir := ProjectSettings.globalize_path("user://logs/")
	if not DirAccess.dir_exists_absolute(logs_dir):
		DirAccess.make_dir_recursive_absolute(logs_dir)

	var session_log := ProjectSettings.globalize_path(_session_log_path)
	var offset := 0
	if FileAccess.file_exists(session_log):
		var file := FileAccess.open(session_log, FileAccess.READ)
		if file:
			offset = file.get_length()
			file.close()

	_session_log_start_offset = offset
	print("[ShufflerSubManager] Session log capture started at offset " + str(offset))

func _finalize_session_log() -> void:
	if _session_log_start_offset < 0:
		return

	var session_log := ProjectSettings.globalize_path(_session_log_path)
	var start_offset := _session_log_start_offset
	_session_log_start_offset = -1

	if not FileAccess.file_exists(session_log):
		return

	var file := FileAccess.open(session_log, FileAccess.READ)
	if not file:
		push_error("[ShufflerSubManager] Failed to read session log")
		return

	var size := file.get_length()
	if size <= start_offset:
		file.close()
		return

	file.seek(start_offset)
	var chunk := file.get_buffer(size - start_offset)
	file.close()

	var dt := Time.get_datetime_dict_from_system()
	var filename := "shuffler_%04d-%02d-%02d_%02d-%02d-%02d.log" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var output_path := ProjectSettings.globalize_path("user://logs/" + filename)

	var out := FileAccess.open(output_path, FileAccess.WRITE)
	if not out:
		push_error("[ShufflerSubManager] Failed to write session log: " + output_path)
		return

	out.store_buffer(chunk)
	out.close()
	print("[ShufflerSubManager] Session log saved: " + output_path)

# ============================================================================
# PUBLIC API
# ============================================================================

func is_session_active() -> bool:
	return _state != State.IDLE

func get_state() -> State:
	return _state

func is_shuffle_session_active() -> bool:
	return _shuffle_session_active

func can_pause() -> bool:
	return _state == State.ACTIVE

func can_resume() -> bool:
	return _state == State.PAUSED

func can_skip() -> bool:
	return _state == State.ACTIVE or _state == State.PAUSED

func can_restart() -> bool:
	return _state == State.ACTIVE or _state == State.PAUSED

func can_reroll() -> bool:
	return _state == State.ACTIVE or _state == State.PAUSED

func set_shuffle_override(platform_slug: String, emulator_id: String, core_id: String) -> void:
	_shuffle_overrides[platform_slug] = {"emulator_id": emulator_id, "core_id": core_id}

func get_shuffle_override(platform_slug: String) -> Dictionary:
	return _shuffle_overrides.get(platform_slug, {})

func clear_shuffle_overrides() -> void:
	_shuffle_overrides.clear()
	_shuffle_session_active = false

func start_session(config: Dictionary) -> void:
	if _state != State.IDLE:
		push_error("[ShufflerSubManager] Already in a session")
		return

	if not SystemManager.platform.is_windows():
		push_error("[ShufflerSubManager] Shuffler is only available on Windows")
		return

	var platforms = config.get("platforms", [])
	var bag_size = config.get("bag_size", 4)

	if platforms.is_empty():
		push_error("[ShufflerSubManager] No platforms selected for shuffler")
		return

	_bag = ShufflerBag.new()
	_bag.build(platforms, bag_size)
	_bag.build_candidates(platforms)

	if _bag.is_empty():
		push_error("[ShufflerSubManager] No games found for selected platforms")
		return

	_state = State.DOWNLOADING
	_config = config
	_current_game_index = -1
	_switch_in_progress = false
	_pending_switch_index = -1
	_reset_download_tracking()
	_shuffler_vita_apps.clear()

	# Cut background music for the whole session (resumed in stop_session);
	# per-game exit signals must not resume it mid-session.
	SystemManager.audio.pause_background_music()

	print("[ShufflerSubManager] Starting session with bag size " + str(_bag.size()) + ": " + _format_bag())
	_start_bag_preparation()
	_await_first_ready()

func stop_session() -> void:
	if _state == State.IDLE or _state == State.STOPPING:
		print("[ShufflerSubManager] stop_session called but state=" + str(_state) + ", ignoring")
		return

	print("[ShufflerSubManager] stop_session: state=" + str(_state) + " " + _format_bag())
	_state = State.STOPPING
	_dismiss_prep_notification()

	_reroll_in_progress = false
	_reroll_download_id = ""
	_pending_switch_index = -1
	_maximize_token += 1

	_kill_round_timer()

	if SystemManager.download.download_progress.is_connected(_on_download_progress):
		SystemManager.download.download_progress.disconnect(_on_download_progress)

	for item_id in _download_item_ids:
		SystemManager.download.cancel(item_id)

	var kill_pids: Array[int] = []
	for entry in _bag.entries:
		if entry.pid != -1:
			LaunchManager.process.kill_process_async(entry.pid)
			kill_pids.append(entry.pid)

	# Wait until the killed processes are actually gone (bounded) before
	# restoring configs and deleting temp files they may still be writing.
	if not kill_pids.is_empty():
		var deadline := 3.0
		var elapsed := 0.0
		while elapsed < deadline:
			var alive: Array[int] = []
			for pid in kill_pids:
				if await LaunchManager.process.is_running_async(pid):
					alive.append(pid)
			if alive.is_empty():
				break
			await get_tree().create_timer(0.2).timeout
			elapsed += 0.2
			if elapsed >= deadline:
				push_warning("[ShufflerSubManager] Processes still alive after kill timeout: " + str(alive))
		print("[ShufflerSubManager] stop_session: process teardown took " + str(elapsed) + "s")

	_restore_emulator_file_if_backed_up("retroarch", "{emulator_dir}/retroarch.cfg")
	_restore_emulator_file_if_backed_up("pcsx2", PCSX2_SHUFFLER_INI_PATH)

	_cleanup_vita3k_shuffler_apps()

	_stop_controls_topmost_timer()
	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.queue_free()
		_controls_window = null

	get_tree().root.gui_disable_input = false

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if SystemManager.display:
		var last_size: Vector2i = SystemManager.display.restore_last_window_size()
		if last_size == Vector2i.ZERO:
			var resolution_setting = SystemManager.display.settings_man.get_setting("resolution")
			if resolution_setting:
				var resolution_value = resolution_setting.value
				if resolution_value is int and resolution_setting.options.size() > resolution_value:
					resolution_value = resolution_setting.options[resolution_value]
				SystemManager.display.set_resolution(resolution_value)
			DisplayServer.window_set_position(Vector2i(Vector2(DisplayServer.screen_get_position()) + Vector2(DisplayServer.screen_get_size()) / 2.0 - Vector2(DisplayServer.window_get_size()) / 2.0))
	DisplayServer.window_move_to_foreground()

	_cleanup_temp_files()

	_bag = ShufflerBag.new()
	_current_game_index = -1
	_config.clear()
	_state = State.IDLE
	_shuffle_session_active = false

	# State is IDLE again, so the audio guard no longer suppresses this resume.
	SystemManager.audio.resume_background_music()

	_finalize_session_log()
	session_stopped.emit()

func pause_session() -> void:
	if not can_pause():
		print("[ShufflerSubManager] pause_session ignored: state=" + str(_state))
		return
	if _reroll_in_progress:
		print("[ShufflerSubManager] pause_session ignored: reroll in progress")
		return
	print("[ShufflerSubManager] pause_session")
	_state = State.PAUSED
	if _round_timer:
		_round_timer.paused = true

func resume_session() -> void:
	if not can_resume():
		print("[ShufflerSubManager] resume_session ignored: state=" + str(_state))
		return
	if _reroll_in_progress:
		print("[ShufflerSubManager] resume_session ignored: reroll in progress")
		return
	print("[ShufflerSubManager] resume_session")
	_state = State.ACTIVE
	if _round_timer and is_instance_valid(_round_timer) and not _round_timer.is_stopped():
		_round_timer.paused = false
	else:
		var round_time = _random_round_time()
		_start_round_timer(round_time)

func skip_game() -> void:
	if not can_skip():
		print("[ShufflerSubManager] skip_game ignored: state=" + str(_state))
		return
	if _reroll_in_progress:
		print("[ShufflerSubManager] skip_game ignored: reroll in progress")
		return
	print("[ShufflerSubManager] skip_game: current=" + str(_current_game_index) + " " + _format_bag())
	_kill_round_timer()
	_switch_to_next_game()

func restart_game() -> void:
	if not can_restart():
		print("[ShufflerSubManager] restart_game ignored: state=" + str(_state))
		return
	if _reroll_in_progress:
		print("[ShufflerSubManager] restart_game ignored: reroll in progress")
		return
	print("[ShufflerSubManager] restart_game: current=" + str(_current_game_index))
	if _current_game_index >= 0:
		# Wait for any in-flight switch, then hold the guard so skip/timer
		# requests queue behind the restart instead of interleaving with it.
		while _switch_in_progress:
			await get_tree().process_frame
		_switch_in_progress = true
		var entry = _bag.entries[_current_game_index]
		await _stop_game(entry)
		if entry.pid != -1:
			# Restart boots a fresh instance; the old process (suspended for
			# suspend-method emulators, possibly still exiting for udp/tcp)
			# would otherwise be orphaned and untracked forever.
			LaunchManager.process.kill_process_async(entry.pid)
			await LaunchManager.process.confirm_process_dead_async(entry.pid, 3.0)
		entry.started = false
		entry.pid = -1
		if _state != State.STOPPING and _state != State.IDLE:
			_launch_game(entry)
		_switch_in_progress = false
		if _pending_switch_index != -1:
			var next = _pending_switch_index
			_pending_switch_index = -1
			_request_switch(next)

func remove_game() -> void:
	if not can_reroll():
		print("[ShufflerSubManager] remove_game ignored: state=" + str(_state))
		return
	if _current_game_index < 0:
		print("[ShufflerSubManager] remove_game ignored: no current game")
		return
	if _reroll_in_progress:
		print("[ShufflerSubManager] remove_game ignored: reroll in progress")
		return

	_reroll_in_progress = true
	_set_controls_reroll_enabled(false)

	# Wait for any in-flight switch before mutating bag entries
	while _switch_in_progress:
		await get_tree().process_frame

	var index = _current_game_index
	var entry = _bag.entries[index]
	print("[ShufflerSubManager] Rerolling slot " + str(index) + " (" + entry.game.title + ")")

	await _stop_game(entry)

	if not can_reroll():
		_reset_reroll_state()
		return

	if entry.pid != -1:
		LaunchManager.process.kill_process_async(entry.pid)
		await LaunchManager.process.confirm_process_dead_async(entry.pid)
	entry.pid = -1
	entry.started = false
	entry.active = false

	var candidate = _bag.pick_reroll_candidate(_bag.get_bag_ids())
	if candidate == null:
		_reset_reroll_state()
		push_warning("[ShufflerSubManager] No alternative game found for reroll")
		_switch_to_game(index)
		return

	_bag.replace_entry(index, candidate, "")
	var new_entry = _bag.entries[index]

	var library_m3u := _get_library_m3u(candidate)
	if library_m3u != "":
		new_entry.temp_path = library_m3u
		await _prepare_entry(index, new_entry)
		_finish_reroll(index)
		return

	if _is_multi_disc_m3u(candidate):
		# Incomplete multi-disc set: temp-download the missing discs, then
		# shuffle through a temp m3u playlist
		_download_discs_to_temp(candidate, Callable(), func(m3u_path: String):
			if _state != State.ACTIVE and _state != State.PAUSED:
				print("[ShufflerSubManager] Reroll disc downloads finished but session is no longer active; discarding result")
				_reset_reroll_state()
				return
			if m3u_path == "" or index < 0 or index >= _bag.size():
				push_warning("[ShufflerSubManager] Reroll disc downloads failed for " + candidate.title + "; relaunching previous game")
				_reset_reroll_state()
				_switch_to_game(index)
				return
			_bag.entries[index].temp_path = m3u_path
			await _prepare_entry(index, _bag.entries[index])
			_finish_reroll(index)
		)
		return

	if candidate.is_active_variant_downloaded() and FileAccess.file_exists(candidate.file_path):
		new_entry.temp_path = candidate.file_path
		await _prepare_entry(index, new_entry)
		_finish_reroll(index)
		return

	var download_url = SystemManager.network.get_romm_download_url(candidate.get_active_game_id(), candidate.get_active_file_name())
	var temp_dir = TEMP_DIR + str(candidate.romm_id)
	var temp_path = FSM.join_paths(temp_dir, candidate.get_active_file_name())
	FSM.make_dir_recursive(temp_dir)
	new_entry.temp_path = temp_path
	var file_size = candidate.get_active_file_size()

	if not SystemManager.download.download_progress.is_connected(_on_download_progress):
		SystemManager.download.download_progress.connect(_on_download_progress)

	_reroll_download_id = SystemManager.download.queue_download(
		download_url,
		temp_path,
		"game",
		"",
		false,
		"",
		candidate,
		{"on_complete": _on_reroll_download_complete.bind(index, candidate)},
		candidate.romm_id,
		true,
		true,
		file_size,
		false
	)

	if _reroll_download_id == "":
		_reset_reroll_state()
		push_error("[ShufflerSubManager] Failed to queue reroll download")
		_switch_to_game(index)
		return

func _finish_reroll(index: int) -> void:
	if not can_reroll():
		print("[ShufflerSubManager] _finish_reroll: session no longer active; abandoning reroll")
		_reset_reroll_state()
		return
	if index < 0 or index >= _bag.size():
		push_error("[ShufflerSubManager] _finish_reroll: invalid index " + str(index))
		_reset_reroll_state()
		return
	if _bag.entries[index].status != ShufflerBag.EntryStatus.READY:
		# Launch anyway: launch_shuffler_game re-runs preparation for
		# vita3k/rpcs3, so a failed pre-prep can still recover at launch time.
		push_warning("[ShufflerSubManager] Rerolled entry not READY (status=" + _status_name(_bag.entries[index].status) + "); attempting launch anyway")
	_reset_reroll_state()
	_switch_to_game(index)

# ============================================================================
# LOGGING HELPERS
# ============================================================================

func _status_name(status: int) -> String:
	match status:
		ShufflerBag.EntryStatus.QUEUED:
			return "QUEUED"
		ShufflerBag.EntryStatus.DOWNLOADING:
			return "DOWNLOADING"
		ShufflerBag.EntryStatus.PREPARING:
			return "PREPARING"
		ShufflerBag.EntryStatus.READY:
			return "READY"
		ShufflerBag.EntryStatus.FAILED:
			return "FAILED"
	return "UNKNOWN"


func _format_entry(entry: Dictionary) -> String:
	if entry == null or entry.is_empty():
		return "null"
	return "%s [%s] status=%s pid=%d started=%s" % [
		entry.game.title,
		entry.game.platform_slug,
		_status_name(entry.status),
		entry.pid,
		entry.started
	]


func _format_bag() -> String:
	var parts: Array[String] = []
	for i in range(_bag.entries.size()):
		var entry = _bag.entries[i]
		var marker = " <-" if i == _current_game_index else ""
		parts.append(str(i) + ":" + _format_entry(entry) + marker)
	return "bag=[" + ", ".join(parts) + "]"


# ============================================================================
# BAG MANAGEMENT
# ============================================================================

func _start_bag_preparation() -> void:
	_reset_download_tracking()
	print("[ShufflerSubManager] _start_bag_preparation: " + _format_bag())

	if not SystemManager.download.download_progress.is_connected(_on_download_progress):
		SystemManager.download.download_progress.connect(_on_download_progress)

	for i in range(_bag.entries.size()):
		var entry = _bag.entries[i]
		var game = entry.game
		print("[ShufflerSubManager] _start_bag_preparation entry " + str(i) + ": " + _format_entry(entry))
		var library_m3u := _get_library_m3u(game)
		if library_m3u != "":
			entry.temp_path = library_m3u
			_prepare_entry(i, entry)
		elif _is_multi_disc_m3u(game):
			# Multi-disc m3u game with an incomplete set: temp-download the
			# missing discs and shuffle through a temp m3u playlist
			var missing_count := 0
			for e in game.get_disc_entries():
				if not e["downloaded"]:
					missing_count += 1
					_total_download_bytes += int(e.get("file_size", 0))
			_total_downloads += missing_count
			_pending_downloads += missing_count
			entry.status = ShufflerBag.EntryStatus.DOWNLOADING
			_download_discs_to_temp(game,
				func(success: bool):
					_pending_downloads -= 1
					download_progress.emit(_total_downloads - _pending_downloads, _total_downloads)
					if not success:
						entry.status = ShufflerBag.EntryStatus.FAILED
						push_error("[ShufflerSubManager] Disc download failed for " + game.title)
					_check_all_preparations_complete(),
				func(m3u_path: String):
					if m3u_path == "":
						entry.status = ShufflerBag.EntryStatus.FAILED
						_check_all_preparations_complete()
						return
					entry.temp_path = m3u_path
					_prepare_entry(i, entry)
			)
		elif game.is_active_variant_downloaded() and FileAccess.file_exists(game.file_path):
			entry.temp_path = game.file_path
			_prepare_entry(i, entry)
		else:
			_total_downloads += 1
			_pending_downloads += 1
			_total_download_bytes += game.get_active_file_size()
			_download_entry(i, entry)

## Multi-disc games on m3u-capable platforms shuffle through an m3u playlist
func _is_multi_disc_m3u(game: GameResource) -> bool:
	return M3USubManager.supports_m3u(game.platform_slug) and game.is_multi_disc()

## Returns the library m3u path when the full disc set is on disk ("" otherwise)
func _get_library_m3u(game: GameResource) -> String:
	if not _is_multi_disc_m3u(game) or not game.are_all_discs_downloaded():
		return ""
	var m3u_path: String = LaunchManager.m3u.ensure_m3u(game)
	if m3u_path != "" and FileAccess.file_exists(m3u_path):
		return m3u_path
	return ""

## Temp-downloads the missing discs of a multi-disc game, then writes a temp m3u
## (library discs are referenced by absolute path, temp discs by file name).
## on_one_done(success) fires per disc; on_done(m3u_path or "") fires once.
func _download_discs_to_temp(game: GameResource, on_one_done: Callable, on_done: Callable) -> void:
	var temp_dir = TEMP_DIR + str(game.romm_id)
	FSM.make_dir_recursive(temp_dir)
	var missing: Array[Dictionary] = []
	for e in game.get_disc_entries():
		if not e["downloaded"]:
			missing.append(e)
	print("[ShufflerSubManager] Queueing " + str(missing.size()) + " missing disc(s) for " + game.title + " to " + temp_dir)
	if missing.is_empty():
		on_done.call(_write_temp_m3u(game, temp_dir))
		return
	SystemManager.download.queue_disc_files(game, missing, temp_dir, false, true,
		func(_entry: Dictionary, success: bool):
			if on_one_done.is_valid():
				on_one_done.call(success),
		func(success: bool):
			if not success:
				on_done.call("")
				return
			on_done.call(_write_temp_m3u(game, temp_dir))
	)

func _write_temp_m3u(game: GameResource, temp_dir: String) -> String:
	var root_folder = DataManager.get_setting("games_root_folder")
	var platform_dir: String = (root_folder.value + "/" + game.platform_slug) if root_folder else ""
	var lines: Array[String] = []
	for e in game.get_disc_entries():
		if e["downloaded"]:
			lines.append(platform_dir + "/" + e["file_name"])
		else:
			# Temp-downloaded disc, relative to the m3u
			lines.append(e["file_name"])
	return M3USubManager.write_m3u(temp_dir, game.title, lines)

func _download_entry(index: int, entry: Dictionary) -> void:
	entry.status = ShufflerBag.EntryStatus.DOWNLOADING
	var game = entry.game
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()

	var download_url = SystemManager.network.get_romm_download_url(active_game_id, active_file_name)
	var temp_dir = TEMP_DIR + str(game.romm_id)
	var temp_path = FSM.join_paths(temp_dir, active_file_name)
	FSM.make_dir_recursive(temp_dir)
	entry.temp_path = temp_path

	var file_size = game.get_active_file_size()
	var captured_item_id: String = ""

	var callbacks = {
		"on_complete": func(success: bool, _path: String):
			_download_progresses[captured_item_id] = 1.0
			var completed = _total_downloads - _pending_downloads
			download_progress.emit(completed, _total_downloads)
			_pending_downloads -= 1
			print("[ShufflerSubManager] Download callback for " + game.title + ": success=" + str(success) + " pending_downloads=" + str(_pending_downloads))
			_check_all_preparations_complete()
			if success:
				_prepare_entry(index, entry)
			else:
				entry.status = ShufflerBag.EntryStatus.FAILED
				push_error("[ShufflerSubManager] Download failed for " + game.title)
	}

	print("[ShufflerSubManager] Queueing download for " + game.title + " to " + temp_path)

	var item_id = SystemManager.download.queue_download(
		download_url,
		temp_path,
		"game",
		"",
		false,
		"",
		game,
		callbacks,
		game.romm_id,
		true,
		true,
		file_size,
		false
	)

	if item_id != "":
		captured_item_id = item_id
		_active_download_item_id = item_id
		_download_item_ids.append(item_id)
		_download_sizes[item_id] = file_size
		_download_progresses[item_id] = 0.0
		entry.download_id = item_id
		if _prep_notification_id == 0:
			_show_prep_notification(item_id, game.title)
	else:
		entry.status = ShufflerBag.EntryStatus.FAILED
		_pending_downloads -= 1
		_check_all_preparations_complete()
		push_error("[ShufflerSubManager] Failed to queue download for " + game.title)

func _prepare_entry(index: int, entry: Dictionary) -> void:
	if entry.status == ShufflerBag.EntryStatus.READY or entry.status == ShufflerBag.EntryStatus.FAILED:
		return

	_pending_preparations += 1
	entry.status = ShufflerBag.EntryStatus.PREPARING
	var game = entry.game
	var emulator_id = LaunchManager.resolve_emulator_for_game(game)
	print("[ShufflerSubManager] Preparing entry " + str(index) + ": " + _format_entry(entry) + " emulator=" + emulator_id)

	# Only emulators whose launch can require prep (archive extraction /
	# title-id-based launch paths) go through preparation. Xenia is included
	# for XBLA archives, which must be extracted before xenia can launch them.
	if emulator_id == "" or not (emulator_id.begins_with("vita3k") or emulator_id.begins_with("rpcs3") or emulator_id == "xenia"):
		entry.status = ShufflerBag.EntryStatus.READY
		_pending_preparations -= 1
		print("[ShufflerSubManager] Ready (no prep needed): " + game.title)
		game_ready.emit(index)
		return

	if entry.temp_path == "":
		push_warning("[ShufflerSubManager] Skipping preparation for " + game.title + " - no temp_path")
		entry.status = ShufflerBag.EntryStatus.FAILED
		_pending_preparations -= 1
		return

	var prep_success = await LaunchManager.prepare_game_for_shuffler(game, emulator_id, entry.temp_path)
	if prep_success:
		var prepared_path = LaunchManager.get_last_prepared_rom_path(game)
		if prepared_path != "":
			entry.temp_path = prepared_path
		entry.status = ShufflerBag.EntryStatus.READY
		_pending_preparations -= 1
		print("[ShufflerSubManager] Ready after prep: " + game.title)
		game_ready.emit(index)
	else:
		push_error("[ShufflerSubManager] Failed to prepare " + game.title + " for shuffler session")
		entry.status = ShufflerBag.EntryStatus.FAILED
		_pending_preparations -= 1

	print("[ShufflerSubManager] _prepare_entry done for " + str(index) + ": " + _format_entry(entry))
	_check_all_preparations_complete()

func _check_all_preparations_complete() -> void:
	print("[ShufflerSubManager] _check_all_preparations_complete: state=" + str(_state) + " pending_downloads=" + str(_pending_downloads) + " pending_preparations=" + str(_pending_preparations) + " has_ready=" + str(_bag.has_any_ready()) + " " + _format_bag())
	if _state != State.DOWNLOADING:
		return
	if _pending_downloads == 0 and _pending_preparations == 0 and not _bag.has_any_ready():
		push_error("[ShufflerSubManager] No games could be prepared; aborting session")
		stop_session()

func _await_first_ready() -> void:
	print("[ShufflerSubManager] _await_first_ready: has_ready=" + str(_bag.has_any_ready()) + " pending_downloads=" + str(_pending_downloads) + " pending_preparations=" + str(_pending_preparations))
	if _bag.has_any_ready():
		_enter_shuffler_mode()
		return
	if _pending_downloads == 0 and _pending_preparations == 0:
		push_error("[ShufflerSubManager] No games could be prepared; aborting session")
		stop_session()
		return
	var cb = func(index: int):
		print("[ShufflerSubManager] game_ready signal received for index " + str(index) + " while state=" + str(_state))
		if _state == State.DOWNLOADING:
			_enter_shuffler_mode()
	game_ready.connect(cb, CONNECT_ONE_SHOT)

func _random_round_time() -> float:
	return randf_range(
		_config.get("round_time_min", 30.0),
		_config.get("round_time_max", 120.0)
	)

func _on_reroll_download_complete(success: bool, path: String, index: int, game: GameResource) -> void:
	print("[ShufflerSubManager] _on_reroll_download_complete: index=" + str(index) + " game=" + game.title + " success=" + str(success) + " path=" + path)
	_reroll_download_id = ""

	if _state != State.ACTIVE and _state != State.PAUSED:
		print("[ShufflerSubManager] Reroll download finished but session is no longer active; discarding result")
		_reset_reroll_state()
		return

	if index < 0 or index >= _bag.size():
		push_error("[ShufflerSubManager] Reroll completion called with invalid index " + str(index))
		_reset_reroll_state()
		return

	if success and FileAccess.file_exists(path):
		print("[ShufflerSubManager] Reroll download complete: " + game.title)
		_bag.entries[index].temp_path = path
		await _prepare_entry(index, _bag.entries[index])
		_finish_reroll(index)
	else:
		push_warning("[ShufflerSubManager] Reroll download failed for " + game.title + "; relaunching previous game")
		_reset_reroll_state()
		_switch_to_game(index)

func _reset_reroll_state() -> void:
	print("[ShufflerSubManager] _reset_reroll_state")
	_reroll_in_progress = false
	_reroll_download_id = ""
	_set_controls_reroll_enabled(true)

func _set_controls_reroll_enabled(enabled: bool) -> void:
	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.set_reroll_enabled(enabled)

# ============================================================================
# DOWNLOAD PROGRESS
# ============================================================================

func _on_download_progress(item_id: String, progress: float) -> void:
	if item_id in _download_item_ids:
		_download_progresses[item_id] = progress

func _reset_download_tracking() -> void:
	_pending_downloads = 0
	_total_downloads = 0
	_pending_preparations = 0
	_download_item_ids.clear()
	_download_progresses.clear()
	_download_sizes.clear()
	_total_download_bytes = 0
	_active_download_item_id = ""

# ============================================================================
# SHUFFLER MODE
# ============================================================================

func _show_prep_notification(item_id: String, game_title: String) -> void:
	_prep_first_item_id = item_id
	_prep_first_title = game_title
	_prep_notification_id = SystemManager.notifications.show_notification(
		"Preparing Shuffle...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		func() -> float:
			return _download_progresses.get(_prep_first_item_id, 0.0),
		func(progress_frac: float) -> String:
			return "Preparing Shuffle: %s (%d%%)" % [_prep_first_title, int(progress_frac * 100)],
		false,  # pulsing
		true  # pinned
	)

func _dismiss_prep_notification() -> void:
	if _prep_notification_id == 0:
		return
	SystemManager.notifications.dismiss_notification(_prep_notification_id)
	_prep_notification_id = 0
	_prep_first_item_id = ""
	_prep_first_title = ""

func _enter_shuffler_mode() -> void:
	if _state != State.DOWNLOADING:
		print("[ShufflerSubManager] _enter_shuffler_mode ignored: state=" + str(_state))
		return
	_state = State.ACTIVE
	_shuffle_session_active = true
	_dismiss_prep_notification()
	_start_session_log_capture()
	print("[ShufflerSubManager] _enter_shuffler_mode: " + _format_bag())

	if SystemManager.download.download_progress.is_connected(_on_download_progress):
		SystemManager.download.download_progress.disconnect(_on_download_progress)

	if SystemManager.display:
		SystemManager.display.save_last_window_size()

	_create_controls_window()

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	get_tree().root.gui_disable_input = true

	_apply_emulator_configs()

	session_started.emit()

	var first_index = _bag.pick_random_ready()
	print("[ShufflerSubManager] _enter_shuffler_mode first game index=" + str(first_index))
	if first_index == -1:
		push_error("[ShufflerSubManager] No ready game available at session start")
		stop_session()
		return
	_switch_to_game(first_index)

func _apply_emulator_configs() -> void:
	var needs_retroarch := false
	var needs_pcsx2 := false
	for entry in _bag.entries:
		var emulator_id := LaunchManager.resolve_emulator_for_game(entry.game) as String
		if emulator_id == "retroarch":
			needs_retroarch = true
		elif emulator_id == "pcsx2":
			needs_pcsx2 = true
	print("[ShufflerSubManager] _apply_emulator_configs: needs_retroarch=" + str(needs_retroarch) + " needs_pcsx2=" + str(needs_pcsx2))
	if needs_retroarch:
		_ensure_retroarch_shuffler_config()
	if needs_pcsx2:
		_ensure_pcsx2_shuffler_config()

func _switch_to_next_game() -> void:
	print("[ShufflerSubManager] _switch_to_next_game: current=" + str(_current_game_index) + " state=" + str(_state) + " " + _format_bag())
	if _bag.is_empty():
		print("[ShufflerSubManager] _switch_to_next_game: bag is empty")
		return
	var ready_indices = _bag.get_ready_indices(_current_game_index)
	print("[ShufflerSubManager] _switch_to_next_game ready indices excluding current=" + str(ready_indices))
	var next_index = _bag.pick_random_ready(_current_game_index)
	if next_index == -1:
		print("[ShufflerSubManager] No other ready game; extending current round")
		_start_round_timer(_random_round_time())
		return
	_request_switch(next_index)

## Serializes game switches: while a switch coroutine is in flight, only the
## latest requested target is kept (skip-mashing degenerates to "last wins").
func _request_switch(index: int) -> void:
	if _state == State.STOPPING or _state == State.IDLE:
		return
	if _switch_in_progress:
		_pending_switch_index = index
		return
	_switch_in_progress = true
	await _switch_to_game(index)
	_switch_in_progress = false
	if _pending_switch_index != -1:
		var next = _pending_switch_index
		_pending_switch_index = -1
		_request_switch(next)

func _switch_to_game(index: int) -> void:
	print("[ShufflerSubManager] _switch_to_game: index=" + str(index) + " current=" + str(_current_game_index) + " state=" + str(_state) + " " + _format_bag())
	if index < 0 or index >= _bag.size():
		print("[ShufflerSubManager] _switch_to_game: invalid index " + str(index))
		return
	if _current_game_index >= 0 and _current_game_index < _bag.size():
		var prev = _bag.entries[_current_game_index]
		prev.active = false
		print("[ShufflerSubManager] _switch_to_game stopping previous: " + _format_entry(prev))
		await _stop_game(prev)

	# stop_session may have raced the stop await: never launch during teardown
	if _state == State.STOPPING or _state == State.IDLE:
		print("[ShufflerSubManager] _switch_to_game aborted: state=" + str(_state))
		return

	_current_game_index = index
	_maximize_token += 1
	var entry = _bag.entries[index]
	entry.active = true

	var method := entry.suspend_method as String
	print("[ShufflerSubManager] _switch_to_game: target=" + _format_entry(entry) + " method=" + method)
	if method == "suspend" and entry.started and entry.pid != -1 and await _is_process_running_async(entry.pid):
		print("[ShufflerSubManager] _switch_to_game: resuming existing process")
		await _resume_game(entry)
	elif entry.started and entry.pid != -1 and await _is_process_running_async(entry.pid):
		print("[ShufflerSubManager] _switch_to_game: killing lingering process and relaunching")
		LaunchManager.process.kill_process_async(entry.pid)
		entry.started = false
		entry.pid = -1
		_launch_game(entry)
	else:
		print("[ShufflerSubManager] _switch_to_game: launching fresh")
		entry.started = false
		entry.pid = -1
		_launch_game(entry)

	print("[ShufflerSubManager] _switch_to_game: launched index=" + str(index) + " state=" + str(_state))
	if _state == State.ACTIVE or _state == State.PAUSED:
		var round_time = _random_round_time()
		print("[ShufflerSubManager] _switch_to_game: starting round timer " + str(round_time) + "s")
		_start_round_timer(round_time)
	else:
		print("[ShufflerSubManager] _switch_to_game: not starting timer because state=" + str(_state))

	var game = entry.game
	game_switched.emit(game.title, game.platform_slug)

# ============================================================================
# GAME LAUNCH
# ============================================================================

func _launch_game(entry: Dictionary) -> void:
	var game = entry.game
	var emulator_id = LaunchManager.resolve_emulator_for_game(game)
	entry.emulator_id = emulator_id

	var emulator = LaunchManager.get_emulator(emulator_id)
	entry.suspend_method = emulator.get("suspend_method", "suspend")
	print("[ShufflerSubManager] _launch_game: " + _format_entry(entry) + " emulator=" + emulator_id + " method=" + entry.suspend_method + " temp_path=" + entry.temp_path)

	var on_pid_ready = func(pid: int):
		print("[ShufflerSubManager] on_pid_ready for " + game.title + ": pid=" + str(pid))
		if pid != -1:
			# Prerequisites (downloads, prep) can delay this callback past a
			# switch or stop; a process that arrives late must not take focus
			# or linger untracked.
			var is_stale: bool = (_state != State.ACTIVE and _state != State.PAUSED) \
				or _current_game_index < 0 or _current_game_index >= _bag.size() \
				or _bag.entries[_current_game_index].game != game \
				or entry.pid != -1
			if is_stale:
				push_warning("[ShufflerSubManager] Late pid " + str(pid) + " for " + game.title + " arrived after switch/stop; killing it")
				LaunchManager.process.kill_process_async(pid)
				return
			entry.pid = pid
			entry.started = true
			_maximize_with_retry(pid)
		else:
			push_error("[ShufflerSubManager] Failed to launch game: " + game.title)

		if emulator_id.begins_with("vita3k"):
			var title_id = game.get_active_title_id()
			if title_id != "":
				var install_path = LaunchManager.get_emulator_install_path(emulator_id)
				if install_path != "":
					var ux0_app_path = install_path.get_base_dir() + "/ux0/app/" + title_id
					entry.vita_title_id = title_id
					entry.vita_app_path = ux0_app_path
					var already_tracked := false
					for tracked in _shuffler_vita_apps:
						if tracked.get("title_id", "") == title_id:
							already_tracked = true
							break
					if not already_tracked:
						_shuffler_vita_apps.append({
							"title_id": title_id,
							"ux0_app_path": ux0_app_path
						})
						print("[ShufflerSubManager] Tracked Vita3K shuffler app for cleanup: " + ux0_app_path)
			else:
				push_warning("[ShufflerSubManager] Vita3K game launched but no TitleID was extracted: " + game.title)

	LaunchManager.launch_shuffler_game(game, entry.temp_path, on_pid_ready)

# ============================================================================
# GAME STOP / SUSPEND / RESUME
# ============================================================================

func _stop_game(entry: Dictionary) -> void:
	_maximize_token += 1  # cancel any maximize retries still targeting this entry
	if entry.pid == -1:
		print("[ShufflerSubManager] _stop_game: no pid for " + _format_entry(entry))
		return

	var method = entry.suspend_method
	print("[ShufflerSubManager] _stop_game: " + _format_entry(entry) + " method=" + method)
	match method:
		"udp":
			_send_udp_command("localhost", 55355, "QUIT")
			await get_tree().create_timer(0.5).timeout
			_send_udp_command("localhost", 55355, "QUIT")
		"tcp":
			var save_hash = str(entry.game.romm_id)
			await _send_tcp_command("localhost", 4444, "savevm " + save_hash)
			await _send_tcp_command("localhost", 4444, "quit")
		"suspend", _:
			_suspend_game(entry)

func _suspend_game(entry: Dictionary) -> void:
	if entry.pid == -1:
		print("[ShufflerSubManager] _suspend_game: no pid for " + _format_entry(entry))
		return

	var emulator = LaunchManager.get_emulator(entry.emulator_id)
	var exe_name = ""
	var launch_config = emulator.get("launch", {})
	var platforms = launch_config.get("platforms", {})
	var pc = platforms.get("windows", {})
	exe_name = pc.get("executable", "")

	print("[ShufflerSubManager] _suspend_game: " + _format_entry(entry) + " exe=" + exe_name)
	_hide_window_async(entry.pid, exe_name)

	LaunchManager.process.suspend_process_async(entry.pid, _pssuspend_path)

	entry.active = false

func _resume_game(entry: Dictionary) -> void:
	if entry.pid == -1:
		print("[ShufflerSubManager] _resume_game: no pid for " + _format_entry(entry))
		return

	print("[ShufflerSubManager] _resume_game: " + _format_entry(entry))
	LaunchManager.process.resume_process_async(entry.pid, _pssuspend_path)

	await get_tree().create_timer(0.2).timeout

	await _maximize_with_retry(entry.pid)

	entry.active = true

# ============================================================================
# TIMER
# ============================================================================

func _start_round_timer(duration: float) -> void:
	print("[ShufflerSubManager] _start_round_timer: duration=" + str(duration) + "s state=" + str(_state))
	_kill_round_timer()
	_round_timer = Timer.new()
	_round_timer.one_shot = true
	_round_timer.wait_time = duration
	_round_timer.paused = (_state == State.PAUSED)
	_round_timer.timeout.connect(_on_round_timer_timeout)
	add_child(_round_timer)
	_round_timer.start()

	_countdown_timer = Timer.new()
	_countdown_timer.one_shot = false
	_countdown_timer.wait_time = 0.1
	_countdown_timer.timeout.connect(_emit_timer_updated)
	add_child(_countdown_timer)
	_countdown_timer.start()
	_emit_timer_updated()

func _kill_round_timer() -> void:
	print("[ShufflerSubManager] _kill_round_timer")
	if _round_timer and is_instance_valid(_round_timer):
		_round_timer.stop()
		_round_timer.queue_free()
		_round_timer = null
	if _countdown_timer and is_instance_valid(_countdown_timer):
		_countdown_timer.stop()
		_countdown_timer.queue_free()
		_countdown_timer = null

func _on_round_timer_timeout() -> void:
	print("[ShufflerSubManager] _on_round_timer_timeout: state=" + str(_state) + " " + _format_bag())
	if _state != State.ACTIVE:
		print("[ShufflerSubManager] _on_round_timer_timeout ignored: state=" + str(_state))
		return
	if _reroll_in_progress:
		# The reroll flow owns the current switch; its completion re-arms the timer.
		print("[ShufflerSubManager] _on_round_timer_timeout ignored: reroll in progress")
		return
	if _countdown_timer and is_instance_valid(_countdown_timer):
		_countdown_timer.stop()
	_switch_to_next_game()

func _emit_timer_updated() -> void:
	if _round_timer and is_instance_valid(_round_timer) and _state == State.ACTIVE:
		timer_updated.emit(_round_timer.time_left)
	else:
		if _countdown_timer and is_instance_valid(_countdown_timer):
			_countdown_timer.stop()

func _input(event: InputEvent) -> void:
	if _state == State.IDLE:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F10:
			stop_session()
			get_viewport().set_input_as_handled()

# ============================================================================
# WINDOW / PROCESS HELPERS
# ============================================================================

func _hide_window_async(pid: int, exe_name: String) -> void:
	var ahk_script = _tools_dir + "minimize_window.ahk"
	if FileAccess.file_exists(ahk_script) and FileAccess.file_exists(_ahk_path):
		MemorySubManager.queue_os_execute(_ahk_path, [ahk_script, str(pid), exe_name])

func _hide_window(pid: int, exe_name: String) -> void:
	_hide_window_async(pid, exe_name)

func _is_current_game_pid(pid: int) -> bool:
	if _state != State.ACTIVE and _state != State.PAUSED:
		return false
	if _current_game_index < 0 or _current_game_index >= _bag.size():
		return false
	return _bag.entries[_current_game_index].pid == pid

func _maximize_with_retry(pid: int) -> void:
	print("[ShufflerSubManager] _maximize_with_retry START pid=" + str(pid))
	var token := _maximize_token
	var maximized := false
	for i in range(3):
		if token != _maximize_token or not _is_current_game_pid(pid):
			print("[ShufflerSubManager] _maximize_with_retry aborted: pid " + str(pid) + " is no longer the foreground game")
			return
		print("[ShufflerSubManager] Maximizing pid " + str(pid) + " (attempt " + str(i + 1) + "/3)")
		if await _maximize_window_async(pid, token):
			print("[ShufflerSubManager] pid " + str(pid) + " maximized successfully")
			maximized = true
			break
		await get_tree().create_timer(0.5).timeout
	print("[ShufflerSubManager] _maximize_with_retry END pid=" + str(pid) + " maximized=" + str(maximized))
	if token != _maximize_token or not _is_current_game_pid(pid):
		return
	if not maximized:
		push_error("[ShufflerSubManager] Failed to maximize window for pid " + str(pid) + " after 3 attempts")
	_raise_controls_window()

func _maximize_window_async(pid: int, token: int = -1) -> bool:
	var ahk_script = _tools_dir + "maximize_process.ahk"
	if not FileAccess.file_exists(ahk_script) or not FileAccess.file_exists(_ahk_path):
		print("[ShufflerSubManager] _maximize_window_async missing tool: ahk_script=" + str(FileAccess.file_exists(ahk_script)) + " ahk_path=" + str(FileAccess.file_exists(_ahk_path)))
		return false

	var os_state := {"completed": false, "success": false, "output_text": ""}

	MemorySubManager.queue_os_execute(_ahk_path, [ahk_script, str(pid)], func(result: Dictionary):
		os_state["completed"] = true
		os_state["success"] = (result.get("exit_code", -1) == 0)
		var output: Array = result.get("output", [])
		os_state["output_text"] = "".join(output)
		print("[ShufflerSubManager] maximize_process.ahk result for pid " + str(pid) + ": exit=" + str(result.get("exit_code", -1)) + " output=\"" + os_state["output_text"].strip_edges() + "\"")
	)

	while not os_state["completed"]:
		if token != -1 and token != _maximize_token:
			# Switched away mid-attempt; the AHK process finishes in the
			# background and its result is discarded.
			return false
		await get_tree().process_frame

	return os_state["success"]

func _maximize_window(pid: int) -> bool:
	return await _maximize_window_async(pid)

func _is_process_running_async(pid: int) -> bool:
	return await LaunchManager.process.is_running_async(pid)

func _send_udp_command(host: String, port: int, command: String) -> void:
	var address := IP.resolve_hostname(host, IP.TYPE_IPV4)
	if address.is_empty():
		push_error("[ShufflerSubManager] Failed to resolve host: " + host)
		return

	var udp = PacketPeerUDP.new()
	var err = udp.connect_to_host(address, port)
	if err != OK:
		push_error("[ShufflerSubManager] Failed to connect UDP to " + address + ":" + str(port))
		return
	udp.put_packet(command.to_utf8_buffer())
	udp.close()

func _send_tcp_command(host: String, port: int, command: String) -> void:
	var address := IP.resolve_hostname(host, IP.TYPE_IPV4)
	var tcp = StreamPeerTCP.new()
	var err = tcp.connect_to_host(address, port)
	if err != OK:
		push_error("[ShufflerSubManager] Failed to connect TCP to " + address + ":" + str(port))
		return

	var attempts = 0
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING and attempts < 50:
		await get_tree().process_frame
		attempts += 1

	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("[ShufflerSubManager] TCP connection timed out to " + host + ":" + str(port))
		return

	tcp.put_data((command + "\n").to_utf8_buffer())

	await get_tree().create_timer(0.1).timeout
	tcp.disconnect_from_host()

# ============================================================================
# CONTROLS WINDOW
# ============================================================================

func _create_controls_window() -> void:
	print("[ShufflerSubManager] _create_controls_window")
	if _controls_window and is_instance_valid(_controls_window):
		print("[ShufflerSubManager] _create_controls_window: freeing existing controls window")
		_controls_window.queue_free()

	var scene = load("res://components/shuffler_controls_window.tscn")
	if not scene:
		push_error("[ShufflerSubManager] Failed to load controls window scene")
		return

	_controls_window = scene.instantiate()
	_controls_window.pause_requested.connect(pause_session)
	_controls_window.resume_requested.connect(resume_session)
	_controls_window.skip_requested.connect(skip_game)
	_controls_window.restart_requested.connect(restart_game)
	_controls_window.remove_requested.connect(remove_game)
	_controls_window.stop_requested.connect(stop_session)

	get_tree().root.add_child(_controls_window)
	_controls_window.popup()
	_raise_controls_window()
	_start_controls_topmost_timer()
	print("[ShufflerSubManager] Controls palette created: window_id=" + str(_controls_window.get_window_id()) + " visible=" + str(_controls_window.visible))

func _raise_controls_window() -> void:
	if not _controls_window or not is_instance_valid(_controls_window):
		return
	var window_id: int = _controls_window.get_window_id()
	if window_id == DisplayServer.INVALID_WINDOW_ID:
		print("[ShufflerSubManager] _raise_controls_window: invalid window id")
		return
	DisplayServer.window_move_to_foreground(window_id)

func _start_controls_topmost_timer() -> void:
	_stop_controls_topmost_timer()
	if not _controls_window or not is_instance_valid(_controls_window):
		print("[ShufflerSubManager] _start_controls_topmost_timer: no controls window")
		return
	print("[ShufflerSubManager] _start_controls_topmost_timer")
	_controls_topmost_timer = Timer.new()
	_controls_topmost_timer.wait_time = 0.5
	_controls_topmost_timer.one_shot = false
	_controls_topmost_timer.timeout.connect(_raise_controls_window)
	add_child(_controls_topmost_timer)
	_controls_topmost_timer.start()

func _stop_controls_topmost_timer() -> void:
	if _controls_topmost_timer and is_instance_valid(_controls_topmost_timer):
		print("[ShufflerSubManager] _stop_controls_topmost_timer")
		_controls_topmost_timer.stop()
		_controls_topmost_timer.queue_free()
		_controls_topmost_timer = null

# ============================================================================
# RETROARCH CONFIG
# ============================================================================

func _ensure_retroarch_shuffler_config() -> void:
	var edits: Array[Dictionary] = []
	for key in RETROARCH_SHUFFLER_CFG:
		var value: String = RETROARCH_SHUFFLER_CFG[key]
		edits.append({
			"old": r'%s\s*=\s*"[^"]*"' % key,
			"new": '%s = "%s"' % [key, value],
			"regex": true,
		})

	if not LaunchManager.edit_emulator_file_with_backup("retroarch", "{emulator_dir}/retroarch.cfg", edits, true, RETROARCH_SHUFFLER_CFG, ""):
		push_error("[ShufflerSubManager] Failed to apply retroarch.cfg edits")

# ============================================================================
# CLEANUP
# ============================================================================

func _ensure_pcsx2_shuffler_config() -> void:
	var emu_dir := FSM.resolve_emulator_path("{emulator_dir}", "pcsx2")
	if emu_dir != "":
		var portable_path := FSM.join_paths(emu_dir, "portable.txt")
		if not FSM.file_exists(portable_path):
			FSM.write_file(portable_path, "")
			print("[ShufflerSubManager] Created portable.txt to force PCSX2 portable mode")

	var edits: Array[Dictionary] = []
	for key in PCSX2_MEMORY_CARD_KEYS:
		edits.append({
			"old": r'%s\s*=\s*[^\n]*' % key,
			"new": '%s = %s' % [key, PCSX2_MEMORY_CARD_VALUES[key]],
			"regex": true,
		})

	if not LaunchManager.edit_emulator_file_with_backup("pcsx2", PCSX2_SHUFFLER_INI_PATH, edits, false, PCSX2_MEMORY_CARD_VALUES, "MemoryCards"):
		push_error("[ShufflerSubManager] Failed to apply PCSX2.ini memory-card edits")
		return

	var cfg_path := FSM.resolve_emulator_path(PCSX2_SHUFFLER_INI_PATH, "pcsx2")
	if cfg_path == "":
		return
	print("[ShufflerSubManager] PCSX2 shuffler config path: " + cfg_path)
	var content := FSM.read_file(cfg_path)
	var section_regex := RegEx.new()
	section_regex.compile(r"(?s)\[MemoryCards\].*?(?=\n\[|\Z)")
	var section_match := section_regex.search(content)
	if section_match:
		print("[ShufflerSubManager] PCSX2 [MemoryCards] section:\n" + section_match.get_string().strip_edges())
	else:
		print("[ShufflerSubManager] PCSX2 [MemoryCards] section not found")

func _cleanup_vita3k_shuffler_apps() -> void:
	for entry in _shuffler_vita_apps:
		var app_path = entry.get("ux0_app_path", "") as String
		if app_path == "":
			continue

		var sentinel_path = app_path + "/.kyodai_shuffler"
		if not FSM.file_exists(sentinel_path):
			push_warning("[ShufflerSubManager] Refusing to clean up Vita3K app folder without sentinel: " + app_path)
			continue

		if FSM.dir_exists(app_path):
			print("[ShufflerSubManager] Cleaning up Vita3K shuffler app folder: " + app_path)
			FSM.delete_dir_recursive(app_path)
		else:
			print("[ShufflerSubManager] Vita3K shuffler app folder already gone: " + app_path)

	_shuffler_vita_apps.clear()

func _cleanup_temp_files() -> void:
	if DirAccess.dir_exists_absolute(TEMP_DIR):
		FSM.delete_dir_recursive(TEMP_DIR)

func _restore_emulator_file_if_backed_up(emulator_id: String, file_path: String) -> void:
	if LaunchManager.has_emulator_file_backup(emulator_id, file_path):
		LaunchManager.restore_emulator_file(emulator_id, file_path)
	else:
		print("[ShufflerSubManager] Skipping restore for " + emulator_id + " " + file_path + " (no backup)")
