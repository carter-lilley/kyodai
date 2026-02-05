class_name GameResource
extends Resource

@export var id: String
@export var romm_id: int
@export var title: String
@export var platform: String
@export var platform_slug: String
@export var cover_url: String
@export var cover_path: String
@export var file_name: String
@export var file_path: String
@export var file_size: int
@export var has_local_copy: bool = false
@export var last_updated: String
@export var description: String
@export var genres: Array[String] = []
@export var rating: float = 0.0

func get_display_name() -> String:
	return title if title else file_name

func get_cover_image() -> Texture2D:
	if cover_path and FileAccess.file_exists(cover_path):
		var img = Image.new()
		var error = img.load(cover_path)
		if error == OK:
			return ImageTexture.create_from_image(img)
	return null
