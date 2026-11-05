class_name MotesBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Motes"
	effect_id = "motes"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_motes.gdshader")
