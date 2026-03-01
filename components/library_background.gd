class_name LibraryBackground
extends Control

@onready var color_rect: ColorRect = $ColorRect

var _material: ShaderMaterial = null

func _ready():
	# Get the shader material
	if color_rect and color_rect.material is ShaderMaterial:
		_material = color_rect.material
	else:
		push_error("[LibraryBackground] No material found!")

func set_background_color(color: Color) -> void:
	if _material:
		_material.set_shader_parameter("background_color", color)
