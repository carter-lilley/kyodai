class_name BackgroundState
extends RefCounted

signal effect_changed(effect_id: String)
signal setting_changed(setting_name: String, value: Variant)
signal background_color_changed(color: Color)

var effect_id: String = "xmb":
	set(value):
		if effect_id != value:
			effect_id = value
			effect_changed.emit(value)

var effect_settings: Dictionary = {}:
	set(value):
		effect_settings = value.duplicate()

var background_color: Color = Color(0.1, 0.1, 0.15, 1.0):
	set(value):
		if background_color != value:
			background_color = value
			background_color_changed.emit(value)

func _init(config: Dictionary = {}) -> void:
	effect_id = config.get("effect_id", "xmb")
	effect_settings = config.get("settings", {}).duplicate()
	background_color = config.get("background_color", Color(0.1, 0.1, 0.15, 1.0))

func get_setting(key: String, default: Variant = null) -> Variant:
	return effect_settings.get(key, default)

func set_setting(key: String, value: Variant) -> void:
	effect_settings[key] = value
	setting_changed.emit(key, value)

func get_config() -> Dictionary:
	return {
		"effect_id": effect_id,
		"background_color": background_color,
		"settings": effect_settings.duplicate()
	}

func duplicate() -> BackgroundState:
	return BackgroundState.new(get_config())
