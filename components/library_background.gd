class_name LibraryBackground
extends Control

var _current_effect: BackgroundEffect = null
var _background_state: BackgroundState = null

func _ready():
	# Wait for next frame to initialize
	call_deferred("_initialize_background")
	resized.connect(_on_resized)

func _on_resized() -> void:
	# Update effect size when LibraryBackground resizes
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
	
	# Default config
	return {
		"effect_id": "xmb",
		"settings": {
			"time_scale": 1.0,
			"show_dust": true,
			"wave_intensity": 1.0,
			"star_threshold": 0.99,
			"color_top_left": Color(0.7, 0.2, 0.2, 1.0),
			"color_top_right": Color(0.4, 0.1, 0.1, 1.0),
			"color_bottom_left": Color(0.45, 0.1, 0.1, 1.0),
			"color_bottom_right": Color(0.8, 0.3, 0.5, 1.0),
			"wave_blend_color": Color.WHITE
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
		_current_effect.layout_mode = 1  # Required for anchors to work
		_current_effect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_current_effect.visible = true
		# Force size to match parent immediately
		_current_effect.size = size
		_current_effect.initialize(_background_state.effect_settings)

func _create_effect(effect_id: String) -> BackgroundEffect:
	match effect_id:
		"solid":
			return SolidBackgroundEffect.new()
		"xmb":
			return XmbBackgroundEffect.new()
		"motes":
			return MotesBackgroundEffect.new()
		"osdsys":
			return OsdSysBackgroundEffect.new()
		_:
			return XmbBackgroundEffect.new()

func _on_effect_changed(_new_effect_id: String) -> void:
	_apply_background_state()

func _on_setting_changed(setting_name: String, value: Variant) -> void:
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
		_background_state.effect_id = config.get("effect_id", "xmb")
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
func set_background_color(_color: Color) -> void:
	# This is now handled by the solid background effect
	pass

# Get available effect IDs for dropdown
static func get_available_effects() -> Array[String]:
	return ["solid", "xmb", "motes", "osdsys"]

# Get effect display name
static func get_effect_display_name(effect_id: String) -> String:
	match effect_id:
		"solid": return "Solid Color"
		"xmb": return "XMB"
		"motes": return "Motes"
		"osdsys": return "OSDSYS"
		_: return "Unknown"

# Get settings schema for an effect
static func get_effect_schema(effect_id: String) -> Array[SettingsVar]:
	var effect: BackgroundEffect
	match effect_id:
		"solid":
			effect = SolidBackgroundEffect.new()
		"xmb":
			effect = XmbBackgroundEffect.new()
		"motes":
			effect = MotesBackgroundEffect.new()
		"osdsys":
			effect = OsdSysBackgroundEffect.new()
		_:
			effect = XmbBackgroundEffect.new()
	
	var schema = effect.get_settings_schema()
	effect.queue_free()
	return schema
