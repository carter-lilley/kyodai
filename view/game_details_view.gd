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

var _current_game: GameResource = null
var _sibling_options: Array[Dictionary] = []  # [{id, name, file_name, file_size}, ...]

func _ready():
	super._ready()
	if sibling_dropdown:
		sibling_dropdown.item_selected.connect(_on_sibling_selected)

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
		# Update display to show selected variant's info
		_update_file_info_display(_current_game)
		# Persist the selection
		DataManager.update_game(_current_game)

func _update_file_info_display(game: GameResource) -> void:
	# Get the active file info (either main game or selected sibling)
	var active_file_name = game.get_active_file_name()
	var active_file_size = game.get_active_file_size()
	
	file_info_label.text = "File: " + (active_file_name if active_file_name else "N/A")
	file_size_label.text = "Size: " + _format_file_size(active_file_size)
	
	# Check if the selected variant has a local copy
	# For now, we only track local copy status on the main game
	# In the future, you might want to track per-variant download status
	if game.has_local_copy:
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
