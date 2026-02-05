class_name LibraryView
extends View

@onready var search_line_edit: LineEdit = $VBoxContainer/Toolbar/SearchLineEdit
@onready var platform_option: OptionButton = $VBoxContainer/Toolbar/PlatformOption
@onready var sync_button: Button = $VBoxContainer/Toolbar/SyncButton
@onready var test_sync_button: Button = $VBoxContainer/Toolbar/TestSyncButton
@onready var scroll_container: ScrollContainer = $VBoxContainer/ScrollContainer
@onready var games_grid: GridContainer = $VBoxContainer/ScrollContainer/GamesGrid
@onready var status_label: Label = $VBoxContainer/StatusLabel

var _game_cards: Array[GameCard] = []
var _current_platform: String = ""

func _ready():
	# Setup UI
	search_line_edit.text_changed.connect(_on_search_changed)
	platform_option.item_selected.connect(_on_platform_selected)
	sync_button.pressed.connect(_on_sync_pressed)
	test_sync_button.pressed.connect(_on_test_sync_pressed)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_added.connect(_on_game_added)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.sync_progress.connect(_on_sync_progress)
	
	# Connect to network manager for downloads
	NetworkManager.download_progress_update.connect(_on_download_progress)
	NetworkManager.download_finished.connect(_on_download_finished)
	
	# Initial load
	_load_platforms()
	_load_games()

func _load_platforms():
	platform_option.clear()
	platform_option.add_item("All Platforms")
	
	var platforms = DataManager.get_all_platforms()
	for platform in platforms:
		platform_option.add_item(platform.name)
		platform_option.set_item_metadata(platform_option.get_item_count() - 1, platform.slug)

func _load_games():
	# Clear existing cards
	for card in _game_cards:
		card.queue_free()
	_game_cards.clear()
	
	var games: Array[GameResource]
	
	if _current_platform == "":
		games = DataManager.get_all_games()
	else:
		games = DataManager.get_games_by_platform(_current_platform)
	
	for game in games:
		_add_game_card(game)
	
	status_label.text = "Showing %d games" % games.size()

func _add_game_card(game: GameResource):
	var card_scene = preload("res://ui/components/game_card.tscn")
	var card = card_scene.instantiate()
	card.game = game
	card.download_requested.connect(_on_download_requested)
	games_grid.add_child(card)
	_game_cards.append(card)

func _on_search_changed(text: String):
	if text == "":
		_load_games()
		return
	
	# Clear existing
	for card in _game_cards:
		card.queue_free()
	_game_cards.clear()
	
	var games = DataManager.search_games(text)
	for game in games:
		_add_game_card(game)
	
	status_label.text = "Found %d games" % games.size()

func _on_platform_selected(index: int):
	if index == 0:
		_current_platform = ""
	else:
		_current_platform = platform_option.get_item_metadata(index)
	_load_games()

func _on_sync_pressed():
	if not NetworkManager.is_online():
		status_label.text = "Not connected to RomM - check settings"
		status_label.modulate = Color.RED
		return
	
	if _current_platform == "":
		status_label.text = "Please select a platform first"
		status_label.modulate = Color.YELLOW
		return
	
	status_label.text = "Syncing games for " + _current_platform + "..."
	status_label.modulate = Color.YELLOW
	sync_button.disabled = true
	
	DataManager.sync_platform_games(_current_platform, func(success: bool, message: String, synced: int, total: int):
		sync_button.disabled = false
		
		if success:
			status_label.text = "Synced " + str(synced) + " games for " + _current_platform
			status_label.modulate = Color.GREEN
			_load_games()  # Refresh the game grid
		else:
			status_label.text = "Sync failed: " + message
			status_label.modulate = Color.RED
	)

func _on_test_sync_pressed():
	if not NetworkManager.is_online():
		status_label.text = "Not connected to RomM - check settings"
		status_label.modulate = Color.RED
		return
	
	status_label.text = "Syncing test game..."
	status_label.modulate = Color.YELLOW
	test_sync_button.disabled = true
	
	DataManager.test_sync_single_game(9616, func(success: bool, message: String):
		test_sync_button.disabled = false
		
		if success:
			status_label.text = "Game 9616 synced successfully"
			status_label.modulate = Color.GREEN
			_load_games()  # Refresh the game grid
		else:
			status_label.text = "Game sync failed: " + message
			status_label.modulate = Color.RED
	)

func _on_database_ready():
	_load_platforms()
	_load_games()

func _on_game_added(game: GameResource):
	_add_game_card(game)

func _on_game_updated(game: GameResource):
	# Find and update the card
	for card in _game_cards:
		if card.game and card.game.romm_id == game.romm_id:
			card.game = game
			break

func _on_sync_progress(percent: float, current: int, total: int):
	status_label.text = "Syncing: %d/%d games (%.0f%%)" % [current, total, percent]

func _on_download_requested(game: GameResource):
	if NetworkManager.queue_game_download(game):
		status_label.text = "Queued: " + game.get_display_name()
	else:
		status_label.text = "Failed to queue download"

func _on_download_progress(game_id: int, progress_percent: float):
	# Update UI if needed (game cards handle their own progress display)
	pass

func _on_download_finished(game_id: int, success: bool, file_path: String):
	if success:
		status_label.text = "Download completed"
	else:
		status_label.text = "Download failed"
