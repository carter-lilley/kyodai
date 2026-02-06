#sync_batch_processor.gd
extends RefCounted
class_name SyncBatchProcessor

signal batch_complete(success_count: int)
signal all_complete(total_success: int, cover_urls: Array)

var _items: Array
var _platform_slug: String
var _success_count: int = 0
var _completed_count: int = 0
var _current_index: int = 0
var _chunk_size: int = 3  # Process 3 games at a time to prevent callback flooding
var _processed_in_current_chunk: int = 0
var _current_chunk_size: int = 0
var _mutex: Mutex
var _is_processing: bool = false
var _cover_urls: Array = []  # Collect cover URLs during sync

func _init(items: Array, platform_slug: String = ""):
	_items = items
	_platform_slug = platform_slug
	_mutex = Mutex.new()

func start():
	_success_count = 0
	_completed_count = 0
	_current_index = 0
	_is_processing = true
	print("[SyncBatchProcessor] Starting batch processing for ", _items.size(), " games with chunk size ", _chunk_size)
	_process_next_chunk()

func _process_next_chunk():
	print("[SyncBatchProcessor] _process_next_chunk called, current_index: ", _current_index, ", total: ", _items.size())
	
	if not _is_processing:
		print("[SyncBatchProcessor] Not processing (stopped)")
		return
	
	if _current_index >= _items.size():
		print("[SyncBatchProcessor] Reached end, checking completion")
		_check_complete()
		return
	
	var end_index = mini(_current_index + _chunk_size, _items.size())
	var chunk = _items.slice(_current_index, end_index)
	_current_chunk_size = chunk.size()
	_processed_in_current_chunk = 0
	
	print("[SyncBatchProcessor] Processing chunk ", _current_index, " to ", end_index, " (", _current_chunk_size, " games)")
	
	for game_data in chunk:
		_process_single_game(game_data, func():
			_mutex.lock()
			_processed_in_current_chunk += 1
			var chunk_progress = _processed_in_current_chunk
			var chunk_total = _current_chunk_size
			var should_continue = _processed_in_current_chunk >= _current_chunk_size
			_mutex.unlock()
			
			print("[SyncBatchProcessor] Game completed in chunk: ", chunk_progress, "/", chunk_total)
			
			if should_continue:
				print("[SyncBatchProcessor] Chunk complete! Scheduling next chunk")
				# Chunk complete, schedule next chunk
				_current_index = end_index
				call_deferred("_process_next_chunk")
		)

func _process_single_game(game_data: Dictionary, on_complete: Callable):
	if not game_data is Dictionary:
		on_complete.call()
		return
	
	var game = GameResource.new()
	game.id = str(game_data.get("id", ""))
	game.romm_id = game_data.get("id", 0)
	game.title = game_data.get("name", "") if game_data.get("name") != null else ""
	game.platform = game_data.get("platform_display_name", "") if game_data.get("platform_display_name") != null else ""
	game.platform_slug = _platform_slug if _platform_slug != "" else (game_data.get("platform_slug", "") if game_data.get("platform_slug") != null else "")
	game.cover_url = game_data.get("url_cover", "") if game_data.get("url_cover") != null else ""
	game.cover_path = game_data.get("path_cover_large", "") if game_data.get("path_cover_large") != null else ""
	game.file_name = game_data.get("fs_name", "") if game_data.get("fs_name") != null else ""
	game.file_path = game_data.get("full_path", "") if game_data.get("full_path") != null else ""
	game.file_size = game_data.get("fs_size_bytes", 0)
	game.has_local_copy = false
	var updated_at = game_data.get("updated_at", "")
	game.last_updated = updated_at if updated_at != null else ""
	var desc = game_data.get("summary", "")
	game.description = desc if desc != null else ""
	
	var genres_array: Array[String] = []
	if game_data.has("metadatum") and game_data["metadatum"] != null and game_data["metadatum"] is Dictionary:
		if game_data["metadatum"].has("genres") and game_data["metadatum"]["genres"] != null and game_data["metadatum"]["genres"] is Array:
			for genre in game_data["metadatum"]["genres"]:
				if genre is String:
					genres_array.append(genre)
	game.genres = genres_array
	
	var rating = 0.0
	if game_data.has("metadatum") and game_data["metadatum"] != null and game_data["metadatum"] is Dictionary:
		var avg_rating = game_data["metadatum"].get("average_rating", 0.0)
		rating = avg_rating if avg_rating != null else 0.0
	game.rating = rating
	
	# Collect cover URL for download
	var cover_url = game_data.get("url_cover", "") if game_data.get("url_cover") != null else ""
	
	DataManager.add_game(game, func(success: bool):
		_mutex.lock()
		_completed_count += 1
		if success:
			_success_count += 1
			# Store cover URL if successful and has cover
			if cover_url != "" and cover_url.begins_with("http"):
				_cover_urls.append(cover_url)
		_mutex.unlock()
		on_complete.call()
	)

func _check_complete():
	_mutex.lock()
	var is_complete = _completed_count >= _items.size()
	var success_count = _success_count
	_mutex.unlock()
	
	if is_complete:
		print("[SyncBatchProcessor] Batch complete! Success: ", success_count, "/", _items.size(), ", Covers collected: ", _cover_urls.size())
		_is_processing = false
		batch_complete.emit(success_count)
		all_complete.emit(success_count, _cover_urls)

func stop():
	_is_processing = false

func get_progress() -> Dictionary:
	_mutex.lock()
	var result = {
		"completed": _completed_count,
		"total": _items.size(),
		"success": _success_count
	}
	_mutex.unlock()
	return result
