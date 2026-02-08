#sync_batch_processor.gd
extends RefCounted
class_name SyncBatchProcessor

signal all_complete(success_count: int)
signal game_fully_processed(game_id: String, success: bool)

var _items: Array
var _platform_slug: String
var _success_count: int = 0
var _completed_count: int = 0
var _total_count: int = 0

func _init(items: Array, platform_slug: String = ""):
	_items = items
	_platform_slug = platform_slug
	_total_count = items.size()

func start():
	_success_count = 0
	_completed_count = 0
	
	print("[SyncBatchProcessor] Starting batch of ", _total_count, " games")
	
	# Start all games simultaneously
	for item in _items:
		_process_single_game(item)

func _process_single_game(game_data: Dictionary):
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
	
	var game_id = str(game_data.get("id", ""))
	var db_success = false
	
	# Use a Dictionary to track operations (passed by reference)
	var tracker = {
		"operations_remaining": 2,  # DB + Cover
		"db_success": false
	}
	
	var check_complete = func():
		tracker.operations_remaining -= 1
		print("[SyncBatchProcessor] Game ", game_id, " operation done, remaining: ", tracker.operations_remaining)
		if tracker.operations_remaining <= 0:
			_completed_count += 1
			if tracker.db_success:
				_success_count += 1
			
			print("[SyncBatchProcessor] Game ", game_id, " complete (", _completed_count, "/", _total_count, ")")
			game_fully_processed.emit(game_id, tracker.db_success)
			
			if _completed_count >= _total_count:
				print("[SyncBatchProcessor] All ", _total_count, " games complete")
				all_complete.emit(_success_count)
	
	# Start DB write
	DataManager.add_game(game, func(success: bool):
		tracker.db_success = success
		check_complete.call()
	)
	
	# Start cover download (if we have a URL)
	var cover_url = game_data.get("url_cover", "") if game_data.get("url_cover") != null else ""
	if cover_url != "" and cover_url.begins_with("http"):
		_download_cover(cover_url, func(_success: bool):
			check_complete.call()
		)
	else:
		# No cover to download - mark as done immediately
		check_complete.call()

func _download_cover(url: String, on_complete: Callable):
	var cache_path = DataManager.get_cached_image_path(url)
	
	# Skip if already cached
	if FileAccess.file_exists(cache_path):
		# No actual image operation needed, just call completion
		on_complete.call(true)
		return
	
	# Download the image
	# Track this image operation in DataManager
	DataManager._pending_image_operations += 1
	print("[SyncBatchProcessor] Queued cover download. Pending images: ", DataManager._pending_image_operations)
	
	NetworkManager.download_image(url, func(body: PackedByteArray):
		if body.is_empty():
			DataManager._pending_image_operations -= 1
			print("[SyncBatchProcessor] Cover download failed. Pending images: ", DataManager._pending_image_operations)
			on_complete.call(false)
			DataManager._check_batch_completion()
			return
		
		# Process and save on image thread
		ThreadManager.queue_image_task(
			func():
				var texture = DataManager._load_texture_from_memory(body)
				if texture:
					var file = FileAccess.open(cache_path, FileAccess.WRITE)
					if file:
						file.store_buffer(body)
						file.close()
				return texture,
			func(texture: Texture2D):
				DataManager._pending_image_operations -= 1
				print("[SyncBatchProcessor] Cover processing complete. Pending images: ", DataManager._pending_image_operations)
				on_complete.call(texture != null)
				DataManager._check_batch_completion()
		)
	)
