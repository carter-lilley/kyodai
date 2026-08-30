extends Manager
class_name ProcessSubManager

## Process launch and background-state management

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

# Background state tracking (desktop only)
var _background_active_pid: int = -1
var _background_active_game: GameResource = null
var _is_in_background_state: bool = false
var _background_poll_timer: Timer = null
var _poll_in_flight: bool = false
const BACKGROUND_POLL_INTERVAL: float = 1.0

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
func enter_background_state(pid: int, game: GameResource) -> void:
	if _is_in_background_state:
		print("[ProcessManager] Warning: Already in background state, ignoring new PID ", pid)
		return

	if pid <= 0:
		push_error("[ProcessManager] Invalid PID for background state: " + str(pid))
		return

	print("[ProcessManager] Entering background state with PID: ", pid)
	_background_active_pid = pid
	_background_active_game = game
	_is_in_background_state = true

	if _background_poll_timer:
		_background_poll_timer.start()

	launch_manager.background_state_entered.emit(pid, game)

## Enter background state for Android (no PID polling)
func enter_background_state_android(game: GameResource) -> void:
	if _is_in_background_state:
		print("[ProcessManager] Warning: Already in background state, ignoring Android entry")
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

	_background_active_pid = -1
	_background_active_game = null
	_is_in_background_state = false

	launch_manager.background_state_exited.emit(game, exit_code)

## Poll callback - check if process is still running (async: never blocks the main thread)
func _on_background_poll_timeout() -> void:
	if not _is_in_background_state or _background_active_pid <= 0:
		return
	if _poll_in_flight:
		return
	_poll_in_flight = true
	var pid = _background_active_pid
	_is_process_running_async(pid, func(running: bool):
		_poll_in_flight = false
		# Background state may have changed while the check was in flight
		if not _is_in_background_state or _background_active_pid != pid:
			return
		if not running:
			print("[ProcessManager] Process ", pid, " no longer running")
			exit_background_state(0)
	)

## Async process liveness check; callback receives `running: bool` on the main thread.
func _is_process_running_async(pid: int, callback: Callable) -> void:
	if pid <= 0:
		callback.call(false)
		return

	# Linux fast path: /proc check is effectively free, no process spawn needed
	if SystemManager.platform.is_linux():
		var dir = DirAccess.open("/proc/" + str(pid))
		if dir:
			callback.call(true)
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
	if pid <= 0 or pssuspend_path == "":
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	if not SystemManager.platform.is_windows():
		push_warning("[ProcessManager] suspend_process_async is only supported on Windows")
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	MemorySubManager.queue_os_execute(pssuspend_path, ["-accepteula", str(pid)], on_done)

## Resumes a suspended process via pssuspend (Windows only; path supplied by caller).
func resume_process_async(pid: int, pssuspend_path: String, on_done: Callable = Callable()) -> void:
	if pid <= 0 or pssuspend_path == "":
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	if not SystemManager.platform.is_windows():
		push_warning("[ProcessManager] resume_process_async is only supported on Windows")
		if on_done.is_valid():
			on_done.call({"exit_code": -1, "output": []})
		return
	MemorySubManager.queue_os_execute(pssuspend_path, ["-accepteula", "-r", str(pid)], on_done)

## Force exit background state (for crashes/emergencies)
func force_exit_background_state() -> void:
	print("[ProcessManager] Force exiting background state")
	exit_background_state(-1)

## Executes a launch intent
func execute_launch(intent: LaunchIntent) -> bool:
	if not intent or not intent.is_valid():
		push_error("[ProcessManager] Invalid launch intent")
		return false

	# Check if emulator is fully installed using step validation (all emulators use registry steps)
	var emulator = launch_manager.registry.get_emulator(intent.emulator_id)
	var is_actually_installed = false
	var install_steps = emulator.get("install", [])
	is_actually_installed = true
	for i in range(install_steps.size()):
		if not launch_manager.emulator._validate_install_step(intent.emulator_id, i, install_steps):
			is_actually_installed = false
			break

	if not is_actually_installed:
		push_error("[ProcessManager] Emulator not fully installed: " + intent.emulator_id)
		SystemManager.notifications.show_notification("Emulator not ready: " + intent.emulator_name, SystemManager.notifications.Type.ERROR)
		return false

	if SystemManager.platform.is_android():
		return _execute_android(intent)
	else:
		return await _execute_desktop(intent)

func _execute_desktop(intent: LaunchIntent) -> bool:
	if intent.launch_args.is_empty():
		push_error("[ProcessManager] No launch arguments for desktop")
		return false

	var pid = await _create_desktop_process(intent)
	if pid == -1:
		launch_manager.launch_completed.emit(false, "Failed to start emulator")
		return false

	# Store PID and enter background state for desktop
	enter_background_state(pid, intent.game)

	launch_manager.launch_completed.emit(true, "Game launched successfully")
	return true

## Creates a process from a launch intent without entering background state.
## Coroutine: returns the PID or -1 on failure.
func _create_process_from_intent(intent: LaunchIntent) -> int:
	return await _create_desktop_process(intent)

## Shared desktop process creation. Coroutine: returns the REAL emulator PID
## (never a shell-wrapper PID) or -1 on failure.
func _create_desktop_process(intent: LaunchIntent) -> int:
	if intent.launch_args.is_empty():
		push_error("[ProcessManager] No launch arguments for desktop")
		return -1

	var exe_path = intent.launch_args[0]
	var arguments = intent.launch_args.slice(1)
	var pid: int = -1

	if intent.working_directory == "":
		# No working directory needed: call executable directly (no shell, no injection risk)
		pid = OS.create_process(exe_path, arguments, false)
	elif not SystemManager.platform.is_windows():
		# Linux/macOS: sh -c with exec, so the shell REPLACES itself with the
		# emulator and the returned PID is the emulator's own PID
		var safe_args = _escape_args_for_shell(arguments)
		var safe_working_dir = _escape_sh_arg(intent.working_directory)
		var safe_exe = _escape_sh_arg(exe_path)
		var inner_cmd = 'cd %s && exec %s %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
		pid = OS.create_process("sh", ["-c", inner_cmd], false)
	else:
		# Windows: Start-Process sets the working directory AND reports the real
		# child PID via -PassThru (a cmd /c wrapper would return cmd.exe's PID)
		var ps_arg_list: Array[String] = []
		for arg in arguments:
			ps_arg_list.append(_escape_ps_arg_quoted(arg))
		var ps_command = "Start-Process -FilePath %s -WorkingDirectory %s" % [_escape_ps_arg(exe_path), _escape_ps_arg(intent.working_directory)]
		if not ps_arg_list.is_empty():
			ps_command += " -ArgumentList " + ",".join(ps_arg_list)
		ps_command += " -PassThru | Select-Object -ExpandProperty Id"

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

		if pid <= 0:
			# Fallback: cmd /c wrapper (tracks the wrapper PID, not the emulator)
			push_warning("[ProcessManager] PowerShell launch failed, falling back to cmd wrapper (PID tracking will follow cmd.exe)")
			var safe_args = _escape_args_for_shell(arguments)
			var safe_working_dir = _escape_cmd_meta(intent.working_directory)
			var safe_exe = _escape_cmd_meta(exe_path)
			var inner_cmd = 'cd /d "%s" && "%s" %s' % [safe_working_dir, safe_exe, " ".join(safe_args)]
			print("[ProcessManager] Executing command: cmd /c ", inner_cmd)
			pid = OS.create_process("cmd", ["/c", inner_cmd], false)

	if pid == -1:
		push_error("[ProcessManager] Failed to launch process: " + exe_path)
		return -1

	return pid

func _execute_android(intent: LaunchIntent) -> bool:
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
			print("[ProcessManager] Core path for sideload: " + core_path)
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
				print("[ProcessManager] Replaced {core_path} with: " + core_path)

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
	var emulator_name = emulator.get("name", emulator_id)

	# Create M3Dialog reminder as a distinct overlay type so it stacks above the settings dialog
	UIManager.show_alert("Installation Reminder", "Please open " + emulator_name + " from your app drawer and grant any requested permissions (especially storage access) before launching games.",
		Callable(),
		Callable(),
		{"ok_text": "Got it", "overlay_type": "alert", "overlay_layer": 95, "dismissible": false}
	)

	print("[ProcessManager] Shown Android permissions reminder for: " + emulator_name)
