extends Manager

const FSM := preload("res://managers/filesystem_manager.gd")

# DataManager - Public facade for data persistence and caching.
# Delegates all work to child managers in the data_manager.tscn scene.

signal database_ready()
signal database_failed(error_message: String)
signal sync_completed(success: bool, message: String)
signal sync_progress(percent: float, current: int, total: int)
signal game_added(game: GameResource)
signal game_updated(game: GameResource)
signal games_removed(platform_slug: String)
signal image_loaded(url: String, texture: Texture2D)
signal cache_cleared()

# NEW: Batch notification signals for efficient UI updates
signal games_batch_added(platform_slug: String, start_index: int, games: Array[GameResource])
signal sync_started()  # Emitted when a sync begins - allows UI to clear cache

# NEW: Emitted when the downloaded-games scan finishes.
signal scan_for_downloaded_games_completed(found_count: int)

@onready var database: DatabaseManager = $DatabaseManager
@onready var sync: SyncManager = $SyncManager
@onready var cover: CoverManager = $CoverManager
@onready var save: SaveSyncManager = $SaveManager


func _ready():
	_ensure_memory_manager()
	database.initialize_database()
	cover._ensure_cache_folder()

	# Connect to setting changes for dynamic cover folding
	SettingsManager.setting_changed.connect(_on_setting_changed)


func _ensure_memory_manager():
	if MemoryManager._instance == null:
		var mm = MemoryManager.new()
		add_child(mm)


func _on_setting_changed(value, setting):
	if setting.property_name == "fold_duplicate_covers":
		if value:
			print("[CoverFolding] Setting enabled - applying cover folding...")
			cover.apply_cover_folding_to_database(func(folded_count: int):
				print("[CoverFolding] Applied cover folding to %d games" % folded_count)
				# Trigger grid refresh
				sync_completed.emit(true, "Cover folding enabled - folded %d games" % folded_count)
			)
		else:
			print("[CoverFolding] Setting disabled - removing cover-based siblings...")
			cover._remove_cover_based_siblings()
	elif setting.property_name == "hide_games_without_covers":
		print("[DataManager] Hide no-cover setting changed to %s" % value)
		# Filter clause changed; count may be different even without data changes.
		database.invalidate_downloaded_games_count_cache()
		# Trigger grid refresh so library view updates filtering
		sync_completed.emit(true, "Hide no-cover games %s" % ("enabled" if value else "disabled"))
	elif setting.property_name == "fold_romm_siblings":
		print("[DataManager] Fold RomM siblings setting changed to %s" % value)
		# Filter clause changed; count may be different even without data changes.
		database.invalidate_downloaded_games_count_cache()
		# Trigger grid refresh so library view updates filtering
		sync_completed.emit(true, "RomM sibling folding %s" % ("enabled" if value else "disabled"))
	elif setting.property_name == "enabled_platforms":
		# Platform filter changed; count may be different. Do NOT emit sync_completed
		# here because PlatformsSettingsView updates this setting for each platform
		# during initialization and emitting sync_completed would spam scans.
		database.invalidate_downloaded_games_count_cache()


# ==================== DATABASE READY ====================

func is_database_ready() -> bool:
	return database.is_database_ready()


# ==================== GAME QUERIES ====================

func get_game_by_id(romm_id: int) -> GameResource:
	return database.get_game_by_id(romm_id)


func get_all_games() -> Array[GameResource]:
	return database.get_all_games()


func get_games_by_platform(platform_slug: String) -> Array[GameResource]:
	return database.get_games_by_platform(platform_slug)


func get_games_paginated(offset: int, limit: int, sort_field: String = "title", ascending: bool = true, platform_slug: String = "") -> Array[GameResource]:
	return database.get_games_paginated(offset, limit, sort_field, ascending, platform_slug)


func get_platforms_with_games() -> Array[Dictionary]:
	return database.get_platforms_with_games()


func get_total_games_count(platform_slug: String = "") -> int:
	return database.get_total_games_count(platform_slug)


func search_games_paginated(query: String, offset: int, limit: int) -> Array[GameResource]:
	return database.search_games_paginated(query, offset, limit)


func get_search_results_count(query: String) -> int:
	return database.get_search_results_count(query)


func get_downloaded_games_count() -> int:
	return database.get_downloaded_games_count()


func get_downloaded_games_paginated(offset: int, limit: int) -> Array[GameResource]:
	return database.get_downloaded_games_paginated(offset, limit)


func get_random_game() -> GameResource:
	return database.get_random_game()


# ==================== GAME WRITES ====================

func add_game(game: GameResource, callback: Callable = Callable()) -> bool:
	return database.add_game(game, callback)


func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	return database.update_game(game, callback)


func update_game_title_id(romm_id: int, title_id: String, callback: Callable = Callable()) -> bool:
	return database.update_game_title_id(romm_id, title_id, callback)


func update_game_siblings(romm_id: int, siblings: Array[Dictionary], callback: Callable = Callable()) -> bool:
	return database.update_game_siblings(romm_id, siblings, callback)


func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	return database.update_game_last_played(romm_id, timestamp)


func delete_game_download(game: GameResource, callback: Callable = Callable(), force_db_update: bool = false) -> bool:
	"""Delete a downloaded game file and update the database.
	If force_db_update is true and the file doesn't exist, the DB entry will be updated anyway."""
	if not database.is_database_ready() or not game:
		push_error("[DataManager] Cannot delete: DB not ready or game is null")
		if callback.is_valid():
			callback.call(false)
		return false

	# Deleting a download changes the downloaded-games count.
	database.invalidate_downloaded_games_count_cache()

	# Get the file path to delete - construct it from components (like launch_manager does)
	var active_id = game.get_active_game_id()
	var active_file_name = ""

	if active_id == game.romm_id:
		active_file_name = game.file_name
	else:
		# Get sibling file name
		for sibling in game.siblings:
			if sibling.get("id", 0) == active_id:
				active_file_name = sibling.get("file_name", "")
				break

	if active_file_name == "":
		push_error("[DataManager] Cannot delete: empty file name")
		if callback.is_valid():
			callback.call(false)
		return false

	# Construct the full path (same as launch_manager.gd line 1162)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	var root_path = root_folder.value if root_folder else "user://roms/"
	var abs_path = root_path + "/" + game.platform_slug + "/" + active_file_name

	# Check if file exists
	var file_exists = FSM.file_exists(abs_path)

	if not file_exists:
		if force_db_update:
			print("[DataManager] File not found but force_db_update=true, removing DB entry for: " + game.title)
		else:
			push_error("[DataManager] File does not exist: " + abs_path)
			if callback.is_valid():
				callback.call(false)
			return false

	# Attempt to delete the file (only if it exists)
	var file_deleted = not file_exists  # If file doesn't exist, consider it "deleted" when forcing
	var error_msg = ""

	if file_exists:
		if FSM.delete_file(abs_path):
			file_deleted = true
		else:
			error_msg = "FileSystemManager.delete_file failed"

		# If file deletion failed, don't update the database (unless forcing)
		if not file_deleted and not force_db_update:
			push_error("[DataManager] Failed to delete file: " + abs_path + " | " + error_msg)
			if callback.is_valid():
				callback.call(false)
			return false

		# Verify file was actually deleted
		var file_still_exists = FSM.file_exists(abs_path)

		if file_still_exists and not force_db_update:
			push_error("[DataManager] File still exists after deletion attempt: " + abs_path)
			if callback.is_valid():
				callback.call(false)
			return false

	# Update game state (after successful deletion or forced removal)
	if active_id == game.romm_id:
		# Main game
		game.has_local_copy = false
		game.file_path = ""
		# Also clear any downloaded siblings since user is removing this game from library
		game.downloaded_sibling_ids.clear()
	else:
		# Sibling - remove from downloaded list
		game.downloaded_sibling_ids.erase(active_id)

	print("[DataManager] delete_game_download: Updating DB for game " + game.title + " (romm_id=" + str(game.romm_id) + ") - has_local_copy=" + str(game.has_local_copy) + ", downloaded_sibling_ids=" + str(game.downloaded_sibling_ids))

	# Clean up extracted game files for platforms that extract during launch
	LaunchManager.cleanup_extracted_game_files(game)

	# Persist to database
	var wrapped_callback = func(success: bool):
		print("[DataManager] delete_game_download: DB update result for " + game.title + " = " + str(success))
		if callback.is_valid():
			callback.call(success)

	return database.update_game(game, wrapped_callback)


# ==================== SYNC TIMESTAMPS / DEVICE ID ====================

func get_last_sync_time(platform_slug: String = "") -> String:
	return database.get_last_sync_time(platform_slug)


func set_last_sync_time(platform_slug: String, timestamp: String):
	database.set_last_sync_time(platform_slug, timestamp)


func get_romm_device_id() -> String:
	return database.get_romm_device_id()


func set_romm_device_id(device_id: String) -> void:
	database.set_romm_device_id(device_id)


func clear_romm_device_id() -> void:
	database.clear_romm_device_id()


# ==================== SYNC ====================

func sync_enabled_platforms(callback: Callable = Callable(), force_full_sync: bool = false) -> void:
	sync.sync_enabled_platforms(callback, force_full_sync)


func sync_platforms_from_romm(callback: Callable = Callable()):
	sync.sync_platforms_from_romm(callback)


func is_sync_in_progress() -> bool:
	return sync.is_sync_in_progress()


func get_sync_state() -> int:
	return sync.get_sync_state()


func get_sync_state_name() -> String:
	return sync.get_sync_state_name()


func get_current_platform_progress() -> Dictionary:
	return sync.get_current_platform_progress()


# ==================== COVERS / CACHE ====================

func load_image(url: String, callback: Callable = Callable()):
	cover.load_image(url, callback)


func get_cached_image_path(url: String) -> String:
	return cover.get_cached_image_path(url)


func clear_cache():
	cover.clear_cache()


func get_cache_size() -> int:
	return cover.get_cache_size()


func get_random_cached_cover_path() -> String:
	return cover.get_random_cached_cover_path()


func apply_cover_folding_to_database(callback: Callable = Callable()):
	cover.apply_cover_folding_to_database(callback)


# ==================== PLATFORMS / SCAN ====================

func scan_for_downloaded_games(callback: Callable = Callable()) -> void:
	database.scan_for_downloaded_games(callback)


func remove_platform_games(platform_slug: String, callback: Callable = Callable()):
	database.remove_platform_games(platform_slug, callback)


func get_all_platforms() -> Array[PlatformResource]:
	return database.get_all_platforms()


# ==================== SAVE SYNC ====================

func get_save_sync_records(romm_id: int, emulator_id: String = "") -> Array[Dictionary]:
	return save.get_save_sync_records(romm_id, emulator_id)



func update_save_sync_record(romm_id: int, emulator_id: String, file_name: String, file_path: String, last_synced_at: String, remote_save_id: int, slot: String = "") -> bool:
	return save.update_save_sync_record(romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, slot)


func delete_save_sync_record(romm_id: int, emulator_id: String, file_name: String, slot: String = "") -> bool:
	return save.delete_save_sync_record(romm_id, emulator_id, file_name, slot)
