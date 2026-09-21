extends Manager

## Coordinates multi-emulator update sessions ("update all" flow).
##
## Instead of every install step firing its own snackbar, a session shows one
## pinned aggregate progress snackbar (0-100%, equal weight per emulator) that
## lists the emulators still working and their current step. Per-step
## download/extraction notifications are suppressed while a session is active.
##
## On Android, updates are serialized: APK installs need user interaction in
## the system package installer, so only one emulator update runs at a time
## and the session waits for the user to return to the app before continuing.
## On desktop, updates run in parallel but bounded: the extraction pipeline
## has a small single-threaded queue, so unlimited parallelism overflows it
## and gets extraction tasks rejected outright.

## Emitted once when every emulator in a session has settled (done or failed).
## succeeded/failed contain emulator display names; failed entries include the
## failure reason in parentheses. Views should refresh once on this instead of
## reacting to every per-step signal during the session.
signal update_session_finished(succeeded: Array, failed: Array)

const MAX_CONCURRENT_DESKTOP: int = 4
const MAX_CONCURRENT_ANDROID: int = 1

var launch_manager: Node

# emulator_id -> {
#   "name": String, "total_steps": int, "step_index": int, "step_label": String,
#   "status": String,  # "queued" | "running" | "waiting_apk" | "done" | "failed"
#   "waiting_fraction": float, "fail_reason": String
# }
var _session: Dictionary = {}
var _pending_queue: Array[String] = []
var _snackbar_id: int = -1

func _ready() -> void:
	launch_manager = get_parent()
	# Deferred: the parent's @onready sub-manager refs aren't assigned until
	# after child _ready() runs.
	call_deferred("_connect_signals")

func _connect_signals() -> void:
	launch_manager.emulator.install_step_started.connect(_on_install_step_started)
	launch_manager.emulator.install_steps_finished.connect(_on_install_steps_finished)
	launch_manager.emulator.install_steps_failed.connect(_on_install_steps_failed)
	launch_manager.emulator_extraction_completed.connect(_on_emulator_extraction_completed)

## Starts (or extends) an update session for the given emulator ids. All ids
## enter a queue; updates run up to the platform's concurrency limit
## (1 on Android, a few on desktop).
func begin_session(emulator_ids: Array) -> void:
	var added: Array[String] = []
	for emulator_id in emulator_ids:
		var id := str(emulator_id)
		if _session.has(id):
			continue
		var emulator: Dictionary = launch_manager.registry.get_emulator(id)
		if emulator.is_empty():
			continue
		_session[id] = {
			"name": RegistrySubManager.get_emulator_display_name(emulator, id),
			"total_steps": maxi((emulator.get("install", []) as Array).size(), 1),
			"step_index": 0,
			"step_label": "Queued",
			"status": "queued",
			"waiting_fraction": 0.0,
			"fail_reason": "",
		}
		added.append(id)

	if added.is_empty():
		return

	print("[UpdateManager] Update session started for: " + ", ".join(added))
	launch_manager.emulator.suppress_step_notifications = true

	if _snackbar_id == -1:
		_snackbar_id = SystemManager.notifications.show_notification(
			"Updating emulators...",
			SystemManager.notifications.Type.INFO,
			null,
			0.0,
			_session_progress,
			_format_session_text,
			false,  # pulsing
			true  # pinned - must survive dismiss_all on Android resume
		)

	_pending_queue.append_array(added)
	_start_next_if_idle()

## Called when the app returns to the foreground (Android). Resolves emulators
## waiting on the system package installer and continues the queue.
func on_app_resumed() -> void:
	if _session.is_empty():
		return
	for id in _session.keys():
		var state: Dictionary = _session[id]
		if state.status != "waiting_apk":
			continue
		var package := _get_apk_package(id)
		if package != "" and launch_manager.emulator._is_android_package_installed(package):
			print("[UpdateManager] APK installed after resume: " + id)
			_mark_done(id)
		else:
			print("[UpdateManager] APK not installed after resume, marking failed: " + id)
			_mark_failed(id, "install not completed")
	_start_next_if_idle()

func is_session_active() -> bool:
	return not _session.is_empty()

# ============================================================================
# Signal handlers
# ============================================================================

func _on_install_step_started(emulator_id: String, step_index: int, total_steps: int) -> void:
	if not _session.has(emulator_id):
		return
	var state: Dictionary = _session[emulator_id]
	if state.status != "running" and state.status != "queued":
		return
	state.status = "running"
	state.step_index = step_index
	state.total_steps = maxi(total_steps, 1)
	var emulator: Dictionary = launch_manager.registry.get_emulator(emulator_id)
	var install_steps: Array = emulator.get("install", [])
	var step_name := ""
	if step_index < install_steps.size():
		step_name = install_steps[step_index].get("step", "")
	state.step_label = launch_manager.emulator._get_step_display_name(step_name)

func _on_install_steps_finished(emulator_id: String) -> void:
	if not _session.has(emulator_id):
		return
	# On Android, the chain completes right after the package installer intent
	# fires - the APK itself may not be installed yet. Wait for the user to
	# return to the app before calling this emulator done.
	if SystemManager.platform.is_android():
		var package := _get_apk_package(emulator_id)
		if package != "" and not launch_manager.emulator._is_android_package_installed(package):
			var state: Dictionary = _session[emulator_id]
			state.status = "waiting_apk"
			state.step_label = "Waiting for install"
			launch_manager.emulator._validation_cache.erase(emulator_id)
			var progress: Dictionary = launch_manager.emulator.get_install_progress(emulator_id)
			var total: int = maxi(progress.get("total_steps", 1), 1)
			state.waiting_fraction = clampf(float(progress.get("completed_steps", 0)) / float(total), 0.0, 0.999)
			print("[UpdateManager] Waiting for APK install: " + emulator_id)
			return
	_mark_done(emulator_id)
	_start_next_if_idle()

func _on_install_steps_failed(emulator_id: String, reason: String) -> void:
	if not _session.has(emulator_id):
		return
	_mark_failed(emulator_id, reason if reason != "" else "install step failed")
	_start_next_if_idle()

func _on_emulator_extraction_completed(emulator_id: String, success: bool) -> void:
	if success or not _session.has(emulator_id):
		return
	_mark_failed(emulator_id, "download/extract failed")
	_start_next_if_idle()

# ============================================================================
# Internals
# ============================================================================

func _max_concurrent() -> int:
	if SystemManager.platform.is_android():
		return MAX_CONCURRENT_ANDROID
	return MAX_CONCURRENT_DESKTOP

## Starts queued emulator updates until the concurrency limit is reached.
## waiting_apk occupies a slot: the user must finish (or cancel) the system
## package installer before the next update starts.
func _start_next_if_idle() -> void:
	var active := 0
	for id in _session.keys():
		var status: String = _session[id].status
		if status == "running" or status == "waiting_apk":
			active += 1
	while active < _max_concurrent() and not _pending_queue.is_empty():
		var next_id := _pending_queue.pop_front() as String
		if not _session.has(next_id):
			continue
		if _session[next_id].status != "queued":
			continue
		_session[next_id].status = "running"
		print("[UpdateManager] Starting update: " + next_id)
		if launch_manager.registry.trigger_emulator_update(next_id):
			active += 1
		else:
			_mark_failed(next_id, "install already in progress")

func _mark_done(emulator_id: String) -> void:
	var state: Dictionary = _session[emulator_id]
	if state.status == "done" or state.status == "failed":
		return
	state.status = "done"
	state.step_label = "Done"
	print("[UpdateManager] Update complete: " + emulator_id)
	_check_session_finished()

func _mark_failed(emulator_id: String, reason: String) -> void:
	var state: Dictionary = _session[emulator_id]
	if state.status == "done" or state.status == "failed":
		return
	state.status = "failed"
	state.fail_reason = reason
	state.step_label = "Failed"
	print("[UpdateManager] Update failed: " + emulator_id + " (" + reason + ")")
	_check_session_finished()

func _check_session_finished() -> void:
	if _session.is_empty():
		return
	for id in _session.keys():
		var status: String = _session[id].status
		if status == "queued" or status == "running" or status == "waiting_apk":
			return
	# Everything settled - dismiss the aggregate snackbar and summarize.
	if _snackbar_id != -1:
		SystemManager.notifications.dismiss_notification(_snackbar_id)
		_snackbar_id = -1
	var succeeded: Array[String] = []
	var failed: Array[String] = []
	for id in _session.keys():
		if _session[id].status == "done":
			succeeded.append(_session[id].name)
		else:
			var label: String = _session[id].name
			if _session[id].fail_reason != "":
				label += " (" + _session[id].fail_reason + ")"
			failed.append(label)
	_session.clear()
	_pending_queue.clear()
	launch_manager.emulator.suppress_step_notifications = false
	update_session_finished.emit(succeeded, failed)
	if failed.is_empty():
		SystemManager.notifications.show_notification(
			"Updated %d emulator(s)" % succeeded.size(),
			SystemManager.notifications.Type.SUCCESS
		)
	else:
		SystemManager.notifications.show_notification(
			"Updates finished - failed: " + ", ".join(failed),
			SystemManager.notifications.Type.WARNING,
			null,
			8.0
		)

func _get_apk_package(emulator_id: String) -> String:
	var emulator: Dictionary = launch_manager.registry.get_emulator(emulator_id)
	for step in emulator.get("install", []):
		var config: Dictionary = launch_manager.registry._get_step_platform_config(step)
		if config.get("action_type", "") == "apk_install":
			return config.get("package_name", "")
	return ""

# ============================================================================
# Aggregate snackbar callables (polled by NotificationSubManager)
# ============================================================================

func _session_progress() -> float:
	if _session.is_empty():
		return 1.0
	var sum := 0.0
	for id in _session.keys():
		sum += _emulator_fraction(id)
	# Capped below 1.0 so the notification manager's auto-dismiss never fires;
	# the session dismisses itself once every emulator has settled.
	return clampf(sum / float(_session.size()), 0.0, 0.999)

func _emulator_fraction(emulator_id: String) -> float:
	var state: Dictionary = _session[emulator_id]
	match state.status:
		"done", "failed":
			return 1.0
		"waiting_apk":
			return state.waiting_fraction
		"running":
			var total: int = maxi(state.total_steps, 1)
			var fraction := float(state.step_index) / float(total)
			# Refine the current step's fraction with live download progress
			var item = launch_manager.emulator.get_emulator_active_download(emulator_id)
			if item != null and item.status == "downloading":
				fraction += clampf(item.progress, 0.0, 1.0) / float(total)
			return minf(fraction, 0.999)
	return 0.0

func _format_session_text(progress: float) -> String:
	var text := "Updating emulators - %d%%" % int(round(progress * 100.0))
	# Snackbars ellipsize aggressively, so show only the first active entry
	# plus an overflow count instead of listing every emulator.
	var waiting_count := 0
	var first_waiting := ""
	var active_count := 0
	var first_active := ""
	for id in _session.keys():
		var state: Dictionary = _session[id]
		match state.status:
			"waiting_apk":
				waiting_count += 1
				if first_waiting == "":
					first_waiting = state.name
			"running":
				active_count += 1
				if first_active == "":
					first_active = state.name + ": " + state.step_label
	if first_waiting != "":
		text += " | install " + first_waiting + " in the system installer"
		if waiting_count > 1:
			text += " +%d more" % (waiting_count - 1)
	elif first_active != "":
		text += " | " + first_active
		if active_count > 1:
			text += " +%d more" % (active_count - 1)
	elif not _pending_queue.is_empty():
		text += " | %d queued" % _pending_queue.size()
	return text
