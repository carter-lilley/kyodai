#thread_manager.gd
extends Node
class_name ThreadManager

var _db_thread: Thread
var _image_thread: Thread
var _db_queue: Array = []
var _image_queue: Array = []
var _db_mutex: Mutex
var _image_mutex: Mutex
var _db_semaphore: Semaphore
var _image_semaphore: Semaphore
var _exit_flag: bool = false

const MAX_IMAGE_QUEUE_SIZE = 30
const MAX_DB_QUEUE_SIZE = 50

static var _instance: ThreadManager = null

func _init():
	if _instance == null:
		_instance = self
		_db_mutex = Mutex.new()
		_image_mutex = Mutex.new()
		_db_semaphore = Semaphore.new()
		_image_semaphore = Semaphore.new()
		
		_db_thread = Thread.new()
		_image_thread = Thread.new()
		
		_db_thread.start(_db_worker)
		_image_thread.start(_image_worker)
		
		print("[ThreadManager] Threads initialized")

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
			print("[ThreadManager] DB worker processing task, remaining in queue: ", remaining, " | Thread ID: ", OS.get_thread_caller_id())
			var result = task.callable.call()
			print("[ThreadManager] DB task completed, result: ", result)
			
			# Call callback on main thread
			if task.callback.is_valid():
				print("[ThreadManager] Scheduling callback on main thread")
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
			print("[ThreadManager] Image worker processing task, remaining: ", remaining, " | Thread ID: ", OS.get_thread_caller_id())
			var result = task.callable.call()
			print("[ThreadManager] Image task completed")
			
			# Call callback on main thread
			if task.callback.is_valid():
				print("[ThreadManager] Scheduling image callback on main thread")
				_instance.call_deferred("_execute_callback", task.callback, result)

func _execute_callback(callback: Callable, result):
	print("[ThreadManager] Executing callback on main thread | Thread ID: ", OS.get_thread_caller_id())
	callback.call(result)
	print("[ThreadManager] Callback completed")

static func queue_db_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[ThreadManager] Not initialized - cannot queue DB task")
		return
	
	_instance._db_mutex.lock()
	var current_size = _instance._db_queue.size()
	
	# If queue is critically full, wait a bit or drop
	if current_size >= MAX_DB_QUEUE_SIZE:
		_instance._db_mutex.unlock()
		print("[ThreadManager] DB queue critical (", current_size, "/", MAX_DB_QUEUE_SIZE, "), throttling...")
		# Simple throttle: delay slightly before queuing
		OS.delay_msec(10)
		_instance._db_mutex.lock()
		current_size = _instance._db_queue.size()
		# If still full after delay, proceed anyway but warn
		if current_size >= MAX_DB_QUEUE_SIZE:
			print("[ThreadManager] DB queue still full, queuing anyway")
	
	_instance._db_queue.append({"callable": callable, "callback": callback})
	var queue_size = _instance._db_queue.size()
	_instance._db_mutex.unlock()
	_instance._db_semaphore.post()
	
	if queue_size % 10 == 0 or queue_size > MAX_DB_QUEUE_SIZE - 5:
		print("[ThreadManager] Queued DB task, queue size: ", queue_size, " | Caller Thread: ", OS.get_thread_caller_id())

static func queue_image_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[ThreadManager] Not initialized - cannot queue image task")
		return
	
	_instance._image_mutex.lock()
	var current_size = _instance._image_queue.size()
	
	# If queue is full, drop this task to prevent memory issues
	if current_size >= MAX_IMAGE_QUEUE_SIZE:
		_instance._image_mutex.unlock()
		print("[ThreadManager] Dropping image task - queue full (", current_size, "/", MAX_IMAGE_QUEUE_SIZE, ")")
		# Still call callback with null so UI doesn't hang
		if callback.is_valid():
			callback.call_deferred(null)
		return
	
	_instance._image_queue.append({"callable": callable, "callback": callback})
	var queue_size = _instance._image_queue.size()
	_instance._image_mutex.unlock()
	_instance._image_semaphore.post()
	
	if queue_size % 10 == 0:
		print("[ThreadManager] Queued image task, queue size: ", queue_size, " | Caller Thread: ", OS.get_thread_caller_id())

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
	
	return db_pending > 0 or image_pending > 0

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
	_instance._db_thread.wait_to_finish()
	_instance._image_thread.wait_to_finish()
	print("[ThreadManager] Threads shut down")
	_instance = null

func _exit_tree():
	ThreadManager.shutdown()
