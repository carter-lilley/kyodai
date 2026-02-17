#thread_manager.gd
extends Node
class_name ThreadManager

var _db_thread: Thread
var _image_thread: Thread
var _extraction_thread: Thread
var _db_queue: Array = []
var _image_queue: Array = []
var _extraction_queue: Array = []
var _db_mutex: Mutex
var _image_mutex: Mutex
var _extraction_mutex: Mutex
var _db_semaphore: Semaphore
var _image_semaphore: Semaphore
var _extraction_semaphore: Semaphore
var _exit_flag: bool = false

const MAX_IMAGE_QUEUE_SIZE = 100
const MAX_DB_QUEUE_SIZE = 50
const MAX_EXTRACTION_QUEUE_SIZE = 5

static var _instance: ThreadManager = null

func _init():
	if _instance == null:
		_instance = self
		_db_mutex = Mutex.new()
		_image_mutex = Mutex.new()
		_extraction_mutex = Mutex.new()
		_db_semaphore = Semaphore.new()
		_image_semaphore = Semaphore.new()
		_extraction_semaphore = Semaphore.new()
		
		_db_thread = Thread.new()
		_image_thread = Thread.new()
		_extraction_thread = Thread.new()
		
		_db_thread.start(_db_worker)
		_image_thread.start(_image_worker)
		_extraction_thread.start(_extraction_worker)

static func _db_worker():
	while not _instance._exit_flag:
		_instance._db_semaphore.wait()
		
		if _instance._exit_flag:
			break
		
		_instance._db_mutex.lock()
		var task = _instance._db_queue.pop_front()
		var remaining = _instance._db_queue.size()
		_instance._db_mutex.unlock()
		
		if task:
			var result = task.callable.call()
			
			# Call callback on main thread
			if task.callback.is_valid():
				_instance.call_deferred("_execute_callback", task.callback, result)

static func _image_worker():
	while not _instance._exit_flag:
		_instance._image_semaphore.wait()
		
		if _instance._exit_flag:
			break
		
		_instance._image_mutex.lock()
		var task = _instance._image_queue.pop_front()
		var remaining = _instance._image_queue.size()
		_instance._image_mutex.unlock()
		
		if task:
			var result = task.callable.call()
			
			# Call callback on main thread
			if task.callback.is_valid():
				_instance.call_deferred("_execute_callback", task.callback, result)

static func _extraction_worker():
	while not _instance._exit_flag:
		_instance._extraction_semaphore.wait()
		
		if _instance._exit_flag:
			break
		
		_instance._extraction_mutex.lock()
		var task = _instance._extraction_queue.pop_front()
		var remaining = _instance._extraction_queue.size()
		_instance._extraction_mutex.unlock()
		
		if task:
			var result = task.callable.call()
			
			# Call callback on main thread
			if task.callback.is_valid():
				_instance.call_deferred("_execute_callback", task.callback, result)

func _execute_callback(callback: Callable, result):
	callback.call(result)

static func queue_db_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[ThreadManager] Not initialized - cannot queue DB task")
		return
	
	_instance._db_mutex.lock()
	var current_size = _instance._db_queue.size()
	
	# If queue is critically full, wait a bit
	if current_size >= MAX_DB_QUEUE_SIZE:
		_instance._db_mutex.unlock()
		OS.delay_msec(10)
		_instance._db_mutex.lock()
		current_size = _instance._db_queue.size()
	
	_instance._db_queue.append({"callable": callable, "callback": callback})
	_instance._db_mutex.unlock()
	_instance._db_semaphore.post()

static func queue_image_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[ThreadManager] Not initialized - cannot queue image task")
		return
	
	_instance._image_mutex.lock()
	var current_size = _instance._image_queue.size()
	
	# If queue is full, drop this task to prevent memory issues
	if current_size >= MAX_IMAGE_QUEUE_SIZE:
		_instance._image_mutex.unlock()
		push_warning("[ThreadManager] Dropping image task - queue full (%d/%d)" % [current_size, MAX_IMAGE_QUEUE_SIZE])
		print("[ThreadManager] DEBUG: Image queue overloaded! Dropping task. Queue: %d/%d" % [current_size, MAX_IMAGE_QUEUE_SIZE])
		# Still call callback with null so UI doesn't hang
		if callback.is_valid():
			callback.call_deferred(null)
		return
	
	_instance._image_queue.append({"callable": callable, "callback": callback})
	_instance._image_mutex.unlock()
	_instance._image_semaphore.post()

static func queue_extraction_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[ThreadManager] Not initialized - cannot queue extraction task")
		return
	
	_instance._extraction_mutex.lock()
	var current_size = _instance._extraction_queue.size()
	
	# If queue is full, reject this task
	if current_size >= MAX_EXTRACTION_QUEUE_SIZE:
		_instance._extraction_mutex.unlock()
		push_error("[ThreadManager] Extraction queue full - cannot queue task")
		# Still call callback with failure so UI doesn't hang
		if callback.is_valid():
			callback.call_deferred(false)
		return
	
	_instance._extraction_queue.append({"callable": callable, "callback": callback})
	_instance._extraction_mutex.unlock()
	_instance._extraction_semaphore.post()

static func get_db_queue_size() -> int:
	if _instance == null:
		return 0
	_instance._db_mutex.lock()
	var size = _instance._db_queue.size()
	_instance._db_mutex.unlock()
	return size

static func has_pending_tasks() -> bool:
	"""Check if ThreadManager has any pending work (queued tasks or active processing)"""
	if _instance == null:
		return false
	
	_instance._db_mutex.lock()
	var db_pending = _instance._db_queue.size()
	_instance._db_mutex.unlock()
	
	_instance._image_mutex.lock()
	var image_pending = _instance._image_queue.size()
	_instance._image_mutex.unlock()
	
	_instance._extraction_mutex.lock()
	var extraction_pending = _instance._extraction_queue.size()
	_instance._extraction_mutex.unlock()
	
	return db_pending > 0 or image_pending > 0 or extraction_pending > 0

static func get_image_queue_size() -> int:
	if _instance == null:
		return 0
	_instance._image_mutex.lock()
	var size = _instance._image_queue.size()
	_instance._image_mutex.unlock()
	return size

static func shutdown():
	if _instance == null:
		return
	print("[ThreadManager] Shutting down threads...")
	_instance._exit_flag = true
	_instance._db_semaphore.post()
	_instance._image_semaphore.post()
	_instance._extraction_semaphore.post()
	_instance._db_thread.wait_to_finish()
	_instance._image_thread.wait_to_finish()
	_instance._extraction_thread.wait_to_finish()
	print("[ThreadManager] Threads shut down")
	_instance = null

func _exit_tree():
	ThreadManager.shutdown()
