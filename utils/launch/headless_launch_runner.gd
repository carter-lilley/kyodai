extends Node
class_name HeadlessLaunchRunner

## Headless companion launcher: performs save sync around an emulator launch
## with no UI. Invoked as: kyodai --headless -- --kyodai-launch <romm_id>
## Steam shortcuts written by SteamVDFWriter point here so save sync keeps
## working when games are launched from Steam instead of the Kyodai GUI.
##
## Flow: pre-launch save download -> spawn emulator -> wait for exit ->
## post-launch save upload -> quit. All status is reported on stdout/stderr.

const ARG_LAUNCH := "--kyodai-launch"

const NETWORK_WAIT_TIMEOUT_SEC := 20.0
const PRE_SYNC_TIMEOUT_SEC := 180.0
const UPLOAD_BEGIN_GRACE_SEC := 30.0
const UPLOAD_TIMEOUT_SEC := 1800.0
const PROCESS_POLL_INTERVAL_SEC := 1.0

static var _active_cached := -1

## Returns the romm_id passed via --kyodai-launch, or -1 when not headless.
static func parse_launch_romm_id() -> int:
	var args := OS.get_cmdline_args()
	# get_cmdline_args() includes user args on some builds only; union both.
	for user_arg in OS.get_cmdline_user_args():
		if not args.has(user_arg):
			args.append(user_arg)
	var idx := args.find(ARG_LAUNCH)
	if idx == -1 or idx + 1 >= args.size():
		return -1
	return args[idx + 1].to_int()

## True when this process was started as the headless launch companion.
## Lazily parsed from the command line so it is safe to call from any autoload
## regardless of startup ordering.
static func is_active() -> bool:
	if _active_cached == -1:
		_active_cached = 1 if parse_launch_romm_id() > 0 else 0
	return _active_cached == 1

func run(romm_id: int) -> void:
	print("[HeadlessLauncher] Starting headless launch for romm_id=", romm_id)

	if not await _await_database_ready():
		_exit(1, "Database failed to initialize")
		return

	var first_run = DataManager.get_setting("first_run_completed")
	if first_run and not first_run.value:
		_exit(1, "Kyodai first-run setup is not complete - open the Kyodai app once before launching from Steam")
		return

	var game: GameResource = DataManager.get_game_by_id(romm_id)
	if game == null:
		_exit(1, "No game found for romm_id=" + str(romm_id) + " (library may have changed - re-add the shortcut)")
		return

	if not game.is_active_variant_downloaded():
		_exit(1, game.get_display_name() + " is not downloaded - launch it from Kyodai once to download it")
		return

	var emulator_id: String = LaunchManager.resolve_emulator_for_game(game)
	if emulator_id == "":
		_exit(1, "No emulator configured for platform: " + game.platform_slug)
		return

	# A previous headless companion may have died while its game survived.
	# Continue that session instead of syncing against it and launching twice.
	await LaunchManager.process.wait_for_initial_recovery()
	var recovered: GameSession = LaunchManager.sessions.get_live_for_game(romm_id)
	if recovered and recovered.backend == GameSession.Backend.DESKTOP_PROCESS:
		print("[HeadlessLauncher] Reattached to surviving emulator; resuming wait without a second launch")
		await _wait_for_session_exit(recovered)
		await _post_launch(recovered)
		_exit(0, "Headless launch complete for " + game.get_display_name())
		return

	if LaunchManager.get_install_progress(emulator_id).get("status", "") != "complete":
		_exit(1, "Emulator " + emulator_id + " is not fully installed - launch from Kyodai to set it up")
		return

	_warn_if_other_instance_running()

	if await _await_romm_connection():
		await _pre_launch_sync(game, emulator_id)
	else:
		push_warning("[HeadlessLauncher] RomM unreachable - launching without save sync")

	# NOTE: game preparation (PS3/Vita ZIP extraction, firmware setup) does not
	# run headless. Games that need first-time prep must be launched from the
	# Kyodai GUI once before their Steam shortcut works.
	var intent: LaunchIntent = LaunchManager.create_launch_intent(game)
	if intent == null or not intent.is_valid():
		_exit(1, "Failed to create a valid launch intent for " + game.get_display_name())
		return

	print("[HeadlessLauncher] Launching: ", intent)
	var pid: int = await LaunchManager.process._create_process_from_intent(intent)
	if pid <= 0:
		_exit(1, "Failed to start emulator process")
		return

	print("[HeadlessLauncher] Emulator running (pid=", pid, ") - waiting for exit")
	var pgid: int = LaunchManager.process.get_pgid(pid)
	var session: GameSession = LaunchManager.sessions.begin_session(game, GameSession.Backend.DESKTOP_PROCESS, {
		"emulator_id": emulator_id,
		"policy": {"origin": "headless"},
		"runtime": {
			"pid": pid,
			"pgid": pgid,
			"process_start_ticks": LaunchManager.process._process_start_ticks(pid),
			"boot_id": LaunchManager.process._current_boot_id(),
			"signature": game.file_path,
			"exe_signature": str(intent.launch_args[0]).get_file().get_basename().to_lower() if not intent.launch_args.is_empty() else "",
		},
	})
	LaunchManager.sessions.activate_session(session, pid)
	LaunchManager._update_last_played(game)

	await _wait_for_session_exit(session)

	print("[HeadlessLauncher] Emulator exited - starting post-launch save upload")
	await _post_launch(session)

	_exit(0, "Headless launch complete for " + game.get_display_name())

func _wait_for_session_exit(session: GameSession) -> void:
	var tracked_pid := int(session.runtime.get("pid", -1))
	var tracked_pgid := int(session.runtime.get("pgid", -1))
	while true:
		var alive := false
		if SystemManager.platform.is_linux():
			if tracked_pgid > 1 and tracked_pgid != LaunchManager.process.get_own_pgid():
				alive = LaunchManager.process.is_group_alive(tracked_pgid)
			if not alive:
				var target: Dictionary = LaunchManager.process.resolve_live_target(tracked_pid, session.game.file_path)
				alive = int(target.get("pid", -1)) > 0
				if alive:
					var new_pid := int(target.get("pid", tracked_pid))
					var new_pgid := int(target.get("pgid", tracked_pgid))
					if new_pid != tracked_pid or new_pgid != tracked_pgid:
						tracked_pid = new_pid
						if new_pgid > 0:
							tracked_pgid = new_pgid
						LaunchManager.sessions.update_runtime(session, {
							"pid": tracked_pid,
							"pgid": tracked_pgid,
						})
		else:
			alive = await LaunchManager.process.is_running_async(tracked_pid)
		if not alive:
			break
		await get_tree().create_timer(PROCESS_POLL_INTERVAL_SEC).timeout

## Isolated terminal hook for the headless launch path. Keeping the upload and
## its wait together makes the exactly-once contract directly testable.
func _post_launch(session: GameSession) -> void:
	_finalize_session(session)
	LaunchManager.process.request_pending_recovery()
	await _await_upload_completion(session.game, session.emulator_id)

func _finalize_session(session: GameSession) -> void:
	LaunchManager.sessions.finalize_once(session, 0, "process_exited")

func _exit(code: int, message: String) -> void:
	if code == 0:
		print("[HeadlessLauncher] ", message)
	else:
		push_error("[HeadlessLauncher] " + message)
	get_tree().quit(code)

func _await_database_ready() -> bool:
	if DataManager.is_database_ready():
		return true
	var state := {"ready": false, "waited": 0.0}
	DataManager.database_ready.connect(func(): state["ready"] = true, CONNECT_ONE_SHOT)
	while not state["ready"] and state["waited"] < 30.0:
		await get_tree().create_timer(0.1).timeout
		state["waited"] += 0.1
	return DataManager.is_database_ready()

func _await_romm_connection() -> bool:
	if SystemManager.network.is_romm_connected():
		return true
	var waited := 0.0
	while waited < NETWORK_WAIT_TIMEOUT_SEC:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if SystemManager.network.is_romm_connected():
			return true
	return false

func _pre_launch_sync(game: GameResource, emulator_id: String) -> void:
	print("[HeadlessLauncher] Pre-launch save sync starting")
	var state := {"done": false, "waited": 0.0}
	DataManager.auto_download_saves_for_game(game, emulator_id, func(): state["done"] = true)
	while not state["done"] and state["waited"] < PRE_SYNC_TIMEOUT_SEC:
		await get_tree().create_timer(0.25).timeout
		state["waited"] += 0.25
	if not state["done"]:
		push_warning("[HeadlessLauncher] Pre-launch save sync timed out - launching anyway")
	else:
		print("[HeadlessLauncher] Pre-launch save sync complete")

func _await_upload_completion(game: GameResource, emulator_id: String) -> void:
	var game_save = DataManager.game_save
	# Grace window: the upload path scans saves on a worker thread before the
	# in-flight flag flips, and early-outs (nothing to upload, sync disabled)
	# never flip it at all.
	var grace := 0.0
	while grace < UPLOAD_BEGIN_GRACE_SEC:
		if game_save.is_save_sync_in_flight(game, emulator_id):
			break
		await get_tree().create_timer(0.25).timeout
		grace += 0.25
	if not game_save.is_save_sync_in_flight(game, emulator_id):
		print("[HeadlessLauncher] No post-launch upload was needed")
		return
	var waited := 0.0
	while game_save.is_save_sync_in_flight(game, emulator_id) and waited < UPLOAD_TIMEOUT_SEC:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	if game_save.is_save_sync_in_flight(game, emulator_id):
		push_warning("[HeadlessLauncher] Post-launch upload timed out after " + str(UPLOAD_TIMEOUT_SEC) + "s")
	else:
		print("[HeadlessLauncher] Post-launch save upload complete")

## Warns (but proceeds) when another Kyodai process is alive - concurrent GUI +
## headless sync is allowed, but worth surfacing in the log.
func _warn_if_other_instance_running() -> void:
	var self_pid := OS.get_process_id()
	var exe_name := OS.get_executable_path().get_file()
	var other_pids: Array[int] = []
	var output: Array = []

	if SystemManager.platform.is_windows():
		# CSV rows: "kyodai.exe","12345","Console","1","100,000 K"
		if OS.execute("tasklist", ["/FI", "IMAGENAME eq " + exe_name, "/FO", "CSV", "/NH"], output, true) == 0:
			for line in str(output[0]).split("\n", false):
				var parts := line.split("\",\"")
				if parts.size() >= 2:
					var pid := parts[1].strip_edges().trim_prefix("\"").trim_suffix("\"").to_int()
					if pid > 0 and pid != self_pid:
						other_pids.append(pid)
	else:
		# pgrep -x matches the kernel comm field, truncated to 15 chars
		var comm := exe_name.substr(0, 15)
		if OS.execute("pgrep", ["-x", comm], output, true) == 0:
			for line in str(output[0]).split("\n", false):
				var pid := line.strip_edges().to_int()
				if pid > 0 and pid != self_pid:
					other_pids.append(pid)

	if not other_pids.is_empty():
		push_warning("[HeadlessLauncher] Another Kyodai instance is running (pids: " + str(other_pids) + ") - concurrent save sync may conflict")
