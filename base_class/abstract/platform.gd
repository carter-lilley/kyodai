class_name PlatformResource
extends Resource

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

@export var id: String
@export var slug: String
@export var name: String
@export var romm_id: int
@export var icon_url: String
@export var icon_path: String
@export var emulator_path: String
@export var extensions: Array[String] = []

func get_icon() -> Texture2D:
	if icon_path and FSM.file_exists(icon_path):
		var img = Image.new()
		var error = img.load(icon_path)
		if error == OK and not img.is_empty():
			return SystemManager.memory.create_texture_from_image(img)
	return null
