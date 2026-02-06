class_name LibraryView
extends View

@onready var search_line_edit: LineEdit = $VBoxContainer/Toolbar/SearchLineEdit
@onready var platform_option: OptionButton = $VBoxContainer/Toolbar/PlatformOption
@onready var scroll_container: ScrollContainer = $VBoxContainer/ScrollContainer
@onready var games_grid: GridContainer = $VBoxContainer/ScrollContainer/GamesGrid
@onready var status_label: Label = $VBoxContainer/StatusLabel

var _game_cards: Array[GameCard] = []
var _current_platform: String = ""

# Batched card addition during sync
var _pending_games: Array[GameResource] = []
var _is_processing_pending: bool = false
var _card_batch_size: int = 3  # Add 3 cards at a time to reduce image queue pressure

func _ready():
	# Setup UI
	search_line_edit.text_changed.connect(_on_search_changed)
	platform_option.item_selected.connect(_on_platform_selected)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_added.connect(_on_game_added)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.sync_completed.connect(_on_sync_completed)
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
	
	status_label.text = "Loading %d games..." % games.size()
	
	# Add cards in batches to prevent UI freeze and image queue overflow
	_add_game_cards_batch(games, 0)

func _add_game_cards_batch(games: Array[GameResource], index: int):
	var batch_size = 5
	var end_index = mini(index + batch_size, games.size())
	
	for i in range(index, end_index):
		_add_game_card(games[i])
	
	if end_index < games.size():
		# Schedule next batch
		status_label.text = "Loading games... %d/%d" % [end_index, games.size()]
		call_deferred("_add_game_cards_batch", games, end_index)
	else:
		status_label.text = "Showing %d games" % games.size()

func _add_game_card(game: GameResource):
	var card_scene = preload("res://components/game_card.tscn")
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

func _on_database_ready():
	_load_platforms()
	_load_games()

func _on_game_added(game: GameResource):
	# Queue the game for batched UI addition
	_pending_games.append(game)
	if not _is_processing_pending:
		_process_pending_cards()

func _on_game_updated(game: GameResource):
	# Find and update the card
	for card in _game_cards:
		if card.game and card.game.romm_id == game.romm_id:
			card.game = game
			break

func _process_pending_cards():
	_is_processing_pending = true
	
	# Process a batch of pending games
	var batch_count = mini(_card_batch_size, _pending_games.size())
	for i in range(batch_count):
		_add_game_card(_pending_games[0])
		_pending_games.remove_at(0)
	
	# If more pending, schedule next batch with a small delay
	if _pending_games.size() > 0:
		await get_tree().create_timer(0.05).timeout  # 50ms delay between batches
		_process_pending_cards()
	else:
		_is_processing_pending = false
		status_label.text = "Showing %d games" % _game_cards.size()

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

func _on_sync_progress(percent: float, current: int, total: int):
	status_label.text = "Syncing... %d/%d games (%.0f%%)" % [current, total, percent]

func _on_sync_completed(success: bool, message: String):
	# Clear any pending cards that haven't been processed yet
	_pending_games.clear()
	_is_processing_pending = false
	# Don't reload all games - cards were already added incrementally during sync
	# Just refresh the platforms list in case new ones were added
	_load_platforms()
	status_label.text = "Showing %d games" % _game_cards.size()
