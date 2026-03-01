class_name OsdSysBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "OSDSYS"
	effect_id = "osdsys"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/library_background_osdsys.gdshader")

func _apply_settings() -> void:
	# OSDSYS effect has no configurable settings - everything is hardcoded
	pass

func get_settings_schema() -> Array[SettingsVar]:
	# Return empty array - no settings for this effect
	return []
