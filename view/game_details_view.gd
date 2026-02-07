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

var _current_game: GameResource = null

func _ready():
	super._ready()

func set_game(game: GameResource) -> void:
	_current_game = game
	
	if not is_node_ready():
		await ready
	
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
	
	file_info_label.text = "File: " + (game.file_name if game.file_name else "N/A")
	file_size_label.text = "Size: " + _format_file_size(game.file_size)
	
	if game.has_local_copy:
		status_label.text = "✓ Downloaded"
		status_label.modulate = Color.GREEN
	else:
		status_label.text = "☐ Not downloaded"
		status_label.modulate = Color.GRAY
	
	description_label.text = game.description if game.description else "No description available."
	
	_load_cover(game)

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
