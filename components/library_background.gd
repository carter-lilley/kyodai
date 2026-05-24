class_name LibraryBackground
extends Control

var _current_effect: BackgroundEffect = null
var _background_state: BackgroundState = null

func _ready():
	_initialize_background()
	resized.connect(_on_resized)

func _on_resized() -> void:
	if _current_effect:
		_current_effect.size = size

func _initialize_background() -> void:
	# Get initial config from settings if available
	var config = _get_initial_config()
	_background_state = BackgroundState.new(config)
	_background_state.effect_changed.connect(_on_effect_changed)
	_background_state.setting_changed.connect(_on_setting_changed)
	_apply_background_state()

func _get_initial_config() -> Dictionary:
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("library_background_config")
		if config_setting and config_setting.value is Dictionary:
			return config_setting.value.duplicate()
	
	# Default config - gradient effect
	var default_gradient = Gradient.new()
	default_gradient.offsets = [0.0, 1.0]
	default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
	
	return {
		"effect_id": "gradient",
		"settings": {
			"background_gradient": default_gradient,
			"gradient_direction": 0
		}
	}

func _apply_background_state() -> void:
	if not _background_state:
		return
	
	# Remove current effect if any
	if _current_effect:
		_current_effect.queue_free()
		_current_effect = null
	
	# Create and add new effect
	_current_effect = _create_effect(_background_state.effect_id)
	if _current_effect:
		add_child(_current_effect)
		_current_effect.position = Vector2.ZERO
		_current_effect.size = size
		_current_effect.visible = true
		_current_effect.initialize(_background_state.effect_settings)

func _create_effect(effect_id: String) -> BackgroundEffect:
	match effect_id:
		"none":
			return null
		"gradient":
			return GradientBackgroundEffect.new()
		"xmb":
			return XmbBackgroundEffect.new()
		"xmb_classic":
			return XmbClassicBackgroundEffect.new()
		"motes":
			return MotesBackgroundEffect.new()
		"osdsys":
			return OsdSysBackgroundEffect.new()
		"cafeos":
			return CafeOSBackgroundEffect.new()
		_:
			return GradientBackgroundEffect.new()

func _on_effect_changed(_new_effect_id: String) -> void:
	_apply_background_state()

func _on_setting_changed(_setting_name: String, _value: Variant) -> void:
	if _current_effect:
		_current_effect.update_settings(_background_state.effect_settings)

# Public API for updating background configuration
func set_background_config(config: Dictionary) -> void:
	if not _background_state:
		_background_state = BackgroundState.new(config)
		_background_state.effect_changed.connect(_on_effect_changed)
		_background_state.setting_changed.connect(_on_setting_changed)
		_apply_background_state()
	else:
		var old_effect_id = _background_state.effect_id
		_background_state.effect_id = config.get("effect_id", "gradient")
		_background_state.effect_settings = config.get("settings", {}).duplicate()
		
		if _background_state.effect_id != old_effect_id:
			_apply_background_state()
		else:
			# Same effect, just update settings
			if _current_effect:
				_current_effect.update_settings(_background_state.effect_settings)

func get_background_config() -> Dictionary:
	if _background_state:
		return _background_state.get_config()
	return _get_initial_config()

# Legacy method for backward compatibility
func set_background_color(color: Color) -> void:
	if _background_state:
		# Convert solid color to single-color gradient
		var gradient = Gradient.new()
		gradient.offsets = [0.0, 1.0]
		gradient.colors = [color, color]
		_background_state.effect_settings["background_gradient"] = gradient
		if _current_effect:
			_current_effect.update_settings(_background_state.effect_settings)

# Get available effect IDs for dropdown
static func get_available_effects() -> Array[String]:
	return ["none", "gradient", "xmb", "xmb_classic", "motes", "osdsys", "cafeos"]

# Get effect display name
static func get_effect_display_name(effect_id: String) -> String:
	match effect_id:
		"none": return "None"
		"gradient": return "Gradient"
		"xmb": return "XMB"
		"xmb_classic": return "XMB (Classic)"
		"motes": return "Motes"
		"osdsys": return "OSDSYS"
		"cafeos": return "CafeOS"
		_: return "Unknown"

# Get settings schema for an effect
static func get_effect_schema(effect_id: String) -> Array[SettingsVar]:
	if effect_id == "none":
		return []
	
	var effect: BackgroundEffect
	match effect_id:
		"gradient":
			effect = GradientBackgroundEffect.new()
		"xmb":
			effect = XmbBackgroundEffect.new()
		"xmb_classic":
			effect = XmbClassicBackgroundEffect.new()
		"motes":
			effect = MotesBackgroundEffect.new()
		"osdsys":
			effect = OsdSysBackgroundEffect.new()
		"cafeos":
			effect = CafeOSBackgroundEffect.new()
		_:
			effect = GradientBackgroundEffect.new()
	
	var schema = effect.get_settings_schema()
	effect.queue_free()
	return schema
