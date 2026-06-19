extends Manager
class_name CoverManager

var data_manager: Node

const CACHE_FOLDER = "user://cache/covers/"


func _ready():
	data_manager = get_parent()


func _ensure_cache_folder():
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("cache"):
		dir.make_dir("cache")
	if not dir.dir_exists("cache/covers"):
		dir.make_dir("cache/covers")


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


func _download_cover(url: String, callback: Callable):
	var cache_path = get_cached_image_path(url)

	# Check if already cached
	if FileAccess.file_exists(cache_path):
		callback.call(true)
		return

	# Direct download - DownloadManager handles deduplication
	DownloadManager.download_image(url, cache_path, callback)


func download_cover(url: String, callback: Callable) -> void:
	_download_cover(url, callback)


func _load_image_from_memory(buffer: PackedByteArray, _cache_path: String = "") -> Image:
	if buffer.size() < 16:
		return null

	var err = FAILED
	var image = Image.new()

	# Always use magic bytes to detect actual format, regardless of file extension
	# This handles cases where the extension doesn't match the actual content
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		# JPEG magic bytes
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		# PNG magic bytes (0x89 0x50 0x4E 0x47)
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49:
		# WebP magic bytes (RIFF header)
		err = image.load_webp_from_buffer(buffer)
	else:
		# Try all formats as fallback
		err = image.load_jpg_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_png_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_webp_from_buffer(buffer)

	if err == OK:
		if image.is_empty():
			return null
		return image
	return null


func load_image(url: String, callback: Callable = Callable()):
	if url == "" or not url.begins_with("http"):
		if callback.is_valid():
			callback.call(null)
		return

	var cache_path = get_cached_image_path(url)

	# Try cache first - using background thread
	if FileAccess.file_exists(cache_path):
		MemoryManager.queue_image_task(
			func():
				var file = FileAccess.open(cache_path, FileAccess.READ)
				if file:
					var buffer = file.get_buffer(file.get_length())
					file.close()
					return _load_image_from_memory(buffer, cache_path)
				return null,
			func(image):
				if image:
					var texture = ImageTexture.create_from_image(image)
					if texture:
						if callback.is_valid():
							callback.call(texture)
						data_manager.image_loaded.emit(url, texture)
					else:
						# Cache file exists but failed to load, try downloading fresh
						_load_image_from_network(url, cache_path, callback)
				else:
					# Cache file exists but failed to load, try downloading fresh
					_load_image_from_network(url, cache_path, callback)
		)
		return

	# Download if not cached
	_load_image_from_network(url, cache_path, callback)


func _load_image_from_network(url: String, cache_path: String, callback: Callable):
	"""Download and load image from network using background thread."""
	_download_cover(url, func(_ok):
		# Check if file was downloaded successfully
		if not FileAccess.file_exists(cache_path):
			if callback.is_valid():
				callback.call(null)
			return

		MemoryManager.queue_image_task(
			func():
				var file = FileAccess.open(cache_path, FileAccess.READ)
				if file:
					var buffer = file.get_buffer(file.get_length())
					file.close()
					return _load_image_from_memory(buffer, cache_path)
				return null,
			func(image):
				if image:
					var texture = ImageTexture.create_from_image(image)
					if callback.is_valid():
						callback.call(texture)
					if texture:
						data_manager.image_loaded.emit(url, texture)
		)
	)


func clear_cache():
	var dir = DirAccess.open(CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				dir.remove(file_name)
			file_name = dir.get_next()
	data_manager.cache_cleared.emit()


func get_cache_size() -> int:
	var total_size = 0
	var dir = DirAccess.open(CACHE_FOLDER)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				total_size += dir.get_space_left()
			file_name = dir.get_next()
	return total_size


func get_random_cached_cover_path() -> String:
	"""Get a random cover image from the cache folder."""
	var dir = DirAccess.open(CACHE_FOLDER)
	if not dir:
		return ""

	var image_files: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and (file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg") or file_name.ends_with(".webp")):
			image_files.append(CACHE_FOLDER + file_name)
		file_name = dir.get_next()

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
	var fold_covers_setting = SettingsManager.get_setting("fold_duplicate_covers")
	if not fold_covers_setting or not fold_covers_setting.value:
		if callback.is_valid():
			callback.call(0)
		return

	# Cover folding changes cover_group_master, which affects the count query.
	data_manager.database.invalidate_downloaded_games_count_cache()

	print("[CoverFolding] Starting global cover folding...")

	# Show pulsing notification
	var notification_id = NotificationManager.show_notification(
		"Folding duplicate covers...",
		NotificationManager.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true  # pulsing
	)

	MemoryManager.queue_db_task(
		func():
			# Query all games with cover URLs that don't have RomM siblings
			# We exclude games that already have siblings in the RomM system
			var query = """
				SELECT id, romm_id, title, file_name, file_size, cover_url, siblings
				FROM games
				WHERE cover_url != '' AND cover_url IS NOT NULL
			"""

			var query_result = data_manager.database.query_array(query)
			if query_result.is_empty():
				return 0
			var rows = query_result

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
							if sibling_id != 0 and sibling_id != romm_id:
								var sibling_result = data_manager.database.query_array("SELECT COUNT(*) as count FROM games WHERE romm_id = ? AND is_master_entry = 1", [sibling_id])
								if sibling_result.size() > 0:
									if sibling_result[0].get("count", 0) > 0:
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

					data_manager.database.query_bool(update_query, [group_id, is_master, game.romm_id])

					# Count non-master games as folded
					if game.romm_id != lowest_id:
						games_folded += 1

			print("[CoverFolding] Processed %d cover groups, folded %d games" % [groups_processed, games_folded])
			return games_folded,
		func(folded_count: int):
			NotificationManager.dismiss_notification(notification_id)

			if folded_count > 0:
				NotificationManager.show_notification(
					"Folded %d duplicate covers" % folded_count,
					NotificationManager.Type.SUCCESS
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

	MemoryManager.queue_db_task(
		func():
			# Simple: set cover_group_master = 1 for all games in any cover group
			var query = "UPDATE games SET cover_group_master = 1 WHERE cover_group_id != ''"
			var success = data_manager.database.query_bool(query)

			# Get count of affected games
			var count_query = "SELECT changes() as count"
			var unfolded_count = 0
			var query_result = data_manager.database.query_array(count_query)
			if success and query_result.size() > 0:
				unfolded_count = query_result[0].get("count", 0)

			return unfolded_count,
		func(unfolded_count: int):
			print("[CoverFolding] Unfolded %d games" % unfolded_count)
			# Notify listeners that library needs refresh
			data_manager.sync_completed.emit(true, "Cover folding disabled - unfolded %d games" % unfolded_count)
	)
