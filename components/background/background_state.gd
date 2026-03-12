class_name BackgroundState
extends RefCounted

signal effect_changed(effect_id: String)
signal setting_changed(setting_name: String, value: Variant)
signal background_gradient_changed(gradient: Gradient)
signal gradient_direction_changed(direction: int)

var effect_id: String = "xmb":
	set(value):
		if effect_id != value:
			effect_id = value
			effect_changed.emit(value)

var effect_settings: Dictionary = {}:
	set(value):
		effect_settings = value.duplicate()

var background_gradient: Gradient:
	set(value):
		if background_gradient != value:
			background_gradient = value
			background_gradient_changed.emit(value)

var gradient_direction: int = 0:  # 0 = horizontal, 1 = vertical, 2 = diagonal
	set(value):
		if gradient_direction != value:
			gradient_direction = value
			gradient_direction_changed.emit(value)

func _init(config: Dictionary = {}) -> void:
	effect_id = config.get("effect_id", "xmb")
	effect_settings = config.get("settings", {}).duplicate()
	
	# Load gradient from config or create default
	var gradient_data = config.get("background_gradient")
	if gradient_data is Gradient:
		background_gradient = gradient_data
	elif gradient_data is Dictionary and gradient_data.has("offsets") and gradient_data.has("colors"):
		# Reconstruct gradient from serialized data
		background_gradient = Gradient.new()
		background_gradient.offsets = gradient_data.offsets
		background_gradient.colors = gradient_data.colors
	else:
		# Create default dark gradient
		background_gradient = Gradient.new()
		background_gradient.offsets = [0.0, 1.0]
		background_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
	
	gradient_direction = config.get("gradient_direction", 0)

func get_setting(key: String, default: Variant = null) -> Variant:
	return effect_settings.get(key, default)

func set_setting(key: String, value: Variant) -> void:
	effect_settings[key] = value
	setting_changed.emit(key, value)

func get_config() -> Dictionary:
	return {
		"effect_id": effect_id,
		"background_gradient": background_gradient,
		"gradient_direction": gradient_direction,
		"settings": effect_settings.duplicate()
	}

func duplicate() -> BackgroundState:
	return BackgroundState.new(get_config())
