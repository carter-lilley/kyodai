class_name LogoBoxSubManager
extends Manager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

var data_manager: Node = null

var _threads: Array[Thread] = []
var _queue_mutex: Mutex = Mutex.new()
var _queue_semaphore: Semaphore = Semaphore.new()
var _running: bool = false
var _queue: Array[Dictionary] = []

var _pending_tasks: int = 0
var _pending_mutex: Mutex = Mutex.new()
var _completed_semaphore: Semaphore = Semaphore.new()

var _detect_time_total_ms: float = 0.0
var _detect_count: int = 0
var _detect_time_mutex: Mutex = Mutex.new()

var _worker_count: int = 1

func _ready():
	data_manager = get_parent()
	# HARD CLAMP: exactly one worker. Each worker constructs its own LogoDetector,
	# and the native Impl creates a per-instance Ort::Env - but ONNX Runtime only
	# allows ONE default LoggingManager per process, so a second detector aborts
	# the process (SIGABRT on Android). Keep at 1 until the native lib shares a
	# single Ort::Env across instances.
	_worker_count = 1
	Performance.add_custom_monitor("logo_box/pending_tasks", _get_pending_task_count)
	Performance.add_custom_monitor("logo_box/avg_detect_time_ms", _get_avg_detect_time_ms)

func _exit_tree():
	stop_worker()

func _get_intra_op_threads() -> int:
	# Keep intra-op threads minimal to avoid oversubscription across workers and
	# reduce CPU contention on the main thread.
	return 1

func set_worker_count(p_count: int) -> void:
	# See _ready: a second LogoDetector instance aborts the process (Ort::Env
	# single-instance limitation), so the pool is pinned to one worker.
	var count := 1
	if count == _worker_count and not _threads.is_empty():
		return
	_worker_count = count
	# Restart the pool if it is already running.
	if not _threads.is_empty():
		stop_worker()
		start_worker()

func start_worker() -> void:
	if not _threads.is_empty():
		return
	_running = true
	for i in range(_worker_count):
		var thread := Thread.new()
		thread.start(_worker_loop)
		_threads.append(thread)

func stop_worker() -> void:
	_queue_mutex.lock()
	_running = false
	_queue_mutex.unlock()
	# Wake every worker so they can exit cleanly.
	for i in range(_threads.size()):
		_queue_semaphore.post()
	for thread in _threads:
		if thread.is_alive():
			thread.wait_to_finish()
	_threads.clear()

## Called from the main thread when a cover download completes or is already cached.
## Queues detection on a worker thread and writes the resulting logo_box to each
## game in the list. Duplicate covers are not shared; each game gets its own row.
func process_cover_url(cover_url: String, games: Array[GameResource], on_complete: Callable = Callable()) -> void:
	if cover_url == "" or not cover_url.begins_with("http"):
		if on_complete.is_valid():
			on_complete.call()
		return
	var cache_path := _get_cache_path(cover_url)
	if cache_path == "" or not FSM.file_exists(cache_path):
		if on_complete.is_valid():
			on_complete.call()
		return

	var title := ""
	var game_ids: Array[int] = []
	for game in games:
		if game is GameResource:
			if title == "":
				title = game.title
			game_ids.append(game.romm_id)

	if title == "" or game_ids.is_empty():
		if on_complete.is_valid():
			on_complete.call()
		return

	_queue_mutex.lock()
	if not _running:
		_queue_mutex.unlock()
		if on_complete.is_valid():
			on_complete.call()
		return
	_queue.append({
		"type": "detect",
		"cache_path": cache_path,
		"title": title,
		"game_ids": game_ids,
		"cover_url": cover_url,
		"on_complete": on_complete,
	})
	_queue_mutex.unlock()
	_pending_mutex.lock()
	_pending_tasks += 1
	_pending_mutex.unlock()
	_queue_semaphore.post()
	start_worker()

## Queues a backfill pass for all games that already have cached covers but no
## logo_box. The work happens on a worker thread.
func backfill_missing() -> void:
	if not data_manager or not data_manager.database:
		return
	if not data_manager.database.is_database_ready():
		return

	_queue_mutex.lock()
	if not _running:
		_queue_mutex.unlock()
		return
	_queue.append({"type": "backfill"})
	_queue_mutex.unlock()
	_pending_mutex.lock()
	_pending_tasks += 1
	_pending_mutex.unlock()
	_queue_semaphore.post()
	start_worker()

## Blocks until all queued detection and backfill tasks have finished.
func wait_for_all() -> void:
	while true:
		_pending_mutex.lock()
		var count = _pending_tasks
		_pending_mutex.unlock()
		if count == 0:
			return
		_completed_semaphore.wait()

func _worker_loop() -> void:
	# Each worker owns its own detector and ONNX sessions. This avoids thread-safety
	# issues when running multiple inferences in parallel.
	var detector: Variant = null

	while true:
		_queue_semaphore.wait()

		_queue_mutex.lock()
		if not _running:
			_queue_mutex.unlock()
			break
		if _queue.is_empty():
			_queue_mutex.unlock()
			continue
		var task = _queue.pop_front()
		_queue_mutex.unlock()

		if detector == null:
			detector = _create_detector()
			if detector == null:
				print("[LogoBoxCache] Worker failed to create detector; skipping task")
				_finish_task(task.get("on_complete", Callable()))
				continue

		match task.get("type", ""):
			"detect":
				_process_detect_task(task, detector)
			"backfill":
				_process_backfill_task()

const MODEL_EXTRACT_DIR := "user://onnx_models"

## Copies a model out of the PCK onto the real filesystem. In exported builds,
## res:// is not a real path and ONNX Runtime opens models via fopen, so the
## file must exist on disk. Returns the user:// path ("" on failure).
func _ensure_model_extracted(res_path: String) -> String:
	var dest = MODEL_EXTRACT_DIR + "/" + res_path.get_file()
	if FSM.file_exists(dest) and FSM.get_file_size(dest) == FSM.get_file_size(res_path):
		return dest
	var bytes = FSM.read_file_bytes(res_path)
	if bytes.is_empty():
		push_error("[LogoBoxCache] Model not found in PCK: " + res_path)
		return ""
	if not FSM.make_dir_recursive(MODEL_EXTRACT_DIR):
		push_error("[LogoBoxCache] Failed to create model extract dir")
		return ""
	var f = FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		push_error("[LogoBoxCache] Failed to write extracted model: " + dest)
		return ""
	f.store_buffer(bytes)
	f.close()
	return dest

func _create_detector() -> Variant:
	if not ClassDB.class_exists("LogoDetector"):
		print("[LogoBoxCache] LogoDetector class not available")
		return null
	var detector: Variant = ClassDB.instantiate("LogoDetector")
	detector.set_intra_op_num_threads(_get_intra_op_threads())
	var yolo_path = _ensure_model_extracted("res://addons/logo_detector/models/logo_detector.onnx")
	var det_path = _ensure_model_extracted("res://addons/logo_detector/models/ch_PP-OCRv4_det_infer.onnx")
	var rec_path = _ensure_model_extracted("res://addons/logo_detector/models/ch_PP-OCRv4_rec_infer.onnx")
	if yolo_path == "" or det_path == "" or rec_path == "":
		return null
	if detector.load_yolo_model(yolo_path) != OK:
		print("[LogoBoxCache] Failed to load YOLO model")
		return null
	if detector.load_ocr_det_model(det_path) != OK:
		print("[LogoBoxCache] Failed to load OCR det model")
		return null
	if detector.load_ocr_rec_model(rec_path) != OK:
		print("[LogoBoxCache] Failed to load OCR rec model")
		return null
	return detector

func _process_detect_task(task: Dictionary, detector: Variant) -> void:
	var cache_path = task.get("cache_path", "")
	var title = task.get("title", "")
	var game_ids: Array[int] = task.get("game_ids", [])
	var cover_url = task.get("cover_url", "")
	var on_complete: Callable = task.get("on_complete", Callable())

	if cache_path == "" or title == "" or game_ids.is_empty() or cover_url == "":
		_finish_task(on_complete)
		return

	var image := _load_image(cache_path)
	if image == null or image.is_empty():
		_finish_task(on_complete)
		return

	var start_ms := Time.get_ticks_msec()
	var result: Variant = detector.detect_title_box(image, title)
	var elapsed_ms := Time.get_ticks_msec() - start_ms
	_detect_time_mutex.lock()
	_detect_time_total_ms += elapsed_ms
	_detect_count += 1
	_detect_time_mutex.unlock()
	var logo_box := _logo_box_dict_from_result(result, image)
	_write_logo_box_to_games(logo_box, game_ids)
	_finish_task(on_complete)

func _finish_task(on_complete: Callable) -> void:
	if on_complete.is_valid():
		on_complete.call_deferred()
	_task_done()

func _process_backfill_task() -> void:
	if not data_manager or not data_manager.database:
		_task_done()
		return
	if not data_manager.database.is_database_ready():
		_task_done()
		return

	var rows = _query_db_blocking(
		"SELECT romm_id, cover_url, title FROM games WHERE cover_url != '' AND cover_url IS NOT NULL AND (logo_box = '' OR logo_box = '{}')",
		[]
	)
	if rows.is_empty():
		_task_done()
		return

	var groups: Dictionary = {}  # cover_url -> Array[GameResource]
	for row in rows:
		var url = row.get("cover_url", "")
		var title = row.get("title", "")
		var romm_id = row.get("romm_id", 0)
		if url == "" or romm_id <= 0:
			continue
		if not groups.has(url):
			groups[url] = [] as Array[GameResource]
		var game = GameResource.new()
		game.romm_id = romm_id
		game.title = title
		game.cover_url = url
		groups[url].append(game)

	var backfilled = 0
	for url in groups.keys():
		var games = groups[url]
		if games.is_empty():
			continue
		process_cover_url(url, games)
		backfilled += games.size()

	if backfilled > 0:
		print("[LogoBoxCache] Backfilling logo boxes for %d games across %d unique covers" % [backfilled, groups.size()])

	_task_done()

func _query_db_blocking(query: String, bindings: Array = []) -> Array:
	"""Run a read query on the DB thread and block until the result is ready."""
	var task_state := {"result": [], "done": false}
	var mutex = Mutex.new()
	var semaphore = Semaphore.new()
	MemorySubManager.queue_db_task(
		func():
			return data_manager.database.query_array_unlocked(query, bindings),
		func(rows: Array):
			mutex.lock()
			task_state["result"] = rows
			task_state["done"] = true
			mutex.unlock()
			semaphore.post()
	)
	semaphore.wait()
	mutex.lock()
	var final_result: Array = task_state["result"]
	mutex.unlock()
	return final_result

func _task_done() -> void:
	_pending_mutex.lock()
	_pending_tasks -= 1
	var done = _pending_tasks == 0
	_pending_mutex.unlock()
	if done:
		_completed_semaphore.post()

func _get_cache_path(cover_url: String) -> String:
	if cover_url == "" or not cover_url.begins_with("http"):
		return ""
	if not data_manager or not data_manager.cover:
		return ""
	return data_manager.cover.get_cached_image_path(cover_url)

func _write_logo_box_to_games(logo_box: Dictionary, game_ids: Array[int]) -> void:
	var json := JSON.stringify(logo_box)
	for romm_id in game_ids:
		if romm_id <= 0:
			continue
		data_manager.database.update_game_logo_box(romm_id, json)

func _load_image(cache_path: String) -> Image:
	if not FSM.file_exists(cache_path):
		return null
	var buffer := FSM.read_file_bytes(cache_path)
	if buffer.size() < 64:
		return null

	var image := Image.new()
	var err = FAILED
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49 and buffer[2] == 0x46 and buffer[3] == 0x46:
		err = image.load_webp_from_buffer(buffer)
	else:
		# Unknown magic bytes: skip rather than spam every codec loader.
		return null

	if err == OK and not image.is_empty():
		return image
	return null

func _logo_box_dict_from_result(result: Variant, image: Image) -> Dictionary:
	var failed := {
		"detected": false,
		"confidence": 0.0,
		"matched_text": "",
		"title_score": 0.0,
		"source": "none",
	}
	if not result is Dictionary:
		return failed
	if not result.get("detected", false):
		return failed
	if image == null or image.is_empty():
		return failed
	var img_w := float(image.get_width())
	var img_h := float(image.get_height())
	if img_w <= 0.0 or img_h <= 0.0:
		return failed
	var x1 := float(result.get("x1", 0.0))
	var y1 := float(result.get("y1", 0.0))
	var x2 := float(result.get("x2", 0.0))
	var y2 := float(result.get("y2", 0.0))
	var title_score := float(result.get("title_score", 0.0))
	var source := "title_box" if title_score > 0.0 else "yolo_fallback"
	return {
		"detected": true,
		"x1": x1 / img_w,
		"y1": y1 / img_h,
		"x2": x2 / img_w,
		"y2": y2 / img_h,
		"confidence": float(result.get("confidence", 0.0)),
		"matched_text": str(result.get("matched_text", "")),
		"title_score": title_score,
		"source": source,
	}

func _get_pending_task_count() -> Variant:
	_pending_mutex.lock()
	var count = _pending_tasks
	_pending_mutex.unlock()
	return count

func _get_avg_detect_time_ms() -> Variant:
	_detect_time_mutex.lock()
	var avg := 0.0
	if _detect_count > 0:
		avg = _detect_time_total_ms / float(_detect_count)
	_detect_time_mutex.unlock()
	return avg
