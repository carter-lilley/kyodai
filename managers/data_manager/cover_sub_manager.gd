extends Manager
class_name CoverSubManager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

var data_manager: Node

const CACHE_FOLDER = "user://cache/covers/"


func _ready():
	data_manager = get_parent()
	_ensure_cache_folder()
	_clean_invalid_cover_cache.call_deferred()


func _ensure_cache_folder():
	FSM.make_dir_recursive(CACHE_FOLDER)


func _clean_invalid_cover_cache():
	"""Remove cached covers that are not valid images (e.g. HTML error pages)."""
	if not FSM.dir_exists(CACHE_FOLDER):
		return

	var total := 0
	var deleted := 0
	for file_name in FSM.list_dir(CACHE_FOLDER):
		var path = FSM.join_paths(CACHE_FOLDER, file_name)
		if not FSM.file_exists(path):
			continue
		total += 1

		var size = FSM.get_file_size(path)
		if size < 64:
			deleted += 1
			print("[CoverCache] Deleting %s: too small (%d bytes)" % [file_name, size])
			FSM.delete_file(path)
			continue

		var buffer = FSM.read_file_bytes(path)
		if buffer.size() < 16:
			deleted += 1
			print("[CoverCache] Deleting %s: unreadable/empty (%d bytes read of %d)" % [file_name, buffer.size(), size])
			FSM.delete_file(path)
			continue
		if FSM.detect_image_format(buffer) == FSM.ImageFormat.UNKNOWN:
			deleted += 1
			var preview = buffer.slice(0, 16).hex_encode()
			print("[CoverCache] Deleting %s: unknown magic bytes (%d bytes, first16=%s)" % [file_name, size, preview])
			FSM.delete_file(path)

	print("[CoverCache] Startup cache check: %d files, %d deleted as invalid" % [total, deleted])


func get_cached_image_path(url: String) -> String:
	# Extract extension from URL, default to jpg if not found
	var extension = "jpg"
	var query_start = url.find("?")
	var url_without_query = url
	if query_start != -1:
		url_without_query = url.substr(0, query_start)

	var last_dot = url_without_query.rfind(".")
	if last_dot != -1 and last_dot < url_without_query.length() - 1:
		var ext = url_without_query.substr(last_dot + 1).to_lower()
		if ext in ["jpg", "jpeg", "png", "webp"]:
			extension = ext
			if extension == "jpeg":
				extension = "jpg"

	return CACHE_FOLDER + url.md5_text() + "." + extension


func _download_cover(url: String, callback: Callable, high_priority: bool = false):
	var cache_path = get_cached_image_path(url)

	# Check if already cached
	if FSM.file_exists(cache_path):
		callback.call(true)
		return

	# Direct download - SystemManager.download handles deduplication
	SystemManager.download.download_image(url, cache_path, callback, high_priority)


func download_cover(url: String, callback: Callable, high_priority: bool = false) -> void:
	_download_cover(url, callback, high_priority)


func _load_image_from_memory(buffer: PackedByteArray, _cache_path: String = "") -> Image:
	if buffer.size() < 16:
		push_error("[CoverCache] Decode failed for %s: buffer too small (%d bytes)" % [_cache_path, buffer.size()])
		return null

	var image = Image.new()
	var err = FAILED
	var format = FSM.detect_image_format(buffer)

	match format:
		FSM.ImageFormat.JPEG:
			err = image.load_jpg_from_buffer(buffer)
		FSM.ImageFormat.PNG:
			err = image.load_png_from_buffer(buffer)
		FSM.ImageFormat.WEBP:
			err = image.load_webp_from_buffer(buffer)
		_:
			# Unknown magic bytes: not a supported image.
			push_error("[CoverCache] Decode failed for %s: unknown magic bytes (%d bytes, first16=%s)" % [_cache_path, buffer.size(), buffer.slice(0, 16).hex_encode()])
			return null

	if err == OK and not image.is_empty():
		return image
	push_error("[CoverCache] Decode failed for %s: format=%d loader error=%d (%d bytes)" % [_cache_path, format, err, buffer.size()])
	return null


func load_image(url: String, callback: Callable = Callable(), high_priority: bool = false):
	if url == "" or not url.begins_with("http"):
		if callback.is_valid():
			callback.call(null)
		return

	var cache_path = get_cached_image_path(url)

	# Try cache first - using background thread
	if FSM.file_exists(cache_path):
		MemorySubManager.queue_image_task(
			func():
				return MemorySubManager.prepare_image_for_texture(_load_image_from_memory(FSM.read_file_bytes(cache_path), cache_path)),
		func(image):
			if image and not image.is_empty():
				var texture = MemorySubManager.create_texture_from_image(image)
				if texture:
					if callback.is_valid():
						callback.call(texture)
					data_manager.image_loaded.emit(url, texture)
				else:
					# Cache file exists but failed to load, try downloading fresh
					_load_image_from_network(url, cache_path, callback, high_priority)
			else:
				# Cache file exists but failed to load, try downloading fresh
				_load_image_from_network(url, cache_path, callback, high_priority)
		, high_priority)
		return

	# Download if not cached
	_load_image_from_network(url, cache_path, callback, high_priority)


func _load_image_from_network(url: String, cache_path: String, callback: Callable, high_priority: bool = false):
	"""Download and load image from network using background thread."""
	_download_cover(url, func(_ok):
		# Check if file was downloaded successfully
		if not FSM.file_exists(cache_path):
			if callback.is_valid():
				callback.call(null)
			return

		MemorySubManager.queue_image_task(
			func():
				return MemorySubManager.prepare_image_for_texture(_load_image_from_memory(FSM.read_file_bytes(cache_path), cache_path)),
		func(image):
			if image and not image.is_empty():
				var texture = MemorySubManager.create_texture_from_image(image)
				if callback.is_valid():
					callback.call(texture)
				data_manager.image_loaded.emit(url, texture)
		, high_priority)
	, high_priority)


func clear_cache():
	for file_name in FSM.list_dir(CACHE_FOLDER):
		FSM.delete_file(FSM.join_paths(CACHE_FOLDER, file_name))
	# Wipe the in-memory texture cache too, or stale textures survive the disk wipe
	MemorySubManager.clear_texture_cache()
	data_manager.cache_cleared.emit()


func get_cache_size() -> int:
	var total_size = 0
	for file_name in FSM.list_dir(CACHE_FOLDER):
		total_size += FSM.get_file_size(FSM.join_paths(CACHE_FOLDER, file_name))
	return total_size


func get_random_cached_cover_path() -> String:
	"""Get a random cover image from the cache folder."""
	var image_files: Array[String] = []
	for file_name in FSM.list_dir(CACHE_FOLDER):
		if file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg") or file_name.ends_with(".webp"):
			image_files.append(FSM.join_paths(CACHE_FOLDER, file_name))

	if image_files.size() > 0:
		return image_files[randi() % image_files.size()]
	return ""


# ==================== COMPREHENSIVE COVER FOLDING ====================

func apply_cover_folding_to_database(callback: Callable = Callable()):
	"""Apply cover folding globally across all games in the database.

	This runs after all syncs complete and groups games with identical covers
	across all batches and platforms. Skips games that are already RomM siblings.

	NEW TWO-TIER SYSTEM:
	- Games with identical covers get the same cover_group_id (hash of cover_url)
	- Within each cover group, only the game with the lowest romm_id is visible (cover_group_master = 1)
	- RomM siblings remain untouched (they have their own is_master_entry system)
	"""
	if not data_manager.database.is_database_ready():
		if callback.is_valid():
			callback.call(0)
		return

	# Check if cover folding is enabled
	var fold_covers_setting = DataManager.get_setting("fold_duplicate_covers")
	if not fold_covers_setting or not fold_covers_setting.value:
		if callback.is_valid():
			callback.call(0)
		return

	# Cover folding changes cover_group_master, which affects the count query.
	data_manager.database.invalidate_downloaded_games_count_cache()

	print("[CoverFolding] Starting global cover folding...")

	# Show pulsing notification
	var notification_id = SystemManager.notifications.show_notification(
		"Folding duplicate covers...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true  # pulsing
	)

	MemorySubManager.queue_db_task(
		func():
			data_manager.database.lock()

			# Query all games with cover URLs that don't have RomM siblings
			# We exclude games that already have siblings in the RomM system
			var query = """
				SELECT id, romm_id, title, file_name, file_size, cover_url, siblings
				FROM games
				WHERE cover_url != '' AND cover_url IS NOT NULL
			"""

			var rows = data_manager.database.query_array_unlocked(query)
			if rows.is_empty():
				data_manager.database.unlock()
				return 0

			# Prefetch all master-entry romm_ids once (avoids a per-sibling COUNT query)
			var master_ids: Dictionary = {}
			var master_rows = data_manager.database.query_array_unlocked("SELECT romm_id FROM games WHERE is_master_entry = 1")
			for r in master_rows:
				master_ids[r.get("romm_id", 0)] = true

			# Build cover groups from games WITHOUT RomM siblings
			var cover_groups: Dictionary = {}
			var games_with_romm_siblings: Dictionary = {}

			for row in rows:
				var romm_id = row.get("romm_id", 0)
				var cover_url = row.get("cover_url", "")
				var siblings_json = row.get("siblings", "[]")

				if cover_url == "" or romm_id == 0:
					continue

				# Check if this game has RomM siblings (not just cover siblings)
				var has_romm_siblings = false
				var json = JSON.new()
				var err = json.parse(siblings_json)
				if err == OK and json.data is Array:
					for sibling in json.data:
						if sibling is Dictionary:
							var sibling_id = sibling.get("id", 0)
							# Check if this sibling exists in DB as master (RomM sibling)
							if sibling_id != 0 and sibling_id != romm_id and master_ids.has(sibling_id):
								has_romm_siblings = true
								break

				if has_romm_siblings:
					# Don't process games with RomM siblings
					games_with_romm_siblings[romm_id] = true
					continue

				# Add to cover group
				if not cover_groups.has(cover_url):
					cover_groups[cover_url] = []

				cover_groups[cover_url].append({
					"romm_id": romm_id
				})

			var groups_processed = 0
			var games_folded = 0

			# Apply all group updates in a single transaction
			if not data_manager.database.query_bool_unlocked("BEGIN IMMEDIATE TRANSACTION"):
				data_manager.database.unlock()
				return 0

			var tx_ok = true

			# Process each cover group with 2+ games
			for cover_url in cover_groups.keys():
				var games = cover_groups[cover_url]
				if games.size() < 2:
					continue

				groups_processed += 1

				# Generate group ID from cover URL hash
				var group_id = cover_url.md5_text()

				# Find the lowest romm_id in this group (will be the master)
				var lowest_id = games[0].romm_id
				for game in games:
					if game.romm_id < lowest_id:
						lowest_id = game.romm_id

				# Update all games in this group
				for game in games:
					var is_master = 1 if game.romm_id == lowest_id else 0

					var update_query = """
						UPDATE games
						SET cover_group_id = ?, cover_group_master = ?
						WHERE romm_id = ?
					"""

					if not data_manager.database.query_bool_unlocked(update_query, [group_id, is_master, game.romm_id]):
						tx_ok = false

					# Count non-master games as folded
					if game.romm_id != lowest_id:
						games_folded += 1

			if tx_ok:
				data_manager.database.query_bool_unlocked("COMMIT")
			else:
				data_manager.database.query_bool_unlocked("ROLLBACK")
				games_folded = 0
			data_manager.database.unlock()

			print("[CoverFolding] Processed %d cover groups, folded %d games" % [groups_processed, games_folded])
			return games_folded,
		func(folded_count: int):
			SystemManager.notifications.dismiss_notification(notification_id)

			if folded_count > 0:
				SystemManager.notifications.show_notification(
					"Folded %d duplicate covers" % folded_count,
					SystemManager.notifications.Type.SUCCESS
				)

			print("[CoverFolding] Complete - folded %d games" % folded_count)
			if callback.is_valid():
				callback.call(folded_count)
	)


func _remove_cover_based_siblings():
	"""Unfold all games by setting cover_group_master = 1 for all games in cover groups.

	This is the simple inverse of apply_cover_folding_to_database. Since cover_group_id
	is preserved during sync, we just need to set cover_group_master = 1 for all games
	that are in a cover group (cover_group_id != '').
	"""
	if not data_manager.database.is_database_ready():
		return

	# Unfolding changes cover_group_master, which affects the count query.
	data_manager.database.invalidate_downloaded_games_count_cache()

	MemorySubManager.queue_db_task(
		func():
			# Lock across UPDATE + changes() so another thread's query can't
			# interleave and corrupt the count.
			data_manager.database.lock()
			var query = "UPDATE games SET cover_group_master = 1 WHERE cover_group_id != ''"
			var success = data_manager.database.query_bool_unlocked(query)

			var unfolded_count = 0
			var query_result = data_manager.database.query_array_unlocked("SELECT changes() as count")
			data_manager.database.unlock()
			if success and query_result.size() > 0:
				unfolded_count = query_result[0].get("count", 0)

			return unfolded_count,
		func(unfolded_count: int):
			print("[CoverFolding] Unfolded %d games" % unfolded_count)
			# Notify listeners that library needs refresh
			data_manager.sync_completed.emit(true, "Cover folding disabled - unfolded %d games" % unfolded_count)
	)
