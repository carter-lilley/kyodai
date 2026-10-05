extends Manager
class_name ProcessSubManager

## Process launch and background-state management

const DEBUG_LOG: bool = false
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const RSM = preload("res://managers/system_manager/resolution_sub_manager.gd")
const AndroidBinaryExtractor = preload("res://utils/android_binary_extractor.gd")

# Background state tracking (desktop only)
var _background_active_pid: int = -1
var _background_active_game: GameResource = null
var _background_active_signature: String = ""
var _background_active_exe_signature: String = ""
var _is_in_background_state: bool = false
# Linux AppImage launches fork a runtime wrapper (comm=AppRun, exe under /tmp/.mount_*)
# that outlives the actual emulator payload. We keep its PID so we can clean it up
# once the real emulator process is gone.
var _background_wrapper_pid: int = -1
var _background_poll_timer: Timer = null
var _poll_in_flight: bool = false
const BACKGROUND_POLL_INTERVAL: float = 1.0
# Game Mode (gamescope) tracks the game window rather than the process PID,
# because the compositor reparents/forks emulator wrappers in ways that defeat
# /proc polling. The XID is captured once and then polled for existence.
var _background_window_xid: String = ""
var _background_window_hint: String = ""

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

	# Initialize background state polling (desktop only)
	if not SystemManager.platform.is_android():
		_background_poll_timer = Timer.new()
		_background_poll_timer.wait_time = BACKGROUND_POLL_INTERVAL
		_background_poll_timer.one_shot = false
		_background_poll_timer.timeout.connect(_on_background_poll_timeout)
		add_child(_background_poll_timer)
		if DEBUG_LOG: print("[ProcessManager] Poll timer created, in_tree=", _background_poll_timer.is_inside_tree(), " wait=", _background_poll_timer.wait_time)


# ============================================================================
# SHELL ESCAPING HELPERS (prevent command injection from user-controlled paths)
# ============================================================================

## Escapes a string for safe use inside Windows cmd.exe double quotes.
## Inside a quoted cmd string only % and " need special handling:
##   - % is doubled to prevent environment-variable expansion.
##   - " is doubled because a pair of double quotes inside a quoted string
##     represents one literal double quote.
## Other cmd metacharacters (& | < > ^ ( )) are literal inside quotes,
## so escaping them with ^ would actually introduce literal carets into paths.
func _escape_cmd_meta(s: String) -> String:
	var result = s.replace("%", "%%")
	# Double quotes are escaped by doubling them inside a quoted string
	result = result.replace('"', '""')
	return result

## Escapes a string for safe use inside Unix sh single quotes.
## Wraps in single quotes and handles embedded single quotes.
func _escape_sh_arg(s: String) -> String:
	# Single quotes prevent ALL interpretation in sh
	# To embed a single quote, close the quote, add an escaped quote, reopen
	return "'" + s.replace("'", "'\"'\"'") + "'"

## Escapes an array of arguments for the current platform's shell.
func _escape_args_for_shell(args: Array) -> Array:
	var result = []
	if SystemManager.platform.is_windows():
		for arg in args:
			result.append('"' + _escape_cmd_meta(arg) + '"')
	else:
		for arg in args:
			result.append(_escape_sh_arg(arg))
	return result

# ============================================================================
# APPIMAGE ENVIRONMENT SANITIZATION
# ============================================================================

## Returns true if candidate path is inside (or equal to) app_dir.
func _is_within_app_dir(candidate: String, app_dir: String) -> bool:
	var norm_candidate = candidate.replace("\\", "/").rstrip("/")
	var norm_app_dir = app_dir.replace("\\", "/").rstrip("/")
	return norm_candidate == norm_app_dir or norm_candidate.begins_with(norm_app_dir + "/")

## Removes entries inside app_dir from a colon/space separated path variable.
func _clean_path_var(value: String, app_dir: String) -> String:
	if value == "":
		return ""
	# LD_PRELOAD may be space-separated; everything else uses colons.
	# Normalize whitespace to colons so a single split covers both cases.
	var normalized = value.replace(" ", ":").replace("\t", ":")
	var parts = normalized.split(":", false)
	var cleaned: Array[String] = []
	for part in parts:
		if _is_within_app_dir(part, app_dir):
			continue
		cleaned.append(part)
	return ":".join(cleaned)

## Builds env(1) arguments that strip Kyodai's AppImage identity and apply
## per-emulator overrides. Returns an empty array on non-Linux platforms.
func _build_linux_env_args(intent: LaunchIntent) -> Array[String]:
	if not SystemManager.platform.is_linux():
		return []

	var env_args: Array[String] = []

	# Strip AppImage identity variables so child emulators don't mistake
	# Kyodai's AppImage for their own.
	for var_name in ["APPIMAGE", "APPDIR", "ARGV0", "OWD"]:
		env_args.append("-u")
		env_args.append(var_name)

	# Clean PATH-like variables of entries bundled inside Kyodai's AppImage.
	var app_dir = OS.get_environment("APPDIR")
	if app_dir != "":
		var path_vars = [
			"PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PERLLIB",
			"XDG_DATA_DIRS", "GTK_PATH", "GIO_EXTRA_MODULES", "GI_TYPELIB_PATH",
			"GSETTINGS_SCHEMA_DIR", "GDK_PIXBUF_MODULE_FILE",
			"QT_PLUGIN_PATH", "QT_QPA_PLATFORM_PLUGIN_PATH",
			"QML_IMPORT_PATH", "QML2_IMPORT_PATH"
		]
		for var_name in path_vars:
			var value = OS.get_environment(var_name)
			if value == "":
				continue
			var cleaned = _clean_path_var(value, app_dir)
			if cleaned == value:
				continue
			if cleaned == "":
				env_args.append("-u")
				env_args.append(var_name)
			else:
				env_args.append(var_name + "=" + cleaned)

	# Apply per-emulator environment overrides from the launch config.
	for var_name in intent.environment:
		env_args.append(var_name + "=" + str(intent.environment[var_name]))

	return env_args

## Escapes env(1) arguments for safe use inside a sh single-quoted string.
func _escape_env_args_for_shell(args: Array[String]) -> String:
	var escaped: Array[String] = []
	for arg in args:
		escaped.append(_escape_sh_arg(arg))
	return " ".join(escaped)

## Escapes a string for safe use as a single-quoted PowerShell argument.
## In PS single quotes only the single quote itself needs escaping (doubled).
func _escape_ps_arg(s: String) -> String:
	return "'" + s.replace("'", "''") + "'"

## Escapes a string for use inside Start-Process -ArgumentList.
## PowerShell joins -ArgumentList entries with spaces WITHOUT re-quoting them,
## so each entry is additionally wrapped in literal double quotes to keep
## paths containing spaces intact on the target process command line.
func _escape_ps_arg_quoted(s: String) -> String:
	return "'\"" + s.replace("'", "''") + "\"'"

## Resolves the path to the x11_windowctl helper, extracting it from the
## package if running a shipped build so the binary is executable.
func _resolve_x11_windowctl_path() -> String:
	if SystemManager.platform.is_packaged():
		return AndroidBinaryExtractor.extract_binary("res://bin/linux/x11_windowctl", "x11_windowctl")
	return ProjectSettings.globalize_path("res://bin/linux/x11_windowctl")

# ==================== BACKGROUND STATE (DESKTOP ONLY) ====================

## Returns true if currently in background state (emulator running)
func is_in_background_state() -> bool:
	return _is_in_background_state

## Returns the active process PID, or -1 if none
func get_background_pid() -> int:
	return _background_active_pid

## Returns the active game during background state, or null
func get_background_game() -> GameResource:
	return _background_active_game

## Enter background state with active PID
func enter_background_state(pid: int, game: GameResource, intent: LaunchIntent = null) -> void:
	if _is_in_background_state:
		if DEBUG_LOG: print("[ProcessManager] Warning: Already in background state, ignoring new PID ", pid)
		return

	if pid <= 0:
		push_error("[ProcessManager] Invalid PID for background state: " + str(pid))
		return

	print("[ProcessManager] Entering background state with PID: ", pid)
	_background_active_pid = pid
	_background_wrapper_pid = -1
	_background_active_game = game
	_is_in_background_state = true
	_background_window_xid = ""
	_background_window_hint = ""
	if intent != null:
		_background_window_hint = intent.emulator_id

	# Build command-line signatures for /proc fallback scanning. The ROM path is
	# the most reliable signature because it appears in the actual emulator's
	# cmdline even when wrapper processes fork/reparent it away from us.
	if game != null and game.file_path != "":
		_background_active_signature = game.file_path
	elif intent != null and not intent.launch_args.is_empty():
		# Fallback: use the last launch argument, which is commonly the ROM path.
		_background_active_signature = intent.launch_args[-1]
	if intent != null and not intent.launch_args.is_empty():
		var exe_name := str(intent.launch_args[0]).get_file().get_basename().to_lower()
		if exe_name != "":
			_background_active_exe_signature = exe_name
	if DEBUG_LOG: print("[ProcessManager] Background signatures: rom=\"", _background_active_signature, "\" exe=\"", _background_active_exe_signature, "\"")

	if _background_poll_timer:
		if DEBUG_LOG: print("[ProcessManager] Starting poll timer, in_tree=", _background_poll_timer.is_inside_tree(), " active=", _background_poll_timer.is_stopped())
		_background_poll_timer.start()
		if DEBUG_LOG: print("[ProcessManager] Poll timer started")
	else:
		if DEBUG_LOG: print("[ProcessManager] Poll timer not available")

	launch_manager.background_state_entered.emit(pid, game)

## Enter background state for Android (no PID polling)
func enter_background_state_android(game: GameResource) -> void:
	if _is_in_background_state:
		if DEBUG_LOG: print("[ProcessManager] Warning: Already in background state, ignoring Android entry")
		return

	print("[ProcessManager] Entering background state for Android launch")
	_background_active_pid = -1  # No PID on Android
	_background_active_game = game
	_is_in_background_state = true

	# Don't start poll timer on Android - we rely on resume notification

	launch_manager.background_state_entered.emit(-1, game)

## Exit background state
func exit_background_state(exit_code: int = 0) -> void:
	if not _is_in_background_state:
		return

	print("[ProcessManager] Exiting background state. PID was: ", _background_active_pid)

	var game = _background_active_game

	if _background_poll_timer:
		_background_poll_timer.stop()

	# Clean up any Linux AppImage runtime wrapper that outlived the payload.
	if _background_wrapper_pid > 0:
		if DEBUG_LOG: print("[ProcessManager] Terminating AppImage wrapper PID ", _background_wrapper_pid)
		OS.kill(_background_wrapper_pid)
		_background_wrapper_pid = -1

	_background_active_pid = -1
	_background_active_game = null
	_background_active_signature = ""
	_background_active_exe_signature = ""
	_background_window_xid = ""
	_background_window_hint = ""
	_is_in_background_state = false

	launch_manager.background_state_exited.emit(game, exit_code)

## Poll callback - check if process is still running (async: never blocks the main thread)
func _on_background_poll_timeout() -> void:
	if DEBUG_LOG: print("[ProcessManager] Poll timer fired")
	if not _is_in_background_state or _background_active_pid <= 0:
		if DEBUG_LOG: print("[ProcessManager] Poll skipped: in_background=", _is_in_background_state, " pid=", _background_active_pid)
		return
	if _poll_in_flight:
		if DEBUG_LOG: print("[ProcessManager] Poll skipped: previous check still in flight")
		return

	# Game Mode (gamescope): track the game window, not the PID. The compositor
	# reparents/forks emulator wrappers in ways that make /proc polling unreliable,
	# but the X11 window lifetime matches what the user actually sees.
	if SystemManager.platform.is_gamemode():
		_poll_in_flight = true
		_poll_gamemode_window(func(exists: bool):
			_poll_in_flight = false
			if not _is_in_background_state:
				return
			if DEBUG_LOG: print("[ProcessManager] Gamemode window poll result: exists=", exists)
			if not exists:
				exit_background_state(0)
		)
		return

	_poll_in_flight = true
	var pid = _background_active_pid
	if DEBUG_LOG: print("[ProcessManager] Polling PID ", pid)
	_is_process_running_async(pid, func(running: bool):
		# Background state may have changed while the check was in flight
		if not _is_in_background_state or _background_active_pid != pid:
			_poll_in_flight = false
			if DEBUG_LOG: print("[ProcessManager] Poll result ignored: state changed")
			return
		if DEBUG_LOG: print("[ProcessManager] Poll result for PID ", pid, ": running=", running)
		# Linux AppImage wrappers (comm=AppRun, exe under /tmp/.mount_*) stay alive
		# after the real emulator payload exits. If we're tracking a wrapper, find
		# and switch to the actual payload process instead.
		if running and SystemManager.platform.is_linux() and _is_appimage_wrapper_pid(pid):
			if DEBUG_LOG: print("[ProcessManager] Tracked PID ", pid, " is an AppImage wrapper; searching for payload")
			var payload_pid := _find_process_by_signature()
			if payload_pid > 0 and payload_pid != pid:
				if DEBUG_LOG: print("[ProcessManager] AppImage payload found at PID ", payload_pid, "; wrapper PID ", pid, " will be cleaned up on exit")
				_background_wrapper_pid = pid
				_background_active_pid = payload_pid
				_poll_in_flight = false
				return
		if running:
			_poll_in_flight = false
			return
		# PID is gone or zombie. On Linux, fall back to scanning /proc by the
		# ROM/cmdline signature in case the emulator process was reparented
		# away from the wrapper we were tracking.
		if SystemManager.platform.is_linux() and (_background_active_signature != "" or _background_active_exe_signature != ""):
			if DEBUG_LOG: print("[ProcessManager] PID ", pid, " not running; scanning /proc by signature")
			var found_pid := _find_process_by_signature()
			if found_pid > 0 and found_pid != pid:
				if DEBUG_LOG: print("[ProcessManager] Reparented emulator found at PID ", found_pid, "; updating tracker")
				_background_active_pid = found_pid
				_poll_in_flight = false
				return
			elif found_pid > 0:
				if DEBUG_LOG: print("[ProcessManager] Signature still matches PID ", pid, " (zombie?), keeping background state")
				_poll_in_flight = false
				return
			else:
				if DEBUG_LOG: print("[ProcessManager] No signature match found in /proc")
		_poll_in_flight = false
		if DEBUG_LOG: print("[ProcessManager] Process ", pid, " no longer running")
		exit_background_state(0)
	)

## Poll callback for Game Mode (gamescope): track the game window by XID.
## Captures the XID on the first call if needed, then checks whether it still
## exists. Calls back with true while the window is alive, false once it closes.
func _poll_gamemode_window(callback: Callable) -> void:
	var tool := _resolve_x11_windowctl_path()
	if tool == "" or not FileAccess.file_exists(tool):
		push_warning("[ProcessManager] x11_windowctl not available in gamemode; falling back to PID poll")
		callback.call(true)
		return

	if _background_window_xid == "":
		# First poll: try to find the game window. We may need a few attempts
		# while the emulator is still starting up.
		var args: Array = ["find", str(_background_active_pid)]
		if _background_window_hint != "":
			args.append(_background_window_hint)
		MemorySubManager.queue_os_execute(tool, args, func(result: Dictionary):
			if not _is_in_background_state:
				callback.call(true)
				return
			if result.get("exit_code", -1) != 0:
				if DEBUG_LOG: print("[ProcessManager] Gamemode window not found yet; will retry")
				callback.call(true)
				return
			var output: Array = result.get("output", [])
			var text := ("".join(output)).strip_edges()
			var xid := ""
			for line: String in text.split("\n", false):
				var l := line.strip_edges().to_lower()
				if l.length() > 0 and l.is_valid_hex_number(false):
					xid = l
			if xid == "":
				callback.call(true)
				return
			_background_window_xid = xid
			print("[ProcessManager] Gamemode captured game window xid: ", xid)
			callback.call(true)
		)
	else:
		# Subsequent polls: check if the captured window still exists.
		MemorySubManager.queue_os_execute(tool, ["exists", "xid:" + _background_window_xid], func(result: Dictionary):
			if not _is_in_background_state:
				callback.call(true)
				return
			var exit_code: int = result.get("exit_code", -1)
			callback.call(exit_code == 0)
		)

## Scans /proc for a live (non-zombie) emulator process whose cmdline contains
## the stored launch signature (usually the ROM path). This catches emulators
## that were reparented away from the wrapper PID Kyodai was tracking.
func _find_process_by_signature() -> int:
	if _background_active_signature == "" and _background_active_exe_signature == "":
		return -1

	if not SystemManager.platform.is_linux():
		return -1

	var proc_dir := DirAccess.open("/proc")
	if proc_dir == null:
		return -1

	var best_pid := -1
	var filename_signature := ""
	if _background_active_signature != "":
		filename_signature = _background_active_signature.get_file()
		if filename_signature == _background_active_signature:
			filename_signature = ""

	proc_dir.list_dir_begin()
	var entry := proc_dir.get_next()
	while entry != "":
		if entry.is_valid_int():
			var scan_pid := entry.to_int()
			if scan_pid > 0:
				var stat := _parse_proc_stat(scan_pid)
				if stat.ok and stat.state != "Z" and not _is_appimage_wrapper_pid(scan_pid):
					var cmdline := _get_process_cmdline(scan_pid)
					if _background_active_signature != "" and cmdline.find(_background_active_signature) != -1:
						if DEBUG_LOG: print("[ProcessManager] Signature match in cmdline for PID ", scan_pid, ": ", cmdline)
						best_pid = scan_pid
						break
					if filename_signature != "" and cmdline.find(filename_signature) != -1:
						if DEBUG_LOG: print("[ProcessManager] Filename signature match in cmdline for PID ", scan_pid, ": ", cmdline)
						best_pid = scan_pid
						break
					if _background_active_exe_signature != "" and cmdline.to_lower().find(_background_active_exe_signature) != -1:
						if DEBUG_LOG: print("[ProcessManager] Exe-signature match in cmdline for PID ", scan_pid, ": ", cmdline)
						best_pid = scan_pid
						break
					if _background_active_exe_signature != "":
						var exe_link := "/proc/" + str(scan_pid) + "/exe"
						if FileAccess.file_exists(exe_link):
							var exe_path := proc_dir.read_link(exe_link)
							if exe_path != "":
								var exe_base := exe_path.get_file().get_basename().to_lower()
								if exe_base == _background_active_exe_signature or exe_base.contains(_background_active_exe_signature):
									if DEBUG_LOG: print("[ProcessManager] Exe-signature match for PID ", scan_pid, ": ", exe_path)
									best_pid = scan_pid
									break
		entry = proc_dir.get_next()
	proc_dir.list_dir_end()

	return best_pid

## Async process liveness check; callback receives `running: bool` on the main thread.
func _is_process_running_async(pid: int, callback: Callable) -> void:
	if pid <= 0:
		callback.call(false)
		return

	# Linux fast path: /proc check is effectively free, no process spawn needed.
	# Also parse /proc/{pid}/stat so we don't treat zombie (defunct) processes
	# as still running — OS.create_process can leave children unreaped.
	if SystemManager.platform.is_linux():
		var stat := _parse_proc_stat(pid)
		if stat.ok:
			if DEBUG_LOG: print("[ProcessManager] /proc/" + str(pid) + "/stat state=" + stat.state)
			if stat.state == "Z":
				if DEBUG_LOG: print("[ProcessManager] PID " + str(pid) + " is a zombie, treating as not running")
				callback.call(false)
				return
			callback.call(true)
			return
		else:
			if DEBUG_LOG: print("[ProcessManager] /proc/" + str(pid) + "/stat does not exist or is unreadable")
			callback.call(false)
			return

	if SystemManager.platform.is_windows():
		MemorySubManager.queue_os_execute("tasklist", ["/FI", "PID eq " + str(pid), "/NH"], func(result: Dictionary):
			var output: Array = result.get("output", [])
			var running = false
			if result.get("exit_code", -1) == 0 and output.size() > 0:
				var text = str(output[0]).strip_edges()
				running = text != "" and not text.begins_with("INFO:")
			callback.call(running)
		)
	else:
		MemorySubManager.queue_os_execute("ps", ["-p", str(pid)], func(result: Dictionary):
			callback.call(result.get("exit_code", -1) == 0)
		)


## Awaitable variant of _is_process_running_async. Returns true if running.
func is_running_async(pid: int) -> bool:
	var state := {"completed": false, "running": false}
	_is_process_running_async(pid, func(running: bool):
		state["completed"] = true
		state["running"] = running
	)
	while not state["completed"]:
		await get_tree().process_frame
	return state["running"]

## Kills a process by PID without blocking the main thread.
func kill_process_async(pid: int) -> void:
	if pid <= 0:
		return
	if SystemManager.platform.is_windows():
		MemorySubManager.queue_os_execute("taskkill", ["/F", "/PID", str(pid)])
	else:
		MemorySubManager.queue_os_execute("kill", ["-9", str(pid)])

## Waits until the process exits (or timeout). Returns true if confirmed dead.
func confirm_process_dead_async(pid: int, timeout_sec: float = 5.0) -> bool:
	var elapsed := 0.0
	while elapsed < timeout_sec:
		var running = await is_running_async(pid)
		if not running:
			return true
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	return false

## Suspends a process via pssuspend (Windows only; path supplied by caller).
## on_done(result: Dictionary {exit_code, output}) fires on the main thread
## when pssuspend exits - callers that must not race the suspended process
## (e.g. launching a new emulator instance) should await it.
func suspend_process_async(pid: int, pssuspend_path: String, on_done: Callable = Callable()) -> void:
	if pid <= 0:
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	if SystemManager.platform.is_windows():
		if pssuspend_path == "":
			if on_done.is_valid():
				on_done.call({"exit_code": -1, "output": []})
			return
		MemorySubManager.queue_os_execute(pssuspend_path, ["-accepteula", str(pid)], on_done)
	elif OS.get_name() == "Linux" or OS.get_name().ends_with("BSD"):
		MemorySubManager.queue_os_execute("kill", ["-STOP", str(pid)], on_done)
	else:
		push_warning("[ProcessManager] suspend_process_async is only supported on Windows and Linux/BSD")
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})

## Resumes a suspended process via pssuspend (Windows) or kill -CONT (Linux/BSD).
func resume_process_async(pid: int, pssuspend_path: String, on_done: Callable = Callable()) -> void:
	if pid <= 0:
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	if SystemManager.platform.is_windows():
		if pssuspend_path == "":
			if on_done.is_valid():
				on_done.call({"exit_code": -1, "output": []})
			return
		MemorySubManager.queue_os_execute(pssuspend_path, ["-accepteula", "-r", str(pid)], on_done)
	elif OS.get_name() == "Linux" or OS.get_name().ends_with("BSD"):
		MemorySubManager.queue_os_execute("kill", ["-CONT", str(pid)], on_done)
	else:
		push_warning("[ProcessManager] resume_process_async is only supported on Windows and Linux/BSD")
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})

## Force exit background state (for crashes/emergencies)
func force_exit_background_state() -> void:
	print("[ProcessManager] Force exiting background state")
	exit_background_state(-1)

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	print("[ProcessManager] execute_launch called for emulator: ", intent.emulator_id if intent else "<null>")
	if not intent or not intent.is_valid():
		push_error("[ProcessManager] Invalid launch intent")
		return false

	# Check if emulator is fully installed (cached scan, see _is_emulator_fully_installed)
	var is_actually_installed: bool = launch_manager.emulator.get_install_progress(intent.emulator_id).get("is_installed", false)

	if not is_actually_installed:
		push_error("[ProcessManager] Emulator not fully installed: " + intent.emulator_id)
		SystemManager.notifications.show_notification("Emulator not ready: " + intent.emulator_name, SystemManager.notifications.Type.ERROR)
		return false

	if SystemManager.platform.is_android():
		return _execute_android(intent)
	else:
		return await _execute_desktop(intent)

func _execute_desktop(intent: LaunchIntent) -> bool:
	if DEBUG_LOG: print("[ProcessManager] _execute_desktop called")
	if intent.launch_args.is_empty():
		push_error("[ProcessManager] No launch arguments for desktop")
		return false

	var pid = await _create_desktop_process(intent)
	if pid == -1:
		launch_manager.launch_completed.emit(false, "Failed to start emulator")
		return false

	# Store PID and enter background state for desktop
	enter_background_state(pid, intent.game, intent)

	launch_manager.launch_completed.emit(true, "Game launched successfully")
	return true

## Creates a process from a launch intent without entering background state.
## Coroutine: returns the PID or -1 on failure.
func _create_process_from_intent(intent: LaunchIntent) -> int:
	return await _create_desktop_process(intent)

## Removes a stale portable config that points to the wrong home directory
## (e.g. /home/user/... on /home/carter). The file is backed up first so the
## user can restore it if needed. Returns true if a stale config was reset.
func _sanitize_portable_config(portable_root: String) -> bool:
	var config_dir := FSM.join_paths(portable_root, "user", "config")
	var candidates := ["qt-config.ini", "config.ini"]
	var current_home := OS.get_environment("HOME")
	if current_home == "":
		return false
	current_home = current_home.rstrip("/")
	
	for file_name in candidates:
		var config_path := FSM.join_paths(config_dir, file_name)
		if not FSM.file_exists(config_path):
			continue
		var text := FSM.read_file(config_path)
		var stale := false
		for line in text.split("\n"):
			# Look for absolute Unix home paths that aren't the current home.
			var idx := line.find("/home/")
			if idx < 0:
				continue
			var path_end := line.find(" ", idx)
			if path_end < 0:
				path_end = line.length()
			var candidate := line.substr(idx, path_end - idx).strip_edges()
			# Drop trailing slash/quote chars
			while not candidate.is_empty() and candidate[-1] in ['"', "'", "/"]:
				candidate = candidate.substr(0, candidate.length() - 1)
			if candidate == current_home or candidate.begins_with(current_home + "/"):
				continue
			stale = true
			break
		
		if stale:
			var backup_path := config_path + ".kyodai-stale-backup"
			FSM.write_file(backup_path, text)
			FSM.delete_file(config_path)
			print("[ProcessManager] Reset stale portable config: %s (backup: %s)" % [config_path, backup_path])
			return true
	return false

## Shared desktop process creation. Coroutine: returns the REAL emulator PID
## (never a shell-wrapper PID) or -1 on failure.
func _create_desktop_process(intent: LaunchIntent) -> int:
	if intent.launch_args.is_empty():
		push_error("[ProcessManager] No launch arguments for desktop")
		return -1

	var exe_path = intent.launch_args[0]
	var arguments = intent.launch_args.slice(1)
	var pid: int = -1

	# Enforce Kyodai-managed data paths in the emulator config before launching.
	# This is the writing side of the config resolver: the same strategy that
	# reads save/firmware locations now writes them so managed and unmanaged
	# installs use the same directories.
	if not RSM.enforce_paths(intent.emulator_id, intent.platform_slug, intent.core_name):
		push_warning("[ProcessManager] Could not enforce config paths for %s" % intent.emulator_id)

	var linux_env_args = _build_linux_env_args(intent)
	var use_env_wrapper = SystemManager.platform.is_linux() and not linux_env_args.is_empty()
	
	# Portable-mode handshake: emulators like Eden/Azahar trigger portable mode
	# when their working directory contains a user/ folder. If the requested
	# working directory does not contain user/, fall back to the executable's
	# directory so unmanaged installs use their native config paths.
	var effective_working_dir := intent.working_directory
	if effective_working_dir != "":
		if FSM.dir_exists(FSM.join_paths(effective_working_dir, "user")):
			# We are forcing portable mode; reset any stale config that points
			# to a different home directory so the emulator regenerates it.
			_sanitize_portable_config(effective_working_dir)
		else:
			if DEBUG_LOG: print("[ProcessManager] No user/ in requested working dir '%s'; falling back to exe dir" % effective_working_dir)
			effective_working_dir = exe_path.get_base_dir().replace("//", "/")

	# Existence guard: a missing working dir makes the shell wrappers' `cd` (or
	# PowerShell's -WorkingDirectory) fail before the emulator ever starts.
	# Fall back to the exe dir, then to the process default working dir.
	if effective_working_dir != "" and not FSM.dir_exists(effective_working_dir):
		push_warning("[ProcessManager] Working dir does not exist, falling back: " + effective_working_dir)
		effective_working_dir = exe_path.get_base_dir().replace("//", "/")
	if effective_working_dir != "" and not FSM.dir_exists(effective_working_dir):
		push_warning("[ProcessManager] Exe dir missing too, using default working dir: " + effective_working_dir)
		effective_working_dir = ""
	
	print("[ProcessManager] Creating desktop process for: ", exe_path)
	if DEBUG_LOG: print("[ProcessManager] launch args: ", arguments)
	if DEBUG_LOG: print("[ProcessManager] working directory: ", effective_working_dir)
	if DEBUG_LOG: print("[ProcessManager] linux env args: ", linux_env_args, " use_env_wrapper=", use_env_wrapper)

	if effective_working_dir == "" and not use_env_wrapper:
		# No working directory needed and no env sanitization: call executable directly
		# (no shell, no injection risk)
		if DEBUG_LOG: print("[ProcessManager] Direct launch: exe=", exe_path, " args=", arguments)
		pid = OS.create_process(exe_path, arguments, false)
		print("[ProcessManager] Direct launch returned pid: ", pid)
	elif effective_working_dir == "" and use_env_wrapper:
		# Linux with env sanitization: wrap env(1) in sh -c with exec so the
		# shell replaces itself with env, which then replaces itself with the
		# emulator. Calling env directly as the OS.create_process executable
		# can cause some AppRun scripts (e.g. Eden) to exit immediately when
		# backgrounded, because the intermediate non-exec parent changes the
		# process/session relationship the child sees.
		var safe_args = _escape_args_for_shell(arguments)
		var safe_exe = _escape_sh_arg(exe_path)
		var env_prefix = _escape_env_args_for_shell(linux_env_args) + " "
		# Capture stdout/stderr to a log file. This both gives us a diagnostic
		# trace if the emulator crashes, and provides the child with real open
		# file descriptors instead of whatever closed/socket fds the parent
		# Godot process happens to have inherited.
		var launch_log := FSM.resolve_path(
			FSM.resolve_emulator_path("launch.log", intent.emulator_id),
			{"format": FSM.PathFormat.ABSOLUTE}
		)
		var safe_log := _escape_sh_arg(launch_log)
		var inner_cmd = 'exec env %s%s %s > %s 2>&1' % [env_prefix, safe_exe, " ".join(safe_args), safe_log]
		if DEBUG_LOG: print("[ProcessManager] env launch via sh: sh -c ", inner_cmd)
		pid = OS.create_process("sh", ["-c", inner_cmd], false)
		print("[ProcessManager] env launch via sh returned pid: ", pid)
	elif not SystemManager.platform.is_windows():
		# Linux: sh -c with exec, so the shell REPLACES itself with the
		# emulator and the returned PID is the emulator's own PID.
		var safe_args = _escape_args_for_shell(arguments)
		var safe_working_dir = _escape_sh_arg(effective_working_dir)
		var safe_exe = _escape_sh_arg(exe_path)
		var env_prefix = _escape_env_args_for_shell(linux_env_args) + " " if use_env_wrapper else ""
		var launch_log := FSM.resolve_path(
			FSM.resolve_emulator_path("launch.log", intent.emulator_id),
			{"format": FSM.PathFormat.ABSOLUTE}
		)
		var safe_log := _escape_sh_arg(launch_log)
		var inner_cmd = 'cd %s && exec env %s%s %s > %s 2>&1' % [safe_working_dir, env_prefix, safe_exe, " ".join(safe_args), safe_log]
		if DEBUG_LOG: print("[ProcessManager] shell launch: sh -c ", inner_cmd)
		pid = OS.create_process("sh", ["-c", inner_cmd], false)
		print("[ProcessManager] shell launch returned pid: ", pid)
	else:
		# Windows: Start-Process sets the working directory AND reports the real
		# child PID via -PassThru (a cmd /c wrapper would return cmd.exe's PID)
		var ps_arg_list: Array[String] = []
		for arg in arguments:
			ps_arg_list.append(_escape_ps_arg_quoted(arg))
		var ps_command = "Start-Process -FilePath %s -WorkingDirectory %s" % [_escape_ps_arg(exe_path), _escape_ps_arg(effective_working_dir)]
		if not ps_arg_list.is_empty():
			ps_command += " -ArgumentList " + ",".join(ps_arg_list)
		ps_command += " -PassThru | Select-Object -ExpandProperty Id"
		if DEBUG_LOG: print("[ProcessManager] PowerShell launch: ", ps_command)

		var spawn_state := {"completed": false, "pid": -1}
		MemorySubManager.queue_os_execute("powershell", ["-NoProfile", "-Command", ps_command], func(result: Dictionary):
			spawn_state["completed"] = true
			if result.get("exit_code", -1) == 0:
				var output: Array = result.get("output", [])
				# Take the last non-empty output line as the PID
				for i in range(output.size() - 1, -1, -1):
					var line = str(output[i]).strip_edges()
					if line != "":
						spawn_state["pid"] = line.to_int()
						break
		)
		while not spawn_state["completed"]:
			await get_tree().process_frame
		pid = spawn_state["pid"]
		print("[ProcessManager] PowerShell launch returned pid: ", pid)

		if pid <= 0:
			# Fallback: cmd /c wrapper (tracks the wrapper PID, not the emulator)
			push_warning("[ProcessManager] PowerShell launch failed, falling back to cmd wrapper (PID tracking will follow cmd.exe)")
			var safe_args = _escape_args_for_shell(arguments)
			var safe_working_dir = _escape_cmd_meta(effective_working_dir)
			var safe_exe = _escape_cmd_meta(exe_path)
			var inner_cmd = 'cd /d "%s" && "%s" %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			if DEBUG_LOG: print("[ProcessManager] Executing command: cmd /c ", inner_cmd)
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)
			print("[ProcessManager] cmd fallback returned pid: ", pid)

	if pid == -1:
		push_error("[ProcessManager] Failed to launch process: " + exe_path)
		return -1

	# AppImage runtimes and env(1) wrappers often leave a parent process alive
	# even after the emulator window closes. Wait briefly for the real emulator
	# process to appear and discover it by walking the process tree.
	await get_tree().create_timer(0.3).timeout
	pid = _discover_emulator_pid(pid, arguments)

	return pid

## Reads a /proc virtual file whose reported size is 0. Godot's
## FileAccess.get_file_as_string() returns empty for such files, so we read
## chunks until EOF.
func _read_proc_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = []
	while not f.eof_reached():
		var chunk = f.get_buffer(1024)
		if chunk.size() == 0:
			break
		bytes.append_array(chunk)
	f.close()
	return bytes.get_string_from_utf8()

## Parses /proc/<pid>/stat and returns a dictionary with commonly-needed
## fields. The command name is wrapped in parentheses and may contain spaces
## or closing parens, so we locate the last ')' and split the remaining
## whitespace-delimited fields.
func _parse_proc_stat(pid: int) -> Dictionary:
	var result := {
		"ok": false,
		"state": "",
	}
	if pid <= 0:
		return result
	var content := _read_proc_file("/proc/" + str(pid) + "/stat")
	if content == "":
		return result
	var close_paren := content.rfind(")")
	if close_paren == -1:
		return result
	var tail := content.substr(close_paren + 1).strip_edges()
	var fields := tail.split(" ", false)
	# Field 0 after ')' is the process state.
	if fields.size() >= 1:
		result["ok"] = true
		result["state"] = fields[0]
	return result

## Reads immediate child PIDs of a process from /proc.
func _get_process_children(pid: int) -> Array[int]:
	var children: Array[int] = []
	if pid <= 0:
		return children
	var path = "/proc/" + str(pid) + "/task/" + str(pid) + "/children"
	var content = _read_proc_file(path).strip_edges()
	if content == "":
		return children
	for part in content.split(" ", false):
		var child_pid = part.to_int()
		if child_pid > 0:
			children.append(child_pid)
	return children

## Reads the command line of a process.
func _get_process_cmdline(pid: int) -> String:
	if pid <= 0:
		return ""
	var path = "/proc/" + str(pid) + "/cmdline"
	var content = _read_proc_file(path)
	# Replace null bytes with spaces
	var bytes = content.to_utf8_buffer()
	for i in range(bytes.size()):
		if bytes[i] == 0:
			bytes[i] = 32  # space
	return bytes.get_string_from_utf8().strip_edges()

## Reads the short command name (comm) of a process from /proc/<pid>/comm.
func _get_process_comm(pid: int) -> String:
	if pid <= 0:
		return ""
	return _read_proc_file("/proc/" + str(pid) + "/comm").strip_edges()

## Returns true if the given PID is a Linux AppImage runtime wrapper.
## These wrappers (commonly comm="AppRun", exe under /tmp/.mount_*) fork the
## real emulator payload and stay alive to manage the FUSE mount, so they must
## not be mistaken for the emulator process itself.
func _is_appimage_wrapper_pid(pid: int) -> bool:
	if pid <= 0 or not SystemManager.platform.is_linux():
		return false
	if _get_process_comm(pid) == "AppRun":
		return true
	var exe_link := "/proc/" + str(pid) + "/exe"
	if FileAccess.file_exists(exe_link):
		var exe_path := DirAccess.open("/proc").read_link(exe_link) if DirAccess.open("/proc") != null else ""
		if exe_path != "" and exe_path.begins_with("/tmp/.mount_"):
			return true
	return false

## Reads the parent PID from /proc/<pid>/status.
func _get_parent_pid(pid: int) -> int:
	if pid <= 0:
		return 0
	var path = "/proc/" + str(pid) + "/status"
	var content = _read_proc_file(path)
	for line in content.split("\n", false):
		if line.begins_with("PPid:"):
			var parts = line.split(":", false)
			if parts.size() >= 2:
				return parts[1].strip_edges().to_int()
	return 0

## Computes how many parent-child hops target_pid is below initial_pid.
func _pid_depth(initial_pid: int, target_pid: int) -> int:
	var depth := 0
	var current := target_pid
	while current > 0 and current != initial_pid:
		current = _get_parent_pid(current)
		depth += 1
		if depth > 20:  # Safety break
			break
	if current == initial_pid:
		return depth
	return 0

## Recursively collects all descendant PIDs of a process.
func _collect_descendants(pid: int, collected: Dictionary = {}) -> void:
	if collected.has(pid):
		return
	collected[pid] = true
	for child in _get_process_children(pid):
		_collect_descendants(child, collected)

## Tries to find the actual emulator PID under the initial wrapper PID.
## Returns the best candidate (deepest descendant whose cmdline matches the
## launch arguments) or the initial PID if no better candidate is found.
func _discover_emulator_pid(initial_pid: int, launch_args: Array) -> int:
	if initial_pid <= 0:
		return initial_pid

	var initial_cmdline := _get_process_cmdline(initial_pid)
	if DEBUG_LOG: print("[ProcessManager] Initial PID ", initial_pid, " cmdline=\"", initial_cmdline, "\"")

	var descendants := {}
	_collect_descendants(initial_pid, descendants)
	descendants.erase(initial_pid)  # Don't include the wrapper itself

	if descendants.is_empty():
		if DEBUG_LOG: print("[ProcessManager] No child processes found under PID ", initial_pid, ", using initial PID")
		return initial_pid

	# Signature from launch arguments (excluding the executable path) so we can
	# match the real emulator even when the executable name changes (AppRun -> retroarch).
	var arg_signature := ""
	if launch_args.size() > 1:
		arg_signature = " ".join(launch_args.slice(1))

	var best_pid := initial_pid
	var best_depth := 0
	for pid in descendants.keys():
		var depth := _pid_depth(initial_pid, pid)
		var cmdline := _get_process_cmdline(pid)
		if DEBUG_LOG: print("[ProcessManager] Descendant PID ", pid, " depth=", depth, " cmdline=\"", cmdline, "\"")
		if arg_signature != "" and cmdline.contains(arg_signature):
			if best_pid == initial_pid or depth > best_depth:
				best_pid = pid
				best_depth = depth
		elif best_pid == initial_pid:
			# Fallback: deepest leaf if no argument match yet
			if depth > best_depth:
				best_pid = pid
				best_depth = depth

	if best_pid != initial_pid:
		print("[ProcessManager] Discovered emulator PID ", best_pid, " (initial was ", initial_pid, ")")
		return best_pid

	# Final fallback: the emulator may have already been reparented away from the
	# wrapper (e.g. AppImage runtime). Scan all of /proc for a live process whose
	# cmdline contains the launch argument signature.
	if arg_signature != "":
		var proc_dir := DirAccess.open("/proc")
		if proc_dir != null:
			proc_dir.list_dir_begin()
			var entry := proc_dir.get_next()
			while entry != "":
				if entry.is_valid_int():
					var scan_pid := entry.to_int()
					if scan_pid > 0 and scan_pid != initial_pid:
						var stat := _parse_proc_stat(scan_pid)
						if stat.ok and stat.state != "Z":
							var cmdline := _get_process_cmdline(scan_pid)
							if cmdline.contains(arg_signature):
								print("[ProcessManager] Discovered reparented emulator PID ", scan_pid, " via /proc scan")
								proc_dir.list_dir_end()
								return scan_pid
				entry = proc_dir.get_next()
			proc_dir.list_dir_end()

	print("[ProcessManager] Could not match child cmdline, keeping initial PID ", initial_pid)
	return initial_pid

func _execute_android(intent: LaunchIntent) -> bool:
	# Enforce Kyodai-managed data paths in the emulator's writable config, when
	# the emulator exposes one (e.g. ARMSX2's armsx2-settings.json). Failures are
	# logged but do not block the launch because many Android apps keep their
	# settings inside private app data Kyodai cannot reach.
	if not RSM.enforce_paths(intent.emulator_id, intent.platform_slug, intent.core_name):
		push_warning("[ProcessManager] Could not enforce config paths for Android emulator %s" % intent.emulator_id)

	var plugin = Engine.get_singleton("PackageChecker")
	if plugin == null:
		push_error("[ProcessManager] PackageChecker plugin not available for Android launch")
		return false

	# Check if we need MANAGE_EXTERNAL_STORAGE permission for FileProvider to work with SD cards
	if not plugin.hasManageExternalStoragePermission():
		push_warning("[ProcessManager] MANAGE_EXTERNAL_STORAGE permission not granted - FileProvider may fail for SD card files")
		# Show dialog to user explaining they need to grant the permission manually
		if UIManager:
			UIManager.show_alert("Permission Required", "To launch games from SD card storage, Kyodai needs 'All Files Access' permission.\n\nPlease grant this permission in Settings → Apps → Kyodai → Permissions → Files",
				func(): plugin.requestManageExternalStoragePermission(),
				Callable(),
				{"ok_text": "Open Settings"}
			)
		return false

	# Format the core path for RetroArch
	var core_path = ""

	# Check if using CoreSideloadActivity (for testing sideloaded cores)
	if intent.android_class == "com.retroarch.browser.debug.CoreSideloadActivity":
		# Use downloaded core from emulator directory
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Cores are downloaded to {emulator_dir}/cores
			var _emulator_dir = launch_manager.registry._get_emulator_directory(intent.emulator_id)
			# Use real filesystem path - with MANAGE_EXTERNAL_STORAGE, RetroArch can read directly
			core_path = FSM.resolve_emulator_path("cores/" + core_filename, intent.emulator_id, "", FSM.PathFormat.ABSOLUTE)
			if DEBUG_LOG: print("[ProcessManager] Core path for sideload: " + core_path)
	else:
		# Regular RetroArch launch - use internal core path
		if intent.core_name != "":
			var core_filename = intent.core_name + "_libretro_android.so"
			# Build core path using the actual package name from intent
			var retroarch_package = intent.android_package
			if retroarch_package != "":
				core_path = "/data/data/" + retroarch_package + "/cores/" + core_filename
			else:
				# Fallback if package name is somehow empty
				core_path = "/data/data/com.retroarch/cores/" + core_filename

	# Resolve ROM path to absolute filesystem path for the Java plugin.
	# The plugin creates File objects directly, so user:// virtual paths won't work.
	var absolute_rom_path = FSM.resolve_path(intent.rom_path, {"format": FSM.PathFormat.ABSOLUTE})
	print("[ProcessManager] Resolved ROM path for Android intent: " + absolute_rom_path)

	# Get configuration from android_config
	var rom_delivery = intent.android_config.get("rom_delivery", "intent_data")
	var mime_type = intent.android_config.get("mime_type", "application/octet-stream")
	var clear_task = intent.android_config.get("clear_task", true)
	var grant_uri_permission = intent.android_config.get("grant_uri_permission", true)
	var use_document_uri = intent.android_config.get("use_document_uri", false)
	var use_file_uri = intent.android_config.get("use_file_uri", false)

	# Convert extras array to JSON string
	var extras_array = intent.android_extras
	if extras_array.is_empty() and intent.android_config.has("extras"):
		extras_array = intent.android_config.get("extras", [])

	# Convert extras to JSON using proper JSON.stringify to handle escaping correctly
	# Replace {core_path} placeholder with actual core path
	var extras_json = "[]"
	if extras_array.size() > 0:
		var extras_to_serialize = []
		for extra in extras_array:
			var value = extra.get("value", "")
			if value.contains("{core_path}"):
				value = value.replace("{core_path}", core_path)
				if DEBUG_LOG: print("[ProcessManager] Replaced {core_path} with: " + core_path)

			extras_to_serialize.append({
				"key": extra.get("key", ""),
				"value": value,
				"type": extra.get("type", "string")
			})
		var json_result = JSON.stringify(extras_to_serialize)
		if json_result == "":
			push_error("[ProcessManager] Failed to serialize extras to JSON")
		else:
			extras_json = json_result

	# Launch using unified method
	var success = plugin.call("launchAndroidIntent",
		intent.android_action,
		intent.android_package,
		intent.android_class,
		absolute_rom_path,
		core_path,
		rom_delivery,
		extras_json,
		mime_type,
		clear_task,
		grant_uri_permission,
		use_document_uri,
		use_file_uri
	)

	if not success:
		push_error("[ProcessManager] Failed to launch Android intent")
		return false

	# Enter background state for Android - we track the game and exit on resume
	enter_background_state_android(intent.game)

	return true

## Shows a reminder dialog on Android after APK installation
## Prompts the user to open the newly installed emulator and grant permissions
func _show_android_permissions_reminder(emulator_id: String) -> void:
	# Only show on Android
	if SystemManager.platform.get_platform_name().to_lower() != "android":
		return

	var emulator = launch_manager.registry.get_emulator(emulator_id)
	var emulator_name = RegistrySubManager.get_emulator_display_name(emulator, emulator_id)

	# Don't stack a second reminder if one is already open for this emulator
	if launch_manager._open_install_reminders.has(emulator_id):
		print("[ProcessManager] Install reminder already open for: " + emulator_name)
		return

	launch_manager._open_install_reminders[emulator_id] = true

	# Create M3Dialog reminder as a distinct overlay type so it stacks above the settings dialog.
	# "Got it" routes through LaunchManager so a mid-game-launch pending launch can
	# resume (or abort) once the user acknowledges the reminder.
	UIManager.show_alert("Installation Reminder", "Please open " + emulator_name + " from your app drawer and grant any requested permissions (especially storage access) before launching games.",
		launch_manager.on_install_reminder_dismissed.bind(emulator_id),
		Callable(),
		{"ok_text": "Got it", "overlay_type": "alert", "overlay_layer": OverlayLayers.MENU, "dismissible": false}
	)

	print("[ProcessManager] Shown Android permissions reminder for: " + emulator_name)
