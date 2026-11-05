class_name OsdSysBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "OSDSYS"
	effect_id = "osdsys"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_osdsys.gdshader")
