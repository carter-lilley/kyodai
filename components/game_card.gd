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

# Track which game we're currently loading an image for (prevents wrong texture on recycled cards)
var _loading_game_id: String = ""
var _image_retry_count: int = 0
const MAX_IMAGE_RETRIES: int = 3

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
	if game.is_active_variant_downloaded():
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
	_loading_game_id = game.id  # Track which game this load is for
	_image_retry_count = 0  # Reset retry count
	
	# Try local cover path first (from Romm) - using background thread
	if game.cover_path != "" and FileAccess.file_exists(game.cover_path):
		_load_local_cover()
		return
	
	# Try external URL (from metadata)
	_load_cover_from_url()

func _load_local_cover():
	"""Load cover from local file path using background thread."""
	var target_game_id = _loading_game_id
	
	ThreadManager.queue_image_task(
		func():
			var img = Image.new()
			var err = img.load(game.cover_path)
			if err == OK:
				return ImageTexture.create_from_image(img)
			return null,
		func(texture):
			# Validate card still shows the same game and is still valid
			if not is_instance_valid(self):
				print("[GameCard] Callback for %s ignored - card no longer valid" % target_game_id)
				return
			if not game or game.id != target_game_id:
				var current_title = game.title if game else "null"
				print("[GameCard] Callback for %s ignored - card now showing %s" % [target_game_id, current_title])
				return  # Card was recycled to different game
			
			if texture and is_instance_valid(cover_texture):
				cover_texture.texture = texture
			else:
				# Task may have been dropped (queue full) or load failed
				# Retry with exponential backoff
				_image_retry_count += 1
				if _image_retry_count < MAX_IMAGE_RETRIES:
					print("[GameCard] Image load failed for %s (retry %d/%d), will retry..." % [game.title, _image_retry_count, MAX_IMAGE_RETRIES])
					await get_tree().create_timer(0.1 * _image_retry_count).timeout
					if is_instance_valid(self) and game and game.id == target_game_id:
						_load_local_cover()
				else:
					# Max retries reached, try external URL as fallback
					print("[GameCard] Max retries reached for local cover of %s, falling back to URL" % game.title)
					_load_cover_from_url()
	)

func _load_cover_from_url():
	if game.cover_url != "" and game.cover_url.begins_with("http"):
		var target_game_id = _loading_game_id
		var current_retry = _image_retry_count
		
		DataManager.load_image(game.cover_url, func(texture):
			# Validate card still shows the same game and is still valid
			if not is_instance_valid(self):
				print("[GameCard] URL callback for %s ignored - card no longer valid" % target_game_id)
				return
			if not game or game.id != target_game_id:
				var current_title = game.title if game else "null"
				print("[GameCard] URL callback for %s ignored - card now showing %s" % [target_game_id, current_title])
				return  # Card was recycled to different game
			
			if texture and is_instance_valid(cover_texture):
				cover_texture.texture = texture
			else:
				# Task may have been dropped (queue full) or load failed
				# Retry with exponential backoff
				_image_retry_count = current_retry + 1
				if _image_retry_count < MAX_IMAGE_RETRIES:
					print("[GameCard] URL image load failed for %s (retry %d/%d), will retry..." % [game.title, _image_retry_count, MAX_IMAGE_RETRIES])
					await get_tree().create_timer(0.1 * _image_retry_count).timeout
					if is_instance_valid(self) and game and game.id == target_game_id:
						_load_cover_from_url()
				else:
					# Max retries reached, show placeholder
					print("[GameCard] All retries exhausted for %s, showing placeholder" % game.title)
					if is_instance_valid(cover_texture):
						cover_texture.texture = _loading_texture
		)
	else:
		# No cover available
		if is_instance_valid(cover_texture):
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
	# Only apply if we're still showing the same game (card wasn't recycled)
	if not is_instance_valid(self) or not game:
		return
	if game.cover_url == url and texture and is_instance_valid(cover_texture):
		cover_texture.texture = texture

func set_placeholder(is_placeholder: bool):
	"""Set placeholder state for incremental loading."""
	if is_placeholder:
		# Show placeholder/loading state
		if is_instance_valid(title_label):
			title_label.text = "Loading..."
		if is_instance_valid(platform_label):
			platform_label.text = ""
		if is_instance_valid(cover_texture):
			cover_texture.texture = _loading_texture
		if is_instance_valid(download_button):
			download_button.visible = false
	else:
		# Show actual game data
		_update_display()
		if is_instance_valid(download_button):
			download_button.visible = true

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# Right-click to show context menu
			if game:
				UIManager.show_game_context_menu(game.romm_id, get_viewport().get_mouse_position())
