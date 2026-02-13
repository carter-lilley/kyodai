class_name GameCard
extends PanelContainer

signal download_requested(game: GameResource)

@export var game: GameResource:
	set(value):
		game = value
		_update_display()

@onready var cover_texture: TextureRect = $MarginContainer/VBoxContainer/CoverTexture
@onready var title_label: Label = $MarginContainer/VBoxContainer/TitleLabel
@onready var platform_label: Label = $MarginContainer/VBoxContainer/PlatformLabel
@onready var download_button: Button = $MarginContainer/VBoxContainer/DownloadButton
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel

var _loading_texture: Texture2D = preload("res://icon.svg")  # Placeholder
var _is_downloading: bool = false
var _image_loaded: bool = false

func _ready():
	_update_display()
	download_button.pressed.connect(_on_download_pressed)
	
	# Connect to download manager signals
	DownloadManager.download_progress.connect(_on_download_progress)
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Listen for cover downloads to refresh if our cover was just downloaded
	DataManager.image_loaded.connect(_on_cover_loaded)

func _update_display():
	if not game:
		return
	
	if not is_node_ready():
		return
	
	title_label.text = game.get_display_name()
	platform_label.text = game.platform if game.platform else "Unknown Platform"
	
	# Update download button state
	if game.has_local_copy:
		download_button.text = "Play"
		download_button.disabled = false
		status_label.text = "Ready"
		status_label.modulate = Color.GREEN
	elif _is_downloading:
		download_button.text = "Downloading..."
		download_button.disabled = true
	else:
		download_button.text = "Download"
		download_button.disabled = false
		status_label.text = ""
	
	# Load cover image
	_load_cover()

func _load_cover():
	if not game:
		cover_texture.texture = _loading_texture
		return
	
	_image_loaded = true  # Mark as attempted
	
	# Try local cover path first (from Romm)
	if game.cover_path != "" and FileAccess.file_exists(game.cover_path):
		var img = Image.new()
		var err = img.load(game.cover_path)
		if err == OK:
			cover_texture.texture = ImageTexture.create_from_image(img)
			return
	
	# Try external URL (from metadata)
	if game.cover_url != "" and game.cover_url.begins_with("http"):
		DataManager.load_image(game.cover_url, func(texture):
			if texture and is_instance_valid(cover_texture):
				cover_texture.texture = texture
			elif is_instance_valid(cover_texture):
				cover_texture.texture = _loading_texture
		)
		return
	
	# No cover available
	cover_texture.texture = _loading_texture

func _on_download_pressed():
	if not game:
		return
	
	if game.has_local_copy:
		# Launch the game using LaunchManager
		print("[GameCard] Launch requested for game: ", game.romm_id)
		LaunchManager.launch_game(game)
	else:
		download_requested.emit(game)

func _on_download_progress(item_id: String, progress: float):
	# Check if this download is for our game
	var item = DownloadManager.get_item(item_id)
	if item and item.game_resource and game and item.game_resource.romm_id == game.romm_id:
		_is_downloading = true
		status_label.text = "Downloading: %d%%" % int(progress * 100)
		_update_display()

func _on_download_completed(item_id: String, success: bool, message: String):
	# Check if this download is for our game
	var item = DownloadManager.get_item(item_id)
	if item and item.game_resource and game and item.game_resource.romm_id == game.romm_id:
		_is_downloading = false
		if success:
			# Refresh game data from DataManager
			var updated = DataManager.get_game_by_id(game.romm_id)
			if updated:
				game = updated
		else:
			status_label.text = "Failed"
			status_label.modulate = Color.RED
		_update_display()

func _on_cover_loaded(url: String, texture: Texture2D):
	# If this card's cover was just downloaded, update it
	if game and game.cover_url == url and texture and is_instance_valid(cover_texture):
		cover_texture.texture = texture

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# Right-click to show context menu
			if game:
				UIManager.show_game_context_menu(game.romm_id, get_viewport().get_mouse_position())
