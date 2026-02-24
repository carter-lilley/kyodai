class_name HomeView
extends View

@onready var games_grid: VirtualScrollGridContainer = $VBoxContainer/VirtualScrollGridContainer
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var zoom_slider: HSlider = $VBoxContainer/BottomBar/ZoomSlider

var _total_games: int = 0
var _is_loading: bool = false

func _ready():
	# Setup VirtualScrollGridContainer
	var card_scene = preload("res://components/game_card.tscn")
	games_grid.setup(card_scene, 0)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Setup zoom slider
	zoom_slider.min_value = 0.15
	zoom_slider.max_value = 0.50
	zoom_slider.step = 0.01
	zoom_slider.value = games_grid.target_card_width_ratio
	zoom_slider.value_changed.connect(_on_zoom_changed)
	
	# Setup vertical layout from settings
	_update_grid_orientation()
	SettingsManager.setting_changed.connect(_on_setting_changed)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_updated.connect(_on_game_updated)
	
	# Connect to download manager for download status updates
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Connect to UIManager modal signals
	UIManager.modal_item_selected.connect(_on_modal_item_selected)
	
	# Initial load
	_load_total_count()

func _load_total_count(preserve_cache: bool = false):
	"""Get total downloaded game count for virtual scrolling setup."""
	_is_loading = true
	status_label.text = "Loading recent games..."
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			print("[HomeView] Total downloaded games count: %d" % count)
			return count,
		func(count: int):
			_total_games = count
			print("[HomeView] Setting total count: %d (preserve_cache=%s)" % [count, preserve_cache])
			games_grid.set_total_count(count, preserve_cache)
			if count == 0:
				status_label.text = "No downloaded games found"
			else:
				status_label.text = "Showing 0-0 of %d games" % count
			_is_loading = false
	)

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	print("[HomeView] Items requested: offset=%d, limit=%d, preload=%s" % [offset, limit, is_preload])
	MemoryManager.queue_db_task(
		func():
			var games = DataManager.get_downloaded_games_paginated(offset, limit)
			print("[HomeView] DB query complete: got %d games" % games.size())
			return games,
		func(games: Array[GameResource]):
			print("[HomeView] Calling on_items_loaded with %d games at offset %d (preload: %s)" % [games.size(), offset, is_preload])
			games_grid.on_items_loaded(games, offset, is_preload)
	)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int):
	"""Update status label with current visible range."""
	if total_count == 0:
		status_label.text = "No downloaded games found"
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		status_label.text = "Showing %d-%d of %d games" % [start_num, end_num, total_count]

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
		status_label.text = "Error: Games folder not set"
		NotificationManager.show_notification("Error: Games folder not set", Notification.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, active_game_id)
	
	if item_id != "":
		status_label.text = "Queued: " + game.get_display_name()
	else:
		status_label.text = "Failed to queue download"

func _on_download_completed(item_id: String, success: bool, message: String):
	# Refresh when a download completes (game may now show in home view)
	if success:
		_load_total_count()

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

func _on_modal_item_selected(item_id: String, context: Dictionary):
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
		"hide":
			print("[HomeView] Hide requested for game: ", romm_id)

func _on_zoom_changed(value: float) -> void:
	games_grid.target_card_width_ratio = value

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "library_vertical_layout":
		_update_grid_orientation()

func _update_grid_orientation() -> void:
	if SettingsManager:
		var vertical_setting = SettingsManager.get_setting("library_vertical_layout")
		if vertical_setting:
			games_grid.vertical = vertical_setting.value
