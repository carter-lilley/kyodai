class_name LibraryView
extends View

@onready var games_grid: VirtualScrollGridContainer = $VBoxContainer/VirtualScrollGridContainer
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var zoom_slider: HSlider = $VBoxContainer/BottomBar/ZoomSlider

var _total_games: int = 0
var _is_loading: bool = false

func _ready():
	# Setup VirtualScrollGridContainer
	var card_scene = preload("res://components/game_card.tscn")
	games_grid.setup(card_scene, 0, 5)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Setup zoom slider
	zoom_slider.value_changed.connect(_on_zoom_changed)
	
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
	
	# Initial load
	_load_total_count()

func _load_total_count(preserve_cache: bool = false):
	"""Get total game count for virtual scrolling setup."""
	_is_loading = true
	status_label.text = "Loading library..."
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count()
			print("[LibraryView] Total games count: %d" % count)
			return count,
		func(count: int):
			_total_games = count
			print("[LibraryView] Setting total count: %d (preserve_cache=%s)" % [count, preserve_cache])
			games_grid.set_total_count(count, preserve_cache)
			status_label.text = "Showing 0-0 of %d games" % count
			_is_loading = false
	)

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
		status_label.text = "No games found"
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		status_label.text = "Showing %d-%d of %d games" % [start_num, end_num, total_count]

func rebuild_grid() -> void:
	"""Rebuild the grid to reflect card size/orientation changes."""
	# Refresh dimensions based on current orientation
	games_grid.refresh_dimensions()
	# Force grid to recalculate layout
	_load_total_count(true)

func _on_card_created(card: Control, index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)
		card.set_card_zoom(games_grid.zoom)

func _on_download_requested(game: GameResource):
	# Use the selected sibling's ID and file name if one is selected
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		status_label.text = "Error: Games folder not set"
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, active_game_id)
	
	if item_id != "":
		status_label.text = "Queued: " + game.get_display_name()
	else:
		status_label.text = "Failed to queue download"

func _on_download_progress(item_id: String, progress: float):
	pass

func _on_download_completed(item_id: String, success: bool, message: String):
	if success:
		status_label.text = "Download completed"
	else:
		status_label.text = "Download failed: " + message

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
		status_label.text = "Showing %d-%d of %d games" % [start_num, end_num, range_info.total]

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
	status_label.text = "Syncing... %d/%d games (%.0f%%)" % [current, total, percent]

func _on_sync_completed(success: bool, message: String):
	if success:
		status_label.text = "Sync complete. Finalizing..."
		
		# Wait for any final batch emissions to complete
		await get_tree().create_timer(0.7).timeout  # Slightly over the 500ms batch interval
		
		# Final consistency check - reload total count from database
		# Preserve cache to avoid stuttering when scrolling to previously loaded pages
		_load_total_count(true)
		
		status_label.text = message
	else:
		status_label.text = "Sync failed: " + message

func _on_modal_item_selected(item_id: String, context: Dictionary):
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

func _on_zoom_changed(value: float) -> void:
	games_grid.zoom = value
