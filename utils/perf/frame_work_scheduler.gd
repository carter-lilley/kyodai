class_name FrameWorkScheduler
extends RefCounted

## Single main-thread driver for small per-frame bookkeeping drains. WarmupBudget
## is opened once here, before any registered work runs, preserving its original
## first-autoload ordering. Callbacks keep their existing budgets and early-outs;
## this only consolidates dispatch, it does not change their semantics.

static var _callbacks: Array[Dictionary] = []

static func register(owner: Object, callback: Callable) -> void:
	if owner == null or not callback.is_valid():
		return
	var id := owner.get_instance_id()
	for entry in _callbacks:
		if entry.id == id:
			entry.callback = callback
			return
	_callbacks.append({"id": id, "owner": owner, "callback": callback})

static func unregister(owner: Object) -> void:
	if owner == null:
		return
	var id := owner.get_instance_id()
	for i in range(_callbacks.size() - 1, -1, -1):
		if _callbacks[i].id == id:
			_callbacks.remove_at(i)

static func drain(delta: float) -> void:
	WarmupBudget.begin_frame()
	# Registration may change during a drain (view/pool construction), so iterate
	# over a snapshot instead of the live array.
	var pending := _callbacks.duplicate()
	for entry in pending:
		var owner: Object = entry.owner
		if not is_instance_valid(owner):
			for i in range(_callbacks.size() - 1, -1, -1):
				if _callbacks[i].id == entry.id:
					_callbacks.remove_at(i)
			continue
		var callback: Callable = entry.callback
		if callback.is_valid():
			callback.call(delta)
