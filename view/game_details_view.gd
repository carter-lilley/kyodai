class_name GameDetailsView
extends View

@onready var cover_texture: TextureRect = $MarginContainer/HBoxContainer/CoverContainer/CoverTexture
@onready var title_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/TitleLabel
@onready var metadata_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow
@onready var platform_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow/PlatformLabel
@onready var genres_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow/GenresLabel
@onready var rating_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow/RatingLabel
@onready var file_info_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/InfoVBox/FileInfoLabel
@onready var file_size_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/InfoVBox/FileSizeLabel
@onready var status_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/InfoVBox/StatusLabel
@onready var description_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/DescriptionLabel

# Sibling dropdown - will be null until added to scene
@onready var sibling_dropdown: OptionButton = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/InfoVBox/SiblingDropdown
@onready var action_button: Button = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/ActionButton

var _current_game: GameResource = null
var _sibling_options: Array[Dictionary] = []  # [{id, name, file_name, file_size}, ...]

func _ready():
	super._ready()
	if sibling_dropdown:
		sibling_dropdown.item_selected.connect(_on_sibling_selected)
	
	# Connect action button
	if action_button:
		action_button.pressed.connect(_on_action_button_pressed)
	
	# Connect to download manager to refresh button state when downloads complete
	DownloadManager.download_completed.connect(_on_download_completed)

func set_game(game: GameResource) -> void:
	_current_game = game
	
	print("[GameDetailsView] set_game called for '%s' (ID: %d), siblings: %d" % [game.title, game.romm_id, game.siblings.size()])
	
	if not is_node_ready():
		print("[GameDetailsView] Node not ready, awaiting...")
		await ready
		print("[GameDetailsView] Node ready now, sibling_dropdown is: %s" % ("valid" if sibling_dropdown else "null"))
	
	title_label.text = game.title if game.title else "Unknown Game"
	platform_label.text = game.platform if game.platform else "Unknown Platform"
	
	if game.genres.size() > 0:
		genres_label.text = "• " + ", ".join(game.genres)
	else:
		genres_label.text = ""
	
	if game.rating > 0:
		var stars = clamp(round(game.rating * 5), 1, 5)
		var empty_stars = 5 - stars
		rating_label.text = "★".repeat(stars) + ("☆".repeat(empty_stars) if empty_stars > 0 else "")
	else:
		rating_label.text = "No rating"
	
	# Setup sibling dropdown and determine which variant to display
	_setup_sibling_dropdown(game)
	_update_file_info_display(game)
	_update_action_button()
	
	description_label.text = game.description if game.description else "No description available."
	
	_load_cover(game)

func _setup_sibling_dropdown(game: GameResource) -> void:
	if not sibling_dropdown:
		print("[GameDetailsView] No sibling dropdown node found")
		return
	
	print("[GameDetailsView] Setting up sibling dropdown for '%s' (ID: %d), siblings count: %d" % [game.title, game.romm_id, game.siblings.size()])
	
	sibling_dropdown.clear()
	_sibling_options = []
	
	# Add the main game as the first option
	_sibling_options.append({
		"id": game.romm_id,
		"name": game.file_name if game.file_name else game.title,
		"file_name": game.file_name,
		"file_size": game.file_size
	})
	sibling_dropdown.add_item(game.file_name if game.file_name else game.title)
	print("[GameDetailsView] Added main game option: '%s' (ID: %d)" % [game.file_name, game.romm_id])
	
	# Add siblings
	for sibling in game.siblings:
		if sibling is Dictionary:
			print("[GameDetailsView] Adding sibling to dropdown: '%s' (ID: %d)" % [sibling.get("name", "Unknown"), sibling.get("id", 0)])
			_sibling_options.append(sibling)
			sibling_dropdown.add_item(sibling.get("name", "Unknown"))
	
	print("[GameDetailsView] Total dropdown options: %d" % _sibling_options.size())
	
	# Select the currently active sibling
	var active_id = game.selected_sibling_id if game.selected_sibling_id != 0 else game.romm_id
	for i in range(_sibling_options.size()):
		if _sibling_options[i].get("id", 0) == active_id:
			sibling_dropdown.select(i)
			break
	
	# Show/hide dropdown based on whether there are siblings
	sibling_dropdown.visible = _sibling_options.size() > 1
	print("[GameDetailsView] Dropdown visible: %s, options: %d" % [str(sibling_dropdown.visible), _sibling_options.size()])
	
	# Debug: force visible to check if it's a visibility issue
	if _sibling_options.size() > 1:
		print("[GameDetailsView] FORCING dropdown visible for debugging")
		sibling_dropdown.visible = true

func _on_sibling_selected(index: int) -> void:
	if index < 0 or index >= _sibling_options.size():
		return
	
	var selected = _sibling_options[index]
	var selected_id = selected.get("id", 0)
	
	if _current_game and selected_id != 0:
		_current_game.selected_sibling_id = selected_id
		
		# Check if we need to fetch full sibling details (no file extension means incomplete data)
		var sibling_file_name = selected.get("file_name", "")
		if selected_id != _current_game.romm_id and not sibling_file_name.contains("."):
			print("[GameDetailsView] Fetching full details for sibling %d (no extension in cached data)" % selected_id)
			_fetch_sibling_details(selected_id, index)
			return
		
		# Update display to show selected variant's info
		_update_file_info_display(_current_game)
		# Update action button based on new selection
		_update_action_button()
		# Persist the selection
		DataManager.update_game(_current_game)

func _fetch_sibling_details(sibling_id: int, dropdown_index: int) -> void:
	"""Fetch full game details for a sibling to get proper file name with extension."""
	NetworkManager.fetch_game_details(sibling_id, func(data: Dictionary, error: String):
		if error == "" and data.has("fs_name"):
			var full_file_name = str(data.get("fs_name", ""))
			print("[GameDetailsView] Fetched sibling %d details: %s" % [sibling_id, full_file_name])
			
			# Update the sibling data in _current_game
			for i in range(_current_game.siblings.size()):
				if _current_game.siblings[i].get("id", 0) == sibling_id:
					_current_game.siblings[i]["file_name"] = full_file_name
					_current_game.siblings[i]["file_size"] = data.get("fs_size_bytes", 0)
					break
			
			# Also update _sibling_options
			if dropdown_index < _sibling_options.size():
				_sibling_options[dropdown_index]["file_name"] = full_file_name
				_sibling_options[dropdown_index]["file_size"] = data.get("fs_size_bytes", 0)
			
			# Save updated game data
			DataManager.update_game(_current_game)
			
			# Update the display
			_update_file_info_display(_current_game)
			_update_action_button()
		else:
			print("[GameDetailsView] Failed to fetch sibling details: %s" % error)
			# Still update display with what we have
			_update_file_info_display(_current_game)
			_update_action_button()
			DataManager.update_game(_current_game)
	)

func _update_file_info_display(game: GameResource) -> void:
	# Get the active file info (either main game or selected sibling)
	var active_file_name = game.get_active_file_name()
	var active_file_size = game.get_active_file_size()
	
	file_info_label.text = "File: " + (active_file_name if active_file_name else "N/A")
	file_size_label.text = "Size: " + _format_file_size(active_file_size)
	
	# Check if the selected variant has a local copy
	if game.is_active_variant_downloaded():
		status_label.text = "✓ Downloaded"
		status_label.modulate = Color.GREEN
	else:
		status_label.text = "☐ Not downloaded"
		status_label.modulate = Color.GRAY

func _load_cover(game: GameResource) -> void:
	cover_texture.texture = null
	
	if game.cover_path and FileAccess.file_exists(game.cover_path):
		var img = Image.new()
		var err = img.load(game.cover_path)
		if err == OK:
			cover_texture.texture = ImageTexture.create_from_image(img)
			return
	
	if game.cover_url and game.cover_url.begins_with("http"):
		DataManager.load_image(game.cover_url, func(texture):
			if texture and _current_game and _current_game.romm_id == game.romm_id:
				cover_texture.texture = texture
		)

func _format_file_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	elif bytes < 1024 * 1024:
		return str(bytes / 1024) + " KB"
	elif bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	else:
		return "%.1f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))

func _update_action_button() -> void:
	if not action_button or not _current_game:
		return
	
	if _current_game.is_active_variant_downloaded():
		action_button.text = "Launch"
		# Use green color for launch button
		action_button.modulate = Color(0.4, 0.8, 0.4)
	else:
		action_button.text = "Download"
		# Use blue color for download button
		action_button.modulate = Color(0.4, 0.6, 1.0)

func _on_action_button_pressed() -> void:
	if not _current_game:
		return
	
	# Skip file check for GameNative games - they don't have physical files
	if _current_game.source == "gamenative":
		print("[GameDetailsView] Launching GameNative game: ", _current_game.steam_app_id)
		LaunchManager.launch_game(_current_game)
		return
	
	if _current_game.is_active_variant_downloaded():
		# Check if the file actually exists before launching
		var root_folder = SettingsManager.get_setting("games_root_folder")
		if root_folder and root_folder.value != "":
			# Construct the full file path from known components (don't rely on file_path which may be relative)
			var active_file_name = _current_game.get_active_file_name()
			var file_path = root_folder.value + "/" + _current_game.platform_slug + "/" + active_file_name
			
			if not FileAccess.file_exists(file_path):
				# File is marked as downloaded but doesn't exist - redownload
				print("[GameDetailsView] File not found for game %d at %s, queuing redownload" % [_current_game.romm_id, file_path])
				NotificationManager.show_notification("File not found - redownloading", Notification.Type.WARNING)
				_queue_download()
				return
		
		# Launch the game
		print("[GameDetailsView] Launch requested for game: ", _current_game.romm_id)
		LaunchManager.launch_game(_current_game)
	else:
		# Download the game - same logic as library view
		_queue_download()

func _queue_download() -> void:
	if not _current_game:
		return
	
	# Use the selected sibling's ID and file name if one is selected
	var active_game_id = _current_game.get_active_game_id()
	var active_file_name = _current_game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		NotificationManager.show_notification("Error: Games folder not set", Notification.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + _current_game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", _current_game.get_display_name(), false, "", _current_game, {}, active_game_id)
	
	if item_id != "":
		NotificationManager.show_notification("Queued: " + _current_game.get_display_name(), Notification.Type.INFO)
	else:
		NotificationManager.show_notification("Failed to queue download", Notification.Type.ERROR)

func _on_download_completed(item_id: String, success: bool, message: String) -> void:
	# Check if this download is for our current game
	if not _current_game:
		return
	
	var item = DownloadManager.get_item(item_id)
	if item and item.game_resource and item.game_resource.romm_id == _current_game.romm_id:
		if success:
			NotificationManager.show_notification("Download completed", Notification.Type.INFO)
		else:
			NotificationManager.show_notification("Download failed: " + message, Notification.Type.ERROR)
		
		# Reload game data from DataManager to get updated downloaded_sibling_ids
		var updated_game = DataManager.get_game_by_id(_current_game.romm_id)
		if updated_game:
			_current_game = updated_game
		
		# Refresh the action button state
		_update_action_button()
		# Also refresh the file info display
		_update_file_info_display(_current_game)

func clear() -> void:
	_current_game = null
	title_label.text = ""
	cover_texture.texture = null
	platform_label.text = ""
	genres_label.text = ""
	rating_label.text = ""
	file_info_label.text = ""
	file_size_label.text = ""
	status_label.text = ""
	description_label.text = ""
