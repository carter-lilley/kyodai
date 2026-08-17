extends Manager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

# DataManager - Public facade for data persistence and caching.
# Delegates all work to child managers in the data_manager.tscn scene.

signal database_ready()
@warning_ignore("unused_signal")
signal database_failed(error_message: String)
signal sync_completed(success: bool, message: String)
@warning_ignore("unused_signal")
signal sync_progress(percent: float, current: int, total: int)
@warning_ignore("unused_signal")
signal game_updated(game: GameResource)
@warning_ignore("unused_signal")
signal games_removed(platform_slug: String)
@warning_ignore("unused_signal")
signal image_loaded(url: String, texture: Texture2D)
@warning_ignore("unused_signal")
signal cache_cleared()

# NEW: Emitted when the downloaded-games scan finishes.
@warning_ignore("unused_signal")
signal scan_for_downloaded_games_completed(found_count: int)

# Settings facade signals
signal setting_changed(value: Variant, setting: SettingsVar)
signal settings_saved()
signal apply_preset_begin()
signal apply_preset_end()

# Game save facade signal
signal save_sync_completed(game: GameResource, success: bool, message: String)

@onready var database: DatabaseSubManager = $DatabaseSubManager
@onready var sync: SyncSubManager = $SyncSubManager
@onready var cover: CoverSubManager = $CoverSubManager
@onready var save: SaveSyncSubManager = $SaveSyncSubManager
@onready var collections: CollectionSubManager = $CollectionSubManager
@onready var user_props: UserPropsSubManager = $UserPropsSubManager
var settings: SettingsSubManager
var game_save: GameSaveSubManager

func _enter_tree() -> void:
	settings = $SettingsSubManager
	game_save = $GameSaveSubManager

func _ready():
	_ensure_memory_manager()

	# Open the database on the DB worker thread so the autoload chain isn't
	# blocked by disk I/O. Views gate on database_ready / is_database_ready().
	MemorySubManager.queue_db_task(
		func():
			return database.initialize_database(),
		func(success: bool):
			if success:
				print("[DatabaseManager] Database ready - emitting signal")
				database_ready.emit()
				# Warm the downloaded-games count cache so the first HomeView
				# call returns the cached value instead of running COUNT(*).
				MemorySubManager.queue_db_task(func():
					database.get_downloaded_games_count()
				)
			else:
				var err_msg = "Failed to initialize database at " + database.DB_PATH
				database_failed.emit(err_msg)
				SystemManager.notifications.show_notification("Fatal error: " + err_msg + "\nApp cannot function without database access.", SystemManager.notifications.Type.ERROR)
	)
	cover._ensure_cache_folder()
	database_ready.connect(_on_database_ready_for_collections)

	# Wire settings sub-manager signals through the DataManager facade
	settings.setting_changed.connect(func(value: Variant, setting: SettingsVar): setting_changed.emit(value, setting))
	settings.settings_saved.connect(settings_saved.emit)
	settings.apply_preset_begin.connect(apply_preset_begin.emit)
	settings.apply_preset_end.connect(apply_preset_end.emit)

	# Wire game save sub-manager signal through the DataManager facade
	game_save.save_sync_completed.connect(func(game: GameResource, success: bool, message: String): save_sync_completed.emit(game, success, message))

	# Connect to setting changes for dynamic cover folding
	settings.setting_changed.connect(_on_setting_changed)


func _ensure_memory_manager():
	if SystemManager.memory._instance == null:
		var mm = MemorySubManager.new()
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
		var folded_count = database.count_folded_sibling_entries()
		# Trigger grid refresh so library view updates filtering
		if value:
			sync_completed.emit(true, "RomM sibling folding enabled - %d entries folded" % folded_count)
		else:
			sync_completed.emit(true, "RomM sibling folding disabled - %d entries restored" % folded_count)
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


# ==================== COLLECTIONS ====================

func _on_database_ready_for_collections() -> void:
	"""Sync collections from RomM once the database is ready and RomM is configured."""
	if SystemManager.network and SystemManager.network.is_configured():
		print("[DataManager] Syncing collections at startup...")
		# Favorites are derived from the favorite collection, so sync them after it
		sync_collections(func(_success, _msg):
			user_props.sync_favourites()
		)
		user_props.flush_pending()

func sync_collections(callback: Callable = Callable()) -> void:
	collections.sync_collections(callback)


func get_collections() -> Array[Dictionary]:
	return collections.get_collections()


func get_collection(romm_id: int) -> Dictionary:
	return collections.get_collection(romm_id)


func get_romm_ids_for_collection(romm_id: int) -> Array[int]:
	return collections.get_romm_ids_for_collection(romm_id)


func get_games_for_collection_count(romm_id: int) -> int:
	return collections.get_games_for_collection_count(romm_id)


func get_games_for_collection_paginated(romm_id: int, offset: int, limit: int, sort_field: String = "title", ascending: bool = true) -> Array[GameResource]:
	return collections.get_games_for_collection_paginated(romm_id, offset, limit, sort_field, ascending)


# ==================== GAME WRITES ====================

func update_game(game: GameResource, callback: Callable = Callable()) -> bool:
	return database.update_game(game, callback)


func update_game_title_id(romm_id: int, title_id: String, callback: Callable = Callable()) -> bool:
	return database.update_game_title_id(romm_id, title_id, callback)


func update_game_save_info(romm_id: int, save_id: String, save_usage: String, callback: Callable = Callable()) -> bool:
	return database.update_game_save_info(romm_id, save_id, save_usage, callback)


func update_game_siblings(romm_id: int, siblings: Array[Dictionary], callback: Callable = Callable()) -> bool:
	return database.update_game_siblings(romm_id, siblings, callback)


func update_game_m3u_path(romm_id: int, m3u_path: String, callback: Callable = Callable()) -> bool:
	return database.update_game_m3u_path(romm_id, m3u_path, callback)


func update_game_last_played(romm_id: int, timestamp: String) -> bool:
	return database.update_game_last_played(romm_id, timestamp)


func update_game_unwrapped(romm_id: int, unwrapped: bool) -> bool:
	return database.update_game_unwrapped(romm_id, unwrapped)


# ==================== ROMM USER PROPS / FAVORITES ====================

## Apply RomM per-user props (status/now_playing/backlogged/hidden) locally and
## push to the server. Set notify=false for silent background updates (launches).
func set_game_user_props(game: GameResource, props: Dictionary, update_last_played: bool = false, notify: bool = true, callback: Callable = Callable()) -> void:
	user_props.set_game_props(game, props, update_last_played, notify, callback)


## Toggle a game's membership in the RomM "favourites" virtual collection.
func set_game_favorite(game: GameResource, favorite: bool, notify: bool = true, callback: Callable = Callable()) -> void:
	user_props.set_favorite(game, favorite, notify, callback)


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
	var root_folder = get_setting("games_root_folder")
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
			error_msg = "SystemManager.filesystem.delete_file failed"

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

func load_image(url: String, callback: Callable = Callable(), high_priority: bool = false):
	cover.load_image(url, callback, high_priority)


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



func update_save_sync_record(romm_id: int, emulator_id: String, file_name: String, file_path: String, last_synced_at: String, remote_save_id: int, slot: String = "", local_hash: String = "", server_hash: String = "", local_size: int = 0) -> bool:
	return save.update_save_sync_record(romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, slot, local_hash, server_hash, local_size)


func delete_save_sync_record(romm_id: int, emulator_id: String, file_name: String, slot: String = "") -> bool:
	return save.delete_save_sync_record(romm_id, emulator_id, file_name, slot)


# ==================== SETTINGS FACADE ====================

func is_settings_loaded() -> bool:
	return settings.settings != null

func get_setting(_name: String) -> SettingsVar:
	return settings.get_setting(_name)

func set_setting(value: Variant, setting: SettingsVar, force: bool = false):
	settings.set_setting(value, setting, force)

func save_settings():
	settings.save_settings()

func get_settings() -> Dictionary:
	return settings.get_settings()

func get_settings_by_subgroup() -> Dictionary:
	return settings.get_settings_by_subgroup()

func enable_setting(_name: String):
	settings.enable_setting(_name)

func disable_setting(_name: String):
	settings.disable_setting(_name)

func load_settings():
	settings.load_settings()

func reset_settings():
	settings.reset_settings()

func list_presets() -> Array[ThemePreset]:
	return settings.list_presets()

func save_preset(preset: ThemePreset) -> bool:
	return settings.save_preset(preset)

func load_preset(preset_path: String) -> ThemePreset:
	return settings.load_preset(preset_path)

func apply_preset(preset: ThemePreset) -> bool:
	return settings.apply_preset(preset)

func export_preset(preset: ThemePreset, export_path: String) -> bool:
	return settings.export_preset(preset, export_path)

func import_preset(import_path: String) -> ThemePreset:
	return settings.import_preset(import_path)

func create_preset_from_current() -> ThemePreset:
	return settings.create_preset_from_current()

func create_preset_from_settings(source_settings: Settings) -> ThemePreset:
	return settings.create_preset_from_settings(source_settings)


# ==================== GAME SAVE FACADE ====================

func auto_upload_saves_for_game(game: GameResource, emulator_id: String):
	game_save.auto_upload_saves_for_game(game, emulator_id)

func auto_download_saves_for_game(game: GameResource, emulator_id: String, on_complete: Callable = Callable()):
	game_save.auto_download_saves_for_game(game, emulator_id, on_complete)

func sync_saves_for_game(game: GameResource, emulator_id: String, callback: Callable = Callable()):
	game_save.sync_saves_for_game(game, emulator_id, callback)

func resolve_default_save_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	return game_save.resolve_default_save_directory(emulator_id, platform_slug, core_id)

func get_save_extensions(emulator_id: String, platform_slug: String = "", core_id: String = "") -> Array[String]:
	return game_save.get_save_extensions(emulator_id, platform_slug, core_id)

func get_save_sync_status_text(game: GameResource, emulator_id: String) -> String:
	return game_save.get_save_sync_status_text(game, emulator_id)

func create_pcsx2_superblock(memcard_path: String) -> bool:
	return game_save.create_pcsx2_superblock(memcard_path)

func parse_iso_timestamp(iso_string: String) -> int:
	return game_save.parse_iso_timestamp(iso_string)
