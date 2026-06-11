extends Manager

## Manages shuffler sessions: bag building, game switching, process control.

const FSM = preload("res://managers/filesystem_manager.gd")

enum State { IDLE, DOWNLOADING, ACTIVE, PAUSED, STOPPING }

signal session_started()
signal session_stopped()
signal game_switched(game_title: String, platform_name: String)
signal timer_updated(time_left: float)
signal download_progress(current: int, total: int)

var _state: State = State.IDLE
var _bag: Array[Dictionary] = []
var _current_game_index: int = -1
var _round_timer: Timer = null
var _config: Dictionary = {}
var _controls_window: Node = null
var _main_window: Window = null
var _pending_downloads: int = 0
var _total_downloads: int = 0
var _tools_dir: String = ""
var _sfk_path: String = ""
var _ahk_path: String = ""
var _pssuspend_path: String = ""
var _notification_id: int = -1

# Download progress tracking
var _download_item_ids: Array[String] = []
var _download_progresses: Dictionary = {}  # item_id -> float
var _download_sizes: Dictionary = {}       # item_id -> int (bytes)
var _total_download_bytes: int = 0
var _completed_download_bytes: int = 0

const TEMP_DIR := "user://shuffler_temp/"

func _ready():
	_main_window = get_tree().root
	var base_dir = OS.get_executable_path().get_base_dir()
	_tools_dir = base_dir + "/bin/shuffler_tools/"
	_sfk_path = _tools_dir + "sfk.exe"
	_ahk_path = base_dir + "/bin/ahk/AutoHotkey64.exe"
	_pssuspend_path = _tools_dir + "pssuspend.exe"

func _exit_tree():
	if is_session_active():
		stop_session()

# ============================================================================
# PUBLIC API
# ============================================================================

func is_session_active() -> bool:
	return _state != State.IDLE

func get_state() -> State:
	return _state

func start_session(config: Dictionary) -> void:
	if _state != State.IDLE:
		push_error("[ShufflerManager] Already in a session")
		return

	if not PlatformManager.is_windows():
		NotificationManager.show_notification("Shuffler is only available on Windows", NotificationManager.Type.ERROR)
		return

	_state = State.DOWNLOADING
	_config = config

	# Reset download progress tracking
	_download_item_ids.clear()
	_download_progresses.clear()
	_download_sizes.clear()
	_total_download_bytes = 0
	_completed_download_bytes = 0

	var platforms = config.get("platforms", [])
	var bag_size = config.get("bag_size", 4)

	if platforms.is_empty():
		NotificationManager.show_notification("No platforms selected for shuffler", NotificationManager.Type.ERROR)
		_state = State.IDLE
		return

	_build_bag(platforms, bag_size)

	if _bag.is_empty():
		NotificationManager.show_notification("No games found for selected platforms", NotificationManager.Type.ERROR)
		_state = State.IDLE
		return

	_download_bag_games()

	if _pending_downloads == 0:
		_enter_shuffler_mode()

func stop_session() -> void:
	if _state == State.IDLE:
		return

	_state = State.STOPPING

	_kill_round_timer()

	# Disconnect from DownloadManager progress signal
	if DownloadManager.download_progress.is_connected(_on_download_progress):
		DownloadManager.download_progress.disconnect(_on_download_progress)

	# Kill all running processes and wait for them to actually die before cleanup
	var pids_to_wait: Array[int] = []
	for entry in _bag:
		if entry["pid"] != -1:
			_force_kill_process(entry["pid"])
			pids_to_wait.append(entry["pid"])

	# Wait for processes to actually terminate before cleanup (files may be locked)
	for pid in pids_to_wait:
		await _confirm_process_dead(pid)

	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.queue_free()
		_controls_window = null

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# Force window to front after restoring
	DisplayServer.window_move_to_foreground()

	_cleanup_temp_files()

	_bag.clear()
	_current_game_index = -1
	_config.clear()
	_state = State.IDLE

	session_stopped.emit()

func pause_session() -> void:
	if _state != State.ACTIVE:
		return
	_state = State.PAUSED
	if _round_timer:
		_round_timer.paused = true

func resume_session() -> void:
	if _state != State.PAUSED:
		return
	_state = State.ACTIVE
	if _round_timer:
		_round_timer.paused = false

func skip_game() -> void:
	if _state != State.ACTIVE and _state != State.PAUSED:
		return
	_kill_round_timer()
	_switch_to_next_game()

func restart_game() -> void:
	if _state != State.ACTIVE and _state != State.PAUSED:
		return
	if _current_game_index >= 0:
		var entry = _bag[_current_game_index]
		_stop_game(entry)
		entry["started"] = false
		entry["pid"] = -1
		_launch_game(entry)

func remove_game() -> void:
	if _state != State.ACTIVE and _state != State.PAUSED:
		return
	if _current_game_index < 0:
		return
	var entry = _bag[_current_game_index]
	_stop_game(entry)
	_reroll_entry(_current_game_index)
	_switch_to_game(_current_game_index)

# ============================================================================
# BAG MANAGEMENT
# ============================================================================

func _build_bag(platforms: Array, bag_size: int) -> void:
	_bag.clear()

	var all_candidates: Array[GameResource] = []
	for platform_slug in platforms:
		var games = DataManager.get_games_by_platform(platform_slug)
		all_candidates.append_array(games)

	if all_candidates.is_empty():
		return

	all_candidates.shuffle()

	var added_ids: Array[int] = []
	for game in all_candidates:
		if game.romm_id in added_ids:
			continue
		added_ids.append(game.romm_id)
		_bag.append({
			"game": game,
			"temp_path": "",
			"pid": -1,
			"started": false,
			"active": false,
			"emulator_id": "",
			"suspend_method": "",
		})
		if _bag.size() >= bag_size:
			break

func _reroll_entry(index: int) -> void:
	if index < 0 or index >= _bag.size():
		return

	var current_platforms: Array[String] = []
	for entry in _bag:
		if entry["game"].platform_slug not in current_platforms:
			current_platforms.append(entry["game"].platform_slug)

	var candidates: Array[GameResource] = []
	for slug in current_platforms:
		candidates.append_array(DataManager.get_games_by_platform(slug))

	candidates.shuffle()

	var existing_ids: Array[int] = []
	for i in range(_bag.size()):
		if i != index:
			existing_ids.append(_bag[i]["game"].romm_id)

	for game in candidates:
		if game.romm_id in existing_ids:
			continue
		if game.is_active_variant_downloaded() and FileAccess.file_exists(game.file_path):
			_bag[index] = {
				"game": game,
				"temp_path": game.file_path,
				"pid": -1,
				"started": false,
				"active": false,
				"emulator_id": "",
				"suspend_method": "",
			}
			break

# ============================================================================
# DOWNLOADS (sequential — one at a time)
# ============================================================================

func _download_bag_games() -> void:
	_pending_downloads = 0
	_total_downloads = 0
	var need_download: Array[Dictionary] = []
	
	# Connect to DownloadManager progress signal
	if not DownloadManager.download_progress.is_connected(_on_download_progress):
		DownloadManager.download_progress.connect(_on_download_progress)
	
	for entry in _bag:
		var game = entry["game"]
		if game.is_active_variant_downloaded() and FileAccess.file_exists(game.file_path):
			entry["temp_path"] = game.file_path
		else:
			_pending_downloads += 1
			_total_downloads += 1
			need_download.append(entry)
			_total_download_bytes += game.get_active_file_size()
	
	if need_download.is_empty():
		_call_enter_shuffler_mode()
		return
	
	# Show progress notification now that we know the total size
	var progress_callable = func() -> float:
		if _total_download_bytes == 0:
			return 0.0
		var downloaded = float(_completed_download_bytes)
		# Find the active download (only one is active at a time in sequential mode)
		for item_id in _download_item_ids:
			var progress = _download_progresses.get(item_id, 0.0)
			if progress > 0.0 and progress < 1.0:
				downloaded += progress * float(_download_sizes.get(item_id, 0))
				break
		return downloaded / float(_total_download_bytes)
	
	var text_formatter = func(progress: float) -> String:
		var total_mb = _total_download_bytes / (1024.0 * 1024.0)
		var downloaded_mb = total_mb * progress
		return "Preparing shuffle... %d/%d MB (%d%%)" % [int(downloaded_mb), int(total_mb), int(progress * 100)]
	
	_notification_id = NotificationManager.show_notification(
		"Preparing shuffle...",
		NotificationManager.Type.INFO,
		null,
		0.0,
		progress_callable,
		text_formatter,
		false,
		true
	)
	
	download_progress.emit(0, _total_downloads)
	_download_next(need_download, 0)

func _download_next(entries: Array[Dictionary], index: int) -> void:
	if index >= entries.size():
		return
	
	var entry = entries[index]
	var game = entry["game"]
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var temp_dir = TEMP_DIR + str(game.romm_id)
	var temp_path = FSM.join_paths(temp_dir, active_file_name)
	
	FSM.make_dir_recursive(temp_dir)
	entry["temp_path"] = temp_path
	
	var file_size = game.get_active_file_size()
	
	var callbacks = {
		"on_complete": func(success: bool, _path: String):
			_pending_downloads -= 1
			_completed_download_bytes += file_size
			var completed = _total_downloads - _pending_downloads
			download_progress.emit(completed, _total_downloads)
			if _pending_downloads == 0 and _state == State.DOWNLOADING:
				_call_enter_shuffler_mode()
			else:
				_download_next(entries, index + 1)
	}
	
	var item_id = DownloadManager.queue_download(download_url, temp_path, "game", "", false, "", game, callbacks, game.romm_id, true, true, file_size, false)
	
	if item_id != "":
		_download_item_ids.append(item_id)
		_download_sizes[item_id] = file_size
		_download_progresses[item_id] = 0.0

func _call_enter_shuffler_mode() -> void:
	# Defer to avoid thread issues from download callbacks
	call_deferred("_enter_shuffler_mode")

func _on_download_progress(item_id: String, progress: float) -> void:
	if item_id in _download_item_ids:
		_download_progresses[item_id] = progress

# ============================================================================
# SHUFFLER MODE
# ============================================================================

func _enter_shuffler_mode() -> void:
	_state = State.ACTIVE

	# Disconnect from DownloadManager progress signal
	if DownloadManager.download_progress.is_connected(_on_download_progress):
		DownloadManager.download_progress.disconnect(_on_download_progress)

	if _notification_id != -1:
		NotificationManager.dismiss_notification(_notification_id)
		_notification_id = -1

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)

	_create_controls_window()
	session_started.emit()
	_switch_to_game(0)

func _switch_to_next_game() -> void:
	if _bag.is_empty():
		return
	var next_index = (_current_game_index + 1) % _bag.size()
	_switch_to_game(next_index)

func _switch_to_game(index: int) -> void:
	if _current_game_index >= 0 and _current_game_index < _bag.size():
		var prev = _bag[_current_game_index]
		prev["active"] = false
		_stop_game(prev)

	_current_game_index = index
	var entry = _bag[index]
	entry["active"] = true

	if entry["started"] and entry["pid"] != -1 and _is_process_running(entry["pid"]):
		_resume_game(entry)
	else:
		entry["started"] = false
		entry["pid"] = -1
		_launch_game(entry)

	var round_time = randf_range(
		_config.get("round_time_min", 30.0),
		_config.get("round_time_max", 120.0)
	)
	_start_round_timer(round_time)

	var game = entry["game"]
	game_switched.emit(game.title, game.platform_slug)

# ============================================================================
# GAME LAUNCH
# ============================================================================

func _launch_game(entry: Dictionary) -> void:
	var game = entry["game"]
	var emulator_id = LaunchManager.resolve_emulator_for_game(game)
	entry["emulator_id"] = emulator_id

	var emulator = LaunchManager.get_emulator(emulator_id)
	entry["suspend_method"] = emulator.get("suspend_method", "suspend")

	var on_pid_ready = func(pid: int):
		if pid != -1:
			entry["pid"] = pid
			entry["started"] = true
			_maximize_window(pid)
		else:
			push_error("[ShufflerManager] Failed to launch game: " + game.title)

	LaunchManager.launch_shuffler_game(game, entry["temp_path"], on_pid_ready)

# ============================================================================
# GAME STOP / SUSPEND / RESUME
# ============================================================================

func _stop_game(entry: Dictionary) -> void:
	if entry["pid"] == -1:
		return

	var method = entry.get("suspend_method", "suspend")
	match method:
		"udp":
			_send_udp_command("localhost", 55355, "QUIT")
			_send_udp_command("localhost", 55355, "QUIT")
		"tcp":
			# Xemu: savevm then quit
			var hash = str(entry["game"].romm_id)
			_send_tcp_command("localhost", 4444, "savevm " + hash)
			_send_tcp_command("localhost", 4444, "quit")
		"suspend", _:
			_suspend_game(entry)

func _suspend_game(entry: Dictionary) -> void:
	if entry["pid"] == -1:
		return

	var emulator = LaunchManager.get_emulator(entry["emulator_id"])
	var exe_name = ""
	var launch_config = emulator.get("launch", {})
	var platforms = launch_config.get("platforms", {})
	var pc = platforms.get("windows", {})
	exe_name = pc.get("executable", "")

	# Hide window
	_hide_window(entry["pid"], exe_name)

	# Freeze threads with pssuspend
	var output: Array[String] = []
	OS.execute(_pssuspend_path, [str(entry["pid"])], output, true)

	entry["active"] = false

func _resume_game(entry: Dictionary) -> void:
	if entry["pid"] == -1:
		return

	# Thaw with pssuspend
	var output: Array[String] = []
	OS.execute(_pssuspend_path, ["-r", str(entry["pid"])], output, true)

	# Maximize window
	_maximize_window(entry["pid"])

	entry["active"] = true

# ============================================================================
# TIMER
# ============================================================================

func _start_round_timer(duration: float) -> void:
	_kill_round_timer()
	_round_timer = Timer.new()
	_round_timer.one_shot = true
	_round_timer.wait_time = duration
	_round_timer.timeout.connect(_on_round_timer_timeout)
	add_child(_round_timer)
	_round_timer.start()

func _kill_round_timer() -> void:
	if _round_timer and is_instance_valid(_round_timer):
		_round_timer.stop()
		_round_timer.queue_free()
		_round_timer = null

func _on_round_timer_timeout() -> void:
	_switch_to_next_game()

func _process(_delta: float) -> void:
	if _round_timer and is_instance_valid(_round_timer) and _state == State.ACTIVE:
		timer_updated.emit(_round_timer.time_left)

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

func _hide_window(pid: int, exe_name: String) -> void:
	var ahk_script = _tools_dir + "minimize_window.ahk"
	if FileAccess.file_exists(ahk_script) and FileAccess.file_exists(_ahk_path):
		var output: Array[String] = []
		OS.execute(_ahk_path, [ahk_script, str(pid), exe_name], output, true)

func _maximize_window(pid: int) -> void:
	var ahk_script = _tools_dir + "maximize_process.ahk"
	if FileAccess.file_exists(ahk_script) and FileAccess.file_exists(_ahk_path):
		var output: Array[String] = []
		OS.execute(_ahk_path, [ahk_script, str(pid)], output, true)

func _force_kill_process(pid: int) -> void:
	if PlatformManager.is_windows():
		var output: Array[String] = []
		OS.execute("taskkill", ["/F", "/PID", str(pid)], output, true)
	else:
		OS.execute("kill", ["-9", str(pid)], [], true)

func _is_process_running(pid: int) -> bool:
	var output: Array[String] = []
	var exit_code = OS.execute("tasklist", ["/FI", "PID eq " + str(pid), "/NH"], output, true)
	return exit_code == 0 and output.size() > 0 and str(pid) in output[0]

func _confirm_process_dead(pid: int) -> void:
	var elapsed = 0.0
	while _is_process_running(pid) and elapsed < 5.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2

func _send_udp_command(host: String, port: int, command: String) -> void:
	if FileAccess.file_exists(_sfk_path):
		var output: Array[String] = []
		OS.execute(_sfk_path, ["udpsend", host, str(port), command], output, true)

func _send_tcp_command(host: String, port: int, command: String) -> void:
	if FileAccess.file_exists(_sfk_path):
		var output: Array[String] = []
		OS.execute(_sfk_path, ["connect", host, str(port), "+send", command, "+receive", "1s"], output, true)

# ============================================================================
# CONTROLS WINDOW
# ============================================================================

func _create_controls_window() -> void:
	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.queue_free()

	var win = Window.new()
	win.title = "Shuffler"
	win.size = Vector2i(56, 260)
	win.borderless = true
	win.always_on_top = true
	win.unresizable = true
	win.transient = false
	win.position = Vector2i(16, DisplayServer.screen_get_size().y - 276)
	
	# Root control to hold everything
	var root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(root)
	
	# Background panel
	var panel = Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.85)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)
	
	# Button container
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 8)
	root.add_child(vbox)
	
	# Pause/Resume button
	var pause_btn = _create_ctrl_button("pause", "Pause")
	pause_btn.pressed.connect(func():
		if pause_btn.icon_name == "pause":
			pause_btn.icon_name = "play"
			pause_session()
		else:
			pause_btn.icon_name = "pause"
			resume_session()
	)
	vbox.add_child(pause_btn)
	
	# Skip button
	var skip_btn = _create_ctrl_button("skip-next", "Skip")
	skip_btn.pressed.connect(skip_game)
	vbox.add_child(skip_btn)
	
	# Restart button
	var restart_btn = _create_ctrl_button("restart", "Restart")
	restart_btn.pressed.connect(restart_game)
	vbox.add_child(restart_btn)
	
	# Remove button
	var remove_btn = _create_ctrl_button("shuffle-variant", "Reroll")
	remove_btn.pressed.connect(remove_game)
	vbox.add_child(remove_btn)
	
	# Stop button
	var stop_btn = _create_ctrl_button("stop", "Stop")
	stop_btn.pressed.connect(stop_session)
	vbox.add_child(stop_btn)
	
	get_tree().root.add_child(win)
	win.transient = false
	win.popup()
	
	_controls_window = win

func _create_ctrl_button(icon: String, tooltip: String) -> M3IconButton:
	var btn = M3IconButton.new()
	btn.icon_name = icon
	btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
	btn.icon_button_size = M3IconButton.IconSize.SMALL
	btn.tooltip_text = tooltip
	return btn

# ============================================================================
# CLEANUP
# ============================================================================

func _cleanup_temp_files() -> void:
	if DirAccess.dir_exists_absolute(TEMP_DIR):
		FSM.delete_dir_recursive(TEMP_DIR)
