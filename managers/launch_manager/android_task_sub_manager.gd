extends Manager
class_name AndroidTaskSubManager

## Async GDScript facade over the native two-tier Android task backend.
signal _result_received(request_id: String)

var _pending: Dictionary = {}  # requestId -> Callable
var _capabilities: Dictionary = {}
var _capabilities_ready := false
var _signal_connected := false

func _ready() -> void:
	_ensure_signal_connection(_plugin())

func _ensure_signal_connection(plugin) -> void:
	# Engine singletons may not be visible yet during autoload _ready. Retry at
	# the first real call rather than permanently losing every async result.
	if _signal_connected or plugin == null:
		return
	plugin.connect("android_task_result", _on_result)
	_signal_connected = true
	print("[AndroidTasks] Native result signal connected")

func _plugin():
	return Engine.get_singleton("KyodaiBridge") if Engine.has_singleton("KyodaiBridge") else null

func _on_result(request_id: String, operation: String, json: String) -> void:
	print("[AndroidTasks] Result ", operation, ": ", json)
	if _pending.has(request_id):
		var callback: Callable = _pending[request_id]
		_pending.erase(request_id)
		var parsed = JSON.parse_string(json)
		callback.call(parsed if parsed is Dictionary else {"ok": false, "code": "invalid_response"})
	# Early Home snapshots have no entry in _pending, but capture_snapshot()
	# may still be waiting for their native result.
	_result_received.emit(request_id)

func _call(method: String, args: Array = []) -> Dictionary:
	var plugin = _plugin()
	if plugin == null:
		return {"ok": false, "code": "unsupported", "error": "Android task backend unavailable"}
	_ensure_signal_connection(plugin)
	var state := {"done": false, "result": {}}
	var request_id: String
	if method == "androidTaskProbeCapabilities":
		request_id = plugin.androidTaskProbeCapabilities()
	elif method == "androidTaskListTasks":
		request_id = plugin.androidTaskListTasks()
	else:
		request_id = plugin.callv(method, args)
	if request_id == "closed" or request_id == "unsupported":
		return {"ok": false, "code": "unsupported"}
	_pending[request_id] = func(result: Dictionary):
		state.done = true
		state.result = result
	# Do not poll process_frame: Android pauses SceneTree frames while the game
	# is foreground, exactly when launch-time task registration must finish.
	# The native router has its own deadline and always returns a result.
	while not state.done:
		await _result_received
	return state.result

func probe_capabilities() -> Dictionary:
	var result := await _call("androidTaskProbeCapabilities")
	# TaskBackendRouter returns Capabilities.toJson() directly. Accept the
	# nested shape too for isolated test doubles, but never discard the real
	# top-level native capabilities.
	_capabilities = result.get("capabilities", result)
	_capabilities_ready = true
	print("[AndroidTasks] Capabilities: ", _capabilities)
	return result

func _ensure_capabilities() -> void:
	if not _capabilities_ready:
		await probe_capabilities()

func retention_available() -> bool:
	if not SystemManager.platform.is_android() or not SessionFeatureFlags.enabled(SessionFeatureFlags.ANDROID_RETAINED_SESSIONS):
		return false
	await _ensure_capabilities()
	return bool(_capabilities.get("retainedSessions", false))

func snapshots_available() -> bool:
	if not await retention_available() or not SessionFeatureFlags.enabled(SessionFeatureFlags.ANDROID_TASK_SNAPSHOTS):
		return false
	return bool(_capabilities.get("snapshots", false))

func list_tasks() -> Dictionary:
	return await _call("androidTaskListTasks")

func set_retained_identity(task: Dictionary, game_foreground: bool) -> void:
	var plugin = _plugin()
	if plugin:
		plugin.androidTaskSetRetainedIdentity(int(task.taskId), _package_name(task), str(task.topActivity), game_foreground)

func clear_retained_identity() -> void:
	var plugin = _plugin()
	if plugin:
		plugin.androidTaskClearRetainedIdentity()

func _package_name(task: Dictionary) -> String:
	return str(task.get("package", task.get("packageName", "")))

func capture_snapshot(task: Dictionary) -> Dictionary:
	var plugin = _plugin()
	var task_id := int(task.taskId)
	if plugin:
		var status: String = plugin.androidTaskHomeSnapshotStatus(task_id)
		while status == "pending":
			await _result_received
			status = plugin.androidTaskHomeSnapshotStatus(task_id)
		if status == "ready":
			var json: String = plugin.androidTaskConsumeHomeSnapshot(task_id)
			var parsed = JSON.parse_string(json)
			if parsed is Dictionary:
				return parsed
	return await _call("androidTaskCaptureSnapshot", [task_id, _package_name(task), str(task.topActivity)])

func focus(task: Dictionary) -> Dictionary:
	return await _call("androidTaskFocus", [int(task.taskId), _package_name(task), str(task.topActivity)])

func force_stop(task: Dictionary) -> Dictionary:
	return await _call("androidTaskForceStop", [int(task.taskId), _package_name(task), int(task.get("userId", 0))])

func remove_task(task: Dictionary) -> Dictionary:
	return await _call("androidTaskRemove", [int(task.taskId), _package_name(task)])

func move_task_to_display(task: Dictionary, display_id: int) -> Dictionary:
	return await _call("androidTaskMoveDisplay", [int(task.taskId), _package_name(task), display_id])
