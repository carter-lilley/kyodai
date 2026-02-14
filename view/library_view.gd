class_name LibraryView
extends View

@onready var games_grid: VirtualScrollGridContainer = $VBoxContainer/VirtualScrollGridContainer
@onready var status_label: Label = $VBoxContainer/StatusLabel

var _total_games: int = 0
var _is_loading: bool = false

func _ready():
	# Setup VirtualScrollGridContainer
	var card_scene = preload("res://components/game_card.tscn")
	games_grid.setup(card_scene, 0, 5)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_added.connect(_on_game_added)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.games_removed.connect(_on_games_removed)
	DataManager.sync_completed.connect(_on_sync_completed)
	DataManager.sync_progress.connect(_on_sync_progress)
	
	# Connect to download manager for downloads
	DownloadManager.download_progress.connect(_on_download_progress)
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Connect to UIManager modal signals
	UIManager.modal_item_selected.connect(_on_modal_item_selected)
	
	# Initial load
	_load_total_count()

func _load_total_count():
	"""Get total game count for virtual scrolling setup."""
	_is_loading = true
	status_label.text = "Loading library..."
	
	# Query total count asynchronously
	ThreadManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count()
			print("[LibraryView] Total games count: %d" % count)
			return count,
		func(count: int):
			_total_games = count
			print("[LibraryView] Setting total count: %d" % count)
			games_grid.set_total_count(count)
			status_label.text = "Showing 0-0 of %d games" % count
			_is_loading = false
	)

func _on_items_requested(offset: int, limit: int):
	"""Handle database query requests from VirtualScrollGridContainer."""
	print("[LibraryView] Items requested: offset=%d, limit=%d" % [offset, limit])
	ThreadManager.queue_db_task(
		func():
			var games = DataManager.get_games_paginated(offset, limit, "title", true)
			print("[LibraryView] DB query complete: got %d games" % games.size())
			return games,
		func(games: Array[GameResource]):
			print("[LibraryView] Calling on_items_loaded with %d games at offset %d" % [games.size(), offset])
			games_grid.on_items_loaded(games, offset)
	)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int):
	"""Update status label with current visible range."""
	if total_count == 0:
		status_label.text = "No games found"
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		status_label.text = "Showing %d-%d of %d games" % [start_num, end_num, total_count]

func _on_card_created(card: Control, index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)

func _on_download_requested(game: GameResource):
	var download_url = NetworkManager.get_romm_download_url(game.romm_id, game.file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		status_label.text = "Error: Games folder not set"
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + game.file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game)
	
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
	# Refresh total count and grid
	_load_total_count()

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
		status_label.text = "Sync complete. Refreshing..."
		await get_tree().create_timer(0.5).timeout
		_load_total_count()
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
