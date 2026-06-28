#memory_manager.gd
extends Node
class_name MemoryManager

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

var _texture_cache: Dictionary = {}
var _texture_cache_order: Array[String] = []
var _texture_cache_mutex: Mutex
const MAX_TEXTURE_CACHE_SIZE: int = 400
const MAX_TEXTURE_CACHE_MEMORY_MB: int = 300
const MAX_TEXTURE_CACHE_MEMORY_MB_ANDROID: int = 100
var _texture_cache_memory: int = 0  # Estimated bytes currently cached

static func get_max_texture_cache_size() -> int:
	if PlatformManager.is_android():
		return 150
	return MAX_TEXTURE_CACHE_SIZE

static func get_max_texture_cache_memory_bytes() -> int:
	if PlatformManager.is_android():
		return MAX_TEXTURE_CACHE_MEMORY_MB_ANDROID * 1024 * 1024
	return MAX_TEXTURE_CACHE_MEMORY_MB * 1024 * 1024

static func _estimate_texture_memory(texture: Texture2D) -> int:
	if texture == null:
		return 0
	return texture.get_width() * texture.get_height() * 4  # RGBA8 estimate

var _lp_callbacks: Array = []
var _lp_callback_mutex: Mutex
const MAX_LP_CALLBACKS_PER_FRAME: int = 15

const IMAGE_THREAD_COUNT: int = 6
const MAX_IMAGE_QUEUE_SIZE = 600
const MAX_DB_QUEUE_SIZE = 50
const MAX_EXTRACTION_QUEUE_SIZE = 5
const MAX_DOWNLOAD_QUEUE_SIZE = 500
const MAX_SYNC_QUEUE_SIZE = 10
const OS_EXECUTE_THREAD_COUNT: int = 2
const MAX_OS_EXECUTE_QUEUE_SIZE = 100

## Returns the number of download threads for the current platform
static func get_download_thread_count() -> int:
	if PlatformManager.is_android():
		return 2  # Android: conservative for battery/heat
	return 12  # Desktop: more threads for speed

static var _instance: MemoryManager = null

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
	var current_index: int = 0
	var on_progress: Callable  # func(processed_count, total_count)
	var on_complete: Callable  # func(results: Array)
	var is_complete: bool = false
	var results: Array = []
	var pending_callbacks: int = 0  # Track async callbacks in flight
	var id: int

	static var _next_id: int = 0

	func _init(p_items: Array, p_process_item: Callable, p_mode: int, p_batch_size: int, 
			   p_on_progress: Callable = Callable(), p_on_complete: Callable = Callable()):
		items = p_items
		process_item = p_process_item
		mode = p_mode
		batch_size = p_batch_size
		on_progress = p_on_progress
		on_complete = p_on_complete
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
	print("[MemoryManager] Initializing " + str(download_thread_count) + " download threads")

	for i in range(download_thread_count):
		var thread = Thread.new()
		thread.start(_download_worker)
		_download_threads.append(thread)

	# Dedicated thread pool for OS.execute calls (AHK window management, etc.)
	# This keeps short-lived shell tools off the download thread pool so long
	# downloads don't stall process control operations.
	print("[MemoryManager] Initializing " + str(OS_EXECUTE_THREAD_COUNT) + " OS execute threads")

	for i in range(OS_EXECUTE_THREAD_COUNT):
		var thread = Thread.new()
		thread.start(_os_execute_worker)
		_os_execute_threads.append(thread)

	# Start sync thread for background metadata sync
	print("[MemoryManager] Initializing sync thread")
	_sync_thread = Thread.new()
	_sync_thread.start(_sync_worker)

func _ready():
	set_process(true)

func _exit_tree():
	shutdown()

func _process(_delta):
	_process_batches()
	_drain_lp_callbacks()

func _drain_lp_callbacks():
	if _lp_callbacks.is_empty():
		return

	_lp_callback_mutex.lock()
	var to_process = mini(_lp_callbacks.size(), MAX_LP_CALLBACKS_PER_FRAME)
	var batch = _lp_callbacks.slice(0, to_process)
	_lp_callbacks = _lp_callbacks.slice(to_process)
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
				_instance.call_deferred("_execute_callback", task.callback, result)

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
		elif low_size > 0:
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

static func _download_worker():
	while not _instance._exit_flag:
		_instance._download_semaphore.wait()

		if _instance._exit_flag:
			break

		_instance._download_mutex.lock()
		var task = _instance._download_queue.pop_front()
		_instance._download_mutex.unlock()

		if task:
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

static func queue_db_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue DB task")
		return

	var current_size = _instance._db_queue.size()

	# If queue is full, wait with thread-safe sleep (background threads cannot access SceneTree)
	while current_size >= MAX_DB_QUEUE_SIZE:
		OS.delay_msec(10)
		_instance._db_mutex.lock()
		current_size = _instance._db_queue.size()
		_instance._db_mutex.unlock()

	_instance._db_mutex.lock()
	_instance._db_queue.append({"callable": callable, "callback": callback})
	_instance._db_mutex.unlock()
	_instance._db_semaphore.post()

static func queue_image_task(callable: Callable, callback: Callable = Callable(), high_priority: bool = false, dedup_key: String = "") -> int:
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue image task")
		return -1

	_instance._image_mutex.lock()

	# If dedup_key provided and an identical task is already in flight, queue callback for coalescing
	if dedup_key != "" and _instance._inflight_image_callbacks.has(dedup_key):
		_instance._inflight_image_callbacks[dedup_key].append({"callback": callback, "high_priority": high_priority})
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
		elif not high_priority:
			_instance._image_mutex.unlock()
			return -1
		else:
			_instance._image_mutex.unlock()
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
		# Clean up coalesced callbacks for this dedup_key
		if task.dedup_key != "" and _instance._inflight_image_callbacks.has(task.dedup_key):
			_instance._inflight_image_callbacks.erase(task.dedup_key)

		var queue = _instance._image_high_priority_queue if task.high_priority else _instance._image_low_priority_queue
		for i in range(queue.size()):
			if queue[i].id == task_id:
				queue.remove_at(i)
				break

		_instance._image_mutex.unlock()
		return true

	_instance._image_mutex.unlock()
	return false

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

	task.high_priority = high_priority

	var from_queue = _instance._image_high_priority_queue if not high_priority else _instance._image_low_priority_queue
	var to_queue = _instance._image_high_priority_queue if high_priority else _instance._image_low_priority_queue

	for i in range(from_queue.size()):
		if from_queue[i].id == task_id:
			from_queue.remove_at(i)
			to_queue.append(task)
			break

	_instance._image_mutex.unlock()
	return true

static func get_cached_texture(cache_key: String) -> Texture2D:
	if _instance == null or cache_key == "":
		return null

	_instance._texture_cache_mutex.lock()
	if _instance._texture_cache.has(cache_key):
		var tex = _instance._texture_cache[cache_key]
		var idx = _instance._texture_cache_order.find(cache_key)
		if idx != -1:
			_instance._texture_cache_order.remove_at(idx)
			_instance._texture_cache_order.append(cache_key)
		_instance._texture_cache_mutex.unlock()
		return tex
	_instance._texture_cache_mutex.unlock()
	return null

static func cache_texture(cache_key: String, texture: Texture2D) -> void:
	if _instance == null or cache_key == "" or texture == null:
		return

	_instance._texture_cache_mutex.lock()

	if _instance._texture_cache.has(cache_key):
		# Refresh LRU order even for existing textures
		var idx = _instance._texture_cache_order.find(cache_key)
		if idx != -1:
			_instance._texture_cache_order.remove_at(idx)
			_instance._texture_cache_order.append(cache_key)
		_instance._texture_cache_mutex.unlock()
		return

	var cache_limit = get_max_texture_cache_size()
	var memory_limit = get_max_texture_cache_memory_bytes()
	var tex_memory = _estimate_texture_memory(texture)

	# Evict by count and/or memory limits
	while (_instance._texture_cache.size() >= cache_limit or 
		   (_instance._texture_cache_memory + tex_memory) > memory_limit) and _instance._texture_cache_order.size() > 0:
		var oldest_key = _instance._texture_cache_order.pop_front()
		var oldest_tex = _instance._texture_cache.get(oldest_key, null)
		if oldest_tex:
			_instance._texture_cache_memory -= _estimate_texture_memory(oldest_tex)
			_instance._texture_cache_memory = maxi(0, _instance._texture_cache_memory)
		_instance._texture_cache.erase(oldest_key)

	_instance._texture_cache[cache_key] = texture
	_instance._texture_cache_order.append(cache_key)
	_instance._texture_cache_memory += tex_memory
	_instance._texture_cache_mutex.unlock()

static func clear_texture_cache() -> void:
	if _instance == null:
		return
	_instance._texture_cache_mutex.lock()
	_instance._texture_cache.clear()
	_instance._texture_cache_order.clear()
	_instance._texture_cache_memory = 0
	_instance._texture_cache_mutex.unlock()


static func create_texture_from_image(image: Image) -> Texture2D:
	"""Create an ImageTexture from an Image, converting unsupported formats first.

	Godot's internal format conversion during ImageTexture.create_from_image
	can trigger _texture_2d_update with an empty image on some hardware/drivers.
	This helper converts every image to RGBA8 up-front and guards empty/null images.
	"""
	if image == null or image.is_empty():
		return null

	var img := image.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)

	if img.is_empty():
		return null

	return ImageTexture.create_from_image(img)

static func queue_extraction_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue extraction task")
		return

	_instance._extraction_mutex.lock()
	var current_size = _instance._extraction_queue.size()

	if current_size >= MAX_EXTRACTION_QUEUE_SIZE:
		_instance._extraction_mutex.unlock()
		push_error("[MemoryManager] Extraction queue full - cannot queue task")
		if callback.is_valid():
			callback.call_deferred(false)
		return

	_instance._extraction_queue.append({"callable": callable, "callback": callback})
	_instance._extraction_mutex.unlock()
	_instance._extraction_semaphore.post()

## Queues a callback to run on the main thread during the next _process tick.
## Safe to call from background threads when call_deferred is unreliable on Android.
static func queue_main_thread_callback(callback: Callable):
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue main thread callback")
		return

	_instance._lp_callback_mutex.lock()
	# Wrap so the existing _drain_lp_callbacks can pass its result argument
	# without requiring the user callback to accept one.
	_instance._lp_callbacks.append({"callback": func(_result): callback.call(), "result": null})
	_instance._lp_callback_mutex.unlock()

## Queues an OS.execute() call to run on a dedicated background thread pool.
## Calls back on the main thread with {exit_code: int, output: Array[String]}.
static func queue_os_execute(path: String, arguments: Array = [], callback: Callable = Callable()):
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue OS execute")
		return

	_instance._os_execute_mutex.lock()

	if _instance._os_execute_queue.size() >= MAX_OS_EXECUTE_QUEUE_SIZE:
		_instance._os_execute_mutex.unlock()
		push_error("[MemoryManager] OS execute queue full - cannot queue command")
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
		push_error("[MemoryManager] Not initialized - cannot queue sync task")
		return

	_instance._sync_mutex.lock()
	var current_size = _instance._sync_queue.size()

	if current_size >= MAX_SYNC_QUEUE_SIZE:
		_instance._sync_mutex.unlock()
		push_error("[MemoryManager] Sync queue full - cannot queue task")
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
		push_error("[MemoryManager] Not initialized - cannot queue parallel downloads")
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
			_instance._download_mutex.lock()

		_instance._download_queue.append({
			"callable": func():
				return process_item.call(item, index),
			"callback": func(result):
				MemoryManager._on_download_chunk_complete(batch.id, index, result)
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

	# Report progress (include index and result for per-item tracking)
	if batch.on_progress.is_valid():
		batch.on_progress.call(batch.completed_count, batch.total_count, index, result)

	# Check if all items complete
	if batch.completed_count >= batch.total_count and not batch.is_complete:
		batch.is_complete = true
		_instance._download_batch_mutex.unlock()

		if batch.on_complete.is_valid():
			batch.on_complete.call(batch.results)

		# Remove batch
		_instance._download_batch_mutex.lock()
		_instance._download_batches.erase(batch_id)
		_instance._download_batch_mutex.unlock()
	else:
		_instance._download_batch_mutex.unlock()

static func get_download_batch_progress(batch_id: int) -> float:
	if _instance == null:
		return 0.0

	_instance._download_batch_mutex.lock()
	if _instance._download_batches.has(batch_id):
		var batch = _instance._download_batches[batch_id]
		var progress = float(batch.completed_count) / float(batch.total_count)
		_instance._download_batch_mutex.unlock()
		return progress
	_instance._download_batch_mutex.unlock()
	return 1.0

static func cancel_download_batch(batch_id: int) -> bool:
	if _instance == null:
		return false

	_instance._download_batch_mutex.lock()
	var cancelled = _instance._download_batches.erase(batch_id)
	_instance._download_batch_mutex.unlock()
	return cancelled

static func get_db_queue_size() -> int:
	if _instance == null:
		return 0
	_instance._db_mutex.lock()
	var size = _instance._db_queue.size()
	_instance._db_mutex.unlock()
	return size

static func get_image_queue_size() -> int:
	if _instance == null:
		return 0
	_instance._image_mutex.lock()
	var size = _instance._image_high_priority_queue.size() + _instance._image_low_priority_queue.size()
	_instance._image_mutex.unlock()
	return size

static func get_extraction_queue_size() -> int:
	if _instance == null:
		return 0
	_instance._extraction_mutex.lock()
	var size = _instance._extraction_queue.size()
	_instance._extraction_mutex.unlock()
	return size

static func has_pending_tasks() -> bool:
	if _instance == null:
		return false

	var db_pending = get_db_queue_size()
	var image_pending = get_image_queue_size()
	var extraction_pending = get_extraction_queue_size()

	return db_pending > 0 or image_pending > 0 or extraction_pending > 0

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
	on_complete: Callable = Callable()
) -> int:
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot start batch")
		return -1

	if items.is_empty():
		if on_complete.is_valid():
			on_complete.call([])
		return -1

	var batch = BatchProcess.new(items, process_item, mode, batch_size, on_progress, on_complete)

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
			_instance._batch_processes.remove_at(i)
			_instance._batch_mutex.unlock()
			return true
	_instance._batch_mutex.unlock()
	return false

## Returns the current progress of a batch (0.0 to 1.0)
static func get_batch_progress(batch_id: int) -> float:
	if _instance == null:
		return 0.0

	_instance._batch_mutex.lock()
	for batch in _instance._batch_processes:
		if batch.id == batch_id:
			var progress = float(batch.current_index) / float(batch.items.size())
			_instance._batch_mutex.unlock()
			return progress
	_instance._batch_mutex.unlock()
	return 1.0  # Batch not found = complete

func _process_batches():
	_batch_mutex.lock()
	var processes_copy = _batch_processes.duplicate()
	_batch_mutex.unlock()

	for batch in processes_copy:
		if batch.is_complete:
			continue

		# Check if previous async operations are complete
		if batch.pending_callbacks > 0:
			continue

		var end_index = mini(batch.current_index + batch.batch_size, batch.items.size())
		var items_this_frame = end_index - batch.current_index

		if items_this_frame <= 0:
			continue

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
	if batch.current_index >= batch.items.size() and batch.pending_callbacks == 0:
		_complete_batch(batch)

func _complete_batch(batch: BatchProcess):
	if batch.is_complete:
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


