#memory_sub_manager.gd
extends Node
class_name MemorySubManager

# ============================================================================
# THREAD MANAGEMENT (from thread_manager.gd)
# ============================================================================

var _db_thread: Thread
var _image_threads: Array[Thread] = []
var _extraction_thread: Thread
var _download_threads: Array[Thread] = []
var _os_execute_threads: Array[Thread] = []
var _sync_thread: Thread
var _db_queue: Array = []
var _image_high_priority_queue: Array = []
var _image_low_priority_queue: Array = []
var _extraction_queue: Array = []
var _download_queue: Array = []
var _os_execute_queue: Array = []
var _sync_queue: Array = []
var _db_mutex: Mutex
var _image_mutex: Mutex
var _extraction_mutex: Mutex
var _download_mutex: Mutex
var _os_execute_mutex: Mutex
var _sync_mutex: Mutex
var _db_semaphore: Semaphore
var _image_semaphore: Semaphore
var _extraction_semaphore: Semaphore
var _download_semaphore: Semaphore
var _os_execute_semaphore: Semaphore
var _sync_semaphore: Semaphore
var _exit_flag: bool = false
var _image_task_counter: int = 0
var _image_tasks: Dictionary = {}
var _inflight_image_callbacks: Dictionary[String, Array] = {}
var _dedup_task_ids: Dictionary = {}  # dedup_key -> task_id of the in-flight task

var _texture_cache: Dictionary = {}  # Insertion-ordered: front = LRU, back = MRU
var _texture_cache_mutex: Mutex
## Keys pinned by currently-visible cards; eviction skips these while refcount > 0.
var _pinned_texture_keys: Dictionary = {}  # cache_key -> int refcount
const MAX_TEXTURE_CACHE_SIZE: int = 400
const MAX_TEXTURE_CACHE_MEMORY_MB: int = 300
const MAX_TEXTURE_CACHE_MEMORY_MB_ANDROID: int = 100
## Eviction logging (per-entry decode bucket + byte totals) for cache audits.
const DEBUG_CACHE_LOG: bool = false
var _texture_cache_memory: int = 0  # Estimated bytes currently cached

static func get_max_texture_cache_size() -> int:
	if OS.get_name() == "Android":
		return 150
	return MAX_TEXTURE_CACHE_SIZE

static func get_max_texture_cache_memory_bytes() -> int:
	if OS.get_name() == "Android":
		return MAX_TEXTURE_CACHE_MEMORY_MB_ANDROID * 1024 * 1024
	return MAX_TEXTURE_CACHE_MEMORY_MB * 1024 * 1024

static func _estimate_texture_memory(texture: Texture2D) -> int:
	if texture == null:
		return 0
	return texture.get_width() * texture.get_height() * 4  # RGBA8 estimate

var _lp_callbacks: Array = []
var _lp_callback_head: int = 0  # Unconsumed items start here; avoids O(n) re-slicing per frame
var _lp_callback_mutex: Mutex
const MAX_LP_CALLBACKS_PER_FRAME: int = 15
## Scroll-idle gate (Argosy/Playnite stale-decode policy): while the grid is
## scrolling fast, workers only pull HIGH-priority (visible) decodes so the
## thread pool's full throughput serves on-screen covers; buffer/low-priority
## decodes resume once scrolling settles. Prevents a scroll storm from minting
## hundreds of soon-evicted textures that crowd out visible rows.
var _low_priority_gated: bool = false
## Owners currently holding the low-priority decode gate (owner_id -> true).
var _low_priority_gate_holders: Dictionary = {}

# Thread-safe main-thread hops ({"callback": Callable, "args": Array}) from
# workers that must reach the main thread reliably; call_deferred from threads
# is unreliable on Android (silently dropped). Drained every frame in _process.
var _mt_callbacks: Array = []
var _mt_callback_mutex: Mutex

const IMAGE_THREAD_COUNT: int = 6
const MAX_IMAGE_QUEUE_SIZE = 600
const MAX_DB_QUEUE_SIZE = 500
## Extra headroom main-thread producers get past the soft cap before tasks
## are dropped (with a null callback) instead of growing the queue forever.
const MAX_DB_QUEUE_MAIN_OVERFLOW = 500
# 5 was tight enough that bursts of save-sync / cover extraction silently
# dropped work; 20 absorbs realistic bursts without unbounded memory growth.
const MAX_EXTRACTION_QUEUE_SIZE = 20
# Total tasks dropped because the extraction queue was full (diagnostic).
static var _extraction_overflow_count: int = 0
const MAX_DOWNLOAD_QUEUE_SIZE = 500
const MAX_SYNC_QUEUE_SIZE = 10
const OS_EXECUTE_THREAD_COUNT: int = 4
const MAX_OS_EXECUTE_QUEUE_SIZE = 100

## Returns the number of download threads for the current platform
static func get_download_thread_count() -> int:
	if OS.get_name() == "Android":
		return 8  # Android: below desktop for battery/heat, enough for chunk concurrency caps
	return 12  # Desktop: more threads for speed

static var _instance: MemorySubManager = null

# ============================================================================
# BATCH SCHEDULING (NEW)
# ============================================================================

## Batch processing modes
enum BatchMode {
	SYNC,       # Process on main thread (for fast operations)
	DB_THREAD,  # Process on DB thread (for DB operations)
	IMAGE_THREAD # Process on image thread (for image operations)
}

## Represents a parallel download batch
class DownloadBatch:
	var items: Array
	var process_item: Callable
	var on_progress: Callable
	var on_complete: Callable
	var completed_count: int = 0
	var total_count: int
	var id: int
	var is_complete: bool = false
	var results: Dictionary = {}  # batch_index -> result

	static var _next_id: int = 0

	func _init(p_items: Array, p_process_item: Callable, p_on_progress: Callable, p_on_complete: Callable):
		items = p_items
		process_item = p_process_item
		on_progress = p_on_progress
		on_complete = p_on_complete
		total_count = items.size()
		id = _next_id
		_next_id += 1

## Represents a batch of work items to be processed across multiple frames
class BatchProcess:
	var items: Array
	var process_item: Callable  # func(item, index) -> result
	var mode: int  # BatchMode
	var batch_size: int
	## Optional per-frame main-thread time budget (microseconds) for SYNC batches.
	## 0 = fixed-count chunks (batch_size items per frame, legacy behavior).
	var frame_budget_us: int = 0
	var current_index: int = 0
	var on_progress: Callable  # func(processed_count, total_count)
	var on_complete: Callable  # func(results: Array)
	var is_complete: bool = false
	var cancelled: bool = false
	var results: Array = []
	var pending_callbacks: int = 0  # Track async callbacks in flight
	var id: int

	static var _next_id: int = 0

	func _init(p_items: Array, p_process_item: Callable, p_mode: int, p_batch_size: int,
			   p_on_progress: Callable = Callable(), p_on_complete: Callable = Callable(),
			   p_frame_budget_us: int = 0):
		items = p_items
		process_item = p_process_item
		mode = p_mode
		batch_size = p_batch_size
		on_progress = p_on_progress
		on_complete = p_on_complete
		frame_budget_us = p_frame_budget_us
		id = _next_id
		_next_id += 1
		results.resize(items.size())

var _batch_processes: Array[BatchProcess] = []
var _batch_mutex: Mutex = Mutex.new()

# Parallel download batch tracking
var _download_batches: Dictionary = {}  # id -> DownloadBatch
var _download_batch_mutex: Mutex = Mutex.new()

# ============================================================================
# INITIALIZATION
# ============================================================================

func _init():
	if _instance == null:
		_instance = self
		_initialize_threads()

func _initialize_threads():
	_db_mutex = Mutex.new()
	_image_mutex = Mutex.new()
	_extraction_mutex = Mutex.new()
	_download_mutex = Mutex.new()
	_os_execute_mutex = Mutex.new()
	_sync_mutex = Mutex.new()
	_texture_cache_mutex = Mutex.new()
	_lp_callback_mutex = Mutex.new()
	_mt_callback_mutex = Mutex.new()
	_db_semaphore = Semaphore.new()
	_image_semaphore = Semaphore.new()
	_extraction_semaphore = Semaphore.new()
	_download_semaphore = Semaphore.new()
	_os_execute_semaphore = Semaphore.new()
	_sync_semaphore = Semaphore.new()

	_db_thread = Thread.new()
	_db_thread.start(_db_worker)

	for i in range(IMAGE_THREAD_COUNT):
		var thread = Thread.new()
		thread.start(_image_worker)
		_image_threads.append(thread)

	_extraction_thread = Thread.new()
	_extraction_thread.start(_extraction_worker)

	# Get thread count from centralized function
	var download_thread_count = get_download_thread_count()
	print("[SystemManager.memory] Initializing " + str(download_thread_count) + " download threads")

	for i in range(download_thread_count):
		var thread = Thread.new()
		thread.start(_download_worker)
		_download_threads.append(thread)

	# Dedicated thread pool for OS.execute calls (AHK window management, etc.)
	# This keeps short-lived shell tools off the download thread pool so long
	# downloads don't stall process control operations.
	print("[SystemManager.memory] Initializing " + str(OS_EXECUTE_THREAD_COUNT) + " OS execute threads")

	for i in range(OS_EXECUTE_THREAD_COUNT):
		var thread = Thread.new()
		thread.start(_os_execute_worker)
		_os_execute_threads.append(thread)

	# Start sync thread for background metadata sync
	print("[SystemManager.memory] Initializing sync thread")
	_sync_thread = Thread.new()
	_sync_thread.start(_sync_worker)

func _ready():
	set_process(true)
	Performance.add_custom_monitor("memory/image_queue_high", _get_image_queue_high_size)
	Performance.add_custom_monitor("memory/image_queue_low", _get_image_queue_low_size)
	Performance.add_custom_monitor("memory/image_tasks_inflight", _get_image_tasks_inflight)
	Performance.add_custom_monitor("memory/db_queue_size", _get_db_queue_size)
	Performance.add_custom_monitor("memory/lp_callback_backlog", _get_lp_callback_backlog)
	Performance.add_custom_monitor("memory/texture_cache_count", _get_texture_cache_count)
	Performance.add_custom_monitor("memory/texture_cache_mb", _get_texture_cache_mb)

func _get_image_queue_high_size() -> int:
	_image_mutex.lock()
	var size = _image_high_priority_queue.size()
	_image_mutex.unlock()
	return size

func _get_image_queue_low_size() -> int:
	_image_mutex.lock()
	var size = _image_low_priority_queue.size()
	_image_mutex.unlock()
	return size

func _get_image_tasks_inflight() -> int:
	_image_mutex.lock()
	var size = _image_tasks.size()
	_image_mutex.unlock()
	return size

func _get_db_queue_size() -> int:
	_db_mutex.lock()
	var size = _db_queue.size()
	_db_mutex.unlock()
	return size

func _get_lp_callback_backlog() -> int:
	_lp_callback_mutex.lock()
	var size = _lp_callbacks.size() - _lp_callback_head
	_lp_callback_mutex.unlock()
	return size

func _get_texture_cache_count() -> int:
	_texture_cache_mutex.lock()
	var size = _texture_cache.size()
	_texture_cache_mutex.unlock()
	return size

func _get_texture_cache_mb() -> float:
	_texture_cache_mutex.lock()
	var mb = _texture_cache_memory / 1048576.0
	_texture_cache_mutex.unlock()
	return mb

func _exit_tree():
	Performance.remove_custom_monitor("memory/image_queue_high")
	Performance.remove_custom_monitor("memory/image_queue_low")
	Performance.remove_custom_monitor("memory/image_tasks_inflight")
	Performance.remove_custom_monitor("memory/db_queue_size")
	Performance.remove_custom_monitor("memory/lp_callback_backlog")
	Performance.remove_custom_monitor("memory/texture_cache_count")
	Performance.remove_custom_monitor("memory/texture_cache_mb")
	shutdown()

func _process(_delta):
	WarmupBudget.begin_frame()
	_drain_mt_callbacks()
	_process_batches()
	_drain_lp_callbacks()

## Startup cap for the main-thread completion drain: a burst (everything
## landing at once while the DB/sync wakes) must not monopolize a boot frame.
## The remainder drains on the following frame(s).
const MT_STARTUP_DRAIN_CAP := 8

func _drain_mt_callbacks():
	"""Run queued main-thread hops from worker threads. Drained before the
	capped lp queue: these are rare, latency-critical completions (e.g. sync
	finished) that must not wait behind batched image callbacks."""
	_mt_callback_mutex.lock()
	if _mt_callbacks.is_empty():
		_mt_callback_mutex.unlock()
		return
	WarmupBudget.tag("mt_cbs")
	var batch := _mt_callbacks
	if WarmupBudget.is_startup_mode() and batch.size() > MT_STARTUP_DRAIN_CAP:
		_mt_callbacks = batch.slice(MT_STARTUP_DRAIN_CAP)
		batch = batch.slice(0, MT_STARTUP_DRAIN_CAP)
	else:
		_mt_callbacks = []
	_mt_callback_mutex.unlock()

	for item in batch:
		if _callback_has_freed_capture(item.callback):
			continue
		if item.callback.is_valid():
			item.callback.callv(item.args)

func _drain_lp_callbacks():
	_lp_callback_mutex.lock()
	var backlog := _lp_callbacks.size() - _lp_callback_head
	if backlog <= 0:
		if not _lp_callbacks.is_empty():
			_lp_callbacks.clear()
			_lp_callback_head = 0
		_lp_callback_mutex.unlock()
		return

	# During the startup window, texture-upload callbacks share the frame with
	# grid settle work; cap the drain so covers can't crowd out the first paint.
	var per_frame_cap := 6 if WarmupBudget.is_startup_mode() else MAX_LP_CALLBACKS_PER_FRAME
	var to_process = mini(backlog, per_frame_cap)
	WarmupBudget.tag("img_upload_cbs")
	var batch: Array = []
	batch.resize(to_process)
	for i in range(to_process):
		batch[i] = _lp_callbacks[_lp_callback_head + i]
	_lp_callback_head += to_process

	if _lp_callback_head >= _lp_callbacks.size():
		_lp_callbacks.clear()
		_lp_callback_head = 0
	elif _lp_callback_head >= 256 and _lp_callback_head * 2 >= _lp_callbacks.size():
		# Amortized compaction so a long-lived backlog doesn't grow the array.
		_lp_callbacks = _lp_callbacks.slice(_lp_callback_head)
		_lp_callback_head = 0
	_lp_callback_mutex.unlock()

	for item in batch:
		if _callback_has_freed_capture(item.callback):
			continue
		if item.callback.is_valid():
			item.callback.call(item.result)

func _callback_has_freed_capture(callback: Callable) -> bool:
	"""Return true if any captured Object argument has been freed.
	This prevents crashes when a node-bound lambda outlives its node."""
	if callback.is_null():
		return true
	for arg in callback.get_bound_arguments():
		if arg is Object and not is_instance_valid(arg):
			return true
	return false

# ============================================================================
# THREAD WORKERS
# ============================================================================

static func _db_worker():
	while not _instance._exit_flag:
		_instance._db_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._db_mutex.lock()
		var task = _instance._db_queue.pop_front()
		_instance._db_mutex.unlock()

		if task:
			var result = task.callable.call()

			if task.callback.is_valid():
				# Use thread-safe callback queue instead of call_deferred
				# (call_deferred from threads is unreliable on Android)
				_instance._mt_callback_mutex.lock()
				_instance._mt_callbacks.append({"callback": task.callback, "args": [result]})
				_instance._mt_callback_mutex.unlock()

static func _image_worker():
	var high_count = 0
	while not _instance._exit_flag:
		_instance._image_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._image_mutex.lock()
		var task = null

		var high_size = _instance._image_high_priority_queue.size()
		var low_size = _instance._image_low_priority_queue.size()

		if high_size > 0 and (low_size == 0 or high_count < 2):
			task = _instance._image_high_priority_queue.pop_front()
			high_count += 1
		elif low_size > 0 and not _instance._low_priority_gated:
			task = _instance._image_low_priority_queue.pop_front()
			high_count = 0

		if task and task.has("cancelled") and task.cancelled:
			_instance._image_tasks.erase(task.id)
			_instance._image_mutex.unlock()
			continue

		_instance._image_mutex.unlock()

		if task:
			var result = task.callable.call()

			_instance._image_mutex.lock()
			_instance._image_tasks.erase(task.id)
			# Collect any coalesced callbacks waiting on this dedup_key
			var coalesced = []
			if task.dedup_key != "" and _instance._inflight_image_callbacks.has(task.dedup_key):
				coalesced = _instance._inflight_image_callbacks[task.dedup_key].duplicate()
				_instance._inflight_image_callbacks.erase(task.dedup_key)
				_instance._dedup_task_ids.erase(task.dedup_key)
			_instance._image_mutex.unlock()

			if task.callback.is_valid() and not task.cancelled:
				if task.high_priority:
					# High priority: immediate callback
					_instance.call_deferred("_execute_callback", task.callback, result)
				else:
					# Low priority: batch for smooth processing
					_instance._lp_callback_mutex.lock()
					_instance._lp_callbacks.append({"callback": task.callback, "result": result})
					_instance._lp_callback_mutex.unlock()

			# Fire coalesced callbacks with the same result
			for waiting in coalesced:
				var cb = waiting.callback
				if cb.is_valid():
					if waiting.high_priority:
						_instance.call_deferred("_execute_callback", cb, result)
					else:
						_instance._lp_callback_mutex.lock()
						_instance._lp_callbacks.append({"callback": cb, "result": result})
						_instance._lp_callback_mutex.unlock()

static func _extraction_worker():
	while not _instance._exit_flag:
		_instance._extraction_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._extraction_mutex.lock()
		var task = _instance._extraction_queue.pop_front()
		_instance._extraction_mutex.unlock()

		if task:
			var result = task.callable.call()

			if task.callback.is_valid():
				# Use thread-safe callback queue instead of call_deferred
				# (call_deferred from threads is unreliable on Android)
				_instance._lp_callback_mutex.lock()
				_instance._lp_callbacks.append({"callback": task.callback, "result": result})
				_instance._lp_callback_mutex.unlock()

static func is_shutting_down() -> bool:
	return _instance == null or _instance._exit_flag

static func _download_worker():
	while not _instance._exit_flag:
		_instance._download_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._download_mutex.lock()
		var task = _instance._download_queue.pop_front()
		_instance._download_mutex.unlock()

		if task:
			if task.get("cancelled", false):
				continue
			var result = task.callable.call()

			if task.callback.is_valid():
				# Use thread-safe callback queue instead of call_deferred
				# (call_deferred from threads is unreliable on Android)
				_instance._lp_callback_mutex.lock()
				_instance._lp_callbacks.append({"callback": task.callback, "result": result})
				_instance._lp_callback_mutex.unlock()

static func _sync_worker():
	while not _instance._exit_flag:
		_instance._sync_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._sync_mutex.lock()
		var task = _instance._sync_queue.pop_front()
		_instance._sync_mutex.unlock()

		if task:
			var result = task.callable.call()

			if task.callback.is_valid():
				# Use thread-safe callback queue instead of call_deferred
				_instance._lp_callback_mutex.lock()
				_instance._lp_callbacks.append({"callback": task.callback, "result": result})
				_instance._lp_callback_mutex.unlock()

static func _os_execute_worker():
	while not _instance._exit_flag:
		_instance._os_execute_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._os_execute_mutex.lock()
		var task = _instance._os_execute_queue.pop_front()
		_instance._os_execute_mutex.unlock()

		if task:
			var result = task.callable.call()

			if task.callback.is_valid():
				# Use thread-safe callback queue instead of call_deferred
				# (call_deferred from threads is unreliable on Android)
				_instance._lp_callback_mutex.lock()
				_instance._lp_callbacks.append({'callback': task.callback, 'result': result})
				_instance._lp_callback_mutex.unlock()

func _execute_callback(callback: Callable, result):
	if _callback_has_freed_capture(callback):
		return
	callback.call(result)

# ============================================================================
# THREAD QUEUE METHODS (from thread_manager)
# ============================================================================

## True when called on the DB worker thread. Write helpers use this to stay
## synchronous inside an outer DB task (preserving FIFO/atomicity) while
## queueing when invoked from the main thread.
static func is_db_thread() -> bool:
	# Thread.get_id() is a String; OS.get_thread_caller_id() is an int.
	return _instance != null and _instance._db_thread != null \
		and OS.get_thread_caller_id() == int(_instance._db_thread.get_id())

static func queue_db_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue DB task")
		return
	# Shutdown race: async view callbacks can outlive the worker pools (e.g.
	# the startup benchmark's instant quit). Dropping silently is correct —
	# the app is exiting and no result will be consumed.
	if _instance._exit_flag:
		return

	var is_main_thread = OS.get_thread_caller_id() == OS.get_main_thread_id()

	_instance._db_mutex.lock()
	var current_size = _instance._db_queue.size()
	_instance._db_mutex.unlock()

	# If queue is full, wait with thread-safe sleep (background threads cannot access SceneTree).
	# Main-thread callers get headroom past the cap (freezing the UI on
	# backpressure is worse), but not unlimited headroom: past the overflow
	# limit we drop with a null callback, the same contract as the image queue,
	# so callers run their fallback instead of queueing unboundedly.
	if not is_main_thread:
		if current_size >= MAX_DB_QUEUE_SIZE:
			print("[SystemManager.memory] WARNING: DB queue saturated (%d), throttling background producer" % current_size)
		while current_size >= MAX_DB_QUEUE_SIZE:
			OS.delay_msec(10)
			_instance._db_mutex.lock()
			current_size = _instance._db_queue.size()
			_instance._db_mutex.unlock()
	elif current_size >= MAX_DB_QUEUE_SIZE + MAX_DB_QUEUE_MAIN_OVERFLOW:
		push_error("[SystemManager.memory] DB queue overflow (%d); dropping main-thread task" % current_size)
		if callback.is_valid():
			_instance.call_deferred("_execute_callback", callback, null)
		return
	elif current_size >= MAX_DB_QUEUE_SIZE and current_size % 100 == 0:
		print("[SystemManager.memory] WARNING: DB queue at %d tasks (main-thread producer past soft cap)" % current_size)

	_instance._db_mutex.lock()
	_instance._db_queue.append({"callable": callable, "callback": callback})
	_instance._db_mutex.unlock()
	_instance._db_semaphore.post()

static func queue_image_task(callable: Callable, callback: Callable = Callable(), high_priority: bool = false, dedup_key: String = "") -> int:
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue image task")
		return -1
	# Shutdown race, same as queue_db_task.
	if _instance._exit_flag:
		return -1

	_instance._image_mutex.lock()

	# If dedup_key provided and an identical task is already in flight, queue callback for coalescing
	if dedup_key != "" and _instance._inflight_image_callbacks.has(dedup_key):
		_instance._inflight_image_callbacks[dedup_key].append({"callback": callback, "high_priority": high_priority})
		# Promote the underlying task if a high-priority waiter arrived for low-priority work
		if high_priority and _instance._dedup_task_ids.has(dedup_key):
			var existing_id: int = _instance._dedup_task_ids[dedup_key]
			if _instance._image_tasks.has(existing_id):
				var existing_task = _instance._image_tasks[existing_id]
				if not existing_task.cancelled and not existing_task.high_priority:
					_move_task_between_queues_locked(existing_task, true)
		_instance._image_mutex.unlock()
		return -1

	var total_size = _instance._image_high_priority_queue.size() + _instance._image_low_priority_queue.size()

	if total_size >= MAX_IMAGE_QUEUE_SIZE:
		if _instance._image_low_priority_queue.size() > 0 and high_priority:
			var evicted = _instance._image_low_priority_queue.pop_front()
			if _instance._image_tasks.has(evicted.id):
				evicted.cancelled = true
				_instance._image_tasks.erase(evicted.id)
				if evicted.callback.is_valid():
					_instance.call_deferred("_execute_callback", evicted.callback, null)
		else:
			# Never drop silently: fire a null callback (same as the eviction
			# path above) so callers run their retry/fallback logic instead of
			# waiting on a callback that would never arrive.
			_instance._image_mutex.unlock()
			_instance.call_deferred("_execute_callback", callback, null)
			return -1

	_instance._image_task_counter += 1
	var task_id = _instance._image_task_counter

	var task = {
		"id": task_id,
		"callable": callable,
		"callback": callback,
		"cancelled": false,
		"high_priority": high_priority,
		"dedup_key": dedup_key
	}

	_instance._image_tasks[task_id] = task

	if dedup_key != "":
		_instance._inflight_image_callbacks[dedup_key] = []
		_instance._dedup_task_ids[dedup_key] = task_id

	if high_priority:
		_instance._image_high_priority_queue.append(task)
	else:
		_instance._image_low_priority_queue.append(task)

	_instance._image_mutex.unlock()
	_instance._image_semaphore.post()

	return task_id

static func cancel_image_task(task_id: int) -> bool:
	if _instance == null or task_id <= 0:
		return false

	_instance._image_mutex.lock()

	if _instance._image_tasks.has(task_id):
		var task = _instance._image_tasks[task_id]
		task.cancelled = true
		_instance._image_tasks.erase(task_id)
		# Drain coalesced callbacks for this dedup_key so waiters aren't dropped silently
		var coalesced = []
		if task.dedup_key != "" and _instance._inflight_image_callbacks.has(task.dedup_key):
			coalesced = _instance._inflight_image_callbacks[task.dedup_key]
			_instance._inflight_image_callbacks.erase(task.dedup_key)
			_instance._dedup_task_ids.erase(task.dedup_key)

		var queue = _instance._image_high_priority_queue if task.high_priority else _instance._image_low_priority_queue
		for i in range(queue.size()):
			if queue[i].id == task_id:
				queue.remove_at(i)
				break

		_instance._image_mutex.unlock()

		for waiting in coalesced:
			if waiting.callback.is_valid():
				_instance.call_deferred("_execute_callback", waiting.callback, null)
		return true

	_instance._image_mutex.unlock()
	return false

## Drain every queued (not yet executing) image task from both priority queues.
## In-flight tasks and the worker threads themselves are untouched, and game
## downloads run on separate queues, so they are unaffected. Drained waiters
## receive a null callback (same contract as cancellation/eviction) so callers
## run their fallback logic instead of waiting forever; pass fire_callbacks =
## false when the tree is being torn down. Returns the drain count.
static func clear_pending_image_tasks(fire_callbacks: bool = true) -> int:
	if _instance == null:
		return 0

	_instance._image_mutex.lock()

	var drained_callbacks: Array = []
	var drained_count := 0
	for queue in [_instance._image_high_priority_queue, _instance._image_low_priority_queue]:
		for task in queue:
			task.cancelled = true
			_instance._image_tasks.erase(task.id)
			if task.callback.is_valid():
				drained_callbacks.append(task.callback)
			# Drain coalesced waiters on this dedup_key so they aren't dropped silently
			if task.dedup_key != "" and _instance._inflight_image_callbacks.has(task.dedup_key):
				for waiting in _instance._inflight_image_callbacks[task.dedup_key]:
					if waiting.callback.is_valid():
						drained_callbacks.append(waiting.callback)
				_instance._inflight_image_callbacks.erase(task.dedup_key)
				_instance._dedup_task_ids.erase(task.dedup_key)
			drained_count += 1
		queue.clear()

	_instance._image_mutex.unlock()

	if fire_callbacks:
		for cb in drained_callbacks:
			_instance.call_deferred("_execute_callback", cb, null)
	return drained_count

## Drain only the LOW-priority image queue: in-flight tasks and high-priority
## loads (hero art, details sheets, visible cards) are untouched. Used on grid
## teleports (random-game jump, focus restore), where every queued low task is
## directional prefetch for a window nobody is looking at anymore - draining
## frees the workers for the new window instead of spending a share of decode
## throughput (and texture-cache slots) on stale covers. Drained waiters get a
## null callback (same contract as cancellation); pass fire_callbacks = false
## when the tree is being torn down. Returns the drain count.
static func clear_pending_low_priority_image_tasks(fire_callbacks: bool = true) -> int:
	if _instance == null:
		return 0

	_instance._image_mutex.lock()

	var drained_callbacks: Array = []
	var drained_count := 0
	for task in _instance._image_low_priority_queue:
		task.cancelled = true
		_instance._image_tasks.erase(task.id)
		if task.callback.is_valid():
			drained_callbacks.append(task.callback)
		# Drain coalesced waiters on this dedup_key so they aren't dropped silently
		if task.dedup_key != "" and _instance._inflight_image_callbacks.has(task.dedup_key):
			for waiting in _instance._inflight_image_callbacks[task.dedup_key]:
				if waiting.callback.is_valid():
					drained_callbacks.append(waiting.callback)
			_instance._inflight_image_callbacks.erase(task.dedup_key)
			_instance._dedup_task_ids.erase(task.dedup_key)
		drained_count += 1
	_instance._image_low_priority_queue.clear()

	_instance._image_mutex.unlock()

	if fire_callbacks:
		for cb in drained_callbacks:
			_instance.call_deferred("_execute_callback", cb, null)
	return drained_count

## Low-priority decode gate, owner-refcounted. While ANY holder has the gate,
## image workers only pull high-priority tasks. Previously a bare bool two
## live grids could fight over (whichever grid's scroll pass ran last won);
## now each holder acquires/releases by owner id and _exit_tree releases its
## own id. On un-gate, re-post one semaphore wake per queued low-priority
## task: their original posts were consumed by workers that (correctly)
## refused to pop them while the gate was closed.
static func acquire_low_priority_gate(owner_id: int) -> void:
	if _instance == null:
		return
	_instance._image_mutex.lock()
	_instance._low_priority_gate_holders[owner_id] = true
	_instance._image_mutex.unlock()
	_refresh_low_priority_gate()

static func release_low_priority_gate(owner_id: int) -> void:
	if _instance == null:
		return
	_instance._image_mutex.lock()
	var had: bool = _instance._low_priority_gate_holders.erase(owner_id)
	_instance._image_mutex.unlock()
	if had:
		_refresh_low_priority_gate()

static func _refresh_low_priority_gate() -> void:
	if _instance == null:
		return
	_instance._image_mutex.lock()
	var gated := not _instance._low_priority_gate_holders.is_empty()
	var was_gated := _instance._low_priority_gated
	_instance._low_priority_gated = gated
	var pending := _instance._image_low_priority_queue.size() if (was_gated and not gated) else 0
	_instance._image_mutex.unlock()
	for i in pending:
		_instance._image_semaphore.post()

static func update_image_priority(task_id: int, high_priority: bool) -> bool:
	if _instance == null or task_id <= 0:
		return false

	_instance._image_mutex.lock()

	if not _instance._image_tasks.has(task_id):
		_instance._image_mutex.unlock()
		return false

	var task = _instance._image_tasks[task_id]

	if task.cancelled:
		_instance._image_mutex.unlock()
		return false

	if task.high_priority == high_priority:
		_instance._image_mutex.unlock()
		return true

	_move_task_between_queues_locked(task, high_priority)

	_instance._image_mutex.unlock()
	return true

# Moves a task between the high/low priority queues.
# Assumes _instance._image_mutex is already held by the caller.
static func _move_task_between_queues_locked(task: Dictionary, to_high_priority: bool) -> void:
	task.high_priority = to_high_priority

	var from_queue = _instance._image_high_priority_queue if not to_high_priority else _instance._image_low_priority_queue
	var to_queue = _instance._image_high_priority_queue if to_high_priority else _instance._image_low_priority_queue

	for i in range(from_queue.size()):
		if from_queue[i].id == task.id:
			from_queue.remove_at(i)
			to_queue.append(task)
			break

## Cache keys must include the decoded size variant: cards decode covers to
## 512px while hero/background layers decode the same file to 1024px, and
## sharing a bare path key lets whichever loads first poison the other.
static func cover_cache_key(cache_path: String, max_texture_size: int) -> String:
	return "%s#%d" % [cache_path, max_texture_size]

static func get_cached_texture(cache_key: String) -> Texture2D:
	if _instance == null or cache_key == "":
		return null

	_instance._texture_cache_mutex.lock()
	if _instance._texture_cache.has(cache_key):
		# Move to back (most recently used). Dictionary preserves insertion
		# order, so erase+re-set is an O(1) LRU refresh.
		var tex = _instance._texture_cache[cache_key]
		_instance._texture_cache.erase(cache_key)
		_instance._texture_cache[cache_key] = tex
		_instance._texture_cache_mutex.unlock()
		return tex
	_instance._texture_cache_mutex.unlock()
	return null

static func cache_texture(cache_key: String, texture: Texture2D) -> void:
	if _instance == null or cache_key == "" or texture == null:
		return

	_instance._texture_cache_mutex.lock()

	# Replace existing entry: refresh recency and keep memory accounting exact
	if _instance._texture_cache.has(cache_key):
		var old_tex = _instance._texture_cache[cache_key]
		_instance._texture_cache_memory = maxi(0, _instance._texture_cache_memory - _estimate_texture_memory(old_tex))
		_instance._texture_cache.erase(cache_key)

	var cache_limit = get_max_texture_cache_size()
	var memory_limit = get_max_texture_cache_memory_bytes()
	var tex_memory = _estimate_texture_memory(texture)

	# Evict oldest (front of the insertion-ordered Dictionary). The BYTE
	# estimate is the primary eviction metric; the entry count cap is a
	# secondary backstop. Pinned textures are skipped so currently-visible
	# covers never disappear.
	var examined: int = 0
	var evicted_count: int = 0
	var evicted_bytes: int = 0
	while (_instance._texture_cache.size() >= cache_limit or
		   (_instance._texture_cache_memory + tex_memory) > memory_limit) and not _instance._texture_cache.is_empty():
		var oldest_key: String = _instance._texture_cache.keys()[0]
		if _instance._pinned_texture_keys.get(oldest_key, 0) > 0:
			# Oldest entry is pinned: move it to the back and look at the next one.
			var tex = _instance._texture_cache[oldest_key]
			_instance._texture_cache.erase(oldest_key)
			_instance._texture_cache[oldest_key] = tex
			examined += 1
			# If every entry is pinned we cannot make room; break to avoid an
			# infinite loop and let the new texture be added anyway.
			if examined >= _instance._texture_cache.size():
				break
			continue
		var oldest_tex = _instance._texture_cache.get(oldest_key, null)
		var freed := 0
		if oldest_tex:
			freed = _estimate_texture_memory(oldest_tex)
			_instance._texture_cache_memory = maxi(0, _instance._texture_cache_memory - freed)
		if DEBUG_CACHE_LOG:
			# Keys are "<path>#<decode bucket>"; log the bucket so cache audits
			# can spot duplicate (path, bucket) variants and hit-rate trouble.
			var bucket := oldest_key.get_slice("#", oldest_key.get_slice_count("#") - 1)
			var reason := "bytes" if (_instance._texture_cache_memory + tex_memory) > memory_limit else "count"
			print("[Memory] evict %s#%s reason=%s freed=%.1fKB cache=%.1fMB/%d entries" % [oldest_key.get_slice("#", 0).get_file(), bucket, reason, freed / 1024.0, _instance._texture_cache_memory / 1048576.0, _instance._texture_cache.size()])
		evicted_count += 1
		evicted_bytes += freed
		_instance._texture_cache.erase(oldest_key)
		examined = 0
	if DEBUG_CACHE_LOG and evicted_count > 1:
		print("[Memory] evicted %d textures (%.1fKB) for %s" % [evicted_count, evicted_bytes / 1024.0, cache_key.get_slice("#", 0).get_file()])

	_instance._texture_cache[cache_key] = texture
	_instance._texture_cache_memory += tex_memory
	_instance._texture_cache_mutex.unlock()

static func clear_texture_cache() -> void:
	if _instance == null:
		return
	_instance._texture_cache_mutex.lock()
	_instance._texture_cache.clear()
	_instance._pinned_texture_keys.clear()
	_instance._texture_cache_memory = 0
	_instance._texture_cache_mutex.unlock()


## Pin a texture so the LRU evictor will not drop it. Multiple callers can pin
## the same key (refcounted); it is only unpinned when the last caller releases.
static func pin_texture(cache_key: String) -> void:
	if _instance == null or cache_key == "":
		return
	_instance._texture_cache_mutex.lock()
	_instance._pinned_texture_keys[cache_key] = _instance._pinned_texture_keys.get(cache_key, 0) + 1
	_instance._texture_cache_mutex.unlock()


static func unpin_texture(cache_key: String) -> void:
	if _instance == null or cache_key == "":
		return
	_instance._texture_cache_mutex.lock()
	var refcount: int = _instance._pinned_texture_keys.get(cache_key, 0)
	refcount -= 1
	if refcount <= 0:
		_instance._pinned_texture_keys.erase(cache_key)
	else:
		_instance._pinned_texture_keys[cache_key] = refcount
	_instance._texture_cache_mutex.unlock()


static func prepare_image_for_texture(image: Image) -> Image:
	"""Worker-thread helper: duplicate + convert an Image to RGBA8 so the main
	thread only pays for the ImageTexture upload in create_texture_from_image."""
	if image == null or image.is_empty():
		return null
	var img := image.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.is_empty():
		return null
	return img

static func create_texture_from_image(image: Image) -> Texture2D:
	"""Create an ImageTexture from an Image, converting unsupported formats first.

	Godot's internal format conversion during ImageTexture.create_from_image
	can trigger _texture_2d_update with an empty image on some hardware/drivers.
	This helper converts every image to RGBA8 up-front and guards empty/null images.
	Images already prepared by prepare_image_for_texture skip the duplicate+convert.
	"""
	if image == null or image.is_empty():
		return null

	var img := image
	if img.get_format() != Image.FORMAT_RGBA8:
		img = image.duplicate()
		img.convert(Image.FORMAT_RGBA8)

	if img.is_empty():
		return null

	return ImageTexture.create_from_image(img)

static func queue_extraction_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue extraction task")
		return

	_instance._extraction_mutex.lock()
	var current_size = _instance._extraction_queue.size()

	if current_size >= MAX_EXTRACTION_QUEUE_SIZE:
		_instance._extraction_mutex.unlock()
		_extraction_overflow_count += 1
		push_error("[SystemManager.memory] Extraction queue full - dropping task (overflow count=" + str(_extraction_overflow_count) + ")")
		if callback.is_valid():
			callback.call_deferred(false)
		return

	_instance._extraction_queue.append({"callable": callable, "callback": callback})
	_instance._extraction_mutex.unlock()
	_instance._extraction_semaphore.post()

## Queues a callback to run on the main thread during the next _process tick.
## Safe to call from background threads when call_deferred is unreliable on
## Android. Drained via the uncapped _mt_callbacks queue ahead of the lp queue
## so rare, latency-critical hops (e.g. sync completion) aren't held back.
static func queue_main_thread_callback(callback: Callable, args: Array = []):
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue main thread callback")
		return
	if _instance._exit_flag:
		return

	_instance._mt_callback_mutex.lock()
	_instance._mt_callbacks.append({"callback": callback, "args": args})
	_instance._mt_callback_mutex.unlock()

## Queues an OS.execute() call to run on a dedicated background thread pool.
## Calls back on the main thread with {exit_code: int, output: Array[String]}.
static func queue_os_execute(path: String, arguments: Array = [], callback: Callable = Callable()):
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue OS execute")
		return

	_instance._os_execute_mutex.lock()

	if _instance._os_execute_queue.size() >= MAX_OS_EXECUTE_QUEUE_SIZE:
		_instance._os_execute_mutex.unlock()
		push_error("[SystemManager.memory] OS execute queue full - cannot queue command")
		if callback.is_valid():
			callback.call_deferred({"exit_code": -1, "output": []})
		return

	_instance._os_execute_queue.append({
		"callable": func():
			var output: Array[String] = []
			var exit_code := OS.execute(path, arguments, output, true)
			return {"exit_code": exit_code, "output": output},
		"callback": func(result):
			if callback.is_valid():
				queue_main_thread_callback(func(): callback.call(result))
	})
	_instance._os_execute_mutex.unlock()
	_instance._os_execute_semaphore.post()

## Queues a task to the sync thread for background metadata sync
## This runs the entire sync orchestration off the main thread
static func queue_sync_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue sync task")
		return

	_instance._sync_mutex.lock()
	var current_size = _instance._sync_queue.size()

	if current_size >= MAX_SYNC_QUEUE_SIZE:
		_instance._sync_mutex.unlock()
		push_error("[SystemManager.memory] Sync queue full - cannot queue task")
		if callback.is_valid():
			callback.call_deferred(false)
		return

	_instance._sync_queue.append({"callable": callable, "callback": callback})
	_instance._sync_mutex.unlock()
	_instance._sync_semaphore.post()

## Queues a parallel download batch using dedicated download threads
## Each item is processed in parallel across DOWNLOAD_THREAD_COUNT threads
## Returns batch ID for tracking progress
static func queue_parallel_downloads(
	items: Array,
	process_item: Callable,
	on_progress: Callable = Callable(),
	on_complete: Callable = Callable()
) -> int:
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot queue parallel downloads")
		return -1

	if items.is_empty():
		if on_complete.is_valid():
			on_complete.call([])
		return -1

	var batch = DownloadBatch.new(items, process_item, on_progress, on_complete)

	_instance._download_batch_mutex.lock()
	_instance._download_batches[batch.id] = batch
	_instance._download_batch_mutex.unlock()

	# Queue all items to the download thread pool
	for i in range(items.size()):
		var item = items[i]
		var index = i

		_instance._download_mutex.lock()

		# If queue is full, wait non-blocking with timer
		while _instance._download_queue.size() >= MAX_DOWNLOAD_QUEUE_SIZE:
			_instance._download_mutex.unlock()
			await _instance.get_tree().create_timer(0.01).timeout
			if _instance == null or _instance._exit_flag:
				return -1
			_instance._download_mutex.lock()

		_instance._download_queue.append({
			"callable": func():
				return process_item.call(item, index),
			"callback": func(result):
				SystemManager.memory._on_download_chunk_complete(batch.id, index, result),
			"batch_id": batch.id,
			"cancelled": false
		})
		_instance._download_mutex.unlock()
		_instance._download_semaphore.post()

	return batch.id

static func _on_download_chunk_complete(batch_id: int, index: int, result):
	_instance._download_batch_mutex.lock()

	if not _instance._download_batches.has(batch_id):
		_instance._download_batch_mutex.unlock()
		return

	var batch = _instance._download_batches[batch_id]
	batch.completed_count += 1
	batch.results[index] = result

	# Copy callback state; callbacks are invoked AFTER unlocking so they can
	# safely call cancel_download_batch (non-recursive mutex).
	var on_progress = batch.on_progress
	var completed_count = batch.completed_count
	var total_count = batch.total_count
	var is_now_complete = batch.completed_count >= batch.total_count and not batch.is_complete
	var on_complete = Callable()
	var final_results = null
	if is_now_complete:
		batch.is_complete = true
		on_complete = batch.on_complete
		final_results = batch.results
		_instance._download_batches.erase(batch_id)
	_instance._download_batch_mutex.unlock()

	# Report progress (include index and result for per-item tracking)
	if on_progress.is_valid():
		on_progress.call(completed_count, total_count, index, result)

	if is_now_complete and on_complete.is_valid():
		on_complete.call(final_results)

static func cancel_download_batch(batch_id: int) -> bool:
	if _instance == null:
		return false

	_instance._download_batch_mutex.lock()
	var cancelled = _instance._download_batches.erase(batch_id)
	_instance._download_batch_mutex.unlock()

	# Mark queued (not yet started) tasks for this batch so workers skip them
	if cancelled:
		_instance._download_mutex.lock()
		for task in _instance._download_queue:
			if task.get("batch_id", -1) == batch_id:
				task.cancelled = true
		_instance._download_mutex.unlock()
	return cancelled

static func shutdown():
	if _instance == null:
		return
	_instance._exit_flag = true

	# Clear all pending work so threads don't start new tasks after waking.
	_instance._db_mutex.lock()
	_instance._db_queue.clear()
	_instance._db_mutex.unlock()

	_instance._image_mutex.lock()
	_instance._image_high_priority_queue.clear()
	_instance._image_low_priority_queue.clear()
	_instance._image_tasks.clear()
	_instance._inflight_image_callbacks.clear()
	_instance._image_mutex.unlock()

	_instance._extraction_mutex.lock()
	_instance._extraction_queue.clear()
	_instance._extraction_mutex.unlock()

	_instance._download_mutex.lock()
	_instance._download_queue.clear()
	_instance._download_mutex.unlock()

	_instance._os_execute_mutex.lock()
	_instance._os_execute_queue.clear()
	_instance._os_execute_mutex.unlock()

	_instance._sync_mutex.lock()
	_instance._sync_queue.clear()
	_instance._sync_mutex.unlock()

	_instance._lp_callback_mutex.lock()
	_instance._lp_callbacks.clear()
	_instance._lp_callback_head = 0
	_instance._lp_callback_mutex.unlock()

	# Wake all threads so they can observe the exit flag and terminate.
	_instance._db_semaphore.post()
	_instance._extraction_semaphore.post()
	_instance._download_semaphore.post()
	_instance._os_execute_semaphore.post()
	_instance._sync_semaphore.post()
	for i in range(IMAGE_THREAD_COUNT):
		_instance._image_semaphore.post()
	# Post semaphore for each download thread that was created
	for thread in _instance._download_threads:
		_instance._download_semaphore.post()
	# Post semaphore for each OS execute thread that was created
	for thread in _instance._os_execute_threads:
		_instance._os_execute_semaphore.post()
	_instance._db_thread.wait_to_finish()
	for thread in _instance._image_threads:
		thread.wait_to_finish()
	_instance._extraction_thread.wait_to_finish()
	for thread in _instance._download_threads:
		thread.wait_to_finish()
	for thread in _instance._os_execute_threads:
		thread.wait_to_finish()
	if _instance._sync_thread:
		_instance._sync_thread.wait_to_finish()

	clear_texture_cache()
	# Release static caches held by UI components so their Texture/CanvasItem RIDs
	# are not leaked when the rendering server finalizes.
	GameCard.clear_platform_icon_cache()
	CardMediaLoader.clear_failed_downloads()
	EffectStack.clear_script_cache()
	_instance = null

# ============================================================================
# BATCH SCHEDULING (NEW)
# ============================================================================

## Starts a new batch process that will be processed across multiple frames
## Returns the batch ID that can be used to check status or cancel
static func start_batch(
	items: Array,
	process_item: Callable,
	mode: int = BatchMode.SYNC,
	batch_size: int = 10,
	on_progress: Callable = Callable(),
	on_complete: Callable = Callable(),
	frame_budget_us: int = 0
) -> int:
	if _instance == null:
		push_error("[SystemManager.memory] Not initialized - cannot start batch")
		return -1

	if items.is_empty():
		if on_complete.is_valid():
			on_complete.call([])
		return -1

	var batch = BatchProcess.new(items, process_item, mode, batch_size, on_progress, on_complete, frame_budget_us)

	_instance._batch_mutex.lock()
	_instance._batch_processes.append(batch)
	_instance._batch_mutex.unlock()

	return batch.id

## Cancels a running batch process
static func cancel_batch(batch_id: int) -> bool:
	if _instance == null:
		return false

	_instance._batch_mutex.lock()
	for i in range(_instance._batch_processes.size()):
		if _instance._batch_processes[i].id == batch_id:
			# Mark cancelled so in-flight async callbacks don't fire on_complete.
			_instance._batch_processes[i].cancelled = true
			_instance._batch_processes.remove_at(i)
			_instance._batch_mutex.unlock()
			return true
	_instance._batch_mutex.unlock()
	return false

func _process_batches():
	_batch_mutex.lock()
	var processes_copy = _batch_processes.duplicate()
	_batch_mutex.unlock()

	for batch in processes_copy:
		if batch.is_complete or batch.cancelled:
			continue

		# Check if previous async operations are complete
		if batch.pending_callbacks > 0:
			continue

		# Time-budgeted SYNC chunks: process items until the frame budget is
		# exhausted (batch_size stays the upper cap, and at least one item per
		# frame is always processed so no batch can starve). Fixed-count for
		# everything else: async modes don't burn main-thread time per item.
		if batch.mode == BatchMode.SYNC and batch.frame_budget_us > 0:
			WarmupBudget.tag("batches")
			var chunk_start_us := Time.get_ticks_usec()
			var chunk_end := mini(batch.current_index + batch.batch_size, batch.items.size())
			while batch.current_index < chunk_end:
				batch.pending_callbacks += 1
				_process_batch_item(batch, batch.current_index)
				batch.current_index += 1
				if Time.get_ticks_usec() - chunk_start_us >= batch.frame_budget_us:
					break
		else:
			var end_index = mini(batch.current_index + batch.batch_size, batch.items.size())
			var items_this_frame = end_index - batch.current_index

			if items_this_frame <= 0:
				continue

			WarmupBudget.tag("batches")

			# Process this batch
			for i in range(batch.current_index, end_index):
				batch.pending_callbacks += 1
				_process_batch_item(batch, i)

			batch.current_index = end_index

		# Report progress
		if batch.on_progress.is_valid():
			batch.on_progress.call(batch.current_index, batch.items.size())

		# Check for completion
		if batch.current_index >= batch.items.size() and batch.pending_callbacks == 0:
			_complete_batch(batch)

func _process_batch_item(batch: BatchProcess, index: int):
	var item = batch.items[index]

	match batch.mode:
		BatchMode.SYNC:
			# Process immediately on main thread
			var result = batch.process_item.call(item, index)
			batch.results[index] = result
			batch.pending_callbacks -= 1

		BatchMode.DB_THREAD:
			# Queue to DB thread
			queue_db_task(
				func():
					return batch.process_item.call(item, index),
				func(result):
					batch.results[index] = result
					batch.pending_callbacks -= 1
					_check_batch_completion(batch)
			)

		BatchMode.IMAGE_THREAD:
			# Queue to image thread
			queue_image_task(
				func():
					return batch.process_item.call(item, index),
				func(result):
					batch.results[index] = result
					batch.pending_callbacks -= 1
					_check_batch_completion(batch)
			)

func _check_batch_completion(batch: BatchProcess):
	# Check if batch is complete (called from callbacks)
	if batch.cancelled:
		return
	if batch.current_index >= batch.items.size() and batch.pending_callbacks == 0:
		_complete_batch(batch)

func _complete_batch(batch: BatchProcess):
	if batch.is_complete or batch.cancelled:
		return

	batch.is_complete = true

	if batch.on_complete.is_valid():
		batch.on_complete.call(batch.results)

	# Remove from active processes
	_batch_mutex.lock()
	for i in range(_batch_processes.size()):
		if _batch_processes[i].id == batch.id:
			_batch_processes.remove_at(i)
			break
	_batch_mutex.unlock()
