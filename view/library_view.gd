class_name LibraryView
extends View

signal hero_game_changed(game: GameResource)

@onready var games_grid: VirtualScrollGridContainer = $VirtualScrollGridContainer

var _total_games: int = 0
var _is_loading: bool = false

func _ready():
	# Setup VirtualScrollGridContainer
	if not games_grid:
		push_error("[LibraryView] games_grid is null! Cannot initialize.")
		return
	
	var card_scene = preload("res://components/game_card.tscn")
	games_grid.setup(card_scene, 0)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Setup vertical layout from settings
	_update_grid_orientation()
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_added.connect(_on_game_added)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.games_removed.connect(_on_games_removed)
	DataManager.sync_completed.connect(_on_sync_completed)
	DataManager.sync_progress.connect(_on_sync_progress)
	
	# NEW: Connect to batch updates for efficient UI during sync
	DataManager.games_batch_added.connect(_on_games_batch_added)
	
	# Connect to download manager for downloads
	DownloadManager.download_progress.connect(_on_download_progress)
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Connect to UIManager modal signals
	UIManager.modal_item_selected.connect(_on_modal_item_selected)
	
	# Connect to focus changes for hero image
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	# Initial load
	_load_total_count()

func _load_total_count(preserve_cache: bool = false):
	"""Get total game count for virtual scrolling setup."""
	_is_loading = true
	_update_status("Loading library...")
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count()
			print("[LibraryView] Total games count: %d" % count)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				print("[LibraryView] games_grid no longer valid, skipping set_total_count")
				_is_loading = false
				return
			_total_games = count
			print("[LibraryView] Setting total count: %d (preserve_cache=%s)" % [count, preserve_cache])
			games_grid.set_total_count(count, preserve_cache)
			_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _load_total_count_with_callback(preserve_cache: bool = false, on_complete: Callable = Callable()):
	"""Get total game count and call callback when complete."""
	_is_loading = true
	_update_status("Loading library...")
	
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count()
			print("[LibraryView] Total games count: %d" % count)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				print("[LibraryView] games_grid no longer valid, skipping set_total_count")
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
				return
			_total_games = count
			games_grid.set_total_count(count, preserve_cache)
			_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
			if on_complete.is_valid():
				on_complete.call()
	)

func _update_status(text: String):
	# Emit signal to update global status bar
	if not is_inside_tree() or not get_tree():
		return
	var main = get_tree().get_root().get_node_or_null("Main")
	if main and main.has_method("set_status_text"):
		main.set_status_text(text)

func _on_focus_changed(control: Control):
	# Check if focused control is a button inside a GameCard
	var card = control.get_parent() if control is Button else control
	if card is GameCard:
		hero_game_changed.emit(card.game)
	else:
		hero_game_changed.emit(null)

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	print("[LibraryView] Items requested: offset=%d, limit=%d, preload=%s" % [offset, limit, is_preload])
	MemoryManager.queue_db_task(
		func():
			var games = DataManager.get_games_paginated(offset, limit, "title", true)
			print("[LibraryView] DB query complete: got %d games" % games.size())
			return games,
		func(games: Array[GameResource]):
			print("[LibraryView] Calling on_items_loaded with %d games at offset %d (preload: %s)" % [games.size(), offset, is_preload])
			games_grid.on_items_loaded(games, offset, is_preload)
	)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int):
	"""Update status label with current visible range."""
	if total_count == 0:
		_update_status("No games found")
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		_update_status("Showing %d-%d of %d games" % [start_num, end_num, total_count])

func rebuild_grid() -> void:
	"""Rebuild the grid to reflect card size/orientation changes."""
	_update_grid_orientation()
	games_grid.refresh_dimensions()
	# Force grid to recalculate layout
	_load_total_count(true)

func _on_card_created(card: Control, index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)

func _on_download_requested(game: GameResource):
	# Use the selected sibling's ID and file name if one is selected
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		_update_status("Error: Games folder not set")
		NotificationManager.show_notification("Error: Games folder not set", Notification.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, active_game_id)
	
	if item_id != "":
		_update_status("Queued: " + game.get_display_name())
	else:
		_update_status("Failed to queue download")

func _on_download_progress(item_id: String, progress: float):
	pass

func _on_download_completed(item_id: String, success: bool, message: String):
	if success:
		_update_status("Download completed")
	else:
		_update_status("Download failed: " + message)

func _on_database_ready():
	_load_total_count()

func _on_game_added(game: GameResource):
	# Refresh total count and grid (for individual additions outside sync)
	_load_total_count()

func _on_games_batch_added(platform_slug: String, start_index: int, games: Array[GameResource]):
	"""Handle batch game additions during sync without full grid rebuild."""
	# Filter out games without cover art
	var filtered_games: Array[GameResource] = []
	for game in games:
		if game.has_cover_art:
			filtered_games.append(game)
	
	if filtered_games.size() == 0:
		return
	
	print("[LibraryView] Batch added %d games from %s at index %d" % [filtered_games.size(), platform_slug, start_index])
	
	# Increment total count without rebuilding buffer
	var actual_start = games_grid.increment_total_count(filtered_games.size())
	
	# Cache games for when user scrolls to them
	games_grid.cache_items_at_offset(filtered_games, actual_start)
	
	# Only refresh visible cards if they fall within current viewport
	games_grid.refresh_if_visible(actual_start, actual_start + filtered_games.size() - 1)
	
	# Update status label with current counts
	var range_info = games_grid.get_visible_range()
	if range_info.total > 0:
		var start_num = range_info.start + 1
		var end_num = mini(range_info.end, range_info.total)
		_update_status("Showing %d-%d of %d games" % [start_num, end_num, range_info.total])

func _on_game_updated(game: GameResource):
	# Find and update any visible cards for this game
	var range_info = games_grid.get_visible_range()
	for i in range(range_info.buffer_start, range_info.buffer_start + range_info.buffer_size):
		var card = games_grid.get_card_at_index(i)
		if card and card is GameCard and card.game and card.game.romm_id == game.romm_id:
			card.game = game
			break

func _on_games_removed(platform_slug: String):
	print("[LibraryView] Games removed from platform: ", platform_slug)
	_reload_after_change()

func _reload_after_change():
	"""Reload after games added/removed."""
	_load_total_count()

func _on_sync_progress(percent: float, current: int, total: int):
	_update_status("Syncing... %d/%d games (%.0f%%)" % [current, total, percent])

func _on_sync_completed(success: bool, message: String):
	if success:
		_update_status("Sync complete. Finalizing...")
		
		# Wait for any final batch emissions to complete
		await get_tree().create_timer(0.7).timeout  # Slightly over the 500ms batch interval
		
		# Final consistency check - reload total count from database
		# Preserve cache to avoid stuttering when scrolling to previously loaded pages
		_load_total_count(true)
		
		_update_status(message)
	else:
		_update_status("Sync failed: " + message)

func on_view_show():
	super.on_view_show()

func on_view_hide():
	view_hidden.emit()

func _on_modal_item_selected(item_id: String, context: Dictionary):
	# Only handle modal actions if this view is currently active
	if not UIManager.is_current_view(view_name):
		return
	
	var romm_id = context.get("romm_id", 0)
	
	match item_id:
		"details":
			UIManager.show_game_details(romm_id)
		"launch":
			print("[LibraryView] Launch requested for game: ", romm_id)
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				LaunchManager.launch_game(game)
			else:
				print("[LibraryView] Game not found: ", romm_id)
		"hide":
			print("[LibraryView] Hide requested for game: ", romm_id)

func perform_rebuild() -> void:
	"""Override: Perform the actual grid rebuild when view becomes visible."""
	print("[LibraryView] perform_rebuild() called, deferring to ensure valid size...")
	print("[LibraryView] Current size: ", size)
	print("[LibraryView] Visible: ", visible)
	call_deferred("_do_rebuild")

func _do_rebuild() -> void:
	print("[LibraryView] _do_rebuild() executing")
	print("[LibraryView] Size now: ", size)
	print("[LibraryView] Visible now: ", visible)
	
	# Ensure we have valid dimensions before rebuilding
	if size.x <= 0 or size.y <= 0:
		print("[LibraryView] WARNING: Invalid size detected, deferring again...")
		call_deferred("_do_rebuild")
		return
	
	if games_grid:
		print("[LibraryView] games_grid size: ", games_grid.size)
		print("[LibraryView] games_grid visible: ", games_grid.visible)
		# Force a layout recalculation with the new valid size
		games_grid.queue_redraw()
	
	rebuild_grid()
	print("[LibraryView] Rebuild complete")

func _update_grid_orientation() -> void:
	if SettingsManager:
		var vertical_setting = SettingsManager.get_setting("library_vertical_layout")
		if vertical_setting:
			games_grid.vertical = vertical_setting.value
