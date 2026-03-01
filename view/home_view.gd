class_name HomeView
extends View

signal hero_game_changed(game: GameResource)

@onready var games_grid: VirtualScrollGridContainer = $VirtualScrollGridContainer

var _total_games: int = 0
var _is_loading: bool = false

func _ready():
	# Setup VirtualScrollGridContainer
	if not games_grid:
		push_error("[HomeView] games_grid is null! Cannot initialize.")
		return
	
	var card_scene = preload("res://components/game_card.tscn")
	games_grid.setup(card_scene, 0)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Setup vertical layout from settings
	_update_grid_orientation()
	SettingsManager.setting_changed.connect(_on_setting_changed)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.scan_for_downloaded_games_completed.connect(_on_scan_completed)
	
	# Connect to download manager for download status updates
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Connect to LaunchManager for game launch events (to resort by last_played)
	LaunchManager.game_launched.connect(_on_game_launched)
	
	# Connect to UIManager modal signals
	UIManager.modal_item_selected.connect(_on_modal_item_selected)
	
	# Connect to focus changes for hero image
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	# Initial load (will trigger scan if no games found)
	_load_total_count()

func _load_total_count(preserve_cache: bool = false, trigger_scan_if_empty: bool = true):
	"""Get total downloaded game count for virtual scrolling setup."""
	_is_loading = true
	_update_status("Loading recent games...")
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			print("[HomeView] Total downloaded games count: %d" % count)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				print("[HomeView] games_grid no longer valid, skipping set_total_count")
				_is_loading = false
				return
			_total_games = count
			print("[HomeView] Setting total count: %d (preserve_cache=%s)" % [count, preserve_cache])
			games_grid.set_total_count(count, preserve_cache)
			if count == 0:
				_update_status("No downloaded games found")
				# Trigger scan if no games found (may have been wiped from DB but files exist)
				if trigger_scan_if_empty:
					_scan_for_downloaded_games()
			else:
				_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _update_status(text: String):
	# Emit signal to update global status bar
	# Find the main node and update its status
	if not is_inside_tree() or not get_tree():
		return
	var main = get_tree().get_root().get_node_or_null("Main")
	if main and main.has_method("set_status_text"):
		main.set_status_text(text)

func _on_focus_changed(control: Control):
	print("[HomeView] Focus changed to: ", control.name if control else "null")
	# Check if focused control is a button inside a GameCard
	var card = control.get_parent() if control is Button else control
	if card is GameCard:
		print("[HomeView] Focus on GameCard: ", card.game.get_display_name() if card.game else "no game")
		hero_game_changed.emit(card.game)
	else:
		print("[HomeView] Focus not on GameCard, clearing hero")
		hero_game_changed.emit(null)

func _scan_for_downloaded_games():
	"""Trigger scan to detect downloaded games in filesystem."""
	_update_status("Scanning for downloaded games...")
	print("[HomeView] Scanning for downloaded games...")
	DataManager.scan_for_downloaded_games(func(found_count: int):
		print("[HomeView] Scan complete, found %d games" % found_count)
		if found_count > 0:
			# Force complete grid refresh (don't preserve cache - we need fresh data from DB)
			_load_total_count(false, false)
		else:
			_update_status("No downloaded games found")
	)

func _on_scan_completed(found_count: int):
	"""Called when scan for downloaded games completes."""
	if found_count > 0:
		NotificationManager.show_notification("Found %d downloaded games" % found_count, Notification.Type.SUCCESS)

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	print("[HomeView] Items requested: offset=%d, limit=%d, preload=%s" % [offset, limit, is_preload])
	MemoryManager.queue_db_task(
		func():
			var games = DataManager.get_downloaded_games_paginated(offset, limit)
			print("[HomeView] DB query complete: got %d games" % games.size())
			for game in games:
				print("[HomeView] Loaded game: %s (has_local_copy=%s, file_path=%s)" % [game.title, game.has_local_copy, game.file_path])
			return games,
		func(games: Array[GameResource]):
			print("[HomeView] Calling on_items_loaded with %d games at offset %d (preload: %s)" % [games.size(), offset, is_preload])
			games_grid.on_items_loaded(games, offset, is_preload)
	)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int):
	"""Update status label with current visible range."""
	if total_count == 0:
		_update_status("No downloaded games found")
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		_update_status("Showing %d-%d of %d games" % [start_num, end_num, total_count])

func rebuild_grid() -> void:
	"""Rebuild the grid to reflect card size/orientation changes."""
	games_grid.refresh_dimensions()
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

func _on_download_completed(item_id: String, success: bool, message: String):
	# Refresh when a download completes (game may now show in home view)
	if success:
		# Rebuild grid to ensure layout transforms are recalculated
		rebuild_grid()

func _on_database_ready():
	_load_total_count()

func _on_game_updated(game: GameResource):
	# Find and update any visible cards for this game
	var range_info = games_grid.get_visible_range()
	for i in range(range_info.buffer_start, range_info.buffer_start + range_info.buffer_size):
		var card = games_grid.get_card_at_index(i)
		if card and card is GameCard and card.game and card.game.romm_id == game.romm_id:
			card.game = game
			break

func _on_game_launched(game: GameResource):
	"""Called when a game is launched - refresh grid to resort by last_played."""
	print("[HomeView] Game launched, refreshing grid to resort by last_played")
	# Reload data to get new sort order (don't preserve cache), then refresh dimensions
	_load_total_count_with_callback(false, func():
		games_grid.refresh_dimensions()
	)

func _load_total_count_with_callback(preserve_cache: bool = false, on_complete: Callable = Callable()):
	"""Get total downloaded game count and call callback when complete."""
	_is_loading = true
	_update_status("Refreshing...")
	
	MemoryManager.queue_db_task(
		func():
			return DataManager.get_downloaded_games_count(),
		func(count: int):
			if not is_instance_valid(games_grid):
				print("[HomeView] games_grid no longer valid, skipping set_total_count")
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
				return
			_total_games = count
			games_grid.set_total_count(count, preserve_cache)
			if count == 0:
				_update_status("No downloaded games found")
			else:
				var range_info = games_grid.get_visible_range()
				var start_num = range_info.start + 1
				var end_num = mini(range_info.end, count)
				_update_status("Showing %d-%d of %d games" % [start_num, end_num, count])
			_is_loading = false
			
			if on_complete.is_valid():
				on_complete.call()
	)

func on_view_show():
	view_shown.emit()
	# Refresh the view when shown (in case downloads happened while away)
	if not _is_loading:
		_load_total_count(true, false)

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
			print("[HomeView] Launch requested for game: ", romm_id)
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				LaunchManager.launch_game(game)
			else:
				print("[HomeView] Game not found: ", romm_id)
		"delete":
			print("[HomeView] Delete requested for game: ", romm_id)
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				# Show deleting notification
				NotificationManager.show_notification("Deleting " + game.title + "...", Notification.Type.INFO)
				# Delete the game
				DataManager.delete_game_download(game, func(success: bool):
					if success:
						NotificationManager.show_notification(game.title + " deleted", Notification.Type.SUCCESS)
						# Force refresh the grid (don't preserve cache to remove the deleted game)
						_load_total_count_with_callback(false, func():
							games_grid.refresh_dimensions()
							# Reset focus to home button
							if not is_inside_tree() or not get_tree():
								return
							var main = get_tree().get_root().get_node_or_null("Main")
							if main and main.has_method("reset_focus_to_home_button"):
								main.reset_focus_to_home_button()
							if AudioManager:
								AudioManager.play_sfx("error")
						)
					else:
						NotificationManager.show_notification("Failed to delete " + game.title, Notification.Type.ERROR)
						# Play error sound
						if AudioManager:
							AudioManager.play_sfx("error")
				)
		"hide":
			print("[HomeView] Hide requested for game: ", romm_id)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "library_vertical_layout":
		_update_grid_orientation()

func _update_grid_orientation() -> void:
	if SettingsManager:
		var vertical_setting = SettingsManager.get_setting("library_vertical_layout")
		if vertical_setting:
			games_grid.vertical = vertical_setting.value
