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

func _ready():
	_update_display()
	download_button.pressed.connect(_on_download_pressed)
	
	# Connect to high-level manager signals
	NetworkManager.download_progress_update.connect(_on_download_progress)
	NetworkManager.download_finished.connect(_on_download_completed)

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
	if not game or game.cover_url == "":
		cover_texture.texture = _loading_texture
		return
	
	# Use DataManager to load image (handles caching)
	DataManager.load_image(game.cover_url, func(texture):
		if texture:
			cover_texture.texture = texture
		else:
			cover_texture.texture = _loading_texture
	)

func _on_download_pressed():
	if not game:
		return
	
	if game.has_local_copy:
		# Launch game (not implemented yet)
		print("Launch game: " + game.get_display_name())
	else:
		download_requested.emit(game)

func _on_download_progress(game_id: int, progress_percent: float):
	if game and game.romm_id == game_id:
		_is_downloading = true
		status_label.text = "Downloading: %d%%" % int(progress_percent)
		_update_display()

func _on_download_completed(game_id: int, success: bool, file_path: String):
	if game and game.romm_id == game_id:
		_is_downloading = false
		if success:
			# Refresh game data from DataManager
			var updated = DataManager.get_game_by_id(game_id)
			if updated:
				game = updated
		else:
			status_label.text = "Failed"
			status_label.modulate = Color.RED
		_update_display()
