#memory_manager.gd
extends Node
class_name MemoryManager

# ============================================================================
# THREAD MANAGEMENT (from thread_manager.gd)
# ============================================================================

var _db_thread: Thread
var _image_threads: Array[Thread] = []
var _extraction_thread: Thread
var _db_queue: Array = []
var _image_high_priority_queue: Array = []
var _image_low_priority_queue: Array = []
var _extraction_queue: Array = []
var _db_mutex: Mutex
var _image_mutex: Mutex
var _extraction_mutex: Mutex
var _db_semaphore: Semaphore
var _image_semaphore: Semaphore
var _extraction_semaphore: Semaphore
var _exit_flag: bool = false
var _image_task_counter: int = 0
var _image_tasks: Dictionary = {}

var _texture_cache: Dictionary = {}
var _texture_cache_order: Array[String] = []
var _texture_cache_mutex: Mutex
const MAX_TEXTURE_CACHE_SIZE: int = 800

const IMAGE_THREAD_COUNT: int = 12
const MAX_IMAGE_QUEUE_SIZE = 600
const MAX_DB_QUEUE_SIZE = 50
const MAX_EXTRACTION_QUEUE_SIZE = 5

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
var _batch_processing: bool = false

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
	_texture_cache_mutex = Mutex.new()
	_db_semaphore = Semaphore.new()
	_image_semaphore = Semaphore.new()
	_extraction_semaphore = Semaphore.new()
	
	_db_thread = Thread.new()
	_db_thread.start(_db_worker)
	
	for i in range(IMAGE_THREAD_COUNT):
		var thread = Thread.new()
		thread.start(_image_worker)
		_image_threads.append(thread)
	
	_extraction_thread = Thread.new()
	_extraction_thread.start(_extraction_worker)

func _ready():
	set_process(true)

func _exit_tree():
	shutdown()

func _process(_delta):
	_process_batches()

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
			_instance._image_mutex.unlock()
			
			if task.callback.is_valid() and not task.cancelled:
				_instance.call_deferred("_execute_callback", task.callback, result)

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
				_instance.call_deferred("_execute_callback", task.callback, result)

func _execute_callback(callback: Callable, result):
	callback.call(result)

# ============================================================================
# THREAD QUEUE METHODS (from thread_manager)
# ============================================================================

static func queue_db_task(callable: Callable, callback: Callable = Callable()):
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue DB task")
		return
	
	_instance._db_mutex.lock()
	var current_size = _instance._db_queue.size()
	
	if current_size >= MAX_DB_QUEUE_SIZE:
		_instance._db_mutex.unlock()
		OS.delay_msec(10)
		_instance._db_mutex.lock()
		current_size = _instance._db_queue.size()
	
	_instance._db_queue.append({"callable": callable, "callback": callback})
	_instance._db_mutex.unlock()
	_instance._db_semaphore.post()

static func queue_image_task(callable: Callable, callback: Callable = Callable(), high_priority: bool = false) -> int:
	if _instance == null:
		push_error("[MemoryManager] Not initialized - cannot queue image task")
		return -1
	
	_instance._image_mutex.lock()
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
		"high_priority": high_priority
	}
	
	_instance._image_tasks[task_id] = task
	
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
		_instance._texture_cache_mutex.unlock()
		return
	
	if _instance._texture_cache.size() >= MAX_TEXTURE_CACHE_SIZE:
		var to_evict = _instance._texture_cache.size() - MAX_TEXTURE_CACHE_SIZE + 1
		for i in range(to_evict):
			if _instance._texture_cache_order.size() > 0:
				var oldest_key = _instance._texture_cache_order.pop_front()
				_instance._texture_cache.erase(oldest_key)
	
	_instance._texture_cache[cache_key] = texture
	_instance._texture_cache_order.append(cache_key)
	_instance._texture_cache_mutex.unlock()

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
	print("[MemoryManager] Shutting down threads...")
	_instance._exit_flag = true
	_instance._db_semaphore.post()
	_instance._extraction_semaphore.post()
	for i in range(IMAGE_THREAD_COUNT):
		_instance._image_semaphore.post()
	_instance._db_thread.wait_to_finish()
	for thread in _instance._image_threads:
		thread.wait_to_finish()
	_instance._extraction_thread.wait_to_finish()
	print("[MemoryManager] Threads shut down")
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
	
	print("[MemoryManager] Started batch %d with %d items (mode: %d, batch_size: %d)" % 
		  [batch.id, items.size(), mode, batch_size])
	
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
			print("[MemoryManager] Cancelled batch %d" % batch_id)
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
	print("[MemoryManager] Batch %d complete: %d items processed" % [batch.id, batch.results.size()])
	
	if batch.on_complete.is_valid():
		batch.on_complete.call(batch.results)
	
	# Remove from active processes
	_batch_mutex.lock()
	for i in range(_batch_processes.size()):
		if _batch_processes[i].id == batch.id:
			_batch_processes.remove_at(i)
			break
	_batch_mutex.unlock()

# ============================================================================
# CONVENIENCE METHODS FOR COMMON OPERATIONS
# ============================================================================

## Process a batch of sibling checks
## Each item should be a Dictionary with: {romm_id: int, siblings: Array[Dictionary]}
## Results will be Array[bool] - true if a sibling exists in DB
static func queue_sibling_checks(
	games_data: Array,
	db_instance: SQLite,
	batch_size: int = 10,
	on_progress: Callable = Callable(),
	on_complete: Callable = Callable()
) -> int:
	var process_func = func(item: Dictionary, _index: int) -> bool:
		if db_instance == null:
			return false
		
		var romm_id = item.get("romm_id", 0)
		var siblings = item.get("siblings", [])
		
		# Build list of all IDs to check
		var ids_to_check = [romm_id]
		for sibling in siblings:
			var sid = sibling.get("id", 0)
			if sid != 0:
				ids_to_check.append(sid)
		
		if ids_to_check.is_empty():
			return false
		
		# Check if any of these IDs already exist as master entries
		var id_list = ", ".join(ids_to_check.map(func(id): return str(id)))
		var query = "SELECT COUNT(*) as count FROM games WHERE romm_id IN (%s) AND is_master_entry = 1" % id_list
		
		var success = db_instance.query(query)
		if success and db_instance.query_result.size() > 0:
			return db_instance.query_result[0]["count"] > 0
		
		return false
	
	return start_batch(games_data, process_func, BatchMode.DB_THREAD, batch_size, on_progress, on_complete)

## Process a batch of DB inserts
## Each item should be a GameResource
static func queue_db_inserts(
	games: Array,
	db_instance: SQLite,
	batch_size: int = 10,
	on_progress: Callable = Callable(),
	on_complete: Callable = Callable()
) -> int:
	var process_func = func(game, _index: int) -> bool:
		if db_instance == null or game == null:
			return false
		
		var query = _build_insert_query(game)
		return db_instance.query(query)
	
	return start_batch(games, process_func, BatchMode.DB_THREAD, batch_size, on_progress, on_complete)

static func _build_insert_query(game) -> String:
	# Helper to build insert query - matches data_manager's add_game logic
	var escape_sql = func(text: String) -> String:
		return text.replace("'", "''")
	
	return """
		INSERT OR REPLACE INTO games 
		(id, romm_id, title, platform, platform_slug, cover_url, cover_path, 
		 file_name, file_path, file_size, has_local_copy, last_updated, 
		 description, genres, rating, siblings, selected_sibling_id, is_master_entry, downloaded_sibling_ids, has_cover_art)
		VALUES ('%s', %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', %d, %d, '%s', '%s', '%s', %f, '%s', %d, %d, '%s', %d)
	""" % [
		escape_sql.call(game.id),
		game.romm_id,
		escape_sql.call(game.title),
		escape_sql.call(game.platform),
		escape_sql.call(game.platform_slug),
		escape_sql.call(game.cover_url),
		escape_sql.call(game.cover_path),
		escape_sql.call(game.file_name),
		escape_sql.call(game.file_path),
		game.file_size,
		1 if game.has_local_copy else 0,
		escape_sql.call(game.last_updated),
		escape_sql.call(game.description),
		escape_sql.call(",".join(game.genres)),
		game.rating,
		escape_sql.call(JSON.stringify(game.siblings)),
		game.selected_sibling_id,
		1 if game.is_master_entry else 0,
		escape_sql.call(JSON.stringify(game.downloaded_sibling_ids)),
		1 if game.has_cover_art else 0
	]

## Process a batch of image downloads
## Each item should be a Dictionary with: {url: String, cache_path: String}
static func queue_image_downloads(
	downloads: Array,
	batch_size: int = 5,
	on_progress: Callable = Callable(),
	on_complete: Callable = Callable()
) -> int:
	var process_func = func(item: Dictionary, _index: int) -> bool:
		var url = item.get("url", "")
		var cache_path = item.get("cache_path", "")
		
		if url == "" or cache_path == "":
			return false
		
		# This would need to integrate with DownloadManager
		# For now, return true as placeholder
		# TODO: Integrate with DownloadManager
		return true
	
	return start_batch(downloads, process_func, BatchMode.SYNC, batch_size, on_progress, on_complete)
