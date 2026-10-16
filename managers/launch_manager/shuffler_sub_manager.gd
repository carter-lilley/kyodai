extends Manager
class_name ShufflerSubManager

## Manages shuffler sessions: bag building, game switching, process control.

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const ShufflerInputWindowScene = preload("res://components/shuffler/shuffler_input_window.gd")

# Gate per-download / per-preparation logging: these fire in bursts while
# the session intro plays, and building _format_bag()/_format_entry() strings
# for every completion hitches the intro animation. Lifecycle logs
# (start/stop/switch) stay unconditional.
const DEBUG_LOG: bool = false

enum State { IDLE, DOWNLOADING, ACTIVE, PAUSED, STOPPING, CHOOSING }
enum WindowBackend { NONE, WINDOWS_AHK, LINUX_KWIN, LINUX_X11 }

signal session_started()
signal session_stopped()
signal game_switched(game_title: String, platform_name: String)
signal timer_updated(time_left: float)
signal download_progress(current: int, total: int)
signal game_ready(index: int)

var _state: State = State.IDLE
# Session start now awaits the bag sample on the DB worker thread; _starting
# holds the double-start guard across that await (state is still IDLE there),
# and _start_cancelled lets stop_session abort a start still in flight.
var _starting: bool = false
var _start_cancelled: bool = false
var _switch_in_progress: bool = false
var _restart_in_progress: bool = false  # extra guard: reject restarts queued while one is running
var _pending_switch_index: int = -1  # latest requested target while a switch is in flight
var _bag: ShufflerBag = ShufflerBag.new()
var _current_game_index: int = -1
var _round_timer: Timer = null
var _countdown_timer: Timer = null
var _config: Dictionary = {}
var _controls_window: Node = null
# Persistent invisible window that listens for the summon chord; joypad input
# only reaches MAPPED OS windows, and the palette is ephemeral.
var _input_window: Node = null

## Platforms with known shuffler lifecycle issues (pico8/win3x suspend
## problems); their shuffler dialog toggles default to off, but the user can
## still opt in per session.
const SHUFFLER_PLATFORM_DEFAULT_DISABLED: Array[String] = ["win3x", "pico8", "model2", "model3", "ps4"]

func is_platform_shuffle_default_disabled(slug: String) -> bool:
	return slug in SHUFFLER_PLATFORM_DEFAULT_DISABLED
# Cached reroll-button state, re-applied to each freshly summoned palette.
var _controls_reroll_enabled: bool = true
var _main_window: Window = null
var _total_downloads: int = 0
var _pending_downloads: int = 0
var _pending_preparations: int = 0
var _tools_dir: String = ""
var _ahk_path: String = ""
var _pssuspend_path: String = ""
var _qdbus_cmd: String = ""
var _x11_windowctl_path: String = ""
# Max time to wait for pssuspend to confirm a process is frozen before
# launching the next emulator instance (defensive: a wedged pssuspend must
# not stall switching forever).
const SUSPEND_AWAIT_TIMEOUT_SEC := 2.0
# Max time to verify every process-group member reached stopped state after
# SIGSTOP. Generous on purpose: a member briefly stuck in uninterruptible I/O
# (shader cache writes) must not false-positive into a hard kill.
const SUSPEND_VERIFY_TIMEOUT_SEC := 2.0
# Max time to wait for minimize_window.ahk before suspending. AHK must finish
# its window messages before pssuspend freezes the emulator, otherwise the
# script wedges on a synchronous send to a suspended UI thread.
const HIDE_AWAIT_TIMEOUT_SEC := 2.0
# Max time to wait for a udp/tcp quit command to actually terminate the
# emulator before falling back to a hard kill.
const QUIT_CONFIRM_TIMEOUT_SEC := 5.0

var _reroll_in_progress: bool = false
# Entry being refilled by a reroll ({} = none). The refill runs in the
# background; completion is detected in _prepare_entry/_fail_entry outcomes.
# Tracked by entry identity (not slot number): pick-3 rejections remove bag
# entries and renumber slots while the refill is still in flight, and a stale
# slot number would never match again - leaving the re-shuffle button stuck
# disabled for the rest of the session.
var _reroll_entry: Dictionary = {}
# Slot _reroll_entry currently occupies (-1 = none); informational only,
# always re-derived from _reroll_entry before use.
var _reroll_slot_index: int = -1
const MAX_CANDIDATE_RETRIES := 3
var _shuffle_overrides: Dictionary = {}  # platform_slug -> {"emulator_id": String, "core_id": String}
var _shuffle_session_active: bool = false

# The session's first download gets the standard (unsuppressed) download
# notification labeled "Preparing Shuffle"; later downloads stay silent.
var _first_download_notification_shown: bool = false
var _session_log_path: String = "user://logs/session.log"
var _session_log_start_offset: int = -1
var _download_item_ids: Array[String] = []
var _shuffler_vita_apps: Array[Dictionary] = []
var _shuffler_ps3_games: Array[Dictionary] = []
var _maximize_token: int = 0  # incremented whenever the foreground game changes; in-flight maximize coroutines check it and bail
var _window_backend: int = WindowBackend.NONE

# Balatro-style "choose 1 of 3" interstitial. Every 3-5 completed shuffles the
# current game closes and the player picks one seen game to keep; the rejected
# games are removed from the bag.
const CHOICE_SCENE := "res://components/shuffler/shuffler_choice_window.tscn"
const INTRO_SCENE := "res://components/shuffler/shuffler_intro_window.tscn"
const CHOICE_MIN_CANDIDATES := 3
const CHOICE_MIN_SHUFFLES := 3
const CHOICE_MAX_SHUFFLES := 5
var _games_until_choice: int = -1
# Armed by _switch_to_next_game when it dispatches a shuffle; the matching
# decrement lands in _switch_to_game only once the switch actually commits,
# so a choice offer or an aborted dispatch can't drain the countdown.
var _debit_choice_on_commit := false
var _seen_entries: Array = []  # bag entries that have been the current game
var _choice_window: Node = null
var _intro_window: Node = null
# Prewarmed at session start so the first intro doesn't pay the scene load
# cost mid-animation.
var _intro_scene: PackedScene = null

const TEMP_DIR := "user://temp/shuffler/"

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
	if SystemManager.platform.is_windows():
		_window_backend = WindowBackend.WINDOWS_AHK
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
	elif OS.get_name() == "Linux" or OS.get_name().ends_with("BSD"):
		_initialize_linux_window_backend()


func _initialize_linux_window_backend() -> void:
	print("[ShufflerSubManager] window backend detect: gamemode=", SystemManager.platform.is_gamemode(),
		" XDG_CURRENT_DESKTOP=", OS.get_environment("XDG_CURRENT_DESKTOP"),
		" XDG_SESSION_DESKTOP=", OS.get_environment("XDG_SESSION_DESKTOP"),
		" XDG_SESSION_TYPE=", OS.get_environment("XDG_SESSION_TYPE"),
		" DESKTOP_SESSION=", OS.get_environment("DESKTOP_SESSION"),
		" WAYLAND_DISPLAY=", OS.get_environment("WAYLAND_DISPLAY"),
		" DISPLAY=", OS.get_environment("DISPLAY"))
	# Game Mode (gamescope) is the session compositor; the desktop env vars do
	# not describe a usable WM, but apps still get X11 via XWayland, so the X11
	# helper (with unmap/map instead of EWMH hints) is the only working backend.
	if SystemManager.platform.is_gamemode():
		_x11_windowctl_path = _resolve_x11_windowctl_path()
		if _x11_windowctl_path != "" and FileAccess.file_exists(_x11_windowctl_path):
			_window_backend = WindowBackend.LINUX_X11
			if DEBUG_LOG: print("[ShufflerSubManager] Linux window backend: X11 helper, GameMode (" + _x11_windowctl_path + ")")
		else:
			_window_backend = WindowBackend.NONE
			push_warning("[ShufflerSubManager] GameMode session but no X11 helper; shuffler window switching will be unavailable")
		return

	var desktop := (OS.get_environment("XDG_CURRENT_DESKTOP") + ";" + OS.get_environment("XDG_SESSION_DESKTOP")).to_lower()
	var session_type := OS.get_environment("XDG_SESSION_TYPE").to_lower()

	# Prefer KDE KWin scripting on KDE sessions (works on both X11 and Wayland).
	if desktop.contains("kde"):
		_qdbus_cmd = _find_qdbus()
		if _qdbus_cmd != "":
			_window_backend = WindowBackend.LINUX_KWIN
			if DEBUG_LOG: print("[ShufflerSubManager] Linux window backend: KDE KWin scripting (" + _qdbus_cmd + ")")
			return
		else:
			push_warning("[ShufflerSubManager] KDE session detected but qdbus/qdbus6 not found; falling back to X11")

	# Fallback to X11 helper if we have an X session.
	if session_type == "x11" or (OS.get_environment("DISPLAY") != "" and OS.get_environment("WAYLAND_DISPLAY") == ""):
		_x11_windowctl_path = _resolve_x11_windowctl_path()
		if _x11_windowctl_path != "" and FileAccess.file_exists(_x11_windowctl_path):
			_window_backend = WindowBackend.LINUX_X11
			if DEBUG_LOG: print("[ShufflerSubManager] Linux window backend: X11 helper (" + _x11_windowctl_path + ")")
			return

	_window_backend = WindowBackend.NONE
	push_warning("[ShufflerSubManager] No supported Linux window backend available; shuffler window switching will be unavailable")


func _find_qdbus() -> String:
	for cmd in ["qdbus6", "qdbus-qt6", "qdbus"]:
		if OS.execute("which", [cmd], [], true) == 0:
			return cmd
	return ""


func _resolve_x11_windowctl_path() -> String:
	if SystemManager.platform.is_packaged():
		return AndroidBinaryExtractor.extract_binary("res://bin/linux/x11_windowctl", "x11_windowctl")
	return ProjectSettings.globalize_path("res://bin/linux/x11_windowctl")

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
	if DEBUG_LOG: print("[ShufflerSubManager] Session log capture started at offset " + str(offset))

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
	if DEBUG_LOG: print("[ShufflerSubManager] Session log saved: " + output_path)

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
	if _state != State.IDLE or _starting:
		push_error("[ShufflerSubManager] Already in a session")
		return

	if not SystemManager.platform.is_windows() and not (OS.get_name() == "Linux" or OS.get_name().ends_with("BSD")):
		push_error("[ShufflerSubManager] Shuffler is only available on Windows and Linux/BSD")
		return

	var platforms = config.get("platforms", [])
	var bag_size = config.get("bag_size", 10)
	var filters: Dictionary = config.get("filters", {})
	# Platform balance as a 0-1 fraction (slider percent / 100): 0 = pure
	# proportional sampling, 1 = equal shares per platform.
	var platform_balance: float = clampf(float(config.get("platform_balance", 50)) / 100.0, 0.0, 1.0)

	if platforms.is_empty():
		push_error("[ShufflerSubManager] No platforms selected for shuffler")
		return

	# Prewarm one-shot intro assets on the click frame so the first intro
	# doesn't pay scene/font load costs while its animation runs.
	_prewarm_intro_assets()

	# _starting holds the double-start guard across the await below: state is
	# still IDLE until the sample lands, so the plain _state check can't reject
	# a second start in that window.
	_starting = true
	var fetch_start := Time.get_ticks_msec()
	var sampled: Array[GameResource] = await DataManager.get_random_games_for_shuffle_balanced_async(platforms, filters, bag_size, platform_balance)
	print("[ShufflerSubManager] Sampled " + str(sampled.size()) + " bag games in " + str(Time.get_ticks_msec() - fetch_start) + " ms")
	if _start_cancelled:
		_start_cancelled = false
		_starting = false
		return

	_bag = ShufflerBag.new()
	_bag.build(sampled, bag_size)

	if _bag.is_empty():
		push_error("[ShufflerSubManager] No games found for selected platforms")
		_starting = false
		return

	_state = State.DOWNLOADING
	_starting = false
	_config = config
	_current_game_index = -1
	_switch_in_progress = false
	_pending_switch_index = -1
	_reset_download_tracking()
	_shuffler_vita_apps.clear()
	_shuffler_ps3_games.clear()
	_games_until_choice = randi_range(CHOICE_MIN_SHUFFLES, CHOICE_MAX_SHUFFLES)
	_debit_choice_on_commit = false
	_seen_entries.clear()

	# Cut background music for the whole session (resumed in stop_session);
	# per-game exit signals must not resume it mid-session.
	SystemManager.audio.pause_background_music()

	print("[ShufflerSubManager] Starting session with bag size " + str(_bag.size()) + ": " + _format_bag())
	_start_bag_preparation()
	_build_candidates_background(platforms, filters, platform_balance)
	_await_first_ready()

func stop_session() -> void:
	if _state == State.IDLE or _state == State.STOPPING:
		if _starting:
			if DEBUG_LOG: print("[ShufflerSubManager] stop_session: session start still in flight; cancelling it")
			_start_cancelled = true
		else:
			if DEBUG_LOG: print("[ShufflerSubManager] stop_session called but state=" + str(_state) + ", ignoring")
		return

	print("[ShufflerSubManager] stop_session: state=" + str(_state) + " " + _format_bag())
	_state = State.STOPPING

	# Let any in-flight switch/restart finish so teardown doesn't interleave
	# with it (its coroutines re-check state and bail once STOPPING).
	var guard_wait := 0.0
	while _switch_in_progress and guard_wait < 3.0:
		await get_tree().create_timer(0.05).timeout
		guard_wait += 0.05
	if _switch_in_progress:
		push_warning("[ShufflerSubManager] stop_session: switch still in progress after 3s; tearing down anyway")

	_reroll_in_progress = false
	_reroll_entry = {}
	_reroll_slot_index = -1
	_restart_in_progress = false
	_pending_switch_index = -1
	_maximize_token += 1

	_kill_round_timer()

	for item_id in _download_item_ids:
		SystemManager.download.cancel(item_id)

	var kill_pids: Array[int] = []
	for entry in _bag.entries:
		if entry.pid != -1:
			_kill_entry_processes(entry)
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
		if DEBUG_LOG: print("[ShufflerSubManager] stop_session: process teardown took " + str(elapsed) + "s")

	_restore_emulator_file_if_backed_up("retroarch", _retroarch_shuffler_cfg_path())
	_restore_emulator_file_if_backed_up("pcsx2", PCSX2_SHUFFLER_INI_PATH)

	_cleanup_vita3k_shuffler_apps()
	_cleanup_rpcs3_shuffler_games()

	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.queue_free()
		_controls_window = null

	if _choice_window and is_instance_valid(_choice_window):
		_choice_window.queue_free()
		_choice_window = null

	if _intro_window and is_instance_valid(_intro_window):
		_intro_window.queue_free()
		_intro_window = null

	if _input_window and is_instance_valid(_input_window):
		_input_window.queue_free()
		_input_window = null

	get_tree().root.gui_disable_input = false

	# Restore the pre-session window mode from the "windowed" setting; the
	# session minimizes the main window, so blindly forcing WINDOWED here
	# would leave fullscreen users windowed until they retoggle the setting.
	var windowed_setting = SystemManager.display.settings_man.get_setting("windowed") if SystemManager.display else null
	if windowed_setting and not windowed_setting.value:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		if SystemManager.display:
			# Re-apply the borderless chrome before the size restore below.
			SystemManager.display.apply_window_chrome(true)
			var last_size: Vector2i = SystemManager.display.restore_last_window_size()
			if last_size == Vector2i.ZERO:
				var resolution_setting = SystemManager.display.settings_man.get_setting("resolution")
				if resolution_setting:
					var resolution_value = resolution_setting.value
					if resolution_value is int and resolution_setting.options.size() > resolution_value:
						resolution_value = resolution_setting.options[resolution_value]
					SystemManager.display.set_resolution(resolution_value)
				DisplayServer.window_set_position(Vector2i(Vector2(DisplayServer.screen_get_position()) + Vector2(DisplayServer.screen_get_size()) / 2.0 - Vector2(DisplayServer.window_get_size()) / 2.0))
	if SystemManager.display:
		# Notify the title bar chrome of the restored mode (fullscreen branch:
		# apply_window_chrome(false) only emits the inactive state).
		SystemManager.display.apply_window_chrome(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED)
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
	print("[ShufflerSubManager] pause_session")
	_state = State.PAUSED
	if _round_timer:
		_round_timer.paused = true

func resume_session() -> void:
	if not can_resume():
		print("[ShufflerSubManager] resume_session ignored: state=" + str(_state))
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
		if DEBUG_LOG: print("[ShufflerSubManager] skip_game ignored: state=" + str(_state))
		return
	print("[ShufflerSubManager] skip_game: current=" + str(_current_game_index) + " " + _format_bag())
	_kill_round_timer()
	_switch_to_next_game()

func restart_game() -> void:
	if not can_restart():
		if DEBUG_LOG: print("[ShufflerSubManager] restart_game ignored: state=" + str(_state))
		return
	if _restart_in_progress:
		# Input layers can deliver several requests per physical press
		# (double-registered pads, raw + mapped action events). A restart is
		# already tearing down and relaunching the game; a second one queued
		# on top would just kill the fresh instance and loop forever.
		if DEBUG_LOG: print("[ShufflerSubManager] restart_game ignored: restart already in progress")
		return
	_restart_in_progress = true
	print("[ShufflerSubManager] restart_game: current=" + str(_current_game_index))
	# Wait for any in-flight switch, then hold the guard so skip/timer
	# requests queue behind the restart instead of interleaving with it.
	while _switch_in_progress:
		await get_tree().process_frame
	# stop_session may have run while we waited; never touch the bag during
	# or after teardown.
	if not can_restart() or _current_game_index < 0 or _current_game_index >= _bag.size():
		if DEBUG_LOG: print("[ShufflerSubManager] restart_game aborted after wait: state=" + str(_state) + " current=" + str(_current_game_index))
		_restart_in_progress = false
		return
	_switch_in_progress = true
	_kill_round_timer()
	var entry = _bag.entries[_current_game_index]
	await _await_launch_settled(entry)
	await _stop_game(entry)
	if entry.pid != -1:
		# Restart boots a fresh instance; the old process (suspended for
		# suspend-method emulators, possibly still exiting for udp/tcp)
		# would otherwise be orphaned and untracked forever. Thorough kill:
		# plain group kill misses payloads that setsid'd out of the group.
		_kill_entry_processes(entry)
		await LaunchManager.process.confirm_process_dead_async(entry.pid, 3.0)
	entry.started = false
	entry.pid = -1
	entry.pgid = -1
	entry["window_xid"] = ""
	if _state != State.STOPPING and _state != State.IDLE:
		_launch_game(entry)
		# Start the round only once the relaunch has actually produced a
		# process (or is still in flight past the settle window). A failed
		# boot is recovered by the deferred skip in _launch_game's pid
		# callback instead of idling out a full round on a dead game.
		await _await_launch_settled(entry)
		if _state != State.STOPPING and _state != State.IDLE \
			and (entry.pid != -1 or entry.get("launch_pending", false)):
			_start_round_timer(_random_round_time())
	_switch_in_progress = false
	_restart_in_progress = false
	if _pending_switch_index != -1:
		var next = _pending_switch_index
		_pending_switch_index = -1
		_request_switch(next)

func remove_game() -> void:
	if not can_reroll():
		if DEBUG_LOG: print("[ShufflerSubManager] remove_game ignored: state=" + str(_state))
		return
	if _current_game_index < 0:
		if DEBUG_LOG: print("[ShufflerSubManager] remove_game ignored: no current game")
		return
	if _reroll_in_progress:
		if DEBUG_LOG: print("[ShufflerSubManager] remove_game ignored: reroll in progress")
		return

	_reroll_in_progress = true
	_set_controls_reroll_enabled(false)

	# Wait for any in-flight switch before mutating bag entries
	while _switch_in_progress:
		await get_tree().process_frame

	# stop_session may have run while we waited; never touch the bag during
	# or after teardown.
	if not can_reroll() or _current_game_index < 0 or _current_game_index >= _bag.size():
		if DEBUG_LOG: print("[ShufflerSubManager] remove_game aborted after wait: state=" + str(_state) + " current=" + str(_current_game_index))
		_reset_reroll_state()
		return

	# Hold the switch guard across the teardown so a skip or timer fire can't
	# start a concurrent switch while the current game is being stopped; kill
	# the round timer up front so it can't fire mid-suspend.
	_switch_in_progress = true
	_kill_round_timer()

	var index = _current_game_index
	var entry = _bag.entries[index]
	print("[ShufflerSubManager] Rerolling slot " + str(index) + " (" + entry.game.title + ")")

	await _await_launch_settled(entry)
	await _stop_game(entry)

	if not can_reroll():
		_reset_reroll_state()
		_switch_in_progress = false
		return

	if entry.pid != -1:
		# Thorough kill (groups + payload tree + window): plain group kill
		# misses payloads that setsid'd out of the launch group, leaking a
		# live game whose window then poisons hint-based matching.
		_kill_entry_processes(entry)
		await LaunchManager.process.confirm_process_dead_async(entry.pid)
		entry.pid = -1
		entry.pgid = -1
		entry.started = false
		entry.active = false
		entry["window_xid"] = ""

	# Replace the slot with a fresh candidate and refill it in the background
	# (download/prep completion is detected via _maybe_complete_reroll), then
	# immediately skip to another ready game instead of waiting for the refill.
	# The refill entry is registered BEFORE acquisition starts: a candidate
	# that is already on disk finishes synchronously, and a completion missed
	# before the state exists would strand the re-shuffle button disabled.
	var refill := await _swap_slot_for_candidate(entry)
	if refill.is_empty():
		push_warning("[ShufflerSubManager] No alternative game found for reroll")
		_reset_reroll_state()
	else:
		_reroll_entry = refill
		_reroll_slot_index = _live_index(refill)
		print("[ShufflerSubManager] Reroll refill started for slot " + str(_reroll_slot_index))
		_start_entry_acquisition(_reroll_slot_index)

	_switch_in_progress = false
	if _pending_switch_index != -1:
		# A skip landed during the teardown; honor it instead of picking anew.
		var next = _pending_switch_index
		_pending_switch_index = -1
		_request_switch(next)
	else:
		_switch_to_next_game()

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
	return "%s [%s] status=%s pid=%d pgid=%d started=%s" % [
		entry.game.title,
		entry.game.platform_slug,
		_status_name(entry.status),
		entry.pid,
		int(entry.get("pgid", -1)),
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

## Re-resolves an entry's current slot index. Deferred callbacks (download /
## disc / prep completions) capture their slot when they start, but pick-3
## rejections remove bag entries and renumber every higher slot before those
## callbacks fire, so a captured index can be stale - or past the end of the
## array. Returns -1 when the entry has left the bag entirely.
func _live_index(entry: Dictionary) -> int:
	if entry == null or entry.is_empty():
		return -1
	return _bag.entries.find(entry)

func _start_bag_preparation() -> void:
	_reset_download_tracking()
	print("[ShufflerSubManager] _start_bag_preparation: " + _format_bag())

	for i in range(_bag.entries.size()):
		if DEBUG_LOG: print("[ShufflerSubManager] _start_bag_preparation entry " + str(i) + ": " + _format_entry(_bag.entries[i]))
		_start_entry_acquisition(i)

## Starts acquiring one bag entry (local path, disc downloads, or full download).
## Shared by initial bag fill and candidate-retry refills; runs in the
## background for rerolls. Failure paths replace the slot via
## _try_replace_with_candidate (bounded by MAX_CANDIDATE_RETRIES).
func _start_entry_acquisition(index: int) -> void:
	var entry = _bag.entries[index]
	var game = entry.game
	var library_m3u := _get_library_m3u(game)
	if library_m3u != "":
		entry.temp_path = library_m3u
		_prepare_entry(entry)
	elif _is_multi_disc_m3u(game):
		# Multi-disc m3u game with an incomplete set: temp-download the
		# missing discs and shuffle through a temp m3u playlist
		var missing_count := 0
		for e in game.get_disc_entries():
			if not e["downloaded"]:
				missing_count += 1
		_total_downloads += missing_count
		_pending_downloads += missing_count
		entry.status = ShufflerBag.EntryStatus.DOWNLOADING
		_download_discs_to_temp(game,
			func(_success: bool):
				_pending_downloads -= 1
				download_progress.emit(_total_downloads - _pending_downloads, _total_downloads)
				_check_all_preparations_complete(),
			func(m3u_path: String):
				if m3u_path == "":
					if not await _try_replace_with_candidate(entry):
						_fail_entry(entry, "[ShufflerSubManager] Disc download failed for " + game.title)
					_check_all_preparations_complete()
					return
				# The pick-3 screen can drop entries (renumbering slots) while
				# this disc set downloads; only write back if we still have a slot.
				if _live_index(entry) == -1:
					if DEBUG_LOG: print("[ShufflerSubManager] Disc-set slot for " + game.title + " left the bag; discarding temp m3u")
					_maybe_complete_reroll(entry)
					_check_all_preparations_complete()
					return
				entry.temp_path = m3u_path
				_prepare_entry(entry)
		)
	elif game.is_active_variant_downloaded() and FileAccess.file_exists(game.file_path):
		entry.temp_path = game.file_path
		_prepare_entry(entry)
	else:
		_total_downloads += 1
		_pending_downloads += 1
		_download_entry(entry)

## Fills the bag's reroll candidate pool in the background after session
## start: a single SQL-side random sample capped relative to the bag, so the
## whole platform library is never materialized as GameResources (the old
## per-platform fetch built one per row). Uses the same platform_balance
## weighting as the initial bag, so mid-session rerolls keep the session's
## platform distribution. Abandons silently if the session ends or the bag
## is replaced mid-build.
func _build_candidates_background(platforms: Array[String], filters: Dictionary, platform_balance: float) -> void:
	var bag := _bag
	bag.candidates_building = true
	var build_start := Time.get_ticks_msec()
	var pool: Array[GameResource] = await DataManager.get_random_games_for_shuffle_balanced_async(platforms, filters, bag.size() * 10, platform_balance)
	if _bag != bag or _state == State.IDLE:
		bag.candidates_building = false
		return
	# The random sample can overlap games already in the bag; drop those.
	var seen: Dictionary = {}
	for id in bag.get_bag_ids():
		seen[id] = true
	var candidates: Array[GameResource] = []
	for game in pool:
		if not seen.has(game.romm_id):
			candidates.append(game)
	bag.candidates = candidates
	bag.candidates_building = false
	bag.candidates_built = true
	print("[ShufflerSubManager] Candidate pool built: " + str(candidates.size()) + " games in " + str(Time.get_ticks_msec() - build_start) + " ms")

## Swaps a bag slot for a fresh candidate WITHOUT starting acquisition.
## Returns the new entry ({} when nothing was swapped: out of candidates or
## out of retry attempts for this entry). Entry-based rather than index-based:
## the slot is re-resolved after the candidate-pool wait, so pick-3 removals
## that renumber slots can't redirect the swap onto a healthy entry.
func _swap_slot_for_candidate(entry: Dictionary) -> Dictionary:
	var index := _live_index(entry)
	if index == -1:
		return {}
	var attempts: int = entry.get("retry_count", 0)
	if attempts >= MAX_CANDIDATE_RETRIES:
		return {}
	# The candidate pool fills in the background at session start; a failure
	# or reroll landing before that waits rather than failing outright.
	while _bag.candidates_building and _state != State.IDLE and _state != State.STOPPING:
		await get_tree().process_frame
	if _state == State.IDLE or _state == State.STOPPING:
		return {}
	# Re-resolve after the wait: entries removed above us shift every slot.
	index = _live_index(entry)
	if index == -1:
		return {}
	var candidate = _bag.pick_reroll_candidate(_bag.get_bag_ids())
	if candidate == null:
		return {}
	print("[ShufflerSubManager] Replacing slot " + str(index) + " with candidate " + candidate.title + " (attempt " + str(attempts + 1) + "/" + str(MAX_CANDIDATE_RETRIES) + ")")
	_bag.replace_entry(index, candidate, "")
	_bag.entries[index]["retry_count"] = attempts + 1
	return _bag.entries[index]

## Replaces a failed/refilling bag slot with a fresh candidate and starts
## acquiring it in the background. Returns false when out of candidates or
## out of retry attempts for this entry.
func _try_replace_with_candidate(entry: Dictionary) -> bool:
	var replacement := await _swap_slot_for_candidate(entry)
	if replacement.is_empty():
		return false
	# No await between the swap and here, so the fresh entry's slot is still
	# valid - acquisition can then run (and even complete synchronously for a
	# locally-present candidate) while callers do their own bookkeeping.
	var index := _live_index(replacement)
	if index == -1:
		return false
	_start_entry_acquisition(index)
	return true

## Marks an entry FAILED (retry exhausted) and completes a reroll if it was
## the refill being awaited. Safe with stale entries: a slot removed while
## this was queued is skipped (but still frees the reroll button if it was
## the refill).
func _fail_entry(entry: Dictionary, reason: String) -> void:
	var index := _live_index(entry)
	if index == -1:
		if DEBUG_LOG: print("[ShufflerSubManager] _fail_entry: entry left the bag, skipping: " + reason)
		_maybe_complete_reroll(entry)
		return
	_bag.entries[index].status = ShufflerBag.EntryStatus.FAILED
	push_error(reason)
	_maybe_complete_reroll(entry)

## Completes an in-flight reroll when the refill entry it is waiting on turns
## READY or FAILED. Matched by entry identity, not slot number: pick-3
## rejections renumber slots while the refill downloads, and a stale slot
## number would never match again (stranding the re-shuffle button). If the
## refill entry left the bag entirely, the reroll can never complete, so the
## state is freed instead.
func _maybe_complete_reroll(entry: Dictionary) -> void:
	if _reroll_entry.is_empty() or entry != _reroll_entry:
		return
	var live := _live_index(entry)
	if live == -1:
		if DEBUG_LOG: print("[ShufflerSubManager] Reroll refill entry left the bag; resetting reroll state")
		_reset_reroll_state()
		return
	_reroll_slot_index = live
	_reroll_entry = {}
	_complete_reroll_background(live)

func _complete_reroll_background(index: int) -> void:
	_reset_reroll_state()
	# Fill-switches must serialize with user switches: wait for any in-flight
	# switch, then re-check everything (that switch may have moved the session
	# to another game or torn it down while we waited).
	while _switch_in_progress:
		await get_tree().process_frame
	if _state != State.ACTIVE and _state != State.PAUSED:
		return
	# Fill-switch: if the immediate skip found no other ready game, this slot
	# is still "current" with nothing running - launch the refilled game now.
	if _current_game_index != index or index < 0 or index >= _bag.size():
		return
	var entry = _bag.entries[index]
	if entry.status != ShufflerBag.EntryStatus.READY or entry.pid != -1:
		return
	_switch_in_progress = true
	await _switch_to_game(index)
	_switch_in_progress = false
	if _pending_switch_index != -1:
		var next = _pending_switch_index
		_pending_switch_index = -1
		_request_switch(next)

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
	var is_mid_session := _state == State.ACTIVE or _state == State.PAUSED
	SystemManager.download.queue_disc_files(game, missing, temp_dir, false, true,
		func(_entry: Dictionary, success: bool):
			if on_one_done.is_valid():
				on_one_done.call(success),
		func(success: bool):
			if not success:
				on_done.call("")
				return
			on_done.call(_write_temp_m3u(game, temp_dir)),
		is_mid_session
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

func _download_entry(entry: Dictionary) -> void:
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

	var callbacks = {
		"on_complete": func(success: bool, _path: String):
			var completed = _total_downloads - _pending_downloads
			download_progress.emit(completed, _total_downloads)
			_pending_downloads -= 1
			if DEBUG_LOG:
				if DEBUG_LOG: print("[ShufflerSubManager] Download callback for " + game.title + ": success=" + str(success) + " pending_downloads=" + str(_pending_downloads))
			# Resolved through the entry, never through a captured slot number:
			# pick-3 rejections can remove entries (renumbering slots) while
			# this download is in flight, which is exactly when the old
			# `_bag.entries[index]` crashed with an out-of-bounds get.
			if success:
				_prepare_entry(entry)
			else:
				if not await _try_replace_with_candidate(entry):
					_fail_entry(entry, "[ShufflerSubManager] Download failed for " + game.title)
			_check_all_preparations_complete()
	}

	if DEBUG_LOG:
		print("[ShufflerSubManager] Queueing download for " + game.title + " to " + temp_path)

	# The session's first download shows the standard download notification
	# (the same moving MB progress a main-UI download gets) labeled "Preparing
	# Shuffle" so the user can tell the session is about to start; all later
	# downloads stay silent.
	var is_first_download := not _first_download_notification_shown
	_first_download_notification_shown = true

	# All shuffler-session downloads stay silent: no download loop SFX, whether
	# it's the initial prep batch or a mid-session reroll/replacement refill.
	# The first download still shows the "Preparing Shuffle" notification.
	var item_id = SystemManager.download.queue_download(
		download_url,
		temp_path,
		"game",
		"Preparing Shuffle" if is_first_download else "",
		false,
		"",
		game,
		callbacks,
		game.romm_id,
		true,
		not is_first_download,
		file_size,
		false,
		true
	)

	if item_id != "":
		_download_item_ids.append(item_id)
		entry.download_id = item_id
	else:
		_pending_downloads -= 1
		if not await _try_replace_with_candidate(entry):
			_fail_entry(entry, "[ShufflerSubManager] Failed to queue download for " + game.title)
		_check_all_preparations_complete()

func _prepare_entry(entry: Dictionary) -> void:
	if entry.status == ShufflerBag.EntryStatus.READY or entry.status == ShufflerBag.EntryStatus.FAILED:
		return

	# Resolve the slot from the entry itself: the caller's index may already
	# be stale (pick-3 rejections remove entries and renumber slots while
	# downloads are still in flight).
	var index := _live_index(entry)
	if index == -1:
		if DEBUG_LOG: print("[ShufflerSubManager] _prepare_entry: " + _format_entry(entry) + " is no longer in the bag; skipping")
		_maybe_complete_reroll(entry)
		_check_all_preparations_complete()
		return

	_pending_preparations += 1
	entry.status = ShufflerBag.EntryStatus.PREPARING
	var game = entry.game
	var emulator_id = LaunchManager.resolve_emulator_for_game(game)
	if DEBUG_LOG:
		if DEBUG_LOG: print("[ShufflerSubManager] Preparing entry " + str(index) + ": " + _format_entry(entry) + " emulator=" + emulator_id)

	# Only emulators whose launch can require prep (archive extraction /
	# title-id-based launch paths) go through preparation. Xenia-family
	# emulators are included for XBLA archives, which must be extracted
	# before any xenia-based emulator can launch them.
	var prep_architecture = LaunchManager.registry.get_emulator_architecture(emulator_id)
	if emulator_id == "" or not (emulator_id.begins_with("vita3k") or prep_architecture in ["rpcs3", "xenia"]):
		entry.status = ShufflerBag.EntryStatus.READY
		_pending_preparations -= 1
		if DEBUG_LOG:
			if DEBUG_LOG: print("[ShufflerSubManager] Ready (no prep needed): " + game.title)
		game_ready.emit(index)
		_maybe_complete_reroll(entry)
		return

	if entry.temp_path == "":
		push_warning("[ShufflerSubManager] Skipping preparation for " + game.title + " - no temp_path")
		_pending_preparations -= 1
		if not await _try_replace_with_candidate(entry):
			_fail_entry(entry, "[ShufflerSubManager] Skipping preparation for " + game.title + " - no temp_path")
		return

	var prep_success = await LaunchManager.prepare_game_for_shuffler(game, emulator_id, entry.temp_path)
	# Prep is a long await: the pick-3 screen can remove entries and renumber
	# slots while it runs. Re-resolve before touching bag bookkeeping.
	index = _live_index(entry)
	if index == -1:
		if DEBUG_LOG: print("[ShufflerSubManager] _prepare_entry: " + _format_entry(entry) + " left the bag during prep; discarding result")
		_pending_preparations -= 1
		_maybe_complete_reroll(entry)
		_check_all_preparations_complete()
		return
	if prep_success:
		var prepared_path = LaunchManager.get_last_prepared_rom_path(game)
		if prepared_path != "":
			entry.temp_path = prepared_path
		entry.status = ShufflerBag.EntryStatus.READY
		_pending_preparations -= 1
		if DEBUG_LOG:
			if DEBUG_LOG: print("[ShufflerSubManager] Ready after prep: " + game.title)
		game_ready.emit(index)
		_maybe_complete_reroll(entry)
	else:
		push_error("[ShufflerSubManager] Failed to prepare " + game.title + " for shuffler session")
		_pending_preparations -= 1
		if not await _try_replace_with_candidate(entry):
			_fail_entry(entry, "[ShufflerSubManager] Failed to prepare " + game.title + " for shuffler session")

	if DEBUG_LOG:
		if DEBUG_LOG: print("[ShufflerSubManager] _prepare_entry done for " + str(index) + ": " + _format_entry(entry))
	_check_all_preparations_complete()

func _check_all_preparations_complete() -> void:
	if DEBUG_LOG:
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
		if DEBUG_LOG: print("[ShufflerSubManager] game_ready signal received for index " + str(index) + " while state=" + str(_state))
		if _state == State.DOWNLOADING:
			_enter_shuffler_mode()
	game_ready.connect(cb, CONNECT_ONE_SHOT)

func _random_round_time() -> float:
	return randf_range(
		_config.get("round_time_min", 40.0),
		_config.get("round_time_max", 130.0)
	)

func _reset_reroll_state() -> void:
	if DEBUG_LOG: print("[ShufflerSubManager] _reset_reroll_state")
	_reroll_in_progress = false
	_reroll_entry = {}
	_reroll_slot_index = -1
	_set_controls_reroll_enabled(true)

func _set_controls_reroll_enabled(enabled: bool) -> void:
	_controls_reroll_enabled = enabled
	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.set_reroll_enabled(enabled)

## The shuffler force-raises the emulator window on launch/skip/restart, which
## buries the controls panel. Reassert the panel's stacking whenever that
## happens so it stays reachable with LT+Select.
func _ensure_controls_on_top() -> void:
	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.ensure_on_top()

# ============================================================================
# DOWNLOAD PROGRESS
# ============================================================================

func _reset_download_tracking() -> void:
	_pending_downloads = 0
	_total_downloads = 0
	_pending_preparations = 0
	_download_item_ids.clear()
	_first_download_notification_shown = false

# ============================================================================
# SHUFFLER MODE
# ============================================================================

func _enter_shuffler_mode() -> void:
	if _state != State.DOWNLOADING:
		print("[ShufflerSubManager] _enter_shuffler_mode ignored: state=" + str(_state))
		return
	_state = State.ACTIVE
	_shuffle_session_active = true
	_start_session_log_capture()
	print("[ShufflerSubManager] _enter_shuffler_mode: " + _format_bag())

	if SystemManager.display:
		SystemManager.display.save_last_window_size()

	_hide_main_window()
	_create_input_window()

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

## Minimizing directly from EXCLUSIVE_FULLSCREEN is unreliable on Windows (the
## transition can bounce back to visible), so drop to windowed first, then
## minimize, and re-issue once if the mode didn't stick. stop_session()
## restores the real mode from the "windowed" setting.
func _hide_main_window() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		await get_tree().process_frame
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	await get_tree().create_timer(0.5).timeout
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED:
		if DEBUG_LOG: print("[ShufflerSubManager] main window minimize did not stick; retrying")
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)

func _apply_emulator_configs() -> void:
	var needs_retroarch := false
	var needs_pcsx2 := false
	for entry in _bag.entries:
		var emulator_id := LaunchManager.resolve_emulator_for_game(entry.game) as String
		if emulator_id == "retroarch":
			needs_retroarch = true
		elif emulator_id == "pcsx2":
			needs_pcsx2 = true
	if DEBUG_LOG: print("[ShufflerSubManager] _apply_emulator_configs: needs_retroarch=" + str(needs_retroarch) + " needs_pcsx2=" + str(needs_pcsx2))
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
		if DEBUG_LOG: print("[ShufflerSubManager] No other ready game; extending current round")
		_start_round_timer(_random_round_time())
		return
	# A real shuffle is about to happen: arm the choice debit, which lands in
	# _switch_to_game only once the switch actually commits — a choice offer
	# or an aborted dispatch must not consume a shuffle that never ran.
	if _games_until_choice == 0:
		var pool := _choice_pool()
		if pool.size() >= CHOICE_MIN_CANDIDATES:
			_offer_choice(pool)
			return
		# Not enough seen games to offer a choice (tiny bag); postpone.
		_games_until_choice = randi_range(CHOICE_MIN_SHUFFLES, CHOICE_MAX_SHUFFLES)
	_debit_choice_on_commit = true
	_request_switch(next_index)

func _choice_pool() -> Array:
	"""Seen, launch-ready entries that are still in the bag, in random order."""
	var pool: Array = []
	for entry in _seen_entries:
		if _bag.entries.has(entry) and entry.status == ShufflerBag.EntryStatus.READY:
			pool.append(entry)
	pool.shuffle()
	return pool

func _offer_choice(pool: Array) -> void:
	print("[ShufflerSubManager] _offer_choice: pool=" + str(pool.size()) + " current=" + str(_current_game_index))
	_state = State.CHOOSING
	# Any armed-but-unpaid debit belongs to a dispatch this choice supersedes;
	# the countdown restarts fresh when the choice resolves.
	_debit_choice_on_commit = false
	_kill_round_timer()
	var prev_entry = null
	if _current_game_index >= 0 and _current_game_index < _bag.size():
		prev_entry = _bag.entries[_current_game_index]
		await _await_launch_settled(prev_entry)
		prev_entry.active = false
		await _stop_game(prev_entry)
	# stop_session may have raced the stop await; never show the picker during
	# or after teardown.
	if _state != State.CHOOSING:
		print("[ShufflerSubManager] _offer_choice aborted: state=" + str(_state))
		return
	# Readiness can change while the previous game was stopping (a pooled
	# entry's download/prep can fail mid-trigger); only present entries that
	# are still ready and still in the bag.
	var candidates: Array = []
	for entry in pool:
		if _bag.entries.has(entry) and entry.status == ShufflerBag.EntryStatus.READY:
			candidates.append(entry)
			if candidates.size() >= CHOICE_MIN_CANDIDATES:
				break
	if candidates.size() < CHOICE_MIN_CANDIDATES:
		_games_until_choice = randi_range(CHOICE_MIN_SHUFFLES, CHOICE_MAX_SHUFFLES)
		_state = State.ACTIVE
		_switch_to_next_game()
		return
	# The controls panel must not float above the choice screen.
	if _controls_window and is_instance_valid(_controls_window) and _controls_window.has_method("hide_controls"):
		_controls_window.hide_controls()
	var scene := load(CHOICE_SCENE)
	if not scene:
		push_error("[ShufflerSubManager] Failed to load choice window scene: " + CHOICE_SCENE)
		_games_until_choice = randi_range(CHOICE_MIN_SHUFFLES, CHOICE_MAX_SHUFFLES)
		_state = State.ACTIVE
		_switch_to_next_game()
		return
	# Pooled for the session like the intro window: one OS window, re-presented
	# per pick (present() resets all card state for reuse).
	if not (_choice_window and is_instance_valid(_choice_window)):
		_choice_window = scene.instantiate()
		_choice_window.game_chosen.connect(_on_game_chosen)
		get_tree().root.add_child(_choice_window)
	_choice_window.present(candidates)

func _on_game_chosen(chosen: Dictionary, candidates: Array) -> void:
	print("[ShufflerSubManager] _on_game_chosen: " + _format_entry(chosen))
	# Snapshot the entry the (stopped) current index points at; removals below
	# can shift indexes or remove it entirely.
	var prev_entry = null
	if _current_game_index >= 0 and _current_game_index < _bag.size():
		prev_entry = _bag.entries[_current_game_index]
	# Rejected games leave the bag (and the seen pool) for good. Their slots
	# are refilled with fresh candidates so the bag stays at full size.
	# Tracked as entries, not slot numbers: replacements resolve their own
	# slot, and removals below renumber every higher slot - captured indexes
	# would be stale the moment an earlier slot collapsed.
	var rejected_entries: Array[Dictionary] = []
	for entry in candidates:
		if entry == chosen:
			continue
		_seen_entries.erase(entry)
		var idx := _bag.entries.find(entry)
		if idx != -1:
			rejected_entries.append(entry)
			# Suspend-method games keep a frozen process with a live pid when
			# stopped; kill it before the slot is replaced/dropped so it can't
			# leak (the reroll flow does the same). The replacement reuses
			# this slot's download/temp paths, so wait for the process to
			# actually die — it could otherwise hold files open mid-replace.
			if entry.pid != -1:
				_kill_entry_processes(entry)
				await LaunchManager.process.confirm_process_dead_async(entry.pid, 3.0)
				entry.started = false
				entry.active = false
				entry.pid = -1
				entry.pgid = -1
				entry["window_xid"] = ""
	# The pooled window already hid itself in _on_card_pressed; keep it alive
	# for the next pick (stop_session frees it).
	if _choice_window and is_instance_valid(_choice_window):
		_choice_window.hide()
	_games_until_choice = randi_range(CHOICE_MIN_SHUFFLES, CHOICE_MAX_SHUFFLES)
	if _state != State.CHOOSING:
		return
	_state = State.ACTIVE
	for rejected in rejected_entries:
		if not await _try_replace_with_candidate(rejected):
			# Candidate pool exhausted for this entry: collapse the slot.
			var drop_idx := _bag.entries.find(rejected)
			if drop_idx != -1:
				_bag.entries.remove_at(drop_idx)
	# Re-find after mutations: removals can shift every index.
	if prev_entry != null:
		_current_game_index = _bag.entries.find(prev_entry)
	var target := _bag.entries.find(chosen)
	if target == -1:
		# Should never happen; resume the normal flow defensively.
		_switch_to_next_game()
		return
	_request_switch(target)

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
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game: invalid index " + str(index))
		return
	if _current_game_index >= 0 and _current_game_index < _bag.size():
		var prev = _bag.entries[_current_game_index]
		prev.active = false
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game stopping previous: " + _format_entry(prev))
		await _stop_game(prev)

	# stop_session may have raced the stop await: never launch during teardown
	if _state == State.STOPPING or _state == State.IDLE:
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game aborted: state=" + str(_state))
		return

	_current_game_index = index
	_maximize_token += 1
	var entry = _bag.entries[index]
	entry.active = true
	if not _seen_entries.has(entry):
		_seen_entries.append(entry)
		_show_intro(entry.game)

	var method := entry.suspend_method as String
	if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game: target=" + _format_entry(entry) + " method=" + method)
	await _await_launch_settled(entry)
	# Resolve the live process behind the entry instead of trusting the
	# launch-time pid: an escaped payload (new process group, reaped leader)
	# used to read as "dead" here, which relaunched a fresh instance ON TOP of
	# the still-running suspended one and erased all tracking of it.
	var alive_target := {"pid": -1, "pgid": -1}
	if entry.started and entry.pid != -1:
		if SystemManager.platform.is_linux():
			alive_target = _resolve_entry_target(entry)
		elif await _is_process_running_async(entry.pid):
			alive_target = {"pid": entry.pid, "pgid": -1}
	if method == "suspend" and alive_target.pid > 0:
		_adopt_entry_target(entry, alive_target, "_switch_to_game")
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game: resuming existing process")
		await _resume_game(entry)
	elif alive_target.pid > 0:
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game: killing lingering process and relaunching")
		_kill_entry_processes(entry)
		await LaunchManager.process.confirm_process_dead_async(alive_target.pid, 3.0)
		entry.started = false
		entry.pid = -1
		entry.pgid = -1
		entry["window_xid"] = ""
		_launch_game(entry)
	else:
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game: launching fresh")
		entry.started = false
		entry.pid = -1
		entry.pgid = -1
		_launch_game(entry)

	print("[ShufflerSubManager] _switch_to_game: launched index=" + str(index) + " state=" + str(_state))
	# Pay the shuffle debit armed by _switch_to_next_game now that the switch
	# has actually committed.
	if _debit_choice_on_commit:
		_debit_choice_on_commit = false
		if _games_until_choice > 0:
			_games_until_choice -= 1
	if _state == State.ACTIVE or _state == State.PAUSED:
		var round_time = _random_round_time()
		print("[ShufflerSubManager] _switch_to_game: starting round timer " + str(round_time) + "s")
		_start_round_timer(round_time)
	else:
		if DEBUG_LOG: print("[ShufflerSubManager] _switch_to_game: not starting timer because state=" + str(_state))

	var game = entry.game
	game_switched.emit(game.title, game.platform_slug)

# ============================================================================
# GAME LAUNCH
# ============================================================================

## Waits for a pending launch's pid callback so a stop/relaunch never collides
## with LaunchManager's per-game launch guard (the collision reports pid -1,
## which reads as a failed launch and triggers a spurious skip + late-pid kill).
func _await_launch_settled(entry: Dictionary) -> void:
	var wait := 0.0
	while entry.get("launch_pending", false) and wait < 5.0:
		await get_tree().create_timer(0.1).timeout
		wait += 0.1
	if entry.get("launch_pending", false):
		push_warning("[ShufflerSubManager] _await_launch_settled timed out for " + _format_entry(entry))

## Prewarms the intro scene and fonts at session start, so the first intro
## of the run doesn't stall its animation on asset loading.
func _prewarm_intro_assets() -> void:
	if _intro_scene == null:
		_intro_scene = load(INTRO_SCENE) as PackedScene
	M3Theme.load_fonts()

## Intro notification for a game's first appearance this session (ported from
## the old game_shuffler's notif_intro). Plays over the screen while the
## emulator boots; unfocusable and click-through, so it never touches input.
## One pooled OS window per session: creating a transparent DisplayServer
## window per game switch is the expensive part, so present() re-runs on the
## same instance (it resets all animation state for reuse).
func _show_intro(game: GameResource) -> void:
	if not (_intro_window and is_instance_valid(_intro_window)):
		if _intro_scene == null:
			_intro_scene = load(INTRO_SCENE) as PackedScene
		if not _intro_scene:
			push_warning("[ShufflerSubManager] Failed to load intro window scene: " + INTRO_SCENE)
			return
		_intro_window = _intro_scene.instantiate()
		get_tree().root.add_child(_intro_window)
	_intro_window.present(game)

func _launch_game(entry: Dictionary) -> void:
	var game = entry.game
	var emulator_id = LaunchManager.resolve_emulator_for_game(game)
	entry.emulator_id = emulator_id

	var emulator = LaunchManager.get_emulator(emulator_id)
	entry.suspend_method = emulator.get("suspend_method", "suspend")
	if emulator_id == "retroarch":
		entry.suspend_method = _resolve_retroarch_suspend_method(entry)
	print("[ShufflerSubManager] _launch_game: " + _format_entry(entry) + " emulator=" + emulator_id + " method=" + entry.suspend_method + " temp_path=" + entry.temp_path)

	entry.launch_pending = true
	var on_pid_ready = func(pid: int):
		entry.launch_pending = false
		if DEBUG_LOG: print("[ShufflerSubManager] on_pid_ready for " + game.title + ": pid=" + str(pid))
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
			entry.pgid = LaunchManager.process.get_pgid(pid)
			if entry.pgid <= 1 and SystemManager.platform.is_linux():
				# Godot setsid()s the spawned leader, making it its own group;
				# assume that layout when the stat read raced the process.
				entry.pgid = pid
			entry.started = true
			# New process, new window: drop any XID captured for a previous
			# launch of this entry so it is re-captured below.
			entry["window_xid"] = ""
			_maximize_with_retry(pid, entry.emulator_id)
			# Vita3K/Cemu create the real game window seconds after the first;
			# re-capture on a schedule so the stored XID tracks it.
			_capture_window_xid_delayed(pid, entry.emulator_id)
		else:
			push_error("[ShufflerSubManager] Failed to launch game: " + game.title)
			# Skip immediately instead of idling out the round on a dead launch;
			# deferred so we never re-enter the switch logic from inside a
			# launch/firmware callback. skip_game() re-checks state and current.
			if (_state == State.ACTIVE or _state == State.PAUSED) and _current_game_index >= 0 \
				and _current_game_index < _bag.size() and _bag.entries[_current_game_index].game == game:
				call_deferred("skip_game")

		if emulator_id.begins_with("vita3k"):
			var title_id = game.get_active_title_id()
			if title_id != "":
				var install_path = LaunchManager.get_emulator_install_path(emulator_id)
				if install_path != "":
					# Managed emulator dir, not the exe's parent: extracted
					# AppImages nest the exe inside the update-wiped squashfs-root/.
					var vita_emu_dir = LaunchManager._get_emulator_directory(emulator_id).rstrip("/")
					var ux0_app_path = vita_emu_dir + "/ux0/app/" + title_id
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
							"ux0_app_path": ux0_app_path,
							# The license rif _ensure_vita3k_license installs
							# alongside the app; cleaned with it.
							"ux0_license_path": vita_emu_dir + "/ux0/license/" + title_id
						})
						if DEBUG_LOG: print("[ShufflerSubManager] Tracked Vita3K shuffler app for cleanup: " + ux0_app_path)
			else:
				push_warning("[ShufflerSubManager] Vita3K game launched but no TitleID was extracted: " + game.title)

		if emulator_id.begins_with("rpcs3"):
			var ps3_title_id = game.get_active_title_id()
			if ps3_title_id != "":
				var ps3_install_path = LaunchManager.get_emulator_install_path(emulator_id)
				if ps3_install_path != "":
					# Managed emulator dir, not the exe's parent (AppImage-safe).
					# Desktop shuffler launches extract straight into it; both
					# candidate layouts are candidates for session cleanup.
					var rpcs3_emu_dir = LaunchManager._get_emulator_directory(emulator_id).rstrip("/")
					var already_tracked_ps3 := false
					for tracked in _shuffler_ps3_games:
						if tracked.get("title_id", "") == ps3_title_id:
							already_tracked_ps3 = true
							break
					if not already_tracked_ps3:
						_shuffler_ps3_games.append({
							"title_id": ps3_title_id,
							"paths": [
								rpcs3_emu_dir + "/games/" + ps3_title_id,
								rpcs3_emu_dir + "/dev_hdd0/game/" + ps3_title_id,
							]
						})
						if DEBUG_LOG: print("[ShufflerSubManager] Tracked RPCS3 shuffler game for cleanup: " + ps3_title_id)
			else:
				push_warning("[ShufflerSubManager] RPCS3 game launched but no TitleID was extracted: " + game.title)

	LaunchManager.launch_shuffler_game(game, entry.temp_path, on_pid_ready)

## Resolves the suspend method for a RetroArch bag entry. Cores without
## reliable savestate support (dosbox_core, dosbox_svn, dosbox_pure, gw,
## pico8) declare "suspend_method": "suspend" in retroarch.json so they
## freeze via pssuspend instead of the udp quit+autosave flow. All udp cores
## keep the quit+savestate flow even while a suspended RetroArch in the bag
## still holds UDP port 55355.
func _resolve_retroarch_suspend_method(entry: Dictionary) -> String:
	var method := entry.suspend_method as String
	var core_id: String = LaunchManager.resolve_core_for_game(entry.game)
	if core_id != "":
		var core_cfg: Dictionary = LaunchManager.registry.get_core_config("retroarch", entry.game.platform_slug, core_id)
		method = core_cfg.get("suspend_method", method)
	return method

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
			await _confirm_quit_or_kill(entry)
		"tcp":
			var save_hash = str(entry.game.romm_id)
			await _send_tcp_command("localhost", 4444, "savevm " + save_hash)
			await _send_tcp_command("localhost", 4444, "quit")
			await _confirm_quit_or_kill(entry)
		"suspend", _:
			await _suspend_game(entry)

## udp/tcp quit commands are fire-and-forget: if the emulator never received
## or ignored the quit, it would keep running (and playing) alongside the next
## game. Confirm death and fall back to a hard kill.
func _confirm_quit_or_kill(entry: Dictionary) -> void:
	var pid: int = entry.pid
	if await LaunchManager.process.confirm_process_dead_async(pid, QUIT_CONFIRM_TIMEOUT_SEC):
		entry.pid = -1
		entry.pgid = -1
		entry.started = false
		entry.active = false
		return
	push_warning("[ShufflerSubManager] Quit command ignored by " + _format_entry(entry) + "; killing pid " + str(pid))
	_kill_entry_processes(entry)
	await LaunchManager.process.confirm_process_dead_async(pid, 3.0)
	entry.pid = -1
	entry.pgid = -1
	entry.started = false
	entry.active = false

func _suspend_game(entry: Dictionary) -> void:
	if entry.pid == -1:
		print("[ShufflerSubManager] _suspend_game: no pid for " + _format_entry(entry))
		return

	var emulator = LaunchManager.get_emulator(entry.emulator_id)
	var exe_name = ""
	var launch_config = emulator.get("launch", {})
	var platforms = launch_config.get("platforms", {})
	# Read the CURRENT platform's executable name (used as the Windows AHK
	# target). Previously this always read platforms.windows, which produced
	# names like "Cemu.exe" that can never substring-match a Linux WM_CLASS.
	var platform_key := SystemManager.platform.get_platform_name().to_lower()
	var pc: Dictionary = platforms.get(platform_key, {})
	if pc.is_empty():
		pc = platforms.get("windows", {})
	exe_name = pc.get("executable", "")

	print("[ShufflerSubManager] _suspend_game: " + _format_entry(entry) + " exe=" + exe_name)

	# Re-resolve the live payload before signaling: the tracked pid's group
	# goes stale when the emulator re-execs into its own group (AppImage
	# AppRun, Vita3K's second window), and SIGSTOPping the stale group freezes
	# only a dead wrapper while the game keeps playing. Signal EVERY group
	# the launch currently occupies (payloads that setsid after launch, e.g.
	# sharun/bwrap, leave the cached pgid pointing at the wrapper).
	var signal_pgids: Array[int] = []
	if SystemManager.platform.is_linux():
		var target := _resolve_entry_target(entry)
		_adopt_entry_target(entry, target, "_suspend_game")
		signal_pgids = _collect_signal_pgids(entry, target)
		var diag_pids: Array = [entry.pid, int(target.get("pid", -1))]
		var diag_sigs := _entry_signatures(entry)
		if not diag_sigs.is_empty():
			diag_pids.append_array(LaunchManager.process.find_pids_by_signatures(diag_sigs))
		LaunchManager.process.dump_pid_diagnostics("suspend", diag_pids)
		if int(entry.get("pgid", -1)) > 1:
			print("[ShufflerSubManager] _suspend_game: group members pre-stop: [" + LaunchManager.process.format_group_states(entry.pgid) + "] signal_pgids=" + str(signal_pgids))

	# The stored window XID may be stale (Vita3K/Cemu recreate their window on
	# game boot); drop it so the hide below falls back to a fresh lookup.
	await _validate_window_xid(entry)

	await _hide_window_awaited(entry.pid, exe_name, entry.emulator_id)

	# Await the suspension before returning: _switch_to_game launches the next
	# emulator instance immediately after this, and a still-running previous
	# instance races it (GPU/display/cache contention = hang/crash on launch).
	var suspend_start := Time.get_ticks_msec()
	var pending := {"count": 0, "exit_code": 0}
	var on_suspend_done := func(result: Dictionary):
		pending.count -= 1
		if result.get("exit_code", -1) != 0:
			pending.exit_code = result.get("exit_code", -1)
	if SystemManager.platform.is_linux() and not signal_pgids.is_empty():
		pending.count = signal_pgids.size()
		for pgid in signal_pgids:
			LaunchManager.process.suspend_process_async(entry.pid, _pssuspend_path, on_suspend_done, pgid)
	else:
		pending.count = 1
		LaunchManager.process.suspend_process_async(entry.pid, _pssuspend_path, on_suspend_done, int(entry.get("pgid", -1)))
	var elapsed := 0.0
	while pending.count > 0 and elapsed < SUSPEND_AWAIT_TIMEOUT_SEC:
		await get_tree().create_timer(0.05).timeout
		elapsed = (Time.get_ticks_msec() - suspend_start) / 1000.0

	var suspended: bool = pending.count == 0 and pending.exit_code == 0
	if suspended and SystemManager.platform.is_linux():
		# SIGSTOP exiting 0 only proves the signal was delivered, not that the
		# emulator actually froze (the tracked PID may have been a wrapper, or
		# the emulator may have forked helpers outside its group). Verify every
		# live member of every signaled group is stopped, AND that no process
		# matching the launch signature is still running — an escaped payload
		# (own session via sharun/bwrap) reads as "group stopped" otherwise.
		var verify_start := Time.get_ticks_msec()
		var verified := false
		var sigs := _entry_signatures(entry)
		while Time.get_ticks_msec() - verify_start < int(SUSPEND_VERIFY_TIMEOUT_SEC * 1000):
			verified = true
			for pgid in signal_pgids:
				if LaunchManager.process.is_group_alive(pgid) and not LaunchManager.process.are_group_members_stopped(pgid):
					verified = false
					break
			if verified:
				var pid_state: String = LaunchManager.process.get_process_state(entry.pid)
				if pid_state != "" and pid_state != "Z" and pid_state != "T" and pid_state != "t":
					verified = false
			if verified and not sigs.is_empty():
				for match_pid in LaunchManager.process.find_pids_by_signatures(sigs):
					var mstate: String = LaunchManager.process.get_process_state(match_pid)
					if mstate != "" and mstate != "T" and mstate != "t":
						verified = false
						break
			if verified:
				break
			await get_tree().create_timer(0.05).timeout
		if not verified:
			var pgid: int = entry.get("pgid", -1)
			push_warning("[ShufflerSubManager] _suspend_game: SIGSTOP delivered but game still running for pid " + str(entry.pid) + " pgid=" + str(pgid) + " signal_pgids=" + str(signal_pgids) + " members=[" + LaunchManager.process.format_group_states(pgid) + "]")
			suspended = false

	if suspended:
		print("[ShufflerSubManager] _suspend_game: pid " + str(entry.pid) + " suspended in " + str(Time.get_ticks_msec() - suspend_start) + "ms (exit_code=" + str(pending.exit_code) + ")")
	else:
		# A failed/wedged suspend leaves the outgoing game running and playing
		# alongside the next one. Kill it instead; the slot relaunches fresh
		# the next time it is picked.
		push_warning("[ShufflerSubManager] _suspend_game: suspend failed for pid " + str(entry.pid) + " (signaled=" + str(signal_pgids.size()) + " groups, exit_code=" + str(pending.exit_code) + "); killing to keep only one live game")
		_kill_entry_processes(entry)
		await LaunchManager.process.confirm_process_dead_async(entry.pid, 3.0)
		entry.pid = -1
		entry.pgid = -1
		entry.started = false

	entry.active = false

func _resume_game(entry: Dictionary) -> void:
	if entry.pid == -1:
		print("[ShufflerSubManager] _resume_game: no pid for " + _format_entry(entry))
		return

	print("[ShufflerSubManager] _resume_game: " + _format_entry(entry))
	# SIGCONT must reach every group the launch occupies (escaped payload
	# groups included); a continue delivered only to the wrapper's group
	# leaves a setsid'd payload frozen forever.
	var signal_pgids: Array[int] = []
	if SystemManager.platform.is_linux():
		var target := _resolve_entry_target(entry)
		_adopt_entry_target(entry, target, "_resume_game")
		signal_pgids = _collect_signal_pgids(entry, target)
		if int(entry.get("pgid", -1)) > 1:
			print("[ShufflerSubManager] _resume_game: group members pre-resume: [" + LaunchManager.process.format_group_states(entry.pgid) + "] signal_pgids=" + str(signal_pgids))
	var resume_start := Time.get_ticks_msec()
	var pending := {"count": 0, "exit_code": 0}
	var on_resume_done := func(result: Dictionary):
		pending.count -= 1
		if result.get("exit_code", -1) != 0:
			pending.exit_code = result.get("exit_code", -1)
	if SystemManager.platform.is_linux() and not signal_pgids.is_empty():
		pending.count = signal_pgids.size()
		for pgid in signal_pgids:
			LaunchManager.process.resume_process_async(entry.pid, _pssuspend_path, on_resume_done, pgid)
	else:
		pending.count = 1
		LaunchManager.process.resume_process_async(entry.pid, _pssuspend_path, on_resume_done, int(entry.get("pgid", -1)))
	while pending.count > 0 and Time.get_ticks_msec() - resume_start < int(SUSPEND_AWAIT_TIMEOUT_SEC * 1000):
		await get_tree().create_timer(0.05).timeout
	if pending.count == 0:
		print("[ShufflerSubManager] _resume_game: pid " + str(entry.pid) + " resumed in " + str(Time.get_ticks_msec() - resume_start) + "ms (exit_code=" + str(pending.exit_code) + ")")
	else:
		push_warning("[ShufflerSubManager] _resume_game: timed out waiting for pssuspend -r (pid " + str(entry.pid) + "); maximizing anyway")

	await get_tree().create_timer(0.2).timeout

	# A recreated window (Vita3K/Cemu boot a game window seconds after the
	# first) invalidates the stored XID; drop stale ones before maximizing.
	await _validate_window_xid(entry)

	await _maximize_with_retry(entry.pid, entry.emulator_id)

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
	if _switch_in_progress:
		# A switch (skip/restart/reroll fill) is already in flight and starts a
		# fresh round timer when it completes, so this timeout is stale; acting
		# on it would only queue a jarring second switch right after.
		print("[ShufflerSubManager] _on_round_timer_timeout ignored: switch in progress")
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

func _toggle_controls() -> void:
	if _controls_window and is_instance_valid(_controls_window):
		_controls_window.hide_controls()
	elif _state == State.ACTIVE or _state == State.PAUSED:
		_summon_controls()

# ============================================================================
# WINDOW / PROCESS HELPERS
# ============================================================================

func _hide_window_async(pid: int, exe_name: String, callback: Callable = Callable(), hint: String = "") -> void:
	match _window_backend:
		WindowBackend.WINDOWS_AHK:
			var ahk_script = _tools_dir + "minimize_window.ahk"
			if FileAccess.file_exists(ahk_script) and FileAccess.file_exists(_ahk_path):
				MemorySubManager.queue_os_execute(_ahk_path, [ahk_script, str(pid), exe_name], callback)
			elif callback.is_valid():
				callback.call_deferred({"exit_code": -1, "output": []})
		WindowBackend.LINUX_KWIN:
			_kwin_minimize_async(pid, callback)
		WindowBackend.LINUX_X11:
			_x11_minimize_async(pid, callback, hint)
		_:
			if callback.is_valid():
				callback.call_deferred({"exit_code": -1, "output": []})

func _hide_window_awaited(pid: int, exe_name: String, hint: String = "") -> void:
	var hide_start := Time.get_ticks_msec()
	var done := {"complete": false, "exit_code": -1}
	_hide_window_async(pid, exe_name, func(result: Dictionary):
		done.complete = true
		done.exit_code = result.get("exit_code", -1)
	, hint)
	var elapsed := 0.0
	while not done.complete and elapsed < HIDE_AWAIT_TIMEOUT_SEC:
		await get_tree().create_timer(0.05).timeout
		elapsed = (Time.get_ticks_msec() - hide_start) / 1000.0
	if done.complete:
		if DEBUG_LOG: print("[ShufflerSubManager] _hide_window_awaited: pid " + str(pid) + " hidden in " + str(Time.get_ticks_msec() - hide_start) + "ms (exit_code=" + str(done.exit_code) + ")")
	else:
		push_warning("[ShufflerSubManager] _hide_window_awaited: timed out waiting for window backend (pid " + str(pid) + "); suspending anyway")

func _is_current_game_pid(pid: int) -> bool:
	if _state != State.ACTIVE and _state != State.PAUSED:
		return false
	if _current_game_index < 0 or _current_game_index >= _bag.size():
		return false
	return _bag.entries[_current_game_index].pid == pid

func _maximize_with_retry(pid: int, hint: String = "") -> void:
	if DEBUG_LOG: print("[ShufflerSubManager] _maximize_with_retry START pid=" + str(pid))
	var token := _maximize_token
	var maximized := false
	for i in range(3):
		if token != _maximize_token or not _is_current_game_pid(pid):
			if DEBUG_LOG: print("[ShufflerSubManager] _maximize_with_retry aborted: pid " + str(pid) + " is no longer the foreground game")
			return
		if DEBUG_LOG: print("[ShufflerSubManager] Maximizing pid " + str(pid) + " (attempt " + str(i + 1) + "/3)")
		if await _maximize_window_async(pid, token, hint):
			if DEBUG_LOG: print("[ShufflerSubManager] pid " + str(pid) + " maximized successfully")
			maximized = true
			break
		await get_tree().create_timer(0.5).timeout
	if DEBUG_LOG: print("[ShufflerSubManager] _maximize_with_retry END pid=" + str(pid) + " maximized=" + str(maximized))
	if token != _maximize_token or not _is_current_game_pid(pid):
		return
	if not maximized:
		push_error("[ShufflerSubManager] Failed to maximize window for pid " + str(pid) + " after 3 attempts")
	if maximized:
		_ensure_controls_on_top()
		_delayed_remaximize(pid, token, hint)

# Some emulators (e.g. Vita3K) recreate their game window seconds after the
# first one appears, so a successful maximize can bind to a doomed window.
# Re-raise once more shortly after; no-ops if we've already switched away.
func _delayed_remaximize(pid: int, token: int, hint: String = "") -> void:
	await get_tree().create_timer(4.0).timeout
	if token != _maximize_token or not _is_current_game_pid(pid):
		return
	if DEBUG_LOG: print("[ShufflerSubManager] _delayed_remaximize: re-maximizing pid " + str(pid))
	await _maximize_window_async(pid, token, hint)
	_ensure_controls_on_top()

func _maximize_window_async(pid: int, token: int = -1, hint: String = "") -> bool:
	var os_state := {"completed": false, "success": false, "output_text": ""}

	match _window_backend:
		WindowBackend.WINDOWS_AHK:
			var ahk_script = _tools_dir + "maximize_process.ahk"
			if not FileAccess.file_exists(ahk_script) or not FileAccess.file_exists(_ahk_path):
				if DEBUG_LOG: print("[ShufflerSubManager] _maximize_window_async missing tool: ahk_script=" + str(FileAccess.file_exists(ahk_script)) + " ahk_path=" + str(FileAccess.file_exists(_ahk_path)))
				return false
			MemorySubManager.queue_os_execute(_ahk_path, [ahk_script, str(pid)], func(result: Dictionary):
				os_state["completed"] = true
				os_state["success"] = (result.get("exit_code", -1) == 0)
				var output: Array = result.get("output", [])
				os_state["output_text"] = "".join(output)
				if DEBUG_LOG: print("[ShufflerSubManager] maximize_process.ahk result for pid " + str(pid) + ": exit=" + str(result.get("exit_code", -1)) + " output=\"" + os_state["output_text"].strip_edges() + "\"")
			)
		WindowBackend.LINUX_KWIN:
			_kwin_raise_async(pid, func(result: Dictionary):
				os_state["completed"] = true
				os_state["success"] = (result.get("exit_code", -1) == 0)
				if DEBUG_LOG: print("[ShufflerSubManager] kwin raise result for pid " + str(pid) + ": exit=" + str(result.get("exit_code", -1)))
			)
		WindowBackend.LINUX_X11:
			_x11_raise_async(pid, func(result: Dictionary):
				os_state["completed"] = true
				os_state["success"] = (result.get("exit_code", -1) == 0)
				if DEBUG_LOG: print("[ShufflerSubManager] x11 raise result for pid " + str(pid) + ": exit=" + str(result.get("exit_code", -1)))
			, hint)
		_:
			return false

	while not os_state["completed"]:
		if token != -1 and token != _maximize_token:
			# Switched away mid-attempt; the helper process finishes in the
			# background and its result is discarded.
			return false
		await get_tree().process_frame

	return os_state["success"]

# ============================================================================
# LINUX WINDOW BACKENDS
# ============================================================================

func _kwin_minimize_async(pid: int, callback: Callable = Callable()) -> void:
	_kwin_run_script_async(pid, "minimize", callback)


func _kwin_raise_async(pid: int, callback: Callable = Callable()) -> void:
	_kwin_run_script_async(pid, "raise", callback)


func _kwin_run_script_async(pid: int, action: String, callback: Callable = Callable()) -> void:
	if _qdbus_cmd.is_empty():
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return

	var script_name := "kyodai_shuffler_%s_%d_%d_%d" % [action, pid, Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	var package_root := ProjectSettings.globalize_path(TEMP_DIR + "kwin_" + script_name)
	var code_dir := package_root + "/contents/code"
	var script_path := code_dir + "/main.js"
	if not DirAccess.dir_exists_absolute(code_dir):
		DirAccess.make_dir_recursive_absolute(code_dir)

	var body := ""
	match action:
		"minimize":
			body = "for (const client of workspace.clientList()) { if (client.pid === %d) { client.minimized = true; } }" % pid
		"raise":
			body = "for (const client of workspace.clientList()) { if (client.pid === %d) { workspace.activeClient = client; workspace.raiseWindow(client); } }" % pid
		_:
			if callback.is_valid():
				callback.call_deferred({"exit_code": -1, "output": []})
			return

	var metadata := '{"KPackageStructure":"KWin/Script","KPlugin":{"Authors":[{"Name":"Kyodai"}],"Id":"%s","Name":"Kyodai Shuffler","Version":"1.0"}}' % script_name
	var meta_file := FileAccess.open(package_root + "/metadata.json", FileAccess.WRITE)
	if not meta_file:
		push_warning("[ShufflerSubManager] Failed to write KWin metadata")
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return
	meta_file.store_string(metadata)
	meta_file.close()

	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		push_warning("[ShufflerSubManager] Failed to write KWin script: " + script_path)
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return
	file.store_string(body)
	file.close()

	var sh_script_path := package_root + "/run.sh"
	var sh_script := "#!/bin/sh\n"
	sh_script += "%s org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript \"%s\" >/dev/null 2>&1 || true\n" % [_qdbus_cmd, script_name]
	sh_script += "id=$(%s org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript \"%s\" \"%s\")\n" % [_qdbus_cmd, script_path, script_name]
	sh_script += "id=$(echo \"$id\" | tr -d '[:space:]')\n"
	sh_script += "if [ -z \"$id\" ] || [ \"$id\" -lt 0 ] 2>/dev/null; then exit 1; fi\n"
	sh_script += "%s org.kde.KWin /Scripting/Script${id} org.kde.kwin.Script.run\n" % _qdbus_cmd
	sh_script += "rc=$?\n"
	sh_script += "%s org.kde.KWin /Scripting/Script${id} org.kde.kwin.Script.stop >/dev/null 2>&1 || true\n" % _qdbus_cmd
	sh_script += "%s org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript \"%s\" >/dev/null 2>&1 || true\n" % [_qdbus_cmd, script_name]
	sh_script += "exit $rc\n"

	var sh_file := FileAccess.open(sh_script_path, FileAccess.WRITE)
	if not sh_file:
		push_warning("[ShufflerSubManager] Failed to write KWin runner script: " + sh_script_path)
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return
	sh_file.store_string(sh_script)
	sh_file.close()

	MemorySubManager.queue_os_execute("/bin/sh", [sh_script_path], callback)


## Wraps an x11_windowctl callback to surface the helper's stderr in the log:
## failures and name-hint fallbacks are otherwise invisible in release builds.
func _x11_logging_callback(action: String, pid: int, callback: Callable) -> Callable:
	return func(result: Dictionary):
		var output := ("".join(result.get("output", []))).strip_edges()
		var exit_code: int = result.get("exit_code", -1)
		if exit_code != 0:
			print("[ShufflerSubManager] x11_windowctl " + action + " pid=" + str(pid) + " failed: exit=" + str(exit_code) + " " + output)
		elif output != "":
			print("[ShufflerSubManager] x11_windowctl " + action + " pid=" + str(pid) + ": " + output)
		if callback.is_valid():
			callback.call(result)


## Returns the x11_windowctl target for a game's window: the captured XID if
## we have one (unambiguous when several instances of the same emulator are
## alive, e.g. suspended games), else a comma-separated list of every PID in
## the game's process group (the window's _NET_WM_PID rarely matches the
## leader we spawned — AppImage AppRun, sh wrappers — but always matches
## SOME member of the group).
func _windowctl_target(pid: int) -> String:
	if pid <= 0:
		return str(pid)
	if _bag and _bag.entries:
		for entry in _bag.entries:
			if entry.pid == pid:
				var xid: String = entry.get("window_xid", "")
				if xid != "":
					return "xid:" + xid
				return _group_pid_list(pid)
	return str(pid)

## Comma-separated PID list covering the tracked PID plus every live member
## of its process group, for x11_windowctl's multi-pid window matching.
## Prefers the entry's adopted payload pgid over the launch-time pid's group.
func _group_pid_list(pid: int) -> String:
	var pids := {}
	pids[pid] = true
	if SystemManager.platform.is_linux():
		var pgid := -1
		if _bag and _bag.entries:
			for entry in _bag.entries:
				if entry.pid == pid and int(entry.get("pgid", -1)) > 1:
					pgid = int(entry.pgid)
					break
		if pgid <= 1:
			pgid = LaunchManager.process.get_pgid(pid)
		if pgid > 1:
			for member in LaunchManager.process.get_group_members(pgid):
				pids[member] = true
	var list: Array = []
	for p in pids.keys():
		list.append(str(p))
	return ",".join(list)

## Re-resolves the live process behind a bag entry right now: the tracked pid
## when it (or its group) still lives, else a payload found by ROM-path
## signature scan (emulators re-exec/fork into new process groups, leaving
## the tracked leader a zombie). Returns {"pid": -1, "pgid": -1} when dead.
## All launch signatures that may appear in /proc cmdlines for this entry.
## Vita3K zip launches keep the source zip in the payload cmdline; installed
## app launches name the ux0 app dir or the title id — match any of them.
func _entry_signatures(entry: Dictionary) -> Array[String]:
	var sigs: Array[String] = []
	var vita_app_path: String = entry.get("vita_app_path", "")
	if vita_app_path != "":
		sigs.append(ProjectSettings.globalize_path(vita_app_path))
	var vita_title_id: String = entry.get("vita_title_id", "")
	if vita_title_id != "":
		sigs.append(vita_title_id)
	if entry.get("temp_path", "") != "":
		sigs.append(ProjectSettings.globalize_path(entry.temp_path))
	return sigs

func _entry_signature(entry: Dictionary) -> String:
	var sigs := _entry_signatures(entry)
	return sigs[0] if not sigs.is_empty() else ""

func _resolve_entry_target(entry: Dictionary) -> Dictionary:
	var pid: int = entry.get("pid", -1)
	var target: Dictionary = LaunchManager.process.resolve_live_target(pid, _entry_signature(entry))
	if int(target.get("pid", -1)) <= 0:
		# The tracked pid is gone/unreadable; the payload may still live under
		# a different pid (sharun/bwrap forks, re-execs). Try every signature.
		LaunchManager.process.dump_pid_diagnostics("resolve-miss", [pid])
		# Decisive context: if the entry's group still has live members while
		# the tracked pid is unreadable, the game is alive but invisible to
		# /proc (bwrap dumpable=0); an empty group means it truly died.
		var miss_pgid: int = entry.get("pgid", -1)
		if miss_pgid > 1:
			print("[ShufflerSubManager] resolve-miss: entry group " + str(miss_pgid) + " members=[" + LaunchManager.process.format_group_states(miss_pgid) + "]")
		var matches: Array[int] = LaunchManager.process.find_pids_by_signatures(_entry_signatures(entry))
		if not matches.is_empty():
			LaunchManager.process.dump_pid_diagnostics("resolve-found", matches)
			target["pid"] = matches[0]
			var pgrp: int = LaunchManager.process.get_pgid(matches[0])
			if pgrp > 1 and pgrp != LaunchManager.process.get_own_pgid():
				target["pgid"] = pgrp
	if int(target.get("pid", -1)) <= 0:
		# bwrap/sandboxed payloads can be entirely unreadable via /proc
		# (dumpable=0: empty cmdline, stat restricted). The wrapper group
		# leader stays alive for exactly as long as the launch does (sharun
		# waits on bwrap waits on the payload), so a live entry group means
		# the game is still there — group signals reach the payload in place.
		var entry_pgid: int = entry.get("pgid", -1)
		if entry_pgid > 1 and LaunchManager.process.is_group_alive(entry_pgid):
			target["pid"] = entry_pgid
			target["pgid"] = entry_pgid
	return target

## Every process group this entry's launch currently occupies: the cached
## pgid, the tracked pid's live group, the signature-resolved target's group,
## and the groups of ALL live signature matches. Emulators whose payload
## escapes the launch group after launch (sharun/bwrap setsid: Vita3K,
## Dolphin) leave the cached pgid pointing at a bare wrapper — signaling
## only that group freezes/kills a shell while the game keeps playing.
func _collect_signal_pgids(entry: Dictionary, target: Dictionary = {}) -> Array[int]:
	var pgids: Array[int] = []
	var own_pgid: int = LaunchManager.process.get_own_pgid()
	var add_pgid := func(pgid: int):
		if pgid > 1 and pgid != own_pgid and not pgids.has(pgid):
			pgids.append(pgid)
	add_pgid.call(int(entry.get("pgid", -1)))
	var pid: int = entry.get("pid", -1)
	if pid > 0:
		add_pgid.call(LaunchManager.process.get_pgid(pid))
	if not target.is_empty():
		add_pgid.call(int(target.get("pgid", -1)))
		var tpid: int = target.get("pid", -1)
		if tpid > 0:
			add_pgid.call(LaunchManager.process.get_pgid(tpid))
	var sigs := _entry_signatures(entry)
	if not sigs.is_empty():
		for match_pid in LaunchManager.process.find_pids_by_signatures(sigs):
			add_pgid.call(LaunchManager.process.get_pgid(match_pid))
	return pgids

## Adopts a freshly resolved live target into the entry. Returns true when
## the resolution changed anything.
func _adopt_entry_target(entry: Dictionary, target: Dictionary, context: String) -> bool:
	if int(target.get("pid", -1)) <= 0:
		return false
	var changed := false
	var desc := _format_entry(entry)
	if target.pid != entry.pid:
		print("[ShufflerSubManager] %s: re-adopting pid %d -> %d for %s" % [context, entry.pid, target.pid, desc])
		entry.pid = target.pid
		changed = true
	if int(target.get("pgid", -1)) > 1 and target.pgid != entry.get("pgid", -1):
		print("[ShufflerSubManager] %s: adopting pgid %d for %s (was %d)" % [context, target.pgid, desc, int(entry.get("pgid", -1))])
		entry.pgid = target.pgid
		changed = true
	return changed

## Drops a stored window XID when the window no longer exists (emulators like
## Vita3K and Cemu recreate their window on game boot). After clearing, the
## next hide/show falls back to a fresh pid+hint lookup and re-captures.
func _validate_window_xid(entry: Dictionary) -> void:
	if _window_backend != WindowBackend.LINUX_X11 or _x11_windowctl_path.is_empty():
		return
	var xid: String = entry.get("window_xid", "")
	if xid == "":
		return
	var state := {"done": false, "ok": true}
	LaunchManager.process.queue_helper_execute(_x11_windowctl_path, ["exists", "xid:" + xid], func(result: Dictionary):
		state.done = true
		state.ok = result.get("exit_code", -1) != 1  # 1 = confirmed gone
	)
	var waited := 0.0
	while not state.done and waited < 1.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	if state.done and not state.ok:
		print("[ShufflerSubManager] stored window xid " + xid + " is stale (window recreated?); clearing for re-capture")
		entry["window_xid"] = ""

## Re-captures the window XID a few times after launch: Vita3K/Cemu create
## the real game window seconds after the first one appears, so a single
## early capture can bind to a doomed boot window.
func _capture_window_xid_delayed(pid: int, hint: String) -> void:
	for delay in [1.0, 3.0, 6.0]:
		await get_tree().create_timer(delay).timeout
		if not _pid_is_live_entry(pid):
			return
		_capture_window_xid(pid, hint)

## True while the given pid still belongs to a started bag entry (i.e. the
## game wasn't switched away from or stopped while a capture was pending).
func _pid_is_live_entry(pid: int) -> bool:
	if _state != State.ACTIVE and _state != State.PAUSED:
		return false
	if not _bag or not _bag.entries:
		return false
	for entry in _bag.entries:
		if entry.pid == pid:
			return entry.started
	return false

## Captures the exact X11 window ID for this game and stores it on the bag
## entry, so later hide/show calls target that window unambiguously. When the
## entry has a game title, the window list is matched by title first (some
## emulators, Vita3K in particular, open TWO windows per instance — a main
## window and a game window named after the game — and pid/hint matching can
## pick the wrong one); falls back to pid/hint matching otherwise.
func _capture_window_xid(pid: int, hint: String) -> void:
	if _x11_windowctl_path.is_empty():
		return
	var entry: Dictionary = {}
	if _bag and _bag.entries:
		for e in _bag.entries:
			if e.pid == pid:
				entry = e
				break
	var title := ""
	if not entry.is_empty() and entry.get("game"):
		title = entry.game.title
	if title != "":
		_capture_window_xid_from_list(pid, hint, entry)
	else:
		_capture_window_xid_find(pid, hint)

## Lowercase alnum-only form of a title, so "Cladun Returns: This is
## Sengoku!" still matches a window titled "Cladun Returns - This Is
## Sengoku! (PCSE01234)" regardless of punctuation/case differences.
func _norm_title(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		if (c >= 48 and c <= 57) or (c >= 97 and c <= 122):
			out += char(c)
		elif c >= 65 and c <= 90:
			out += char(c + 32)
	return out

## Selects this entry's window from the full window list by title match;
## falls back to pid/hint find when no window names the game.
func _capture_window_xid_from_list(pid: int, hint: String, entry: Dictionary) -> void:
	LaunchManager.process.queue_helper_execute(_x11_windowctl_path, ["list"], func(result: Dictionary):
		if not _pid_is_live_entry(pid):
			return
		var norm_title := _norm_title(entry.game.title)
		var best_xid := ""
		var best_owner := -1
		var best_name := ""
		var best_in_group := false
		if result.get("exit_code", -1) == 0 and norm_title != "":
			var text := ("".join(result.get("output", []))).strip_edges()
			for line in text.split("\n", false):
				var l := line.strip_edges()
				var sp := l.find(" ")
				if sp == -1:
					continue
				var wxid := l.substr(0, sp)
				if not wxid.is_valid_hex_number(false):
					continue
				var rest := l.substr(sp + 1)
				var name_idx := rest.find("name=")
				if name_idx == -1:
					continue
				var wname := rest.substr(name_idx + 5)
				var wowner := -1
				var pid_part := rest.substr(0, name_idx).strip_edges()
				if pid_part.begins_with("pid="):
					wowner = pid_part.trim_prefix("pid=").to_int()
				var nn := _norm_title(wname)
				if nn.find(norm_title) == -1:
					continue
				var foreign := false
				for other in _bag.entries:
					if other == entry or not other.started:
						continue
					var ot := _norm_title(other.game.title)
					if ot != "" and ot != norm_title and nn.find(ot) != -1:
						foreign = true
						break
				if foreign:
					continue
				var in_group := false
				if wowner > 0:
					var wpgid: int = LaunchManager.process.get_pgid(wowner)
					var epgid := int(entry.get("pgid", -1))
					if epgid <= 1:
						epgid = LaunchManager.process.get_pgid(pid)
					in_group = wpgid > 1 and wpgid == epgid
				if best_xid == "" or (in_group and not best_in_group) or (in_group == best_in_group and wxid.hex_to_int() > best_xid.hex_to_int()):
					best_xid = wxid
					best_owner = wowner
					best_name = wname
					best_in_group = in_group
		if best_xid != "":
			_store_captured_xid(entry, pid, best_xid, best_owner, best_name)
		else:
			_capture_window_xid_find(pid, hint)
	)

## Stores a captured window on the entry, adopting the window owner's process
## group so suspend/resume/kill reach the real payload. Returns false when the
## window clearly belongs to a different started game.
func _store_captured_xid(entry: Dictionary, pid: int, xid: String, owner_pid: int, window_name: String) -> bool:
	if xid == "":
		return false
	if not _pid_is_live_entry(pid):
		return false
	if window_name != "" and _bag and _bag.entries:
		var owner_title := ""
		for other in _bag.entries:
			if other == entry or not other.started:
				continue
			var t := (other.game.title as String).to_lower()
			if t != "" and window_name.to_lower().find(t) != -1:
				owner_title = other.game.title
				break
		if owner_title != "":
			print("[ShufflerSubManager] rejecting window xid " + xid + " for pid " + str(pid) + ": title names '" + owner_title + "' (\"" + window_name + "\")")
			return false
	entry["window_xid"] = xid
	# The window owner is the real payload (AppRun/Vita3K re-exec away from
	# the spawned leader); adopt its group so suspend/resume/kill reach the
	# emulator itself. Guards: hint-matched windows can belong to a DIFFERENT
	# launch entirely (a leaked/suspended instance of the same emulator) — a
	# stopped owner or one whose cmdline doesn't carry this entry's launch
	# signature must never overwrite the entry's live pgid.
	if owner_pid > 0 and SystemManager.platform.is_linux():
		var owner_state: String = LaunchManager.process.get_process_state(owner_pid)
		var owner_ok := owner_state != "" and owner_state != "T" and owner_state != "t" and owner_state != "Z"
		if owner_ok and owner_pid != pid:
			var sigs := _entry_signatures(entry)
			if not sigs.is_empty():
				var owner_cmd: String = LaunchManager.process.get_process_cmdline_pub(owner_pid)
				owner_ok = false
				for sig in sigs:
					if owner_cmd.find(sig) != -1:
						owner_ok = true
						break
		if owner_ok:
			var owner_pgid: int = LaunchManager.process.get_pgid(owner_pid)
			if owner_pgid > 1 and owner_pgid != entry.pgid:
				print("[ShufflerSubManager] adopting pgid " + str(owner_pgid) + " from window owner pid " + str(owner_pid) + " (was pgid " + str(entry.pgid) + ")")
				entry.pgid = owner_pgid
		else:
			print("[ShufflerSubManager] ignoring window owner pid " + str(owner_pid) + " for pgid adoption (state=" + LaunchManager.process.get_process_state(owner_pid) + ")")
	print("[ShufflerSubManager] captured window xid " + xid + " for pid " + str(pid) + " (\"" + window_name + "\")")
	return true

## pid/hint matching fallback (same rules as show/hide targeting).
func _capture_window_xid_find(pid: int, hint: String) -> void:
	var args: Array = ["find", _group_pid_list(pid)]
	if hint != "":
		args.append(hint)
	LaunchManager.process.queue_helper_execute(_x11_windowctl_path, args, func(result: Dictionary):
		if result.get("exit_code", -1) != 0:
			return
		# The helper prints the hex XID on stdout (plus optional "pid=N" owner
		# and "name=..." title lines); LD_PRELOAD noise from the Steam overlay
		# can precede it, so scan line-by-line instead of trusting the blob.
		var text := ("".join(result.get("output", []))).strip_edges()
		var xid := ""
		var owner_pid := -1
		var window_name := ""
		for line in text.split("\n", false):
			var l := line.strip_edges()
			var ll := l.to_lower()
			if ll.begins_with("pid="):
				owner_pid = ll.trim_prefix("pid=").to_int()
			elif ll.begins_with("name="):
				window_name = l.trim_prefix("name=")
			elif l.length() > 0 and l.is_valid_hex_number(false):
				xid = l
		if xid == "":
			return
		if _bag and _bag.entries:
			for entry in _bag.entries:
				if entry.pid == pid:
					_store_captured_xid(entry, pid, xid, owner_pid, window_name)
					break
	)


## Thoroughly terminates a game's process tree. The tracked pid can be a
## launcher wrapper (AppImage sh/AppRun) whose death orphans the real
## emulator, so this also SIGKILLs every descendant, and severs the X client
## that owns the captured game window (the real emulator) as a final
## insurance. SIGCONT first so SIGSTOPped games can actually die.
func _kill_entry_processes(entry: Dictionary) -> void:
	var pid: int = entry.get("pid", -1)
	var xid: String = entry.get("window_xid", "")
	if pid <= 0 and xid == "":
		return
	if SystemManager.platform.is_windows():
		if pid > 0:
			MemorySubManager.queue_os_execute("taskkill", ["/F", "/T", "/PID", str(pid)])
	else:
		if pid > 0:
			# Group kill first (SIGCONT so SIGSTOPped members can die): the
			# whole launch tree shares one PGID (Godot setsid()s the child), so this
			# reaches the payload even when the tracked pid is a wrapper.
			# Payloads that setsid after launch (sharun/bwrap: Vita3K, Dolphin)
			# escape the launch-time group, so signal EVERY group the launch
			# currently occupies and kill_tree every live signature match;
			# kill_tree remains as a descendant fallback (plain sh function; no
			# process-group kill of our own group because Godot-spawned
			# children can share our process group).
			var target := _resolve_entry_target(entry)
			var pgids := _collect_signal_pgids(entry, target)
			var tree_pids: Array[int] = [pid]
			if int(target.get("pid", -1)) > 0 and target.pid != pid:
				tree_pids.append(target.pid)
			var sigs := _entry_signatures(entry)
			if not sigs.is_empty():
				for match_pid in LaunchManager.process.find_pids_by_signatures(sigs):
					if not tree_pids.has(match_pid):
						tree_pids.append(match_pid)
			var script := ""
			for pgid in pgids:
				script += "kill -CONT -- -%d 2>/dev/null; kill -9 -- -%d 2>/dev/null; " % [pgid, pgid]
			script += "kill_tree() { kill -CONT \"$1\" 2>/dev/null; for child in $(ps -o pid= --ppid \"$1\" 2>/dev/null); do kill_tree \"$child\"; done; kill -9 \"$1\" 2>/dev/null; };"
			for tree_pid in tree_pids:
				script += " kill_tree " + str(tree_pid) + ";"
			print("[ShufflerSubManager] _kill_entry_processes: pid=" + str(pid) + " pgids=" + str(pgids) + " tree_pids=" + str(tree_pids))
			MemorySubManager.queue_os_execute("/bin/sh", ["-c", script])
		if xid != "" and not _x11_windowctl_path.is_empty():
			LaunchManager.process.queue_helper_execute(_x11_windowctl_path, ["xkill", "xid:" + xid], _x11_logging_callback("xkill", pid, Callable()))


func _x11_minimize_async(pid: int, callback: Callable = Callable(), hint: String = "") -> void:
	if _x11_windowctl_path.is_empty():
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return
	# In GameMode use XUnmapWindow: gamescope's WM ignores the EWMH hidden
	# hint, and unmap works even on a frozen (suspended) client.
	var action := "hide" if SystemManager.platform.is_gamemode() else "minimize"
	var args: Array = [action, _windowctl_target(pid)]
	if hint != "":
		args.append(hint)
	LaunchManager.process.queue_helper_execute(_x11_windowctl_path, args, _x11_logging_callback(action, pid, callback))


func _x11_raise_async(pid: int, callback: Callable = Callable(), hint: String = "") -> void:
	if _x11_windowctl_path.is_empty():
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return
	# In GameMode remap the (previously unmapped) window and raise it in one go.
	var action := "show" if SystemManager.platform.is_gamemode() else "raise"
	var args: Array = [action, _windowctl_target(pid)]
	if hint != "":
		args.append(hint)
	LaunchManager.process.queue_helper_execute(_x11_windowctl_path, args, _x11_logging_callback(action, pid, func(result: Dictionary):
		if result.get("exit_code", -1) == 0 and not _windowctl_target(pid).begins_with("xid:"):
			# Raised via pid/hint lookup: capture the exact window ID so the
			# next hide/show for this entry is unambiguous.
			_capture_window_xid(pid, hint)
		if callback.is_valid():
			callback.call(result)
	))


func _is_process_running_async(pid: int) -> bool:
	return await LaunchManager.process.is_running_async(pid)

func _send_udp_command(host: String, port: int, command: String) -> void:
	var address := _resolve_host(host)
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

func _resolve_host(host: String) -> String:
	if host == "localhost":
		return "127.0.0.1"
	if host.is_valid_ip_address():
		return host
	return IP.resolve_hostname(host, IP.TYPE_IPV4)

func _send_tcp_command(host: String, port: int, command: String) -> void:
	var address := _resolve_host(host)
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

	var data := (command + "\n").to_utf8_buffer()
	var sent := 0
	while sent < data.size():
		var result: Array = tcp.put_partial_data(data.slice(sent))
		if result[0] != OK:
			push_error("[ShufflerSubManager] TCP put_data failed (err=" + str(result[0]) + ") sending: " + command)
			tcp.disconnect_from_host()
			return
		sent += result[1]
		if sent < data.size():
			await get_tree().process_frame

	await get_tree().create_timer(0.1).timeout
	tcp.disconnect_from_host()

# ============================================================================
# CONTROLS WINDOW
# ============================================================================

## Creates the persistent invisible input listener for the summon chord.
## Joypad input only reaches viewports backed by a MAPPED OS window, so the
## chord cannot live in the minimized main window or the ephemeral palette.
func _create_input_window() -> void:
	if _input_window and is_instance_valid(_input_window):
		return
	_input_window = ShufflerInputWindowScene.new()
	_input_window.chord_pressed.connect(_toggle_controls)
	get_tree().root.add_child(_input_window)

## Creates the controls palette on summon. The window is freed on dismiss and
## recreated here on the next summon (create-on-summon): gamescope only
## composites freshly-mapped overlay windows above the focused game, so the
## panel can never be a persistent window that gets raised.
func _summon_controls() -> void:
	if DEBUG_LOG: print("[ShufflerSubManager] _summon_controls")
	if _controls_window and is_instance_valid(_controls_window):
		return

	var scene = load("res://components/shuffler/shuffler_controls_window.tscn")
	if not scene:
		push_error("[ShufflerSubManager] Failed to load controls window scene")
		return

	_controls_window = scene.instantiate()
	_controls_window.skip_requested.connect(skip_game)
	_controls_window.restart_requested.connect(restart_game)
	_controls_window.remove_requested.connect(remove_game)
	_controls_window.stop_requested.connect(stop_session)
	var w = _controls_window
	w.tree_exited.connect(func():
		if _controls_window == w:
			_controls_window = null
		# The palette is a transient pause menu: dismissing it resumes the round.
		resume_session()
		# Gamescope presents the focused window; once the palette menu closes,
		# hand focus back to the game (harmless if a choice/intro window is
		# about to map and take focus itself).
		if SystemManager.platform.is_gamemode() and (_state == State.ACTIVE or _state == State.PAUSED):
			var pid: int = _bag.entries[_current_game_index].pid if _current_game_index >= 0 and _current_game_index < _bag.entries.size() else -1
			if pid > 0:
				_maximize_with_retry.call_deferred(pid, _bag.entries[_current_game_index].emulator_id)
	)

	# The palette marks itself transient for the game window (gamescope draws
	# dialogs above their parent), so it needs the game's captured window XID
	# before _ready runs.
	if _current_game_index >= 0 and _current_game_index < _bag.entries.size():
		_controls_window.game_window_xid = _bag.entries[_current_game_index].get("window_xid", "")
	get_tree().root.add_child(_controls_window)
	# Summoning the palette pauses the shuffler timers automatically.
	pause_session()
	_controls_window.set_reroll_enabled(_controls_reroll_enabled)
	print("[ShufflerSubManager] Controls palette summoned: window_id=" + str(_controls_window.get_window_id()) + " visible=" + str(_controls_window.visible))

# ============================================================================
# RETROARCH CONFIG
# ============================================================================

func _retroarch_shuffler_cfg_path() -> String:
	match SystemManager.platform.get_platform_name().to_lower():
		"windows":
			return "{home}/AppData/Roaming/RetroArch/retroarch.cfg"
		"linux", "freebsd", "netbsd", "openbsd", "bsd":
			return "{emulator_dir}/.config/retroarch/retroarch.cfg"
		"android":
			return "{app_data}/retroarch.cfg"
		_:
			return "{emulator_dir}/retroarch.cfg"


func _ensure_retroarch_shuffler_config() -> void:
	var edits: Array[Dictionary] = []
	for key in RETROARCH_SHUFFLER_CFG:
		var value: String = RETROARCH_SHUFFLER_CFG[key]
		edits.append({
			"old": r'%s\s*=\s*"[^"]*"' % key,
			"new": '%s = "%s"' % [key, value],
			"regex": true,
		})

	var cfg_path := _retroarch_shuffler_cfg_path()
	if not LaunchManager.edit_emulator_file_with_backup("retroarch", cfg_path, edits, true, RETROARCH_SHUFFLER_CFG, ""):
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
			if DEBUG_LOG: print("[ShufflerSubManager] Created portable.txt to force PCSX2 portable mode")

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
	if DEBUG_LOG: print("[ShufflerSubManager] PCSX2 shuffler config path: " + cfg_path)
	var content := FSM.read_file(cfg_path)
	var section_regex := RegEx.new()
	section_regex.compile(r"(?s)\[MemoryCards\].*?(?=\n\[|\Z)")
	var section_match := section_regex.search(content)
	if section_match:
		if DEBUG_LOG: print("[ShufflerSubManager] PCSX2 [MemoryCards] section:\n" + section_match.get_string().strip_edges())
	else:
		if DEBUG_LOG: print("[ShufflerSubManager] PCSX2 [MemoryCards] section not found")

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

		# Sentinel passed, so this install is shuffler-created: the license
		# rif folder installed alongside it is derived content and goes too.
		var license_path = entry.get("ux0_license_path", "") as String
		if license_path != "" and FSM.dir_exists(license_path):
			print("[ShufflerSubManager] Cleaning up Vita3K shuffler license folder: " + license_path)
			FSM.delete_dir_recursive(license_path)

	_shuffler_vita_apps.clear()

## PS3 counterpart of the Vita cleanup: desktop shuffler launches extract
## straight into the RPCS3 emulator dir (games/ or dev_hdd0/game/), which
## TEMP_DIR cleanup never reaches. Sentinel-guarded like the Vita path so a
## pre-existing (non-shuffler) install is never deleted.
func _cleanup_rpcs3_shuffler_games() -> void:
	for entry in _shuffler_ps3_games:
		for raw_path in entry.get("paths", []):
			var game_path := str(raw_path)
			if game_path == "" or not FSM.dir_exists(game_path):
				continue
			var sentinel_path = game_path + "/.kyodai_shuffler"
			if not FSM.file_exists(sentinel_path):
				push_warning("[ShufflerSubManager] Refusing to clean up RPCS3 game folder without sentinel: " + game_path)
				continue
			print("[ShufflerSubManager] Cleaning up RPCS3 shuffler game folder: " + game_path)
			FSM.delete_dir_recursive(game_path)

	_shuffler_ps3_games.clear()

func _cleanup_temp_files() -> void:
	if DirAccess.dir_exists_absolute(TEMP_DIR):
		FSM.delete_dir_recursive(TEMP_DIR)

func _restore_emulator_file_if_backed_up(emulator_id: String, file_path: String) -> void:
	if LaunchManager.has_emulator_file_backup(emulator_id, file_path):
		LaunchManager.restore_emulator_file(emulator_id, file_path)
	else:
		if DEBUG_LOG: print("[ShufflerSubManager] Skipping restore for " + emulator_id + " " + file_path + " (no backup)")
