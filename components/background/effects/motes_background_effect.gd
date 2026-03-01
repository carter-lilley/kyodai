class_name MotesBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Motes"
	effect_id = "motes"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/library_background_motes.gdshader")

func _apply_settings() -> void:
	# Motes effect has no configurable settings - everything is hardcoded
	pass

func get_settings_schema() -> Array[SettingsVar]:
	# Return empty array - no settings for this effect
	return []
